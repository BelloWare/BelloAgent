import XCTest
@testable import PiApp

/// One activity phase per chat, read the same way by the menu bar's rows and
/// the live monitor's activity graph. They used to work it out separately,
/// and disagreed about a run marked interrupted: the menu bar showed it as
/// waiting for Resume, while the graph counted it as starting work once a
/// message was being sent in it again, and as idle before that.
final class ActivityPhaseTests: XCTestCase {
    private struct Case {
        var state: String
        var loading = false
        var uncertain = false
        var reported: String? = nil
        var phase: String
    }

    @MainActor func testTheActivityPhaseOfEveryRunState() {
        let cases: [Case] = [
            Case(state: "idle", phase: "idle"),
            Case(state: "idle", loading: true, phase: "starting"),
            Case(state: "running", phase: "starting"),
            Case(state: "running", reported: "model", phase: "model"),
            Case(state: "running", reported: "tool", phase: "tool"),
            Case(state: "running", reported: "compacting", phase: "compacting"),
            // A reported phase the menu bar has no words for reads as starting.
            Case(state: "running", reported: "reviewing", phase: "starting"),
            Case(state: "running", loading: true, reported: "model", phase: "starting"),
            Case(state: "queued", phase: "queued"),
            Case(state: "compacting", reported: "compacting", phase: "compacting"),
            // A stop that has not landed reads as stopping, whatever the turn last reported.
            Case(state: "stopping", reported: "model", phase: "stopping"),
            Case(state: "stopping", loading: true, phase: "stopping"),
            // A run whose queue waits for Resume, however it came to.
            Case(state: "paused", phase: "paused"),
            Case(state: "paused", loading: true, phase: "paused"),
            Case(state: "interrupted", phase: "paused"),
            Case(state: "interrupted", loading: true, phase: "paused"),
            Case(state: "idle", uncertain: true, phase: "paused"),
            Case(state: "running", uncertain: true, reported: "model", phase: "paused"),
            // A failed run reads as an error, its uncertainty included.
            Case(state: "error", phase: "error"),
            Case(state: "error", uncertain: true, phase: "error"),
            Case(state: "error", loading: true, phase: "error"),
            // A state a newer helper reports and this build does not know.
            Case(state: "reviewing", phase: "idle"),
        ]
        for item in cases {
            let view = SessionDisplay(id: "phase")
            view.state = item.state; view.loading = item.loading; view.uncertain = item.uncertain
            if let reported = item.reported { view.activity = ["phase": .string(reported)] }
            XCTAssertEqual(view.activityPhase, item.phase, "\(item)")
        }
    }

    /// The menu bar's row and the activity graph read the same phase: here
    /// the case they used to disagree on, a message sent again in a run the
    /// app marked interrupted.
    @MainActor func testTheMenuBarAndTheActivityGraphAgree() throws {
        let model = makeWorkspaceModel(stateRoot: scratchRoot("activity-phase"))
        model.chats = [ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "profile")]
        let view = SessionDisplay(id: "chat"); model.displays[view.id] = view
        let key = LiveSessionKey(workspace: "project", session: "chat")
        func read() -> (menu: String?, graph: String?, counted: Int) {
            model.noteActivityChanged("chat")
            return (model.menuBarActivity().rows.first { $0.id == "chat" }?.phase, model.liveActivity.accumulator.phases[key],
                    model.liveActivity.accumulator.counts.total)
        }

        view.runState = .running; view.activity = ["phase": .string("model")]
        var now = read()
        XCTAssertEqual(now.menu, "model"); XCTAssertEqual(now.graph, "model"); XCTAssertEqual(now.counted, 1)

        view.runState = .interrupted; view.activity = [:]
        now = read()
        XCTAssertEqual(now.menu, "paused"); XCTAssertNil(now.graph, "A run waiting for Resume is not counted as work"); XCTAssertEqual(now.counted, 0)

        // The reader sends again while the app still shows the run interrupted.
        view.loading = true
        now = read()
        XCTAssertEqual(now.menu, "paused")
        XCTAssertNil(now.graph, "The graph reads the phase the menu bar shows; it counted this as starting work")
        XCTAssertEqual(now.counted, 0)

        // The send goes out: the app shows the run starting, and both follow.
        view.runState = .running
        now = read()
        XCTAssertEqual(now.menu, "starting"); XCTAssertEqual(now.graph, "starting"); XCTAssertEqual(now.counted, 1)
    }
}
