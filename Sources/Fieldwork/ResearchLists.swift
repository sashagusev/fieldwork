import SwiftUI
import ResearchCore

// Aims, then the chosen aim's questions, then the chosen question's workflow: three plain checklists.
// Two columns fit the panel; opening a question slides the view over to show its steps.
struct ResearchLists: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    private var animation: Animation? { store.motion && !reduceMotion ? .easeInOut(duration: 0.22) : nil }
    private var aim: ResearchNode? { store.expandedAimID.flatMap(store.workspace.node) }
    private var question: ResearchNode? { aim == nil ? nil : store.questionID.flatMap(store.workspace.node) }

    var body: some View {
        GeometryReader { geometry in
            // Side margins and the column gap match, so a slid-away column ends exactly at the panel edge.
            let columnWidth = max(160, (geometry.size.width - Self.margin * 3) / 2)
            // A plain offset rather than a scroll view: it cannot miss a column that is still being laid out.
            columns(width: columnWidth)
                .offset(x: question == nil ? 0 : -(columnWidth + Self.margin))
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
        .overlay(alignment: .topLeading) { dragPreview }
        .coordinateSpace(name: "lists")
        .onPreferenceChange(RowFramesKey.self) { store.rowFrames = $0 }
        .animation(animation, value: store.expandedAimID)
        .animation(animation, value: store.questionID)
        .animation(store.motion && !reduceMotion ? .easeInOut(duration: 0.16) : nil, value: store.questionsWhileDragging.map(\.id))
        .animation(store.motion && !reduceMotion ? .easeInOut(duration: 0.16) : nil, value: store.stepsWhileDragging.map(\.id))
        .animation(store.motion && !reduceMotion ? .easeInOut(duration: 0.16) : nil, value: store.aimSectionsWhileDragging.active.map(\.id) + ["|"] + store.aimSectionsWhileDragging.completed.map(\.id))
    }

    private static let margin: CGFloat = 24

    private enum AimItem: Identifiable {
        case aim(ResearchNode), add, divider
        var id: String { switch self { case .aim(let aim): return aim.id; case .add: return "aims-add"; case .divider: return AppStore.aimsDividerID } }
    }
    private var aimItems: [AimItem] {
        let sections = store.aimSectionsWhileDragging
        let divider: [AimItem] = !sections.completed.isEmpty || store.aimDrag != nil ? [.divider] : []
        return sections.active.map(AimItem.aim) + [.add] + divider + sections.completed.map(AimItem.aim)
    }

    private func aimRow(_ aim: ResearchNode) -> some View {
        ListRow(node: aim) { store.toggle(aim) }
            .overlay { if store.questionDrag?.validDrop == true && store.questionDrag?.targetAimID == aim.id && store.questionDrag?.sourceAimID != aim.id { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink, lineWidth: 1).allowsHitTesting(false) } }
            .opacity(store.aimDrag?.aimID == aim.id ? 0 : 1)
            .modifier(RowDragSource(node: aim))
            .id(aim.id)
    }

    private func stepRows(_ step: ResearchNode) -> some View {
        Group {
            ListRow(node: step, caption: step.kind == .task ? nil : step.kind.label) { store.toggle(step) }
                .opacity(store.stepDrag?.stepID == step.id ? 0 : 1)
                .modifier(RowDragSource(node: step))
                .id(step.id)
            // Results travel with their task; the whole group slides when steps reorder.
            ForEach(store.workspace.children(step.id).filter { $0.kind == .result }) { result in
                ListRow(node: result) { store.toggle(result) }.id(result.id)
                    .opacity(store.stepDrag?.stepID == step.id ? 0 : 1)
            }
        }
    }

    private func columns(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.margin) {
            ListColumn(title: "Aims", inset: 0) {
                // One loop for the whole column: a dragged aim must stay the same view as it crosses the divider, or its drag is cancelled.
                ForEach(aimItems) { item in
                    switch item {
                    case .aim(let aim): aimRow(aim)
                    case .add: AddRow(label: "New aim", hasGutter: false) { store.newNode(.aim) }
                    // Drag an aim below the divider to complete it, or back above to reopen it.
                    case .divider: SectionDivider(label: "Completed", frameID: AppStore.aimsDividerID).transition(.opacity)
                    }
                }
            }.frame(width: width).padding(.leading, Self.margin)
            Group {
                if let aim {
                    ListColumn(title: "Questions", onBack: question == nil ? nil : { store.questionID = nil }) {
                        NewQuestionField(aimID: aim.id)
                        ForEach(store.questionsWhileDragging) { question in
                            ListRow(node: question) { store.toggle(question) }
                                .opacity(store.questionDrag?.questionID == question.id ? 0 : 1)
                                .modifier(RowDragSource(node: question))
                                .id(question.id)
                        }
                    }.id(aim.id).transition(.opacity) // No offset: rows report their frames, and a moving transition leaves them stale.
                } else { Color.clear }
            }.frame(width: width).frame(maxHeight: .infinity).padding(.trailing, question == nil ? Self.margin : 0)
            if let question {
                    ListColumn(title: "Steps") {
                        let steps = store.stepsWhileDragging
                        ForEach(steps.filter { $0.kind != .conclusion }) { stepRows($0) }
                        AddRow(label: "New task") { store.newNode(.task, parentID: question.id, append: true) }
                        // Conclusions close the question, so they keep to their own section at the bottom.
                        SectionDivider(label: "Conclusions", frameID: AppStore.stepsDividerID)
                        ForEach(steps.filter { $0.kind == .conclusion }) { stepRows($0) }
                        AddRow(label: "New conclusion") { store.newNode(.conclusion, parentID: question.id, append: true) }
                    }.id(question.id).frame(width: width).padding(.trailing, Self.margin).transition(.opacity)
            }
        }
    }

    // The row follows the pointer above every column while its neighbours slide apart to show where it will land.
    @ViewBuilder private var dragPreview: some View {
        if let drag = store.aimDrag, let node = store.workspace.node(drag.aimID), let frame = drag.startFrames[drag.aimID] {
            ListRow(node: node, reportsFrame: false) {}
                .frame(width: frame.width)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: Palette.ink.opacity(0.12), radius: 10, y: 3)
                .offset(x: frame.minX, y: frame.minY + drag.translation.height)
                .allowsHitTesting(false)
        }
        if let drag = store.stepDrag, let node = store.workspace.node(drag.stepID), let frame = drag.startFrames[drag.stepID] {
            ListRow(node: node, caption: node.kind == .task ? nil : node.kind.label, reportsFrame: false) {}
                .frame(width: frame.width)
                .background { RoundedRectangle(cornerRadius: 6).fill(Palette.card).padding(.leading, RowMetrics.thumbSlot) }
                .shadow(color: Palette.ink.opacity(0.12), radius: 10, y: 3)
                .offset(x: frame.minX, y: frame.minY + drag.translation.height)
                .allowsHitTesting(false)
        }
        if let drag = store.questionDrag, let node = store.workspace.node(drag.questionID), let frame = drag.startFrames[drag.questionID] {
            ListRow(node: node, reportsFrame: false) {}
                .frame(width: frame.width)
                .background { RoundedRectangle(cornerRadius: 6).fill(Palette.card).padding(.leading, RowMetrics.thumbSlot) }
                .shadow(color: Palette.ink.opacity(0.12), radius: 10, y: 3)
                .offset(x: frame.minX + drag.translation.width, y: frame.minY + drag.translation.height)
                .allowsHitTesting(false)
        }
    }
}

