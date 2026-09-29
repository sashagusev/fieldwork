import Foundation
import CoreGraphics
import ResearchCore

struct SpringNode: Equatable {
    var id: String
    var parentID: String?
    var level: Int // 0 aim, 1 question, 2 step
}

// A small force-directed layout: every node repels every other, children are sprung to their parent, whole subgraphs push each other apart, and a weak pull keeps the graph centred on the origin.
// Everything the per-frame loop touches is a plain array indexed like `nodes`; string keys are only used when the graph changes.
final class SpringLayout {
    private(set) var nodes: [SpringNode] = []
    private(set) var points: [CGPoint] = []
    private(set) var parent: [Int] = [] // -1 for aims
    private var velocities: [CGVector] = []
    private var cluster: [Int] = []
    private var clusterSize: [CGFloat] = []
    private var index: [String: Int] = [:]
    private(set) var settled = true
    var pinnedID: String? { didSet { if pinnedID != oldValue { settled = false } } }

    static let restLength: [CGFloat] = [0, 92, 38]
    static let charge: [CGFloat] = [3.6, 1.7, 1]
    static let radius: [CGFloat] = [9, 6, 4]
    // Subgraphs repel each other as discs: the push grows as the gap between their rims closes, and every node in a subgraph receives the same share, so the subgraph moves as one piece. Pushing node against node instead lets a large subgraph crush a small neighbour.
    static let separation: CGFloat = 320

