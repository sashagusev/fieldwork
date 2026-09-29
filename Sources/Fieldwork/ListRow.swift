import SwiftUI
import ResearchCore

enum RowMetrics {
    static let padding: CGFloat = 8
    static let vertical: CGFloat = 4
    // The bullet sits midway between the highlight's left edge and the title.
    static let gutter: CGFloat = 14
    static let bullet: CGFloat = 16
    // Status rows keep a slot outside the highlight's left edge; the rating thumb slides out into it.
    static let thumbSlot: CGFloat = 20
    // Every row is two lines tall with its bullet centred.
    static func ratingCenter(in frame: CGRect, indent: CGFloat = 0) -> CGPoint {
        CGPoint(x: frame.minX + indent + thumbSlot / 2, y: frame.midY)
    }
    static func bulletCenter(in frame: CGRect, indent: CGFloat = 0) -> CGPoint {
        CGPoint(x: frame.minX + indent + thumbSlot + gutter + bullet / 2, y: frame.midY)
    }
}

struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct ListRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var node: ResearchNode
    var indent: CGFloat = 0
    var caption: String?
    var flat = false // Outside the aims column, aims keep the thumb slot and gutter so titles align.
    var reportsFrame = true
    var onTap: () -> Void
    @State private var hover = false

    private var progress: Progress { store.workspace.progress(node) }
    private var selected: Bool { store.selectedID == node.id }
    private var inPath: Bool { store.selectedAncestorIDs.contains(node.id) || store.expandedAimID == node.id || store.questionID == node.id }
    private var small: Bool { node.kind == .result }
    // A rating only shows on finished work: thumbs up washes the row green, thumbs down red.
    private var rating: Rating? { progress == .done ? store.workspace.ratings[node.id] : nil }
    private var revealed: Bool { progress == .done && store.ratingRevealID == node.id }
    // An aim's bullet is a pie of its finished questions.
    private var tally: (done: Int, total: Int) {
        let questions = store.workspace.children(node.id).filter { $0.kind == .question }
        return (questions.filter { store.workspace.progress($0) == .done }.count, questions.count)
    }
    private var slot: CGFloat { node.kind == .aim && !flat ? 0 : RowMetrics.thumbSlot }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if node.kind == .aim {
                ProgressPie(fraction: tally.total > 0 ? Double(tally.done) / Double(tally.total) : 0, color: selected || inPath ? Palette.ink : Palette.muted)
                    .frame(width: RowMetrics.bullet, height: RowMetrics.bullet).padding(.leading, flat ? slot + RowMetrics.gutter : 0)
                    .help(tally.total > 0 ? "\(tally.done) of \(tally.total) questions done" : "No questions yet")
                    .accessibilityLabel("\(tally.done) of \(tally.total) questions done")
            } else {
                HStack(spacing: 0) {
                    ZStack { if revealed { RatingButton(node: node).transition(.move(edge: .trailing).combined(with: .opacity)) } }
                        .frame(width: RowMetrics.thumbSlot, height: RowMetrics.bullet + 8).clipped()
                    StatusBullet(node: node, progress: progress, tint: rating.map { $0 == .up ? Palette.good : Palette.bad })
                        .padding(.leading, RowMetrics.gutter)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { store.ratingRevealID = node.id } else if store.ratingRevealID == node.id { store.ratingRevealID = nil }
                }
                .animation(store.motion && !reduceMotion ? .easeOut(duration: 0.16) : nil, value: revealed)
            }
            // An invisible two-line block fixes the height; the title sits centred in it and truncates past two lines.
            Text(" ").lineLimit(2, reservesSpace: true).hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Text(node.title).foregroundStyle(titleColor).lineLimit(2).truncationMode(.tail).help(node.title)
                }
                .font(.system(size: small ? 11 : 12, weight: progress == .working ? .medium : .regular))
                .padding(.leading, node.kind == .aim && !flat ? RowMetrics.padding : RowMetrics.gutter).padding(.trailing, 8)
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .padding(.leading, indent + (node.kind == .aim && !flat ? RowMetrics.padding : 0))
        .padding(.trailing, RowMetrics.padding).padding(.vertical, RowMetrics.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 6).fill(rowFill).padding(.leading, slot) }
        .background {
            if reportsFrame { GeometryReader { geometry in Color.clear.preference(key: RowFramesKey.self, value: [node.id: geometry.frame(in: .named("lists"))]) } }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { RowMenu(node: node) }
        .animation(store.motion && !reduceMotion ? .easeInOut(duration: 0.18) : nil, value: progress)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.kind.label) \(node.id), \(node.title), \(progress.rawValue)")
        .accessibilityAction(.default, onTap)
    }

    private var rowFill: Color {
        if let rating { return rating == .up ? Palette.goodWash : Palette.badWash }
        return selected ? Palette.quiet : hover || inPath ? Palette.canvas : .clear
    }

    private var titleColor: Color {
        if let rating { return (rating == .up ? Palette.good : Palette.bad).opacity(selected ? 0.95 : 0.7) }
        switch progress {
        case .working: return Palette.ink
        case .done, .skipped: return Palette.muted
        default: return node.kind == .aim && (selected || inPath) ? Palette.ink : Palette.body
        }
    }
}

