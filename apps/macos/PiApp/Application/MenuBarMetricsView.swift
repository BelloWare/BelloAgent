import SwiftUI
import AppKit
import Combine
import Charts

typealias MenuBarMetricsLoader = @MainActor (MenuBarPeriod, Date, Int) async throws -> MenuBarSnapshot
/// The status-bar charts switch between requests, reported cost and output rate.
enum MenuBarChartMetric: String, CaseIterable { case requests, cost, rate
    var title: String { switch self { case .requests: "Requests"; case .cost: "Cost"; case .rate: "Output tok/s" } }
}

/// Queries run on the bounded read-only report worker. Closing the panel cancels
/// polling; a cancelled or superseded read cannot replace the visible scope.
@MainActor final class MenuBarMetricsController: ObservableObject {
    @Published var period = MenuBarPeriod.day {
        didSet { if period != oldValue { offset = 0; snapshot = nil; restart() } }
    }
    @Published private(set) var snapshot: MenuBarSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published private(set) var offset = 0
    @Published private(set) var activeSessions = 0
    @Published private(set) var activity = MenuBarActivitySnapshot()
    private let load: MenuBarMetricsLoader
    private let readActiveSessions: @MainActor () -> Int
    private let readActivity: (@MainActor () -> MenuBarActivitySnapshot)?
    /// What says the panel's rows may have changed. Without one the panel
    /// counts when it opens and whenever it is asked to `refresh()`.
    private let activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)?
    private let now: () -> Date
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var activityObservation: AnyCancellable?
    private var activityRefresh: Task<Void, Never>?
    private var visible = false
    private var generation = 0
    /// Test seam: how many times the rows have actually been counted.
    private(set) var activityCounts = 0

    init(load: @escaping MenuBarMetricsLoader, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, interval: Duration = .seconds(10), now: @escaping () -> Date = { Date() }) {
        self.load = load; self.readActiveSessions = activeSessions; self.readActivity = activity
        self.activityChanges = activityChanges; self.interval = interval; self.now = now
    }
    deinit { task?.cancel(); activityRefresh?.cancel() }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; restart()
        activityObservation = nil
        activityRefresh?.cancel(); activityRefresh = nil
        guard value else { return }
        refreshActivity()
        // Counting every chat's phase, queue and unread state once a second
        // is work with nothing behind it. The workspace says when its rows
        // change; several changes in the same moment count once.
        activityObservation = activityChanges?().sink { [weak self] _ in self?.scheduleActivityRefresh() }
    }
    /// A trailing debounce never fires while several sessions continuously
    /// stream. Coalesce into a fixed window instead; read after @Published's
    /// will-change notifications have actually committed their values.
    private func scheduleActivityRefresh() {
        guard visible, activityRefresh == nil else { return }
        activityRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.visible else { return }
            self.activityRefresh = nil
            self.refreshActivity()
        }
    }
    func refresh() { if visible { refreshActivity() }; restart() }
    private func refreshActivity() {
        activityCounts += 1
        // Reassigning an unchanged snapshot republishes it and redraws the
        // whole panel.
        if let readActivity {
            let next = readActivity()
            if activity != next { activity = next }
            if activeSessions != next.running { activeSessions = next.running }
        } else {
            let next = max(0, readActiveSessions())
            if activeSessions != next { activeSessions = next }
        }
    }
    func previousPage() {
        guard offset > 0 else { return }
        offset = max(0, offset - MenuBarSnapshot.pageSize); restart()
    }
    func nextPage() {
        guard snapshot?.hasNext == true else { return }
        offset += MenuBarSnapshot.pageSize; restart()
    }
    private func restart() {
        task?.cancel(); task = nil; generation += 1; loading = false
        guard visible else { return }
        let generation = generation, period = period, offset = offset
        let load = load, now = now, interval = interval
        loading = true; notice = ""
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let value = try await load(period, now(), offset)
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    // Reassigning an identical snapshot every interval redrew
                    // the chart and the model table with the same numbers.
                    if self.snapshot != value { self.snapshot = value }
                    if self.loading { self.loading = false }
                    if !self.notice.isEmpty { self.notice = "" }
                    if offset > 0 && value.models.isEmpty {
                        // Retention can shrink the distribution while open.
                        self.offset = 0; self.restart(); return
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.loading = false; self.notice = error.localizedDescription
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}

@MainActor struct MenuBarMetricsView: View {
    @StateObject private var controller: MenuBarMetricsController
    @State private var chartMetric = MenuBarChartMetric.requests
    @State private var showingUsageDetails = false
    private let openApp: () -> Void
    private let openReport: () -> Void
    private let openSession: (String) -> Void

    init(load: @escaping MenuBarMetricsLoader, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, openApp: @escaping () -> Void, openReport: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in }) {
        _controller = StateObject(wrappedValue: MenuBarMetricsController(load: load, activeSessions: activeSessions, activity: activity, activityChanges: activityChanges))
        self.openApp = openApp; self.openReport = openReport; self.openSession = openSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PiSpacing.sm) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bello Agent").font(PiFont.title(18)).foregroundStyle(Color.piInk)
                    Text("\(controller.activity.running) running · \(controller.activity.generating) generating").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .accessibilityIdentifier("menu-bar-running-count")
                }
                Spacer()
                if controller.loading { ProgressView().controlSize(.small) }
                PiIconButton(symbol: "arrow.clockwise", label: "Refresh activity and usage", size: 28) { controller.refresh() }
            }.padding(PiSpacing.lg)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.lg) {
                    now(controller.activity)
                    VStack(alignment: .leading, spacing: PiSpacing.md) {
                        PiTabs(selection: $controller.period, items: MenuBarPeriod.allCases.map { ($0, $0.title) })
                        if !controller.notice.isEmpty {
                            Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piDanger)
                                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("menu-bar-metrics-error")
                        }
                        if let snapshot = controller.snapshot {
                            usage(snapshot)
                            charts(snapshot)
                            distribution(snapshot)
                            DisclosureGroup("Usage details", isExpanded: $showingUsageDetails) {
                                VStack(alignment: .leading, spacing: PiSpacing.md) {
                                    usageDetails(snapshot)
                                    requestActivity(snapshot)
                                    scope(snapshot)
                                }.padding(.top, PiSpacing.sm)
                            }.font(PiFont.caption.weight(.medium))
                                .accessibilityIdentifier("menu-bar-usage-details")
                        } else {
                            VStack(spacing: PiSpacing.sm) {
                                Image(systemName: "chart.bar.xaxis").font(.system(size: 26)).foregroundStyle(Color.piAccent)
                                Text(controller.loading ? "Reading retained metrics…" : "Metrics unavailable")
                                    .font(PiFont.title(17)).foregroundStyle(Color.piInk)
                                Text("Uses local request metadata; no model call is made.")
                                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                            }.frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                }.padding(PiSpacing.lg)
            }.frame(maxHeight: .infinity)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            HStack(spacing: PiSpacing.sm) {
                Button("Open Bello Agent", action: openApp).buttonStyle(.piPrimaryCompact)
                Button("Report", action: openReport).buttonStyle(.piSecondaryCompact)
                Spacer()
            }.padding(PiSpacing.md)
        }
        .frame(width: 428, height: 720)
        .background(Color.piContent)
        .tint(Color.piAccent)
        .background(WindowVisibilityReader(onChange: controller.setVisible))
        .onDisappear { controller.setVisible(false) }
        .accessibilityIdentifier("menu-bar-metrics")
    }

    /// Current work, using existing host state and reported accounting. Only
    /// the tiny elapsed labels tick; clocks do not poll history or providers.
    private func now(_ activity: MenuBarActivitySnapshot) -> some View {
        let rows = activity.runningRows
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiSectionHeader("Live activity", subtitle: rows.isEmpty ? "All quiet" : "\(activity.running) running · \(activity.generating) generating · \(activity.runningPending) queued inputs")
            if rows.isEmpty {
                Text("No sessions are running.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
            }
            VStack(spacing: 4) {
                ForEach(Array(rows.prefix(12))) { row in chatRow(row) }
            }
            if rows.count > 12 {
                Text("Showing 12 of \(rows.count) chats. Open Bello Agent to see all.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
        }.accessibilityIdentifier("menu-bar-activity")
    }
    private func chatRow(_ row: MenuBarActivityRow) -> some View {
        Button { openSession(row.id) } label: {
            HStack(spacing: PiSpacing.sm) {
                ZStack {
                    if row.running { ProgressView().controlSize(.mini) }
                    else if row.needsAttention { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(row.phase == "error" ? Color.piDanger : Color.piWarning) }
                    else { UnreadDot() }
                }.frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(PiFont.body.weight(.medium)).foregroundStyle(Color.piInk).lineLimit(1)
                    Text([row.phaseLabel, row.workspace].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(PiFont.caption).foregroundStyle(row.running ? Color.piAccent : Color.piInkSecondary).lineLimit(1)
                    if !row.model.isEmpty {
                        Text(row.model + (row.resolvedModel.map { " · last route: " + $0 } ?? ""))
                            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).help("Requested model: \(row.model)" + (row.resolvedModel.map { "\nLast reported route: " + $0 } ?? ""))
                    }
                    HStack(spacing: 6) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let elapsed = row.elapsed(at: context.date) { Text(TranscriptActivity.formatDuration(elapsed)).monospacedDigit() }
                        }
                        if let rate = row.latestRate { Text("Latest " + SessionRatePresentation.compactRate(rate)).help(SessionRatePresentation.explanation) }
                        if row.followUps + row.steering > 0 { Text("\(row.followUps + row.steering) queued") }
                    }.font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                    if row.tokens != nil || row.costUSD != nil {
                        Text("Session: \(menuBarTokens(row.tokens)) tokens · \(gatewayUSD(row.costUSD))")
                            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, PiSpacing.md).padding(.vertical, 7).piInset()
        }.buttonStyle(.plain).piPointer().accessibilityLabel("Open \(row.title), \(row.phaseLabel)")
            .accessibilityIdentifier("menu-bar-running-session-\(row.id)")
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
                    Chart(buckets) { bucket in
                        switch chartMetric {
                        case .requests:
                            RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Count", 0), yEnd: .value("Count", bucket.requests))
                                .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                                .accessibilityLabel(bucket.start.formatted()).accessibilityValue("\(bucket.requests) requests")
                        case .cost:
                            if let cost = bucket.gateway.costUSD {
                                RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("USD", 0), yEnd: .value("USD", cost))
                                    .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                                    .accessibilityLabel(bucket.start.formatted()).accessibilityValue(bucket.gateway.costLabel)
                            }
                        case .rate:
                            if let rate = bucket.historicalRate.tokensPerSecond {
                                LineMark(x: .value("Time", bucket.start), y: .value("tok/s", rate)).foregroundStyle(Color.piAccent).interpolationMethod(.monotone)
                                PointMark(x: .value("Time", bucket.start), y: .value("tok/s", rate)).foregroundStyle(Color.piAccent).symbolSize(22)
                                    .accessibilityLabel(bucket.start.formatted()).accessibilityValue("\(menuBarRate(rate)) output tokens per second over \(bucket.historicalRate.samples) requests")
                            }
                        }
                    }
                    .chartXScale(domain: domain)
                    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel().foregroundStyle(Color.piInkTertiary) } }
                    .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat).foregroundStyle(Color.piInkTertiary) } }
                    .frame(height: 110)
                    .accessibilityIdentifier("menu-bar-chart-\(chartMetric.rawValue)")
                }
                Text(chartCaption(snapshot)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func chartCaption(_ snapshot: MenuBarSnapshot) -> String {
        switch chartMetric {
        case .requests: "\(snapshot.counts.dispatched) dispatched requests · tool rounds and compactions included"
        case .cost: "\(gatewayUSD(snapshot.gateway.costUSD)) reported · \(snapshot.gateway.costSamples)/\(snapshot.gateway.requests) requests reported cost"
        case .rate: "\(menuBarRate(snapshot.historicalRate.tokensPerSecond)) tok/s over \(snapshot.historicalRate.samples) completed requests · output tokens ÷ dispatch-to-completion time"
        }
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
                Chart(snapshot.models) { item in
                    BarMark(x: .value("Requests", item.gateway.requests), y: .value("Model", modelChartLabel(item)))
                        .foregroundStyle(item.resolvedModel == nil ? Color.piWarning : Color.piBrandOrange).cornerRadius(3)
                        .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                            Text(item.requestShare.formatted(.percent.precision(.fractionLength(0)))).font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                        }
                        .accessibilityLabel(modelChartLabel(item)).accessibilityValue("\(item.gateway.requests) requests")
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(preset: .aligned) { value in
                    // A long model id must not squeeze the bars out of the popover: one
                    // line, cut in the middle, never wider than about two fifths of the chart.
                    AxisValueLabel {
                        Text(value.as(String.self) ?? "").font(PiFont.caption).foregroundStyle(Color.piInk)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 156, alignment: .trailing)
                    }
                } }
                .chartXScale(domain: 0...Double(max(1, snapshot.models.map(\.gateway.requests).max() ?? 1)) * 1.18)
                .frame(height: CGFloat(snapshot.models.count) * 24 + 8)
                .accessibilityIdentifier("menu-bar-model-chart")
            }
            ForEach(snapshot.models) { item in
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
                    Text("\(menuBarRate(item.historicalRate.tokensPerSecond)) historical tok/s · \(item.historicalRate.samples) completed requests timed")
                        .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                }.padding(PiSpacing.md).piInset().accessibilityElement(children: .combine)
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
            if let from = snapshot.from {
                Text("\(from.formatted(date: .abbreviated, time: .shortened)) – \(snapshot.until.formatted(date: .abbreviated, time: .shortened))")
            }
            Text("Input includes provider cache once. Reasoning tokens and cost are included in output, not added to totals. Total tokens require both input and output. Each observed HTTP attempt counts once; hidden gateway retries are unavailable.")
            Text("Output tok/s uses completed output tokens divided by their combined dispatch-to-completion time, including first-token latency. Missing usage or timing is excluded.")
            Text("Retained metadata only · \(snapshot.gateway.expiredRecords) expired records and \(snapshot.counts.unobservedDispatch) unobserved dispatches excluded. Refreshes every 10 seconds while open.")
        }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            .help(snapshot.observationHelp)
    }
}

private func menuBarRate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return value.formatted(.number.precision(.fractionLength(1)))
}
