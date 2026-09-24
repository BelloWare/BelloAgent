import AppKit
import XCTest
@testable import PiApp

final class TranscriptIdleSchedulerTests: XCTestCase {
    @MainActor func testCheapUnitsUseTheRemainingSharedBudgetWithoutPollingFutureWork() {
        var now = 10.0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in true })
        let main = NSView(), side = NSView(), future = NSView()
        var order: [String] = []
        scheduler.request(main, after: now) { order.append("main"); now += 0.0004; return true }
        scheduler.request(side, after: now) { order.append("side"); now += 0.0004; return true }
        scheduler.request(future, after: now + 1) { XCTFail("Future work must retain its deadline"); return false }
        scheduler.runReady()
        XCTAssertEqual(order, ["main", "side", "main", "side"], "Cheap units share the available allowance fairly")
        XCTAssertEqual(scheduler.workCount, 4)
        scheduler.runReady()
        XCTAssertEqual(order.count, 4, "Using the budget does not bypass the global interval")
        scheduler.cancel(main); scheduler.cancel(side)
        now += 0.02; scheduler.runReady()
        XCTAssertEqual(scheduler.workCount, 4, "A queue containing only future work must terminate without polling")
    }
    @MainActor func testTwoPanesShareTheBudgetAndAlternateAfterAnExpensiveUnit() {
        var now = 10.0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in true })
        let main = NSView(), side = NSView()
        var order: [String] = []
        scheduler.request(main, after: now) { order.append("main"); now += 0.003; return true }
        scheduler.request(side, after: now) { order.append("side"); now += 0.003; return true }
        scheduler.runReady()
        XCTAssertEqual(order, ["main"], "No second host may start after the shared admission budget is spent")
        scheduler.runReady()
        XCTAssertEqual(order, ["main"], "The other pane must wait for the shared interval, not take another immediate budget")
        now += 0.02; scheduler.runReady()
        XCTAssertEqual(order, ["main", "side"], "The other pane is first next time")
        XCTAssertEqual(scheduler.longestUnit, 0.003, accuracy: 0.00001)
    }
    /// A reply's tokens each move the quiet deadline later. They may hold
    /// reconciliation back for a moment, never for the whole reply.
    @MainActor func testAStreamOfChangesDefersReconciliationOnlySoLong() {
        var now = 10.0, calls = 0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in true })
        let owner = NSView()
        let step = { calls += 1; now += 0.001; return false }
        // A token every 40 ms, each asking for quiet 150 ms after it.
        while now < 10.0 + TranscriptIdleScheduler.longestDeferral + 0.1 {
            scheduler.request(owner, after: now + TranscriptNativeDocument.sliceQuietPeriod, step: step)
            now += 0.04
            scheduler.runReady()
            if calls > 0 { break }
        }
        XCTAssertEqual(calls, 1, "tokens kept deferring the history's measurement for the whole reply")
        XCTAssertLessThanOrEqual(now, 10.0 + TranscriptIdleScheduler.longestDeferral + 0.05)
        // Finished work starts a new wait: a single change still waits for quiet.
        scheduler.request(owner, after: now + TranscriptNativeDocument.sliceQuietPeriod, step: step)
        now += 0.1; scheduler.runReady()
        XCTAssertEqual(calls, 1, "a single change must still wait for its quiet period")
    }
    @MainActor func testQuietDeadlineMovesAndInputAndVisibilityPauseOptionalWork() {
        var now = 10.0, visible = true, calls = 0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in visible })
        let owner = NSView()
        let step = { calls += 1; now += 0.002; return true }
        scheduler.request(owner, after: 10.15, step: step)
        now = 10.10; scheduler.request(owner, after: 10.25, step: step)
        now = 10.16; scheduler.runReady(); XCTAssertEqual(calls, 0)
        now = 10.26; visible = false; scheduler.runReady(); XCTAssertEqual(calls, 0)
        visible = true; scheduler.pauseForInput(); scheduler.runReady(); XCTAssertEqual(calls, 0)
        now = 10.5; scheduler.runReady(); XCTAssertEqual(calls, 1)
        scheduler.cancel(owner)
        now = 11; scheduler.runReady(); XCTAssertEqual(calls, 1)
    }
    /// Getting the rows the reader is about to reach ready runs while they
    /// are scrolling and while a reply is arriving — that is exactly when
    /// they are about to reach one, and waiting for quiet is what used to
    /// leave a scroll during a reply meeting rows with no tree. Only
    /// measuring history nobody is looking at still waits for their hands to
    /// stop.
    @MainActor func testPreparationRunsThroughInputWhileReconciliationWaitsForQuiet() {
        var now = 10.0, prepared = 0, reconciled = 0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in true })
        let owner = NSView()
        scheduler.request(owner, work: .preparation, after: 0) { prepared += 1; now += 0.002; return true }
        scheduler.request(owner, work: .reconciliation, after: 0) { reconciled += 1; now += 0.002; return true }
        scheduler.pauseForInput()
        scheduler.runReady()
        XCTAssertGreaterThan(prepared, 0, "preparation stopped while the reader was moving")
        XCTAssertEqual(reconciled, 0, "unseen history was measured while the reader was moving")
        XCTAssertEqual(scheduler.preparationCount, prepared)
        now += TranscriptNativeDocument.sliceQuietPeriod + TranscriptIdleScheduler.interval
        scheduler.runReady()
        XCTAssertGreaterThan(reconciled, 0, "unseen history was never measured once the reader stopped")
        scheduler.cancel(owner)
    }

    @MainActor func testQueuedWorkDoesNotOwnAClosedPane() {
        var now = 0.0, calls = 0
        let scheduler = TranscriptIdleScheduler(automatic: false, clock: { now }, visible: { _ in true })
        weak var weakOwner: NSView?
        autoreleasepool {
            let owner = NSView()
            weakOwner = owner
            scheduler.request(owner, after: 1) { calls += 1; return true }
        }
        XCTAssertNil(weakOwner)
        now = 2; scheduler.runReady()
        XCTAssertEqual(calls, 0)
    }
}
