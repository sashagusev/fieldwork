#if FIELDWORK_STANDALONE_CHECKS
import Foundation
#else
import XCTest
#endif
@testable import ResearchCore

final class ResearchCoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fieldwork-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func repository() throws -> WorkspaceRepository {
        let repo = WorkspaceRepository(url: directory.appendingPathComponent("workspace"))
        _ = try repo.create(name: "Test Research",sample: true); return repo
    }
    func testCSVPreservesQuotesCommasUnicodeNewlinesAndEmptyFields() throws {
        let rows = [["id","summary","details","path"],["R-1","Gain, then \"review\"","First line\nSecond line\r\n第三行",""]]
        XCTAssertEqual(try CSV.parse(CSV.encode(rows)),rows)
        XCTAssertEqual(try CSV.parse("\u{FEFF}id,value\r\na,\r\n"),[["id","value"],["a",""]])
        XCTAssertEqual(try CSV.parse("\"\""),[[""]])
        XCTAssertEqual(try CSV.parse("a,b,"),[["a","b",""]])
        XCTAssertEqual(try CSV.parse(""),[])
    }
    func testCSVMalformedQuotesAreRejected() throws {
        XCTAssertThrowsError(try CSV.parse("a,\"unclosed"))
        XCTAssertThrowsError(try CSV.parse("a,\"closed\"junk"))
        XCTAssertThrowsError(try CSV.parse("a,un\"quoted"))
    }
    func testWorkspaceRoundTripAndArtifactReferences() throws {
        let repo = try repository(), s = try repo.load()
        XCTAssertEqual(s.name,"Test Research")
        XCTAssertEqual(s.nodes.count,12)
        XCTAssertEqual(s.node("R-001")?.runID,"RUN-001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.resultsURL(for:s.node("R-001")!)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.resultsURL(for:s.node("T-003")!)!.path))
        XCTAssertEqual(try repo.load(),s)
    }
    func testSequentialTasksAndIndependentQuestions() throws {
        var s = SampleWorkspace.make()
        XCTAssertEqual(s.nextStep("Q-001")?.id,"T-003")
        XCTAssertThrowsError(try s.completeSynthesis("ANS-001"))
        try s.startTask("T-004",agent:"two")
        try s.startTask("T-003",agent:"one")
        XCTAssertEqual(s.nodes.filter { $0.status == .running }.count,2)
        try s.validate()
        XCTAssertThrowsError(try s.startTask("T-003",agent:"other"))
    }
    func testRetryRequiresResultFromTheNewAttempt() throws {
        var s = SampleWorkspace.make()
        try s.startTask("T-004",agent:"agent")
        try s.add(ResearchNode(id:"R-old",kind:.result,parentID:"T-004",title:"Partial output"))
        try s.finishTask("T-004",failed:true,note:"Execution interrupted")
        Thread.sleep(forTimeInterval:0.003)
        try s.startTask("T-004",agent:"agent")
        XCTAssertThrowsError(try s.finishTask("T-004"))
        try s.add(ResearchNode(id:"R-new",kind:.result,parentID:"T-004",title:"Completed strata",shortSummary:"Three query groups."))
        try s.finishTask("T-004")
        XCTAssertNotEqual(s.node("R-old")?.runID,s.node("R-new")?.runID)
        XCTAssertEqual(s.nextStep("Q-002")?.id,"ANS-002")
        try s.validate()
    }
    func testInvalidMutationLeavesEveryCSVUnchanged() throws {
        let repo = try repository(), before = try repo.load()
        XCTAssertThrowsError(try repo.update(actor:"test",action:"bad_edit") { s in
            s.nodes.append(ResearchNode(kind:.task,parentID:"missing",title:"Orphan task"))
        })
        XCTAssertEqual(try repo.load(),before)
    }
    func testDirectCSVEditsAreReadAndInvalidChangesAreExplained() throws {
        let repo = try repository(), url=repo.url.appendingPathComponent("questions.csv"), fingerprint=repo.fingerprint()
        var rows=try CSV.parse(String(contentsOf:url,encoding:.utf8))
        let column=rows[0].firstIndex(of:"short_summary")!
        rows[1][column]="A direct agent edit, with a comma."
        try CSV.encode(rows).write(to:url,atomically:true,encoding:.utf8)
        XCTAssertNotEqual(repo.fingerprint(),fingerprint)
        XCTAssertEqual(try repo.load().node(rows[1][0])?.shortSummary,rows[1][column])
        rows[0].append("unrecognized_column")
        try CSV.encode(rows).write(to:url,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try repo.load()) { XCTAssertTrue($0.localizedDescription.contains("unexpected columns")) }
    }
    func testCommittedInterruptedTransactionRecoversOnOpen() throws {
        let repo=try repository(), pending=repo.url.appendingPathComponent(".fieldwork-pending")
        try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:true)
        try CSV.encode([["schema_version","name"],["1","Recovered workspace"]]).write(to:pending.appendingPathComponent("workspace.csv"),atomically:true,encoding:.utf8)
        try "ready".write(to:pending.appendingPathComponent("COMMIT"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try repo.load().name,"Recovered workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath:pending.path))
    }
    func testUncommittedTransactionDoesNotReplaceData() throws {
        let repo=try repository(), pending=repo.url.appendingPathComponent(".fieldwork-pending")
        try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:true)
        try "broken".write(to:pending.appendingPathComponent("tasks.csv"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try repo.load().name,"Test Research")
        XCTAssertFalse(FileManager.default.fileExists(atPath:pending.path))
    }
    func testConcurrentClaimsHaveExactlyOneWinner() throws {
        let repo=try repository(), lock=NSLock()
        var wins=0, failures=0
        DispatchQueue.concurrentPerform(iterations:6) { index in
            do {
                try WorkspaceRepository(url:repo.url).update(actor:"agent-\(index)",action:"claim",nodeID:"T-004") { try $0.startTask("T-004",agent:"agent-\(index)") }
                lock.lock(); wins += 1; lock.unlock()
            } catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(wins,1); XCTAssertEqual(failures,5)
        XCTAssertEqual(try repo.load().runs.filter { $0.taskID == "T-004" && $0.status == "running" }.count,1)
    }
    func testStaleEditorDoesNotOverwriteAnAgentUpdate() throws {
        let repo=try repository(), original=try repo.load().node("Q-001")!
        Thread.sleep(forTimeInterval:0.005)
        try repo.update(actor:"agent",action:"edit") { s in var updated=s.node(original.id)!; updated.shortSummary="Newer evidence"; try s.edit(updated) }
        XCTAssertThrowsError(try repo.update(actor:"human",action:"edit") { s in var old=original; old.shortSummary="Stale edit"; try s.edit(old,expectedUpdatedAt:original.updatedAt) })
        XCTAssertEqual(try repo.load().node("Q-001")?.shortSummary,"Newer evidence")
    }
    func testDuplicatePositionsAreRejected() throws {
        var s=SampleWorkspace.make(); s.nodes[s.nodes.firstIndex { $0.id == "T-003" }!].order=20
        XCTAssertThrowsError(try s.validate())
    }
    func testImportedHistoryCannotContainParallelTasksWithinOneQuestion() throws {
        var s = SampleWorkspace.make()
        s.runs[1].startedAt = s.runs[0].startedAt
        XCTAssertThrowsError(try s.validate())
    }
    func testCompleteQuestionAfterSynthesisAndConclusion() throws {
        var s=SampleWorkspace.make()
        try s.startTask("T-003",agent:"agent")
        try s.add(ResearchNode(id:"R-rep",kind:.result,parentID:"T-003",title:"Replication held up"))
        try s.finishTask("T-003")
        try s.completeSynthesis("ANS-001")
        XCTAssertEqual(s.nextStep("Q-001")?.id,"C-001")
        try s.completeSynthesis("C-001")
        XCTAssertEqual(s.node("Q-001")?.status,.complete)
        XCTAssertNil(s.nextStep("Q-001"))
        try s.validate()
    }
    func testQuestionDeletionBacksUpCascadesAndRestoresWithoutLosingNewWork() throws {
        let repo = try repository(), original = try repo.load()
        let resultFile = repo.resultsURL(for: original.node("R-001")!)!
        let deleted = try repo.deleteQuestion("Q-001", actor: "human")
        XCTAssertNil(deleted.workspace.node("Q-001"))
        XCTAssertTrue(deleted.workspace.runs.isEmpty)
        XCTAssertTrue(deleted.workspace.metrics.isEmpty)
        XCTAssertTrue(deleted.workspace.links.isEmpty)
        XCTAssertTrue(deleted.workspace.node("T-004") != nil)
        XCTAssertEqual(try WorkspaceRepository(url: deleted.backupURL).load(), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultFile.path))
        try repo.update(actor: "agent", action: "edit") { state in
            var q = state.node("Q-002")!; q.title = "Changed after deletion"; try state.edit(q)
        }
        let restored = try repo.restoreQuestion("Q-001", from: deleted.backupURL, actor: "human")
        XCTAssertEqual(restored.node("Q-001"), original.node("Q-001"))
        XCTAssertEqual(restored.node("Q-002")?.title, "Changed after deletion")
        XCTAssertEqual(restored.runs, original.runs)
        XCTAssertEqual(restored.links, original.links)
        XCTAssertThrowsError(try repo.restoreQuestion("Q-001", from: deleted.backupURL, actor: "human"))
        XCTAssertEqual(try repo.load(), restored)
    }
    func testAimDeletionBacksUpAllDescendantsAndRestoresAlongsideNewWork() throws {
        let repo = try repository(), original = try repo.load()
        let resultFile = repo.resultsURL(for: original.node("R-001")!)!
        let deleted = try repo.deleteAim("AIM-001", actor: "human")
        XCTAssertTrue(deleted.workspace.nodes.isEmpty)
        XCTAssertTrue(deleted.workspace.runs.isEmpty && deleted.workspace.metrics.isEmpty && deleted.workspace.links.isEmpty)
        XCTAssertEqual(try WorkspaceRepository(url: deleted.backupURL).load(), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultFile.path))
        XCTAssertEqual(deleted.workspace.events.last?.action, "delete_aim")
        try repo.update(actor: "agent", action: "create") { state in
            try state.add(ResearchNode(id: "AIM-new", kind: .aim, title: "New work"))
        }
        let restored = try repo.restoreAim("AIM-001", from: deleted.backupURL, actor: "human")
        for node in original.nodes { XCTAssertEqual(restored.node(node.id), node) }
        XCTAssertEqual(restored.node("AIM-new")?.title, "New work")
        XCTAssertEqual(restored.runs, original.runs)
        XCTAssertEqual(restored.metrics, original.metrics)
        XCTAssertEqual(restored.links, original.links)
        XCTAssertEqual(restored.events.last?.action, "restore_aim")
        XCTAssertThrowsError(try repo.restoreAim("AIM-001", from: deleted.backupURL, actor: "human"))
        XCTAssertEqual(try repo.load(), restored)
        let emptyDeleted = try repo.deleteAim("AIM-new", actor: "human")
        XCTAssertNil(emptyDeleted.workspace.node("AIM-new"))
        XCTAssertEqual(emptyDeleted.workspace.node("AIM-001"), original.node("AIM-001"))
        XCTAssertTrue(try repo.restoreAim("AIM-new", from: emptyDeleted.backupURL, actor: "human").node("AIM-new") != nil)
    }
    func testWritesTouchOnlyChangedTablesAndAppendToTheEventLog() throws {
        let repo = try repository()
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: repo.url.appendingPathComponent(name)) }
        func modified(_ name: String) throws -> Date { try FileManager.default.attributesOfItem(atPath: repo.url.appendingPathComponent(name).path)[.modificationDate] as! Date }
        _ = try repo.load()
        let untouched = ["aims.csv", "questions.csv", "tasks.csv", "results.csv", "runs.csv", "links.csv", "metrics.csv", "workspace.csv"]
        let before = try Dictionary(uniqueKeysWithValues: untouched.map { ($0, try modified($0)) })
        let logBefore = try bytes("events.csv")
        Thread.sleep(forTimeInterval: 0.02)
        let rated = try repo.update(actor: "human", action: "rate", nodeID: "Q-001", detail: "Comma, \"quote\"\nand a second line") { try $0.setRating("Q-001", to: .up) }
        for name in untouched { XCTAssertEqual(try modified(name), before[name]) }
        let logAfter = try bytes("events.csv")
        XCTAssertEqual(logAfter.prefix(logBefore.count), logBefore)
        XCTAssertTrue(logAfter.count > logBefore.count)
        XCTAssertEqual(try repo.load(), rated)
        XCTAssertEqual(try WorkspaceRepository(url: repo.url).load(), rated)
        XCTAssertEqual(repo.committedFingerprint, repo.fingerprint())
        XCTAssertEqual(rated.events.last?.detail, "Comma, \"quote\"\nand a second line")

        // Two writers take turns; each sees the other's events exactly once.
        let other = WorkspaceRepository(url: repo.url)
        try other.update(actor: "agent", action: "rate", nodeID: "Q-002") { try $0.setRating("Q-002", to: .down) }
        try repo.update(actor: "human", action: "rate", nodeID: "T-001") { try $0.setRating("T-001", to: .up) }
        let merged = try other.update(actor: "agent", action: "rate", nodeID: "Q-002") { try $0.setRating("Q-002", to: nil) }
        XCTAssertEqual(merged.events.count, rated.events.count + 3)
        XCTAssertEqual(Set(merged.events.map(\.id)).count, merged.events.count)
        XCTAssertEqual(try repo.load(), merged)
        XCTAssertEqual(try WorkspaceRepository(url: repo.url).load(), merged)

        // A deleted table is written again even though its contents did not change.
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("ratings.csv"))
        let restored = try repo.update(actor: "human", action: "touch") { _ in }
        XCTAssertTrue(restored.ratings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("ratings.csv").path))

        // A log rewritten behind our back, or one that stops mid-row, is read again from the start.
        let rewritten = try String(contentsOf: repo.url.appendingPathComponent("events.csv"), encoding: .utf8).replacingOccurrences(of: ",agent,", with: ",robot,")
        try rewritten.write(to: repo.url.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try repo.load().events.contains { $0.actor == "robot" })
        XCTAssertFalse(try repo.load().events.contains { $0.actor == "agent" })
        try String(rewritten.dropLast(1)).write(to: repo.url.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
        let unterminated = try repo.update(actor: "human", action: "after_partial_log") { _ in }
        XCTAssertEqual(try WorkspaceRepository(url: repo.url).load(), unterminated)
        XCTAssertEqual(unterminated.events.last?.action, "after_partial_log")
        XCTAssertEqual(unterminated.events.count, restored.events.count + 1)
    }
    func testManualStatusRowsMayNameAnyExistingRecordAndErrorsNameTheMissingOnes() throws {
        let repo = try repository()
        // An agent that lists active questions and recorded results as manual must not lock the workspace.
        let tolerant = try repo.update(actor: "agent", action: "manual") { state in
            state.manualStatusIDs.formUnion(["AIM-001", "Q-002", "R-001", "T-003"])
        }
        XCTAssertEqual(try repo.load(), tolerant)
        XCTAssertEqual(tolerant.node("Q-002")?.status, .active)
        XCTAssertEqual(tolerant.nextStep("Q-001")?.id, "T-003")
        // A hand-entered result may be recorded without a run when it is marked manual, and not otherwise.
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "bad") { try $0.add(ResearchNode(id: "R-hand", kind: .result, parentID: "T-003", title: "Found by hand")) })
        let byHand = try repo.update(actor: "agent", action: "manual_result") { state in
            state.nodes.append(ResearchNode(id: "R-hand", kind: .result, parentID: "T-003", title: "Found by hand")); state.manualStatusIDs.insert("R-hand")
        }
        XCTAssertEqual(byHand.node("R-hand")?.status, .recorded)
        XCTAssertEqual(try WorkspaceRepository(url: repo.url).load(), byHand)
        // A manual entry still cannot excuse a status that is wrong for the kind.
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "bad") { state in
            state.manualStatusIDs.insert("AIM-001"); state.nodes[state.nodes.firstIndex { $0.id == "AIM-001" }!].status = .recorded
        })
        let file = repo.url.appendingPathComponent("manual_status.csv")
        try "node_id\nQ-001\nghost-a\nghost-b\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try repo.load()) { error in XCTAssertTrue(error.localizedDescription.contains("ghost-a, ghost-b")) }
    }
    func testNewWorkspacesCarryTheAgentFileGuide() throws {
        let repo = try repository()
        let copy = repo.url.appendingPathComponent(AgentGuide.filename)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), AgentGuide.text)
        XCTAssertTrue(AgentGuide.text.hasPrefix("# Populating a Fieldwork workspace"))
        // The embedded text is generated from the Markdown in the repository; a stale copy means the build step did not run.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AGENT_FILE_GUIDE.md")
        if let markdown = try? String(contentsOf: source, encoding: .utf8) { XCTAssertEqual(markdown, AgentGuide.text) }
        // The guide is not a CSV, so it is neither read as data nor part of the change fingerprint.
        let fingerprint = repo.fingerprint()
        try "edited".write(to: copy, atomically: true, encoding: .utf8)
        XCTAssertEqual(repo.fingerprint(), fingerprint)
        XCTAssertEqual(try repo.load(), try WorkspaceRepository(url: repo.url).load())
    }
    func testEmptyWorkspaceRoundTripsWithAnEmptyEventLog() throws {
        let empty = WorkspaceRepository(url: directory.appendingPathComponent("empty"))
        let created = try empty.create(name: "Empty")
        XCTAssertTrue(created.events.isEmpty)
        XCTAssertEqual(try String(contentsOf: empty.url.appendingPathComponent("events.csv"), encoding: .utf8), "id,time,actor,action,node_id,detail\r\n")
        XCTAssertEqual(try WorkspaceRepository(url: empty.url).load(), created)
        let first = try empty.update(actor: "human", action: "create") { try $0.add(ResearchNode(id: "A", kind: .aim, title: "Aim")) }
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(try WorkspaceRepository(url: empty.url).load(), first)
    }
    func testInterruptedEventAppendIsRecoveredExactlyOnce() throws {
        let repo = try repository()
        let before = try repo.load()
        let log = repo.url.appendingPathComponent("events.csv")
        let size = try Data(contentsOf: log).count
        let row = "EVENT-1,2026-09-21T12:00:00.000Z,agent,test,Q-001,Recovered\r\n"
        func stage() throws {
            let pending = repo.url.appendingPathComponent(".fieldwork-pending", isDirectory: true)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try "\(size)\n\(row)".write(to: pending.appendingPathComponent("events.append"), atomically: true, encoding: .utf8)
            try "ready".write(to: pending.appendingPathComponent("COMMIT"), atomically: true, encoding: .utf8)
        }
        // Crashed before the append reached the log.
        try stage()
        XCTAssertEqual(try repo.load().events.map(\.id), before.events.map(\.id) + ["EVENT-1"])
        // Crashed after the append but before the pending folder was removed: the rows must not be added twice.
        try stage()
        let once = try WorkspaceRepository(url: repo.url).load()
        XCTAssertEqual(once.events.map(\.id), before.events.map(\.id) + ["EVENT-1"])
        XCTAssertEqual(try Data(contentsOf: log).count, size + row.utf8.count)
        // Staged but never committed: discarded.
        try stage()
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent(".fieldwork-pending/COMMIT"))
        try "\(size)\nEVENT-2,2026-09-21T12:00:00.000Z,agent,test,Q-001,Never committed\r\n".write(to: repo.url.appendingPathComponent(".fieldwork-pending/events.append"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.load(), once)
    }
    func testCSVParserHandlesBytesQuotesLineEndingsAndUnicode() throws {
        XCTAssertEqual(try CSV.parse("\u{FEFF}a,b\r\n1,\"x, \"\"y\"\"\r\nz\"\r\n"), [["a", "b"], ["1", "x, \"y\"\r\nz"]])
        XCTAssertEqual(try CSV.parse("a,b\n日本語,α\rlast,"), [["a", "b"], ["日本語", "α"], ["last", ""]])
        XCTAssertEqual(try CSV.parse(""), [])
        XCTAssertEqual(try CSV.parse("only"), [["only"]])
        XCTAssertThrowsError(try CSV.parse("a\"b"))
        XCTAssertThrowsError(try CSV.parse("\"a\"b"))
        XCTAssertThrowsError(try CSV.parse("\"open"))
        let awkward = [["id", "text"], ["1", "comma, \"quote\"\r\nnewline\nand 🎯"], ["2", ""]]
        XCTAssertEqual(try CSV.parse(CSV.encode(awkward)), awkward)
    }
    func testAimsArrangeAndCompleteOrReopenWhenMovedAcrossTheDivider() throws {
        let repo = try repository()
        try repo.update(actor: "human", action: "prepare") { state in
            try state.add(ResearchNode(id: "AIM-b", kind: .aim, title: "Second"))
            try state.add(ResearchNode(id: "AIM-c", kind: .aim, title: "Third"))
            try state.setManualStatus("AIM-c", status: .complete, actor: "human")
        }
        let arranged = try repo.update(actor: "human", action: "move_aim") { try $0.arrangeAims(["AIM-b", "AIM-c", "AIM-001"], moving: "AIM-001", completed: true) }
        XCTAssertEqual(arranged.children("").map(\.id), ["AIM-b", "AIM-c", "AIM-001"])
        XCTAssertEqual(arranged.node("AIM-001")?.status, .complete)
        XCTAssertFalse(arranged.node("AIM-001")!.finishedAt.isEmpty)
        XCTAssertEqual(arranged.node("Q-001"), try repo.load().node("Q-001"))
        let reopened = try repo.update(actor: "agent", action: "move_aim") { try $0.arrangeAims(["AIM-c", "AIM-b", "AIM-001"], moving: "AIM-c", completed: false) }
        XCTAssertEqual(reopened.node("AIM-c")?.status, .active)
        XCTAssertEqual(reopened.node("AIM-c")?.finishedAt, "")
        XCTAssertFalse(reopened.manualStatusIDs.contains("AIM-c"))
        XCTAssertEqual(reopened.node("AIM-001")?.status, .complete)
        XCTAssertEqual(try repo.load(), reopened)
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "move_aim") { try $0.arrangeAims(["AIM-c", "AIM-b"], moving: "AIM-c", completed: false) })
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "move_aim") { try $0.arrangeAims(["AIM-c", "AIM-b", "Q-001"], moving: "AIM-c", completed: false) })
        XCTAssertEqual(try repo.load(), reopened)
    }
    func testRatingsPersistAndSupportOlderWorkspacesAndDeletionUndo() throws {
        let repo = try repository()
        let ratingsFile = repo.url.appendingPathComponent("ratings.csv")
        try FileManager.default.removeItem(at: ratingsFile)
        XCTAssertTrue(try repo.load().ratings.isEmpty)
        let rated = try repo.update(actor: "human", action: "rate") { try $0.setRating("Q-001", to: .up); try $0.setRating("T-001", to: .down); try $0.setRating("Q-002", to: .down) }
        XCTAssertEqual(try repo.load(), rated)
        XCTAssertEqual(try String(contentsOf: ratingsFile, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init), ["node_id,rating", "Q-001,up", "Q-002,down", "T-001,down"])
        let deleted = try repo.deleteQuestion("Q-001", actor: "human")
        XCTAssertEqual(deleted.workspace.ratings, ["Q-002": .down])
        try repo.update(actor: "agent", action: "rate") { try $0.setRating("Q-002", to: nil) }
        XCTAssertEqual(try repo.restoreQuestion("Q-001", from: deleted.backupURL, actor: "human").ratings, ["Q-001": .up, "T-001": .down])
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "rate") { try $0.setRating("missing", to: .up) })
        try "node_id,rating\nQ-001,sideways\n".write(to: ratingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try repo.load())
        try "node_id,rating\nQ-001,up\nQ-001,down\n".write(to: ratingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try repo.load())
    }
    func testManualStatusesOverrideEveryKindAndPreserveEvidence() throws {
        let original = SampleWorkspace.make()
        for record in original.nodes {
            var state = original
            for status in [NodeStatus.running, .complete, .planned, .running] {
                try state.setManualStatus(record.id, status: status, actor: "human")
                try state.validate()
                XCTAssertEqual(state.node(record.id)?.status, status)
                XCTAssertTrue(state.manualStatusIDs.contains(record.id))
                XCTAssertEqual(state.node(record.id)?.shortSummary, record.shortSummary)
                XCTAssertEqual(state.node(record.id)?.detailedSummary, record.detailedSummary)
                XCTAssertEqual(state.node(record.id)?.resultsPath, record.resultsPath)
                XCTAssertEqual(state.nodes.count, original.nodes.count)
                XCTAssertEqual(state.runs, original.runs)
                XCTAssertEqual(state.events.last?.action, "manual_status_override")
            }
        }
        var state = original
        try state.setManualStatus("T-003", status: .running, actor: "human")
        try state.setManualStatus("T-001", status: .running, actor: "human")
        try state.setManualStatus("Q-001", status: .complete, actor: "human")
        try state.validate()
        XCTAssertEqual(state.node("T-003")?.status, .running)
        XCTAssertThrowsError(try state.setManualStatus("missing", status: .running, actor: "human"))
        XCTAssertThrowsError(try state.setManualStatus("T-001", status: .failed, actor: "human"))
    }
    func testManualStatusesPersistCloseExistingRunsAndSurviveUndo() throws {
        let repo = try repository()
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("manual_status.csv"))
        XCTAssertTrue(try repo.load().manualStatusIDs.isEmpty)
        let started = try repo.update(actor: "agent", action: "start") { try $0.startTask("T-004", agent: "agent") }
        let done = try repo.update(actor: "human", action: "set_status") { try $0.setManualStatus("T-004", status: .complete, actor: "human") }
        XCTAssertEqual(done.node("T-004")?.status, .complete)
        XCTAssertEqual(done.runs.last?.status, "complete")
        XCTAssertTrue(done.runs.last?.note.contains("manual status override") == true)
        XCTAssertEqual(done.nodes.count, started.nodes.count)
        XCTAssertEqual(try repo.load(), done)
        let deleted = try repo.deleteAim("AIM-001", actor: "human")
        XCTAssertTrue(deleted.workspace.manualStatusIDs.isEmpty)
        let restored = try repo.restoreAim("AIM-001", from: deleted.backupURL, actor: "human")
        XCTAssertEqual(restored.manualStatusIDs, done.manualStatusIDs)
        XCTAssertEqual(restored.node("T-004"), done.node("T-004"))
        XCTAssertThrowsError(try repo.update(actor: "agent", action: "invalid_override") { $0.manualStatusIDs.insert("missing") })
        XCTAssertEqual(try repo.load(), restored)
    }
    func testMarkPlannedStopsExistingAttemptAndPersistsForRetry() throws {
        let repo = try repository()
        let started = try repo.update(actor: "agent", action: "start") { try $0.startTask("T-004", agent: "agent") }
        let planned = try repo.update(actor: "human", action: "set_status") { try $0.setManualStatus("T-004", status: .planned, actor: "human") }
        XCTAssertEqual(planned.node("T-004")?.status, .planned)
        XCTAssertEqual(planned.node("T-004")?.startedAt, "")
        XCTAssertEqual(planned.node("T-004")?.finishedAt, "")
        XCTAssertEqual(planned.runs.last?.status, "failed")
        XCTAssertTrue(planned.runs.last?.note.contains("reset to Planned") == true)
        XCTAssertEqual(planned.nodes.count, started.nodes.count)
        XCTAssertEqual(try repo.load(), planned)
        let retried = try repo.update(actor: "agent", action: "start") { try $0.startTask("T-004", agent: "agent") }
        XCTAssertEqual(retried.node("T-004")?.status, .running)
        XCTAssertFalse(retried.manualStatusIDs.contains("T-004"))
        XCTAssertEqual(retried.runs.count, started.runs.count + 1)
    }
    func testEveryCardKindCanBeDeletedAndRestoredWithMetadata() throws {
        for kind in NodeKind.allCases {
            let repo = WorkspaceRepository(url: directory.appendingPathComponent(kind.rawValue))
            _ = try repo.create(name: "Deletion", sample: true)
            let before = try repo.update(actor: "human", action: "prepare") { state in
                for card in state.nodes { try state.setManualStatus(card.id, status: .complete, actor: "human") }
                for card in state.nodes { try state.setRating(card.id, to: .up) }
                try state.add(ResearchNode(id: "AIM-other", kind: .aim, title: "Other aim"))
            }
            let card = before.nodes.first { $0.kind == kind }!
            let removed = try before.recordIDs(card.id)
            let deletion = try repo.deleteNode(card.id, actor: "human")
            XCTAssertTrue(deletion.workspace.nodes.allSatisfy { !removed.contains($0.id) })
            XCTAssertTrue(Set(deletion.workspace.ratings.keys).isDisjoint(with: removed))
            XCTAssertTrue(deletion.workspace.manualStatusIDs.isDisjoint(with: removed))
            XCTAssertEqual(try WorkspaceRepository(url: deletion.backupURL).load(), before)
            try repo.update(actor: "agent", action: "edit") { state in
                var other = state.node("AIM-other")!; other.title = "Concurrent edit"; try state.edit(other)
            }
            let restored = try repo.restoreNode(card.id, from: deletion.backupURL, actor: "human")
            for node in before.nodes where node.id != "AIM-other" { XCTAssertEqual(restored.node(node.id), node) }
            XCTAssertEqual(restored.node("AIM-other")?.title, "Concurrent edit")
            XCTAssertEqual(restored.ratings, before.ratings)
            XCTAssertEqual(restored.manualStatusIDs, before.manualStatusIDs)
            XCTAssertEqual(restored.runs.sorted { $0.id < $1.id }, before.runs.sorted { $0.id < $1.id })
            XCTAssertEqual(restored.metrics, before.metrics)
            XCTAssertEqual(restored.links, before.links)
            XCTAssertEqual(try repo.load(), restored)
            XCTAssertThrowsError(try repo.restoreNode(card.id, from: deletion.backupURL, actor: "human"))
        }
    }
    func testCardDeletionProtectsReferencesAndCompletionEvidence() throws {
        let repo = try repository(), before = try repo.load()
        for id in ["R-001", "missing"] {
            XCTAssertThrowsError(try repo.deleteNode(id, actor: "human"))
            XCTAssertEqual(try repo.load(), before)
        }
        try repo.update(actor: "human", action: "override") { try $0.setManualStatus("T-001", status: .running, actor: "human") }
        let deleted = try repo.deleteNode("R-001", actor: "human")
        XCTAssertNil(deleted.workspace.node("R-001"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.resultsURL(for: before.node("R-001")!)!.path))
        XCTAssertTrue(try repo.restoreNode("R-001", from: deleted.backupURL, actor: "human").node("R-001") != nil)
    }
    func testDeletingCompletedSynthesisRefreshesQuestionAndUndoRestoresCompletion() throws {
        let repo = try repository()
        _ = try repo.update(actor: "human", action: "finish_question") { state in
            try state.completeTaskManually("T-004", actor: "human", note: "Reviewed")
            try state.completeSynthesis("ANS-002")
        }
        XCTAssertEqual(try repo.load().node("Q-002")?.status, .complete)
        let deleted = try repo.deleteNode("ANS-002", actor: "human")
        XCTAssertEqual(deleted.workspace.node("Q-002")?.status, .active)
        let restored = try repo.restoreNode("ANS-002", from: deleted.backupURL, actor: "human")
        XCTAssertEqual(restored.node("Q-002")?.status, .complete)
    }
    func testQuestionReorderingUsesStablePositionsBeforeAfterAndAtEnd() throws {
        var state = SampleWorkspace.make()
        try state.add(ResearchNode(id: "Q-third", kind: .question, parentID: "AIM-001", order: 30, title: "Third"))
        try state.moveQuestion("Q-third", toAim: "AIM-001", relativeTo: "Q-001")
        XCTAssertEqual(state.children("AIM-001").map(\.id), ["Q-third", "Q-001", "Q-002"])
        try state.moveQuestion("Q-third", toAim: "AIM-001", relativeTo: "Q-001", after: true)
        XCTAssertEqual(state.children("AIM-001").map(\.id), ["Q-001", "Q-third", "Q-002"])
        try state.moveQuestion("Q-001", toAim: "AIM-001")
        XCTAssertEqual(state.children("AIM-001").map(\.id), ["Q-third", "Q-002", "Q-001"])
        XCTAssertEqual(state.children("AIM-001").map(\.order), [10, 20, 30])
        let beforeSelfDrop = state
        try state.moveQuestion("Q-001", toAim: "AIM-001", relativeTo: "Q-001")
        XCTAssertEqual(state, beforeSelfDrop)
        try state.validate()
    }
    func testMovingQuestionsAcrossAimsPersistsWorkflowAndConcurrentEdits() throws {
        let repo = try repository()
        let original = try repo.update(actor: "human", action: "prepare_move") { state in
            try state.add(ResearchNode(id: "AIM-other", kind: .aim, title: "Another aim"))
            try state.setRating("Q-001", to: .up); try state.setRating("R-001", to: .down)
            try state.setManualStatus("T-003", status: .complete, actor: "human")
        }
        let edited = try repo.update(actor: "agent", action: "edit") { state in
            var q = state.node("Q-001")!; q.title = "Latest question title"; try state.edit(q)
        }
        let moved = try repo.update(actor: "human", action: "move_question") { state in
            try state.moveQuestion("Q-001", toAim: "AIM-other", expectedAimID: "AIM-001")
        }
        XCTAssertEqual(moved.node("Q-001")?.title, "Latest question title")
        XCTAssertEqual(moved.children("AIM-other").map(\.id), ["Q-001"])
        XCTAssertEqual(moved.children("AIM-001").map(\.id), ["Q-002"])
        for record in original.nodes where [.task, .result, .answer, .conclusion].contains(record.kind) {
            XCTAssertEqual(moved.node(record.id), edited.node(record.id))
        }
        XCTAssertEqual(moved.aimID(for: moved.node("R-001")!), "AIM-other")
        XCTAssertEqual(moved.runs, original.runs)
        XCTAssertEqual(moved.metrics, original.metrics)
        XCTAssertEqual(moved.links, original.links)
        XCTAssertEqual(moved.ratings, original.ratings)
        XCTAssertEqual(moved.manualStatusIDs, original.manualStatusIDs)
        XCTAssertEqual(try repo.load(), moved)
        XCTAssertThrowsError(try repo.update(actor: "human", action: "stale_move") { try $0.moveQuestion("Q-001", toAim: "AIM-001", expectedAimID: "AIM-001") })
        XCTAssertEqual(try repo.load(), moved)
    }
    func testQuestionMovesRejectInvalidTargetsWithoutChangingRecords() throws {
        let original = SampleWorkspace.make()
        for (id, aim, anchor) in [("T-001", "AIM-001", "Q-001"), ("Q-001", "Q-002", "Q-002"), ("Q-001", "AIM-001", "T-001"), ("missing", "AIM-001", "Q-001")] {
            var state = original
            XCTAssertThrowsError(try state.moveQuestion(id, toAim: aim, relativeTo: anchor))
            XCTAssertEqual(state, original)
        }
        var state = original
        try state.add(ResearchNode(id: "AIM-other", kind: .aim, title: "Another aim"))
        let before = state
        XCTAssertThrowsError(try state.moveQuestion("Q-001", toAim: "AIM-other", relativeTo: "Q-002"))
        XCTAssertEqual(state, before)
    }
    func testManualCompletionRecordsAnAttestationAndPreservesSequence() throws {
        let repo = try repository(), before = try repo.load()
        XCTAssertThrowsError(try repo.update(actor: "human", action: "complete") { try $0.completeTaskManually("T-001", actor: "human", note: "Done") })
        XCTAssertThrowsError(try repo.update(actor: "human", action: "complete") { try $0.completeTaskManually("T-004", actor: "human", note: "  ") })
        XCTAssertEqual(try repo.load(), before)
        let completed = try repo.update(actor: "human", action: "manual_complete_task") { try $0.completeTaskManually("T-004", actor: "human", note: "Reviewed the query groups.") }
        XCTAssertEqual(completed.node("T-004")?.status, .complete)
        XCTAssertEqual(completed.nextStep("Q-002")?.id, "ANS-002")
        XCTAssertEqual(completed.node("Q-002")?.status, .active)
        let result = completed.children("T-004").first!
        XCTAssertEqual(result.title, "Completion note")
        XCTAssertTrue(result.detailedSummary.contains("User-reported completion"))
        XCTAssertEqual(result.runID, completed.runs.last?.id)
        XCTAssertEqual(completed.runs.last?.status, "complete")
        XCTAssertThrowsError(try repo.update(actor: "human", action: "complete") { try $0.completeTaskManually("T-004", actor: "human", note: "Again") })
    }
    func testManualCompletionUsesExistingOutputWithoutDuplicatingResults() throws {
        let repo = try repository()
        try repo.update(actor: "agent", action: "start") { state in
            try state.startTask("T-004", agent: "agent")
            try state.add(ResearchNode(id: "R-output", kind: .result, parentID: "T-004", title: "Actual output"))
        }
        let completed = try repo.update(actor: "human", action: "manual_complete_task") { try $0.completeTaskManually("T-004", actor: "human", note: "Reviewed the output.") }
        XCTAssertEqual(completed.children("T-004").map(\.id), ["R-output"])
        XCTAssertEqual(completed.runs.last?.agentID, "agent")
        XCTAssertTrue(completed.runs.last?.note.contains("human") == true)
        try completed.validate()
    }

    func testStepsArrangeAndOutOfSequenceMovesBecomeOverrides() throws {
        let repo = try repository()
        let reordered = try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["T-001", "T-002", "ANS-001", "T-003", "C-001"]) }
        XCTAssertEqual(reordered.steps("Q-001").map(\.id), ["T-001", "T-002", "ANS-001", "T-003", "C-001"])
        XCTAssertEqual(reordered.steps("Q-001").map(\.order), [10, 20, 30, 40, 50])
        XCTAssertEqual(reordered.nextStep("Q-001")?.id, "ANS-001")
        XCTAssertTrue(reordered.manualStatusIDs.isEmpty) // Moving unfinished steps among themselves needs no override.
        XCTAssertEqual(try repo.load(), reordered)
        XCTAssertEqual(try WorkspaceRepository(url: repo.url).load(), reordered)
        // A finished task moved below unfinished ones keeps its evidence and state as an explicit override.
        let overridden = try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["T-002", "ANS-001", "T-001", "T-003", "C-001"]) }
        XCTAssertEqual(overridden.node("T-001")?.status, .complete)
        XCTAssertEqual(overridden.manualStatusIDs, ["T-001"])
        XCTAssertEqual(overridden.runs, reordered.runs)
        XCTAssertEqual(overridden.children("T-001").map(\.id), ["R-001"])
        XCTAssertEqual(overridden.nextStep("Q-001")?.id, "ANS-001")
        // A running task dragged below a staged one is an override too; dragging it back does not clear the override.
        try repo.update(actor: "agent", action: "start") { try $0.startTask("T-004", agent: "agent") }
        try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-002", ["ANS-002", "T-004"]) }
        XCTAssertTrue(try repo.load().manualStatusIDs.contains("T-004"))
        try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-002", ["T-004", "ANS-002"]) }
        XCTAssertTrue(try repo.load().manualStatusIDs.contains("T-004"))
        // Conclusions always come last, however the list is given or where a new step is numbered.
        let closing = try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["C-001", "T-003", "T-002", "ANS-001", "T-001"]) }
        XCTAssertEqual(closing.steps("Q-001").map(\.id), ["T-003", "T-002", "ANS-001", "T-001", "C-001"])
        let appended = try repo.update(actor: "agent", action: "create") { try $0.add(ResearchNode(id: "T-late", kind: .task, parentID: "Q-001", order: 99, title: "Late task")) }
        XCTAssertEqual(appended.steps("Q-001").map(\.id), ["T-003", "T-002", "ANS-001", "T-001", "T-late", "C-001"])
        XCTAssertEqual(Set(appended.steps("Q-001").map(\.order)).count, 6)
        try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["T-001", "T-002", "ANS-001", "T-003", "C-001", "T-late"]) }
        XCTAssertEqual(try repo.load().steps("Q-001").map(\.id), ["T-001", "T-002", "ANS-001", "T-003", "T-late", "C-001"])
        try repo.update(actor: "human", action: "delete") { try $0.deleteNode("T-late") }
        // Bad lists change nothing.
        let before = try repo.load()
        XCTAssertThrowsError(try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["T-001", "T-002"]) })
        XCTAssertThrowsError(try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-001", ["T-001", "T-002", "ANS-001", "T-003", "T-004"]) })
        XCTAssertThrowsError(try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("T-001", []) })
        XCTAssertEqual(try repo.load(), before)
        // Reordering a finished question's steps keeps it finished.
        let finished = try repo.update(actor: "human", action: "finish") { state in
            try state.setManualStatus("T-004", status: .complete, actor: "human")
            try state.completeSynthesis("ANS-002")
        }
        XCTAssertEqual(finished.node("Q-002")?.status, .complete)
        XCTAssertEqual(try repo.update(actor: "human", action: "move_step") { try $0.arrangeSteps("Q-002", ["T-004", "ANS-002"]) }.node("Q-002")?.status, .complete)
    }

}
