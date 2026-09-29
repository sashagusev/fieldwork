import Foundation
import ResearchCore

let help = """
Fieldwork — CSV research workspaces for humans and agents

Usage: fieldwork <command> [arguments] --workspace <folder> [options]

  init <folder> [--name NAME] [--sample]
  list [--kind task] [--question Q-ID] [--json]
  show <id>
  ready                         Current runnable step in each question (JSON)
  validate                      Check CSV schemas, references, and workflow rules
  add <kind> --title TEXT [--parent ID] [--order N]
  edit <id> [--title TEXT] [--summary TEXT] [--details TEXT]
  result <task-id> --title TEXT  Record a result while a task is running
  start <task-id> --actor NAME   Atomically claim a task and create a run
  complete <id>                 Complete a running task, answer, or conclusion
  fail <task-id> --reason TEXT  Fail the current attempt; the task can be retried
  move <step-id> --before ID | --after ID | --last
                                Reorder a step within its question
  metric <result-id> <key> <value>
  link <source-id> <target-id> <inspired_by|supports|contradicts|related|supersedes>
  status <id> staged|working|done  Set the checklist state shown in the app
  rate <id> up|down|neutral     Rate finished work
  ratings                       Current ratings (JSON)

Shared write options: --summary TEXT --details TEXT --details-file PATH
                     --results PATH --actor NAME (default: agent)
Result review:       edit R-ID --status recorded|accepted|rejected

Paths in records are relative to the workspace unless absolute. There is one
active task per question. Complete tasks only after recording a result. Steps
run in order; moving a finished step below an unfinished one keeps its state
as an explicit override.
"""

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    init(_ args: [String]) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if ["sample","json","help","last"].contains(key) { flags[key] = "true" }
                else { guard index+1 < args.count else { throw ResearchError("Missing value for \(arg).") }; index += 1; flags[key] = args[index] }
            } else { positional.append(arg) }
            index += 1
        }
    }
    func at(_ index: Int) throws -> String { guard positional.indices.contains(index) else { throw ResearchError("Missing argument. Run fieldwork --help.") }; return positional[index] }
    func require(_ name: String) throws -> String { guard let v = flags[name], !v.isEmpty else { throw ResearchError("Missing --\(name).") }; return v }
    func detail() throws -> String? { if let file = flags["details-file"] { return try String(contentsOfFile: file, encoding: .utf8) }; return flags["details"] }
}
func json<T: Encodable>(_ value: T) throws { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; print(String(data: try e.encode(value), encoding: .utf8)!) }
do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.positional.first, args.flags["help"] == nil else { print(help); exit(0) }
    if command == "help" { print(help); exit(0) }
    if command == "init" {
        let folder = URL(fileURLWithPath: try args.at(1), isDirectory: true)
        let state = try WorkspaceRepository(url: folder).create(name: args.flags["name"] ?? folder.lastPathComponent, sample: args.flags["sample"] != nil)
        print("Created \(state.name) at \(folder.path)"); exit(0)
    }
    let folder = URL(fileURLWithPath: try args.require("workspace"), isDirectory: true)
    let repository = WorkspaceRepository(url: folder), actor = args.flags["actor"] ?? "agent"
    switch command {
    case "validate":
        let state = try repository.load(); print("Valid: \(state.nodes.count) records, \(state.runs.count) runs.")
    case "list":
        let state = try repository.load()
        let records = state.nodes.filter { (args.flags["kind"] == nil || $0.kind.rawValue == args.flags["kind"]) && (args.flags["question"] == nil || state.questionID(for: $0) == args.flags["question"]) }
        if args.flags["json"] != nil { try json(records) }
        else { for n in records { print("\(n.id)\t\(n.kind.rawValue)\t\(state.state(n))\t\(n.title)") } }
    case "show":
        guard let node = try repository.load().node(try args.at(1)) else { throw ResearchError("Record not found.") }; try json(node)
    case "ready":
        let state = try repository.load()
        try json(state.nodes.filter { $0.kind == .question }.compactMap { state.nextStep($0.id) }.filter { $0.status == .planned || $0.status == .failed })
    case "add", "result":
        let state = try repository.load()
        let kind: NodeKind
        if command == "result" { kind = .result }
        else { guard let k = NodeKind(rawValue: try args.at(1)) else { throw ResearchError("Unknown node kind.") }; kind = k }
        let parent = command == "result" ? try args.at(1) : args.flags["parent"] ?? ""
        // New questions lead their aim's list; everything else joins the end.
        let siblings = state.children(parent).map(\.order)
        let order = args.flags["order"].flatMap(Int.init) ?? (kind == .question ? (siblings.min() ?? 10) - 10 : (siblings.max() ?? 0) + 10)
        let n = ResearchNode(kind: kind, parentID: parent, order: order, title: try args.require("title"), shortSummary: args.flags["summary"] ?? "", detailedSummary: try args.detail() ?? "", resultsPath: args.flags["results"] ?? "")
        let saved = try repository.update(actor: actor, action: "create", nodeID: n.id, detail: n.title) { s in try s.add(n) }
        try json(saved.node(n.id)!)
    case "edit":
        let state = try repository.load(), id = try args.at(1)
        guard var n = state.node(id) else { throw ResearchError("Record not found.") }
        let previous = n.updatedAt
        if let title = args.flags["title"] { n.title = title }
        if let summary = args.flags["summary"] { n.shortSummary = summary }
        if let details = try args.detail() { n.detailedSummary = details }
        if let path = args.flags["results"] { n.resultsPath = path }
        if let status = args.flags["status"] {
            guard n.kind == .result, let v = NodeStatus(rawValue: status), [.recorded,.accepted,.rejected].contains(v) else { throw ResearchError("Use workflow commands for status transitions. Only result review status can be edited directly.") }; n.status = v
        }
        try repository.update(actor: actor, action: "edit", nodeID: id, detail: "Updated record content") { try $0.edit(n, expectedUpdatedAt: previous) }
        print("Updated \(id)")
    case "start", "complete", "fail":
        let id = try args.at(1)
        try repository.update(actor: actor, action: command, nodeID: id, detail: args.flags["reason"] ?? "") { s in
            if command == "start" { try s.startTask(id, agent: actor) }
            else if s.node(id)?.kind == .task {
                guard s.node(id)?.agentID == actor else { throw ResearchError("This task belongs to \(s.node(id)?.agentID ?? "another agent"). Use that --actor to finish its run.") }
                try s.finishTask(id, failed: command == "fail", note: args.flags["reason"] ?? "")
            } else if command == "complete" { try s.completeSynthesis(id) }
            else { throw ResearchError("Only task attempts can fail.") }
        }; print("\(command.capitalized): \(id)")
    case "move":
        let id = try args.at(1)
        let placement: String
        if let before = args.flags["before"] { placement = "before " + before } else if let after = args.flags["after"] { placement = "after " + after } else { placement = "last" }
        try repository.update(actor: actor, action: "move_step", nodeID: id, detail: placement) { s in
            guard let step = s.node(id), step.kind.isStep else { throw ResearchError("Choose a task, answer, or conclusion to move.") }
            var ordered = s.steps(step.parentID).map(\.id).filter { $0 != id }
            if let anchor = args.flags["before"] ?? args.flags["after"] {
                guard let at = ordered.firstIndex(of: anchor) else { throw ResearchError("\(anchor) is not another step in the same question.") }
                ordered.insert(id, at: args.flags["before"] != nil ? at : at + 1)
            } else { guard args.flags["last"] != nil else { throw ResearchError("Give --before ID, --after ID, or --last.") }; ordered.append(id) }
            try s.arrangeSteps(step.parentID, ordered)
        }; print("Moved \(id)")
    case "metric":
        let id = try args.at(1), key = try args.at(2), value = try args.at(3)
        try repository.update(actor: actor, action: "set_metric", nodeID: id, detail: "\(key)=\(value)") { $0.setMetric(resultID: id, key: key, value: value) }; print("Metric saved")
    case "link":
        let link = try ResearchLink(sourceID: args.at(1), targetID: args.at(2), relation: args.at(3))
        try repository.update(actor: actor, action: "link", nodeID: link.sourceID, detail: "\(link.relation) \(link.targetID)") { $0.links.append(link) }; print("Link saved")
    case "status":
        let id = try args.at(1)
        let names: [String: NodeStatus] = ["staged": .planned, "planned": .planned, "working": .running, "running": .running, "done": .complete, "complete": .complete]
        guard let status = names[try args.at(2)] else { throw ResearchError("Status must be staged, working, or done.") }
        try repository.update(actor: actor, action: "set_status", nodeID: id, detail: status.rawValue) { try $0.setManualStatus(id, status: status, actor: actor) }; print("Status saved: \(id)")
    case "rate":
        let id = try args.at(1), value = try args.at(2)
        guard value == "neutral" || Rating(rawValue: value) != nil else { throw ResearchError("Rating must be up, down, or neutral.") }
        try repository.update(actor: actor, action: "rate", nodeID: id, detail: value) { try $0.setRating(id, to: Rating(rawValue: value)) }; print("Rating saved: \(id)")
    case "ratings":
        try json(try repository.load().ratings)
    default: throw ResearchError("Unknown command: \(command). Run fieldwork --help.")
    }
} catch {
    FileHandle.standardError.write(Data("fieldwork: \(error.localizedDescription)\n".utf8)); exit(1)
}
