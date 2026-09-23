import SwiftUI

extension DashboardModelSummary {
    var distributionID: String { model ?? "\(alias) · \(status)" }
}

extension DashboardFilter {
    /// Live history is indexed by project. A narrower saved-request filter
    /// must never silently display other sessions' or models' live counters.
    var supportsProjectLiveHistory: Bool {
        sessionID == nil && purpose == nil && api == nil && requestedAlias == nil
            && effectiveModel == nil && !unreportedModelOnly && ["all", "completed"].contains(status)
    }
}

/// The time axis of the report's throughput chart. The live series follows
/// the clock; the retained request averages cover exactly the window they
/// were read for, so they never slide out of view before the next refresh.
enum ReportThroughputDomain {
    static func live(_ window: DashboardWindow, observedAt: Date) -> ClosedRange<Date> {
        let until = window.preset == .custom ? window.until : max(window.until, observedAt)
        return until.addingTimeInterval(-window.span)...until
    }
    static func following(metric: MonitorRateMetric, live: ClosedRange<Date>, retained: DashboardFilter) -> ClosedRange<Date> {
        metric == .average ? retained.from...retained.until : live
    }
}

/// Only this leaf observes the paced live snapshot. Chart ticks never query
/// SQLite or rebuild the report's routing, cost or request tables.
@MainActor struct ReportThroughputPanel: View {
    @ObservedObject var live: LiveActivityStore
    let snapshot: DashboardSnapshot
    let window: DashboardWindow
    let palette: MonitorModelPalette
    let controls: () -> AnyView
    let registerModels: ([String]) -> Void
    /// The report's selection. The chart's zoom shows and follows it; it is
    /// never a second copy that has to be synchronised back.
    var selection: DashboardBrush?
    /// The reader zoomed or reset the chart: the only way this panel changes the selection.
    var select: (ClosedRange<Date>?) -> Void = { _ in }
    @State private var observer = UUID().uuidString
    @State private var zoom = MonitorChartZoom()
    @State private var metric: MonitorRateMetric?

    private func chosenMetric(_ samples: [LiveRateSample]) -> MonitorRateMetric {
        guard snapshot.filter.supportsProjectLiveHistory else { return .average }
        return metric ?? (samples.contains { !$0.hasGap(workspace: snapshot.filter.workspaceID) && !$0.models(workspace: snapshot.filter.workspaceID).isEmpty } ? .live : .average)
    }
    /// Writes from the chart: a drag in progress stays local; a committed
    /// zoom or a reset goes to the report, whose selection then comes back
    /// through `selection` without another round trip.
    private var chartZoom: Binding<MonitorChartZoom> {
        Binding(get: { zoom }, set: { next in
            let changed = next.range != zoom.range
            zoom = next
            if changed { select(next.range) }
        })
    }
    private var retained: MenuBarSnapshot {
        MenuBarSnapshot(period: .day, from: snapshot.filter.from, until: snapshot.filter.until,
            counts: snapshot.scopeCounts, gateway: snapshot.gateway, workspaces: 0, sessions: 0,
            compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: [], modelGroups: 0, offset: 0,
            buckets: snapshot.buckets.map { MenuBarBucket(id: $0.id, start: $0.start, end: $0.end, gateway: $0.gateway) })
    }
    var body: some View {
        let liveDomain = ReportThroughputDomain.live(window, observedAt: live.snapshot.observedAt)
        // Filtered once per update: the metric choice and the chart share it.
        let samples = live.snapshot.rateHistory.samples(in: zoom.domain(following: liveDomain))
        let metric = chosenMetric(samples)
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 12) {
                PiSectionHeader("Throughput by model") { controls() }
                if snapshot.filter.supportsProjectLiveHistory {
                    let current = live.snapshot.currentRates(workspace: snapshot.filter.workspaceID)
                    HStack {
                        Text("Now \(menuBarRate(current.rate)) tok/s").font(PiFont.heading)
                        Spacer()
                        Text("\(current.reported)/\(current.active) requests reporting live").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                    }.monospacedDigit()
                }
                MonitorRateChart(samples: samples, usage: retained, workspace: snapshot.filter.workspaceID,
                    following: ReportThroughputDomain.following(metric: metric, live: liveDomain, retained: snapshot.filter),
                    zoom: chartZoom, metric: metric, palette: palette, selectMetric: { self.metric = $0 },
                    showsMetricSelection: snapshot.filter.supportsProjectLiveHistory, chartHeight: 180)
                if !snapshot.filter.supportsProjectLiveHistory {
                    Text("Showing completed requests matching your filters. Live history is available for whole projects.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                }
            }
        }
        .background(WindowVisibilityReader { live.setVisible($0, owner: observer) })
        .onDisappear { live.setVisible(false, owner: observer) }
        .onChange(of: live.snapshot.rateHistory.modelNames, initial: true) { _, names in registerModels(Array(names)) }
        // The selection drives the zoom; a refresh that keeps it keeps the
        // zoom, one that drops it (or a cleared chip) resets it.
        .onChange(of: selection, initial: true) { _, value in zoom.show(value.map { $0.from...$0.until }) }
        .accessibilityIdentifier("analytics-throughput")
    }
}

