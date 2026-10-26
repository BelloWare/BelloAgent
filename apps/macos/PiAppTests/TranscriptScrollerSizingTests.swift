import AppKit
import XCTest
@testable import PiApp

final class TranscriptScrollerSizingTests: XCTestCase {
    @MainActor func testLegacyScrollersKeepTheColumnWidthAsAChatFillsAndChanges() async throws {
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(.normal)
        defer { TranscriptDisplay.use(previous) }
        let view = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.scrollView.scrollerStyle = .legacy
        // First lay out an empty page, as the pane does before its chat arrives.
        view.layoutSubtreeIfNeeded()
        let emptyWidth = view.scrollView.contentSize.width
        for chat in 0..<2 {
            let session = SessionDisplay(id: "scroller-\(UUID().uuidString)")
            session.historyState = .ready; session.draftReady = true
            session.messages = (0..<4).flatMap { turn -> [TranscriptMessage] in
                let q = "q\(chat)-\(turn)"
                return [.init(id: q, role: "user", text: "Question \(turn)", turn: q),
                        .init(id: "a\(chat)-\(turn)", role: "assistant", text: String(repeating: "The reply wraps in the reading column. ", count: 35), turn: q)]
            }
            view.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
            for _ in 0..<8 {
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(view.document.frame.height, view.scrollView.contentSize.height)
            XCTAssertEqual(view.scrollView.contentSize.width, emptyWidth, "the first rows already use the scroller's column width")
            let rows = ConversationPaneTests.views(TranscriptRowContainer.self, in: view.document)
            XCTAssertGreaterThan(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0.measurementCount == 1 }, "row measurements: \(rows.map(\.measurementCount))")
            let bodies = ConversationPaneTests.views(NativeMarkdownContainer.self, in: view.document)
            XCTAssertFalse(bodies.isEmpty)
            XCTAssertTrue(bodies.allSatisfy { $0.textLayouts == 1 }, "full text layouts: \(bodies.map(\.textLayouts))")
        }
        view.scrollView.scrollerStyle = .overlay
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.scrollView.autohidesScrollers)
        XCTAssertGreaterThan(view.scrollView.contentSize.width, emptyWidth)
        view.scrollView.scrollerStyle = .legacy
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.scrollView.autohidesScrollers)
        XCTAssertEqual(view.scrollView.contentSize.width, emptyWidth)
    }
}
