import XCTest
@testable import PiApp

final class TranscriptPagingTests: XCTestCase {
    private func row(_ id: String) -> TranscriptMessage { TranscriptMessage(id: id, role: "assistant", text: id) }

    func testLivePageKeepsThePrependedRowsInFrontOfIt() {
        let shown = ["a", "b", "c", "d", "e"].map(row)
        let live = ["c", "d", "e", "f"].map(row)
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: live).map(\.id), ["a", "b", "c", "d", "e", "f"], "Earlier rows stay; the live window supplies the tail")
        XCTAssertEqual(TranscriptPaging.merge(previous: [], live: live).map(\.id), ["c", "d", "e", "f"])
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: ["a", "b", "c"].map(row)).map(\.id), ["a", "b", "c"], "A window that starts at the first shown row is the whole display")
    }

    func testUnverifiedNonoverlappingOrEmptyWindowKeepsRetainedHistory() {
        let shown = ["a", "b", "c"].map(row)
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: ["x", "y"].map(row)).map(\.id), ["a", "b", "c"], "Only a validated history reload can replace a branch or skip a gap")
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: []).map(\.id), ["a", "b", "c"])
    }

    func testALivePageThatStartsRightAfterTheLastShownRowJoinsIt() {
        let shown = ["a", "b", "long"].map(row)
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: ["q", "r"].map(row), follows: "long").map(\.id), ["a", "b", "long", "q", "r"],
                       "A page with no room for the long reply before it carries on from that reply")
        XCTAssertEqual(TranscriptPaging.merge(previous: shown, live: ["q", "r"].map(row), follows: "b").map(\.id), ["a", "b", "long"],
                       "A page that starts after an earlier row leaves a gap: the rows shown stay until a validated reload")
        XCTAssertTrue(TranscriptPaging.joins(shown, follows: "long"))
        XCTAssertFalse(TranscriptPaging.joins(shown, follows: nil)); XCTAssertFalse(TranscriptPaging.joins([], follows: "long"))
    }

    func testLiveWindowStartingBeforeSmallerSavedWindowStillUpdatesItsTail() {
        let shown = ["c", "d"].map(row)
        var live = ["a", "b", "c", "d", "e"].map(row)
        live[3].text = "Updated retained row"
        let merged = TranscriptPaging.merge(previous: shown, live: live)
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(merged[3].text, "Updated retained row")
    }

    func testEarlierPagesPrependOnlyUnknownRows() {
        let shown = ["c", "d"].map(row)
        XCTAssertEqual(TranscriptPaging.prefix(earlier: ["a", "b", "c"].map(row), shown: shown).map(\.id), ["a", "b"])
        XCTAssertTrue(TranscriptPaging.prefix(earlier: ["c", "d"].map(row), shown: shown).isEmpty)
    }

    func testHistoryProjectionKeepsClockTurnAndModelTime() {
        let projected = TranscriptMessage.project(id: "a1", message: ["role": .string("assistant"), "content": .string("Reply"), "timestamp": .number(1_700_000_000_000), "nativeTurn": .string("turn-9"), "nativeModelMs": .number(840)])
        XCTAssertEqual(projected.at, 1_700_000_000_000); XCTAssertEqual(projected.turn, "turn-9"); XCTAssertEqual(projected.modelMs, 840)
        let bare = TranscriptMessage.project(id: "u", message: ["role": .string("user"), "content": .string("Older journal")])
        XCTAssertNil(bare.at); XCTAssertNil(bare.turn); XCTAssertNil(bare.modelMs)
    }
}
