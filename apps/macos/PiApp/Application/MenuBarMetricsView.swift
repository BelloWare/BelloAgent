import AppKit
import Combine

typealias MenuBarMetricsLoader = @MainActor (MenuBarPeriod, Date, Int) async throws -> MenuBarSnapshot
typealias MenuBarScopedMetricsLoader = @MainActor (MenuBarPeriod, Date, Int, Date?, String?) async throws -> MenuBarSnapshot
/// The status-bar charts switch between requests, reported cost and output rate.
enum MenuBarChartMetric: String, CaseIterable { case requests, tokens, cost, rate
    var title: String { switch self { case .requests: "Requests"; case .tokens: "Tokens"; case .cost: "Cost"; case .rate: "Output tok/s" } }
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
    private let scopedLoad: MenuBarScopedMetricsLoader?
    private(set) var selectedRange: ClosedRange<Date>?
    private(set) var workspaceID: String?
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

    init(load: @escaping MenuBarMetricsLoader, scopedLoad: MenuBarScopedMetricsLoader? = nil, period: MenuBarPeriod = .day, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, interval: Duration = .seconds(10), now: @escaping () -> Date = { Date() }) {
        self.load = load; self.readActiveSessions = activeSessions; self.readActivity = activity
        self.scopedLoad = scopedLoad; self.period = period
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
    /// One committed selection, never one SQL query per drag pixel. Hide the
    /// old totals until the new scope arrives; cancellation rejects stale reads.
    func setScope(range: ClosedRange<Date>?, workspaceID: String?) {
        guard selectedRange != range || self.workspaceID != workspaceID else { return }
        selectedRange = range; self.workspaceID = workspaceID; offset = 0; snapshot = nil; restart()
    }
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
        let load = load, scopedLoad = scopedLoad, range = selectedRange, workspace = workspaceID, now = now, interval = interval
        loading = true; notice = ""
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let value: MenuBarSnapshot
                    if let scopedLoad { value = try await scopedLoad(period, range?.upperBound ?? now(), offset, range?.lowerBound, workspace) }
                    else {
                        // Legacy loaders cannot express a selected interval or
                        // project. Never label their broader totals as scoped.
                        guard range == nil, workspace == nil else { throw CaptureFailure.unavailable }
                        value = try await load(period, now(), offset)
                    }
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

/// The menu bar panel's Usage tab: the period, the totals, a chart of
/// requests, tokens, cost or output rate per slice, the model distribution
/// and the details behind them. It follows its controller; each part touches
/// only what changed.
@MainActor final class MenuBarUsageView: DashView, PiKit.WidthSizing {
    let controller: MenuBarMetricsController
    private(set) var chartMetric: MenuBarChartMetric
    private(set) var selectedStart: Date? { didSet { if selectedStart != oldValue { refreshChart() } } }
    private var detailsOpen = false
    private var observer: ShellObserver!
    private var lastSnapshot: MenuBarSnapshot?

    private lazy var periodTabs = PiKit.Tabs(selection: controller.period, items: [MenuBarPeriod.day, .week, .retained].map { ($0, $0.title) }) { [weak self] in self?.controller.period = $0 }
    private let notice = ShellText("", font: PiKit.Font.caption, color: .piDanger)
    private let empty = UsageEmpty()
    // Totals
    private let tilesRow = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .top)
    // Chart
    private lazy var metricTabs = PiKit.Tabs(selection: chartMetric, items: MenuBarChartMetric.allCases.map { ($0, $0.title) }) { [weak self] in self?.chartMetric = $0; self?.refreshChart() }
    let chart = UsageChart()
    private let chartEmpty = PiKit.TextLine(PiKit.Line("No dispatched requests in this scope.", font: PiKit.Font.caption, color: .piInkSecondary))
    private let chartCaption = ShellText("", font: PiKit.Font.micro, color: .piInkTertiary)
    private let chartSelection = ShellText("", font: PiKit.Font.micro, color: .piInkSecondary)
    private lazy var chartEmptySlot = FixedHeight(chartEmpty, height: 110)
    private lazy var chartColumn = ShellStack(.vertical, spacing: PiSpacing.sm, [.view(metricTabs), .view(chart, .fill), .view(chartEmptySlot), .view(chartCaption, .fill), .view(chartSelection, .fill)])
    private lazy var chartCard = PiKit.card(chartColumn, padding: PiSpacing.md)
    // Models
    private let modelsColumn = ShellStack(.vertical, spacing: PiSpacing.sm)
    // Details
    private let detailsColumn = ShellStack(.vertical, spacing: PiSpacing.md)
    private lazy var details = DisclosureGroupView("Usage details", font: PiKit.Font.caption, color: .labelColor, content: detailsColumn)
    private lazy var column = ShellStack(.vertical, spacing: PiSpacing.lg, [.view(periodTabs), .view(notice, .fill), .view(tilesRow, .fill), .view(chartCard, .fill),
                                                                             .view(modelsColumn, .fill), .view(details, .fill), .view(empty, .fill)])

    init(controller: MenuBarMetricsController, chartMetric: MenuBarChartMetric = .requests) {
        self.controller = controller; self.chartMetric = chartMetric
        super.init(frame: .zero)
        addSubview(column)
        notice.setAccessibilityIdentifier("menu-bar-metrics-error")
        details.setAccessibilityIdentifier("menu-bar-usage-details")
        details.onToggle = { [weak self] in self?.detailsOpen = $0 }
        modelsColumn.setAccessibilityIdentifier("menu-bar-models")
        chart.onSelect = { [weak self] in self?.selectedStart = $0 }
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(controller)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func refresh() {
        periodTabs.selection = controller.period
        notice.set(controller.notice, color: .piDanger)
        notice.isHidden = controller.notice.isEmpty
        let snapshot = controller.snapshot
        for view in [tilesRow, chartCard, modelsColumn, details] as [NSView] { view.isHidden = snapshot == nil }
        empty.isHidden = snapshot != nil
        empty.text = controller.loading ? "Reading retained metrics…" : "Metrics unavailable"
        if let snapshot, snapshot != lastSnapshot {
            lastSnapshot = snapshot
            refreshTiles(snapshot)
            refreshModels(snapshot)
            refreshDetails(snapshot)
        }
        // The pager follows every update: a page read under way disables it.
        if let snapshot {
            pager.canPrevious = controller.offset > 0 && !controller.loading
            pager.canNext = snapshot.hasNext && !controller.loading
        }
        refreshChart()
        column.relayoutAll()
        needsLayout = true
        PiKit.sizeChanged(self)
    }

    private func refreshTiles(_ snapshot: MenuBarSnapshot) {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        tilesRow.items = [
            .view(dashStatTile(title: "Tokens consumed", value: menuBarTokens(tokens.total), caption: "\(tokens.samples)/\(totals.requests) requests reported", symbol: "number", tone: .accent), .fill),
            .view(dashStatTile(title: "Reported cost", value: gatewayUSD(totals.costUSD), caption: "\(totals.costSamples)/\(totals.requests) requests reported", symbol: "dollarsign.circle", tone: .success), .fill),
        ]
    }

    private func refreshChart() {
        guard let snapshot = controller.snapshot else { return }
        metricTabs.selection = chartMetric
        let buckets = snapshot.buckets
        let domain: ClosedRange<Date> = (buckets.first?.start ?? snapshot.until.addingTimeInterval(-3600))...snapshot.until
        let selected = selectedStart.flatMap { start in buckets.first { $0.start <= start && $0.end > start } }
        chart.isHidden = buckets.isEmpty
        chartEmptySlot.isHidden = !buckets.isEmpty
        chart.update(buckets: buckets, metric: chartMetric, domain: domain, selected: selected)
        chart.chart.setAccessibilityIdentifier("menu-bar-chart-\(chartMetric.rawValue)")
        chartCaption.set(caption(snapshot), color: .piInkTertiary)
        if let bucket = selected {
            chartSelection.set("\(bucket.start.formatted(date: .abbreviated, time: .shortened)): \(bucket.requests) requests · \(menuBarTokens(bucket.gateway.tokens?.total)) tokens · \(gatewayUSD(bucket.gateway.costUSD)) · \(MenuBarRateText.slice(bucket))", color: .piInkSecondary)
            chartSelection.isHidden = false
        } else { chartSelection.isHidden = true }
        chartColumn.relayoutAll()
    }
    private func caption(_ snapshot: MenuBarSnapshot) -> String {
        switch chartMetric {
        case .requests: "\(snapshot.counts.dispatched) dispatched requests · tool rounds and compactions included"
        case .tokens: "Input + output; cached input and reasoning are included once. \(snapshot.gateway.tokens?.samples ?? 0)/\(snapshot.gateway.requests) requests reported both."
        case .cost: "\(gatewayUSD(snapshot.gateway.costUSD)) reported · \(snapshot.gateway.costSamples)/\(snapshot.gateway.requests) requests reported cost"
        case .rate: MenuBarRateText.caption(snapshot)
        }
    }

    private lazy var modelsHeader = ShellSectionHeader("Model distribution", subtitle: "Requested → resolved · share of requests")
    private let modelsEmpty = PiKit.TextLine(PiKit.Line("No dispatched requests in this scope.", font: PiKit.Font.caption, color: .piInkSecondary))
    private let pageRange = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private lazy var pager = PiKit.Pager(center: pageRange, canPrevious: false, canNext: false,
                                         previous: { [weak self] in self?.controller.previousPage() }, next: { [weak self] in self?.controller.nextPage() })
    private let modelsNote = ShellText("Aliases such as auto-router stay separate from gateway-reported models. Alias echoes and missing evidence do not establish a resolved model.",
                                       font: PiKit.Font.micro, color: .piInkTertiary)
    /// Each route's row, kept while its route is listed: an open row stays
    /// open, and keeps the keyboard, through the panel's polls.
    private var modelRows: [MenuBarModelDistribution.ID: UsageModelRow] = [:]

    private func refreshModels(_ snapshot: MenuBarSnapshot) {
        var items: [ShellItem] = [.view(modelsHeader, .fill)]
        if snapshot.models.isEmpty { items.append(.view(modelsEmpty)) }
        var kept: [MenuBarModelDistribution.ID: UsageModelRow] = [:]
        for item in snapshot.models {
            let row = modelRows[item.id] ?? UsageModelRow(item: item)
            row.update(item: item)
            kept[item.id] = row
            items.append(.view(row, .fill))
        }
        modelRows = kept
        pageRange.line.text = "\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)"
        if snapshot.modelGroups > MenuBarSnapshot.pageSize { items.append(.view(pager)) }
        items.append(.view(modelsNote, .fill))
        modelsColumn.items = items
    }

    private func refreshDetails(_ snapshot: MenuBarSnapshot) {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        var usage: [ShellItem] = [
            .view(ShellText("Input \(menuBarTokens(tokens.input)) (\(tokens.inputSamples)/\(totals.requests)) · output \(menuBarTokens(tokens.output)) (\(tokens.outputSamples)/\(totals.requests))",
                            font: PiKit.Font.caption, color: .piInkSecondary), .fill),
        ]
        let reasoning = ShellText(reasoningUsageSummary(totals), font: PiKit.Font.caption, color: .piInkSecondary)
        reasoning.setAccessibilityIdentifier("menu-bar-reasoning")
        usage.append(.view(reasoning, .fill))
        if snapshot.costUnreported + snapshot.costInvalid + snapshot.costConflicts > 0 {
            usage.append(.view(ShellText("Cost: \(snapshot.costUnreported) unreported · \(snapshot.costInvalid) invalid · \(snapshot.costConflicts) conflicting. Missing amounts are excluded.",
                                         font: PiKit.Font.caption, color: .piInkTertiary), .fill))
        }
        let cacheHeader = ShellStack(.horizontal, spacing: 8, [
            .view(LabelView(PiKit.Line("Response cache", font: PiKit.Font.heading, color: .piInk), symbol: "memorychip")), .spacer(8),
            .view(PiKit.TextLine(PiKit.Line("\(totals.cacheHits + totals.cacheMisses)/\(totals.requests) reported", font: PiKit.Font.caption, color: .piInkSecondary)))])
        let cache = ShellStack(.vertical, spacing: 5, [.view(cacheHeader, .fill),
            .view(ShellText(totals.cacheLabel, font: PiKit.Font.caption, color: .piInkSecondary), .fill),
            .view(ShellText(totals.tokenCacheLabel, font: PiKit.Font.micro, color: .piInkTertiary), .fill)])
        usage.append(.view(PiKit.card(cache, padding: PiSpacing.md), .fill))
        let c = snapshot.counts
        let badges = PiKit.FlowView()
        var badgeViews = [PiKit.Badge(text: "\(c.running) running", tone: c.running > 0 ? .warning : .neutral, dot: true),
                          PiKit.Badge(text: "\(c.completed) completed", tone: .success, dot: true),
                          PiKit.Badge(text: "\(c.failed) failed", tone: c.failed > 0 ? .danger : .neutral, dot: true),
                          PiKit.Badge(text: "\(c.cancelled) cancelled", dot: true)]
        if c.truncated > 0 { badgeViews.append(PiKit.Badge(text: "\(c.truncated) truncated", tone: .warning, dot: true)) }
        if c.interrupted > 0 { badgeViews.append(PiKit.Badge(text: "\(c.interrupted) interrupted", tone: .warning, dot: true)) }
        for badge in badgeViews { badges.addSubview(badge) }
        let activity = ShellStack(.vertical, spacing: 6, [
            .view(ShellSectionHeader("\(c.dispatched) requests", subtitle: "\(snapshot.sessions) sessions · \(snapshot.workspaces) projects"), .fill),
            .view(badges, .fill),
            .view(PiKit.TextLine(PiKit.Line("All statuses · tool rounds included · \(snapshot.compactionRequests) compaction requests", font: PiKit.Font.micro, color: .piInkTertiary)))])
        var scope: [ShellItem] = [.view(ShellText("As of " + (snapshot.summaryReadAt ?? snapshot.until).formatted(date: .abbreviated, time: .standard), font: PiKit.Font.micro, color: .piInkTertiary), .fill)]
        if let from = snapshot.from {
            scope.append(.view(ShellText("\(from.formatted(date: .abbreviated, time: .shortened)) – \(snapshot.until.formatted(date: .abbreviated, time: .shortened))", font: PiKit.Font.micro, color: .piInkTertiary), .fill))
        }
        for text in ["Input includes provider cache once. Reasoning tokens and cost are included in output, not added to totals. Total tokens require both input and output. Each observed HTTP attempt counts once; hidden gateway retries are unavailable.",
                     MenuBarRateText.scope,
                     "Retained metadata only · \(snapshot.gateway.expiredRecords) expired records and \(snapshot.counts.unobservedDispatch) unobserved dispatches excluded. Refreshes every 10 seconds while open."] {
            scope.append(.view(ShellText(text, font: PiKit.Font.micro, color: .piInkTertiary), .fill))
        }
        let scopeColumn = ShellStack(.vertical, spacing: 4, scope)
        scopeColumn.toolTip = snapshot.observationHelp
        detailsColumn.items = [.view(ShellStack(.vertical, spacing: PiSpacing.sm, usage), .fill), .view(activity, .fill), .view(scopeColumn, .fill)]
        detailsColumn.padding = NSEdgeInsets(top: PiSpacing.sm, left: 0, bottom: 0, right: 0)
    }

    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() { super.layout(); column.frame = bounds }

    /// "Reading retained metrics…": body type, centred in 180 points.
    final class UsageEmpty: DashView {
        var text = "" { didSet { if oldValue != text { needsDisplay = true } } }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 180) }
        override func draw(_ dirtyRect: NSRect) {
            let line = PiKit.Line(text, font: PiKit.Font.body, color: .labelColor), size = line.size(scale: piScale)
            line.draw(at: CGPoint(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale)), scale: piScale)
        }
    }
}

