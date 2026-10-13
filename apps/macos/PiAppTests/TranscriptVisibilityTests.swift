import AppKit
import XCTest
@testable import PiApp

final class TranscriptVisibilityTests: XCTestCase {
    @MainActor func testScrollingOnePaneNeverDetachesTheOtherPanesSelectedRow() async throws {
        func session(_ id: String) -> SessionDisplay {
            let view = SessionDisplay(id: id)
            // Related chats may contain the same message IDs: ownership is
            // the document instance, not membership by message ID alone.
            view.messages = (0..<40).map { TranscriptMessage(id: "m\($0)", role: "user", text: String(repeating: "Selectable words ", count: 20)) }
            return view
        }
        let parent = TranscriptStressTestCase.Stage(session("parent"))
        let side = TranscriptStressTestCase.Stage(session("side"))
        defer { side.close(); parent.close() }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 1640, height: 560))
        parent.window.contentView = host
        parent.window.setContentSize(host.frame.size)
        host.addSubview(parent.scroll); host.addSubview(side.scroll)
        parent.scroll.frame = CGRect(x: 0, y: 0, width: 820, height: 560)
        side.scroll.frame = CGRect(x: 820, y: 0, width: 820, height: 560)
        await parent.settleUntilExact(); await side.settleUntilExact()
        for (focused, scrolling) in [(parent, side), (side, parent)] {
            focused.readerScroll(to: try XCTUnwrap(focused.row("m0")).frame.minY)
            scrolling.readerScroll(to: try XCTUnwrap(scrolling.row("m30")).frame.minY)
            await focused.settle(); await scrolling.settle()
            let row = try XCTUnwrap(focused.row("m0"))
            let text = try XCTUnwrap(TranscriptNativeDocument.textViews(in: row).first)
            XCTAssertTrue(parent.window.makeFirstResponder(text))
            text.setSelectedRange(NSRange(location: 1, length: 8))
            XCTAssertTrue(row.superview === focused.document)
            let origin = scrolling.scroll.contentView.bounds.origin
            scrolling.scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y + 1))
            XCTAssertTrue(scrolling.session.pinnedHistoryIDs.isEmpty, "Another pane's selection must not pin this pane's history")
            XCTAssertTrue(parent.window.makeFirstResponder(scrolling.scroll))
            scrolling.scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: origin.y + 2))
            XCTAssertTrue(row.superview === focused.document, "Scrolling after focus moves must not detach the other pane's row")
            XCTAssertTrue(text.isDescendant(of: row), "The other pane must keep its text host")
        }
    }

    @MainActor func testTinyScrollsVisitTheViewportInsteadOfEveryResidentRow() async throws {
        var visits: [Int] = []
        for count in [50, 500] {
            let session = SessionDisplay(id: "visibility-\(count)")
            session.messages = (0..<count).map { TranscriptMessage(id: "m\($0)", role: "user", text: String(repeating: "visible words ", count: 20)) }
            let stage = TranscriptStressTestCase.Stage(session)
            await stage.settleUntilExact()
            let middle = try XCTUnwrap(stage.rows.dropFirst(count / 2).first)
            stage.readerScroll(to: middle.frame.minY)
            let start = stage.scrollY, before = stage.document.visibilityRowVisitCount
            for step in 1...100 {
                stage.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: start + CGFloat(step) / 10))
            }
            let countVisits = stage.document.visibilityRowVisitCount - before
            visits.append(countVisits)
            print("SCROLL-25 resident=\(count) visits=\(countVisits) mounted=\(stage.document.subviews.count)")
            XCTAssertFalse(stage.document.subviews.isEmpty)
            stage.close()
        }
        XCTAssertGreaterThan(visits[0], 0, "The native scroll observer ran")
        XCTAssertLessThanOrEqual(visits[1], visits[0] * 2, "Warm visibility work must not grow tenfold with resident history")
        XCTAssertLessThan(visits[1], 10_000)
    }
}