struct ListColumn<Content: View>: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var title: String
    var inset = RowMetrics.thumbSlot // Lines the header up with the row highlights.
    var onBack: (() -> Void)? // Shown once the view has slid past the aims.
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let onBack {
                    Button(action: onBack) { Label("Aims", systemImage: "chevron.left").labelStyle(.titleAndIcon).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        .buttonStyle(.plain).help("Back to aims").transition(.opacity)
                    Text("/").font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
            }.padding(.horizontal, RowMetrics.padding).padding(.leading, inset).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView { VStack(alignment: .leading, spacing: 2) { content }.padding(.bottom, 40) }
                    .scrollIndicators(.never)
                    .task(id: store.graphFocus?.id) {
                        guard let request = store.graphFocus else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(store.motion && !reduceMotion ? .easeInOut(duration: 0.28) : nil) { proxy.scrollTo(request.nodeID, anchor: .center) }
                    }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SectionDivider: View {
    var label: String
    var frameID: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .padding(.horizontal, RowMetrics.padding).frame(height: 28)
        .background { GeometryReader { geometry in Color.clear.preference(key: RowFramesKey.self, value: [frameID: geometry.frame(in: .named("lists"))]) } }
        .accessibilityLabel(label)
    }
}

// Type a title and press Return to add a question at the top of the list; the pencil opens the full editor instead.
struct NewQuestionField: View {
    @EnvironmentObject var store: AppStore
    var aimID: String
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus").font(.system(size: 10, weight: .light)).foregroundStyle(Palette.muted)
                .frame(width: RowMetrics.bullet, height: RowMetrics.bullet)
                .padding(.leading, RowMetrics.thumbSlot + RowMetrics.gutter)
            TextField("New question", text: $title)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.ink)
                .padding(.leading, RowMetrics.gutter).focused($focused)
                .onSubmit {
                    if store.quickAddQuestion(title, to: aimID) { title = "" }
                    focused = true
                }
                .accessibilityLabel("New question title")
            Button { store.newNode(.question, parentID: aimID, title: title.trimmingCharacters(in: .whitespacesAndNewlines)); title = "" } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Add a summary and details before creating").accessibilityLabel("New question with details")
        }
        .padding(.trailing, RowMetrics.padding).padding(.vertical, RowMetrics.vertical)
    }
}
