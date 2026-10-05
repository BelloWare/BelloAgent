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
    /// The cached share of the input of the requests that reported both
    /// counters — the same population as the session pill and the report's
    /// green bar, never every read over every input.
    var cacheHit: String? {
        guard let split = accounting.split(input: true) else { return nil }
        return MetricFormat.cacheHitPercent(read: split.part, prompt: split.total, decimals: 1)
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
        if let cacheHit { rows.append(PiStatRow(name: "Cache hit", value: cacheHit + "%", coverage: coverage(accounting.split(input: true)?.samples ?? 0))) }
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
        rows.append(PiStatRow(name: "Work", value: TurnPillsPresentation.counts(turn)))
        return rows
    }
    var timeNotes: [String] {
        var notes: [String] = []
        if accounting.throughput.samples == 0, accounting.requests > 0 {
            notes.append("No request of this turn generated two or more output tokens over at least \(SettledThroughput.floorLabel), so it has no output speed.")
        } else {
            notes.append(SettledThroughput.explanation)
        }
        if let outcome = turn.outcome, outcome != "completed" { notes.append("Outcome: " + TurnInfoPresentation.outcome(turn) + ".") }
        return notes
    }
    /// A turn with neither a clock nor one timed figure has nothing to open.
    var hasTimeDialog: Bool { turn.elapsedMs != nil || turn.modelMs > 0 || turn.toolMs > 0 || accounting.throughput.samples > 0 }
}
