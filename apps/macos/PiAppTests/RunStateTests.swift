import XCTest
@testable import PiApp

/// A chat's run state, read one way everywhere: which states are a run under
/// way, which hold the chat's queue for Resume, and that a state this build
/// does not know reads as neither, as the string lists it replaced read it.
final class RunStateTests: XCTestCase {
    func testEveryKnownStateReadsAsItAlwaysDid() {
        // What the string lists said before `RunState`.
        let busy: Set<String> = ["queued", "running", "stopping", "compacting"]
        let held: Set<String> = ["paused", "interrupted"]
        for state in RunState.known {
            XCTAssertEqual(state.isBusy, busy.contains(state.rawValue), state.rawValue)
            XCTAssertEqual(state.holdsQueue, held.contains(state.rawValue), state.rawValue)
            XCTAssertEqual(state.isStopped, ["error", "paused", "interrupted"].contains(state.rawValue), state.rawValue)
            XCTAssertFalse(state.isBusy && state.isStopped, "\(state.rawValue) is never both under way and stopped")
        }
        XCTAssertEqual(Set(RunState.known.map(\.rawValue)), busy.union(held).union(["idle", "error"]))
    }

    func testAStateThisBuildDoesNotKnowIsKeptAndReadsAsNeither() {
        let newer = RunState(rawValue: "reviewing")
        XCTAssertFalse(newer.isBusy); XCTAssertFalse(newer.holdsQueue); XCTAssertFalse(newer.isStopped)
        XCTAssertEqual(newer.rawValue, "reviewing")
        XCTAssertFalse(RunState.known.contains(newer))
    }

    @MainActor func testTheDisplayReadsAndWritesItsStateThroughRunState() {
        let view = SessionDisplay(id: "run-state")
        XCTAssertEqual(view.runState, .idle); XCTAssertFalse(view.busy)
        view.runState = .interrupted
        XCTAssertEqual(view.state, "interrupted", "Writing a RunState writes its string")
        XCTAssertTrue(view.canResumeQueue, "An interrupted run's follow-ups wait for Resume")
        view.state = "compacting"
        XCTAssertEqual(view.runState, .compacting); XCTAssertTrue(view.busy)
        view.state = "reviewing"
        XCTAssertFalse(view.busy, "A state this build does not know is not a run under way")
        XCTAssertEqual(view.runState.rawValue, "reviewing")
    }

    @MainActor func testASnapshotsStateIsReadThroughRunState() {
        let view = SessionDisplay(id: "snapshot-state")
        // A failed run that is still busy (its stop has not landed) stays busy.
        view.observeRunState(["state": .string("stopping"), "runStatus": .string("failed")])
        XCTAssertEqual(view.runState, .stopping)
        XCTAssertNil(view.failureMessage)
        // A failed run that has ended reads as an error.
        view.observeRunState(["state": .string("paused"), "runStatus": .string("failed"), "preflightError": .string("Provider refused")])
        XCTAssertEqual(view.runState, .error)
        XCTAssertEqual(view.failureMessage, "Provider refused")
        // Without `queuePaused`, a paused or interrupted run holds the queue.
        view.observeRunState(["state": .string("interrupted"), "runStatus": .string("interrupted")])
        XCTAssertTrue(view.queuePaused)
        view.observeRunState(["state": .string("idle"), "runStatus": .string("idle")])
        XCTAssertFalse(view.queuePaused)
        XCTAssertNil(view.failureMessage)
    }
}
