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
    /// The chat's spend against its cost limit. Without one the cost reads
    /// as the request log has it, as it always did.
    var cost: SessionCostReading?

    init(gateway: GatewayTotals, work: WorkSplit?, cost: SessionCostReading? = nil) {
        self.gateway = gateway; self.work = work; self.cost = cost
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
    private var usageParts: [String] {
        var parts: [String] = []
        if let total = totalTokens { parts.append(MetricFormat.tokenCount(total)) }
        if let cacheHit { parts.append("Cache hit \(cacheHit)%") }
        return parts
    }
    /// The spend the pill shows: what the chat's helper counted, once it has
    /// counted a reported cost, else the request log's.
    private var spent: Double? {
        let logged = gateway.costSamples > 0 ? gateway.costUSD : nil
        guard let cost, let counted = cost.spentUSD, cost.reportedRequests > 0 || counted > 0 else { return logged }
        return counted
    }
    /// `$0.0025`, or `$4.12 of $5.00` under a cost limit.
    var costFigure: String? {
        guard let cost else { return spent.map(compactGatewayUSD) }
        return cost.figure(spent: spent)
    }
    /// The spend is at 80% of the chat's limit or more.
    var costWarning: Bool { cost?.warning(spent: spent) ?? false }
    /// `15.8K tok · Cache hit 50% · $0.0025`
    var usageLabel: String { (usageParts + [costFigure].compactMap { $0 }).joined(separator: " · ") }
    /// What the pill draws: the reading, with the cost apart, in warning
    /// ink, once it nears the limit.
    var usageFace: (label: String, warningTail: String?) {
        guard costWarning, let figure = costFigure else { return (usageLabel, nil) }
        return (usageParts.joined(separator: " · "), figure)
    }
    /// A session whose requests all settled without billing keeps its counts
    /// and drops this pill rather than showing an empty one.
    var hasUsage: Bool { !usageLabel.isEmpty }
}

/// Session statistics under the composer: how much work the conversation did
/// and how fast, what it consumed, and how full the window is. Three pills,
/// no figure that ticks while a request runs. Each opens the Session
/// Inspector where its figure is explained: the first two its Overview, the
/// context ring the next request.
struct SessionStatsPills: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    let selectedContextWindow: Int?
    /// A side conversation shares the window with its parent; it keeps the two
    /// readings that are its own and drops the session gauge.
    var compact = false
    /// Opens the Session Inspector at a page.
    let open: (InspectorFocus) -> Void

    init(model: WorkspaceModel, session: SessionDisplay, footer: SessionMetrics, selectedContextWindow: Int?, compact: Bool = false,
         open: @escaping (InspectorFocus) -> Void) {
        self.model = model; self.session = session; self.footer = footer
        self.selectedContextWindow = selectedContextWindow; self.compact = compact; self.open = open
    }

    private var presentation: SessionStatsPresentation {
        SessionStatsPresentation(gateway: footer.gateway, work: WorkSplit(timing: footer.turnTiming), cost: footer.cost)
    }
    private var meter: ContextMeterPresentation {
        ContextMeterPresentation(context: model.displayedContext(session),
                                 capacity: session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }

    var body: some View {
        let stats = presentation
        // The pills flow like a sentence: a narrow pane wraps between them
        // rather than cutting a figure in half.
        PiFlow(spacing: PiSpacing.xs, rowSpacing: 3) {
            if !compact, stats.steps > 0 {
                PiStatButton(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel,
                             accessibility: "Session statistics: " + stats.gaugeLabel, identifier: "session-stats-time",
                             help: SettledThroughput.explanation + " Opens the Session Inspector.") { open(.overview) }
            }
            if stats.hasUsage {
                // Near the chat's cost limit, the spend is apart, in warning ink.
                let face = stats.usageFace
                PiStatButton(symbol: "cylinder.split.1x2", label: face.label, warningTail: face.warningTail,
                             accessibility: "Token usage: " + stats.usageLabel, identifier: "session-stats-usage",
                             help: "Gateway-reported usage and cost for this session's retained requests, and its cost limit. Opens the Session Inspector.") { open(.overview) }
            }
            contextPill
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionStatsPills")
    }

    /// A 14 pt ring and its reading. A conversation whose context has not been
    /// counted yet says so instead of drawing an empty ring at zero.
    private var contextPill: some View {
        let meter = meter
        let reading = meter.fraction.flatMap(MetricFormat.occupancyPercent)
        let label = reading.map { $0 + "%" } ?? (footer.preparingContext ? "Calculating context…" : meter.compactLabel)
        return PiStatButton(symbol: "square.stack.3d.up", ring: .some(meter.fraction), label: label,
                            accessibility: reading.map { "\($0)% of context used" } ?? meter.detailLabel,
                            identifier: "session-stats-context", help: meter.detailLabel + " Opens the next request in the Session Inspector.") { open(.nextRequest) }
    }
}

/// A stat pill that opens something: the pill's face, a soft fill under the
/// pointer, and an AppKit press target over it (`PiPopoverTrigger`) that keeps
/// its size, so nothing about it asks for another layout, and that a test can
/// press without an active app.
struct PiStatButton: View {
    let symbol: String
    var ring: Double?? = nil
    let label: String
    /// A last figure in warning ink (see `PiStatPillFace.warningTail`).
    var warningTail: String? = nil
    var accessibility: String? = nil
    var identifier: String? = nil
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        PiStatPillFace(symbol: symbol, ring: ring, label: label, highlighted: hovering, warningTail: warningTail)
            .accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: accessibility ?? label, identifier: identifier, help: help.isEmpty ? label : help,
                                 onHover: { inside in if hovering != inside { hovering = inside } },
                                 onPress: { _ in action() })
            }
    }
}
