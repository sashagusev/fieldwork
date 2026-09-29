import Foundation

extension Workspace {
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ResearchError(message) } }
        // Shadows the linear-scan lookup for the length of this check, which otherwise grows with the square of the workspace.
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func node(_ id: String) -> ResearchNode? { byID[id] }
        try require(Set(nodes.map(\.id)).count == nodes.count, "Node IDs must be unique across all CSVs.")
        try require(Set(ratings.keys).isSubset(of: Set(nodes.map(\.id))), "Ratings must reference existing nodes.")
        // A manual entry may name any record; it only changes how the three checklist statuses are checked.
        let unknownManual = manualStatusIDs.filter { node($0) == nil }.sorted()
        try require(unknownManual.isEmpty, "manual_status.csv names records that do not exist: \(unknownManual.prefix(5).joined(separator: ", "))\(unknownManual.count > 5 ? ", …" : "").")
        for n in nodes {
            try require(!n.id.isEmpty && !n.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Every node needs an ID and title.")
            if let kind = n.kind.parentKind { try require(node(n.parentID)?.kind == kind, "\(n.id) must have a valid \(kind.label.lowercased()) parent.") }
            else { try require(n.parentID.isEmpty, "An aim cannot have a parent.") }
            for date in [n.createdAt, n.updatedAt] { try require(parseTimestamp(date) != nil, "Invalid timestamp on \(n.id). Use ISO 8601, e.g. 2026-09-13T12:00:00Z.") }
            for date in [n.startedAt, n.finishedAt] where !date.isEmpty { try require(parseTimestamp(date) != nil, "Invalid execution timestamp on \(n.id).") }
            let allowed: [NodeStatus]
            switch n.kind {
            case .aim, .question: allowed = [.active,.complete,.hold]
            case .task: allowed = [.planned,.running,.complete,.skipped,.failed]
            case .result: allowed = [.planned,.recorded,.accepted,.rejected,.skipped]
            case .answer, .conclusion: allowed = [.planned,.complete,.skipped]
            }
            // Bullet clicks put planned, running, or complete on any kind; every other status must suit the kind.
            let checklist: [NodeStatus] = [.planned, .running, .complete]
            try require(allowed.contains(n.status) || (manualStatusIDs.contains(n.id) && checklist.contains(n.status)), "Status \(n.status.rawValue) is not valid for \(n.kind.rawValue) \(n.id).")
            // A result entered by hand (manual) may record an outcome without an attempt behind it.
            if n.kind == .result, [.recorded,.accepted,.rejected].contains(n.status), !manualStatusIDs.contains(n.id) {
                try require(runs.contains { $0.id == n.runID && $0.taskID == n.parentID }, "Result \(n.id) needs a valid source run for its parent task, or a manual_status.csv row.")
            }
        }
        for q in nodes.filter({ $0.kind == .question }) {
            let ordered = steps(q.id)
            try require(Set(ordered.map(\.order)).count == ordered.count, "Workflow positions must be unique within \(q.id).")
            let active = ordered.filter { $0.status == .running && !manualStatusIDs.contains($0.id) }
            try require(active.count <= 1, "\(q.id) has multiple running tasks. Parallel work must use separate questions.")
            if let running = active.first { try require(ordered.first(where: { !$0.status.terminal && !manualStatusIDs.contains($0.id) })?.id == running.id, "\(running.id) cannot run before its predecessors finish.") }
            var unfinished = false
            for step in ordered where !manualStatusIDs.contains(step.id) {
                if !step.status.terminal { unfinished = true }
                if step.status == .complete { try require(!unfinished, "\(step.id) is complete before an earlier step. Preserve the sequential workflow.") }
            }
            if q.status == .complete && !manualStatusIDs.contains(q.id) { try require(ordered.contains { $0.kind == .answer && $0.status == .complete } && ordered.allSatisfy { $0.status.terminal }, "\(q.id) needs a completed answer and finished workflow before it can be complete.") }
            let taskIDs = Set(ordered.filter { $0.kind == .task }.map(\.id))
            let attempts = runs.filter { taskIDs.contains($0.taskID) && !manualStatusIDs.contains($0.taskID) }.sorted { (parseTimestamp($0.startedAt) ?? .distantPast) < (parseTimestamp($1.startedAt) ?? .distantPast) }
            for pair in zip(attempts, attempts.dropFirst()) {
                if let firstEnd = parseTimestamp(pair.0.finishedAt), let secondStart = parseTimestamp(pair.1.startedAt) {
                    try require(secondStart >= firstEnd, "Question \(q.id) has overlapping attempts \(pair.0.id) and \(pair.1.id). Tasks in a question must be sequential.")
                } else { throw ResearchError("Question \(q.id) has an unfinished attempt before a later attempt.") }
            }
        }
        try require(Set(metrics.map(\.id)).count == metrics.count, "Duplicate result metric keys.")
        for m in metrics { try require(node(m.resultID)?.kind == .result && !m.key.isEmpty && m.key != "status", "Invalid metric \(m.id). 'status' is reserved for the result's review status.") }
        try require(Set(links.map(\.id)).count == links.count, "Duplicate link IDs.")
        for l in links {
            try require(node(l.sourceID) != nil && node(l.targetID) != nil && l.sourceID != l.targetID, "Link \(l.id) has a missing or self-referencing endpoint.")
            try require(["inspired_by","supports","contradicts","related","supersedes"].contains(l.relation), "Unknown relation: \(l.relation).")
            if l.relation == "inspired_by" { try require(node(l.sourceID)?.kind == .question && node(l.targetID)?.kind == .question, "Inspired-by links must connect questions.") }
        }
        try require(Set(runs.map(\.id)).count == runs.count, "Duplicate run IDs.")
        for r in runs {
            try require(node(r.taskID)?.kind == .task && ["running","complete","failed"].contains(r.status), "Invalid task run \(r.id).")
            try require(parseTimestamp(r.startedAt) != nil, "Invalid run start timestamp for \(r.id).")
            if r.status == "running" { try require(node(r.taskID)?.status == .running && r.finishedAt.isEmpty, "Running attempt \(r.id) does not match its task.") }
            else { try require(parseTimestamp(r.finishedAt).map { $0 >= parseTimestamp(r.startedAt)! } ?? false, "Invalid run finish timestamp for \(r.id).") }
        }
        for n in nodes.filter({ $0.kind == .task && $0.status == .running && !manualStatusIDs.contains($0.id) }) { try require(runs.filter { $0.taskID == n.id && $0.status == "running" }.count == 1, "Running task \(n.id) must have exactly one active attempt.") }
        for n in nodes.filter({ $0.kind == .task && $0.status == .complete && !manualStatusIDs.contains($0.id) }) {
            guard let run = runs.filter({ $0.taskID == n.id }).sorted(by: { $0.startedAt < $1.startedAt }).last else { throw ResearchError("Completed task \(n.id) has no run record.") }
            try require(run.status == "complete" && children(n.id).contains { $0.runID == run.id && ([.recorded,.accepted,.rejected].contains($0.status) || manualStatusIDs.contains($0.id)) }, "Completed task \(n.id) needs a result from its completed attempt.")
        }
    }

    public mutating func setManualStatus(_ id: String, status: NodeStatus, actor: String) throws {
        guard [.planned, .running, .complete].contains(status) else { throw ResearchError("Choose Planned, Running, or Done.") }
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { throw ResearchError("Record no longer exists.") }
        let previous = nodes[i].status
        let now = timestamp()
        nodes[i].status = status
        nodes[i].updatedAt = now
        nodes[i].finishedAt = status == .complete ? now : ""
        if status == .running && (nodes[i].startedAt.isEmpty || previous != .running) { nodes[i].startedAt = now }
        if status == .planned { nodes[i].startedAt = "" }
        manualStatusIDs.insert(id)
        // Close an existing attempt, but never invent execution or output from a status click.
        if status == .complete || status == .planned {
            for ri in runs.indices where runs[ri].taskID == id && runs[ri].status == "running" {
                runs[ri].status = status == .complete ? "complete" : "failed"; runs[ri].finishedAt = now
                runs[ri].note += (runs[ri].note.isEmpty ? "" : "\n") + "\(status == .complete ? "Marked Done" : "Stopped and reset to Planned") by \(actor) using a manual status override."
            }
        }
        if nodes[i].kind.isStep { refreshQuestion(nodes[i].parentID) }
        events.append(AuditEvent(actor: actor, action: "manual_status_override", nodeID: id, detail: "\(previous.rawValue) → \(status.rawValue). User override of workflow requirements."))
    }

    public mutating func setRating(_ id: String, to rating: Rating?) throws {
        guard node(id) != nil else { throw ResearchError("Record no longer exists.") }
        ratings[id] = rating
    }

    public func questionRecordIDs(_ id: String) throws -> Set<String> {
        guard node(id)?.kind == .question else { throw ResearchError("Choose an existing question to delete.") }
        return Set(nodes.filter { $0.id == id || questionID(for: $0) == id }.map(\.id))
    }

    public func aimRecordIDs(_ id: String) throws -> Set<String> {
        guard node(id)?.kind == .aim else { throw ResearchError("Choose an existing aim to delete.") }
        return Set(nodes.filter { $0.id == id || aimID(for: $0) == id }.map(\.id))
    }

    public func recordIDs(_ id: String) throws -> Set<String> {
        guard node(id) != nil else { throw ResearchError("Choose an existing card to delete.") }
        var ids: Set<String> = [id]
        var previousCount = 0
        while previousCount != ids.count {
            previousCount = ids.count
            ids.formUnion(nodes.filter { ids.contains($0.parentID) }.map(\.id))
        }
        return ids
    }

    public mutating func deleteQuestion(_ id: String) throws {
        _ = try questionRecordIDs(id)
        try deleteNode(id)
    }

    public mutating func deleteAim(_ id: String) throws {
        _ = try aimRecordIDs(id)
        try deleteNode(id)
    }

    public mutating func deleteNode(_ id: String) throws {
        guard let record = node(id) else { throw ResearchError("This card no longer exists.") }
        let removed = try recordIDs(id)
        if record.kind == .result, let task = node(record.parentID), task.status == .complete, !manualStatusIDs.contains(task.id),
           let run = runs.filter({ $0.taskID == task.id }).sorted(by: { $0.startedAt < $1.startedAt }).last,
           !children(task.id).contains(where: { !removed.contains($0.id) && $0.runID == run.id && ([.recorded, .accepted, .rejected].contains($0.status) || manualStatusIDs.contains($0.id)) }) {
            throw ResearchError("This is the last result supporting completed task \(task.id). Mark that task Running before deleting its result, or delete the task and its results together.")
        }
        try deleteRecords(removed, label: record.kind.rawValue)
        if record.kind.isStep { refreshQuestion(record.parentID) }
    }

    private mutating func deleteRecords(_ removed: Set<String>, label: String) throws {
        manualStatusIDs.subtract(removed)
        ratings = ratings.filter { !removed.contains($0.key) }
        nodes.removeAll { removed.contains($0.id) }
        metrics.removeAll { removed.contains($0.resultID) }
        runs.removeAll { removed.contains($0.taskID) }
        links.removeAll { removed.contains($0.sourceID) || removed.contains($0.targetID) }
        // Audit history and result files remain available after deletion.
    }

    public mutating func completeTaskManually(_ id: String, actor: String, note: String) throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw ResearchError("Add a completion note describing the outcome.") }
        guard let task = node(id), task.kind == .task, nextStep(task.parentID)?.id == id else { throw ResearchError("Finish the earlier workflow steps before marking this task complete.") }
        if task.status != .running { try startTask(id, agent: actor) }
        guard let run = runs.first(where: { $0.taskID == id && $0.status == "running" }) else { throw ResearchError("No active attempt exists for this task.") }
        if !children(id).contains(where: { $0.runID == run.id && [.recorded,.accepted,.rejected].contains($0.status) }) {
            try add(ResearchNode(kind: .result, parentID: id, title: "Completion note", shortSummary: note, detailedSummary: "User-reported completion by \(actor).\n\n\(note)", resultsPath: task.resultsPath))
        }
        try finishTask(id, note: "User-reported completion by \(actor): \(note)")
    }

    public mutating func add(_ node: ResearchNode) throws {
        guard self.node(node.id) == nil else { throw ResearchError("ID \(node.id) already exists.") }
        if node.kind.isStep, let lastComplete = steps(node.parentID).last(where: { $0.status == .complete || $0.status == .running }) {
            guard node.order > lastComplete.order else { throw ResearchError("New steps must follow work that has already started.") }
        }
        var record = node
        if node.kind == .result, [.recorded,.accepted,.rejected].contains(node.status) {
            guard let run = runs.filter({ $0.taskID == node.parentID }).sorted(by: { $0.startedAt < $1.startedAt }).last else { throw ResearchError("Start the parent task before recording a result. Use Planned for an expected output.") }
            record.runID = run.id
        }
        nodes.append(record)
        if node.kind.isStep { settleConclusions(node.parentID) }
        if node.kind.isStep, let i = nodes.firstIndex(where: { $0.id == node.parentID }), nodes[i].status == .complete && !manualStatusIDs.contains(nodes[i].id) { nodes[i].status = .active; nodes[i].finishedAt = "" }
    }
    // Conclusions always close a question: whatever order is asked for, they come after the other steps.
    private mutating func settleConclusions(_ questionID: String) {
        let ordered = steps(questionID)
        let others = ordered.filter { $0.kind != .conclusion }, conclusions = ordered.filter { $0.kind == .conclusion }
        guard let lastOther = others.map(\.order).max(), let firstConclusion = conclusions.map(\.order).min(), firstConclusion <= lastOther else { return }
        let now = timestamp()
        for (offset, conclusion) in conclusions.enumerated() {
            guard let i = nodes.firstIndex(where: { $0.id == conclusion.id }) else { continue }
            nodes[i].order = lastOther + (offset + 1) * 10; nodes[i].updatedAt = now
        }
    }

    // Steps read in the given order, with conclusions last. A step that ends up out of sequence keeps its state as an explicit override rather than failing the move.
    public mutating func arrangeSteps(_ questionID: String, _ orderedIDs: [String]) throws {
        guard node(questionID)?.kind == .question else { throw ResearchError("Choose an existing question.") }
        let current = steps(questionID).map(\.id)
        guard orderedIDs.count == current.count, Set(orderedIDs) == Set(current) else { throw ResearchError("The steps changed while you were moving one. Try again.") }
        let conclusionIDs = Set(current.filter { node($0)?.kind == .conclusion })
        let settled = orderedIDs.filter { !conclusionIDs.contains($0) } + orderedIDs.filter { conclusionIDs.contains($0) }
        let now = timestamp()
        for (position, id) in settled.enumerated() {
            guard let i = nodes.firstIndex(where: { $0.id == id }) else { continue }
            let order = (position + 1) * 10
            if nodes[i].order != order { nodes[i].order = order; nodes[i].updatedAt = now }
        }
        var unfinished = false
        for step in steps(questionID) where !manualStatusIDs.contains(step.id) {
            if [.complete, .running].contains(step.status) && unfinished { manualStatusIDs.insert(step.id); continue }
            if !step.status.terminal { unfinished = true }
        }
        refreshQuestion(questionID)
    }
    public mutating func moveQuestion(_ id: String, toAim aimID: String, relativeTo anchorID: String? = nil, after: Bool = false, expectedAimID: String? = nil) throws {
        guard let moving = node(id), moving.kind == .question else { throw ResearchError("Choose an existing question to move.") }
        guard node(aimID)?.kind == .aim else { throw ResearchError("The destination aim no longer exists.") }
        if let expectedAimID, moving.parentID != expectedAimID { throw ResearchError("This question moved while you were dragging it. Try again from its current aim.") }
        if let anchorID {
            guard let anchor = node(anchorID), anchor.kind == .question, anchor.parentID == aimID else { throw ResearchError("The destination question changed. Try the move again.") }
            if anchorID == id { return }
        }
        var ordered = children(aimID).filter { $0.kind == .question && $0.id != id }.map(\.id)
        let insertion = anchorID.flatMap { ordered.firstIndex(of: $0) }.map { $0 + (after ? 1 : 0) } ?? ordered.count
        ordered.insert(id, at: insertion)
        let now = timestamp()
        for (position, questionID) in ordered.enumerated() {
            guard let i = nodes.firstIndex(where: { $0.id == questionID }) else { continue }
            let order = (position + 1) * 10
            if nodes[i].order != order || nodes[i].parentID != aimID {
                nodes[i].order = order; nodes[i].parentID = aimID; nodes[i].updatedAt = now
            }
        }
    }

    // Aims read in the given order. Moving one into or out of the completed group also closes or reopens it.
    public mutating func arrangeAims(_ orderedIDs: [String], moving id: String, completed: Bool) throws {
        let aimIDs = nodes.filter { $0.kind == .aim }.map(\.id)
        guard orderedIDs.count == aimIDs.count, Set(orderedIDs) == Set(aimIDs), orderedIDs.contains(id) else { throw ResearchError("The aims changed while you were moving one. Try again.") }
        let now = timestamp()
        for (position, aimID) in orderedIDs.enumerated() {
            guard let i = nodes.firstIndex(where: { $0.id == aimID }) else { continue }
            let order = (position + 1) * 10
            if nodes[i].order != order { nodes[i].order = order; nodes[i].updatedAt = now }
            guard aimID == id, (nodes[i].status == .complete) != completed else { continue }
            nodes[i].status = completed ? .complete : .active
            nodes[i].finishedAt = completed ? now : ""
            nodes[i].updatedAt = now
            manualStatusIDs.remove(aimID)
        }
    }

    public mutating func edit(_ edited: ResearchNode, expectedUpdatedAt: String? = nil) throws {
        guard let i = nodes.firstIndex(where: { $0.id == edited.id }) else { throw ResearchError("Record no longer exists.") }
        if let expectedUpdatedAt, nodes[i].updatedAt != expectedUpdatedAt { throw ResearchError("This record changed while you were editing. Reopen it to avoid overwriting newer work.") }
        guard nodes[i].kind == edited.kind && nodes[i].parentID == edited.parentID && nodes[i].order == edited.order else { throw ResearchError("Record type, parent, and workflow order cannot be changed after creation.") }
        nodes[i].title = edited.title; nodes[i].shortSummary = edited.shortSummary; nodes[i].detailedSummary = edited.detailedSummary; nodes[i].resultsPath = edited.resultsPath
        if edited.kind == .result {
            if nodes[i].status != edited.status { manualStatusIDs.remove(edited.id) }
            nodes[i].status = edited.status
            if nodes[i].runID.isEmpty && [.recorded,.accepted,.rejected].contains(edited.status) {
                guard let run = runs.filter({ $0.taskID == edited.parentID }).sorted(by: { $0.startedAt < $1.startedAt }).last else { throw ResearchError("Start the task before recording its output.") }
                nodes[i].runID = run.id
            }
        }
        // Subsecond uniqueness makes editor conflict checks useful for rapid writes.
        nodes[i].updatedAt = timestamp()
    }
    public mutating func startTask(_ id: String, agent: String) throws {
        guard let i = nodes.firstIndex(where: { $0.id == id && $0.kind == .task }), [.planned,.failed].contains(nodes[i].status) else { throw ResearchError("Only planned or failed tasks can be started.") }
        guard nextStep(nodes[i].parentID)?.id == id else { throw ResearchError("Task \(id) is blocked by an earlier step.") }
        guard !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResearchError("Specify an agent or owner.") }
        manualStatusIDs.remove(id)
        let run = TaskRun(taskID: id, agentID: agent)
        nodes[i].status = .running; nodes[i].agentID = agent; nodes[i].startedAt = run.startedAt; nodes[i].finishedAt = ""; nodes[i].updatedAt = timestamp(); runs.append(run)
    }
    public mutating func finishTask(_ id: String, failed: Bool = false, note: String = "") throws {
        guard let i = nodes.firstIndex(where: { $0.id == id && $0.kind == .task && $0.status == .running }), let ri = runs.firstIndex(where: { $0.taskID == id && $0.status == "running" }) else { throw ResearchError("Task \(id) is not running.") }
        if !failed { guard children(id).contains(where: { $0.kind == .result && $0.runID == runs[ri].id && [.recorded,.accepted,.rejected].contains($0.status) }) else { throw ResearchError("Record at least one result for this attempt before completing the task.") } }
        manualStatusIDs.remove(id)
        nodes[i].status = failed ? .failed : .complete; nodes[i].finishedAt = timestamp(); nodes[i].updatedAt = timestamp()
        runs[ri].status = failed ? "failed" : "complete"; runs[ri].finishedAt = timestamp(); runs[ri].note = note
        refreshQuestion(nodes[i].parentID)
    }
    public mutating func completeSynthesis(_ id: String) throws {
        guard let i = nodes.firstIndex(where: { $0.id == id && [.answer,.conclusion].contains($0.kind) }) else { throw ResearchError("Choose an answer or conclusion.") }
        guard nextStep(nodes[i].parentID)?.id == id else { throw ResearchError("This record is blocked by earlier work.") }
        guard !nodes[i].shortSummary.isEmpty && !nodes[i].detailedSummary.isEmpty else { throw ResearchError("Write both summaries before completing this record.") }
        manualStatusIDs.remove(id)
        nodes[i].status = .complete; nodes[i].finishedAt = timestamp(); nodes[i].updatedAt = timestamp(); refreshQuestion(nodes[i].parentID)
    }
    mutating func refreshQuestion(_ id: String) {
        guard !manualStatusIDs.contains(id), let qi = nodes.firstIndex(where: { $0.id == id }) else { return }
        let steps = steps(id)
        nodes[qi].status = steps.contains { $0.kind == .answer && $0.status == .complete } && steps.allSatisfy { $0.status.terminal } ? .complete : .active
        nodes[qi].updatedAt = timestamp(); nodes[qi].finishedAt = nodes[qi].status == .complete ? timestamp() : ""
    }
    public mutating func setMetric(resultID: String, key: String, value: String) {
        metrics.removeAll { $0.resultID == resultID && $0.key == key }; metrics.append(ResultMetric(resultID: resultID, key: key, value: value))
        if let i = nodes.firstIndex(where: { $0.id == resultID }) { nodes[i].updatedAt = timestamp() }
    }
}
