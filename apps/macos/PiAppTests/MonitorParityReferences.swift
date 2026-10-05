import AppKit
import Charts
import Combine
import SwiftUI
@testable import PiApp

// The SwiftUI live monitor and menu bar panel as they were in 0.1.119
// (9ca27dc8), renamed `Ref…`, for the side-by-side parity tests of their
// AppKit ports (`MonitorParityTests`). Only the tests use them.

@MainActor func refMonitorModel(_ index: Int) -> Color { Color(nsColor: .monitorModel(index)) }

fileprivate struct RefMenuBarHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 720 }

extension EnvironmentValues {
    var refMenuBarHeight: CGFloat { get { self[RefMenuBarHeightKey.self] } set { self[RefMenuBarHeightKey.self] = newValue } }
}


@MainActor struct RefMenuBarMetricsView: View {
    @StateObject private var controller: MenuBarMetricsController
    @StateObject private var monitor: MenuBarMetricsController
    private let live: LiveActivityStore
    private let readProjects: () -> [MonitorProject]
    @State private var projects: [MonitorProject] = []
    @State private var tab: MenuBarTab
    @State private var visible = false
    @State private var liveScroll: String?
    @State private var usageScroll: String?
    @Environment(\.refMenuBarHeight) private var height
    @Environment(\.openSettings) private var openSettings
    private let openApp: () -> Void, openReport: () -> Void, quit: () -> Void
    private let openSession: (String) -> Void
    init(load: @escaping MenuBarMetricsLoader, scopedLoad: MenuBarScopedMetricsLoader? = nil, projects: @escaping () -> [MonitorProject] = { [] }, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, live: LiveActivityStore? = nil, monitorController: MenuBarMetricsController? = nil, usageController: MenuBarMetricsController? = nil, initialTab: MenuBarTab = .live, openApp: @escaping () -> Void, openReport: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in }, quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        _controller = StateObject(wrappedValue: usageController ?? MenuBarMetricsController(load: load))
        _monitor = StateObject(wrappedValue: monitorController ?? MenuBarMetricsController(load: load, scopedLoad: scopedLoad, period: .fifteenMinutes, activeSessions: activeSessions, activity: activity, activityChanges: activityChanges))
        self.live = live ?? LiveActivityStore(); _tab = State(initialValue: initialTab); self.readProjects = projects
        self.openApp = openApp; self.openReport = openReport; self.openSession = openSession; self.quit = quit
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                Text("Bello Agent").font(PiFont.title(18)).foregroundStyle(Color.piInk)
                if tab == .live { RefMonitorFreshness(live: live) }
                else { Text("Usage").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                Spacer(minLength: 4)
                // Built when it opens: this panel refreshes every second while
                // it is shown, and a live pop-up button was rebuilt with it.
                PiMenuControl(label: "Monitor options", identifier: "monitorOptions") { [tab, monitor, controller, quit, openSettings] in
                    PiMenuEntry.button(tab == .live ? "Detailed usage" : "Live monitor") { self.tab = tab == .live ? .usage : .live }
                    PiMenuEntry.button("Refresh usage") { if tab == .live { monitor.refresh() } else { controller.refresh() } }
                    PiMenuEntry.button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                    PiMenuEntry.divider
                    PiMenuEntry.button("Quit Bello Agent") { quit() }
                } face: { hovering in
                    Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(hovering ? Color.piInk : Color.piInkSecondary)
                        .frame(width: 26, height: 26).background(hovering ? Color.piFillStrong : Color.clear, in: Circle())
                }
                .frame(width: 26, height: 26)
            }.padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            ZStack {
                ScrollView {
                    RefLiveMonitorView(live: live, controller: monitor, projects: projects, openSession: openSession, openApp: openApp).padding(18)
                }.scrollPosition(id: $liveScroll).opacity(tab == .live ? 1 : 0).allowsHitTesting(tab == .live).accessibilityHidden(tab != .live)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button("Back to live monitor") { tab = .live }.buttonStyle(.piGhost)
                        RefMenuBarUsageView(controller: controller)
                    }.padding(18)
                }.scrollPosition(id: $usageScroll).opacity(tab == .usage ? 1 : 0).allowsHitTesting(tab == .usage).accessibilityHidden(tab != .usage)
            }.frame(maxHeight: .infinity).clipped()
            Divider()
            HStack(spacing: 12) {
                Button(action: openApp) { Label("Open app", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }.buttonStyle(.piSecondaryCompact)
                Button(action: openReport) { Label("Usage report", systemImage: "chart.bar").frame(maxWidth: .infinity) }.buttonStyle(.piSecondaryCompact)
            }.padding(14)
        }.frame(width: MenuBarPanelLayout.width, height: height).background(Color(nsColor: .monitorCanvas)).tint(Color.piAccent)
            .piAnimation(PiMotion.quick, value: tab)
            .background(WindowVisibilityReader { value in visible = value; updateVisibility(); if value { projects = readProjects() } })
            .onChange(of: tab) { _, _ in updateVisibility() }
            .onDisappear { visible = false; updateVisibility() }
            .accessibilityIdentifier("menu-bar-metrics")
    }
    private func updateVisibility() {
        controller.setVisible(visible && tab == .usage)
        monitor.setVisible(visible && tab == .live)
        live.setVisible(visible && tab == .live)
    }
}

