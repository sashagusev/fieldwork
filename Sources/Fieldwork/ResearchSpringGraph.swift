import SwiftUI
import ResearchCore

// Aims, their questions, and each question's steps as a spring graph. Thumbs up is green and thumbs down is red; everything else is shades of grey by progress.
struct ResearchSpringGraph: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    // The canvas redraws on its own clock and keeps whatever view state it first captured, so everything it reads lives in one object instead.
    @State private var scene = GraphScene()
    private var layout: SpringLayout { scene.layout }
    private var fit: GraphFit { scene.fit }
    private var look: [String: NodeLook] { scene.look }
    @State private var running = true
    @State private var hoveredID: String?
    @State private var draggedID: String?
    final class GraphScene { let layout = SpringLayout(); let fit = GraphFit(); var look: [String: NodeLook] = [:] }
    // Colours and titles are worked out once per workspace change, not once per frame.
    struct NodeLook { var fill: Color; var stroke: Color; var glow: Color?; var title: String; var dimmed: Bool }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
                Canvas { context, size in
                    _ = timeline.date
                    advance(in: size)
                    draw(&context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoveredID = node(at: location, in: geometry.size)
                case .ended: hoveredID = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if draggedID == nil { draggedID = node(at: value.startLocation, in: geometry.size); layout.pinnedID = draggedID }
                        if let draggedID { layout.move(draggedID, to: fit.model(value.location, in: geometry.size)); running = true }
                    }
                    .onEnded { _ in draggedID = nil; layout.pinnedID = nil; running = true }
            )
            .onTapGesture(count: 2) { location in if let node = node(at: location, in: geometry.size).flatMap(store.workspace.node) { store.reveal(node) } }
            .onTapGesture { location in if let node = node(at: location, in: geometry.size).flatMap(store.workspace.node) { store.select(node) } }
            .overlay(alignment: .topLeading) { label(in: geometry.size) }
            .overlay(alignment: .bottomLeading) { legend }
        }
        .onAppear { refresh(store.workspace) }
        .onChange(of: store.workspace) { _, workspace in refresh(workspace) }
        .onChange(of: store.selectedID) { _, _ in running = true }
        .accessibilityLabel("Graph of aims, questions, and steps")
    }

    private func refresh(_ workspace: Workspace) {
        layout.sync(SpringLayout.nodes(in: workspace))
        let records = Dictionary(workspace.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scene.look = Dictionary(uniqueKeysWithValues: layout.nodes.compactMap { node in
            guard let record = records[node.id] else { return nil }
            let style = Self.style(for: record, in: workspace), progress = workspace.progress(record)
            let glow: Color? = progress == .done ? workspace.ratings[node.id].map { $0 == .up ? Palette.goodGlow : Palette.badGlow } : nil
            return (node.id, NodeLook(fill: style.fill, stroke: style.stroke, glow: glow, title: record.title, dimmed: progress == .done))
        })
        running = true
    }

    // Runs inside the canvas on every frame; the timeline pauses once the springs come to rest.
    private func advance(in size: CGSize) {
        let moving = reduceMotion ? { while layout.step() {}; return false }() : layout.step()
        fit.follow(layout.bounds, in: size, immediately: reduceMotion || fit.scale == 0)
        if !moving && fit.atRest && running { DispatchQueue.main.async { running = false } }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        var edges = Path()
        for (i, parent) in layout.parent.enumerated() where parent >= 0 {
            edges.move(to: fit.view(layout.points[parent], in: size)); edges.addLine(to: fit.view(layout.points[i], in: size))
        }
        context.stroke(edges, with: .color(Palette.faint), lineWidth: 1)
        // Rated nodes glow. One blurred layer per colour keeps this cheap while the springs are moving.
        for glow in [Palette.goodGlow, Palette.badGlow] {
            var halo = Path()
            for (i, node) in layout.nodes.enumerated() where look[node.id]?.glow == glow {
                let radius = nodeRadius(node) + 3, centre = fit.view(layout.points[i], in: size)
                halo.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.fill(halo, with: .color(glow.opacity(0.85)))
            }
        }
        for (i, node) in layout.nodes.enumerated().reversed() {
            guard let look = look[node.id] else { continue }
            let radius = nodeRadius(node) + (hoveredID == node.id ? 1.5 : 0)
            let centre = fit.view(layout.points[i], in: size)
            let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            // The selected record sits on a soft halo; a second outline read as a different kind of node.
            if store.selectedID == node.id {
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius - 7, y: centre.y - radius - 7, width: radius * 2 + 14, height: radius * 2 + 14)), with: .color(Palette.ink.opacity(0.10)))
            }
            context.fill(circle, with: .color(look.fill))
            context.stroke(circle, with: .color(look.stroke), lineWidth: 1.2)
        }
        // Aims are always named, so the picture can be read without hovering. Drawn last, on a wash of white, to stay legible over edges.
        for (i, node) in layout.nodes.enumerated() where node.level == 0 {
            guard let look = look[node.id] else { continue }
            let centre = fit.view(layout.points[i], in: size)
            let text = context.resolve(Text(look.title).font(.system(size: 11, weight: .medium)).foregroundColor(look.dimmed ? Palette.muted : Palette.ink))
            let measured = text.measure(in: CGSize(width: 150, height: 30))
            // Centred under the aim, but never past the panel's edge.
            let x = max(8, min(size.width - measured.width - 8, centre.x - measured.width / 2))
            let frame = CGRect(x: x, y: min(size.height - measured.height - 8, centre.y + nodeRadius(node) + 6), width: measured.width, height: measured.height)
            context.fill(Path(roundedRect: frame.insetBy(dx: -4, dy: -2), cornerRadius: 4), with: .color(Palette.card.opacity(0.85)))
            context.draw(text, in: frame)
        }
    }

    private func nodeRadius(_ node: SpringNode) -> CGFloat { SpringLayout.radius[node.level] * max(0.6, min(1.2, fit.scale)) }

    static func style(for node: ResearchNode, in workspace: Workspace) -> (fill: Color, stroke: Color) {
        let progress = workspace.progress(node)
        if progress == .done, let rating = workspace.ratings[node.id] { return rating == .up ? (Palette.goodGlow, Palette.goodGlow) : (Palette.badGlow, Palette.badGlow) }
        switch progress {
        case .done: return (Palette.faint, Palette.muted)
        case .working: return (Palette.ink, Palette.ink)
        case .failed: return (Palette.card, Palette.failed)
        case .held: return (Palette.card, Palette.held)
        default: return (Palette.card, node.kind == .aim ? Palette.ink : Palette.muted)
        }
    }

    private func node(at location: CGPoint, in size: CGSize) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (i, node) in layout.nodes.enumerated() {
            let centre = fit.view(layout.points[i], in: size)
            let distance = hypot(centre.x - location.x, centre.y - location.y)
            if distance <= nodeRadius(node) + 5, distance < best?.distance ?? .infinity { best = (node.id, distance) }
        }
        return best?.id
    }

    @ViewBuilder private func label(in size: CGSize) -> some View {
        if let id = draggedID ?? hoveredID, let record = store.workspace.node(id), let point = layout.point(of: id), let level = layout.level(of: id) {
            let centre = fit.view(point, in: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                Text("\(record.kind.label) · \(store.workspace.progress(record).rawValue)").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1) }
            .shadow(color: Palette.ink.opacity(0.08), radius: 8, y: 2)
            .fixedSize()
            // Sit beside the node, flipping to whichever side has room.
            .alignmentGuide(.leading) { $0[centre.x > size.width * 0.6 ? .trailing : .leading] + (centre.x > size.width * 0.6 ? 1 : -1) * (SpringLayout.radius[level] + 10) }
            .alignmentGuide(.top) { $0[centre.y > size.height * 0.75 ? .bottom : .top] + (centre.y > size.height * 0.75 ? 8 : -8) }
            .offset(x: centre.x, y: centre.y)
            .allowsHitTesting(false)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([("Thumbs up", Palette.goodGlow, Palette.goodGlow), ("Thumbs down", Palette.badGlow, Palette.badGlow), ("Done", Palette.faint, Palette.muted), ("Working", Palette.ink, Palette.ink), ("Staged", Palette.card, Palette.muted)], id: \.0) { item in
                HStack(spacing: 5) {
                    Circle().fill(item.1).overlay { Circle().strokeBorder(item.2, lineWidth: 1) }.frame(width: 8, height: 8)
                    Text(item.0)
                }
            }
        }
        .font(.system(size: 10)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 24 + RowMetrics.padding).padding(.bottom, 20)
        .accessibilityHidden(true)
    }
}

