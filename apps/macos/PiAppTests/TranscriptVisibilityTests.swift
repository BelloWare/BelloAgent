import AppKit
import XCTest
@testable import PiApp

final class TranscriptVisibilityTests: XCTestCase {
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
