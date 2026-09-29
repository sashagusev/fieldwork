import AppKit
import SwiftUI
import ResearchCore

struct ListsTestCanvas: View {
    var body: some View {
        ResearchLists()
            .frame(width: 900, height: 700, alignment: .topLeading)
            .background(Palette.card)
    }
}

// Posts real mouse events at the positions the rows report, in an offscreen window.
@main struct CheckListInteractions {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldwork-list-clicks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try WorkspaceRepository(url: root).create(name: "Click check", sample: true)
        let store = AppStore(workspaceURL: root)
        // Run once without and once with animated transitions; the app ships with them on.
        store.motion = ProcessInfo.processInfo.environment["FIELDWORK_CHECK_MOTION"] != nil
        precondition(store.mutate(action: "prepare_click_test") { try $0.add(ResearchNode(id: "AIM-other", kind: .aim, title: "Other aim")) })
        let host = NSHostingView(rootView: ListsTestCanvas().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        var number = 0
        func post(_ type: NSEvent.EventType, _ point: CGPoint) {
            number += 1
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: 700 - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(number) * 0.03, windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        func click(_ point: CGPoint) { post(.leftMouseDown, point); post(.leftMouseUp, point) }
        func frame(_ id: String) -> CGRect {
            guard let frame = store.rowFrames[id] else { fatalError("Row \(id) is not on screen") }
            return frame
        }
        func title(_ id: String) -> CGPoint { CGPoint(x: frame(id).midX, y: frame(id).minY + 12) }
        // Steps run one after another. Each waits for the previous step's mouse events to be handled, rather than trusting a fixed delay on a busy machine.
        var steps: [@MainActor () -> Void] = []
        var drop = CGPoint.zero
        var eventsBeforeWobble = 0
        func then(_ action: @escaping @MainActor () -> Void) { steps.append(action) }
        func runNext(after delay: TimeInterval = 0.3, patience: Int = 100) {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated {
                if patience > 0, NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: false) != nil { return runNext(after: 0.05, patience: patience - 1) }
                guard !steps.isEmpty else { return }
                steps.removeFirst()()
                runNext()
            } }
        }
        then {
            precondition(store.rowFrames["AIM-001"] != nil && store.rowFrames["Q-001"] == nil, "Only aims show at first")
            click(title("AIM-001"))
        }
        then {
            precondition(store.expandedAimID == "AIM-001" && store.questionID == nil)
            precondition(store.workspace.progress(store.workspace.node("Q-002")!) == .staged)
            click(RowMetrics.bulletCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.node("Q-002")?.status == .running, "First click: working")
            precondition(store.questionID == nil && store.selectedID != "Q-002", "A bullet click does not open the question")
            click(RowMetrics.ratingCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.ratings.isEmpty, "No rating control until the work is done")
            click(RowMetrics.bulletCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.node("Q-002")?.status == .complete, "Second click: done")
            click(RowMetrics.ratingCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.ratings.isEmpty, "The thumb stays tucked away until the pointer is over the bullet")
            // Synthetic clicks do not move the pointer, so stand in for the hover.
            store.ratingRevealID = "Q-002"
        }
        then {
            click(RowMetrics.ratingCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.ratings["Q-002"] == .up)
            click(RowMetrics.ratingCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.ratings["Q-002"] == .down)
            click(RowMetrics.ratingCenter(in: frame("Q-002")))
        }
        then {
            precondition(store.workspace.ratings["Q-002"] == nil, "Third click returns to neutral")
            click(title("Q-001"))
        }
        then {
            precondition(store.questionID == "Q-001" && store.rowFrames["T-001"] != nil && store.rowFrames["R-001"] != nil)
            precondition(frame("AIM-001").maxX <= 0 && frame("T-001").maxX <= 900 && frame("Q-001").minX >= 0, "Opening a question slides the aims away to show questions and steps")
            precondition(store.workspace.node("T-003")?.status == .planned)
            click(RowMetrics.bulletCenter(in: frame("T-003")))
        }
        then {
            precondition(store.workspace.node("T-003")?.status == .running && store.selectedID == "Q-001")
            precondition(frame("C-001").minY > store.rowFrames[AppStore.stepsDividerID]!.maxY - 1, "Conclusions sit below their divider")
            // Drag the answer above the running task.
            drop = CGPoint(x: title("T-003").x, y: frame("T-003").minY + 4)
            post(.leftMouseDown, title("ANS-001"))
            post(.leftMouseDragged, CGPoint(x: title("ANS-001").x, y: title("ANS-001").y - 10))
            post(.leftMouseDragged, drop)
        }
        then {
            precondition(store.stepDrag?.insertionIndex == 2 && frame("T-003").minY > frame("ANS-001").minY, "The task slides down to open the gap")
            precondition(store.workspace.steps("Q-001").map(\.id) == ["T-001", "T-002", "T-003", "ANS-001", "C-001"], "Hovering does not write")
            post(.leftMouseUp, drop)
        }
        then {
            precondition(store.workspace.steps("Q-001").map(\.id) == ["T-001", "T-002", "ANS-001", "T-003", "C-001"] && store.stepDrag == nil && store.selectedID == "Q-001")
            // Drag the second question above the first. Rows slide during the drag, so fix the drop point now.
            drop = CGPoint(x: title("Q-001").x, y: frame("Q-001").minY + 4)
            post(.leftMouseDown, title("Q-002"))
            post(.leftMouseDragged, CGPoint(x: title("Q-002").x, y: title("Q-002").y - 10))
            post(.leftMouseDragged, drop)
        }
        then {
            precondition(store.questionDrag?.insertionIndex == 0 && store.questionDrag?.validDrop == true)
            precondition(store.workspace.children("AIM-001").map(\.id) == ["Q-001", "Q-002"], "Hovering does not write")
            precondition(frame("Q-001").minY > frame("Q-002").minY, "The first question slides down to open the gap")
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/live-drag-preview.png"))
            }
            post(.leftMouseUp, drop)
        }
        then {
            precondition(store.workspace.children("AIM-001").map(\.id) == ["Q-002", "Q-001"] && store.questionDrag == nil)
            post(.leftMouseDown, title("Q-001"))
            post(.leftMouseDragged, CGPoint(x: 880, y: 650))
            post(.leftMouseUp, CGPoint(x: 880, y: 650))
        }
        then {
            precondition(store.workspace.children("AIM-001").map(\.id) == ["Q-002", "Q-001"] && store.questionDrag == nil, "Releasing outside cancels")
            // A small wobble is not a reorder: nothing moves and nothing is selected or written.
            eventsBeforeWobble = store.workspace.events.count
            post(.leftMouseDown, title("Q-001"))
            post(.leftMouseDragged, CGPoint(x: title("Q-001").x + 4, y: title("Q-001").y - 9))
            post(.leftMouseUp, CGPoint(x: title("Q-001").x + 4, y: title("Q-001").y - 9))
        }
        then {
            precondition(store.workspace.events.count == eventsBeforeWobble && store.questionDrag == nil && store.questionID == "Q-001", "A reorder and a wobble leave the open question alone")
            click(title("Q-001"))
        }
        then {
            precondition(store.questionID == nil && frame("AIM-other").minX >= 0, "Closing the question slides back to the aims")
            // Drag the second aim above the first.
            drop = CGPoint(x: title("AIM-001").x, y: frame("AIM-001").minY + 4)
            post(.leftMouseDown, title("AIM-other"))
            post(.leftMouseDragged, CGPoint(x: title("AIM-other").x, y: title("AIM-other").y - 10))
            post(.leftMouseDragged, drop)
        }
        then {
            precondition(store.aimDrag?.insertionIndex == 0 && store.rowFrames[AppStore.aimsDividerID] != nil, "The Completed divider appears as a target while an aim is dragged")
            precondition(frame("AIM-001").minY > frame("AIM-other").minY, "The first aim slides down to open the gap")
            post(.leftMouseUp, drop)
        }
        then {
            precondition(store.aims.map(\.id) == ["AIM-other", "AIM-001"] && store.aimDrag == nil && store.expandedAimID == "AIM-001")
            precondition(store.rowFrames[AppStore.aimsDividerID] == nil, "No divider without completed aims")
            // Drag the last aim down past the add row into Completed.
            drop = CGPoint(x: title("AIM-001").x, y: title("AIM-001").y + 110)
            post(.leftMouseDown, title("AIM-001"))
            post(.leftMouseDragged, CGPoint(x: title("AIM-001").x, y: title("AIM-001").y + 10))
            post(.leftMouseDragged, CGPoint(x: drop.x, y: drop.y - 30))
            post(.leftMouseDragged, drop)
        }
        then {
            precondition(store.aimDrag?.completed == true, "The drag survives crossing the divider")
            precondition(frame("AIM-001").minY > store.rowFrames[AppStore.aimsDividerID]!.maxY - 1, "Its gap opens below the divider")
            post(.leftMouseUp, drop)
        }
        then {
            precondition(store.workspace.node("AIM-001")?.status == .complete && store.completedAims.map(\.id) == ["AIM-001"] && store.aimDrag == nil)
            precondition(store.rowFrames[AppStore.aimsDividerID] != nil && store.expandedAimID == "AIM-001")
            // And back above it to reopen.
            drop = CGPoint(x: title("AIM-other").x, y: frame("AIM-other").minY + 4)
            post(.leftMouseDown, title("AIM-001"))
            post(.leftMouseDragged, CGPoint(x: title("AIM-001").x, y: title("AIM-001").y - 10))
            post(.leftMouseDragged, drop)
        }
        then {
            precondition(store.aimDrag?.completed == false && store.aimDrag?.insertionIndex == 0)
            post(.leftMouseUp, drop)
        }
        then {
            precondition(store.workspace.node("AIM-001")?.status == .active && store.aims.map(\.id) == ["AIM-001", "AIM-other"] && store.completedAims.isEmpty)
            post(.leftMouseDown, title("Q-002"))
            post(.leftMouseDragged, CGPoint(x: title("Q-002").x - 10, y: title("Q-002").y))
            post(.leftMouseDragged, title("AIM-other"))
        }
        then {
            precondition(store.questionDrag?.targetAimID == "AIM-other")
            post(.leftMouseUp, title("AIM-other"))
        }
        then {
            precondition(store.workspace.node("Q-002")?.parentID == "AIM-other" && store.expandedAimID == "AIM-other")
            // The new-question field sits directly above the first question; its pencil opens the full editor.
            click(CGPoint(x: frame("Q-002").maxX - 17, y: frame("Q-002").minY - 14))
        }
        then {
            precondition(store.editor?.kind == .question && store.editor?.parentID == "AIM-other")
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        runNext()
        NSApp.run()
        let disk = try WorkspaceRepository(url: root).load()
        precondition(disk.node("Q-002")?.status == .complete && disk.node("T-003")?.status == .running && disk.ratings.isEmpty)
        precondition(disk.children("AIM-001").map(\.id) == ["Q-001"] && disk.node("Q-002")?.parentID == "AIM-other")
        window.orderOut(nil)
        print("PASS native mouse interactions\(store.motion ? " with animations" : ""): expanding lists, status bullets, rating toggle, drag reorder, outside cancellation, step reorder, aim reorder, completing and reopening an aim by dragging, cross-aim move, and the new-question field")
    }
}
