import Foundation

public enum NodeKind: String, CaseIterable, Codable, Identifiable {
    case aim, question, task, result, answer, conclusion
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var filename: String { rawValue == "aim" ? "aims.csv" : rawValue == "question" ? "questions.csv" : rawValue == "task" ? "tasks.csv" : rawValue == "result" ? "results.csv" : rawValue == "answer" ? "answers.csv" : "conclusions.csv" }
    public var prefix: String { [.aim:"AIM", .question:"Q", .task:"T", .result:"R", .answer:"ANS", .conclusion:"C"][self]! }
    public var isStep: Bool { [.task, .answer, .conclusion].contains(self) }
    public var parentKind: NodeKind? {
        switch self { case .aim: return nil; case .question: return .aim; case .result: return .task; default: return .question }
    }
}

public enum NodeStatus: String, CaseIterable, Codable {
    case planned, running, complete, skipped, failed, recorded, accepted, rejected, active, hold
    public var label: String { rawValue.capitalized }
    public var terminal: Bool { [.complete, .skipped].contains(self) }
}

public struct ResearchNode: Identifiable, Equatable, Codable {
    public var id: String
    public var kind: NodeKind
    public var parentID: String
    public var order: Int
    public var title: String
    public var shortSummary: String
    public var detailedSummary: String
    public var resultsPath: String
    public var status: NodeStatus
    public var createdAt: String
    public var updatedAt: String
    public var startedAt: String
    public var finishedAt: String
    public var agentID: String
    public var runID: String = ""

    public init(id: String? = nil, kind: NodeKind, parentID: String = "", order: Int = 0, title: String, shortSummary: String = "", detailedSummary: String = "", resultsPath: String = "", status: NodeStatus? = nil, createdAt: String = timestamp()) {
        self.id = id ?? "\(kind.prefix)-\(UUID().uuidString.prefix(8).lowercased())"
        self.kind = kind; self.parentID = parentID; self.order = order; self.title = title
        self.shortSummary = shortSummary; self.detailedSummary = detailedSummary; self.resultsPath = resultsPath
        self.status = status ?? (kind == .aim || kind == .question ? .active : kind == .result ? .recorded : .planned)
        self.createdAt = createdAt; self.updatedAt = createdAt; self.startedAt = ""; self.finishedAt = ""; self.agentID = ""
    }
}

public struct ResearchLink: Identifiable, Equatable, Codable {
    public var id: String
    public var sourceID: String
    public var targetID: String
    public var relation: String
    public init(sourceID: String, targetID: String, relation: String) {
        id = UUID().uuidString; self.sourceID = sourceID; self.targetID = targetID; self.relation = relation
    }
}
// A human or agent judgment of finished work; no rating means neutral.
public enum Rating: String, CaseIterable, Codable { case up, down }
public struct ResultMetric: Identifiable, Equatable, Codable {
    public var id: String { resultID + ":" + key }
    public var resultID: String
    public var key: String
    public var value: String
    public init(resultID: String, key: String, value: String) { self.resultID = resultID; self.key = key; self.value = value }
}
public struct TaskRun: Identifiable, Equatable, Codable {
    public var id: String
    public var taskID: String
    public var agentID: String
    public var startedAt: String
    public var finishedAt: String
    public var status: String
    public var note: String
    public init(taskID: String, agentID: String) {
        id = "RUN-" + UUID().uuidString.prefix(8).lowercased(); self.taskID = taskID; self.agentID = agentID
        startedAt = timestamp(); finishedAt = ""; status = "running"; note = ""
    }
}
public struct AuditEvent: Identifiable, Equatable, Codable {
    public var id: String = UUID().uuidString
    public var time: String = timestamp()
    public var actor: String
    public var action: String
    public var nodeID: String
    public var detail: String
}
public struct Workspace: Equatable {
    public var name: String = "Research workspace"
    public var nodes: [ResearchNode] = []
    public var links: [ResearchLink] = []
    public var metrics: [ResultMetric] = []
    public var runs: [TaskRun] = []
    public var events: [AuditEvent] = []
    public var manualStatusIDs: Set<String> = []
    public var ratings: [String: Rating] = [:]
    public init(name: String = "Research workspace") { self.name = name }
    public func node(_ id: String) -> ResearchNode? { nodes.first { $0.id == id } }
    public func children(_ id: String) -> [ResearchNode] { nodes.filter { $0.parentID == id }.sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) } }
    public func steps(_ questionID: String) -> [ResearchNode] { children(questionID).filter { $0.kind.isStep } }
    public func questionID(for node: ResearchNode) -> String? {
        if node.kind == .question { return node.id }
        if node.kind.isStep { return node.parentID }
        if node.kind == .result { return self.node(node.parentID)?.parentID }
        return nil
    }
    public func aimID(for node: ResearchNode) -> String? {
        if node.kind == .aim { return node.id }
        return questionID(for: node).flatMap { self.node($0)?.parentID }
    }
    public func nextStep(_ questionID: String) -> ResearchNode? { steps(questionID).first { !$0.status.terminal } }
    public func state(_ node: ResearchNode) -> String {
        guard node.kind.isStep, node.status == .planned else { return node.status.label }
        return nextStep(node.parentID)?.id == node.id ? "Ready" : "Blocked"
    }
    public func recordEvent(actor: String, action: String, nodeID: String, detail: String) -> AuditEvent {
        AuditEvent(actor: actor, action: action, nodeID: nodeID, detail: detail)
    }
}

// Building a formatter costs far more than using one, and validation parses every timestamp. ISO8601DateFormatter is safe to share across threads.
private let fractionalTimestamps: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let wholeSecondTimestamps = ISO8601DateFormatter()
public func timestamp(_ date: Date = Date()) -> String { fractionalTimestamps.string(from: date) }
// Validation re-reads the same timestamps on every write, so remember the ones already parsed.
private let timestampLock = NSLock()
private var parsedTimestamps: [String: Date] = [:]
public func parseTimestamp(_ value: String) -> Date? {
    timestampLock.lock(); defer { timestampLock.unlock() }
    if let known = parsedTimestamps[value] { return known }
    guard let date = fractionalTimestamps.date(from: value) ?? wholeSecondTimestamps.date(from: value) else { return nil }
    if parsedTimestamps.count > 100_000 { parsedTimestamps.removeAll(keepingCapacity: true) }
    parsedTimestamps[value] = date
    return date
}
public struct ResearchError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