// A ring that fills clockwise from the top as work finishes.
struct ProgressPie: View {
    var fraction: Double
    var color: Color
    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1)
            // A finished aim fills solid, so it cannot be mistaken for the ringed "working" bullet.
            PieSlice(fraction: fraction).fill(color).padding(fraction >= 1 ? 0 : 2.5)
        }.frame(width: 13, height: 13)
    }
}

struct PieSlice: Shape {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: centre)
        path.addArc(center: centre, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * max(0, min(1, fraction))), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct StatusBullet: View {
    @EnvironmentObject var store: AppStore
    var node: ResearchNode
    var progress: Progress
    var tint: Color?
    var body: some View {
        Button { store.cycleStatus(node) } label: {
            Image(systemName: progress.symbol)
                .font(.system(size: node.kind == .result ? 11 : 13, weight: .light))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: RowMetrics.bullet, height: RowMetrics.bullet).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("\(progress.rawValue) · click to mark \(next)")
            .accessibilityLabel("\(progress.rawValue). Mark \(node.title) \(next)")
    }
    private var next: String { progress == .working ? "done" : progress == .done ? "staged" : "working" }
    private var color: Color {
        if let tint { return tint }
        switch progress {
        case .working: return Palette.ink
        case .failed: return Palette.failed
        case .held: return Palette.held
        default: return Palette.muted
        }
    }
}

struct RatingButton: View {
    @EnvironmentObject var store: AppStore
    var node: ResearchNode
    private var rating: Rating? { store.workspace.ratings[node.id] }
    var body: some View {
        Button { store.cycleRating(node) } label: {
            Image(systemName: rating == .down ? "hand.thumbsdown.fill" : rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                .font(.system(size: 11))
                .foregroundStyle(rating == .up ? Palette.good : rating == .down ? Palette.bad : Palette.muted)
                .frame(width: RowMetrics.thumbSlot, height: RowMetrics.bullet + 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(rating == .up ? "Thumbs up · click for thumbs down" : rating == .down ? "Thumbs down · click for neutral" : "Neutral · click for thumbs up")
            .accessibilityLabel("Rating: \(rating?.rawValue ?? "neutral"). Change rating of \(node.title)")
    }
}

struct AddRow: View {
    var label: String
    var hasGutter = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "plus").font(.system(size: 10, weight: .light))
                    .frame(width: RowMetrics.bullet, height: RowMetrics.bullet)
                    .padding(.leading, hasGutter ? RowMetrics.thumbSlot + RowMetrics.gutter : 0)
                Text(label).font(.system(size: 12)).padding(.leading, hasGutter ? RowMetrics.gutter : RowMetrics.padding)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.muted)
            .padding(.leading, hasGutter ? 0 : RowMetrics.padding).padding(.trailing, RowMetrics.padding).padding(.vertical, RowMetrics.vertical)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RowMenu: View {
    @EnvironmentObject var store: AppStore
    var node: ResearchNode
    private var isNext: Bool { store.workspace.nextStep(node.parentID)?.id == node.id }
    var body: some View {
        Button("Mark Staged") { store.setStatus(node, to: .planned) }
        Button("Mark Working") { store.setStatus(node, to: .running) }
        Button("Mark Done") { store.setStatus(node, to: .complete) }
        Divider()
        Button("Edit Record…") { store.select(node); store.editSelected() }
        if store.view != .aims { Button("Show in Aims") { store.reveal(node) } }
        if node.kind == .aim { Button("New Question…") { store.newNode(.question, parentID: node.id) } }
        if node.kind == .task && isNext {
            if [.planned, .failed].contains(node.status) { Button(node.status == .failed ? "Retry Task" : "Start Task") { store.mutate(action: "start_task", id: node.id) { try $0.startTask(node.id, agent: "human") } } }
            if node.status == .running { Button("Mark Failed…") { store.action = ActionRequest(nodeID: node.id, isFailure: true) } }
        }
        if [.answer, .conclusion].contains(node.kind) && !node.status.terminal { Button("Mark Complete") { store.mutate(action: "complete_" + node.kind.rawValue, id: node.id) { try $0.completeSynthesis(node.id) } }.disabled(!isNext) }
        if node.kind == .task && !node.status.terminal { Button("Mark Complete…") { store.requestCompletion(node) }.disabled(!isNext) }
        if node.kind == .task { Button("Add Result…") { store.newNode(.result, parentID: node.id) } }
        if !node.resultsPath.isEmpty { Button("Reveal Results") { store.revealResults(node) }; Button("Copy Results Path") { store.copyPath(node) } }
        Button("Delete \(node.kind.label)", role: .destructive) { store.deleteCard(node) }
    }
}
