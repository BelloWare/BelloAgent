import XCTest
@testable import PiApp

@MainActor final class TurnDurationClockTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private func liveTurn() -> TurnSummary {
        var turn = TaskTranscriptPlan.summary([], task: nil)
        turn.taskKey = "task-a"; turn.live = true
        turn.liveStartedUptimeMs = 100_000; turn.startedAt = epoch.timeIntervalSince1970 * 1000
        return turn
    }

    func testFrequentStreamUpdatesCannotAdvanceAnyDurationBeforeThePacedTick() {
        var turn = liveTurn()
        let clock = TurnDurationClock(input: TurnDurationInput(turn), date: epoch, uptimeMs: 100_000)
        var changedAt: [Int] = []
        for milliseconds in stride(from: 25, through: 2_000, by: 25) {
            let before = clock.reading
            turn.elapsedMs = Double(milliseconds)
            turn.modelMs = Double(milliseconds) * 0.8; turn.toolMs = Double(milliseconds) * 0.2
            let date = epoch.addingTimeInterval(Double(milliseconds) / 1_000)
            clock.update(TurnDurationInput(turn), date: date, uptimeMs: 100_000 + Double(milliseconds))
            XCTAssertEqual(clock.reading, before, "An incoming render must not advance live readings")
            clock.sample(date: date, uptimeMs: 100_000 + Double(milliseconds))
            if before != clock.reading { changedAt.append(milliseconds) }
        }
        XCTAssertEqual(changedAt, [500, 1000, 1500, 2000])
        XCTAssertEqual(clock.reading, TurnDurationReading(elapsedMs: 2_000, modelMs: 1_600, toolMs: 400))
    }

    func testCompletionImmediatelyKeepsExactReportedDurationsAndStopsAdvancing() {
        var turn = liveTurn()
        let clock = TurnDurationClock(input: TurnDurationInput(turn), date: epoch, uptimeMs: 100_000)
        turn.live = false; turn.outcome = "completed"; turn.elapsedMs = 123.456; turn.modelMs = 110.123; turn.toolMs = 13.333
        clock.update(TurnDurationInput(turn), date: epoch.addingTimeInterval(0.124), uptimeMs: 100_124)
        let final = TurnDurationReading(elapsedMs: 123.456, modelMs: 110.123, toolMs: 13.333)
        XCTAssertEqual(clock.reading, final)
        clock.sample(date: epoch.addingTimeInterval(50), uptimeMs: 150_000)
        XCTAssertEqual(clock.reading, final)
        // A previously queued live render for this execution cannot start the
        // clock again after the authoritative terminal reading was delivered.
        clock.update(TurnDurationInput(liveTurn()), date: epoch.addingTimeInterval(60), uptimeMs: 160_000)
        clock.sample(date: epoch.addingTimeInterval(61), uptimeMs: 161_000)
        XCTAssertEqual(clock.reading, final)
    }

    func testTerminalEvidenceFreezesEvenIfTheLiveFlagArrivesLate() {
        for outcome in ["completed", "failed", "cancelled", "output-limited"] {
            var turn = liveTurn(); turn.outcome = outcome; turn.elapsedMs = 1_234.567
            let value = TurnInfoPresentation.live(turn, at: epoch.addingTimeInterval(1000), uptimeMs: 1_100_000)
            XCTAssertFalse(value.live)
            XCTAssertEqual(value.elapsedMs, 1_234.567)
        }
        var turn = liveTurn(); turn.endedAt = epoch.timeIntervalSince1970 * 1000 + 2_500
        let value = TurnInfoPresentation.live(turn, at: epoch.addingTimeInterval(1000), uptimeMs: 1_100_000)
        XCTAssertFalse(value.live); XCTAssertEqual(value.elapsedMs, 2_500)
        turn.endedAt = nil; turn.phase = "terminal"; turn.elapsedMs = nil
        XCTAssertNil(TurnInfoPresentation.live(turn, at: epoch.addingTimeInterval(1000), uptimeMs: 1_100_000).elapsedMs)
    }

    func testSessionRunLineUsesTheRecordedFinishInsteadOfTheCurrentClock() {
        let timing: [String: WireValue] = ["startedAt": .number(100_000), "endedAt": .number(102_500), "elapsedMs": .number(2_500)]
        XCTAssertEqual(SessionRunLine.elapsed(timing, atUptimeMs: 105_000), MetricFormat.runDuration(2_500))
        XCTAssertEqual(SessionRunLine.elapsed(timing, atUptimeMs: 500_000), MetricFormat.runDuration(2_500))
        var withoutElapsed = timing; withoutElapsed.removeValue(forKey: "elapsedMs")
        XCTAssertEqual(SessionRunLine.elapsed(withoutElapsed, atUptimeMs: 500_000), MetricFormat.runDuration(2_500))
    }

    func testNewTaskResetsImmediatelyWithoutReusingThePreviousClock() {
        var turn = liveTurn()
        let clock = TurnDurationClock(input: TurnDurationInput(turn), date: epoch, uptimeMs: 100_000)
        clock.sample(date: epoch.addingTimeInterval(10), uptimeMs: 110_000)
        turn.taskKey = "task-b"; turn.liveStartedUptimeMs = 110_100
        clock.update(TurnDurationInput(turn), date: epoch.addingTimeInterval(10.1), uptimeMs: 110_100)
        XCTAssertEqual(clock.reading.elapsedMs, 0)
        clock.sample(date: epoch.addingTimeInterval(10.2), uptimeMs: 110_200)
        XCTAssertEqual(clock.reading.elapsedMs, 0)
    }

    func testUptimeWinsOverWallClockChangesAndLegacyFallbackDoesNotInventAnEpoch() {
        var turn = liveTurn()
        let clock = TurnDurationClock(input: TurnDurationInput(turn), date: epoch, uptimeMs: 100_000)
        clock.sample(date: epoch.addingTimeInterval(86_400), uptimeMs: 100_500)
        XCTAssertEqual(clock.reading.elapsedMs, 500)
        turn.liveStartedUptimeMs = nil
        XCTAssertEqual(TurnDurationInput(turn).reading(at: epoch.addingTimeInterval(1.25), uptimeMs: 500).elapsedMs, 1_250)
        turn.startedAt = nil; turn.elapsedMs = nil
        XCTAssertNil(TurnDurationInput(turn).reading(at: epoch, uptimeMs: 100_000).elapsedMs)
        turn.elapsedMs = 12.345
        XCTAssertEqual(TurnDurationInput(turn).reading(at: epoch, uptimeMs: 100_000).elapsedMs, 12.345)
    }
}
