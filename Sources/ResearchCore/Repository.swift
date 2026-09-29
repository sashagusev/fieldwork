import Foundation
import Darwin

public final class WorkspaceRepository {
    public let url: URL
    public init(url: URL) { self.url = url.standardizedFileURL }
    static let nodeColumns = ["id","parent_id","order","title","short_summary","detailed_summary","results_path","status","created_at","updated_at","started_at","finished_at","agent_id","run_id"]
    static let eventColumns = ["id","time","actor","action","node_id","detail"]

    // What this repository last read, so a write touches only the files that changed.
    private var readText: [String: String] = [:]
    // events.csv only grows. Remember what has been parsed and where it ended, then read and write just the tail.
    private struct EventLog { var header: [String]; var events: [AuditEvent]; var offset: UInt64; var tail: Data; var modified: Date? }
    private var eventLog: EventLog?
    // The on-disk fingerprint as of this repository's last write, taken while still holding the lock.
    public private(set) var committedFingerprint: String?

    public func create(name: String, sample: Bool = false) throws -> Workspace {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try locked {
            guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("workspace.csv").path) else { throw ResearchError("This folder already contains a Fieldwork workspace.") }
            let existing = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0 != ".fieldwork.lock" && $0 != ".DS_Store" }
            guard existing.isEmpty else { throw ResearchError("Choose an empty folder for a new workspace.") }
            var state = sample ? SampleWorkspace.make() : Workspace(name: name)
            state.name = name
            state = canonicalOrder(state)
            try state.validate()
            try write(state)
            // Every workspace carries the instructions an agent needs to add to it by writing files.
            try AgentGuide.text.write(to: url.appendingPathComponent(AgentGuide.filename), atomically: true, encoding: .utf8)
            if sample { try SampleWorkspace.writeArtifacts(to: url) }
            return state
        }
    }
    public func load() throws -> Workspace { try locked { try recover(); let state = try read(); try state.validate(); return state } }
    @discardableResult public func update(actor: String, action: String, nodeID: String = "", detail: String = "", _ mutation: (inout Workspace) throws -> Void) throws -> Workspace {
        try locked {
            try recover()
            var state = try read(); try state.validate()
            try mutation(&state)
            state = canonicalOrder(state)
            state.events.append(AuditEvent(actor: actor, action: action, nodeID: nodeID, detail: detail))
            try state.validate(); try write(state)
            committedFingerprint = fingerprint()
            return state
        }
    }
    public func deleteQuestion(_ id: String, actor: String) throws -> (workspace: Workspace, backupURL: URL) {
        try deleteHierarchy(id, kind: .question, actor: actor)
    }
    public func deleteAim(_ id: String, actor: String) throws -> (workspace: Workspace, backupURL: URL) {
        try deleteHierarchy(id, kind: .aim, actor: actor)
    }
    public func deleteNode(_ id: String, actor: String) throws -> (workspace: Workspace, backupURL: URL) {
        try deleteHierarchy(id, kind: nil, actor: actor)
    }
    private func deleteHierarchy(_ id: String, kind expectedKind: NodeKind?, actor: String) throws -> (workspace: Workspace, backupURL: URL) {
        try locked {
            try recover()
            let before = try read(); try before.validate()
            guard let record = before.node(id), expectedKind == nil || record.kind == expectedKind else { throw ResearchError("Choose an existing \(expectedKind?.rawValue ?? "card") to delete.") }
            let kind = record.kind
            var after = before
            try after.deleteNode(id)
            try after.validate()
            let backup = url.appendingPathComponent(".fieldwork-trash", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try WorkspaceRepository(url: backup).write(before)
            after.events.append(AuditEvent(actor: actor, action: "delete_" + kind.rawValue, nodeID: id, detail: "\(kind.label) and descendants deleted. CSV backup: \(backup.path)"))
            try write(after)
            committedFingerprint = fingerprint()
            return (after, backup)
        }
    }

    public func restoreQuestion(_ id: String, from backup: URL, actor: String) throws -> Workspace {
        try restoreHierarchy(id, kind: .question, from: backup, actor: actor)
    }
    public func restoreAim(_ id: String, from backup: URL, actor: String) throws -> Workspace {
        try restoreHierarchy(id, kind: .aim, from: backup, actor: actor)
    }
    public func restoreNode(_ id: String, from backup: URL, actor: String) throws -> Workspace {
        try restoreHierarchy(id, kind: nil, from: backup, actor: actor)
    }
    private func restoreHierarchy(_ id: String, kind expectedKind: NodeKind?, from backup: URL, actor: String) throws -> Workspace {
        let original = try WorkspaceRepository(url: backup).load()
        guard let record = original.node(id), expectedKind == nil || record.kind == expectedKind else { throw ResearchError("The backup does not contain this card.") }
        let kind = record.kind
        let restoredIDs = try original.recordIDs(id)
        return try update(actor: actor, action: "restore_" + kind.rawValue, nodeID: id) { state in
            guard !state.nodes.contains(where: { restoredIDs.contains($0.id) }) else { throw ResearchError("A record with one of these IDs already exists. The deletion cannot be undone without overwriting it.") }
            state.manualStatusIDs.formUnion(original.manualStatusIDs.intersection(restoredIDs))
            state.ratings.merge(original.ratings.filter { restoredIDs.contains($0.key) }) { current, _ in current }
            state.nodes += original.nodes.filter { restoredIDs.contains($0.id) }
            state.metrics += original.metrics.filter { restoredIDs.contains($0.resultID) }
            state.runs += original.runs.filter { restoredIDs.contains($0.taskID) }
            state.links += original.links.filter { restoredIDs.contains($0.sourceID) || restoredIDs.contains($0.targetID) }
            if record.kind.isStep { state.refreshQuestion(record.parentID) }
        }
    }

    public func resultsURL(for node: ResearchNode) -> URL? {
        guard !node.resultsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if node.resultsPath.hasPrefix("/") { return URL(fileURLWithPath: node.resultsPath).standardizedFileURL }
        return url.appendingPathComponent(node.resultsPath).standardizedFileURL
    }
    public func fingerprint() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "csv" }.sorted { $0.path < $1.path }.map {
            let v = try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\($0.lastPathComponent):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(v?.fileSize ?? 0)"
        }.joined(separator: "|")
    }
    private func locked<T>(_ block: () throws -> T) throws -> T {
        let path = url.appendingPathComponent(".fieldwork.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ResearchError("Cannot access workspace: \(url.path). \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        // Bound waiting: an agent should not freeze the app indefinitely.
        let deadline = Date().addingTimeInterval(3)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw ResearchError("Workspace is busy. Another writer holds its lock; try again shortly.") }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try block()
    }
    private func table(_ name: String, _ columns: [String]) throws -> [[String: String]] {
        let file = url.appendingPathComponent(name)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw ResearchError("Cannot read \(name). Open a workspace folder containing all its CSV files.") }
        readText[name] = text
        return try CSV.dictionaries(text, columns: columns, filename: name)
    }
    private func read() throws -> Workspace {
        readText = [:] // A file deleted since the last read must not look unchanged.
        let metadata = try table("workspace.csv", ["schema_version","name"])
        guard metadata.count == 1, metadata[0]["schema_version"] == "1" else { throw ResearchError("Unsupported workspace schema. This version of Fieldwork supports schema 1.") }
        var s = Workspace(name: metadata[0]["name"]!)
        for kind in NodeKind.allCases {
            let rows = try table(kind.filename, Self.nodeColumns)
            for r in rows {
                guard let status = NodeStatus(rawValue: r["status"]!), let order = Int(r["order"]!) else { throw ResearchError("Invalid status or order for \(r["id"]!) in \(kind.filename).") }
                var n = ResearchNode(id: r["id"]!, kind: kind, parentID: r["parent_id"]!, order: order, title: r["title"]!, shortSummary: r["short_summary"]!, detailedSummary: r["detailed_summary"]!, resultsPath: r["results_path"]!, status: status, createdAt: r["created_at"]!)
                n.updatedAt = r["updated_at"]!; n.startedAt = r["started_at"]!; n.finishedAt = r["finished_at"]!; n.agentID = r["agent_id"]!
                n.runID = r["run_id"]!
                s.nodes.append(n)
            }
        }
        for r in try table("links.csv", ["id","source_id","target_id","relation"]) {
            var link = ResearchLink(sourceID: r["source_id"]!, targetID: r["target_id"]!, relation: r["relation"]!); link.id = r["id"]!; s.links.append(link)
        }
        for r in try table("metrics.csv", ["result_id","key","value"]) { s.metrics.append(ResultMetric(resultID: r["result_id"]!, key: r["key"]!, value: r["value"]!)) }
        for r in try table("runs.csv", ["id","task_id","agent_id","started_at","finished_at","status","note"]) {
            var run = TaskRun(taskID: r["task_id"]!, agentID: r["agent_id"]!); run.id = r["id"]!; run.startedAt = r["started_at"]!; run.finishedAt = r["finished_at"]!; run.status = r["status"]!; run.note = r["note"]!; s.runs.append(run)
        }
        s.events = try readEvents()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("manual_status.csv").path) {
            let ids = try table("manual_status.csv", ["node_id"]).map { $0["node_id"]! }
            guard Set(ids).count == ids.count else { throw ResearchError("Duplicate manual status IDs.") }
            s.manualStatusIDs = Set(ids)
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("ratings.csv").path) {
            for r in try table("ratings.csv", ["node_id","rating"]) {
                guard let rating = Rating(rawValue: r["rating"]!) else { throw ResearchError("Invalid rating for \(r["node_id"]!). Use up or down; remove the row for neutral.") }
                guard s.ratings.updateValue(rating, forKey: r["node_id"]!) == nil else { throw ResearchError("Duplicate rating IDs in ratings.csv.") }
            }
        }
        return s
    }
    private func canonicalOrder(_ workspace: Workspace) -> Workspace {
        var state = workspace
        let order = Dictionary(uniqueKeysWithValues: NodeKind.allCases.enumerated().map { ($0.element, $0.offset) })
        state.nodes.sort { (order[$0.kind]!, $0.id) < (order[$1.kind]!, $1.id) }
        return state
    }
    private func write(_ s: Workspace) throws {
        var tables: [String: [[String]]] = ["workspace.csv": [["schema_version","name"],["1",s.name]]]
        for kind in NodeKind.allCases {
            var rows = [Self.nodeColumns]
            for n in s.nodes.filter({ $0.kind == kind }).sorted(by: { $0.id < $1.id }) {
                rows.append([n.id,n.parentID,String(n.order),n.title,n.shortSummary,n.detailedSummary,n.resultsPath,n.status.rawValue,n.createdAt,n.updatedAt,n.startedAt,n.finishedAt,n.agentID,n.runID])
            }
            tables[kind.filename] = rows
        }
        tables["manual_status.csv"] = [["node_id"]] + s.manualStatusIDs.sorted().map { [$0] }
        tables["ratings.csv"] = [["node_id","rating"]] + s.ratings.sorted { $0.key < $1.key }.map { [$0.key, $0.value.rawValue] }
        tables["links.csv"] = [["id","source_id","target_id","relation"]] + s.links.map { [$0.id,$0.sourceID,$0.targetID,$0.relation] }
        tables["metrics.csv"] = [["result_id","key","value"]] + s.metrics.map { [$0.resultID,$0.key,$0.value] }
        tables["runs.csv"] = [["id","task_id","agent_id","started_at","finished_at","status","note"]] + s.runs.map { [$0.id,$0.taskID,$0.agentID,$0.startedAt,$0.finishedAt,$0.status,$0.note] }
        let pending = url.appendingPathComponent(".fieldwork-pending", isDirectory: true)
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        var written: [String: String] = [:]
        for (name, rows) in tables {
            let text = CSV.encode(rows)
            written[name] = text
            // A click changes one or two tables; leave the rest, and their modification dates, alone.
            if readText[name] == text { continue }
            try text.write(to: pending.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func encoded(_ events: ArraySlice<AuditEvent>, header: [String]) -> String {
            let fields: [String: (AuditEvent) -> String] = ["id": { $0.id }, "time": { $0.time }, "actor": { $0.actor }, "action": { $0.action }, "node_id": { $0.nodeID }, "detail": { $0.detail }]
            return events.isEmpty ? "" : CSV.encode(events.map { event in header.map { fields[$0]!(event) } })
        }
        var log: EventLog
        if let known = eventLog, s.events.count >= known.events.count, s.events.prefix(known.events.count).last?.id == known.events.last?.id {
            // The log on disk is a prefix of the new one: append the new rows at the offset where it ended.
            let addition = encoded(s.events[known.events.count...], header: known.header)
            if !addition.isEmpty { try Data((String(known.offset) + "\n" + addition).utf8).write(to: pending.appendingPathComponent("events.append"), options: .atomic) }
            log = known; log.events = s.events
        } else {
            let text = CSV.encode([Self.eventColumns]) + encoded(s.events[...], header: Self.eventColumns)
            try text.write(to: pending.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
            log = EventLog(header: Self.eventColumns, events: s.events, offset: 0, tail: Data(), modified: nil)
        }
        try "ready".write(to: pending.appendingPathComponent("COMMIT"), atomically: true, encoding: .utf8)
        try recover()
        readText = written
        let data = (try? Data(contentsOf: url.appendingPathComponent("events.csv"), options: .mappedIfSafe)) ?? Data()
        log.offset = UInt64(data.count); log.tail = data.suffix(64); log.modified = eventLogModified()
        eventLog = log
    }

    private func eventLogModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("events.csv").path))?[.modificationDate] as? Date
    }
    private func readEvents() throws -> [AuditEvent] {
        let file = url.appendingPathComponent("events.csv")
        let modified = eventLogModified()
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw ResearchError("Cannot read events.csv. Open a workspace folder containing all its CSV files.") }
        func events(_ rows: ArraySlice<[String]>, header: [String], firstRow: Int) throws -> [AuditEvent] {
            let column = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
            return try rows.enumerated().map { index, row in
                guard row.count == header.count else { throw ResearchError("events.csv, row \(firstRow + index): expected \(header.count) fields, found \(row.count).") }
                var event = AuditEvent(actor: row[column["actor"]!], action: row[column["action"]!], nodeID: row[column["node_id"]!], detail: row[column["detail"]!])
                event.id = row[column["id"]!]; event.time = row[column["time"]!]
                return event
            }
        }
        // Only rows after the part already parsed, provided that part is still what is on disk.
        // A log of the same length is only trusted if nothing has written to it since; a longer one must still end the old part the same way.
        if var known = eventLog, data.prefix(Int(known.offset)).suffix(64) == known.tail,
           UInt64(data.count) > known.offset || (UInt64(data.count) == known.offset && modified == known.modified) {
            if UInt64(data.count) > known.offset {
                let rows = try CSV.parse(Array(data.suffix(from: data.startIndex + Int(known.offset))))
                known.events += try events(rows[...], header: known.header, firstRow: known.events.count + 2)
                known.offset = UInt64(data.count); known.tail = data.suffix(64); known.modified = modified
                eventLog = data.last == UInt8(ascii: "\n") ? known : nil
            }
            return known.events
        }
        let rows = try CSV.parse(Array(data))
        guard let header = rows.first, Set(header) == Set(Self.eventColumns), header.count == Self.eventColumns.count else {
            throw ResearchError("events.csv has unexpected columns. Expected: \(Self.eventColumns.joined(separator: ", ")).")
        }
        let parsed = try events(rows.dropFirst(), header: header, firstRow: 2)
        // A log that does not end at a row boundary cannot be appended to; it is rewritten whole on the next write.
        eventLog = data.last == UInt8(ascii: "\n") ? EventLog(header: header, events: parsed, offset: UInt64(data.count), tail: data.suffix(64), modified: modified) : nil
        return parsed
    }
    private func recover() throws {
        let fm = FileManager.default, pending = url.appendingPathComponent(".fieldwork-pending", isDirectory: true)
        guard fm.fileExists(atPath: pending.path) else { return }
        if fm.fileExists(atPath: pending.appendingPathComponent("COMMIT").path) {
            for source in try fm.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "csv" }) {
                try Data(contentsOf: source).write(to: url.appendingPathComponent(source.lastPathComponent), options: .atomic)
            }
            // The first line is the log's length before this write. Truncating to it first makes a repeated recovery harmless.
            let addition = pending.appendingPathComponent("events.append")
            if let data = try? Data(contentsOf: addition), let lineEnd = data.firstIndex(of: UInt8(ascii: "\n")),
               let offset = UInt64(String(decoding: data[data.startIndex..<lineEnd], as: UTF8.self)) {
                let handle = try FileHandle(forWritingTo: url.appendingPathComponent("events.csv"))
                defer { try? handle.close() }
                try handle.truncate(atOffset: offset)
                try handle.seekToEnd()
                try handle.write(contentsOf: data[data.index(after: lineEnd)...])
            }
        }
        try fm.removeItem(at: pending)
    }
}
