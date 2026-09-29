import SwiftUI
import ResearchCore

struct QuestionDragState: Equatable {
    var questionID: String
    var sourceAimID: String
    var workspacePath: String
    // Row positions when the drag began. Rows slide while dragging, so live frames would feed back into the drop position.
    var startFrames: [String: CGRect]
    var originalIndex: Int
    var translation: CGSize = .zero
    var targetAimID: String
    var insertionIndex: Int
    var validDrop = true
    var movesWithinAim: Bool { validDrop && targetAimID == sourceAimID }
}

extension AppStore {
    private func siblings(of id: String, in aimID: String) -> [ResearchNode] {
        workspace.children(aimID).filter { $0.kind == .question && $0.id != id }
    }

    // Locations are in the "lists" coordinate space, matching rowFrames.
    func updateQuestionDrag(_ id: String, location: CGPoint, translation: CGSize) {
        guard let node = workspace.node(id), node.kind == .question, let repository else { return }
        if questionDrag == nil {
            let index = workspace.children(node.parentID).filter { $0.kind == .question }.firstIndex { $0.id == id } ?? 0
            questionDrag = QuestionDragState(questionID: id, sourceAimID: node.parentID, workspacePath: repository.url.path, startFrames: rowFrames, originalIndex: index, targetAimID: node.parentID, insertionIndex: index)
        }
        guard var drag = questionDrag, drag.questionID == id else { return }
        drag.translation = translation
        drag.validDrop = false
        drag.targetAimID = drag.sourceAimID
        drag.insertionIndex = drag.originalIndex
        let others = siblings(of: id, in: drag.sourceAimID)
        let column = (others + [node]).compactMap { drag.startFrames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
        if let aim = aims.first(where: { $0.id != drag.sourceAimID && drag.startFrames[$0.id]?.contains(location) == true }) {
            drag.targetAimID = aim.id
            drag.insertionIndex = siblings(of: id, in: aim.id).count
            drag.validDrop = true
        } else if column.insetBy(dx: -18, dy: -48).contains(location), let start = drag.startFrames[id] {
            // The dragged row trades places with a neighbour once its centre passes the neighbour's centre.
            let centre = start.midY + translation.height
            drag.insertionIndex = others.filter { (drag.startFrames[$0.id]?.midY ?? .infinity) < centre }.count
            drag.validDrop = true
        }
        questionDrag = drag
    }

    // The questions as they would read if the drag ended now; the dragged row holds the gap open.
    var questionsWhileDragging: [ResearchNode] {
        var list = questions
        guard let drag = questionDrag, drag.movesWithinAim, let index = list.firstIndex(where: { $0.id == drag.questionID }) else { return list }
        let moving = list.remove(at: index)
        list.insert(moving, at: max(0, min(list.count, drag.insertionIndex)))
        return list
    }

    @discardableResult func finishQuestionDrag() -> Bool {
        guard let drag = questionDrag else { return false }
        questionDrag = nil
        guard drag.validDrop, repository?.url.path == drag.workspacePath,
              workspace.node(drag.targetAimID)?.kind == .aim else { return false }
        // Dropping a row back where it started writes nothing.
        if drag.movesWithinAim && drag.insertionIndex == drag.originalIndex && workspace.node(drag.questionID)?.parentID == drag.sourceAimID { return false }
        let others = siblings(of: drag.questionID, in: drag.targetAimID)
        let anchor = others.indices.contains(drag.insertionIndex) ? others[drag.insertionIndex].id : nil
        return moveQuestion(drag.questionID, toAim: drag.targetAimID, relativeTo: anchor, expectedAimID: drag.sourceAimID)
    }

    func cancelQuestionDrag() { questionDrag = nil }
}

struct AimDragState: Equatable {
    var aimID: String
    var workspacePath: String
    var startFrames: [String: CGRect]
    var wasCompleted: Bool
    var originalIndex: Int
    var translation: CGSize = .zero
    // Where the aim would land: above or below the Completed divider, and its place in that group.
    var completed: Bool
    var insertionIndex: Int
    var moved: Bool { completed != wasCompleted || insertionIndex != originalIndex }
}

extension AppStore {
    nonisolated static let aimsDividerID = "aims-divider"
    nonisolated static let stepsDividerID = "steps-divider"

    func updateAimDrag(_ id: String, translation: CGSize) {
        guard let node = workspace.node(id), node.kind == .aim, let repository else { return }
        if aimDrag == nil {
            let done = workspace.progress(node) == .done
            let index = (done ? completedAims : activeAims).firstIndex { $0.id == id } ?? 0
            aimDrag = AimDragState(aimID: id, workspacePath: repository.url.path, startFrames: rowFrames, wasCompleted: done, originalIndex: index, completed: done, insertionIndex: index)
        }
        guard var drag = aimDrag, drag.aimID == id, let start = drag.startFrames[id] else { return }
        drag.translation = translation
        let centre = start.midY + translation.height
        // The divider may only appear once the drag begins; until then it would sit below the last active aim and the add row.
        let activeBottom = activeAims.compactMap { drag.startFrames[$0.id]?.maxY }.max()
        let boundary = drag.startFrames[Self.aimsDividerID]?.midY ?? activeBottom.map { $0 + 42 } ?? (completedAims.compactMap { drag.startFrames[$0.id]?.minY }.min() ?? 0) - 14
        drag.completed = centre > boundary
        let others = (drag.completed ? completedAims : activeAims).filter { $0.id != id }
        drag.insertionIndex = others.filter { (drag.startFrames[$0.id]?.midY ?? .infinity) < centre }.count
        aimDrag = drag
    }

