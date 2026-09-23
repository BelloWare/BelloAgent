import SwiftUI

/// The readings of the two session pills under the composer.
///
/// Pure over the session's gateway totals and the helper's session clocks, so
/// every string here is asserted without a view. Nothing is a live figure: the
/// throughput is the settled rate over the whole retained log, and the counts
/// only change when a turn ends. What the pills open is built from the same
/// totals by `SessionTimeCharts` and `SessionTokenCharts`.
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
}

/// Session statistics under the composer: how much work the conversation did
/// and how fast, what it consumed, and how full the window is. Three pills,
/// one open dialog at a time, and no figure that ticks while a request runs.
///
/// The first two open chart popovers (`SessionTimePopover`,
/// `SessionTokenPopover`) owned by the session's `SessionStatsStore`, which
/// reads the per-request history only when one opens. The context pill keeps
/// its compact dialog.
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
    /// Opens Session info — the per-request ledger — from a popover's header.
    let openLedger: () -> Void
    /// The context dialog's slot. The two chart popovers are the store's, and
    /// opening any of the three closes whichever was open.
    @State private var openPill: String?
    /// The session's charts and popovers, shared by every row of pills that
    /// shows this session. Held, not observed: the pills draw from the footer.
    private let store: SessionStatsStore

    init(model: WorkspaceModel, session: SessionDisplay, footer: SessionMetrics, selectedContextWindow: Int?, compact: Bool = false,
         exploreContext: @escaping () -> Void, openLedger: @escaping () -> Void) {
        self.model = model; self.session = session; self.footer = footer
        self.selectedContextWindow = selectedContextWindow; self.compact = compact
        self.exploreContext = exploreContext; self.openLedger = openLedger
        store = SessionStatsStore.shared(archive: model.traces, sessionID: session.id)
    }

    private var presentation: SessionStatsPresentation {
        SessionStatsPresentation(gateway: footer.gateway, work: WorkSplit(timing: footer.turnTiming))
    }
    private var meter: ContextMeterPresentation {
        ContextMeterPresentation(context: model.displayedContext(session),
                                 capacity: session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { openPill == key }, set: { open in
            openPill = open ? key : nil
            if open { store.timePresenter.close(); store.tokenPresenter.close() }
        })
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
        // An open popover follows the session: a request settling or a turn
        // ending moves these figures, and the store reads the history again.
        .onChange(of: footer.gateway) { _, _ in followFooter() }
        .onChange(of: WorkSplit(timing: footer.turnTiming)) { _, _ in followFooter() }
    }

    private var scope: SessionUsageScope {
        SessionUsageScope(sessionID: session.id, workspaceID: model.record(session.id)?.workspaceID ?? "")
    }
    /// A chart popover is opening: the context dialog closes, and the store
    /// brings the charts up to the footer's figures.
    private func openCharts() {
        openPill = nil
        store.open(scope: scope, inputs: SessionStatsInputs(footer: footer, session: session))
    }
    private func followFooter() {
        guard store.isShowing else { return }
        store.footerChanged(SessionStatsInputs(footer: footer, session: session))
    }
    private func ledger() {
        store.timePresenter.close(); store.tokenPresenter.close()
        openLedger()
    }

    @ViewBuilder private func gaugePill(_ stats: SessionStatsPresentation) -> some View {
        if stats.hasTimeDialog {
            PiStatPopoverPill(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel,
                              accessibility: "Session statistics: " + stats.gaugeLabel,
                              identifier: "session-stats-time", help: SettledThroughput.explanation,
                              presenter: store.timePresenter, willOpen: openCharts,
                              isReady: { [store] in store.time.historyLoaded || store.failure != nil }) { [store] in
                SessionTimePopover(store: store, openLedger: ledger)
            }
        } else {
            PiStatPill(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel,
                       accessibility: "Session statistics: " + stats.gaugeLabel, identifier: "session-stats-time")
        }
    }

    private func usagePill(_ stats: SessionStatsPresentation) -> some View {
        PiStatPopoverPill(symbol: "cylinder.split.1x2", label: stats.usageLabel,
                          accessibility: "Token usage: " + stats.usageLabel,
                          identifier: "session-stats-usage", help: "Gateway-reported usage and cost for this session's retained requests",
                          presenter: store.tokenPresenter, willOpen: openCharts,
                          isReady: { [store] in store.tokens.historyLoaded || store.failure != nil }) { [store] in
            SessionTokenPopover(store: store, openLedger: ledger)
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
        [ContextMeterPresentation.methodExplanation] + meter.warnings
    }
}