@MainActor struct ReportActiveSessions: View {
    @ObservedObject var live: LiveActivityStore
    let workspaceID: String?
    let activity: () -> MenuBarActivitySnapshot
    let openSession: (String) -> Void
    @State private var observer = UUID().uuidString
    var body: some View {
        let rows = activity().runningRows.filter { workspaceID == nil || $0.workspaceID == workspaceID }
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                PiSectionHeader("Active sessions", subtitle: "Running now in the selected project · \(rows.count) sessions")
                MonitorSessionRows(rows: rows, snapshot: live.snapshot, openSession: openSession)
                if rows.isEmpty { Text("All quiet. No sessions are working.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                if rows.count > 6 { Text("Showing 6 of \(rows.count) running sessions").font(PiFont.micro).foregroundStyle(Color.piInkSecondary) }
            }
        }.background(WindowVisibilityReader { live.setVisible($0, owner: observer) })
            .onDisappear { live.setVisible(false, owner: observer) }
    }
}

extension MonitorDistribution {
    static func report(_ rows: [DashboardModelSummary], total: GatewayTotals) -> [Self] {
        make(rows.map { row in
            MenuBarModelDistribution(api: row.api, requestedAlias: row.alias, resolvedModel: row.model,
                identityStatus: row.status, gateway: row.gateway, allRequests: total.requests,
                costShare: share(row.gateway.costUSD, of: total.costUSD),
                outputShare: share(row.gateway.tokens?.output, of: total.tokens?.output))
        })
    }
    static func share(_ value: Double?, of total: Double?) -> Double? {
        guard let value, let total, value.isFinite, total.isFinite, value >= 0, total > 0, value <= total else { return nil }
        return value / total
    }
    /// Costliest first; routes without a reported cost last, in their token order.
    static func byCost(_ models: [Self]) -> [Self] {
        models.enumerated().sorted { a, b in
            let x = a.element.cost ?? -1, y = b.element.cost ?? -1
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

/// Bounded native drawing; no chart engine or transcript work per live tick.
struct ModelDistributionRing: View {
    let models: [MonitorDistribution]
    let palette: MonitorModelPalette
    let metric: MonitorShareMetric
    let cost: Double?
    @State private var highlighted: String?

    private func share(_ row: MonitorDistribution) -> Double? { metric == .cost ? row.costShare : row.tokenShare }
    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2 - 9
                    let circle = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                    context.stroke(Path(ellipseIn: circle), with: .color(Color.piFillStrong), lineWidth: 15)
                    var start = -90.0
                    for row in models.prefix(24) {
                        guard let fraction = share(row), fraction > 0 else { continue }
                        let end = min(270, start + fraction * 360)
                        var arc = Path()
                        arc.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                        context.stroke(arc, with: .color(Color.monitorModel(palette.index(row.id)).opacity(highlighted == nil || highlighted == row.id ? 1 : 0.25)), lineWidth: 15)
                        start = end
                    }
                }.accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(monitorCost(cost)).font(.system(size: 15, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    Text("reported cost").font(.system(size: 10)).foregroundStyle(Color.piInkSecondary)
                }.padding(.horizontal, 17)
            }.frame(width: 136, height: 136)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.legend(models, metric: metric)) { row in
                    HStack(spacing: 6) {
                        Circle().fill(Color.monitorModel(palette.index(row.id))).frame(width: 7, height: 7)
                        Text(row.id).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(share(row).map { String(format: "%.3f%%", $0 * 100) } ?? "—").monospacedDigit()
                    }.font(PiFont.caption).contentShape(Rectangle())
                        .onHover { highlighted = $0 ? row.id : nil }
                        .help("\(row.id) · \(menuBarTokens(row.tokens)) output · \(gatewayUSD(row.cost))\nRequested as \(row.aliases.sorted().joined(separator: ", "))")
                }
                if models.count > 4 { Text("+\(models.count - 4) more models").font(PiFont.micro).foregroundStyle(Color.piInkSecondary) }
                if models.isEmpty { Text("Awaiting reported usage").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("model-distribution-ring")
    }
    /// The four models the legend names, ranked by the share it shows.
    static func legend(_ models: [MonitorDistribution], metric: MonitorShareMetric) -> [MonitorDistribution] {
        Array((metric == .cost ? MonitorDistribution.byCost(models) : models).prefix(4))
    }
}

struct ModelRoutingMap: View {
    let rows: [DashboardModelSummary]
    let palette: MonitorModelPalette
    /// The routes have not been read yet: not the same as none reported.
    var loading = false
    @State private var showAll = false
    private var aliases: [String] { Array(Set(rows.map(\.alias))).sorted() }
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Model routing").font(PiFont.heading)
                Text("Requested → returned by the gateway").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                if rows.isEmpty { Text(loading ? "Reading routes…" : "No model routes reported in this range.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                ForEach(Array(aliases.prefix(showAll ? 64 : 2)), id: \.self) { alias in
                    let destinations = rows.filter { $0.alias == alias }
                    HStack(spacing: 0) {
                        VStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 18))
                            Text(alias).font(PiFont.caption.weight(.medium)).lineLimit(3).textSelection(.enabled)
                        }.padding(9).frame(width: 116).background(Color.piFill, in: RoundedRectangle(cornerRadius: 10)).help(alias)
                        RoutingBranches(count: min(destinations.count, showAll ? 64 : 4)).frame(width: 30)
                        VStack(spacing: 8) {
                            ForEach(Array(destinations.prefix(showAll ? 64 : 4))) { row in
                                HStack(spacing: 7) {
                                    Circle().fill(Color.monitorModel(palette.index(row.distributionID))).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.resolutionLabel).font(PiFont.caption.weight(.medium)).lineLimit(2)
                                        Text("\(row.requests) requests · \(monitorCost(row.gateway.costUSD))").font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                                    }
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    .background(Color.monitorModel(palette.index(row.distributionID)).opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                    .help("\(alias) → \(row.resolutionLabel)\n\(row.gateway.costLabel)")
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if aliases.count > 2 || aliases.contains(where: { alias in rows.filter { $0.alias == alias }.count > 4 }) {
                    Button(showAll ? "Show fewer routes" : "Show all \(rows.count) routes") { showAll.toggle() }.buttonStyle(.piGhost)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("analytics-model-routing")
    }
}

private struct RoutingBranches: View {
    let count: Int
    var body: some View {
        Canvas { context, size in
            for index in 0..<count {
                let y = (CGFloat(index) + 0.5) * size.height / CGFloat(max(1, count))
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addCurve(to: CGPoint(x: size.width, y: y), control1: CGPoint(x: size.width / 2, y: size.height / 2), control2: CGPoint(x: size.width / 2, y: y))
                context.stroke(path, with: .color(Color.piAccent.opacity(0.45)), lineWidth: 1.5)
            }
        }.accessibilityHidden(true)
    }
}

struct ModelCostBreakdown: View {
    let models: [MonitorDistribution]
    let total: GatewayTotals
    let palette: MonitorModelPalette
    /// The routes have not been read yet: not the same as no reported cost.
    var loading = false
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Text("Cost by model").font(PiFont.heading); Spacer(); Text(monitorCost(total.costUSD)).font(PiFont.caption).monospacedDigit() }
                ForEach(Self.shown(models)) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Circle().fill(Color.monitorModel(palette.index(row.id))).frame(width: 7, height: 7)
                            Text(row.id).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(monitorCost(row.cost)).monospacedDigit()
                        }.font(PiFont.caption)
                        GeometryReader { geometry in
                            Capsule().fill(Color.piFillStrong)
                            Capsule().fill(Color.monitorModel(palette.index(row.id)))
                                .frame(width: geometry.size.width * min(1, max(0, row.costShare ?? 0)))
                        }.frame(height: 5)
                    }.help("\(row.id): \(gatewayUSD(row.cost)) · \(row.requests) requests")
                }
                if models.isEmpty { Text(loading ? "Reading routes…" : "No model costs reported.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                Text("\(total.costSamples)/\(total.requests) requests reported cost · reasoning included in total")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("analytics-model-costs")
    }
    /// The eight costliest routes. The distribution arrives ranked by output
    /// tokens, which could leave an expensive, terse route off a cost card.
    static func shown(_ models: [MonitorDistribution]) -> [MonitorDistribution] { Array(MonitorDistribution.byCost(models).prefix(8)) }
}

