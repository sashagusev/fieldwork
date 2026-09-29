import SwiftUI
import AppKit
import ResearchCore

enum WorkspaceView: String, CaseIterable { case aims = "Aims", timeline = "Timeline", graph = "Graph" }
struct EditorRequest: Identifiable { let id = UUID(); var node: ResearchNode?; var kind: NodeKind; var parentID: String; var appendToWorkflow = false; var title = "" }
extension EditorRequest {
    func suggestedOrder(parentID: String, workspace: Workspace) -> Int {
        let siblings = workspace.children(parentID)
        if kind == .question { return (siblings.map(\.order).min() ?? 10) - 10 }
        if !appendToWorkflow, kind == .task, let synthesis = siblings.first(where: { [.answer, .conclusion].contains($0.kind) && $0.status == .planned }) {
            let lower = siblings.filter { $0.kind.isStep && $0.order < synthesis.order }.map(\.order).max() ?? 0
            if synthesis.order - lower > 1 { return lower + (synthesis.order - lower) / 2 }
        }
        return (siblings.map(\.order).max() ?? 0) + 10
    }
}
struct ActionRequest: Identifiable { let id = UUID(); var nodeID: String; var isFailure = false; var isCompletion = false }

struct GraphFocusRequest: Identifiable { let id = UUID(); let nodeID: String }
struct HierarchyDeletion { let id: String; let kind: NodeKind; let backupURL: URL }

@MainActor final class AppStore: ObservableObject {
    @Published var workspace = Workspace()
    @Published var repository: WorkspaceRepository?
    @Published var selectedID: String?
    @Published var aimID: String?
    @Published var expandedAimID: String?
    @Published var questionID: String?
    @Published var view: WorkspaceView = .aims
    @Published var error: String?
    @Published var diskError: String?
    @Published var editor: EditorRequest?
    @Published var action: ActionRequest?
    @Published var graphFocus: GraphFocusRequest?
    @Published var questionDrag: QuestionDragState?
    @Published var aimDrag: AimDragState?
    @Published var stepDrag: StepDragState?
    // The done row whose bullet is under the pointer; its rating thumb slides out.
    @Published var ratingRevealID: String?
    @Published var deletedHierarchy: HierarchyDeletion?
    @Published var lastSynced = Date()
    // Most recent first, remembered across launches.
    @Published var recentWorkspaces: [URL] = (UserDefaults.standard.stringArray(forKey: "fieldwork.recentWorkspaces") ?? []).map { URL(fileURLWithPath: $0) }
    @Published var query = ""
    @AppStorage("fieldwork.motion") var motion = true
    // Row positions in the "lists" coordinate space; read while dragging, so deliberately not published.
    var rowFrames: [String: CGRect] = [:]
    private var diskFingerprint = ""

