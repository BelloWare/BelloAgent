import XCTest
import SwiftUI
@testable import PiApp

/// Native transcript work is driven by that transcript's revision, not by
/// another session's cost/queue update repainting its containing workspace.
final class TranscriptUpdateIsolationTests: XCTestCase {
    private func messages(_ count: Int = 50) -> [TranscriptMessage] {
        (0..<count).map { index in
            TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                              text: "Row \(index). " + String(repeating: "Keep this conversation's exact native layout and selectable text. ", count: 5),
                              turn: "m\(index - index % 2)")
        }
    }

    @MainActor func testRetainedRowActionsUseTheNewestPaneCallbacks() {
        var calls: [String] = []
        var relay: TranscriptActionRelay? = TranscriptActionRelay()
        relay?.current = TranscriptActions(inspect: { calls.append("old:" + $0) })
        let retained = relay!.forwarded
        retained.inspect("before")
        relay?.current = TranscriptActions(inspect: { calls.append("inspect:" + $0) },
                                           edit: { calls.append("edit:" + $0) },
                                           copyMessage: { calls.append("copy:" + $0) },
                                           stop: { calls.append("stop") }, retry: { calls.append("retry") })
        retained.inspect("after"); retained.edit("message"); retained.copyMessage("message")
        retained.stop(); retained.retry()
        XCTAssertEqual(calls, ["old:before", "inspect:after", "edit:message", "copy:message", "stop", "retry"],
                       "A skipped content repaint must still update every retained row action")
        relay = nil
        retained.inspect("closed")
        XCTAssertEqual(calls.count, 6, "A stale row must not keep its closed conversation's action owner alive")
    }

    @MainActor func testOtherSessionRepaintsDoNotReconcileUnchangedHistory() {
        let session = SessionDisplay(id: "stable-visible-session")
        session.messages = messages()
        let page = TranscriptPage()
        page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        let environment = TranscriptRowEnvironment()
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: environment)
        let rows = document.retainedRows.map(ObjectIdentifier.init)
        let reconciliations = document.contentReconciliationCount
        let updates = document.updateInvocationCount

        // Five sessions can update the surrounding workspace repeatedly while
        // the visible conversation and its exact wrapping width stay unchanged.
        for _ in 0..<500 {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: environment)
        }
        XCTAssertEqual(document.updateInvocationCount - updates, 500)
        XCTAssertEqual(document.contentReconciliationCount, reconciliations,
                       "Unrelated workspace paints must not traverse or compare every retained message")
        XCTAssertEqual(document.retainedRows.map(ObjectIdentifier.init), rows)

        var disabled = environment
        disabled.isEnabled = false
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: disabled)
        XCTAssertEqual(document.contentReconciliationCount, reconciliations + 1,
                       "A disabled install/report overlay still has to reach every retained row")
        XCTAssertEqual(document.retainedRows.map(ObjectIdentifier.init), rows,
                       "Environment updates retain native selection/disclosure hosts")

        session.messages[session.messages.count - 1].text += " A new reply revision."
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: disabled)
        XCTAssertEqual(document.contentReconciliationCount, reconciliations + 2,
                       "The transcript's own revision always reaches its native rows")
    }

    @MainActor func testTailReflowDoesNotTraverseDetachedNativeRowTrees() async throws {
        let session = SessionDisplay(id: "tail-reflow")
        session.messages = messages()
        let page = TranscriptPage()
        page.state = "running"
        page.bind(session)
        let scroll = TranscriptNativeScrollView()
        let document = TranscriptNativeDocument(page: page)
        scroll.documentView = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // A page this long comes up with its viewport exact and measures
            // the rest in slices; the tail reflow under test is the one that
            // happens once it has finished.
            if document.frame.height > 3_000, document.retainedRows.count == 75,
               document.approximateRowCount == 0,
               document.retainedRows.filter({ $0.superview == nil }).count > 35 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(document.retainedRows.count, 75, "25 turns each own a question, persistent work row and prose row")
        XCTAssertGreaterThan(document.retainedRows.filter { $0.superview == nil }.count, 35)
        // Let any initial host attachment validations finish before measuring
        // the synchronous layout caused by a content change to the last row.
        try await Task.sleep(for: .milliseconds(100))
        scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let before = document.retainedRows.map { ($0.itemID, $0.frame, $0.measurementCount) }
        let traversals = document.rowLayoutTraversalCount
        session.messages[session.messages.count - 1].text += "\n\nThe tail grew while the earlier history stayed unchanged."
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        document.layoutRows(width: scroll.contentSize.width)
        XCTAssertLessThan(document.rowLayoutTraversalCount - traversals, 20,
                          "A streaming tail must not recursively lay out every detached native history row")
        for (id, frame, measurements) in before.dropLast() {
            let row = try XCTUnwrap(document.retainedRows.first { $0.itemID == id })
            XCTAssertEqual(row.frame, frame, "Skipping offscreen native traversal preserves exact anchor geometry")
            XCTAssertEqual(row.measurementCount, measurements, "The exact earlier text layout is unchanged")
        }
    }
}