/// The usage chart: its marks, the selected slice's rule, and the slice
/// under the pointer while it is pressed (`chartXSelection`); the arrow keys
/// step the selection when it has the keyboard.
@MainActor final class UsageChart: DashView {
    let chart = PiChartView()
    var onSelect: ((Date?) -> Void)?
    private var buckets: [MenuBarBucket] = []
    private var selected: MenuBarBucket?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(chart)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 110) }
    func update(buckets: [MenuBarBucket], metric: MenuBarChartMetric, domain: ClosedRange<Date>, selected: MenuBarBucket?) {
        self.buckets = buckets; self.selected = selected
        chart.spec = MenuBarUsageChartSpec.make(buckets: buckets, metric: metric, domain: domain, selected: selected)
    }
    override func layout() { super.layout(); chart.frame = bounds }
    private func date(at event: NSEvent) -> Date? {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = chart.resolved()
        guard geometry.plot.contains(point) || (point.x >= geometry.plot.minX && point.x <= geometry.plot.maxX) else { return nil }
        let x = min(max(point.x, geometry.plot.minX), geometry.plot.maxX)
        return Date(timeIntervalSinceReferenceDate: geometry.x.value(at: x))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onSelect?(date(at: event)) }
    override func mouseDragged(with event: NSEvent) { onSelect?(date(at: event)) }
    override func mouseUp(with event: NSEvent) { onSelect?(nil) }
    override func keyDown(with event: NSEvent) {
        let step = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
        guard step != 0, !buckets.isEmpty else { return super.keyDown(with: event) }
        let index = selected.flatMap { s in buckets.firstIndex { $0.id == s.id } } ?? buckets.count - 1
        onSelect?(buckets[max(0, min(buckets.count - 1, index + step))].start)
    }
}

