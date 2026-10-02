import XCTest
import AppKit
@testable import PiApp

// The queue panel beside a terminal and in a narrow split pane, reordering
// across its scroll, its detail view open while the message leaves, and
// image-only messages on the paths that take them.

extension ConversationPaneTests {
    @MainActor private func transcriptHeight(_ pane: Pane) throws -> CGFloat {
        try XCTUnwrap(Self.views(TranscriptSurfaceMarker.self, in: pane.hosted).first?.enclosingScrollView).frame.height
    }
    @MainActor private func queueList(_ pane: Pane) -> NSScrollView? {
        Self.views(NSScrollView.self, in: pane.hosted).first { String(describing: Swift.type(of: $0)).contains("ListCore") }
    }
    @MainActor private func withTerminalHeight(_ height: Double, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "terminalHeight")
        defaults.set(height, forKey: "terminalHeight")
        defer { if let previous { defaults.set(previous, forKey: "terminalHeight") } else { defaults.removeObject(forKey: "terminalHeight") }; TerminalRegistry.shared.shutdown() }
        try await body()
    }

    /// At the 920×600 minimum window, with a tall draft, a terminal open
    /// (at its default height and dragged tall) and twenty messages waiting
    /// (paused: no run card), the composer's field and the terminal give way
    /// so the transcript keeps about 150 points; the queue keeps a reachable
    /// row and the window keeps its size. While a turn runs, its card takes
    /// about 100 points more (docs/Swift-Test-Handoff.md, "Minimum window").
    @MainActor func testATallDraftATerminalAndAQueueLeaveTheTranscriptItsReadingSpace() async throws {
        for stored in [240.0, 520.0] {
            try await withTerminalHeight(stored) {
                let pane = try Pane(width: 920, height: 600); defer { pane.close() }
                pane.model.terminalVisible = true
                pane.session.state = "paused"; pane.session.queuePaused = true
                pane.session.queue = (0..<20).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
                pane.session.draft = (0..<20).map { "Line \($0) of a long draft" }.joined(separator: "\n")
                for _ in 0..<4 { await pane.settle(20); try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertEqual(pane.window.contentLayoutRect.height, 600, accuracy: 1, "the window keeps its size (terminal \(stored))")
                XCTAssertGreaterThanOrEqual(try transcriptHeight(pane), 145, "the transcript keeps its reading space (terminal \(stored))")
                let list = try XCTUnwrap(queueList(pane))
                XCTAssertGreaterThanOrEqual(list.frame.height, QueuePanel.rowHeight + QueuePanel.sectionHeaderHeight - 1, "a queued row stays reachable")
                let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
                XCTAssertLessThanOrEqual(field.frame.height, ComposerScrollView.besideTerminalHeight + 1, "the field gives way beside a terminal")
                XCTAssertEqual(UserDefaults.standard.double(forKey: "terminalHeight"), stored, "the height the terminal was dragged to is kept")
            }
        }
        // Without a terminal the field keeps its full height.
        let pane = try Pane(width: 920, height: 600); defer { pane.close() }
        pane.session.draft = (0..<20).map { "Line \($0)" }.joined(separator: "\n")
        await pane.settle(30)
        XCTAssertGreaterThan(try XCTUnwrap(pane.editor?.enclosingScrollView).frame.height, ComposerScrollView.besideTerminalHeight + 20)
    }

    /// In a narrow split pane with a terminal open, the queue keeps every
    /// message reachable inside its panel, off the composer.
    @MainActor func testTheQueueInANarrowSplitPaneWithATerminal() async throws {
        try await withTerminalHeight(240) {
            let pane = try Pane(width: 460, height: 700); defer { pane.close() }
            pane.model.terminalVisible = true
            pane.session.state = "running"
            pane.session.queue = (0..<5).map { ["turnId": .string("q\($0)"), "kind": .string($0 == 0 ? "steering" : "follow-up"), "text": .string("Message \($0): " + String(repeating: "words ", count: 20))] }
            for _ in 0..<3 { await pane.settle(20); try await Task.sleep(for: .milliseconds(100)) }
            let list = try XCTUnwrap(queueList(pane))
            XCTAssertGreaterThanOrEqual(list.frame.height, QueuePanel.rowHeight + QueuePanel.sectionHeaderHeight - 1)
            let field = try XCTUnwrap(pane.editor?.enclosingScrollView)
            XCTAssertFalse(list.convert(list.bounds, to: nil).intersects(field.convert(field.bounds, to: nil)), "the queue never covers the composer")
            XCTAssertEqual(pane.window.contentLayoutRect.height, 700, accuracy: 1)
            list.documentView?.scroll(NSPoint(x: 0, y: list.documentView?.bounds.maxY ?? 0))
            await pane.settle(8)
            let table = try XCTUnwrap(Self.views(NSTableView.self, in: list).first)
            XCTAssertTrue(list.contentView.documentVisibleRect.intersects(table.rect(ofRow: table.numberOfRows - 1)), "the last message can be scrolled to")
        }
    }

    /// The first of twenty follow-ups dragged past the end of the scrolled
    /// list goes last. A message removed or delivered during the drag: the
    /// helper refuses the stale order, nothing moves, and the chat says so.
    @MainActor func testReorderingAcrossTheScrollAndAQueueThatChangesDuringTheDrag() async throws {
        let pane = try Pane(width: 920, height: 600); defer { pane.close() }
        pane.session.state = "running"
        pane.session.queue = (0..<20).map { ["turnId": .string("q\($0)"), "kind": .string("follow-up"), "text": .string("Message \($0)")] }
        await pane.settle(16)
        let ids = QueuedMessage.from(pane.session.queue).map(\.id)
        let order = QueuePanel.reordered(ids, moving: IndexSet(integer: 0), to: ids.count)
        XCTAssertEqual(order.first, "q1"); XCTAssertEqual(order.last, "q0")
        pane.model.reorderQueued(order, sessionID: pane.session.id)
        try await waitFor("The reorder never landed") { QueuedMessage.from(pane.session.queue).map(\.id) == order }

        // The drag began with the order on screen; a message left meanwhile.
        let dragged = QueuePanel.reordered(QueuedMessage.from(pane.session.queue).map(\.id), moving: IndexSet(integer: 0), to: 20)
        pane.session.queue.removeAll { $0["turnId"]?.string == "q7" }
        let before = QueuedMessage.from(pane.session.queue).map(\.id)
        pane.model.reorderQueued(dragged, sessionID: pane.session.id)
        try await waitFor("The stale reorder was never refused") { pane.session.notice.contains("changed while you were dragging") }
        XCTAssertEqual(QueuedMessage.from(pane.session.queue).map(\.id), before, "nothing moved")
    }
}
