import Foundation
import CoreGraphics
import Combine
import ResearchCore

// Exercises the same commit and selection path used by the native editor.
@main struct FieldworkChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldwork-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = WorkspaceRepository(url: root)
        _ = try repo.create(name: "Editor checks", sample: true)
        let store = AppStore(workspaceURL: root)
        precondition(store.expandedAimID == nil && store.questionID == nil, "Open at the aims-only overview")
        let previousQuestion = store.questions.first?.id
        store.newNode(.question)
        let request = store.editor!
        precondition(request.parentID == store.aimID)
        let question = ResearchNode(kind: .question, parentID: request.parentID, order: request.suggestedOrder(parentID: request.parentID, workspace: store.workspace), title: "Does this save?", shortSummary: "A short, quoted \"summary\"", detailedSummary: "First line\nSecond line", resultsPath: "results/new-question")
        try store.saveRecord(question, replacing: nil) { state in
            state.links.append(ResearchLink(sourceID: question.id, targetID: previousQuestion!, relation: "inspired_by"))
        }
        let saved = try repo.load()
        precondition(saved.children(question.parentID).first?.id == question.id, "New questions lead the list")
        precondition(saved.node(question.id) == question, "Question fields must persist in CSV")
        precondition(store.editor == nil && store.selectedID == question.id && store.questionID == question.id)
        precondition(store.aimID == question.parentID && store.visibleQuestions.map(\.id) == [question.id])
        print("PASS question editor persists fields, closes, and focuses its new question")

        store.newNode(.question)
        let pendingRequest = store.editor!.id
        let invalid = ResearchNode(kind: .question, parentID: "missing", title: "Invalid parent")
        var rejected = false
        do { try store.saveRecord(invalid, replacing: nil) } catch { rejected = true }
        precondition(rejected && store.editor?.id == pendingRequest)
        let unchanged = try repo.load()
        precondition(unchanged == saved, "Failed save must not change CSVs")
        print("PASS failed editor save preserves draft and workspace")

        precondition(saved.links.contains { $0.sourceID == question.id && $0.relation == "inspired_by" })
        let q1 = saved.node(previousQuestion!)!
        store.toggle(q1)
        precondition(store.questionID == q1.id)
        store.toggle(saved.node("R-001")!)
        precondition(store.questionID == q1.id && store.selectedID == "R-001")
        store.toggle(q1)
        precondition(store.questionID == nil && store.selectedID == q1.id)
        precondition(store.selectedAncestorIDs == Set(["AIM-001"]))
        print("PASS clicking a question opens its steps and clicking it again closes them")

        precondition(store.workspace.progress(q1) == .working && store.workspace.progress(question) == .staged, "A question is working once a step has started")
        precondition(store.workspace.progress(saved.node("T-001")!) == .done && store.workspace.progress(saved.node("R-001")!) == .done)
        precondition(store.workspace.progress(saved.node("T-003")!) == .staged)
        let selectionBeforeClicks = store.selectedID
        store.cycleStatus(question)
        precondition(store.workspace.node(question.id)?.status == .running && store.workspace.progress(store.workspace.node(question.id)!) == .working)
        store.cycleStatus(store.workspace.node(question.id)!)
        precondition(store.workspace.node(question.id)?.status == .complete && store.workspace.progress(store.workspace.node(question.id)!) == .done)
        for expected in [Rating.up, .down, nil] {
            store.cycleRating(question)
            precondition(store.workspace.ratings[question.id] == expected)
            let onDisk = try repo.load()
            precondition(onDisk.ratings[question.id] == expected, "Ratings persist in ratings.csv")
        }
        store.cycleRating(question)
        store.cycleStatus(store.workspace.node(question.id)!)
        precondition(store.workspace.node(question.id)?.status == .planned && store.workspace.progress(store.workspace.node(question.id)!) == .staged)
        precondition(store.workspace.ratings[question.id] == .up, "A rating survives a misclick through the status cycle")
        precondition(store.selectedID == selectionBeforeClicks && store.error == nil, "Status and rating clicks do not move the selection")
        let ratingEvents = try repo.load()
        precondition(ratingEvents.events.contains { $0.action == "rate" && $0.nodeID == question.id } && ratingEvents.events.contains { $0.action == "manual_status_override" && $0.nodeID == question.id })
        store.deleteCard(store.workspace.node(question.id)!)
        precondition(store.workspace.ratings[question.id] == nil)
        store.undoHierarchyDeletion()
        precondition(store.workspace.ratings[question.id] == .up)
        store.toggle(store.workspace.node(question.id)!)
        print("PASS bullets cycle staged, working, and done; ratings cycle up, down, and neutral, persist, and follow deletion and undo")

        store.reveal(saved.node("T-004")!)
        precondition(store.questionID == "Q-002" && store.selectedID == "T-004" && store.graphFocus?.nodeID == "T-004")
        let lastFocus = store.graphFocus!.id
        store.reveal(saved.node("T-004")!)
        precondition(store.graphFocus!.id != lastFocus, "Repeated clicks must scroll to the task again")
        print("PASS revealing a record opens its question and scrolls to it")

        store.select(q1, focus: true)
        var aimChanges = 0, questionChanges = 0
        let aimSubscription = store.$aimID.dropFirst().sink { _ in aimChanges += 1 }
        let questionSubscription = store.$questionID.dropFirst().sink { _ in questionChanges += 1 }
        store.toggle(saved.node("T-001")!)
        precondition(store.selectedAncestorIDs == Set(["Q-001", "AIM-001"]))
        store.toggle(saved.node("T-002")!)
        precondition(store.selectedAncestorIDs == Set(["Q-001", "AIM-001"]))
        store.toggle(saved.node("R-001")!)
        precondition(store.selectedAncestorIDs == Set(["T-001", "Q-001", "AIM-001"]))
        precondition(aimChanges == 0 && questionChanges == 0, "Card selection must not republish unchanged hierarchy state")
        aimSubscription.cancel(); questionSubscription.cancel()
        print("PASS selecting sibling cards does not republish hierarchy focus")

        store.requestCompletion(saved.node("T-004")!)
        precondition(store.action?.isCompletion == true && store.action?.nodeID == "T-004")
        store.action = nil
        store.requestCompletion(saved.node("T-003")!)
        precondition(store.action?.nodeID == "T-003", "The next step can be completed")
        store.action = nil
        // A task behind another is refused without opening a sheet; tried in memory so the workspace on disk is untouched.
        let keep = store.workspace
        var withBlocked = keep
        let blocked = ResearchNode(id: "T-blocked", kind: .task, parentID: "Q-001", order: 45, title: "Blocked")
        try withBlocked.add(blocked)
        store.workspace = withBlocked
        store.requestCompletion(blocked)
        precondition(store.action == nil && store.error != nil)
        store.error = nil
        store.workspace = keep
        store.toggle(saved.node("R-001")!)
        store.deleteQuestion(q1)
        precondition(store.workspace.node(q1.id) == nil && store.selectedID == store.aimID && store.questionID == nil && store.deletedHierarchy?.id == q1.id)
        store.undoHierarchyDeletion()
        precondition(store.workspace.node(q1.id) != nil && store.deletedHierarchy == nil && store.questionID == q1.id)
        print("PASS completion actions enforce order and question deletion supports undo and selection recovery")
        var multi = store.workspace
        try multi.add(ResearchNode(id: "AIM-002", kind: .aim, title: "Second aim"))
        try multi.add(ResearchNode(id: "AIM-003", kind: .aim, title: "Empty aim"))
        try multi.add(ResearchNode(id: "Q-other", kind: .question, parentID: "AIM-002", title: "Another question"))
        try multi.add(ResearchNode(id: "Q-above", kind: .question, parentID: "AIM-002", order: -10, title: "First question"))
        try multi.add(ResearchNode(id: "Q-below", kind: .question, parentID: "AIM-002", order: 10, title: "Last question"))
        try multi.add(ResearchNode(id: "T-other", kind: .task, parentID: "Q-other", title: "Another task"))
        try multi.add(ResearchNode(id: "R-other", kind: .result, parentID: "T-other", title: "Expected output", status: .planned))
        try multi.validate()
        store.workspace = multi
        store.toggle(multi.node("AIM-002")!)
        precondition(store.aimID == "AIM-002" && store.expandedAimID == "AIM-002" && store.questionID == nil)
        store.toggle(multi.node("Q-other")!)
        precondition(store.expandedAimID == "AIM-002" && store.questionID == "Q-other")
        store.toggle(multi.node("AIM-002")!)
        precondition(store.expandedAimID == nil && store.questionID == nil)
        store.reveal(multi.node("T-001")!)
        precondition(store.expandedAimID == "AIM-001" && store.questionID == "Q-001" && store.graphFocus?.nodeID == "T-001")
        store.open(root)
        precondition(store.expandedAimID == nil && store.questionID == nil)
        store.reveal(store.workspace.node("T-001")!)
        precondition(store.view == .aims && store.questionID == "Q-001")
        store.show(.aims)
        precondition(store.questionID == nil && store.expandedAimID == "AIM-001" && store.selectedID == "T-001", "Choosing Aims while a question is open slides back to the aims and keeps the aim open")
        store.show(.aims)
        precondition(store.expandedAimID == "AIM-001", "Choosing it again changes nothing")
        store.reveal(store.workspace.node("T-001")!)
        store.show(.timeline)
        store.show(.aims)
        precondition(store.view == .aims && store.questionID == "Q-001", "Coming back from another tab returns to the open question")
        print("PASS aim toggle, cross-aim navigation, the Aims tab as a way back, and reopening preserve the intended expansion state")
        for kind in [NodeKind.task, .conclusion] {
            let previousLast = store.workspace.steps("Q-001").last!
            store.newNode(kind, parentID: "Q-001", append: true)
            let request = store.editor!
            precondition(request.kind == kind && request.parentID == "Q-001" && request.appendToWorkflow)
            let order = request.suggestedOrder(parentID: request.parentID, workspace: store.workspace)
            precondition(order > previousLast.order)
            let record = ResearchNode(kind: kind, parentID: request.parentID, order: order, title: "Appended \(kind.label)")
            try store.saveRecord(record, replacing: nil)
            // A task joins the end of its section; the conclusions stay below it.
            let steps = store.workspace.steps("Q-001")
            precondition(kind == .conclusion ? steps.last?.id == record.id : steps.filter { $0.kind != .conclusion }.last?.id == record.id && steps.last?.kind == .conclusion)
        }
        store.newNode(.task, parentID: "Q-001")
        precondition(store.editor!.suggestedOrder(parentID: "Q-001", workspace: store.workspace) < store.workspace.node("ANS-001")!.order)
        print("PASS step controls append to the execution order and new tasks slot in before synthesis")
        store.editor = nil
        store.reveal(store.workspace.node("T-001")!)
        let deletedAim = store.workspace.node("AIM-001")!
        let recordCount = store.workspace.nodes.count
        store.deleteAim(deletedAim)
        precondition(store.workspace.nodes.isEmpty && store.aimID == nil && store.selectedID == nil)
        precondition(store.expandedAimID == nil && store.questionID == nil && store.graphFocus == nil)
        precondition(store.deletedHierarchy?.kind == .aim && store.deletedHierarchy?.id == deletedAim.id)
        let afterAimDeletion = try repo.load()
        precondition(afterAimDeletion.nodes.isEmpty)
        store.undoHierarchyDeletion()
        precondition(store.workspace.nodes.count == recordCount && store.deletedHierarchy == nil)
        precondition(store.selectedID == deletedAim.id && store.expandedAimID == deletedAim.id && store.questionID == nil)
        try store.saveRecord(ResearchNode(id: "AIM-spare", kind: .aim, title: "Another aim"), replacing: nil)
        store.reveal(store.workspace.node("T-001")!)
        store.deleteAim(store.workspace.node("AIM-spare")!)
        precondition(store.selectedID == "T-001" && store.expandedAimID == "AIM-001" && store.questionID == "Q-001")
        store.undoHierarchyDeletion()
        precondition(store.workspace.node("AIM-spare") != nil)
        store.reveal(store.workspace.node("T-001")!)
        store.deleteAim(deletedAim)
        precondition(store.aimID == "AIM-spare" && store.selectedID == "AIM-spare")
        precondition(store.expandedAimID == nil && store.questionID == nil)
        store.undoHierarchyDeletion()
        precondition(store.workspace.node("T-001") != nil)
        print("PASS aim deletion clears descendants and stale focus, preserves other aims, and supports undo")
        store.view = .timeline
        let statusSelection = store.selectedID
        let statusAim = store.expandedAimID
        let statusQuestion = store.questionID
        for kind in NodeKind.allCases {
            let card = store.workspace.nodes.first { $0.kind == kind }!
            store.setStatus(card, to: .running)
            precondition(store.workspace.node(card.id)?.status == .running)
            store.setStatus(card, to: .complete)
            precondition(store.workspace.node(card.id)?.status == .complete)
            store.setStatus(card, to: .planned)
            precondition(store.workspace.node(card.id)?.status == .planned)
        }
        precondition(store.view == .timeline && store.selectedID == statusSelection)
        precondition(store.expandedAimID == statusAim && store.questionID == statusQuestion)
        let statusReloaded = try repo.load()
        precondition(statusReloaded.manualStatusIDs == store.workspace.manualStatusIDs)
        precondition(statusReloaded.nodes == store.workspace.nodes)
        print("PASS Planned, Running, and Done override every card kind and persist without changing selection or view")
        precondition(store.mutate(action: "prepare_deletion") { state in
            for card in state.nodes { try state.setManualStatus(card.id, status: .complete, actor: "human") }
        })
        for kind in NodeKind.allCases {
            let card = store.workspace.nodes.first { $0.kind == kind }!
            store.cycleRating(card)
            store.select(card, focus: true)
            store.view = .timeline
            let parentID = card.parentID
            store.deleteCard(card)
            precondition(store.workspace.node(card.id) == nil && store.deletedHierarchy?.kind == kind)
            precondition(store.workspace.ratings[card.id] == nil && store.view == .timeline)
            if !parentID.isEmpty { precondition(store.selectedID == parentID) }
            store.undoHierarchyDeletion()
            precondition(store.workspace.node(card.id) != nil && store.selectedID == card.id)
            precondition(store.workspace.ratings[card.id] == .up)
        }
        print("PASS every card kind supports deletion and undo with parent selection and rating cleanup")
        precondition(store.moveQuestion("Q-002", toAim: "AIM-001", relativeTo: question.id))
        precondition(store.moveQuestion("Q-001", toAim: "AIM-001", relativeTo: "Q-002"))
        store.reveal(store.workspace.node("Q-001")!)
        // Rows report their frames to the store; lay out the same two columns the window would.
        func layoutRows() {
            var frames: [String: CGRect] = [:]
            for (index, aim) in store.aims.enumerated() { frames[aim.id] = CGRect(x: 0, y: CGFloat(index) * 36, width: 200, height: 34) }
            for (index, question) in store.questions.enumerated() { frames[question.id] = CGRect(x: 220, y: CGFloat(index) * 36, width: 200, height: 34) }
            store.rowFrames = frames
        }
        layoutRows()
        let beforeDrag = try repo.load()
        let inColumn = CGPoint(x: 300, y: 40), down = CGSize(width: 0, height: 40), up = CGSize(width: 0, height: -40)
        store.updateQuestionDrag("Q-001", location: inColumn, translation: CGSize(width: 0, height: 12))
        precondition(store.questionDrag?.insertionIndex == 0 && store.questionsWhileDragging.map(\.id) == store.questions.map(\.id), "Rows hold still until the dragged row passes a neighbour's centre")
        store.updateQuestionDrag("Q-001", location: inColumn, translation: down)
        precondition(store.questionDrag?.insertionIndex == 1 && store.questionDrag?.validDrop == true)
        precondition(store.questionsWhileDragging.map(\.id) == ["Q-002", "Q-001", question.id], "Neighbours slide to open the gap")
        store.rowFrames = [:]
        store.updateQuestionDrag("Q-001", location: inColumn, translation: down)
        precondition(store.questionDrag?.insertionIndex == 1, "Sliding rows must not feed back into the drop position")
        precondition(store.workspace == beforeDrag, "Hovering must not write CSVs")
        precondition(store.finishQuestionDrag() && store.questionDrag == nil)
        precondition(store.questions.firstIndex { $0.id == "Q-001" }! == store.questions.firstIndex { $0.id == "Q-002" }! + 1)
        layoutRows()
        store.updateQuestionDrag("Q-001", location: inColumn, translation: up)
        let beforeCancel = store.workspace
        store.cancelQuestionDrag()
        precondition(store.questionDrag == nil && store.workspace == beforeCancel)
        store.updateQuestionDrag("Q-001", location: inColumn, translation: .zero)
        precondition(!store.finishQuestionDrag() && store.workspace == beforeCancel && store.error == nil, "Dropping a row where it started writes nothing")
        store.updateQuestionDrag("Q-001", location: inColumn, translation: up)
        precondition(store.finishQuestionDrag())
        precondition(store.questions.firstIndex { $0.id == "Q-001" }! + 1 == store.questions.firstIndex { $0.id == "Q-002" }!)
        try store.saveRecord(ResearchNode(id: "AIM-drop", kind: .aim, title: "Drop target"), replacing: nil)
        store.reveal(store.workspace.node("Q-001")!)
        layoutRows()
        let aimRect = store.rowFrames["AIM-drop"]!
        store.updateQuestionDrag("Q-001", location: CGPoint(x: aimRect.midX, y: aimRect.midY), translation: .zero)
        precondition(store.questionDrag?.targetAimID == "AIM-drop" && store.questionsWhileDragging.map(\.id) == store.questions.map(\.id))
        precondition(store.workspace.node("Q-001")?.parentID == "AIM-001")
        precondition(store.finishQuestionDrag())
        precondition(store.aimID == "AIM-drop" && store.expandedAimID == "AIM-drop" && store.questionID == nil && store.selectedID == "Q-001")
        precondition(store.selectedAncestorIDs == Set(["AIM-drop"]))
        precondition(store.workspace.aimID(for: store.workspace.node("R-001")!) == "AIM-drop")
        let afterDrop = try repo.load()
        precondition(afterDrop.node("Q-001")?.parentID == "AIM-drop")
        layoutRows()
        store.updateQuestionDrag("Q-001", location: CGPoint(x: 900, y: 300), translation: .zero)
        precondition(!store.finishQuestionDrag() && store.workspace == afterDrop)
        store.updateQuestionDrag("Q-001", location: CGPoint(x: store.rowFrames["AIM-001"]!.midX, y: store.rowFrames["AIM-001"]!.midY), translation: .zero)
        precondition(store.questionDrag?.targetAimID == "AIM-001" && store.questionDrag?.validDrop == true)
        let externalMove = try repo.update(actor: "agent", action: "move_question") { try $0.moveQuestion("Q-001", toAim: "AIM-001") }
        precondition(!store.finishQuestionDrag(), "A drag started before another move must not overwrite it")
        store.error = nil
        let afterStaleDrop = try repo.load()
        precondition(afterStaleDrop == externalMove)
        store.sync(force: true)
        print("PASS question dragging slides neighbours apart, targets other aims, commits on release, and handles cancellation and stale moves")
        let timelineRoot = root.appendingPathComponent("timeline-workspace")
        _ = try WorkspaceRepository(url: timelineRoot).create(name: "Timeline")
        let timelineStore = AppStore(workspaceURL: timelineRoot)
        timelineStore.view = .timeline
        for (id, created) in [("A-late", "2026-09-15T11:00:00-04:00"), ("A-early", "2026-09-15T14:00:00Z"), ("A-z", "2026-09-15T15:00:00Z"), ("A-a", "2026-09-15T15:00:00Z")] {
            try timelineStore.saveRecord(ResearchNode(id: id, kind: .aim, title: id, createdAt: created), replacing: nil)
        }
        let chronologicalIDs = ["A-a", "A-z", "A-late", "A-early"]
        precondition(timelineStore.timelineNodes.map(\.id) == chronologicalIDs, "Use actual dates across time zones and creation-event order for ties")
        let old = timelineStore.workspace.node("A-late")!
        var edited = old; edited.title = "Edited much later"
        try timelineStore.saveRecord(edited, replacing: old)
        timelineStore.setStatus(edited, to: .complete)
        timelineStore.cycleRating(edited)
        precondition(timelineStore.view == .timeline && timelineStore.timelineNodes.map(\.id) == chronologicalIDs)
        timelineStore.deleteCard(timelineStore.workspace.node("A-z")!)
        precondition(timelineStore.timelineNodes.map(\.id) == ["A-a", "A-late", "A-early"])
        timelineStore.undoHierarchyDeletion()
        timelineStore.open(timelineRoot)
        precondition(timelineStore.timelineNodes.map(\.id) == chronologicalIDs)
        print("PASS timeline shows creation order across time zones, preserves ties and edits, and handles deletion, undo, and reopening")
        UserDefaults.standard.removeObject(forKey: "fieldwork.recentWorkspaces")
        let recents = AppStore(workspaceURL: root)
        recents.open(timelineRoot)
        recents.open(root)
        precondition(recents.recentWorkspaces.map(\.path) == [root.standardizedFileURL.path, timelineRoot.standardizedFileURL.path], "Most recent first, without duplicates")
        recents.open(root.appendingPathComponent("not-a-workspace"))
        precondition(recents.error != nil && recents.recentWorkspaces.count == 2, "A failed open is not remembered")
        recents.error = nil
        precondition(AppStore(workspaceURL: timelineRoot).recentWorkspaces.count == 2, "Recents persist across launches")
        recents.forgetRecentWorkspaces()
        precondition(recents.recentWorkspaces.isEmpty && UserDefaults.standard.stringArray(forKey: "fieldwork.recentWorkspaces") == nil)
        print("PASS recent workspaces are remembered most recent first, skip failed opens, persist, and can be cleared")
        let listRoot = root.appendingPathComponent("list-workspace")
        _ = try WorkspaceRepository(url: listRoot).create(name: "Lists")
        let lists = AppStore(workspaceURL: listRoot)
        for id in ["A-1", "A-2", "A-3"] { try lists.saveRecord(ResearchNode(id: id, kind: .aim, title: id), replacing: nil) }
        lists.toggle(lists.workspace.node("A-1")!)
        let selectionBeforeTyping = lists.selectedID
        precondition(lists.quickAddQuestion("  First typed  ", to: "A-1") && lists.quickAddQuestion("Second typed", to: "A-1"))
        precondition(!lists.quickAddQuestion("   ", to: "A-1"), "An empty title creates nothing")
        precondition(lists.questions.map(\.title) == ["Second typed", "First typed"], "Typed questions are trimmed and lead the list")
        precondition(lists.selectedID == selectionBeforeTyping && lists.questionID == nil && lists.editor == nil, "Typing a question keeps the view where it is")
        lists.newNode(.question, parentID: "A-1", title: "Needs details")
        precondition(lists.editor?.title == "Needs details" && lists.editor?.kind == .question)
        precondition(lists.editor!.suggestedOrder(parentID: "A-1", workspace: lists.workspace) < lists.questions[0].order)
        lists.editor = nil
        let listDisk = try WorkspaceRepository(url: listRoot).load()
        precondition(listDisk.children("A-1").map(\.title) == ["Second typed", "First typed"])
        print("PASS typing a title adds a question at the top without moving the selection, and the editor opens prefilled")

        func layoutAims(divider: Bool) {
            var frames: [String: CGRect] = [:]
            for (index, aim) in lists.activeAims.enumerated() { frames[aim.id] = CGRect(x: 0, y: CGFloat(index) * 40, width: 200, height: 38) }
            let dividerY = CGFloat(lists.activeAims.count) * 40 + 26
            if divider { frames[AppStore.aimsDividerID] = CGRect(x: 0, y: dividerY, width: 200, height: 28) }
            for (index, aim) in lists.completedAims.enumerated() { frames[aim.id] = CGRect(x: 0, y: dividerY + 30 + CGFloat(index) * 40, width: 200, height: 38) }
            lists.rowFrames = frames
        }
        precondition(lists.aims.map(\.id) == ["A-1", "A-2", "A-3"] && lists.completedAims.isEmpty)
        layoutAims(divider: false)
        let beforeAimDrag = lists.workspace
        lists.updateAimDrag("A-3", translation: CGSize(width: 0, height: -10))
        precondition(lists.aimSectionsWhileDragging.active.map(\.id) == ["A-1", "A-2", "A-3"] && !lists.finishAimDrag() && lists.workspace == beforeAimDrag, "A wobble writes nothing")
        lists.updateAimDrag("A-3", translation: CGSize(width: 0, height: -90))
        precondition(lists.aimSectionsWhileDragging.active.map(\.id) == ["A-3", "A-1", "A-2"] && lists.workspace == beforeAimDrag, "Hovering does not write")
        lists.cancelAimDrag()
        precondition(lists.aimDrag == nil && lists.aims.map(\.id) == ["A-1", "A-2", "A-3"])
        lists.updateAimDrag("A-3", translation: CGSize(width: 0, height: -90))
        precondition(lists.finishAimDrag() && lists.aims.map(\.id) == ["A-3", "A-1", "A-2"])
        layoutAims(divider: false)
        lists.updateAimDrag("A-1", translation: CGSize(width: 0, height: 120))
        precondition(lists.aimDrag?.completed == true, "Below the last aim and its add row is the completed group, even before a divider exists")
        precondition(lists.aimSectionsWhileDragging.active.map(\.id) == ["A-3", "A-2"] && lists.aimSectionsWhileDragging.completed.map(\.id) == ["A-1"])
        precondition(lists.finishAimDrag())
        precondition(lists.workspace.node("A-1")?.status == .complete && lists.completedAims.map(\.id) == ["A-1"] && lists.activeAims.map(\.id) == ["A-3", "A-2"])
        precondition(lists.expandedAimID == "A-1", "Completing an aim leaves it open")
        lists.setStatus(lists.workspace.node("A-2")!, to: .complete)
        precondition(lists.completedAims.map(\.id) == ["A-2", "A-1"], "Mark Done also files an aim under Completed")
        layoutAims(divider: true)
        lists.updateAimDrag("A-1", translation: CGSize(width: 0, height: -50))
        precondition(lists.aimDrag?.completed == true && lists.aimSectionsWhileDragging.completed.map(\.id) == ["A-1", "A-2"], "Completed aims reorder among themselves")
        lists.cancelAimDrag()
        lists.updateAimDrag("A-2", translation: CGSize(width: 0, height: -150))
        precondition(lists.aimDrag?.completed == false && lists.aimSectionsWhileDragging.active.map(\.id) == ["A-2", "A-3"])
        precondition(lists.finishAimDrag())
        let reopened = lists.workspace.node("A-2")!
        precondition(reopened.status == .active && reopened.finishedAt.isEmpty && !lists.workspace.manualStatusIDs.contains("A-2"), "Dragging back above the divider reopens the aim")
        let arranged = try WorkspaceRepository(url: listRoot).load()
        precondition(arranged.nodes.filter { $0.kind == .aim }.sorted { $0.order < $1.order }.map(\.id) == ["A-2", "A-3", "A-1"])
        precondition(AppStore(workspaceURL: listRoot).aims.map(\.id) == ["A-2", "A-3", "A-1"], "The arrangement survives reopening")
        try lists.saveRecord(ResearchNode(id: "A-4", kind: .aim, order: EditorRequest(kind: .aim, parentID: "").suggestedOrder(parentID: "", workspace: lists.workspace), title: "A-4"), replacing: nil)
        precondition(lists.activeAims.map(\.id) == ["A-2", "A-3", "A-4"], "New aims join the end of the active group")
        print("PASS aims reorder by dragging, complete below the divider, reopen above it, and persist their arrangement")

        let stepRoot = root.appendingPathComponent("steps-workspace")
        _ = try WorkspaceRepository(url: stepRoot).create(name: "Steps", sample: true)
        let stepStore = AppStore(workspaceURL: stepRoot)
        stepStore.reveal(stepStore.workspace.node("T-003")!)
        precondition(stepStore.questionID == "Q-001")
        func layoutSteps() {
            var frames: [String: CGRect] = [:]
            var y: CGFloat = 0
            for step in stepStore.workspace.steps("Q-001") {
                frames[step.id] = CGRect(x: 0, y: y, width: 300, height: 38); y += 40
                for result in stepStore.workspace.children(step.id) { frames[result.id] = CGRect(x: 0, y: y, width: 300, height: 30); y += 32 }
            }
            stepStore.rowFrames = frames
        }
        layoutSteps()
        let stepsBefore = stepStore.workspace.steps("Q-001").map(\.id)
        precondition(stepStore.stepsWhileDragging.map(\.id) == stepsBefore)
        let untouched = stepStore.workspace
        stepStore.updateStepDrag("ANS-001", translation: CGSize(width: 0, height: -12))
        precondition(stepStore.stepsWhileDragging.map(\.id) == stepsBefore && !stepStore.finishStepDrag() && stepStore.workspace == untouched, "A wobble writes nothing")
        stepStore.updateStepDrag("ANS-001", translation: CGSize(width: 0, height: -44))
        precondition(stepStore.stepsWhileDragging.map(\.id) == ["T-001", "T-002", "ANS-001", "T-003", "C-001"], "Rows slide once the dragged step passes a neighbour's centre")
        precondition(stepStore.workspace == untouched, "Hovering does not write")
        stepStore.cancelStepDrag()
        precondition(stepStore.stepDrag == nil && stepStore.workspace.steps("Q-001").map(\.id) == stepsBefore)
        stepStore.updateStepDrag("ANS-001", translation: CGSize(width: 0, height: -44))
        precondition(stepStore.finishStepDrag() && stepStore.workspace.steps("Q-001").map(\.id) == ["T-001", "T-002", "ANS-001", "T-003", "C-001"])
        precondition(stepStore.questionID == "Q-001" && stepStore.selectedID == "T-003", "Reordering leaves the selection alone")
        layoutSteps()
        // The conclusion keeps to its own section: dragging it to the top changes nothing, and a task cannot be dropped below it.
        stepStore.updateStepDrag("C-001", translation: CGSize(width: 0, height: -400))
        precondition(stepStore.stepsWhileDragging.last?.id == "C-001" && !stepStore.finishStepDrag())
        stepStore.updateStepDrag("T-003", translation: CGSize(width: 0, height: 400))
        precondition(stepStore.stepsWhileDragging.map(\.id) == ["T-001", "T-002", "ANS-001", "T-003", "C-001"] && !stepStore.finishStepDrag())
        // Dragging the finished first task past its results and the next two steps lands it below the unfinished answer, so it keeps its state as an override.
        stepStore.updateStepDrag("T-001", translation: CGSize(width: 0, height: 150))
        precondition(stepStore.stepsWhileDragging.map(\.id) == ["T-002", "ANS-001", "T-001", "T-003", "C-001"])
        precondition(stepStore.finishStepDrag() && stepStore.workspace.steps("Q-001").map(\.id) == ["T-002", "ANS-001", "T-001", "T-003", "C-001"])
        precondition(stepStore.workspace.node("T-001")?.status == .complete && stepStore.workspace.manualStatusIDs == ["T-001"])
        precondition(stepStore.workspace.children("T-001").map(\.id) == ["R-001"] && stepStore.workspace.nextStep("Q-001")?.id == "ANS-001")
        let stepsOnDisk = try WorkspaceRepository(url: stepRoot).load()
        precondition(stepsOnDisk == stepStore.workspace)
        print("PASS steps reorder by dragging within their question, without writing until release")

        // A fixed workspace: record IDs seed the layout, and the shared workspace has random ones by now.
        var graphWorkspace = Workspace()
        for a in 1...3 {
            try graphWorkspace.add(ResearchNode(id: "GA-\(a)", kind: .aim, title: "Aim \(a)"))
            for q in 1...3 {
                try graphWorkspace.add(ResearchNode(id: "GQ-\(a)\(q)", kind: .question, parentID: "GA-\(a)", order: q, title: "Question"))
                for t in 1...4 { try graphWorkspace.add(ResearchNode(id: "GT-\(a)\(q)\(t)", kind: .task, parentID: "GQ-\(a)\(q)", order: t, title: "Task")) }
            }
        }
        let graphNodes = SpringLayout.nodes(in: graphWorkspace)
        precondition(graphNodes.count == graphWorkspace.nodes.filter { $0.kind != .result }.count, "Aims, questions, and steps are nodes; results are not")
        precondition(graphNodes.allSatisfy { node in node.parentID == nil ? node.level == 0 : graphNodes.firstIndex { $0.id == node.parentID }! < graphNodes.firstIndex { $0.id == node.id }! }, "Parents come before children")
        let spring = SpringLayout()
        spring.sync(graphNodes)
        var ticks = 0
        while spring.step() && ticks < 5000 { ticks += 1 }
        precondition(spring.settled && ticks < 5000, "The springs come to rest")
        precondition(spring.positions.count == graphNodes.count && spring.positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        func distance(_ a: String, _ b: String) -> CGFloat { hypot(spring.positions[a]!.x - spring.positions[b]!.x, spring.positions[a]!.y - spring.positions[b]!.y) }
        for node in graphNodes where node.level == 2 {
            let own = distance(node.id, node.parentID!)
            precondition(own < 90 && graphNodes.filter { $0.level == 1 && $0.id != node.parentID }.allSatisfy { distance(node.id, $0.id) > own }, "Each step sits nearest its own question")
        }
        func aim(_ node: SpringNode) -> String { node.level == 0 ? node.id : aim(graphNodes.first { $0.id == node.parentID }!) }
        var tightestWithin = CGFloat.infinity, tightestBetween = CGFloat.infinity
        for (i, a) in graphNodes.enumerated() {
            for b in graphNodes.dropFirst(i + 1) {
                precondition(distance(a.id, b.id) > 8, "Nodes do not pile up")
                if aim(a) == aim(b) { tightestWithin = min(tightestWithin, distance(a.id, b.id)) } else { tightestBetween = min(tightestBetween, distance(a.id, b.id)) }
            }
        }
        precondition(tightestBetween > 60 && tightestBetween > tightestWithin * 2, "Clear space separates one aim's subgraph from the next")
        let replay = SpringLayout(); replay.sync(graphNodes); while replay.step() {}
        precondition(replay.positions == spring.positions, "The same workspace always opens to the same picture")
        let resting = spring.positions
        spring.sync(graphNodes)
        precondition(spring.settled && spring.positions == resting, "An unchanged workspace does not restart the springs")
        try graphWorkspace.add(ResearchNode(id: "GT-new", kind: .task, parentID: "GQ-11", order: 99, title: "New task"))
        spring.sync(SpringLayout.nodes(in: graphWorkspace))
        precondition(!spring.settled && distance("GT-new", "GQ-11") < 60 && spring.positions["GA-3"] == resting["GA-3"], "A new node appears beside its parent without reshuffling the rest")
        spring.pinnedID = "GA-1"; spring.move("GA-1", to: CGPoint(x: 400, y: 0))
        for _ in 0..<50 { spring.step() }
        precondition(spring.positions["GA-1"] == CGPoint(x: 400, y: 0) && !spring.settled, "A dragged node stays under the pointer while the rest follow")
        spring.pinnedID = nil
        while spring.step() {}
        precondition(spring.settled)
        print("PASS the spring graph settles, keeps steps by their question, is repeatable, and follows additions and drags")

        let markdown = MarkdownBlock.parse("""
        # Findings

        A **strong** result with `inline_code` and [notes](https://example.com/notes).

        - First
          - Nested
        - Second

        3. Third
        4. Fourth

        > Quoted evidence

        ```python
        print("<result>")
        ```

        | Method | Value |
        | --- | ---: |
        | Baseline | 0.5 |
        | New | **0.7** |

        ---
        Final paragraph.
        """)
        guard case .heading(1) = markdown.first!.kind else { fatalError("Markdown heading was lost") }
        precondition(markdown.filter { $0.marker == "•" }.count == 3)
        precondition(markdown.first { String($0.text.characters) == "Nested" }?.listDepth == 2)
        precondition(markdown.contains { $0.marker == "3." } && markdown.contains { $0.marker == "4." })
        precondition(markdown.contains { $0.quoteDepth == 1 && String($0.text.characters) == "Quoted evidence" })
        let paragraph = markdown[1].text
        precondition(paragraph.runs.contains { $0.link?.absoluteString == "https://example.com/notes" })
        precondition(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        precondition(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        precondition(markdown.contains { if case .code("python") = $0.kind { return String($0.text.characters).contains("<result>") }; return false })
        let table = MarkdownSection.group(markdown).first { $0.blocks.first?.tableID != nil }!
        precondition(table.blocks.count == 6 && table.blocks.filter(\.tableHeader).count == 2)
        precondition(Set(table.blocks.compactMap(\.rowID)).count == 3)
        precondition(markdown.contains { if case .rule = $0.kind { return true }; return false })
        precondition(MarkdownBlock.parse("").isEmpty)
        precondition(String(MarkdownBlock.parse("Unfinished **markup")[0].text.characters).contains("**markup"))
        print("PASS Markdown renders structural blocks, nested and numbered lists, links, emphasis, literal code, and tables")
        print("All app checks passed")
    }
}