    init(workspaceURL: URL? = nil) {
        if let workspaceURL { open(workspaceURL); return }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--workspace"), args.indices.contains(i+1) { open(URL(fileURLWithPath: args[i+1])); return }
        if let saved = UserDefaults.standard.string(forKey: "fieldwork.workspace"), FileManager.default.fileExists(atPath: saved) { open(URL(fileURLWithPath: saved)); return }
        openExample()
    }
    var selected: ResearchNode? { selectedID.flatMap(workspace.node) }
    var selectedAncestorIDs: Set<String> {
        var ancestors: Set<String> = []
        var parentID = selected?.parentID ?? ""
        while !parentID.isEmpty, parentID != selectedID, let parent = workspace.node(parentID), ancestors.insert(parentID).inserted {
            parentID = parent.parentID
        }
        return ancestors
    }
    // Aims read in their arranged order; ones never arranged keep creation order.
    var aims: [ResearchNode] {
        workspace.newestFirst(workspace.nodes.filter { $0.kind == .aim }).reversed().enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }
    var activeAims: [ResearchNode] { aims.filter { workspace.progress($0) != .done } }
    var completedAims: [ResearchNode] { aims.filter { workspace.progress($0) == .done } }
    // Typed straight into the list: the question leads its aim without stealing the selection.
    @discardableResult func quickAddQuestion(_ title: String, to aimID: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let order = (workspace.children(aimID).map(\.order).min() ?? 10) - 10
        let question = ResearchNode(kind: .question, parentID: aimID, order: order, title: title)
        return mutate(action: "create", id: question.id, detail: title) { try $0.add(question) }
    }
    var timelineNodes: [ResearchNode] { workspace.newestFirst(workspace.nodes) }
    func setStatus(_ node: ResearchNode, to status: NodeStatus) {
        mutate(action: "set_status", id: node.id, detail: status == .complete ? "Done" : status.label) {
            try $0.setManualStatus(node.id, status: status, actor: "human")
        }
    }
    // One click advances the checklist state: staged → working → done → staged.
    func cycleStatus(_ node: ResearchNode) {
        switch workspace.progress(node) {
        case .working: setStatus(node, to: .complete)
        case .done: setStatus(node, to: .planned)
        default: setStatus(node, to: .running)
        }
    }
    // Neutral → thumbs up → thumbs down → neutral.
    func cycleRating(_ node: ResearchNode) {
        let next: Rating? = switch workspace.ratings[node.id] { case nil: .up; case .up: .down; case .down: nil }
        mutate(action: "rate", id: node.id, detail: next?.rawValue ?? "neutral") { try $0.setRating(node.id, to: next) }
    }
    var questions: [ResearchNode] { aimID.map { workspace.children($0).filter { $0.kind == .question } } ?? [] }
    var visibleQuestions: [ResearchNode] { questions.filter { questionID == nil || $0.id == questionID } }
    var searchResults: [ResearchNode] {
        guard !query.isEmpty else { return [] }
        return workspace.nodes.filter { ($0.id + " " + $0.title + " " + $0.shortSummary).localizedCaseInsensitiveContains(query) }
    }
    func openExample() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fieldwork/Example Research", isDirectory: true)
        do {
            let repo = WorkspaceRepository(url: base)
            if !FileManager.default.fileExists(atPath: base.appendingPathComponent("workspace.csv").path) { _ = try repo.create(name: "Retrieval · Example", sample: true) }
            open(base)
        } catch { self.error = error.localizedDescription }
    }
    func open(_ url: URL) {
        do {
            let repo = WorkspaceRepository(url: url), fingerprint = repo.fingerprint(), state = try repo.load()
            repository = repo; workspace = state; deletedHierarchy = nil; graphFocus = nil; questionDrag = nil; aimDrag = nil; stepDrag = nil; diskFingerprint = fingerprint; diskError = nil
            aimID = aims.first?.id; expandedAimID = nil; questionID = nil; selectedID = aimID
            UserDefaults.standard.set(url.path, forKey: "fieldwork.workspace"); lastSynced = Date()
            remember(repo.url)
        } catch { self.error = error.localizedDescription }
    }
    private func remember(_ url: URL) {
        recentWorkspaces.removeAll { $0.standardizedFileURL.path == url.path }
        recentWorkspaces.insert(url, at: 0)
        recentWorkspaces = Array(recentWorkspaces.prefix(10))
        UserDefaults.standard.set(recentWorkspaces.map(\.path), forKey: "fieldwork.recentWorkspaces")
    }
    func forgetRecentWorkspaces() {
        recentWorkspaces = []
        UserDefaults.standard.removeObject(forKey: "fieldwork.recentWorkspaces")
    }
    func chooseWorkspace() {
        let p = NSOpenPanel(); p.title = "Open a research workspace"; p.prompt = "Open workspace"; p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        // Start beside the open workspace, so it and its neighbours are in view.
        p.directoryURL = repository?.url.deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url { open(url) }
    }
    func newWorkspace() {
        let p = NSSavePanel(); p.title = "Create a research workspace"; p.prompt = "Create workspace"; p.nameFieldStringValue = "New Research"; p.canCreateDirectories = true
        p.directoryURL = repository?.url.deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url {
            do { _ = try WorkspaceRepository(url: url).create(name: url.lastPathComponent); open(url); newNode(.aim) } catch { self.error = error.localizedDescription }
        }
    }
    func sync(force: Bool = false) {
        guard let repo = repository else { return }
        let fingerprint = repo.fingerprint()
        guard force || fingerprint != diskFingerprint else { lastSynced = Date(); return }
        do {
            let latest = try repo.load()
            if latest != workspace { withAnimation(motion ? .easeInOut(duration: 0.22) : nil) { workspace = latest } }
            diskFingerprint = fingerprint; diskError = nil; lastSynced = Date()
            if let aimID, workspace.node(aimID) == nil { self.aimID = aims.first?.id; questionID = nil }
            if let expandedAimID, workspace.node(expandedAimID) == nil { self.expandedAimID = nil; questionID = nil }
            if let questionID, workspace.node(questionID) == nil { self.questionID = nil }
            if let selectedID, workspace.node(selectedID) == nil { self.selectedID = nil }
        } catch { diskError = "CSV changes need attention: " + error.localizedDescription }
    }
    @discardableResult func mutate(action: String, id: String = "", detail: String = "", _ body: (inout Workspace) throws -> Void) -> Bool {
        guard let repo = repository else { return false }
        do {
            let s = try repo.update(actor: "human", action: action, nodeID: id, detail: detail, body)
            withAnimation(motion ? .easeInOut(duration: 0.22) : nil) { workspace = s }
            diskFingerprint = repository?.committedFingerprint ?? ""; diskError = nil; lastSynced = Date(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveRecord(_ node: ResearchNode, replacing original: ResearchNode?, additionalChanges: (inout Workspace) throws -> Void = { _ in }) throws {
        guard let repo = repository else { throw ResearchError("Open a workspace before creating a record.") }
        let saved = try repo.update(actor: "human", action: original == nil ? "create" : "edit", nodeID: node.id, detail: node.title) { state in
            if let original { try state.edit(node, expectedUpdatedAt: original.updatedAt) }
            else { try state.add(node) }
            try additionalChanges(&state)
        }
        workspace = saved
        if let selected = saved.node(node.id) { select(selected, focus: true) }
        diskFingerprint = repository?.committedFingerprint ?? ""; diskError = nil; lastSynced = Date()
        editor = nil
    }
    @discardableResult func moveQuestion(_ id: String, toAim aimID: String, relativeTo anchorID: String? = nil, after: Bool = false, expectedAimID: String? = nil) -> Bool {
        let moved = mutate(action: "move_question", id: id, detail: "Aim: \(aimID); \(after ? "after" : "before"): \(anchorID ?? "end")") {
            try $0.moveQuestion(id, toAim: aimID, relativeTo: anchorID, after: after, expectedAimID: expectedAimID)
        }
        // Follow a question to its new aim without opening it; a reorder leaves the view alone.
        if moved, expandedAimID != aimID { selectedID = id; self.aimID = aimID; expandedAimID = aimID; questionID = nil }
        return moved
    }

    func select(_ n: ResearchNode, focus: Bool = false) {
        if selectedID != n.id { selectedID = n.id }
        let aim = workspace.aimID(for: n)
        let question = workspace.questionID(for: n)
        if let aim, aimID != aim { aimID = aim; if questionID != question { questionID = question } }
        if let aim, (focus || n.kind != .aim), expandedAimID != aim { expandedAimID = aim }
        if focus {
            let targetQuestion = n.kind == .aim ? nil : question
            if questionID != targetQuestion { questionID = targetQuestion }
        }
    }
    func toggle(_ node: ResearchNode) {
        if node.kind == .aim && expandedAimID == node.id {
            if selectedID != node.id { selectedID = node.id }
            expandedAimID = nil
            if questionID != nil { questionID = nil }
        } else if node.kind == .question && questionID == node.id {
            if selectedID != node.id { selectedID = node.id }
            questionID = nil
        } else { select(node, focus: true) }
    }
    // The Aims tab doubles as "back": chosen while already showing an open question, it slides the lists home.
    func show(_ view: WorkspaceView) {
        if view == .aims && self.view == .aims && questionID != nil { questionID = nil }
        self.view = view
    }
    func reveal(_ node: ResearchNode) {
        select(node, focus: true)
        if view != .aims { view = .aims }
        graphFocus = GraphFocusRequest(nodeID: node.id)
    }
    func requestCompletion(_ node: ResearchNode) {
        guard node.kind == .task, !node.status.terminal else { return }
        guard workspace.nextStep(node.parentID)?.id == node.id else {
            error = "Finish the earlier workflow steps before completing this record."; return
        }
        action = ActionRequest(nodeID: node.id, isCompletion: true)
    }
    func deleteQuestion(_ node: ResearchNode) { deleteCard(node) }
    func deleteAim(_ node: ResearchNode) { deleteCard(node) }
    func deleteCard(_ node: ResearchNode) {
        guard let repo = repository else { return }
        do {
            let deletion = try repo.deleteNode(node.id, actor: "human")
            workspace = deletion.workspace
            deletedHierarchy = HierarchyDeletion(id: node.id, kind: node.kind, backupURL: deletion.backupURL)
            if let aimID, workspace.node(aimID) == nil { self.aimID = aims.first?.id }
            if let expandedAimID, workspace.node(expandedAimID) == nil { self.expandedAimID = nil }
            if let questionID, workspace.node(questionID) == nil { self.questionID = nil }
            if let selectedID, workspace.node(selectedID) == nil { self.selectedID = workspace.node(node.parentID)?.id ?? questionID ?? aimID }
            graphFocus = nil; diskFingerprint = repository?.committedFingerprint ?? ""; lastSynced = Date()
        } catch { self.error = error.localizedDescription }
    }
    func undoHierarchyDeletion() {
        guard let repo = repository, let deleted = deletedHierarchy else { return }
        do {
            workspace = try repo.restoreNode(deleted.id, from: deleted.backupURL, actor: "human")
            deletedHierarchy = nil; diskFingerprint = repository?.committedFingerprint ?? ""; lastSynced = Date()
            if let node = workspace.node(deleted.id) { reveal(node) }
        } catch { self.error = error.localizedDescription }
    }
    func newNode(_ kind: NodeKind, parentID: String? = nil, append: Bool = false, title: String = "") {
        let parent: String
        if let parentID { parent = parentID }
        else { switch kind { case .aim: parent = ""; case .question: parent = aimID ?? ""; case .result: parent = selected?.kind == .task ? selected!.id : ""; default: parent = questionID ?? selected.flatMap { workspace.questionID(for: $0) } ?? questions.first?.id ?? "" } }
        editor = EditorRequest(kind: kind, parentID: parent, appendToWorkflow: append, title: title)
    }
    func editSelected() { if let n = selected { editor = EditorRequest(node: n, kind: n.kind, parentID: n.parentID) } }
    func revealResults(_ n: ResearchNode) { if let url = repository?.resultsURL(for: n), FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func copyPath(_ n: ResearchNode) {
        guard let url = repository?.resultsURL(for: n) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
    }
}

enum Palette {
    // Monochrome on white; color is reserved for links and exceptions.
    static let ink = Color(red: 0.094, green: 0.094, blue: 0.106) // #18181B
    static let body = Color(red: 0.322, green: 0.322, blue: 0.357) // #52525B
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.667) // #A1A1AA
    static let faint = Color(red: 0.831, green: 0.831, blue: 0.847) // #D4D4D8
    static let line = Color(red: 0.929, green: 0.929, blue: 0.937) // #EDEDEF
    static let accent = Color(red: 0.145, green: 0.388, blue: 0.922) // #2563EB
    static let canvas = Color(red: 0.98, green: 0.98, blue: 0.98) // #FAFAFA
    static let card = Color.white
    static let quiet = Color(red: 0.957, green: 0.957, blue: 0.961) // #F4F4F5
    static let good = Color(red: 0.082, green: 0.502, blue: 0.239) // #15803D
    static let goodWash = Color(red: 0.918, green: 0.976, blue: 0.937) // #EAF9EF
    static let bad = Color(red: 0.725, green: 0.11, blue: 0.11) // #B91C1C
    static let badWash = Color(red: 0.996, green: 0.937, blue: 0.937) // #FEEFEF
    // Softer tints for the graph, where rated nodes glow.
    static let goodGlow = Color(red: 0.40, green: 0.83, blue: 0.56) // #66D48F
    static let badGlow = Color(red: 0.96, green: 0.52, blue: 0.52) // #F58585
    static let failed = Color(red: 0.835, green: 0.122, blue: 0.239) // #D51F3D
    static let held = Color(red: 0.706, green: 0.325, blue: 0.035) // #B45309
}

extension NodeKind {
    var symbol: String {
        switch self {
        case .aim: return "scope"
        case .question: return "questionmark.circle"
        case .task: return "checklist"
        case .result: return "doc.text"
        case .answer: return "text.bubble"
        case .conclusion: return "flag.checkered"
        }
    }
}
struct Eyebrow: View { var text: String; var body: some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted) } }

