import SwiftUI
import AppKit
import ResearchCore

struct ResearchInspector: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            if let node = store.selected {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("\(node.kind.label) · \(node.id) · \(store.workspace.progress(node).rawValue)")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Spacer(minLength: 8)
                            Button("Edit") { store.editSelected() }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                .help("Edit all fields for this item (⌘E)")
                                .accessibilityLabel("Edit \(node.kind.label.lowercased())")
                        }
                        Text(node.title).font(.system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    summary("Summary", text: node.shortSummary)
                    summary("Details", text: node.detailedSummary)
                }
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 44).padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Edit Record…") { store.editSelected() } }
            } else {
                Text("Nothing selected").font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 44).padding(.vertical, 36)
            }
        }.background(Palette.card)
    }
    private func summary(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: label)
            MarkdownSummary(source: text.isEmpty ? "Nothing written yet." : text)
        }
    }
}

struct WorkflowActionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var request: ActionRequest
    @State private var rationale = ""
    @State private var saveError: String?
    private var taskCompletion: Bool { request.isCompletion && store.workspace.node(request.nodeID)?.kind == .task }
    private var canSave: Bool {
        !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: taskCompletion ? "Task completion" : "Task attempt")
            Text(taskCompletion ? "Mark task complete" : "Record a failed attempt").font(.system(size: 21, weight: .medium))
            Text(store.workspace.node(request.nodeID)?.title ?? request.nodeID).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(taskCompletion ? "Describe the outcome. Your note is saved with the attempt and becomes a result if no output has been recorded." : "Describe what failed. The task can be retried.").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            TextEditor(text: $rationale).font(.system(size: 12)).frame(height: 120).padding(6).overlay { RoundedRectangle(cornerRadius: 5).stroke(Palette.line) }.accessibilityLabel(taskCompletion ? "Completion note" : "Rationale")
            if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(Palette.failed) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(taskCompletion ? "Mark Complete" : "Save Failure", action: save)
                    .buttonStyle(.borderedProminent).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 500).background(Palette.card)
    }
    private func save() {
        let action = taskCompletion ? "manual_complete_task" : "fail_task"
        let ok = store.mutate(action: action, id: request.nodeID, detail: rationale) { state in
            if taskCompletion { try state.completeTaskManually(request.nodeID, actor: "human", note: rationale) }
            else { try state.finishTask(request.nodeID, failed: true, note: rationale) }
        }
        if ok { store.action = nil; dismiss() }
        else { saveError = store.error; store.error = nil }
    }
}
