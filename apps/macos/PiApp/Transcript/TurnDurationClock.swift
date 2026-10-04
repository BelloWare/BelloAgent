import AppKit

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

/// A periodic redraw also comes with every parent update. Sampling into
/// owned state prevents those redraws from turning a millisecond label into a
/// high-frequency timer. Terminal readings and new tasks apply immediately.
/// A plain object: whoever draws the reading is told through `changed`, and
/// the clock ticks (`start`) only while its turn runs.
@MainActor final class TurnDurationClock {
    static let intervalMs: Double = 500
    private(set) var reading: TurnDurationReading
    /// Told of every new reading, a tick's or an update's.
    var changed: ((TurnDurationReading) -> Void)?
    private var input: TurnDurationInput
    private var lastSampleUptimeMs: Double
    private var timer: Timer?

    init(input: TurnDurationInput, date: Date = .now,
         uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        self.input = input; reading = input.reading(at: date, uptimeMs: uptimeMs)
        lastSampleUptimeMs = uptimeMs
    }
    var live: Bool { input.live }
    func update(_ next: TurnDurationInput, date: Date = .now,
                uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        guard !(input.terminal && next.live && next.isSameTask(as: input)) else { return }
        let immediate = !next.live || next.live != input.live || !next.isSameTask(as: input)
        input = next
        if immediate { publish(at: date, uptimeMs: uptimeMs) }
        if !input.live { stop() }
    }
    func sample(date: Date = .now, uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        guard input.live, uptimeMs - lastSampleUptimeMs >= Self.intervalMs else { return }
        publish(at: date, uptimeMs: uptimeMs)
    }
    private func publish(at date: Date, uptimeMs: Double) {
        lastSampleUptimeMs = uptimeMs
        let next = input.reading(at: date, uptimeMs: uptimeMs)
        if next != reading { reading = next; changed?(next) }
    }
    /// Ticks every `intervalMs` while the turn runs; a settled turn's clock
    /// never schedules anything.
    func start() {
        guard input.live, timer == nil else { return }
        let timer = Timer(timeInterval: Self.intervalMs / 1_000, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.input.live else { self.stop(); return }
                self.sample()
            }
        }
        // Ticks on while the reader scrolls or holds a menu open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    /// Whether the clock is ticking, for tests.
    var ticking: Bool { timer != nil }
    func run() async {
        while !Task.isCancelled, input.live {
            do { try await Task.sleep(for: .milliseconds(Int(Self.intervalMs))) }
            catch { return }
            guard !Task.isCancelled else { return }
            sample()
        }
    }
}
