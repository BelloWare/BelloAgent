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

    /// Once the reader has taken the position, where the page last asked to
    /// be says nothing about where they go. A clamp the page claimed before
    /// they took over must not make them coming back down onto the end look
    /// like another clamp: that left the page showing the end and not
    /// following it.
    @MainActor func testTheReaderComingBackToTheEndAfterAClampIsTheReader() {
        let ledger = TranscriptScrollLedger()
        _ = ledger.delivered(900, floor: 1_000)
        ledger.wrote(from: 900, to: 1_000)
        XCTAssertEqual(ledger.delivered(1_000, floor: 1_000), .page, "the page's own follow")
        XCTAssertEqual(ledger.delivered(800, floor: 800), .page, "the document shrank under it: the clamp")
        XCTAssertEqual(ledger.delivered(500, floor: 800), .reader, "the reader goes up")
        XCTAssertEqual(ledger.delivered(800, floor: 800), .reader, "the reader coming back down onto the end is the reader")
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

    /// A mouse wheel has no gesture phases. AppKit says a live scroll has
    /// begun from inside `scrollWheel(with:)`, but moves the clip view a frame
    /// or more later, and a pass that lays the page out in between — a slice
    /// measuring history, a streamed token, a block resolving — takes the
    /// reading anchor where the reader still stands. When the movement lands
    /// it is the reader's, and that anchor has to give way to it: restoring
    /// it put them back on the newest row, where the end of the gesture found
    /// them in the bottom band and pinned the page, and every delta after
    /// that dragged them down again.
    @MainActor func testAWheelThatLandsLateIsNotUndoneByAnAnchorTakenBeforeIt() async throws {
        let pane = try await openedChat("follow-late-wheel"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView)
        let document = try XCTUnwrap(pane.document)
        let clip = scroll.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        XCTAssertGreaterThan(bottom, 1_000, "the fixture must be several screens long")
        XCTAssertTrue(page.atBottom)

        // What the wheel event itself does, before AppKit has moved anything.
        scroll.readerWillNavigate(upward: true)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // A pass in the gap.
        document.layoutNow()
        XCTAssertTrue(scroll.transcriptReading.hasAnchor, "the pass must have taken an anchor for this to mean anything")
        // AppKit lands the wheel, then reports the live scroll and its end.
        let landed = bottom - 700
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: landed))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        await pane.settle(turns: 3)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pane.settle(turns: 4)
        XCTAssertEqual(clip.bounds.minY, landed, accuracy: 1, "an anchor taken before the wheel landed put the reader back")
        XCTAssertFalse(page.atBottom)
        XCTAssertFalse(page.followsBottom, "the end of the gesture pinned a reader the wheel had taken off the end")

        // A reply arriving below them leaves them where the wheel put them.
        pane.session.messages.append(TranscriptMessage(id: "stream:late", role: "assistant", text: "A reply arriving under the reader.",
                                                       state: "streaming", turn: TranscriptFrameBudgetTests.lastUserID(rows: 60)))
        await pane.settle(turns: 6)
        XCTAssertEqual(clip.bounds.minY, landed, accuracy: 1, "a reply arriving pulled the reader back to the newest row")
    }

    /// The same late landing reaching another observer of the clip before the
    /// page's own — AppKit promises no order — and that observer holding the
    /// reading position at once, as a block resolving in the viewport or the
    /// document's own viewport pass does. It must not restore the anchor over
    /// the reader.
    @MainActor func testAnObserverThatHearsOfTheWheelFirstCannotRestoreOverIt() async throws {
        let pane = try await openedChat("follow-late-wheel-order"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView)
        let document = try XCTUnwrap(pane.document)
        let clip = scroll.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        scroll.readerWillNavigate(upward: true)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        document.layoutNow()
        XCTAssertTrue(scroll.transcriptReading.hasAnchor)
        let landed = bottom - 700
        clip.postsBoundsChangedNotifications = false
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: landed))
        scroll.reflectScrolledClipView(clip)
        scroll.transcriptReading.restore()
        let afterRestore = clip.bounds.minY
        clip.postsBoundsChangedNotifications = true
        XCTAssertEqual(afterRestore, landed, accuracy: 1, "an anchor restored before the page heard of the wheel put the reader back")
        XCTAssertFalse(page.followsBottom)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pane.settle(turns: 4)
        XCTAssertEqual(clip.bounds.minY, landed, accuracy: 1)
        XCTAssertFalse(page.atBottom)
    }

    /// A dragged scroller: AppKit says the live scroll began once, then moves
    /// the clip for every step of the drag with nothing in between that the
    /// page hears as the reader's input. A pass between two steps takes an
    /// anchor where the first one left the reader; the draw after the second
    /// must not restore it.
    @MainActor func testEveryStepOfAScrollerDragStandsWhereItPutTheReader() async throws {
        let pane = try await openedChat("follow-scroller-drag"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll)
        let document = try XCTUnwrap(pane.document)
        let clip = scroll.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for step in 1...6 {
            let target = bottom - CGFloat(step) * 150
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            scroll.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            XCTAssertEqual(clip.bounds.minY, target, accuracy: 1, "step \(step) of the drag was pulled back")
            // A pass between this step and the next.
            document.layoutNow()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pane.settle(turns: 4)
        XCTAssertEqual(clip.bounds.minY, bottom - 900, accuracy: 1)
        XCTAssertFalse(page.followsBottom)
    }

    /// A trackpad, the events a real one sends: a gesture that begins,
    /// changes and ends, then momentum that begins, continues and ends, each
    /// through `scrollWheel(with:)` and each with a pass after it. The reader
    /// goes where the gesture takes them and stays there.
    @MainActor func testATrackpadGestureWithMomentumIsNeverPulledBack() async throws {
        let pane = try await openedChat("follow-trackpad"); defer { pane.close() }
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView)
        let document = try XCTUnwrap(pane.document)
        let clip = scroll.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        func event(_ delta: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let gesture: [NSEvent] = try [event(0, phase: .began)] + (0..<6).map { _ in try event(60, phase: .changed) }
            + [event(0, phase: .ended), event(40, momentum: .begin)] + (0..<5).map { _ in try event(30, momentum: .continuous) }
            + [event(0, momentum: .end)]
        var lowest = clip.bounds.minY
        var worstPullBack: CGFloat = 0
        for wheel in gesture {
            scroll.scrollWheel(with: wheel)
            document.layoutNow()
            pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            worstPullBack = max(worstPullBack, clip.bounds.minY - lowest)
            lowest = min(lowest, clip.bounds.minY)
            // A trackpad reports at the display's rate.
            try? await Task.sleep(for: .milliseconds(12))
        }
        await pane.settle(turns: 6)
        worstPullBack = max(worstPullBack, clip.bounds.minY - lowest)
        print(String(format: "PERF trackpad gesture: %d events carried the reader %.0f pt off the end, pulled back at worst %.1f pt",
                     gesture.count, bottom - clip.bounds.minY, worstPullBack))
        XCTAssertLessThan(clip.bounds.minY, bottom - TranscriptPage.followThreshold - 40, "the gesture did not take the reader off the end")
        XCTAssertLessThan(worstPullBack, 1, "a pass during the gesture carried the reader \(worstPullBack) pt back toward the end")
        XCTAssertFalse(page.followsBottom)
        XCTAssertFalse(scroll.readerIsScrolling, "the gesture's end must be heard")
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
