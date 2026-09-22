import SwiftUI

/// The three readings under the composer, and what each one's dialog says.
///
/// Pure over the session's gateway totals, the helper's session clocks and the
/// counts of the loaded page, so every string here is asserted without a view.
/// Nothing is a live figure: the throughput is the settled rate over the whole
/// retained log, and the counts only change when a turn ends.
struct SessionStatsPresentation: Equatable {
    /// The session's own attempts over the whole retained log: every figure
    /// here rides it, so paging the transcript cannot change a reading.
    var gateway: GatewayTotals
    /// The helper's session clocks: where the wall time went.
    var work: WorkSplit?

    init(gateway: GatewayTotals, work: WorkSplit?) {
        self.gateway = gateway; self.work = work
    }

    /// Distinct turns these requests belong to. A title or suggestion request
    /// carries no turn and is counted as neither a turn nor a step.
    var turns: Int { gateway.turnCount ?? 0 }
    /// One model request is one step.
    var steps: Int { gateway.requests }

    // MARK: The gauge pill

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    var countsLabel: String {
        Self.plural(turns, "turn", "turns") + " " + Self.plural(steps, "step", "steps")
    }
    var throughput: SettledThroughput { gateway.settledThroughput }
    var latency: SettledLatency { gateway.settledLatency }
    /// `2 turns 3 steps · 34 tok/s`, and the counts alone when no request
    /// reported both halves of the rate.
    var gaugeLabel: String {
        [countsLabel, throughput.label].compactMap { $0 }.joined(separator: " · ")
    }
    /// A window with no timed figure has nothing to open; the pill stays a reading.
    var hasTimeDialog: Bool {
        (work?.sessionModelMs ?? 0) > 0 || (work?.sessionToolMs ?? 0) > 0 || latency.samples > 0 || throughput.samples > 0
    }
    var timeRows: [PiStatRow] {
        var rows: [PiStatRow] = []
        if let work, work.sessionModelMs > 0 { rows.append(PiStatRow(name: "LLM time", value: workDuration(work.sessionModelMs))) }
        if let work, work.sessionToolMs > 0 { rows.append(PiStatRow(name: "Tool time", value: workDuration(work.sessionToolMs))) }
        if let average = latency.average {
            rows.append(PiStatRow(name: "Average TTFT", value: MetricFormat.latency(average), coverage: latency.coverage))
        }
        if let rate = throughput.tokensPerSecond {
            rows.append(PiStatRow(name: "Output speed", value: MetricFormat.throughput(rate), coverage: throughput.coverage))
        }
        return rows
    }
    var timeNotes: [String] {
        var notes = [SettledThroughput.explanation]
        if latency.samples < latency.requests, latency.requests > 0 {
            notes.append("First-token latency was not recorded for every request; the average covers the \(latency.samples) that recorded it.")
        }
        if gateway.expiredRecords > 0 { notes.append("\(gateway.expiredRecords) expired records are excluded from every figure here.") }
        return notes
    }

    // MARK: The usage pill

    var totalTokens: Double? { gateway.billedTotalTokens }
    var cacheHit: String? { gateway.cacheHitPercent }
    /// `15.8K tok · Cache hit 50% · $0.0025`
    var usageLabel: String {
        var parts: [String] = []
        if let total = totalTokens { parts.append(MetricFormat.tokenCount(total)) }
        if let cacheHit { parts.append("Cache hit \(cacheHit)%") }
        if gateway.costSamples > 0, let cost = gateway.costUSD { parts.append(compactGatewayUSD(cost)) }
        return parts.joined(separator: " · ")
    }
    /// A session whose requests all settled without billing keeps its counts
    /// and drops this pill rather than showing an empty one.
    var hasUsage: Bool { !usageLabel.isEmpty }
    var usageRows: [PiStatRow] {
        let tokens = gateway.tokens ?? GatewayTokenTotals()
        var rows: [PiStatRow] = []
        func coverage(_ samples: Int) -> String? { samples < gateway.requests ? "\(samples)/\(gateway.requests) requests reported" : nil }
        if let cacheHit { rows.append(PiStatRow(name: "Cache hit", value: cacheHit + "%", coverage: coverage(gateway.cacheReadSamples))) }
        if let uncached = gateway.uncachedInputTokens {
            rows.append(PiStatRow(name: "Uncached input", value: MetricFormat.exactTokenCount(uncached), coverage: coverage(gateway.uncachedInputSampleCount)))
        }
        if gateway.cacheReadSamples > 0, let read = gateway.cacheReadTokens {
            rows.append(PiStatRow(name: "Cached input", value: MetricFormat.exactTokenCount(read), coverage: coverage(gateway.cacheReadSamples)))
        }
        if gateway.cacheWriteSamples > 0, let write = gateway.cacheWriteTokens {
            rows.append(PiStatRow(name: "Cache write", value: MetricFormat.exactTokenCount(write), coverage: coverage(gateway.cacheWriteSamples)))
        }
        if tokens.outputSamples > 0, let output = tokens.output {
            let reasoning = (tokens.reasoningSamples ?? 0) > 0 ? tokens.reasoning : nil
            rows.append(PiStatRow(name: "Output", value: MetricFormat.exactTokenCount(output),
                                  detail: reasoning.map { "incl. \(MetricFormat.exactTokens($0)) reasoning" },
                                  coverage: coverage(tokens.outputSamples)))
        }
        if gateway.costSamples > 0, let cost = gateway.costUSD {
            rows.append(PiStatRow(name: "Cost", value: gatewayUSD(cost), coverage: coverage(gateway.costSamples)))
        }
        return rows
    }
    var usageNotes: [String] {
        var notes = ["Cached input is part of input; reasoning is part of output. Neither is added again."]
        if gateway.costSamples < gateway.requests {
            notes.append("\(gateway.requests - gateway.costSamples) of \(gateway.requests) requests reported no cost; the total counts only the ones that did.")
        }
        if gateway.expiredRecords > 0 { notes.append("\(gateway.expiredRecords) expired records are excluded.") }
        return notes
    }
    var usageHeadline: String? { totalTokens.map(MetricFormat.exactTokenCount) }
}