/// A route of the distribution, folded to its alias, resolution and share;
/// open, its requests, cost and rate.
@MainActor final class UsageModelRow: DashView, PiKit.WidthSizing {
    private let group: DisclosureGroupView
    private let inset: ShellInset
    private(set) var item: MenuBarModelDistribution
    private let aliasLine = PiKit.TextLine(PiKit.Line("", font: .systemFont(ofSize: 13, weight: .semibold), color: .piInk))
    private let share = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private let resolution = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let arrow = PiKit.SymbolView(PiKit.Symbol("arrow.turn.down.right", size: 10.5, weight: .medium), color: .piInkSecondary)
    private let bar = PiKit.ShareBar(fraction: 0)
    private let cost = ShellText("", font: PiKit.Font.micro, color: .piInkTertiary)
    private let rate = ShellText("", font: PiKit.Font.micro, color: .piInkSecondary)
    private let content: ShellStack
    var isExpanded: Bool { get { group.isExpanded } set { group.isExpanded = newValue } }
    init(item: MenuBarModelDistribution) {
        self.item = item
        aliasLine.truncation = .middle
        resolution.truncation = .middle
        bar.setAccessibilityElement(false)
        let first = ShellStack(.horizontal, spacing: 8, alignment: .firstBaseline, [.view(aliasLine, .flexible), .spacer(8), .view(share)])
        let second = ShellStack(.horizontal, spacing: 5, alignment: .firstBaseline, [.view(arrow), .view(resolution, .flexible), .spacer(0)])
        content = ShellStack(.vertical, spacing: 5, [.view(first, .fill), .view(second, .fill), .view(FixedHeight(bar, height: 4, fills: true), .fill),
                                                     .view(cost, .fill), .view(rate, .fill)])
        group = DisclosureGroupView(Self.label(item), font: PiKit.Font.caption, color: .labelColor, content: content)
        let padded = ShellStack(.vertical, spacing: 0, padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md), [.view(group, .fill)])
        inset = ShellInset(padded)
        super.init(frame: .zero)
        addSubview(inset)
        apply()
    }
    /// The route's new figures, in the same row: its expansion, focus and
    /// accessibility element stay through the panel's polls.
    func update(item: MenuBarModelDistribution) {
        guard item != self.item else { return }
        self.item = item
        apply()
    }
    private func apply() {
        let alias = item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias
        aliasLine.line.text = alias; aliasLine.toolTip = item.requestedAlias
        share.line.text = "\(item.gateway.requests) · \(item.requestShare.formatted(.percent.precision(.fractionLength(1))))"
        let tone: NSColor = item.resolvedModel == nil ? .piWarning : .piInkSecondary
        resolution.line = PiKit.Line(item.resolutionLabel, font: PiKit.Font.caption, color: tone); resolution.toolTip = item.resolutionLabel
        arrow.color = tone
        bar.fraction = max(0, min(1, item.requestShare)); bar.tone = item.resolvedModel == nil ? .piWarning : .piAccent
        cost.set("\(gatewayUSD(item.gateway.costUSD))\(item.costShare.map { " · \($0.formatted(.percent.precision(.fractionLength(1)))) of reported cost" } ?? "") · \(item.gateway.costSamples)/\(item.gateway.requests) cost reported", color: .piInkTertiary)
        rate.set(MenuBarRateText.model(item), color: .piInkSecondary)
        group.title = Self.label(item)
        group.trailing = item.requestShare.formatted(.percent.precision(.fractionLength(0)))
        for view in [aliasLine, share, resolution] as [NSView] { view.invalidateIntrinsicContentSize() }
        content.relayoutAll()
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    static func label(_ item: MenuBarModelDistribution) -> String {
        let alias = item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias
        guard let resolved = item.resolvedModel, resolved != alias else { return alias }
        return alias + " → " + resolved
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: inset.content, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() { super.layout(); inset.frame = bounds }
}

/// Every output rate the usage panel quotes — its chart, the caption under
/// it, the slice under the pointer, each model row and the scope note — is
/// the settled decode rate the rest of the app shows: the completed requests'
/// output tokens after the first over their time from the first generated
/// token to the last, the figure the live monitor's average chart plots.
/// Never output over the whole dispatch-to-completion round trip, which counts
/// the wait for the first token as if it were decoding.
enum MenuBarRateText {
    static let basis = "output tokens after the first ÷ time from the first generated token to the last"
    static func rate(_ bucket: MenuBarBucket) -> Double? { bucket.gateway.settledThroughput.tokensPerSecond }
    static func point(_ bucket: MenuBarBucket) -> String {
        let settled = bucket.gateway.settledThroughput
        return "\(menuBarRate(settled.tokensPerSecond)) decode tokens per second over \(settled.samples) requests"
    }
    static func slice(_ bucket: MenuBarBucket) -> String { "\(menuBarRate(bucket.gateway.settledThroughput.tokensPerSecond)) decode tok/s" }
    static func caption(_ snapshot: MenuBarSnapshot) -> String {
        let settled = snapshot.gateway.settledThroughput
        return "\(menuBarRate(settled.tokensPerSecond)) tok/s over \(settled.samples) completed requests · " + basis
    }
    static func model(_ item: MenuBarModelDistribution) -> String {
        let settled = item.gateway.settledThroughput
        return "\(menuBarRate(settled.tokensPerSecond)) decode tok/s · \(settled.samples) completed requests timed"
    }
    static let scope = "Output tok/s is the decode rate: completed requests' output tokens after the first (hidden reasoning included) divided by their combined time from the first generated token to the last. The wait for the first token is not counted; replies under \(SettledThroughput.floorLabel) of generation and missing usage or timing are excluded."
}

func menuBarRate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return value.formatted(.number.precision(.fractionLength(3)))
}
