import XCTest
import SwiftUI
@testable import PiApp

/// Who owns the reader's position, and what the page does with it.
///
/// The rule under test is the whole of it: every scroll the page performs is
/// written down before it is written to the clip view; an offset AppKit
/// delivers that the page did not write belongs to the reader; and whether
/// the page follows the newest row is decided by one band at the bottom —
/// leaving it unpins, coming back re-pins — and by nothing else.
final class TranscriptFollowOwnershipTests: XCTestCase {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    // MARK: The ledger on its own

    @MainActor func testTheLedgerTellsThePagesOwnScrollsFromTheReaders() {
        let ledger = TranscriptScrollLedger()
        // The first offset is where the reader stands; nobody moved them there.
        XCTAssertEqual(ledger.delivered(0, floor: 2_000), .unchanged)
        // A scroll the page wrote, delivered back.
        ledger.wrote(from: 0, to: 400)
        XCTAssertEqual(ledger.delivered(400, floor: 2_000), .page)
        // The same offset again is not a second movement.
        XCTAssertEqual(ledger.delivered(400, floor: 2_000), .unchanged)
        XCTAssertEqual(ledger.delivered(400.4, floor: 2_000), .unchanged, "a fraction of a point is not a movement")
        // Nothing explains this one, so it is the reader's.
        XCTAssertEqual(ledger.delivered(260, floor: 2_000), .reader)
        XCTAssertEqual(ledger.readerTakeoverCount, 1)
        // Rounding to the backing scale is still the page's own write.
        ledger.wrote(from: 260, to: 512)
        XCTAssertEqual(ledger.delivered(511.5, floor: 2_000), .page)
    }

    @MainActor func testAnAnimatedScrollOwnsEveryOffsetItPassesThrough() {
        let ledger = TranscriptScrollLedger()
        _ = ledger.delivered(0, floor: 2_000)
        ledger.wrote(from: 0, to: 900, animated: true)
        for offset in stride(from: 40.0, through: 880.0, by: 40) {
            XCTAssertEqual(ledger.delivered(CGFloat(offset), floor: 2_000), .page,
                           "an offset inside an animation the page started is the page's")
        }
        XCTAssertEqual(ledger.delivered(900, floor: 2_000), .page)
        XCTAssertEqual(ledger.readerTakeoverCount, 0, "an animation the page started is never the reader")
        // Once it has landed, the corridor is gone.
        XCTAssertEqual(ledger.delivered(500, floor: 2_000), .reader)
    }

    @MainActor func testTheLedgerIsEmptiedWhenTheReaderTouchesThePage() {
        let ledger = TranscriptScrollLedger()
        _ = ledger.delivered(0, floor: 2_000)
        ledger.wrote(from: 0, to: 300)
        ledger.forgetWrites()
        XCTAssertEqual(ledger.delivered(300, floor: 2_000), .reader, "a write from before the reader moved explains nothing after it")
        // A different conversation starts over: its first reading is a
        // baseline, not somebody's movement.
        ledger.reset()
        XCTAssertEqual(ledger.delivered(1_400, floor: 2_000), .unchanged)
        XCTAssertEqual(ledger.delivered(900, floor: 2_000), .reader)
    }

    /// A document that shrinks under a reader who was not standing at its end
    /// leaves them clamped onto the new end. Nobody scrolled: they did not
    /// choose the bottom, and reading the clamp as their own scroll would say
    /// they had, which pins the page there and takes their reading position
    /// away from them.
    @MainActor func testBeingClampedOntoTheNewEndIsNotChoosingTheBottom() {
        let ledger = TranscriptScrollLedger()
        // A reader 76 points above the end of an 861-point document.
        XCTAssertEqual(ledger.delivered(344.5, floor: 421), .unchanged)
        // The document loses 93 points under them, and 328 is all there is.
        XCTAssertEqual(ledger.delivered(328, floor: 328), .page,
                       "nobody can scroll past the end, so landing exactly on it from beyond it is the clamp")
        XCTAssertEqual(ledger.readerTakeoverCount, 0)
        // The rule is only that: arriving at the end from above it is a scroll.
        XCTAssertEqual(ledger.delivered(200, floor: 328), .reader)
        XCTAssertEqual(ledger.delivered(328, floor: 328), .reader,
                       "a reader scrolling down to the end is still the reader")
        XCTAssertEqual(ledger.readerTakeoverCount, 2)
    }

