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
}