// Scales and centres the layout inside the view, easing towards the target so the picture does not jump as the springs move.
// A reference type, like the layout: both change while the canvas draws, where view state cannot be written.
final class GraphFit {
    var scale: CGFloat = 0
    var centre: CGPoint = .zero
    private(set) var atRest = false

    func follow(_ bounds: CGRect, in size: CGSize, immediately: Bool) {
        guard !bounds.isNull, size.width > 0, size.height > 0 else { atRest = true; return }
        // Wider at the sides and bottom, where aim labels hang off the outermost nodes.
        let target = min(1.6, min((size.width - 180) / max(bounds.width, 1), (size.height - 150) / max(bounds.height, 1)))
        let targetCentre = CGPoint(x: bounds.midX, y: bounds.midY)
        let ease: CGFloat = immediately ? 1 : 0.12
        scale += (max(0.05, target) - scale) * ease
        centre.x += (targetCentre.x - centre.x) * ease; centre.y += (targetCentre.y - centre.y) * ease
        atRest = abs(target - scale) < 0.002 && hypot(targetCentre.x - centre.x, targetCentre.y - centre.y) < 0.2
    }
    func view(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (point.x - centre.x) * scale, y: size.height / 2 + (point.y - centre.y) * scale)
    }
    func model(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: centre.x + (point.x - size.width / 2) / scale, y: centre.y + (point.y - size.height / 2) / scale)
    }
}