/// Session statistics under the composer: how much work the conversation did
/// and how fast, what it consumed, and how full the window is. Three pills,
/// one open dialog at a time, and no figure that ticks while a request runs.
struct SessionStatsPills: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    let selectedContextWindow: Int?
    /// A side conversation shares the window with its parent; it keeps the two
    /// readings that are its own and drops the session gauge.
    var compact = false
    /// Opens the full context sheet from the context dialog.
    let exploreContext: () -> Void
    /// Opens Session info — the per-request ledger — from a dialog's footer.
    let openLedger: () -> Void
    /// One exclusive slot: opening a pill closes whichever was open.
    @State private var openPill: String?

    private var presentation: SessionStatsPresentation {
        SessionStatsPresentation(gateway: footer.gateway, work: WorkSplit(timing: footer.turnTiming))
    }
    private var meter: ContextMeterPresentation {
        ContextMeterPresentation(context: model.displayedContext(session),
                                 capacity: session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { openPill == key }, set: { openPill = $0 ? key : nil })
    }

    var body: some View {
        let stats = presentation
        // The pills flow like a sentence: a narrow pane wraps between them
        // rather than cutting a figure in half.
        PiFlow(spacing: PiSpacing.xs, rowSpacing: 3) {
            if !compact, stats.steps > 0 { gaugePill(stats) }
            if stats.hasUsage { usagePill(stats) }
            contextPill
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionStatsPills")
    }

    @ViewBuilder private func gaugePill(_ stats: SessionStatsPresentation) -> some View {
        if stats.hasTimeDialog {
            PiStatPill(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel,
                       accessibility: "Session statistics: " + stats.gaugeLabel,
                       identifier: "session-stats-time", help: SettledThroughput.explanation,
                       open: binding("time")) {
                PiStatDialog(symbol: "gauge.with.dots.needle.67percent", title: "Session statistics",
                             rows: stats.timeRows, notes: stats.timeNotes, identifier: "session-stats-time-dialog")
            }
        } else {
            PiStatPill(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel,
                       accessibility: "Session statistics: " + stats.gaugeLabel, identifier: "session-stats-time")
        }
    }

    private func usagePill(_ stats: SessionStatsPresentation) -> some View {
        PiStatPill(symbol: "cylinder.split.1x2", label: stats.usageLabel,
                   accessibility: "Token usage: " + stats.usageLabel,
                   identifier: "session-stats-usage", help: "Gateway-reported usage and cost for this session's retained requests",
                   open: binding("usage")) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiStatDialog(symbol: "cylinder.split.1x2", title: "Token usage", headline: stats.usageHeadline,
                             rows: stats.usageRows, notes: stats.usageNotes, identifier: "session-stats-usage-dialog")
                Button("Per-request ledger…") { openPill = nil; openLedger() }
                    .buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.md).padding(.bottom, PiSpacing.md)
            }
        }
    }

    /// A 14 pt ring and its reading. A conversation whose context has not been
    /// counted yet says so instead of drawing an empty ring at zero.
    private var contextPill: some View {
        let meter = meter
        let reading = meter.fraction.flatMap(MetricFormat.occupancyPercent)
        let label = reading.map { $0 + "%" } ?? (footer.preparingContext ? "Calculating context…" : meter.compactLabel)
        return PiStatPill(symbol: "square.stack.3d.up", ring: .some(meter.fraction), label: label,
                          accessibility: reading.map { "\($0)% of context used" } ?? meter.detailLabel,
                          identifier: "session-stats-context", help: meter.detailLabel,
                          open: binding("context")) {
            VStack(alignment: .leading, spacing: 0) {
                PiStatDialog(symbol: "square.stack.3d.up", title: "Context",
                             headline: meter.fraction != nil ? meter.compactFigures : nil,
                             rows: contextRows(meter), notes: contextNotes(meter), identifier: "session-stats-context-dialog")
                Button("Explore context…") { openPill = nil; exploreContext() }
                    .buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.md).padding(.bottom, PiSpacing.md)
            }
        }
    }

    private func contextRows(_ meter: ContextMeterPresentation) -> [PiStatRow] {
        var rows: [PiStatRow] = []
        if let reading = meter.fraction.flatMap(MetricFormat.occupancyPercent) {
            rows.append(PiStatRow(name: "Used", value: reading + "%", detail: meter.compactFigures))
        }
        rows.append(PiStatRow(name: "Counted by", value: meter.methodLabel + (meter.estimated ? " · estimated" : " · counted")))
        if let model = meter.modelLabel { rows.append(PiStatRow(name: "Model", value: model)) }
        for part in meter.budgetParts { rows.append(PiStatRow(name: part.name, value: part.value)) }
        return rows
    }
    private func contextNotes(_ meter: ContextMeterPresentation) -> [String] {
        meter.warnings.isEmpty ? ["The ring uses the helper's matching request count. Explore context for its method, model and uncertainty."] : meter.warnings
    }
}