    // MARK: The page

    /// A gesture, the way AppKit reports one: it says a live scroll is
    /// beginning, moves the clip view, and says it has ended.
    @MainActor private func readerMoves(_ pane: Pane, to y: CGFloat) async throws {
        let scroll = try XCTUnwrap(pane.scroll)
        let clip = scroll.contentView
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pane.settle(turns: 3)
    }

    /// A movement nothing announced — a scroller AppKit reported differently,
    /// a reveal from somewhere else in the window — still takes the page off
    /// the newest row, because the ledger is what decides and it needs no
    /// notification to work.
    @MainActor func testAMovementNothingAnnouncedStillUnpinsThePage() async throws {
        let pane = try await openedChat("follow-silent"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll)
        XCTAssertTrue(page.atBottom)
        let takeovers = scroll.transcriptReading.ledger.readerTakeoverCount
        let clip = scroll.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.minY - 500)))
        scroll.reflectScrolledClipView(clip)
        await pane.settle(turns: 4)
        XCTAssertGreaterThan(scroll.transcriptReading.ledger.readerTakeoverCount, takeovers,
                             "the ledger did not notice an offset the page never wrote")
        XCTAssertFalse(page.atBottom, "a movement nothing announced must still unpin the page")
    }

    @MainActor private func openedChat(_ id: String, rows: Int = 60) async throws -> Pane {
        let session = TranscriptFrameBudgetTests.chat(id, rows: rows)
        let pane = Pane(session, state: "running")
        let last = TranscriptFrameBudgetTests.lastUserID(rows: rows)
        let ready = await pane.waitForRow(last, seconds: 120)
        XCTAssertTrue(ready, "the chat never appeared")
        await pane.settleUntilExact()
        return pane
    }

    @MainActor func testLeavingTheBottomBandUnpinsThePageAndComingBackRepinsIt() async throws {
        let pane = try await openedChat("follow-band"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll)
        let document = try XCTUnwrap(pane.document)
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(bottom, 600, "the fixture must be taller than the viewport")
        XCTAssertTrue(page.atBottom, "a chat with a run going opens at its newest row: the clip is at \(scroll.contentView.bounds.minY) of \(bottom), and \(scroll.transcriptReading.ledger.readerTakeoverCount) of its \(scroll.transcriptReading.ledger.writeCount) own scrolls were read as the reader's")
        XCTAssertFalse(page.detached)

        // Inside the band: still pinned. The band is narrow on purpose, so a
        // few points short of the end is still the end.
        try await readerMoves(pane, to: bottom - (TranscriptPage.followThreshold - 8))
        XCTAssertTrue(page.atBottom, "a reader still inside the bottom band is still following")

        // Out of the band: unpinned, and the way back appears.
        try await readerMoves(pane, to: bottom - 400)
        XCTAssertFalse(page.atBottom, "leaving the bottom band unpins the page")
        XCTAssertTrue(page.detached, "and the Back to bottom pill is shown")

        // A reply arriving below them must not drag them back.
        let offset = scroll.contentView.bounds.minY
        pane.session.messages.append(TranscriptMessage(id: "stream:z", role: "assistant", text: "A reply arriving under the reader.", state: "streaming", turn: TranscriptFrameBudgetTests.lastUserID(rows: 60)))
        await pane.settle(turns: 6)
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1,
                       "a reply arriving must not move a reader who has left the bottom band")
        XCTAssertFalse(page.atBottom)

        // Back into the band: pinned again, and the pill goes.
        let end = max(0, (pane.document?.frame.height ?? 0) - scroll.contentView.bounds.height)
        try await readerMoves(pane, to: end)
        XCTAssertTrue(page.atBottom, "coming back to the bottom band re-pins the page")
        XCTAssertFalse(page.detached, "and the Back to bottom pill goes")
    }

    /// The page's own scrolls are the ones it wrote down, so none of them
    /// ever look like the reader taking the position away from it.
    @MainActor func testThePagesOwnScrollsNeverHandThePositionToTheReader() async throws {
        let pane = try await openedChat("follow-ledger"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll)
        let takeovers = scroll.transcriptReading.ledger.readerTakeoverCount
        let last = TranscriptFrameBudgetTests.lastUserID(rows: 60)
        // Thirty deltas into the newest reply: every one of them grows the
        // document and the page writes itself back onto the new end.
        pane.session.messages.append(TranscriptMessage(id: "stream:w", role: "assistant", text: "#", state: "streaming", turn: last))
        await pane.settle(turns: 4)
        var text = "#"
        for step in 0..<30 {
            text += " token \(step) of a reply that keeps the page at the end of the conversation."
            pane.session.messages[pane.session.messages.count - 1].text = text
            await pane.settle(turns: 1)
        }
        await pane.settle(turns: 6)
        XCTAssertEqual(scroll.transcriptReading.ledger.readerTakeoverCount, takeovers,
                       "the page's own follow scrolls were read as the reader taking the position")
        XCTAssertTrue(page.atBottom, "the page stayed pinned to the newest row for the whole reply")
        XCTAssertGreaterThan(scroll.transcriptReading.ledger.writeCount, 0, "the page wrote its own scrolls down")
    }

    /// A document that shrinks under a reader standing at its end is clamped
    /// by AppKit, not moved by them: they stay pinned.
    @MainActor func testAClampToAShorterDocumentIsNotTheReaderMoving() async throws {
        let pane = try await openedChat("follow-clamp"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        XCTAssertTrue(page.atBottom)
        // The newest rows go: the document gets shorter and AppKit brings the
        // clip view back to the new end without anybody asking it to.
        pane.session.messages.removeLast(12)
        await pane.settle(turns: 8)
        XCTAssertTrue(page.atBottom, "a document that shrank under the reader must not unpin the page")
        XCTAssertFalse(page.detached)
    }

    /// A chat that opens at its last question opens away from the bottom, so
    /// the way back is offered from the first frame — the reader did not put
    /// themselves there, but they are still not at the end.
    @MainActor func testAChatThatOpensAtItsLastQuestionOffersTheWayBack() async throws {
        let session = TranscriptFrameBudgetTests.chat("follow-opening", rows: 40)
        // An idle chat whose last turn is taller than the viewport opens at
        // the question that started it.
        session.messages[session.messages.count - 1].text =
            (0..<60).map { "Line \($0) of a long answer with enough words in it to wrap around and around." }.joined(separator: "\n\n")
        let pane = Pane(session); defer { pane.close() }
        let ready = await pane.waitForRow(TranscriptFrameBudgetTests.lastUserID(rows: 40), seconds: 120)
        XCTAssertTrue(ready, "the chat never appeared")
        await pane.settleUntilExact()
        await pane.settle(turns: 8)
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll)
        let document = try XCTUnwrap(pane.document)
        let short = max(0, document.frame.height - scroll.contentView.bounds.height) - scroll.contentView.bounds.minY
        XCTAssertGreaterThan(short, TranscriptPage.followThreshold + 1, "the fixture must open away from the end")
        XCTAssertFalse(page.atBottom, "a chat that opens \(short) pt from the end must offer the way back")
    }

    /// The narrow band is the whole rule: it is 24 points, as the reference
    /// implementation has it, not most of a line of rows.
    @MainActor func testTheBottomBandIsTwentyFourPoints() {
        let band = TranscriptPage.followThreshold
        XCTAssertEqual(band, 24)
    }
}
