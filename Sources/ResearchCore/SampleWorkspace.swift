import Foundation

public enum SampleWorkspace {
    public static func make() -> Workspace {
        var s = Workspace(name: "Retrieval · Example")
        let now = Date(), base = now.addingTimeInterval(-10_800)
        func at(_ minutes: Double) -> String { timestamp(base.addingTimeInterval(minutes * 60)) }
        func node(_ id: String, _ kind: NodeKind, _ parent: String, _ order: Int, _ title: String, _ summary: String, _ detail: String, _ path: String, _ status: NodeStatus = .planned, _ minute: Double = 0) -> ResearchNode {
            ResearchNode(id: id, kind: kind, parentID: parent, order: order, title: title, shortSummary: summary, detailedSummary: detail, resultsPath: path, status: status, createdAt: at(minute))
        }
        let folder = "artifacts/Q-001/"
        s.nodes = [
            node("AIM-001",.aim,"",0,"Reliable retrieval","Evaluate retrieval reliability.","Explore when retrieval improves the quality of research-agent evidence. Questions can progress independently; tasks within each question form a sequential workflow. This is an illustrative workspace with synthetic results.","artifacts/",.active),
            node("Q-001",.question,"AIM-001",10,"Does reranking help?","Test the value of reranking.","Compare a reranking pipeline against baseline retrieval. The pilot and quality review are complete; replication on independent data comes next, then synthesis. All numbers in this example are synthetic.",folder,.active,5),
            node("T-001",.task,"Q-001",10,"Run pilot evaluation","Pilot evaluation completed.","Compare baseline retrieval and reranking on a fixed pilot set. Keep the metric outputs separate from the later replication. This example task produced a synthetic recall comparison.",folder+"pilot/",.complete,10),
            node("R-001",.result,"T-001",0,"Pilot gain: +7.2 points","Recall increased by 7.2 points.","The synthetic pilot measured a 7.2 percentage-point improvement in recall@10. This exceeds the five-point criterion for considering replication. It does not establish generalization to independent data.",folder+"pilot/metrics.csv",.recorded,60),
            node("T-002",.task,"Q-001",20,"Check result quality","Quality review completed.","Review pilot outputs after the first task finishes. Check for duplicates, missing evidence references, and evaluation inconsistencies. Record the review separately so the synthesis can cite both metrics and quality evidence.",folder+"review/",.complete,65),
            node("R-002",.result,"T-002",0,"Quality checks passed","All specified checks passed.","The synthetic quality review found no blocking issues in the checks performed. Passing these checks supports using the pilot metrics; it does not show that the improvement will reproduce.",folder+"review/checks.csv",.accepted,110),
            node("T-003",.task,"Q-001",40,"Replicate on new data","Replication has not started.","Repeat the comparison on an independent evaluation set. Preserve the method, input versions, and outputs in a new task run. No findings have been recorded for this task.",folder+"replication/"),
            node("ANS-001",.answer,"Q-001",50,"Synthesize the evidence","Synthesis has not started.","Write an answer that weighs the reviewed pilot and any replication evidence. Link supporting and contradicting results. If replication is skipped, retain that limitation.",""),
            node("C-001",.conclusion,"Q-001",60,"Record the conclusion","Conclusion has not been recorded.","Record the current conclusion, its limitations, and any follow-up questions. Supported, unsupported, and inconclusive are all valid outcomes. Missing replication is not a negative result.",""),
            node("Q-002",.question,"AIM-001",20,"Which queries benefit?","Inspect variation across query types.","A separate question inspired by Q-001. Start by classifying query types and designing a stratified evaluation. This workflow can run independently of Q-001.","artifacts/Q-002/",.active,120),
            node("T-004",.task,"Q-002",10,"Design query strata","Define comparable query groups.","Define query categories and minimum sample counts for a stratified comparison. Record the sampling plan as a result before moving on.","artifacts/Q-002/strata/"),
            node("ANS-002",.answer,"Q-002",20,"Describe the evaluation plan","Awaiting query strata.","Synthesize the proposed strata into an evaluation plan and document what evidence would answer the question.","")
        ]
        for (task, start, finish) in [("T-001",10.0,60.0),("T-002",65.0,110.0)] {
            let i = s.nodes.firstIndex { $0.id == task }!
            s.nodes[i].startedAt = at(start); s.nodes[i].finishedAt = at(finish); s.nodes[i].updatedAt = at(finish); s.nodes[i].agentID = "example-agent"
            var run = TaskRun(taskID: task, agentID: "example-agent"); run.id = task == "T-001" ? "RUN-001" : "RUN-002"; run.startedAt = at(start); run.finishedAt = at(finish); run.status = "complete"; run.note = "Synthetic example run"; s.runs.append(run)
        }
        s.nodes[s.nodes.firstIndex { $0.id == "R-001" }!].runID = "RUN-001"
        s.nodes[s.nodes.firstIndex { $0.id == "R-002" }!].runID = "RUN-002"
        s.metrics = [ResultMetric(resultID: "R-001", key: "gain_pp", value: "7.2"), ResultMetric(resultID: "R-001", key: "baseline_recall", value: "0.71"), ResultMetric(resultID: "R-001", key: "reranked_recall", value: "0.782")]
        s.links = [ResearchLink(sourceID: "Q-002", targetID: "Q-001", relation: "inspired_by"), ResearchLink(sourceID: "ANS-001", targetID: "R-001", relation: "supports")]
        s.events = [AuditEvent(actor: "Fieldwork", action: "create_example", nodeID: "AIM-001", detail: "Created a workspace containing synthetic research data.")]
        return s
    }
    static func writeArtifacts(to root: URL) throws {
        let artifacts: [String: [[String]]] = [
            "artifacts/Q-001/pilot/metrics.csv": [["metric","baseline","reranked","gain_pp","data_type"],["recall@10","0.71","0.782","7.2","synthetic example"]],
            "artifacts/Q-001/review/checks.csv": [["check","outcome","data_type"],["duplicate questions","pass","synthetic example"],["missing references","pass","synthetic example"],["evaluation consistency","pass","synthetic example"]]
        ]
        for (path, rows) in artifacts {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CSV.encode(rows).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