@MainActor fileprivate struct RefMonitorFreshness: View {
    @ObservedObject var live: LiveActivityStore
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(live.snapshot.disconnected ? Color.piWarning : live.snapshot.counts.total > 0 ? Color.piSuccess : Color.piInkSecondary).frame(width: 7, height: 7)
            Text(live.snapshot.disconnected ? "Disconnected" : live.snapshot.counts.total > 0 ? "Live" : "Idle").font(PiFont.caption)
                .foregroundStyle(live.snapshot.counts.total > 0 ? Color.piSuccess : Color.piInkSecondary)
        }.help(live.snapshot.freshnessLabel + ". Local observations, not a gateway health check.")
    }
}


@MainActor struct RefMenuBarUsageView: View {
    @ObservedObject var controller: MenuBarMetricsController
    @State private var chartMetric: MenuBarChartMetric
    @State private var showingUsageDetails = false
    @State private var chartSelection: Date?
    init(controller: MenuBarMetricsController, chartMetric: MenuBarChartMetric = .requests) {
        self.controller = controller; _chartMetric = State(initialValue: chartMetric)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.lg) {
            PiTabs(selection: $controller.period, items: [MenuBarPeriod.day, .week, .retained].map { ($0, $0.title) }).id("period")
            if !controller.notice.isEmpty { Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piDanger).accessibilityIdentifier("menu-bar-metrics-error") }
            if let snapshot = controller.snapshot {
                usage(snapshot).id("totals")
                charts(snapshot).id("chart")
                distribution(snapshot).id("models")
                DisclosureGroup("Usage details", isExpanded: $showingUsageDetails) {
                    VStack(alignment: .leading, spacing: PiSpacing.md) { usageDetails(snapshot); requestActivity(snapshot); scope(snapshot) }.padding(.top, PiSpacing.sm)
                }.font(PiFont.caption).id("details").accessibilityIdentifier("menu-bar-usage-details")
            } else {
                Text(controller.loading ? "Reading retained metrics…" : "Metrics unavailable").font(PiFont.body).frame(maxWidth: .infinity, minHeight: 180)
            }
        }.scrollTargetLayout()
    }

    /// Requests, cost or output rate per time slice of the selected period.
    private func charts(_ snapshot: MenuBarSnapshot) -> some View {
        let buckets = snapshot.buckets
        let domain: ClosedRange<Date> = (buckets.first?.start ?? snapshot.until.addingTimeInterval(-3600))...snapshot.until
        let axisFormat: Date.FormatStyle = domain.upperBound.timeIntervalSince(domain.lowerBound) <= 36 * 3600 ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiTabs(selection: $chartMetric, items: MenuBarChartMetric.allCases.map { ($0, $0.title) })
                if buckets.isEmpty {
                    Text("No dispatched requests in this scope.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(height: 110)
                } else {
                    Chart {
                        ForEach(buckets) { bucket in
                        switch chartMetric {
                        case .requests:
                            RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Count", 0), yEnd: .value("Count", bucket.requests))
                                .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                                .accessibilityLabel(bucket.start.formatted()).accessibilityValue("\(bucket.requests) requests")
                        case .tokens:
                            if let tokens = bucket.gateway.tokens?.total {
                                RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Tokens", 0), yEnd: .value("Tokens", tokens)).foregroundStyle(Color.piAccent)
                            }
                        case .cost:
                            if let cost = bucket.gateway.costUSD {
                                RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("USD", 0), yEnd: .value("USD", cost))
                                    .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                                    .accessibilityLabel(bucket.start.formatted()).accessibilityValue(bucket.gateway.costLabel)
                            }
                        case .rate:
                            if let rate = MenuBarRateText.rate(bucket) {
                                PointMark(x: .value("Time", bucket.start), y: .value("tok/s", rate)).foregroundStyle(Color.piAccent).symbolSize(22)
                                    .accessibilityLabel(bucket.start.formatted()).accessibilityValue(MenuBarRateText.point(bucket))
                            }
                        }
                        }
                        if let selected = selectedBucket(snapshot) { RuleMark(x: .value("Selected", selected.start)).foregroundStyle(Color.piInkTertiary) }
                    }
                    .chartXScale(domain: domain)
                    .chartXSelection(value: $chartSelection)
                    .focusable().onMoveCommand { direction in
                        let index = selectedBucket(snapshot).flatMap { b in buckets.firstIndex { $0.id == b.id } } ?? buckets.count - 1
                        let step = direction == .left ? -1 : direction == .right ? 1 : 0
                        chartSelection = buckets[max(0, min(buckets.count - 1, index + step))].start
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Color.piHairline)
                            // A cost axis reads as every amount does, cents at least.
                            if chartMetric == .cost, let usd = value.as(Double.self) {
                                AxisValueLabel { Text(compactGatewayUSD(usd)) }.foregroundStyle(Color.piInkTertiary)
                            } else {
                                AxisValueLabel().foregroundStyle(Color.piInkTertiary)
                            }
                        }
                    }
                    .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat).foregroundStyle(Color.piInkTertiary) } }
                    .frame(height: 110)
                    .accessibilityIdentifier("menu-bar-chart-\(chartMetric.rawValue)")
                }
                Text(chartCaption(snapshot)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                if let bucket = selectedBucket(snapshot) {
                    Text("\(bucket.start.formatted(date: .abbreviated, time: .shortened)): \(bucket.requests) requests · \(menuBarTokens(bucket.gateway.tokens?.total)) tokens · \(gatewayUSD(bucket.gateway.costUSD)) · \(MenuBarRateText.slice(bucket))")
                        .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func chartCaption(_ snapshot: MenuBarSnapshot) -> String {
        switch chartMetric {
        case .requests: "\(snapshot.counts.dispatched) dispatched requests · tool rounds and compactions included"
        case .tokens: "Input + output; cached input and reasoning are included once. \(snapshot.gateway.tokens?.samples ?? 0)/\(snapshot.gateway.requests) requests reported both."
        case .cost: "\(gatewayUSD(snapshot.gateway.costUSD)) reported · \(snapshot.gateway.costSamples)/\(snapshot.gateway.requests) requests reported cost"
        case .rate: MenuBarRateText.caption(snapshot)
        }
    }
    private func selectedBucket(_ snapshot: MenuBarSnapshot) -> MenuBarBucket? {
        guard let chartSelection else { return nil }
        return snapshot.buckets.first { $0.start <= chartSelection && $0.end > chartSelection }
    }

    private func usage(_ snapshot: MenuBarSnapshot) -> some View {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(alignment: .top, spacing: PiSpacing.sm) {
                PiStatTile(title: "Tokens consumed", value: menuBarTokens(tokens.total), caption: "\(tokens.samples)/\(totals.requests) requests reported", symbol: "number", tone: .accent)
                PiStatTile(title: "Reported cost", value: gatewayUSD(totals.costUSD), caption: "\(totals.costSamples)/\(totals.requests) requests reported", symbol: "dollarsign.circle", tone: .success)
            }
        }
    }

    private func usageDetails(_ snapshot: MenuBarSnapshot) -> some View {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            Text("Input \(menuBarTokens(tokens.input)) (\(tokens.inputSamples)/\(totals.requests)) · output \(menuBarTokens(tokens.output)) (\(tokens.outputSamples)/\(totals.requests))")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
            Text(reasoningUsageSummary(totals))
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("menu-bar-reasoning")
            if snapshot.costUnreported + snapshot.costInvalid + snapshot.costConflicts > 0 {
                Text("Cost: \(snapshot.costUnreported) unreported · \(snapshot.costInvalid) invalid · \(snapshot.costConflicts) conflicting. Missing amounts are excluded.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            PiCard(padding: PiSpacing.md) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Response cache", systemImage: "memorychip").font(PiFont.heading).foregroundStyle(Color.piInk)
                        Spacer()
                        Text("\(totals.cacheHits + totals.cacheMisses)/\(totals.requests) reported").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }
                    Text(totals.cacheLabel).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                    Text(totals.tokenCacheLabel).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func requestActivity(_ snapshot: MenuBarSnapshot) -> some View {
        let c = snapshot.counts
        return VStack(alignment: .leading, spacing: 6) {
            PiSectionHeader("\(c.dispatched) requests", subtitle: "\(snapshot.sessions) sessions · \(snapshot.workspaces) projects")
            PiFlow {
                PiBadge(text: "\(c.running) running", tone: c.running > 0 ? .warning : .neutral, dot: true)
                PiBadge(text: "\(c.completed) completed", tone: .success, dot: true)
                PiBadge(text: "\(c.failed) failed", tone: c.failed > 0 ? .danger : .neutral, dot: true)
                PiBadge(text: "\(c.cancelled) cancelled", dot: true)
                if c.truncated > 0 { PiBadge(text: "\(c.truncated) truncated", tone: .warning, dot: true) }
                if c.interrupted > 0 { PiBadge(text: "\(c.interrupted) interrupted", tone: .warning, dot: true) }
            }
            Text("All statuses · tool rounds included · \(snapshot.compactionRequests) compaction requests")
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
        }
    }

    private func distribution(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiSectionHeader("Model distribution", subtitle: "Requested → resolved · share of requests")
            if snapshot.models.isEmpty {
                Text("No dispatched requests in this scope.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            } else {
            }
            ForEach(snapshot.models) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        // Ids are cut in the middle so the numbers keep their column; the full id is in the tooltip.
                        Text(item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias)
                            .font(PiFont.body.weight(.semibold)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                            .help(item.requestedAlias)
                        Spacer(minLength: 8)
                        Text("\(item.gateway.requests) · \(item.requestShare.formatted(.percent.precision(.fractionLength(1))))")
                            .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary).fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").font(PiFont.micro)
                        Text(item.resolutionLabel).font(PiFont.caption).lineLimit(1).truncationMode(.middle).help(item.resolutionLabel)
                        Spacer(minLength: 0)
                    }.foregroundStyle(item.resolvedModel == nil ? Color.piWarning : Color.piInkSecondary)
                    GeometryReader { geometry in
                        Capsule().fill(Color.piFillStrong).overlay(alignment: .leading) {
                            Capsule().fill(item.resolvedModel == nil ? Color.piWarning : Color.piAccent)
                                .frame(width: geometry.size.width * max(0, min(1, item.requestShare)))
                        }
                    }.frame(height: 4).accessibilityHidden(true)
                    Text("\(gatewayUSD(item.gateway.costUSD))\(item.costShare.map { " · \($0.formatted(.percent.precision(.fractionLength(1)))) of reported cost" } ?? "") · \(item.gateway.costSamples)/\(item.gateway.requests) cost reported")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                    Text(MenuBarRateText.model(item))
                        .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    HStack {
                        Text(modelChartLabel(item)).lineLimit(1).truncationMode(.middle).help(modelChartLabel(item))
                        Spacer(minLength: 8)
                        Text(item.requestShare.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    }.font(PiFont.caption)
                }.padding(PiSpacing.md).piInset()
            }
            if snapshot.modelGroups > MenuBarSnapshot.pageSize {
                PiPager(previous: controller.previousPage, next: controller.nextPage, canPrevious: controller.offset > 0 && !controller.loading, canNext: snapshot.hasNext && !controller.loading) {
                    Text("\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)")
                }
            }
            Text("Aliases such as auto-router stay separate from gateway-reported models. Alias echoes and missing evidence do not establish a resolved model.")
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("menu-bar-models")
    }

    private func modelChartLabel(_ item: MenuBarModelDistribution) -> String {
        let alias = item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias
        guard let resolved = item.resolvedModel, resolved != alias else { return alias }
        return alias + " → " + resolved
    }
    private func scope(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("As of " + (snapshot.summaryReadAt ?? snapshot.until).formatted(date: .abbreviated, time: .standard))
            if let from = snapshot.from {
                Text("\(from.formatted(date: .abbreviated, time: .shortened)) – \(snapshot.until.formatted(date: .abbreviated, time: .shortened))")
            }
            Text("Input includes provider cache once. Reasoning tokens and cost are included in output, not added to totals. Total tokens require both input and output. Each observed HTTP attempt counts once; hidden gateway retries are unavailable.")
            Text(MenuBarRateText.scope)
            Text("Retained metadata only · \(snapshot.gateway.expiredRecords) expired records and \(snapshot.counts.unobservedDispatch) unobserved dispatches excluded. Refreshes every 10 seconds while open.")
        }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            .help(snapshot.observationHelp)
    }
}


