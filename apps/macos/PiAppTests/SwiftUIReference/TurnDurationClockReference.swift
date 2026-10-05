import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TurnDurationClock.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

struct TurnDurationMetrics: View {
    private let input: TurnDurationInput
    @State private var clock: TurnDurationClock
    @State private var reading: TurnDurationReading

    init(turn: TurnSummary) {
        let input = TurnDurationInput(turn)
        self.input = input
        let clock = TurnDurationClock(input: input)
        _clock = State(initialValue: clock)
        _reading = State(initialValue: clock.reading)
    }
    /// A running clock counts whole seconds, as every running clock in the
    /// app does: a live reading with milliseconds changed its digits — and,
    /// trailing zeros trimmed, its width — on every tick. A settled reading
    /// is rounded too (`92 ms`, `19.7s`, `1m 05s`): three decimals of a
    /// millisecond said nothing a reader could use. The Session Inspector
    /// keeps each request's exact time.
    nonisolated static func label(_ milliseconds: Double, live: Bool) -> String {
        live ? MetricFormat.runDuration(milliseconds) : MetricFormat.turnDuration(milliseconds)
    }
    var body: some View {
        let live = input.live
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Duration").foregroundStyle(TranscriptPalette.faint)
                Text(reading.elapsedMs.map { Self.label($0, live: live) } ?? "—")
                    .foregroundStyle(TranscriptPalette.text).accessibilityIdentifier("elapsedClock")
            }.font(.system(size: 11, weight: .medium))
            Text("AI \(Self.label(reading.modelMs, live: live)) · Tools \(Self.label(reading.toolMs, live: live))")
                .font(.system(size: 10)).foregroundStyle(TranscriptPalette.muted)
                .help("Recorded AI and tool time, rounded. The Session Inspector has each request's exact time.")
        // Live, the readings keep one line each, so a tick can never wrap the
        // dock. Settled, they no longer change and may wrap rather than cut.
        }.monospacedDigit().lineLimit(live ? 1 : nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .onAppear { clock.changed = { [$reading] next in $reading.wrappedValue = next }; reading = clock.reading }
            .onChange(of: input) { _, next in clock.update(next); reading = clock.reading }
            .task(id: input.live) { if input.live { await clock.run() } }
    }
}
