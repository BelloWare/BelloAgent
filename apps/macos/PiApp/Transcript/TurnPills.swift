import SwiftUI
import AppKit

// What a turn ends with, and what a reply says about the request behind it.
// The turn used to close with a sentence of figures; it now closes with two
// pills — what it cost and how long it ran — each opening the dialog that
// explains it. The figures themselves are unchanged: they come from
// TranscriptActivity, and nothing here measures anything.

/// The two turn pills and their dialogs, as plain strings. Pure over a
/// `TurnSummary`, so every label and every row is asserted without a view.
struct TurnPillsPresentation: Equatable {
    let turn: TurnSummary
    init(_ turn: TurnSummary) { self.turn = turn }

    private var accounting: TurnAccounting { turn.accounting }

    // MARK: The usage pill

    /// The same aggregate the session pill quotes: reported input plus output.
    /// Cache reads/writes and reasoning are breakdowns, not additional tokens.
    var totalTokens: Double? {
        var total: Double?, any = false
        func add(_ value: Double?, _ samples: Int) {
            guard samples > 0, let value, value.isFinite, value >= 0 else { return }
            total = (total ?? 0) + value; any = true
        }
        add(accounting.input, accounting.inputSamples)
        add(accounting.output, accounting.outputSamples)
        if !any { return TranscriptActivity.tokens(of: accounting) }
        return total
    }
    var cacheHit: String? {
        guard accounting.cachedSamples > 0, let read = accounting.cached,
              accounting.inputSamples > 0, let input = accounting.input else { return nil }
        return MetricFormat.cacheHitPercent(read: read, prompt: input, decimals: 1)
    }
    /// `Usage 15.8K tok · $0.0025`
    var usageLabel: String? {
        var parts: [String] = []
        if let totalTokens { parts.append("Usage " + MetricFormat.tokenCount(totalTokens)) }
        if accounting.costSamples > 0, let cost = accounting.costUSD { parts.append(compactGatewayUSD(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var usageHeadline: String? { totalTokens.map(MetricFormat.exactTokenCount) }

    private func coverage(_ samples: Int) -> String? {
        samples < accounting.requests ? "\(samples)/\(accounting.requests) requests reported" : nil
    }

    var usageRows: [PiStatRow] {
        var rows: [PiStatRow] = []
        if let model = accounting.model { rows.append(PiStatRow(name: "Model", value: model)) }
        if let cacheHit { rows.append(PiStatRow(name: "Cache hit", value: cacheHit + "%", coverage: coverage(accounting.cachedSamples))) }
        if let uncached = accounting.uncached {
            rows.append(PiStatRow(name: "Uncached input", value: MetricFormat.exactTokenCount(uncached), coverage: coverage(accounting.uncachedSamples)))
        }
        if let cached = accounting.cached {
            rows.append(PiStatRow(name: "Cached input", value: MetricFormat.exactTokenCount(cached), coverage: coverage(accounting.cachedSamples)))
        }
        if let write = accounting.cacheWrite {
            rows.append(PiStatRow(name: "Cache write", value: MetricFormat.exactTokenCount(write), coverage: coverage(accounting.cacheWriteSamples)))
        }
        if let output = accounting.output {
            rows.append(PiStatRow(name: "Output", value: MetricFormat.exactTokenCount(output),
                                  detail: accounting.reasoning.map { "incl. \(MetricFormat.exactTokens($0)) reasoning" },
                                  coverage: coverage(accounting.outputSamples)))
        }
        if let cost = accounting.costUSD {
            rows.append(PiStatRow(name: "Cost", value: gatewayUSD(cost), coverage: coverage(accounting.costSamples)))
        }
        return rows
    }
    var usageNotes: [String] {
        var notes: [String] = []
        if turn.partial { notes.append("Earlier replies of this turn are above the loaded history; these figures cover the loaded requests.") }
        notes.append("Cached input is part of input; reasoning is part of output. Neither is added again.")
        return notes
    }

    // MARK: The time pill

    /// `Ran for 19s`
    var timeLabel: String? {
        guard let elapsed = turn.elapsedMs else { return nil }
        return "Ran for " + MetricFormat.runDuration(elapsed)
    }
    var timeRows: [PiStatRow] {
        var rows: [PiStatRow] = []
        if let elapsed = turn.elapsedMs { rows.append(PiStatRow(name: "Total run time", value: MetricFormat.runDuration(elapsed))) }
        if let rate = accounting.throughput.tokensPerSecond {
            rows.append(PiStatRow(name: "Output speed", value: MetricFormat.throughput(rate), coverage: accounting.throughput.coverage))
        }
        if let ttft = accounting.latency.average {
            rows.append(PiStatRow(name: "TTFT", value: MetricFormat.latency(ttft), coverage: accounting.latency.coverage))
        }
        if turn.modelMs > 0 || turn.toolMs > 0 {
            rows.append(PiStatRow(name: "Model vs tools", value: MetricFormat.runDuration(turn.modelMs) + " / " + MetricFormat.runDuration(turn.toolMs),
                                  detail: "waiting on the model / running tools"))
        }
        rows.append(PiStatRow(name: "Work", value: TurnLineView.counts(turn)))
        return rows
    }
    var timeNotes: [String] {
        var notes: [String] = []
        if accounting.throughput.samples == 0, accounting.requests > 0 {
            notes.append("No request of this turn reported both a decode span and its output tokens, so it has no output speed.")
        } else {
            notes.append(SettledThroughput.explanation)
        }
        if let outcome = turn.outcome, outcome != "completed" { notes.append("Outcome: " + TurnInfoPresentation.outcome(turn) + ".") }
        return notes
    }
    /// A turn with neither a clock nor one timed figure has nothing to open.
    var hasTimeDialog: Bool { turn.elapsedMs != nil || turn.modelMs > 0 || turn.toolMs > 0 || accounting.throughput.samples > 0 }
}

// MARK: - Per-request accounting line

/// The quiet receipt under one reply: which model answered, and what that
/// request reported. The turn's pills sum these; this line is the evidence.
struct MessageAccountingView: View {
    let accounting: GatewayTotals
    let onInspect: () -> Void
    var trailing = false
    var body: some View {
        let presentation = TranscriptActivity.accountingPresentation(accounting)
        if !presentation.summary.isEmpty {
            HStack(spacing: 0) {
                if let model = presentation.modelLabel {
                    Button(action: onInspect) { Text(model).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted).underline(true, color: .clear) }
                        .buttonStyle(.plain).piPointer().help("View response-body and header models").accessibilityLabel("View model reports: \(model)")
                    if !presentation.usage.isEmpty { Text(" · ").font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted) }
                }
                Text(presentation.usage).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .help(presentation.detail)
            .accessibilityLabel("\(presentation.summary). \(presentation.detail)")
        }
    }
}

// MARK: - The turn's pills

/// Compact turn receipt shared with the live dock. Detail stays available
/// through Info and Copy, while the token split is readable without a click.
struct TurnPillRow: View {
    let turn: TurnSummary
    var actions = TranscriptActions()
    var model: String? = nil
    var showsInfo = false

    var body: some View {
        CompactTurnReport(turn: turn, actions: actions, model: model, showsInfo: showsInfo)
            .accessibilityIdentifier("turn-pills")
    }
}

/// How a turn ends: the compact report over a hairline. A turn that has just
/// settled glows for a moment, as the old turn line did, and hovering it still
/// says when the turn started and finished.
struct TurnLineView: View {
    let turn: TurnSummary
    var settled = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    var actions = TranscriptActions()
    var model: String? = nil
    var modelMessageID: String? = nil

    var body: some View {
        let stamps = [turn.startedAt.map { "Started " + TranscriptActivity.formatClock($0) },
                      turn.isRunning ? nil : turn.endedAt.map { "finished " + TranscriptActivity.formatClock($0) }].compactMap { $0 }.joined(separator: " · ")
        return TurnPillRow(turn: turn, actions: actions, model: model, showsInfo: true)
            .help(stamps)
            .padding(.top, 6)
            .overlay(alignment: .top) { Rectangle().fill(settled ? TranscriptPalette.accent.opacity(0.55) : TranscriptPalette.hair).frame(height: 1) }
            .background(settled ? TranscriptPalette.accent.opacity(0.07) : Color.clear)
            .padding(.top, 8)
            .accessibilityLabel("Turn: \(TurnLineView.counts(turn))")
    }

    nonisolated static func copyText(_ turn: TurnSummary, model: String? = nil) -> String {
        var lines = [turn.partial ? "Turn (partial loaded history)" : "Turn", counts(turn)]
        if let outcome = turn.outcome { lines.append("Outcome: " + outcome) }
        else if !turn.isRunning { lines.append("Task outcome unavailable; retained figures may be incomplete.") }
        if let notice = turn.notice { lines.append(notice) }
        if let started = turn.startedAt { lines.append("Started: " + TranscriptActivity.formatClock(started)) }
        if let ended = turn.endedAt { lines.append("Finished: " + TranscriptActivity.formatClock(ended)) }
        if let elapsed = turn.elapsedMs { lines.append("Duration: " + TranscriptActivity.formatDuration(elapsed)) }
        lines.append("Model time: " + TranscriptActivity.formatDuration(turn.modelMs) + " · Tool time: " + TranscriptActivity.formatDuration(turn.toolMs))
        if let rate = turn.accounting.throughput.tokensPerSecond {
            lines.append("Output speed: " + MetricFormat.throughput(rate) + (turn.accounting.throughput.coverage.map { " (" + $0 + ")" } ?? ""))
        }
        let usage = TranscriptActivity.usageBreakdown(turn.accounting)
        if !usage.isEmpty { lines.append("Gateway-reported usage: " + usage) }
        let names = turn.accounting.reportedModels
        if !names.isEmpty { lines.append("Models: " + names.joined(separator: ", ")) }
        else if let model { lines.append("Model: " + model) }
        if !turn.accounting.requestedModels.isEmpty { lines.append("Requested models: " + turn.accounting.requestedModels.joined(separator: ", ")) }
        for route in turn.accounting.modelRoutes { lines.append(route.detail) }
        if turn.isRunning { lines.append("Still running; figures are incomplete.") }
        for (index, request) in turn.requests.enumerated() {
            guard let accounting = request.accounting else { continue }
            let figures = TranscriptActivity.accountingPresentation(accounting)
            lines.append("\nRequest \(index + 1) · message \(request.id)\n" + figures.summary + "\n" + figures.detail)
        }
        return lines.joined(separator: "\n")
    }
    nonisolated static func counts(_ turn: TurnSummary, includeTools: Bool = true) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        return plural(turn.replies, "reply", "replies")
            + (includeTools && turn.tools > 0 ? ", " + (turn.toolCountPartial ? "at least " : "") + plural(turn.tools, "tool call", "tool calls") : "")
            + (turn.files > 0 ? ", " + plural(turn.files, "file changed", "files changed") : "")
    }
}

/// A terminal slot independent of the prose above it: the turn's outcome, then
/// the same compact report the transcript's own turns end with, then any notice.
struct StableTurnSummaryView: View {
    let turn: TurnSummary
    let actions: TranscriptActions
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TurnPillRow(turn: turn, actions: actions, showsInfo: true)
            if let notice = turn.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(TranscriptPalette.warning).textSelection(.enabled)
            }
        }.padding(.top, 6).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
    }
}
