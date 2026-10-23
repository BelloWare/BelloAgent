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

    /// Turns of a question and `work` rows each: q0, w0_0, w0_1, …, q1, …
    private func turns(_ count: Int, work: Int) -> [TranscriptMessage] {
        (0..<count).flatMap { turn in
            [TranscriptMessage(id: "q\(turn)", role: "user", text: "Question \(turn)")] + (0..<work).map { row("w\(turn)_\($0)") }
        }
    }
    @MainActor private func withCaps(rows: Int, _ body: () throws -> Void) rethrows {
        let caps = TranscriptPaging.residentCaps
        defer { TranscriptPaging.residentCaps = caps }
        TranscriptPaging.residentCaps = (rows: rows, bytes: caps.bytes)
        try body()
    }

    /// The resident window lets go of whole turns (0.1.131): a turn it holds
    /// reads as it does whole, its work folded behind one line. Cut row by
    /// row, a window kept the end of a turn without its question, and that
    /// turn showed every call until the question was read in again.
    @MainActor func testTheResidentWindowLetsGoOfWholeTurns() {
        let page = turns(6, work: 4) // 30 rows, turns of 5
        withCaps(rows: 13) {
            // The newest rows: two whole turns, not the last three rows of a third.
            XCTAssertEqual(TranscriptPaging.window(page, keepingEarlier: false).map(\.id), page.suffix(10).map(\.id))
            XCTAssertEqual(TranscriptPaging.window(page, keepingEarlier: false).first?.id, "q4")
            // The earliest rows: two whole turns, ending before the next question.
            XCTAssertEqual(TranscriptPaging.window(page, keepingEarlier: true).map(\.id), page.prefix(10).map(\.id))
            XCTAssertTrue(TranscriptPaging.endsTurn(Array(page.prefix(10)), in: page))
            XCTAssertFalse(TranscriptPaging.endsTurn(Array(page.prefix(9)), in: page))
            XCTAssertFalse(TranscriptPaging.endsTurn(page, in: page), "the last row of everything held says nothing about what follows")
        }
        // A turn longer than the caps on its own is cut where they fall: no
        // window holds it whole, and letting all of it go would leave nothing.
        let giant = turns(1, work: 3) + turns(1, work: 30).map { message -> TranscriptMessage in
            var copy = message; copy.id = "g" + message.id; return copy
        }
        withCaps(rows: 13) {
            XCTAssertEqual(TranscriptPaging.window(giant, keepingEarlier: true).count, 13)
            XCTAssertEqual(TranscriptPaging.window(giant, keepingEarlier: false).count, 13)
        }
        // A window that starts inside a turn (the end of a turn longer than a
        // page) lets go of that partial turn first.
        withCaps(rows: 26) {
            XCTAssertEqual(TranscriptPaging.window(Array(page.dropFirst(2)), keepingEarlier: false).first?.id, "q1")
        }
    }

    /// An agent's delivery is a user row inside a turn, never where one
    /// starts: the window does not stop at it, as the fold does not.
    @MainActor func testAnAgentDeliveryIsNotWhereAWindowStarts() {
        var page = turns(4, work: 4)
        var delivery = TranscriptMessage(id: "delivery", role: "user", text: "Report", kind: "agent_message")
        delivery.nativeAgentDelivery = .object(["author": .string("subagent")])
        page[12] = delivery // inside the third turn (q2 at 10)
        XCTAssertFalse(TranscriptPaging.startsTurn(delivery))
        XCTAssertTrue(TranscriptPaging.startsTurn(page[10]))
        withCaps(rows: 9) {
            XCTAssertEqual(TranscriptPaging.window(page, keepingEarlier: false).first?.id, "q3", "not the delivery at 12")
        }
    }

    /// Kept rows on the reader's screen keep their whole turns, and the window
    /// grows by whole turns toward the side asked for.
    @MainActor func testKeepingTheRowsOnScreenKeepsTheirWholeTurns() {
        let page = turns(6, work: 4)
        withCaps(rows: 12) {
            // On screen: the middle of the fourth turn. Earlier rows are asked for.
            let kept = TranscriptPaging.window(page, keeping: ["w3_1", "w3_2"], keepingEarlier: true)
            XCTAssertEqual(kept?.first?.id, "q2"); XCTAssertEqual(kept?.last?.id, "w3_3")
            let newer = TranscriptPaging.window(page, keeping: ["w1_1"], keepingEarlier: false)
            XCTAssertEqual(newer?.first?.id, "q1"); XCTAssertEqual(newer?.last?.id, "w2_3")
        }
        // Rows on screen past the caps on their own: still nil.
        withCaps(rows: 3) {
            XCTAssertNil(TranscriptPaging.window(page, keeping: ["q0", "w0_3"], keepingEarlier: true))
        }
    }

    /// A turn too long for the window is cut, and a read toward the rest of
    /// it takes the rows of it nearest the screen that there is room for: it
    /// kept only the rows on screen, since the turn's other rows were more
    /// than the window has, added nothing, and the read was refused, in
    /// either direction (0.1.131 review: a 1,500-row turn, rows 750–759 on
    /// screen). A turn that fits the window on its own still comes whole or
    /// waits.
    @MainActor func testATurnTooLongForTheWindowGivesTheRowsThereIsRoomFor() throws {
        let long = turns(1, work: 1_499) // q0 and 1,499 rows
        try withCaps(rows: 750) {
            // Earlier rows of the turn, the screen at its rows 750–759.
            let top = Set(long[750..<760].map(\.id))
            let earlier = try XCTUnwrap(TranscriptPaging.window(long, keeping: top, keepingEarlier: true))
            XCTAssertEqual(earlier.map(\.id), long[10..<760].map(\.id))
            // Newer rows of it, the screen at its rows 740–749.
            let bottom = Set(long[740..<750].map(\.id))
            let newer = try XCTUnwrap(TranscriptPaging.window(long, keeping: bottom, keepingEarlier: false))
            XCTAssertEqual(newer.map(\.id), long[740..<1490].map(\.id))
            // A turn too long for the window before the one on screen gives
            // its newest rows, as many as there is room for.
            let after = long + turns(2, work: 49).dropFirst(50) // q1 and 49 rows
            let short = Set(after.suffix(5).map(\.id))
            let joined = try XCTUnwrap(TranscriptPaging.window(after, keeping: short, keepingEarlier: true))
            XCTAssertEqual(joined.map(\.id), after[800...].map(\.id))
            XCTAssertEqual(TranscriptPaging.partialTurnInput(of: joined, in: after, fallback: nil), "q0")
        }
        // One that fits on its own but not beside the turn on screen waits.
        let page = turns(3, work: 4)
        try withCaps(rows: 8) {
            let kept = try XCTUnwrap(TranscriptPaging.window(page, keeping: ["w2_1"], keepingEarlier: true))
            XCTAssertEqual(kept.first?.id, "q2", "q1's turn waits: it would fit only on its own")
            XCTAssertNil(TranscriptPaging.partialTurnInput(of: kept, in: page, fallback: "q9"))
        }
    }

    func testHistoryProjectionKeepsClockTurnAndModelTime() {
        let projected = TranscriptMessage.project(id: "a1", message: ["role": .string("assistant"), "content": .string("Reply"), "timestamp": .number(1_700_000_000_000), "nativeTurn": .string("turn-9"), "nativeModelMs": .number(840)])
        XCTAssertEqual(projected.at, 1_700_000_000_000); XCTAssertEqual(projected.turn, "turn-9"); XCTAssertEqual(projected.modelMs, 840)
        let bare = TranscriptMessage.project(id: "u", message: ["role": .string("user"), "content": .string("Older journal")])
        XCTAssertNil(bare.at); XCTAssertNil(bare.turn); XCTAssertNil(bare.modelMs)
    }
}
