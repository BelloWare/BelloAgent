import XCTest
import AppKit
@testable import PiApp

final class NativeTranscriptSafetyTests: XCTestCase {
    @MainActor private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor private func scrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scroll.documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_200))
        return scroll
    }

    @MainActor private func drainDeferredUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testGeometryDrivenScrollWaitsUntilAfterTheNativeUpdate() async throws {
        let session = SessionDisplay(id: "geometry")
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Question")]
        let page = TranscriptPage(), scroll = scrollView()
        page.state = "running"; page.bind(session)
        page.attach(scroll, host: try XCTUnwrap(scroll.documentView))
        page.viewportChanged(CGSize(width: 600, height: 200))
        page.contentChanged(ContentGeometry(top: 0, height: 1_200))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, "Geometry callbacks must not move AppKit inside SwiftUI's layout pass")
        await drainDeferredUpdates()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1_000, accuracy: 0.5)
    }

    @MainActor func testRememberedAnchorWaitsForTheNativeScrollViewToAttach() async throws {
        let session = SessionDisplay(id: "restore")
        session.messages = [TranscriptMessage(id: "middle", role: "user", text: "Saved place"), TranscriptMessage(id: "last", role: "assistant", text: "Latest")]
        session.scrollAnchor = TranscriptAnchor(id: "middle", offset: 15, followsBottom: false)
        let page = TranscriptPage()
        page.bind(session)
        page.viewportChanged(CGSize(width: 600, height: 200))
        page.contentChanged(ContentGeometry(top: 0, height: 1_200))
        page.rowFrame("middle", CGRect(x: 0, y: 700, width: 600, height: 100))
        await drainDeferredUpdates()
        let scroll = scrollView()
        page.attach(scroll, host: try XCTUnwrap(scroll.documentView))
        await drainDeferredUpdates()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 685, accuracy: 0.5, "Reporting a row before ScrollViewFinder attaches must preserve its saved offset")
        XCTAssertFalse(page.followsBottom)
    }

    @MainActor func testReaderScrollSupersedesAnAnchorStillWaitingForItsRow() async throws {
        let session = SessionDisplay(id: "reader")
        session.messages = [TranscriptMessage(id: "middle", role: "user", text: "Saved place")]
        session.scrollAnchor = TranscriptAnchor(id: "middle", offset: 15, followsBottom: false)
        let page = TranscriptPage(), scroll = scrollView()
        page.bind(session)
        page.attach(scroll, host: try XCTUnwrap(scroll.documentView))
        page.viewportChanged(CGSize(width: 600, height: 200))
        page.contentChanged(ContentGeometry(top: 0, height: 1_200))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        page.rowFrame("middle", CGRect(x: 0, y: 700, width: 600, height: 100))
        await drainDeferredUpdates()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 200, accuracy: 0.5, "A saved anchor must not undo the reader's newer movement")
        XCTAssertFalse(page.followsBottom)
    }

    func testOversizedRetainedDurationDoesNotCrashTheTurnLine() throws {
        let json = Data(#"{"role":"assistant","content":"Retained answer","nativeModelMs":1e100}"#.utf8)
        let record = try JSONDecoder().decode([String: WireValue].self, from: json)
        let message = TranscriptMessage.project(id: "answer", message: record)
        let item = try XCTUnwrap(TranscriptActivity.blocks(of: [message]).first)
        guard case .block(let block) = item else { return XCTFail("Expected the retained assistant's block") }
        XCTAssertEqual(block.modelMs, 1e100, "The fixture must reach the formatter through the actual history projection")
        XCTAssertEqual(TranscriptActivity.formatDuration(block.modelMs), "")
        XCTAssertEqual(TranscriptActivity.formatDuration(try XCTUnwrap(block.taskSummary).modelMs), "")
        XCTAssertEqual(TranscriptActivity.formatDuration(Double.greatestFiniteMagnitude), "")
        XCTAssertEqual(TranscriptActivity.formatDuration(72_000), "1m 12s")
    }

    func testTranscriptNumberFormattingHandlesUnrepresentableAndSignedBoundaryValues() {
        for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertEqual(TranscriptActivity.grouped(value), "—")
        }
        XCTAssertEqual(TranscriptActivity.grouped(Double(Int.min)), "-9,223,372,036,854,775,808", "Signed magnitude must not overflow for Int.min")
        XCTAssertEqual(TranscriptActivity.grouped(1_234.5), "1,235")
        for value in [Double.nan, .infinity, -.infinity, -Double.greatestFiniteMagnitude] {
            XCTAssertEqual(TranscriptActivity.formatCompactTokens(value), "—")
        }
        XCTAssertEqual(TranscriptActivity.formatCompactTokens(1_500), "1.5k")
    }
}