struct AnalyticsTokenBreakdown: View {
    let gateway: GatewayTotals
    private var accounting: TurnAccounting {
        var result = TurnAccounting(requests: gateway.requests)
        result.input = gateway.tokens?.input; result.inputSamples = gateway.tokens?.inputSamples ?? 0
        result.cached = gateway.cacheReadTokens; result.cachedSamples = gateway.cacheReadSamples
        result.uncached = gateway.uncachedInputTokens; result.uncachedSamples = gateway.uncachedInputSampleCount
        result.output = gateway.tokens?.output; result.outputSamples = gateway.tokens?.outputSamples ?? 0
        result.reasoning = gateway.tokens?.reasoning; result.reasoningSamples = gateway.tokens?.reasoningSamples ?? 0
        result.inputSplit = GatewayTokenSplit.reported(gateway, input: true)
        result.outputSplit = GatewayTokenSplit.reported(gateway, input: false)
        return result
    }
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Token breakdown").font(PiFont.heading)
                TurnTokenBar(partition: TurnTokenPartition(accounting, input: true))
                TurnTokenBar(partition: TurnTokenPartition(accounting, input: false))
                if let pair = accounting.outputSplit, pair.samples < gateway.requests {
                    Text("Output split: \(pair.samples)/\(gateway.requests) requests supplied both counters.").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                }
                if let pair = accounting.inputSplit, pair.samples < gateway.requests {
                    Text("Input split: \(pair.samples)/\(gateway.requests) requests supplied both counters.").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                }
                Text("Gateway-reported · cached tokens are part of input; reasoning is part of output.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("analytics-token-breakdown")
    }
}
