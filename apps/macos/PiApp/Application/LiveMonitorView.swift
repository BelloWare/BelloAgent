import AppKit
import SwiftUI
import Charts

enum MonitorRateMetric: String, CaseIterable { case live = "Live TPS", average = "Request average" }
enum MonitorShareMetric: String, CaseIterable { case tokens = "By tokens", cost = "By cost" }

extension Color {
    static let monitorCanvas = piDynamic(light: NSColor(srgbRed: 0.985, green: 0.980, blue: 0.965, alpha: 1),
                                         dark: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1))
    static func monitorModel(_ index: Int) -> Color {
        if index == 6 { return .piInkSecondary }
        return [Color.piBrandOrange,
                .piDynamic(light: NSColor(srgbRed: 0.08, green: 0.48, blue: 0.37, alpha: 1), dark: NSColor(srgbRed: 0.48, green: 0.80, blue: 0.69, alpha: 1)),
                .piDynamic(light: NSColor(srgbRed: 0.48, green: 0.34, blue: 0.72, alpha: 1), dark: NSColor(srgbRed: 0.70, green: 0.61, blue: 0.96, alpha: 1)),
                .piInfo, .piWarning, .piDanger][index]
    }
}

@MainActor struct LiveMonitorView: View {
    @ObservedObject var live: LiveActivityStore
    @ObservedObject var controller: MenuBarMetricsController
    let projects: [MonitorProject]
    let openSession: (String) -> Void
    let openApp: () -> Void
    @State private var project: String?
    @State private var period = MenuBarPeriod.fifteenMinutes
    @State private var zoom = MonitorChartZoom()
    @State private var metric: MonitorRateMetric?
    @State private var share = MonitorShareMetric.tokens
    @State private var palette = MonitorModelPalette()
    @State private var routesExpanded = false
    @State private var coverageExpanded = false
    @State private var workingExpanded = false

    private var following: ClosedRange<Date> {
        let until = live.snapshot.observedAt
        return (period.start(until: until) ?? until.addingTimeInterval(-900))...until
    }
    private var domain: ClosedRange<Date> { zoom.domain(following: following) }
    private var rows: [MenuBarActivityRow] { controller.activity.runningRows.filter { project == nil || $0.workspaceID == project } }
    private var current: (rate: Double?, reported: Int, active: Int) { live.snapshot.currentRates(workspace: project) }
    private var samples: [LiveRateSample] { live.snapshot.rateHistory.samples(in: domain) }
    private var chartMetric: MonitorRateMetric { metric ?? (samples.contains { !$0.hasGap(workspace: project) && !$0.models(workspace: project).isEmpty } ? .live : .average) }