@MainActor struct RefLiveMonitorView: View {
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
    private func chartMetric(_ samples: [LiveRateSample]) -> MonitorRateMetric {
        metric ?? (samples.contains { !$0.hasGap(workspace: project) && !$0.models(workspace: project).isEmpty } ? .live : .average)
    }

    private var colorModels: [String] {
        Array(Set(Array(live.snapshot.rateHistory.modelNames) + live.snapshot.requests.map { $0.model ?? "\($0.alias) · \($0.identityStatus)" } + MonitorDistribution.make(controller.snapshot?.models ?? []).map(\.id))).sorted()
    }
    var body: some View {
        // Filtered once per update: the chart and its metric choice share it.
        let samples = samples
        VStack(alignment: .leading, spacing: 12) {
            scope
            ranges
            rates
            RefMonitorRateChart(samples: samples, usage: controller.snapshot, workspace: project, following: following, zoom: $zoom, metric: chartMetric(samples), palette: palette, selectMetric: { metric = $0 })
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
            PiDropdown(selection: $project, items: [(nil as String?, "All projects")] + projects.map { (Optional($0.id), $0.title) }, compact: true, accessibilityName: "Project")
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
                    Text(controller.snapshot?.gateway.settledThroughput.tokensPerSecond.map { menuBarRate($0) } ?? "—").font(PiFont.title(24))
                    Text("tok/s").font(PiFont.heading)
                }.monospacedDigit()
                Text("Avg decode / completed request").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Text("\(controller.snapshot?.gateway.settledThroughput.samples ?? 0) measured requests").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.help("Current is the sum of fresh gateway-reported output counter intervals; partial coverage is labeled. Average: " + SettledThroughput.explanation)
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
            RefModelDistributionRing(models: models, palette: palette, metric: share, cost: snapshot?.gateway.costUSD)
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
            RefMonitorSessionRows(rows: rows, snapshot: live.snapshot, openSession: openSession).id(project)
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

@MainActor struct RefMonitorSessionRows: View {
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


@MainActor struct RefMonitorRateChart: View {
    let samples: [LiveRateSample]
    let usage: MenuBarSnapshot?
    let workspace: String?
    let following: ClosedRange<Date>
    @Binding var zoom: MonitorChartZoom
    let metric: MonitorRateMetric
    let palette: MonitorModelPalette
    let selectMetric: (MonitorRateMetric) -> Void
    var showsMetricSelection = true
    var chartHeight: CGFloat = 124
    @Environment(\.colorScheme) private var colorScheme
    /// Held, not observed: only the rule and the caption watch the pointer,
    /// so a mouse move never rebuilds the series or the marks.
    @State private var hover = RefMonitorChartHover()
    private var domain: ClosedRange<Date> { zoom.domain(following: following) }
    var body: some View {
        let domain = domain
        let series = MonitorRateSeries(samples: samples, domain: domain, workspace: workspace)
        let _ = MonitorChartRenderCount.built()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Output tok/s").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                Spacer(minLength: 0)
                if showsMetricSelection {
                    PiTabs(selection: Binding(get: { metric }, set: { selectMetric($0) }), items: MonitorRateMetric.allCases.map { ($0, $0.rawValue) })
                }
            }
            Chart {
                if metric == .live {
                    ForEach(series.points) { point in
                        AreaMark(x: .value("Time", point.date), y: .value("tok/s", point.rate), series: .value("Segment", "\(point.model):\(point.segment)"))
                            .foregroundStyle(refMonitorModel(palette.index(point.model)).opacity(0.60)).interpolationMethod(.linear)
                        LineMark(x: .value("Time", point.date), y: .value("Cumulative tok/s", point.cumulative), series: .value("Outline", "\(point.model):\(point.segment)"))
                            .foregroundStyle(refMonitorModel(palette.index(point.model))).lineStyle(StrokeStyle(lineWidth: 1.4))
                        // A single observation still has a visible mark.
                        PointMark(x: .value("Time", point.date), y: .value("Model tok/s", point.rate))
                            .foregroundStyle(refMonitorModel(palette.index(point.model))).symbolSize(series.points.count <= series.models.count ? 20 : 0)
                    }
                } else {
                    ForEach(usage?.buckets ?? []) { bucket in
                        if let rate = MonitorRateAverage.rate(bucket) {
                            PointMark(x: .value("Time", MonitorRateAverage.middle(bucket)), y: .value("tok/s", rate))
                                .foregroundStyle(Color.piBrandOrange).symbolSize(30)
                        }
                    }
                }
            }
            .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: true))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color.piHairline)
                    AxisValueLabel(format: domain.upperBound.timeIntervalSince(domain.lowerBound) < 180 ? .dateTime.minute().second() : .dateTime.hour().minute()).foregroundStyle(Color.piInkSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(Color.piHairline)
                    AxisValueLabel().foregroundStyle(Color.piInkSecondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        ZStack(alignment: .topLeading) {
                            if let brush = zoom.brush,
                               let a = proxy.position(forX: brush.lowerBound), let b = proxy.position(forX: brush.upperBound) {
                                Rectangle().fill(Color.piAccent.opacity(0.16))
                                    .overlay(Rectangle().stroke(Color.piAccent, lineWidth: 1))
                                    .frame(width: max(1, b - a), height: frame.height)
                                    .offset(x: frame.minX + a, y: frame.minY).allowsHitTesting(false)
                            }
                            RefMonitorHoverRule(hover: hover, domain: domain, plot: frame)
                            RefMonitorChartInteraction(plot: frame, domain: plotDomain(proxy, width: frame.width),
                                hover: { [hover] in hover.date = $0 },
                                drag: { start, end, width, held in zoom.update(startX: start, x: end, width: width, domain: held) },
                                finish: { horizontal, vertical in _ = zoom.finish(horizontal: horizontal, vertical: vertical) },
                                reset: { [hover] in zoom.reset(); hover.date = nil }, step: { [hover] in Self.move(hover, $0, domain: domain) })
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            // Rebuild the renderer on an intentional zoom/theme change. Swift
            // Charts can otherwise retain its former plot scale and resolved
            // dynamic colors while the surrounding labels have already changed.
            .id("\(colorScheme):\(metric.rawValue):\(zoom.range?.lowerBound.timeIntervalSince1970 ?? -1):\(zoom.range?.upperBound.timeIntervalSince1970 ?? -1)")
            .overlay {
                // Only what falls inside the plotted interval counts: retained
                // buckets outside it are not "timed requests in this interval".
                if metric == .live ? series.points.isEmpty : !(usage?.buckets ?? []).contains(where: { MonitorRateAverage.rate($0) != nil && domain.contains(MonitorRateAverage.middle($0)) }) {
                    Text(metric == .live ? "Awaiting live usage counters" : "No timed requests in this interval")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .padding(8).background(Color(nsColor: .monitorCanvas).opacity(0.95), in: RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false)
                }
            }
            .focusable().onMoveCommand { direction in Self.move(hover, direction == .left ? -1 : direction == .right ? 1 : 0, domain: domain) }
            .onExitCommand { if zoom.brush != nil { zoom.cancel() } else { zoom.reset(); hover.date = nil } }
            .accessibilityLabel(metric.rawValue + " chart. Drag horizontally to zoom, double-click or press Escape to reset. Arrow keys inspect samples; plus zooms the middle half.")
            .accessibilityIdentifier("monitor-rate-chart")
            RefMonitorChartCaption(hover: hover, series: series, buckets: usage?.buckets ?? [], metric: metric, domain: domain, brush: zoom.brush)
            HStack {
                Text("Drag to zoom").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                Spacer()
                if zoom.range != nil {
                    Button("Reset zoom") { zoom.reset() }.buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piAccent).accessibilityIdentifier("monitor-reset-zoom")
                }
            }
            if metric == .live, !series.models.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(series.models, id: \.self) { model in
                            Label { Text(model).lineLimit(1) } icon: { Circle().fill(refMonitorModel(palette.index(model))).frame(width: 7, height: 7) }
                                .font(PiFont.micro).help(model)
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: 17)
            }
        }.onChange(of: metric) { _, _ in hover.date = nil; zoom.cancel() }
            .onDisappear { zoom.cancel() }
    }
    private func plotDomain(_ proxy: ChartProxy, width: CGFloat) -> ClosedRange<Date> {
        guard let from = proxy.value(atX: 0, as: Date.self), let until = proxy.value(atX: width, as: Date.self), from < until else { return domain }
        return from...until
    }
    private static func move(_ hover: RefMonitorChartHover, _ direction: Int, domain: ClosedRange<Date>) {
        let step = domain.upperBound.timeIntervalSince(domain.lowerBound) / 24
        let value = (hover.date ?? domain.upperBound).addingTimeInterval(Double(direction) * step)
        hover.date = min(domain.upperBound.addingTimeInterval(-0.001), max(domain.lowerBound, value))
    }
}