extension Workspace {
    // Creation events break timestamp ties without changing when a card is edited.
    func newestFirst(_ records: [ResearchNode]) -> [ResearchNode] {
        var creationOrder: [String: Int] = [:]
        for (index, event) in events.enumerated() where event.action == "create" {
            if creationOrder[event.nodeID] == nil { creationOrder[event.nodeID] = index }
        }
        return records.map { node in
            (node: node, date: parseTimestamp(node.createdAt) ?? .distantPast, order: creationOrder[node.id] ?? -1)
        }.sorted { ($0.date, $0.order, $0.node.id) > ($1.date, $1.order, $1.node.id) }.map(\.node)
    }
}

// The three checklist states, plus the workflow exceptions a click cannot produce.
enum Progress: String {
    case staged = "Staged", working = "Working", done = "Done", failed = "Failed", held = "On hold", skipped = "Skipped"
    var symbol: String {
        switch self {
        case .staged: return "circle.dashed"
        case .working: return "circle.inset.filled"
        case .done: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .held: return "pause.circle"
        case .skipped: return "minus.circle"
        }
    }
}

extension Workspace {
    func progress(_ node: ResearchNode) -> Progress {
        switch node.status {
        case .complete, .recorded, .accepted: return .done
        case .running: return .working
        case .failed, .rejected: return .failed
        case .hold: return .held
        case .skipped: return .skipped
        case .planned: return .staged
        // Until someone sets it by hand, a question is working once any of its steps has started.
        case .active: return steps(node.id).contains { $0.status != .planned } ? .working : .staged
        }
    }
}