    private var colorModels: [String] {
        Array(Set(Array(live.snapshot.rateHistory.modelNames) + live.snapshot.requests.map { $0.model ?? "\($0.alias) · \($0.identityStatus)" } + MonitorDistribution.make(controller.snapshot?.models ?? []).map(\.id))).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scope
            ranges
            rates
            MonitorRateChart(samples: samples, usage: controller.snapshot, workspace: project, following: following, zoom: $zoom, metric: chartMetric, palette: palette, selectMetric: { metric = $0 })
            if let range = zoom.range {
                Text("\(range.lowerBound.formatted(date: .omitted, time: .standard)) – \(range.upperBound.formatted(date: .omitted, time: .standard)) · selected interval")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
            }
            Divider()
            distribution
            Divider()
            totals
            Divider()
            working
            if !controller.notice.isEmpty {
                Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piDanger).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Usage details", isExpanded: $coverageExpanded) { details }
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }
        .piStableLayout()
        .onAppear { palette.include(colorModels) }
        .onChange(of: colorModels) { _, names in palette.include(names) }
        .onChange(of: period) { _, value in zoom.reset(); controller.setScope(range: nil, workspaceID: project); controller.period = value }
        .onChange(of: project) { _, _ in controller.setScope(range: zoom.range, workspaceID: project) }
        .onChange(of: zoom.range) { _, value in controller.setScope(range: value, workspaceID: project) }
        .onChange(of: projects) { _, value in if let project, !value.contains(where: { $0.id == project }) { self.project = nil } }
        .accessibilityIdentifier("menu-bar-activity")
    }
    private var scope: some View {
        HStack(spacing: 12) {
            PiDropdown(selection: $project, items: [(nil as String?, "All projects")] + projects.map { (Optional($0.id), $0.title) }, compact: true)
                .accessibilityIdentifier("monitor-project")
            Spacer(minLength: 0)
            let generating = rows.filter { $0.phase == "model" || $0.phase == "compacting" }.count
            let other = rows.count - generating
            Text("\(generating) generating · \(other) working").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
        }
    }
    private var ranges: some View {
        HStack(spacing: 3) {
            ForEach(MenuBarPeriod.monitorPeriods) { value in
                Button { period = value; if zoom.range != nil { zoom.reset() } } label: {
                    Text(value == .day ? "24h" : value.title).font(PiFont.body.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(period == value ? Color.piFillStrong : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).foregroundStyle(period == value ? Color.piInk : Color.piInkSecondary)
                    .accessibilityAddTraits(period == value ? .isSelected : [])
                    .accessibilityIdentifier("monitor-range-\(value.rawValue)")
            }
        }.padding(3).background(Color.piFill, in: RoundedRectangle(cornerRadius: 10))
    }
    private var rates: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(current.rate.map { menuBarRate($0) } ?? "—").font(PiFont.display(29))
                    Text("tok/s").font(PiFont.title(18))
                }.foregroundStyle(Color.piInk).monospacedDigit()
                Text("Now · reported output").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Text(current.active == 0 ? "No active requests" : "\(current.reported)/\(current.active) requests reporting live")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.piHairlineStrong).frame(width: 1, height: 62)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(controller.snapshot?.historicalRate.tokensPerSecond.map { menuBarRate($0) } ?? "—").font(PiFont.title(24))
                    Text("tok/s").font(PiFont.heading)
                }.monospacedDigit()
                Text("Avg / completed request").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Text("\(controller.snapshot?.historicalRate.samples ?? 0) timed requests").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.help("Current is the sum of fresh gateway-reported output counter intervals; partial coverage is labeled. Average is reported output divided by total dispatch-to-completion time for completed requests in the chosen scope, including hidden reasoning and time to first content.")
    }
    private var totals: some View {
        let gateway = controller.snapshot?.gateway
        return HStack(alignment: .top, spacing: 12) {
            figure(gateway?.tokens?.output.map(MetricFormat.exactTokens) ?? "—", title: "output tokens")
            Rectangle().fill(Color.piHairline).frame(width: 1, height: 40)
            figure(monitorCost(gateway?.costUSD), title: "reported cost")
            Rectangle().fill(Color.piHairline).frame(width: 1, height: 40)
            figure(monitorCacheShare(gateway), title: "input cache hit")
        }.overlay(alignment: .bottomTrailing) {
            if controller.loading { Text("Reading…").font(PiFont.micro).foregroundStyle(Color.piInkSecondary).offset(y: 12) }
        }
    }
    private func figure(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(PiFont.title(22)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var distribution: some View {
        let snapshot = controller.snapshot
        let models = MonitorDistribution.make(snapshot?.models ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Model distribution").font(PiFont.heading)
                Spacer(minLength: 4)
                PiTabs(selection: $share, items: MonitorShareMetric.allCases.map { ($0, $0.rawValue) })
            }
            ModelDistributionRing(models: models, palette: palette, metric: share, cost: snapshot?.gateway.costUSD)
            if let route = models.first {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.piAccent)
                    Text(route.aliases.sorted().joined(separator: ", ")).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").foregroundStyle(Color.piAccent)
                    Text(route.id).lineLimit(1).truncationMode(.middle)
                }.font(PiFont.caption).help("Most-used route: \(route.aliases.sorted().joined(separator: ", ")) → \(route.id)")
            }
            if models.isEmpty { Text(controller.loading ? "Reading model usage…" : "No reported model usage in this interval.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
            DisclosureGroup("Requested → resolved models", isExpanded: $routesExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(models) { row in
                        Text("\(row.aliases.sorted().joined(separator: ", ")) → \(row.id)\n\(menuBarTokens(row.tokens)) output · \(gatewayUSD(row.cost))")
                            .font(PiFont.micro).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot, snapshot.offset > 0 || snapshot.hasNext {
                        HStack {
                            Button("Previous", action: controller.previousPage).disabled(snapshot.offset == 0)
                            Text("\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)")
                            Button("Next", action: controller.nextPage).disabled(!snapshot.hasNext)
                        }.font(PiFont.micro)
                    }
                }.padding(.top, 6)
            }.font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }
    }
    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Running now (\(rows.count))").font(PiFont.heading)
                Spacer()
                Text("Current tok/s").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }
            MonitorSessionRows(rows: rows, snapshot: live.snapshot, openSession: openSession).id(project)
            if rows.isEmpty { Text("All quiet. No sessions are working.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
            if rows.count > 6 { Button("Open all \(rows.count) sessions", action: openApp).buttonStyle(.piGhost) }
            let errors = controller.activity.rows.filter { $0.phase == "error" && (project == nil || $0.workspaceID == project) }
            if !errors.isEmpty {
                DisclosureGroup("\(errors.count) sessions with errors", isExpanded: $workingExpanded) {
                    ForEach(errors.prefix(6)) { row in
                        Button { openSession(row.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(PiFont.caption)
                                Text(row.errorDetail ?? row.phaseLabel).font(PiFont.micro).lineLimit(3)
                            }.foregroundStyle(Color.piDanger).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.font(PiFont.caption).foregroundStyle(Color.piDanger)
            }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let s = controller.snapshot {
                Text("\(s.gateway.requests) dispatched requests · \(s.sessions) sessions · \(s.compactionRequests) compactions")
                Text("\(menuBarTokens(s.gateway.tokens?.input)) input · \(menuBarTokens(s.gateway.tokens?.output)) output · \(menuBarTokens(s.gateway.tokens?.reasoning)) reasoning (included in output)")
                Text("\(s.gateway.tokens?.outputSamples ?? 0)/\(s.gateway.requests) reported output · \(s.gateway.costSamples)/\(s.gateway.requests) reported cost")
                Text(s.gateway.tokenCacheLabel)
                Text(s.gateway.cacheLabel)
                Text("Reasoning cost \(gatewayUSD(s.gateway.reasoningCostUSD)) (included in total)")
                Text("Requests are scoped by dispatch record time. Live history is observed since launch, up to 24h, with older points averaged per minute. Missing usage and observation gaps are never inferred from text.")
                Text(s.observationHelp)
            }
            Text("\(live.snapshot.utilityRequests) active utility requests · \(live.snapshot.gaps) observation gaps since launch")
        }.font(PiFont.micro).textSelection(.enabled).padding(.top, 6)
    }
}

func monitorCost(_ cost: Double?) -> String {
    guard let cost, cost.isFinite, cost >= 0 else { return "—" }
    return "$" + MetricFormat.preciseDecimal(cost)
}
func monitorCacheShare(_ gateway: GatewayTotals?) -> String {
    // A percentage requires paired observations; unmatched samples cannot be
    // divided by a different population's total input.
    guard let gateway, let cached = gateway.cacheReadTokens, let uncached = gateway.uncachedInputReportedTokens,
          gateway.uncachedInputSamples == gateway.cacheReadSamples, cached + uncached > 0 else { return "—" }
    return String(format: "%.3f%%", cached / (cached + uncached) * 100)
}

@MainActor struct MonitorSessionRows: View {
    let rows: [MenuBarActivityRow]
    let snapshot: LivePopupSnapshot
    let openSession: (String) -> Void
    @State private var order = LivePopupRowOrder()
    @State private var hovered: Set<String> = []
    @FocusState private var focused: String?
    private var held: Set<String> { hovered.union(focused.map { [$0] } ?? []) }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(order.rows(in: .working).prefix(6)) { row in
                let requests = snapshot.requests.filter { $0.id.session.session == row.id }
                let rates = requests.compactMap(\.intervalRate)
                HStack(spacing: 10) {
                    Button { openSession(row.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(PiFont.body.weight(.medium)).lineLimit(1)
                            Text(row.phaseLabel + (row.utility ? " · Utility" : "")).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!row.actionable).focused($focused, equals: row.id).accessibilityIdentifier("menu-bar-running-session-\(row.id)")
                    Text(requests.first?.model ?? (requests.isEmpty ? row.resolvedModel : nil) ?? "Awaiting model")
                        .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle).frame(width: 116, alignment: .leading)
                    Text(rates.isEmpty ? "—" : menuBarRate(rates.reduce(0, +))).font(PiFont.body).monospacedDigit().frame(width: 68, alignment: .trailing)
                        .help("\(rates.count)/\(requests.count) active requests reporting live usage")
                }.padding(.vertical, 8).onHover { value in if value { hovered.insert(row.id) } else { hovered.remove(row.id) } }
                Divider()
            }
        }.onAppear { reconcile() }.onChange(of: rows) { _, _ in reconcile() }.onChange(of: held) { _, _ in reconcile() }
    }
    private func reconcile() { order.reconcile(MenuBarActivitySnapshot(rows: rows), held: held) }
}