/// Where the pointer is over a rate chart. Only the rule and the caption
/// observe it; the chart that owns it holds it without observing it.
@MainActor final class RefMonitorChartHover: ObservableObject {
    @Published var date: Date?
}

fileprivate struct RefMonitorHoverRule: View {
    @ObservedObject var hover: RefMonitorChartHover
    let domain: ClosedRange<Date>
    let plot: CGRect
    var body: some View {
        if let date = hover.date, domain.contains(date), domain.upperBound > domain.lowerBound {
            let x = plot.minX + plot.width * date.timeIntervalSince(domain.lowerBound) / domain.upperBound.timeIntervalSince(domain.lowerBound)
            Path { path in path.move(to: CGPoint(x: x, y: plot.minY)); path.addLine(to: CGPoint(x: x, y: plot.maxY)) }
                .stroke(Color.piInkSecondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)
        }
    }
}

fileprivate struct RefMonitorChartCaption: View {
    @ObservedObject var hover: RefMonitorChartHover
    let series: MonitorRateSeries
    let buckets: [MenuBarBucket]
    let metric: MonitorRateMetric
    let domain: ClosedRange<Date>
    let brush: ClosedRange<Date>?
    var body: some View {
        Text(caption).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
    }
    private var caption: String {
        if let brush {
            return "\(brush.lowerBound.formatted(date: .omitted, time: .standard)) – \(brush.upperBound.formatted(date: .omitted, time: .standard)) · release to zoom"
        }
        if let hover = hover.date {
            if metric == .average, let bucket = buckets.first(where: { hover >= $0.start && hover < $0.end }) {
                let rate = bucket.gateway.settledThroughput
                return "\(hover.formatted(date: .omitted, time: .shortened)) · \(menuBarRate(rate.tokensPerSecond)) tok/s decode · \(rate.samples) measured requests"
            }
            if metric == .live, let point = series.points.min(by: { abs($0.date.timeIntervalSince(hover)) < abs($1.date.timeIntervalSince(hover)) }),
               abs(point.date.timeIntervalSince(hover)) <= max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / 120) {
                let rate = series.points.filter { $0.bin == point.bin }.reduce(0) { $0 + $1.rate }
                return "\(point.date.formatted(date: .omitted, time: .standard)) · \(menuBarRate(rate)) observed tok/s across reporting requests"
            }
            return "\(hover.formatted(date: .omitted, time: .standard)) · no reported observation"
        }
        return metric == .live ? "Reported intervals · gaps stay empty · history since launch" : MonitorRateAverage.explanation
    }
}


