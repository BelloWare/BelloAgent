import SwiftUI

/// Only the timing inputs cross into the clock. Streamed text and usage updates
/// can redraw their own views without changing these displayed readings.
struct TurnDurationInput: Equatable {
    let taskKey: String?
    let startedAt: Double?
    let liveStartedUptimeMs: Double?
    let elapsedMs: Double?
    let modelMs: Double
    let toolMs: Double
    let live: Bool
    let terminal: Bool

    init(_ turn: TurnSummary) {
        taskKey = turn.taskKey; startedAt = turn.startedAt
        liveStartedUptimeMs = turn.liveStartedUptimeMs
        if let reported = DurationObservation.valid(turn.elapsedMs) { elapsedMs = reported }
        else if turn.terminal, turn.outcome != "interrupted", let start = turn.startedAt, let end = turn.endedAt {
            elapsedMs = DurationObservation.valid(end - start)
        } else { elapsedMs = nil }
        modelMs = turn.modelMs; toolMs = turn.toolMs; live = turn.isRunning; terminal = turn.terminal
    }
    func reading(at date: Date, uptimeMs: Double) -> TurnDurationReading {
        var elapsed = DurationObservation.valid(elapsedMs)
        if live, let start = liveStartedUptimeMs { elapsed = DurationObservation.valid(uptimeMs - start) }
        else if live, let start = startedAt { elapsed = DurationObservation.valid(date.timeIntervalSince1970 * 1000 - start) }
        return TurnDurationReading(elapsedMs: elapsed, modelMs: modelMs, toolMs: toolMs)
    }
    func isSameTask(as other: Self) -> Bool {
        if let taskKey, let otherKey = other.taskKey { return taskKey == otherKey }
        return taskKey == other.taskKey && startedAt == other.startedAt && liveStartedUptimeMs == other.liveStartedUptimeMs
    }
}

struct TurnDurationReading: Equatable {
    let elapsedMs: Double?
    let modelMs: Double
    let toolMs: Double
}

/// A periodic TimelineView also redraws on every parent update. Sampling into
/// owned state prevents those redraws from turning a millisecond label into a
/// high-frequency timer. Terminal readings and new tasks apply immediately.
@MainActor final class TurnDurationClock: ObservableObject {
    static let intervalMs: Double = 500
    @Published private(set) var reading: TurnDurationReading
    private var input: TurnDurationInput
    private var lastSampleUptimeMs: Double

    init(input: TurnDurationInput, date: Date = .now,
         uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        self.input = input; reading = input.reading(at: date, uptimeMs: uptimeMs)
        lastSampleUptimeMs = uptimeMs
    }
    func update(_ next: TurnDurationInput, date: Date = .now,
                uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        guard !(input.terminal && next.live && next.isSameTask(as: input)) else { return }
        let immediate = !next.live || next.live != input.live || !next.isSameTask(as: input)
        input = next
        if immediate { publish(at: date, uptimeMs: uptimeMs) }
    }
    func sample(date: Date = .now, uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        guard input.live, uptimeMs - lastSampleUptimeMs >= Self.intervalMs else { return }
        publish(at: date, uptimeMs: uptimeMs)
    }
    private func publish(at date: Date, uptimeMs: Double) {
        lastSampleUptimeMs = uptimeMs
        let next = input.reading(at: date, uptimeMs: uptimeMs)
        if next != reading { reading = next }
    }
    func run() async {
        while !Task.isCancelled, input.live {
            do { try await Task.sleep(for: .milliseconds(Int(Self.intervalMs))) }
            catch { return }
            guard !Task.isCancelled else { return }
            sample()
        }
    }
}

struct TurnDurationMetrics: View {
    private let input: TurnDurationInput
    @StateObject private var clock: TurnDurationClock

    init(turn: TurnSummary) {
        let input = TurnDurationInput(turn)
        self.input = input
        _clock = StateObject(wrappedValue: TurnDurationClock(input: input))
    }
    /// A running clock counts whole seconds, as every running clock in the
    /// app does: a live reading with milliseconds changed its digits — and,
    /// trailing zeros trimmed, its width — on every tick. A settled reading
    /// keeps the precision it was reported with.
    nonisolated static func label(_ milliseconds: Double, live: Bool) -> String {
        live ? MetricFormat.runDuration(milliseconds) : MetricFormat.detailedDuration(milliseconds)
    }
    var body: some View {
        let live = input.live
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Duration").foregroundStyle(TranscriptPalette.faint)
                Text(clock.reading.elapsedMs.map { Self.label($0, live: live) } ?? "—")
                    .foregroundStyle(TranscriptPalette.text).accessibilityIdentifier("elapsedClock")
            }.font(.system(size: 11, weight: .medium))
            Text("AI \(Self.label(clock.reading.modelMs, live: live)) · Tools \(Self.label(clock.reading.toolMs, live: live))")
                .font(.system(size: 10)).foregroundStyle(TranscriptPalette.muted)
                .help("Recorded AI and tool time. Live readings count whole seconds; completed readings retain their reported precision.")
        // Live, the readings keep one line each, so a tick can never wrap the
        // dock. Settled, they no longer change and may wrap rather than cut.
        }.monospacedDigit().lineLimit(live ? 1 : nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .onChange(of: input) { _, next in clock.update(next) }
            .task(id: input.live) { if input.live { await clock.run() } }
    }
}