    // The two groups as they would read if the drag ended now.
    var aimSectionsWhileDragging: (active: [ResearchNode], completed: [ResearchNode]) {
        var active = activeAims, completed = completedAims
        guard let drag = aimDrag, let node = workspace.node(drag.aimID) else { return (active, completed) }
        active.removeAll { $0.id == drag.aimID }; completed.removeAll { $0.id == drag.aimID }
        if drag.completed { completed.insert(node, at: max(0, min(completed.count, drag.insertionIndex))) }
        else { active.insert(node, at: max(0, min(active.count, drag.insertionIndex))) }
        return (active, completed)
    }

    @discardableResult func finishAimDrag() -> Bool {
        guard let drag = aimDrag else { return false }
        let sections = aimSectionsWhileDragging
        aimDrag = nil
        guard drag.moved, repository?.url.path == drag.workspacePath, workspace.node(drag.aimID)?.kind == .aim else { return false }
        let ids = (sections.active + sections.completed).map(\.id)
        return mutate(action: "move_aim", id: drag.aimID, detail: drag.completed ? "Completed" : "Active") { try $0.arrangeAims(ids, moving: drag.aimID, completed: drag.completed) }
    }

    func cancelAimDrag() { aimDrag = nil }
}

struct StepDragState: Equatable {
    var stepID: String
    var questionID: String
    var workspacePath: String
    var startFrames: [String: CGRect]
    var originalIndex: Int
    var translation: CGSize = .zero
    var insertionIndex: Int
}

extension AppStore {
    func updateStepDrag(_ id: String, translation: CGSize) {
        guard let node = workspace.node(id), node.kind.isStep, let repository else { return }
        if stepDrag == nil {
            let index = workspace.steps(node.parentID).filter { ($0.kind == .conclusion) == (node.kind == .conclusion) }.firstIndex { $0.id == id } ?? 0
            stepDrag = StepDragState(stepID: id, questionID: node.parentID, workspacePath: repository.url.path, startFrames: rowFrames, originalIndex: index, insertionIndex: index)
        }
        guard var drag = stepDrag, drag.stepID == id, let start = drag.startFrames[id] else { return }
        drag.translation = translation
        let centre = start.midY + translation.height
        // A step passes a neighbour once its centre crosses the neighbour's centre; a task's results sit between rows and do not count.
        // Conclusions live below their divider and only reorder among themselves; other steps stay above it.
        let group = workspace.steps(drag.questionID).filter { ($0.kind == .conclusion) == (node.kind == .conclusion) }
        drag.insertionIndex = group.filter { $0.id != id && (drag.startFrames[$0.id]?.midY ?? .infinity) < centre }.count
        stepDrag = drag
    }

    // The steps as they would read if the drag ended now, conclusions last.
    var stepsWhileDragging: [ResearchNode] {
        guard let questionID else { return [] }
        let all = workspace.steps(questionID)
        var main = all.filter { $0.kind != .conclusion }, conclusions = all.filter { $0.kind == .conclusion }
        if let drag = stepDrag, let moving = all.first(where: { $0.id == drag.stepID }) {
            if moving.kind == .conclusion {
                conclusions.removeAll { $0.id == moving.id }
                conclusions.insert(moving, at: max(0, min(conclusions.count, drag.insertionIndex)))
            } else {
                main.removeAll { $0.id == moving.id }
                main.insert(moving, at: max(0, min(main.count, drag.insertionIndex)))
            }
        }
        return main + conclusions
    }

    @discardableResult func finishStepDrag() -> Bool {
        guard let drag = stepDrag else { return false }
        let ordered = stepsWhileDragging.map(\.id)
        stepDrag = nil
        guard drag.insertionIndex != drag.originalIndex, repository?.url.path == drag.workspacePath, workspace.node(drag.stepID)?.parentID == drag.questionID else { return false }
        return mutate(action: "move_step", id: drag.stepID, detail: "Position \(drag.insertionIndex + 1)") { try $0.arrangeSteps(drag.questionID, ordered) }
    }

    func cancelStepDrag() { stepDrag = nil }
}

// Aims, questions, and steps drag the same way; only what a drop means differs.
struct RowDragSource: ViewModifier {
    @EnvironmentObject var store: AppStore
    @GestureState private var dragging = false
    @State private var cancelled = false
    var node: ResearchNode
    private var active: Bool {
        switch node.kind {
        case .aim: return store.aimDrag?.aimID == node.id
        case .question: return store.questionDrag?.questionID == node.id
        default: return store.stepDrag?.stepID == node.id
        }
    }
    private func update(_ value: DragGesture.Value) {
        switch node.kind {
        case .aim: store.updateAimDrag(node.id, translation: value.translation)
        case .question: store.updateQuestionDrag(node.id, location: value.location, translation: value.translation)
        default: store.updateStepDrag(node.id, translation: value.translation)
        }
    }
    private func cancel() {
        switch node.kind {
        case .aim: store.cancelAimDrag()
        case .question: store.cancelQuestionDrag()
        default: store.cancelStepDrag()
        }
    }
    func body(content: Content) -> some View {
        content.highPriorityGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("lists"))
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { value in if !cancelled { update(value) } }
                .onEnded { value in
                    if cancelled { cancelled = false; return }
                    update(value)
                    switch node.kind {
                    case .aim: store.finishAimDrag()
                    case .question: store.finishQuestionDrag()
                    default: store.finishStepDrag()
                    }
                }
        )
        .onChange(of: dragging) { _, isDragging in
            if isDragging { cancelled = false }
            else {
                Task { @MainActor in
                    await Task.yield()
                    if !dragging && active { cancel() }
                }
            }
        }
        .onDisappear { if active { cancel() } }
        .onExitCommand { cancelled = true; cancel() }
    }
}