/// AppKit owns mouse tracking inside the plot only. Wheel events continue up
/// to the popup's scroll view; leaving the plot during a drag clamps its end.
/// Keeping the input surface separate also exercises real native mouse events
/// in tests without requiring an unlocked global desktop.
@MainActor struct RefMonitorChartInteraction: NSViewRepresentable {
    let plot: CGRect
    let domain: ClosedRange<Date>
    let hover: (Date?) -> Void
    let drag: (Double, Double, Double, ClosedRange<Date>) -> Void
    let finish: (Double, Double) -> Void
    let reset: () -> Void
    let step: (Int) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.plot = plot; view.domain = domain
        view.hover = hover; view.drag = drag; view.finish = finish; view.reset = reset; view.step = step
    }
    final class Surface: NSView {
        var plot = CGRect.zero
        var domain = Date.distantPast...Date.distantFuture
        var hover: ((Date?) -> Void)?
        var drag: ((Double, Double, Double, ClosedRange<Date>) -> Void)?
        var finish: ((Double, Double) -> Void)?
        var reset: (() -> Void)?
        var step: ((Int) -> Void)?
        private var origin: CGPoint?
        private var capturedDomain: ClosedRange<Date>?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return plot.contains(local) ? super.hitTest(point) : nil
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard plot.contains(point) else { return }
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { origin = nil; capturedDomain = nil; reset?(); return }
            origin = point; capturedDomain = domain
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let capturedDomain else { return }
            let point = convert(event.locationInWindow, from: nil)
            let x = point.x - origin.x, y = point.y - origin.y
            guard abs(x) >= 8, abs(x) > abs(y) else { return }
            hover?(nil)
            drag?(origin.x - plot.minX, point.x - plot.minX, plot.width, capturedDomain)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let capturedDomain, abs(point.x - origin.x) >= 8, abs(point.x - origin.x) > abs(point.y - origin.y) {
                drag?(origin.x - plot.minX, point.x - plot.minX, plot.width, capturedDomain)
            }
            finish?(point.x - origin.x, point.y - origin.y)
            self.origin = nil; capturedDomain = nil
        }
        override func mouseMoved(with event: NSEvent) {
            guard origin == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            hover?(plot.contains(point) ? MonitorChartZoom.date(x: point.x - plot.minX, width: plot.width, domain: domain) : nil)
        }
        override func mouseExited(with event: NSEvent) { if origin == nil { hover?(nil) } }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: origin = nil; capturedDomain = nil; reset?()
            case 123: step?(-1)
            case 124: step?(1)
            case 24, 69: // + zooms the middle half for keyboard users.
                drag?(plot.width / 4, plot.width * 0.75, plot.width, domain); finish?(plot.width / 2, 0)
            case 27, 78: reset?()
            default: super.keyDown(with: event)
            }
        }
    }
}


/// Bounded native drawing; no chart engine or transcript work per live tick.
struct RefModelDistributionRing: View {
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
                        context.stroke(arc, with: .color(refMonitorModel(palette.index(row.id)).opacity(highlighted == nil || highlighted == row.id ? 1 : 0.25)), lineWidth: 15)
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
                        Circle().fill(refMonitorModel(palette.index(row.id))).frame(width: 7, height: 7)
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

