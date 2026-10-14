import AppKit
import XCTest
@testable import PiApp

final class TranscriptHeightSamplingTests: XCTestCase {
    @MainActor func testAnEqualSizedReplacementContributesItsMeasuredHeights() async throws {
        let session = SessionDisplay(id: "height-sampling")
        func install(prefix: String, words: Int) throws {
            let messages = (0..<500).map { TranscriptMessage(id: "\(prefix)\($0)", role: "user", text: String(repeating: "measured words ", count: words)) }
            var page = try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]),
                "incarnation": .string("fixture"), "lineage": .string("root"), "older": .null, "newer": .null]))
            page.messages = messages; page.start = 500; page.total = 1_000
            page.older = ConversationCursor(incarnation: "fixture", lineage: "root", entry: messages[0].id)
            session.historyPositions.reset(page)
            session.olderPage = .init(cursor: page.older)
            session.messages = messages
        }
        try install(prefix: "short", words: 1)
        let stage = TranscriptStressTestCase.Stage(session)
        defer { stage.close() }
        await stage.settleUntilExact()
        let short = stage.rows.reduce(CGFloat(0)) { $0 + $1.frame.height } / 500
        stage.page.measuredHistoryRowHeight(short, over: 500, width: try XCTUnwrap(stage.rows.first).frame.width)
        try install(prefix: "tall", words: 100)
        stage.refresh()
        await stage.settleUntilExact()
        print("SCROLL-13 short=\(short) initial replacement=\(stage.page.historyRowHeight ?? 0)")
        try await eventually("The equal-sized window never updates the history height") {
            stage.draw(); return (stage.page.historyRowHeight ?? 0) > short * 2
        }
        let measured = try XCTUnwrap(stage.page.historyRowHeight)
        print("SCROLL-13 short=\(short) replacement=\(measured) sample=\(stage.page.historyRowHeightSample)")
        XCTAssertGreaterThan(measured, short * 2)
        XCTAssertEqual(stage.rows.count, 500)
    }
}
