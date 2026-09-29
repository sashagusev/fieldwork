import SwiftUI
import AppKit
import ResearchCore

private struct MetricDraft: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct NodeEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var request: EditorRequest
    @State private var recordID = ""
    @State private var title = ""
    @State private var shortSummary = ""
    @State private var detailedSummary = ""
    @State private var resultsPath = ""
    @State private var parentID = ""
    @State private var order = 10
    @State private var status = NodeStatus.recorded
    @State private var metrics: [MetricDraft] = []
    @State private var relatedID = ""
    @State private var relation = "related"
    @State private var error: String?
    private var isNew: Bool { request.node == nil }
    private var kind: NodeKind { request.kind }
    // The parent is normally decided by where the form was opened; only the toolbar's + menu can leave it open.
    private var needsParent: Bool { isNew && kind.parentKind != nil && request.parentID.isEmpty }
    private var parent: ResearchNode? { store.workspace.node(parentID) }
    @FocusState private var focus: Field?
    private enum Field: Hashable { case title, summary, details, path }

    init(request: EditorRequest, workspace: Workspace) {
        self.request = request
        let n = request.node ?? ResearchNode(kind: request.kind, parentID: request.parentID, title: request.title)
        _recordID = State(initialValue: n.id)
        _title = State(initialValue: n.title)
        _shortSummary = State(initialValue: n.shortSummary)
        _detailedSummary = State(initialValue: n.detailedSummary)
        _resultsPath = State(initialValue: n.resultsPath)
        _parentID = State(initialValue: n.parentID)
        _order = State(initialValue: request.node == nil ? request.suggestedOrder(parentID: n.parentID, workspace: workspace) : n.order)
        _status = State(initialValue: n.status)
        _metrics = State(initialValue: workspace.metrics.filter { $0.resultID == n.id }.map { MetricDraft(key: $0.key, value: $0.value) })
    }

    private var sheetHeight: CGFloat { min(kind == .result ? 900 : 800, (NSScreen.main?.visibleFrame.height ?? 820) - 100) }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (kind.parentKind == nil || !parentID.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if needsParent, let parentKind = kind.parentKind {
                        field(parentKind.label) {
                            Picker("Parent", selection: $parentID) {
                                Text("Choose a \(parentKind.label.lowercased())").tag("")
                                ForEach(store.workspace.nodes.filter { $0.kind == parentKind }) { n in Text(n.title).tag(n.id) }
                            }.labelsHidden()
                        }
                    }
                    field("Title") {
                        TextField(titlePrompt, text: $title, axis: .vertical).lineLimit(1...3)
                            .font(.system(size: 15, weight: .medium)).focused($focus, equals: .title).accessibilityLabel("Title")
                            .modifier(FieldBox(focused: focus == .title))
                    }
                    field("Summary") {
                        TextField("One or two sentences", text: $shortSummary, axis: .vertical).lineLimit(2...5)
                            .font(.system(size: 13)).focused($focus, equals: .summary).accessibilityLabel("Short summary")
                            .modifier(FieldBox(focused: focus == .summary))
                    }
                    field("Details", hint: "Markdown is rendered in the detail panel.") {
                        TextEditor(text: $detailedSummary)
                            .font(.system(size: 13)).lineSpacing(3).scrollContentBackground(.hidden)
                            .frame(minHeight: 150).focused($focus, equals: .details).accessibilityLabel("Detailed summary")
                            .modifier(FieldBox(focused: focus == .details, padding: 8))
                    }
                    field("Results path", hint: "A file or folder, relative to the workspace. Leave blank until there is an output.") {
                        HStack(spacing: 10) {
                            TextField("artifacts/…", text: $resultsPath)
                                .font(.system(size: 12, design: .monospaced)).focused($focus, equals: .path).accessibilityLabel("Results path")
                                .modifier(FieldBox(focused: focus == .path))
                            Button("Choose…", action: choosePath).buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                    if kind == .result {
                        field("Review status") {
                            Picker("Review status", selection: $status) {
                                ForEach([NodeStatus.planned, .recorded, .accepted, .rejected], id: \.self) { Text($0.label).tag($0) }
                                if [.running, .complete].contains(status) { Text(status == .complete ? "Done" : "Running").tag(status) }
                            }.labelsHidden().pickerStyle(.segmented)
                        }
                        metricsEditor
                    }
                    if [.question, .answer, .conclusion, .result].contains(kind) {
                        field(kind == .question ? "Inspired by" : "Linked evidence", hint: kind == .question ? "Optional. Records where this question came from." : "Optional. Marks a record this one supports, contradicts, or relates to.") {
                            HStack(spacing: 10) {
                                Picker("Related record", selection: $relatedID) {
                                    Text("None").tag("")
                                    ForEach(store.workspace.nodes.filter { $0.id != recordID && (kind != .question || $0.kind == .question) }) { n in Text(n.title).tag(n.id) }
                                }.labelsHidden()
                                if kind != .question {
                                    Picker("Relationship", selection: $relation) { ForEach(["supports", "contradicts", "related", "supersedes"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 32).padding(.bottom, 28).textFieldStyle(.plain)
            }
            Divider()
            footer.padding(.horizontal, 32).padding(.vertical, 18)
        }
        .frame(width: 640, height: sheetHeight).background(Palette.card)
        .onAppear { focus = .title }
        .onChange(of: parentID) { _, _ in if isNew { order = request.suggestedOrder(parentID: parentID, workspace: store.workspace) } }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isNew ? "New \(kind.label.lowercased())" : "Edit \(kind.label.lowercased())").font(.system(size: 22, weight: .medium))
                if let parent { Text("in \(parent.title)").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1) }
                else if !isNew { Text(recordID).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).frame(width: 28, height: 28).background(Palette.quiet, in: Circle()) }
                .buttonStyle(.plain).help("Cancel").keyboardShortcut(.cancelAction)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.failed)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
            } else {
                Text(kind.filename).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.faint)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.controlSize(.large)
            Button(isNew ? "Create \(kind.label)" : "Save", action: save).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!canSave)
        }
    }

    private var titlePrompt: String {
        switch kind {
        case .aim: return "What this line of work is for"
        case .question: return "What do you want to find out?"
        case .task: return "What needs doing"
        case .result: return "What was found"
        case .answer: return "What the evidence says"
        case .conclusion: return "What was decided"
        }
    }

    @ViewBuilder private func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.body)
            content()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
    }

    private var metricsEditor: some View {
        field("Measurements", hint: "Key/value pairs stored in metrics.csv.") {
            ForEach($metrics) { $metric in
                HStack(spacing: 8) {
                    TextField("key", text: $metric.key).accessibilityLabel("Metric key").modifier(FieldBox(focused: false))
                    TextField("value", text: $metric.value).accessibilityLabel("Metric value").modifier(FieldBox(focused: false))
                    Button { metrics.removeAll { $0.id == metric.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Palette.muted) }.buttonStyle(.plain)
                }.font(.system(size: 12, design: .monospaced))
            }
            Button("Add Measurement") { metrics.append(MetricDraft(key: "metric_\(metrics.count + 1)", value: "")) }.buttonStyle(.bordered)
        }
    }

    private func choosePath() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = false; p.title = "Choose results file or folder"
        if p.runModal() == .OK, let url = p.url {
            let base = store.repository?.url.path ?? ""
            resultsPath = !base.isEmpty && url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.path
        }
    }

    private func save() {
        do {
            var n = request.node ?? ResearchNode(id: recordID, kind: kind, parentID: parentID, order: order, title: title)
            n.title = title.trimmingCharacters(in: .whitespacesAndNewlines); n.shortSummary = shortSummary; n.detailedSummary = detailedSummary; n.resultsPath = resultsPath
            if kind == .result { n.status = status }
            try store.saveRecord(n, replacing: request.node) { s in
                if kind == .result { s.metrics.removeAll { $0.resultID == recordID }; s.metrics += metrics.map { ResultMetric(resultID: recordID, key: $0.key, value: $0.value) } }
                if !relatedID.isEmpty {
                    let link = ResearchLink(sourceID: recordID, targetID: relatedID, relation: kind == .question ? "inspired_by" : relation)
                    if !s.links.contains(where: { $0.sourceID == link.sourceID && $0.targetID == link.targetID && $0.relation == link.relation }) { s.links.append(link) }
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// A quiet filled box around a plain text field, with an ink outline while it has focus.
private struct FieldBox: ViewModifier {
    var focused: Bool
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.ink : Palette.line, lineWidth: focused ? 1.2 : 1) }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