    var positions: [String: CGPoint] { Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), points)) }
    func point(of id: String) -> CGPoint? { index[id].map { points[$0] } }
    func level(of id: String) -> Int? { index[id].map { nodes[$0].level } }

    // Parents come before their children, so a new child can be seeded beside its parent.
    static func nodes(in workspace: Workspace) -> [SpringNode] {
        let aims = workspace.children("").filter { $0.kind == .aim }
        let questions = aims.flatMap { workspace.children($0.id).filter { $0.kind == .question } }
        let steps = questions.flatMap { workspace.steps($0.id) }
        return aims.map { SpringNode(id: $0.id, parentID: nil, level: 0) }
            + questions.map { SpringNode(id: $0.id, parentID: $0.parentID, level: 1) }
            + steps.map { SpringNode(id: $0.id, parentID: $0.parentID, level: 2) }
    }

    // Seeds are derived from IDs rather than random numbers, so the same workspace opens the same way every time.
    private static func angle(_ id: String) -> CGFloat {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return CGFloat(hash % 3600) / 3600 * 2 * .pi
    }

    func sync(_ newNodes: [SpringNode]) {
        guard newNodes != nodes else { return }
        let opening = nodes.isEmpty
        let oldPoints = positions
        let oldVelocities = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), velocities))
        nodes = newNodes
        index = Dictionary(uniqueKeysWithValues: newNodes.enumerated().map { ($0.element.id, $0.offset) })
        parent = newNodes.map { $0.parentID.flatMap { index[$0] } ?? -1 }
        cluster = []
        for (i, _) in newNodes.enumerated() { cluster.append(parent[i] >= 0 ? cluster[parent[i]] : i) }
        clusterSize = [CGFloat](repeating: 0, count: newNodes.count)
        for i in newNodes.indices { clusterSize[cluster[i]] += 1 }
        let aims = newNodes.indices.filter { newNodes[$0].level == 0 }
        points = []; velocities = []
        for (i, node) in newNodes.enumerated() {
            velocities.append(oldVelocities[node.id] ?? .zero)
            if let known = oldPoints[node.id] { points.append(known) }
            else if parent[i] >= 0 {
                let origin = points[parent[i]], reach = Self.restLength[node.level] * 0.6, angle = Self.angle(node.id)
                points.append(CGPoint(x: origin.x + cos(angle) * reach, y: origin.y + sin(angle) * reach))
            } else {
                let angle = 2 * CGFloat.pi * CGFloat(aims.firstIndex(of: i) ?? 0) / CGFloat(max(1, aims.count)) - .pi / 2
                let ring: CGFloat = aims.count > 1 ? 260 : 0
                points.append(CGPoint(x: cos(angle) * ring, y: sin(angle) * ring))
            }
        }
        settled = false
        // Open close to rest, but never hold up the first frame for long; the view carries on from wherever this stops.
        if opening {
            let deadline = Date().addingTimeInterval(0.05)
            var ticks = 0
            while ticks < 240, step(), ticks % 8 != 7 || Date() < deadline { ticks += 1 }
        }
    }

    func move(_ id: String, to point: CGPoint) {
        guard let i = index[id] else { return }
        points[i] = point; velocities[i] = .zero; settled = false
    }

    // Advances one tick. Returns false once everything has come to rest.
    @discardableResult func step() -> Bool {
        guard !settled, !nodes.isEmpty else { settled = true; return false }
        let count = nodes.count
        let charges = nodes.map { Self.charge[$0.level] }
        var forces = [CGVector](repeating: .zero, count: count)
        for i in 0..<count {
            for j in (i + 1)..<max(i + 1, count) {
                var dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                if dx * dx + dy * dy < 0.01 { dx = cos(Self.angle(nodes[i].id)) * 0.5; dy = sin(Self.angle(nodes[j].id)) * 0.5 + 0.1 }
                let squared = max(dx * dx + dy * dy, 36), distance = squared.squareRoot()
                let push = 900 * charges[i] * charges[j] / squared
                forces[i].dx += push * dx / distance; forces[i].dy += push * dy / distance
                forces[j].dx -= push * dx / distance; forces[j].dy -= push * dy / distance
            }
        }
        // Subgraph against subgraph: centre, reach, then one shared push per pair.
        let roots = (0..<count).filter { parent[$0] < 0 }
        if roots.count > 1 {
            var centre = [CGPoint](repeating: .zero, count: count), reach = [CGFloat](repeating: 0, count: count), shove = [CGVector](repeating: .zero, count: count)
            for i in 0..<count { centre[cluster[i]].x += points[i].x / clusterSize[cluster[i]]; centre[cluster[i]].y += points[i].y / clusterSize[cluster[i]] }
            for i in 0..<count { reach[cluster[i]] = max(reach[cluster[i]], hypot(points[i].x - centre[cluster[i]].x, points[i].y - centre[cluster[i]].y)) }
            for (n, a) in roots.enumerated() {
                for b in roots[(n + 1)...] {
                    var dx = centre[a].x - centre[b].x, dy = centre[a].y - centre[b].y
                    if dx * dx + dy * dy < 0.01 { dx = cos(Self.angle(nodes[a].id)); dy = sin(Self.angle(nodes[b].id)) + 0.1 }
                    let distance = (dx * dx + dy * dy).squareRoot(), gap = max(distance - reach[a] - reach[b], 36)
                    let push = Self.separation / (gap * gap)
                    shove[a].dx += push * clusterSize[b] * dx / distance; shove[a].dy += push * clusterSize[b] * dy / distance
                    shove[b].dx -= push * clusterSize[a] * dx / distance; shove[b].dy -= push * clusterSize[a] * dy / distance
                }
            }
            for i in 0..<count { forces[i].dx += shove[cluster[i]].dx; forces[i].dy += shove[cluster[i]].dy }
        }
        for i in 0..<count {
            let j = parent[i]
            if j >= 0 {
                let dx = points[j].x - points[i].x, dy = points[j].y - points[i].y
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let pull = 0.09 * (distance - Self.restLength[nodes[i].level])
                forces[i].dx += pull * dx / distance; forces[i].dy += pull * dy / distance
                forces[j].dx -= pull * dx / distance; forces[j].dy -= pull * dy / distance
            }
            forces[i].dx -= points[i].x * 0.008; forces[i].dy -= points[i].y * 0.008
        }
        let pinned = pinnedID.flatMap { index[$0] } ?? -1
        var fastest: CGFloat = 0
        for i in 0..<count where i != pinned {
            var velocity = velocities[i]
            velocity.dx = (velocity.dx + forces[i].dx) * 0.80; velocity.dy = (velocity.dy + forces[i].dy) * 0.80
            let speed = (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
            if speed > 14 { velocity.dx *= 14 / speed; velocity.dy *= 14 / speed }
            fastest = max(fastest, min(speed, 14))
            points[i].x += velocity.dx; points[i].y += velocity.dy
            velocities[i] = velocity
        }
        settled = fastest < 0.03 && pinned < 0
        return !settled
    }

    var bounds: CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }
    }
}
