import AppKit
import Combine

enum MonitorRateMetric: String, CaseIterable { case live = "Live TPS", average = "Request average" }
enum MonitorShareMetric: String, CaseIterable { case tokens = "By tokens", cost = "By cost" }

/// The menu bar's live monitor: which project, the time range, the output
/// rate now and on average, its chart, the models' shares, the totals, and
/// the sessions working now. It follows the live store and its metrics
/// controller; each part compares what it shows and touches only what moved.
@MainActor final class LiveMonitorView: DashView, PiKit.WidthSizing {
    let live: LiveActivityStore
    let controller: MenuBarMetricsController
    var projects: [MonitorProject] = [] { didSet { if projects != oldValue { projectsChanged() } } }
    var openSession: (String) -> Void
    var openApp: () -> Void

    private(set) var project: String?
    private(set) var period = MenuBarPeriod.fifteenMinutes
    private(set) var zoom = MonitorChartZoom()
    private var metric: MonitorRateMetric?
    private var share = MonitorShareMetric.tokens
    private var palette = MonitorModelPalette()
    private var observer: ShellObserver!

    // Scope
    private lazy var projectPicker: PiKit.Dropdown<String?> = {
        let picker = PiKit.Dropdown<String?>(selection: nil, items: [(nil, "All projects")], compact: true, accessibilityName: "Project") { [weak self] in self?.setProject($0) }
        picker.setAccessibilityIdentifier("monitor-project")
        return picker
    }()
    private let counts = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private lazy var scopeRow = ShellStack(.horizontal, spacing: 12, [.view(projectPicker), .spacer(0), .view(counts)])
    // Ranges
    private lazy var ranges = MonitorRangePicker(periods: MenuBarPeriod.monitorPeriods) { [weak self] in self?.choose($0) }
    // Rates
    private let rateNow = PiKit.TextLine(PiKit.Line("—", font: PiKit.Font.monospacedDigits(PiKit.Font.display(29)), color: .piInk))
    private let rateNowUnit = PiKit.TextLine(PiKit.Line("tok/s", font: PiKit.Font.monospacedDigits(PiKit.Font.title(18)), color: .piInk))
    private let rateNowCaption = PiKit.TextLine(PiKit.Line("Now · reported output", font: PiKit.Font.caption, color: .piInkSecondary))
    private let rateNowCoverage = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private let rateAverage = PiKit.TextLine(PiKit.Line("—", font: PiKit.Font.monospacedDigits(PiKit.Font.title(24)), color: .labelColor))
    private let rateAverageUnit = PiKit.TextLine(PiKit.Line("tok/s", font: PiKit.Font.monospacedDigits(PiKit.Font.heading), color: .labelColor))
    private let rateAverageCaption = PiKit.TextLine(PiKit.Line("Avg decode / completed request", font: PiKit.Font.caption, color: .piInkSecondary))
    private let rateAverageCount = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private lazy var rates = MonitorRates(now: ShellStack(.horizontal, spacing: 5, alignment: .firstBaseline, [.view(rateNow), .view(rateNowUnit)]),
                                          nowCaption: rateNowCaption, nowCoverage: rateNowCoverage,
                                          average: ShellStack(.horizontal, spacing: 4, alignment: .firstBaseline, [.view(rateAverage), .view(rateAverageUnit)]),
                                          averageCaption: rateAverageCaption, averageCount: rateAverageCount)
    // Chart
    let chart = MonitorRateChart()
    private let selectedInterval = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkSecondary))
    // Distribution
    private lazy var shareTabs = PiKit.Tabs(selection: MonitorShareMetric.tokens, items: MonitorShareMetric.allCases.map { ($0, $0.rawValue) }) { [weak self] in self?.setShare($0) }
    private lazy var distributionHeader = ShellStack(.horizontal, spacing: 8, [
        .view(PiKit.TextLine(PiKit.Line("Model distribution", font: PiKit.Font.heading, color: .labelColor))), .spacer(4), .view(shareTabs)])
    let ring = ModelDistributionRing()
    private let route = MonitorRouteLine()
    private let distributionEmpty = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let routesContent = ShellStack(.vertical, spacing: 6)
    private var routeTexts: [String] = []
    private var routesPaged = false
    private lazy var routePager = MonitorRoutePager(previous: { [weak self] in self?.controller.previousPage() }, next: { [weak self] in self?.controller.nextPage() })
    private var errorKeys: [String] = []
    private lazy var routes = DisclosureGroupView("Requested → resolved models", font: PiKit.Font.caption, color: .piInkSecondary, content: routesContent)
    private lazy var distribution = ShellStack(.vertical, spacing: 10, [.view(distributionHeader, .fill), .view(ring, .fill), .view(route, .fill), .view(distributionEmpty), .view(routes, .fill)])
    // Totals
    private let outputFigure = MonitorFigure(title: "output tokens")
    private let costFigure = MonitorFigure(title: "reported cost")
    private let cacheFigure = MonitorFigure(title: "input cache hit")
    private lazy var totals = MonitorTotals(figures: [outputFigure, costFigure, cacheFigure])
    // Working
    private let workingTitle = PiKit.TextLine(PiKit.Line("Running now (0)", font: PiKit.Font.heading, color: .labelColor))
    private lazy var workingHeader = ShellStack(.horizontal, spacing: 8, [.view(workingTitle), .spacer(8),
        .view(PiKit.TextLine(PiKit.Line("Current tok/s", font: PiKit.Font.micro, color: .piInkSecondary)))])
    let sessionRows = MonitorSessionRows()
    private let quiet = PiKit.TextLine(PiKit.Line("All quiet. No sessions are working.", font: PiKit.Font.caption, color: .piInkSecondary))
    private lazy var openAll = PiKit.Button("Open all", style: .ghost) { [weak self] in self?.openApp() }
    private let errorRows = ShellStack(.vertical, spacing: 8)
    private lazy var errors = DisclosureGroupView("", font: PiKit.Font.caption, color: .piDanger, content: errorRows)
    private lazy var working = ShellStack(.vertical, spacing: 10, [.view(workingHeader, .fill), .view(sessionRows, .fill), .view(quiet), .view(openAll), .view(errors, .fill)])
    private let notice = ShellText("", font: PiKit.Font.caption, color: .piDanger)
    private let detailsContent = ShellStack(.vertical, spacing: 5)
    private lazy var details = DisclosureGroupView("Usage details", font: PiKit.Font.caption, color: .piInkSecondary, content: detailsContent)
    private lazy var column = ShellStack(.vertical, spacing: 12, [
        .view(scopeRow, .fill), .view(ranges, .fill), .view(rates, .fill), .view(chart, .fill), .view(selectedInterval),
        .view(DividerView(), .fill), .view(distribution, .fill), .view(DividerView(), .fill), .view(totals, .fill),
        .view(DividerView(), .fill), .view(working, .fill), .view(notice, .fill), .view(details, .fill)])

    init(live: LiveActivityStore, controller: MenuBarMetricsController, projects: [MonitorProject] = [],
         openSession: @escaping (String) -> Void, openApp: @escaping () -> Void) {
        self.live = live; self.controller = controller; self.projects = projects
        self.openSession = openSession; self.openApp = openApp
        super.init(frame: .zero)
        addSubview(column)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("menu-bar-activity")
        chart.onZoom = { [weak self] zoom in self?.setZoom(zoom) }
        chart.onSelectMetric = { [weak self] in self?.metric = $0; self?.refresh() }
        ring.setAccessibilityIdentifier("model-distribution-ring")
        details.content.setAccessibilityElement(false)
        notice.hugsLines = false
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(live)
        observer.observe(controller)
        projectsChanged()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    // MARK: State

    private var following: ClosedRange<Date> {
        let until = live.snapshot.observedAt
        return (period.start(until: until) ?? until.addingTimeInterval(-900))...until
    }
    private var domain: ClosedRange<Date> { zoom.domain(following: following) }
    private var rows: [MenuBarActivityRow] { controller.activity.runningRows.filter { project == nil || $0.workspaceID == project } }
    private func chartMetric(_ samples: [LiveRateSample]) -> MonitorRateMetric {
        metric ?? (samples.contains { !$0.hasGap(workspace: project) && !$0.models(workspace: project).isEmpty } ? .live : .average)
    }
    private var colorModels: [String] {
        Array(Set(Array(live.snapshot.rateHistory.modelNames) + live.snapshot.requests.map { $0.model ?? "\($0.alias) · \($0.identityStatus)" }
                  + MonitorDistribution.make(controller.snapshot?.models ?? []).map(\.id))).sorted()
    }

    private func setProject(_ value: String?) {
        guard project != value else { return }
        project = value
        controller.setScope(range: zoom.range, workspaceID: project)
        refresh()
    }
    private func choose(_ value: MenuBarPeriod) {
        let changed = period != value
        period = value
        // A zoom reset scopes the totals back to the whole period
        // (`onChange(of: zoom.range)`), even on the period already chosen.
        if zoom.range != nil || changed { zoom.reset(); controller.setScope(range: nil, workspaceID: project) }
        if changed { controller.period = value }
        refresh()
    }
    private func setZoom(_ next: MonitorChartZoom) {
        let rangeChanged = next.range != zoom.range
        zoom = next
        if rangeChanged { controller.setScope(range: next.range, workspaceID: project) }
        refresh()
    }
    private func setShare(_ value: MonitorShareMetric) { share = value; refresh() }
    private func projectsChanged() {
        guard projectPicker.superview != nil || true else { return }
        projectPicker.items = [(nil as String?, "All projects")] + projects.map { (Optional($0.id), $0.title) }
        if let project, !projects.contains(where: { $0.id == project }) { setProject(nil) }
    }

    // MARK: Refresh

    /// Brings every part up to the store and the controller.
    func refresh() {
        palette.include(colorModels)
        projectPicker.selection = project
        let rows = self.rows
        let generating = rows.filter { $0.phase == "model" || $0.phase == "compacting" }.count
        counts.line.text = "\(generating) generating · \(rows.count - generating) working"
        ranges.selection = period
        let current = live.snapshot.currentRates(workspace: project)
        rateNow.line.text = current.rate.map { menuBarRate($0) } ?? "—"
        rateNowCoverage.line.text = current.active == 0 ? "No active requests" : "\(current.reported)/\(current.active) requests reporting live"
        let settled = controller.snapshot?.gateway.settledThroughput
        rateAverage.line.text = settled?.tokensPerSecond.map { menuBarRate($0) } ?? "—"
        rateAverageCount.line.text = "\(settled?.samples ?? 0) measured requests"
        rates.toolTip = "Current is the sum of fresh gateway-reported output counter intervals; partial coverage is labeled. Average: " + SettledThroughput.explanation
        // Filtered once per update: the chart and its metric choice share it.
        let samples = live.snapshot.rateHistory.samples(in: domain)
        chart.update(MonitorRateChart.Inputs(samples: samples, usage: controller.snapshot, workspace: project, following: following, zoom: zoom,
                                             metric: chartMetric(samples), palette: palette))
        if let range = zoom.range {
            selectedInterval.line.text = "\(range.lowerBound.formatted(date: .omitted, time: .standard)) – \(range.upperBound.formatted(date: .omitted, time: .standard)) · selected interval"
            selectedInterval.isHidden = false
        } else { selectedInterval.isHidden = true }
        refreshDistribution()
        let gateway = controller.snapshot?.gateway
        outputFigure.set(gateway?.tokens?.output.map(MetricFormat.exactTokens) ?? "—")
        costFigure.set(monitorCost(gateway?.costUSD))
        cacheFigure.set(monitorCacheShare(gateway))
        totals.loading = controller.loading
        refreshWorking(rows)
        notice.set(controller.notice, color: .piDanger)
        notice.isHidden = controller.notice.isEmpty
        refreshDetails()
        column.relayoutAll()
        needsLayout = true
        PiKit.sizeChanged(self)
    }

    private func refreshDistribution() {
        let snapshot = controller.snapshot
        let models = MonitorDistribution.make(snapshot?.models ?? [])
        shareTabs.selection = share
        ring.update(models: models, palette: palette, metric: share, cost: snapshot?.gateway.costUSD)
        if let first = models.first {
            route.update(aliases: first.aliases.sorted().joined(separator: ", "), model: first.id)
            route.isHidden = false
        } else { route.isHidden = true }
        distributionEmpty.line.text = controller.loading ? "Reading model usage…" : "No reported model usage in this interval."
        distributionEmpty.isHidden = !models.isEmpty
        // Kept while unchanged: a selection in a route's text, or the
        // keyboard on the pager, survives the monitor's refreshes.
        let texts = models.map { "\($0.aliases.sorted().joined(separator: ", ")) → \($0.id)\n\(menuBarTokens($0.tokens)) output · \(gatewayUSD($0.cost))" }
        let paged = snapshot.map { $0.offset > 0 || $0.hasNext } ?? false
        if let snapshot { routePager.update(snapshot) }
        if texts != routeTexts || paged != routesPaged {
            routeTexts = texts; routesPaged = paged
            var items: [ShellItem] = texts.map { .view(ShellSelectableText($0, font: PiKit.Font.micro, color: .piInkSecondary), .fill) }
            if paged { items.append(.view(routePager)) }
            routesContent.items = items
            routesContent.padding = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        }
    }

    private func refreshWorking(_ rows: [MenuBarActivityRow]) {
        workingTitle.line.text = "Running now (\(rows.count))"
        sessionRows.update(rows: rows, snapshot: live.snapshot, project: project, openSession: openSession)
        quiet.isHidden = !rows.isEmpty
        openAll.title = "Open all \(rows.count) sessions"
        openAll.isHidden = rows.count <= 6
        let failed = controller.activity.rows.filter { $0.phase == "error" && (project == nil || $0.workspaceID == project) }
        errors.isHidden = failed.isEmpty
        errors.title = "\(failed.count) sessions with errors"
        let keys = failed.prefix(6).map { "\($0.id)\u{1}\($0.title)\u{1}\($0.errorDetail ?? $0.phaseLabel)" }
        if keys != errorKeys {
            errorKeys = keys
            errorRows.items = failed.prefix(6).map { row in
                let button = MonitorErrorRow(title: row.title, detail: row.errorDetail ?? row.phaseLabel) { [weak self] in self?.openSession(row.id) }
                return .view(button, .fill)
            }
        }
    }

    private func refreshDetails() {
        var lines: [String] = []
        if let s = controller.snapshot {
            lines += [
                "\(s.gateway.requests) dispatched requests · \(s.sessions) sessions · \(s.compactionRequests) compactions",
                "\(menuBarTokens(s.gateway.tokens?.input)) input · \(menuBarTokens(s.gateway.tokens?.output)) output · \(menuBarTokens(s.gateway.tokens?.reasoning)) reasoning (included in output)",
                "\(s.gateway.tokens?.outputSamples ?? 0)/\(s.gateway.requests) reported output · \(s.gateway.costSamples)/\(s.gateway.requests) reported cost",
                s.gateway.tokenCacheLabel, s.gateway.cacheLabel,
                "Reasoning cost \(gatewayUSD(s.gateway.reasoningCostUSD)) (included in total)",
                "Requests are scoped by dispatch record time. Live history is observed since launch, up to 24h, with older points averaged per minute. Missing usage and observation gaps are never inferred from text.",
                s.observationHelp,
            ]
        }
        lines.append("\(live.snapshot.utilityRequests) active utility requests · \(live.snapshot.gaps) observation gaps since launch")
        let current = detailsContent.items.compactMap { ($0.view as? ShellSelectableText)?.text }
        guard current != lines else { return }
        detailsContent.items = lines.map { .view(ShellSelectableText($0, font: PiKit.Font.micro, color: .piInkSecondary), .fill) }
        detailsContent.padding = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
    }

    // MARK: Layout

    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() {
        super.layout()
        column.frame = bounds
    }
}

func monitorCost(_ cost: Double?) -> String {
    guard let cost, cost.isFinite, cost >= 0 else { return "—" }
    return "$" + MetricFormat.atLeastCents(MetricFormat.preciseDecimal(cost))
}
func monitorCacheShare(_ gateway: GatewayTotals?) -> String {
    // A percentage requires paired observations; unmatched samples cannot be
    // divided by a different population's total input.
    guard let gateway, let cached = gateway.cacheReadTokens, let uncached = gateway.uncachedInputReportedTokens,
          gateway.uncachedInputSamples == gateway.cacheReadSamples, cached + uncached > 0 else { return "—" }
    return String(format: "%.3f%%", cached / (cached + uncached) * 100)
}

/// The two rates side by side: now (large, leading) and the settled average
/// (trailing), a hairline between them.
@MainActor final class MonitorRates: DashView, PiKit.WidthSizing {
    private let left: ShellStack, right: ShellStack
    private let rule = FillView(.piHairlineStrong)
    init(now: ShellStack, nowCaption: NSView, nowCoverage: NSView, average: ShellStack, averageCaption: NSView, averageCount: NSView) {
        left = ShellStack(.vertical, spacing: 3, alignment: .leading, [.view(now), .view(nowCaption), .view(nowCoverage)])
        right = ShellStack(.vertical, spacing: 3, alignment: .trailing, [.view(average), .view(averageCaption), .view(averageCount)])
        super.init(frame: .zero)
        for view in [left, rule, right] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat {
        let half = (width - 16 * 2 - 1) / 2
        return max(left.height(forWidth: half), 62, right.height(forWidth: half))
    }
    override func layout() {
        super.layout()
        let scale = piScale
        let half = PiKit.round((bounds.width - 16 * 2 - 1) / 2, scale)
        left.frame = CGRect(x: 0, y: 0, width: half, height: left.height(forWidth: half))
        rule.frame = CGRect(x: half + 16, y: 0, width: 1, height: 62)
        right.frame = CGRect(x: half + 16 + 1 + 16, y: 0, width: bounds.width - half - 33, height: right.height(forWidth: bounds.width - half - 33))
    }
}

/// The three totals, a hairline between each, and "Reading…" under the last
/// while a read is under way.
@MainActor final class MonitorTotals: DashView, PiKit.WidthSizing {
    private let figures: [MonitorFigure]
    private let rules = [FillView(.piHairline), FillView(.piHairline)]
    private let reading = PiKit.TextLine(PiKit.Line("Reading…", font: PiKit.Font.micro, color: .piInkSecondary))
    var loading = false { didSet { reading.isHidden = !loading } }
    init(figures: [MonitorFigure]) {
        self.figures = figures
        super.init(frame: .zero)
        for view in figures as [NSView] + rules as [NSView] { addSubview(view) }
        addSubview(reading); reading.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var figureHeight: CGFloat { figures.map { $0.intrinsicContentSize.height }.max() ?? 0 }
    func height(forWidth width: CGFloat) -> CGFloat { max(figureHeight, 40) }
    override func layout() {
        super.layout()
        let scale = piScale
        let width = (bounds.width - 12 * 4 - 2) / 3
        var x: CGFloat = 0
        for (index, figure) in figures.enumerated() {
            figure.frame = CGRect(x: PiKit.round(x, scale), y: 0, width: PiKit.round(width, scale), height: figureHeight)
            x += width + 12
            if index < rules.count { rules[index].frame = CGRect(x: PiKit.round(x, scale), y: 0, width: 1, height: 40); x += 1 + 12 }
        }
        let size = reading.intrinsicContentSize
        reading.frame = CGRect(x: bounds.width - size.width, y: bounds.height - size.height + 12, width: size.width, height: size.height)
    }
}

/// The time ranges as one pill row: each choice an equal share, the chosen
/// one on a stronger fill.
@MainActor final class MonitorRangePicker: DashView, PiKit.WidthSizing {
    private var buttons: [MenuBarPeriod: Choice] = [:]
    private let periods: [MenuBarPeriod]
    var selection: MenuBarPeriod = .fifteenMinutes { didSet { if oldValue != selection { for (period, button) in buttons { button.chosen = period == selection } } } }
    init(periods: [MenuBarPeriod], choose: @escaping (MenuBarPeriod) -> Void) {
        self.periods = periods
        super.init(frame: .zero)
        wantsLayer = true
        for period in periods {
            let button = Choice(title: period == .day ? "24h" : period.title) { choose(period) }
            button.setAccessibilityIdentifier("monitor-range-\(period.rawValue)")
            button.chosen = period == selection
            buttons[period] = button
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piFill); layer?.cornerRadius = 10; layer?.cornerCurve = .continuous
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    private var rowHeight: CGFloat { (buttons.values.first?.intrinsicContentSize.height ?? 28) }
    func height(forWidth width: CGFloat) -> CGFloat { rowHeight + 6 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: rowHeight + 6) }
    override func layout() {
        super.layout()
        let scale = piScale
        let count = CGFloat(periods.count)
        let width = (bounds.width - 6 - 3 * (count - 1)) / count
        for (index, period) in periods.enumerated() {
            buttons[period]?.frame = CGRect(x: PiKit.round(3 + CGFloat(index) * (width + 3), scale), y: 3, width: PiKit.round(width, scale), height: rowHeight)
        }
    }

    /// One range: its words, centred, in body medium; the chosen one inked on a stronger fill.
    final class Choice: PiKit.ButtonBase {
        let text: String
        var chosen = false { didSet { if oldValue != chosen { redrawContent(); refreshFace(animated: false); setAccessibilityValue(nil) } } }
        init(title: String, action: @escaping () -> Void) {
            text = title
            super.init(frame: .zero)
            pressScales = false
            onPress = action
            setAccessibilityLabel(title)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private var line: PiKit.Line { PiKit.Line(text, font: .systemFont(ofSize: 13, weight: .medium), color: chosen ? .piInk : .piInkSecondary) }
        override var intrinsicContentSize: NSSize { let size = line.size(scale: piScale); return NSSize(width: size.width, height: size.height + 14) }
        override func cornerRadius(for size: CGSize) -> CGFloat { 7 }
        override func styleFace() { fill.backgroundColor = chosen ? piCGColor(.piFillStrong) : CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            let size = line.size(scale: piScale)
            line.draw(at: CGPoint(x: PiKit.round((rect.width - size.width) / 2, piScale), y: 7), scale: piScale)
        }
        override func isAccessibilitySelected() -> Bool { chosen }
    }
}

/// The most-used route: "aliases → model", each cut in the middle.
@MainActor final class MonitorRouteLine: DashView {
    private let branch = PiKit.SymbolView(PiKit.Symbol("arrow.triangle.branch", size: PiKit.Font.captionSize), color: .piAccent)
    private let aliases = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .labelColor))
    private let arrow = PiKit.SymbolView(PiKit.Symbol("arrow.right", size: PiKit.Font.captionSize), color: .piAccent)
    private let model = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .labelColor))
    private lazy var row = ShellStack(.horizontal, spacing: 8, [.view(branch), .view(aliases, .flexible), .view(arrow), .view(model, .flexible)])
    override init(frame: NSRect) {
        super.init(frame: frame)
        aliases.truncation = .middle; model.truncation = .middle
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(aliases: String, model: String) {
        self.aliases.line.text = aliases; self.model.line.text = model
        toolTip = "Most-used route: \(aliases) → \(model)"
        row.changed()
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: row.height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() { super.layout(); row.frame = bounds }
}

/// Previous · "1–5 of 9" · Next under the route list.
@MainActor final class MonitorRoutePager: DashView {
    private let row: ShellStack
    private let back: PlainTextButton, forward: PlainTextButton
    private let range = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    init(previous: @escaping () -> Void, next: @escaping () -> Void) {
        back = PlainTextButton("Previous", font: PiKit.Font.micro, color: .piAccent, action: previous)
        forward = PlainTextButton("Next", font: PiKit.Font.micro, color: .piAccent, action: next)
        row = ShellStack(.horizontal, spacing: 8, [.view(back), .view(range), .view(forward)])
        super.init(frame: .zero)
        addSubview(row)
    }
    func update(_ snapshot: MenuBarSnapshot) {
        back.isEnabled = snapshot.offset != 0
        forward.isEnabled = snapshot.hasNext
        range.line.text = "\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)"
        row.changed()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: row.naturalWidth, height: row.height(forWidth: row.naturalWidth)) }
    override func layout() { super.layout(); row.frame = bounds }
}

/// A session that failed: its title and why, in danger ink, opening it.
@MainActor final class MonitorErrorRow: PiKit.ButtonBase, PiKit.WidthSizing {
    private let heading: PiKit.Line
    private let detail: ShellText
    init(title: String, detail: String, action: @escaping () -> Void) {
        self.heading = PiKit.Line(title, font: PiKit.Font.caption, color: .piDanger)
        self.detail = ShellText(detail, font: PiKit.Font.micro, color: .piDanger, maximumLines: 3)
        super.init(frame: .zero)
        pressScales = false
        onPress = action
        addSubview(self.detail)
        setAccessibilityLabel(title + ", " + detail)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { heading.lineHeight + 3 + detail.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func layout() {
        super.layout()
        detail.frame = CGRect(x: 0, y: heading.lineHeight + 3, width: bounds.width, height: detail.height(forWidth: bounds.width))
    }
    override func drawContent(in rect: CGRect) { heading.draw(in: CGRect(x: 0, y: 0, width: rect.width, height: heading.lineHeight), scale: piScale) }
}

/// The sessions working now, up to six, each in the place it first took:
/// a row under the pointer or with the keyboard on it keeps its section and
/// its place through a refresh, so it never moves out from under the click.
@MainActor final class MonitorSessionRows: DashView, PiKit.WidthSizing {
    private var order = LivePopupRowOrder()
    private var hovered: Set<String> = []
    private var focused: String?
    private var rows: [MenuBarActivityRow] = []
    private var snapshot = LivePopupSnapshot()
    private var project: String?
    private var openSession: (String) -> Void = { _ in }
    private var views: [String: Row] = [:]
    private let stack = ShellStack(.vertical, spacing: 0)
    override init(frame: NSRect) { super.init(frame: frame); addSubview(stack) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var held: Set<String> { hovered.union(focused.map { [$0] } ?? []) }

    func update(rows: [MenuBarActivityRow], snapshot: LivePopupSnapshot, project: String?, openSession: @escaping (String) -> Void) {
        // Another project is another list (`.id(project)`): nothing held carries over.
        if project != self.project { self.project = project; order = LivePopupRowOrder(); hovered = []; focused = nil; views = [:] }
        self.rows = rows; self.snapshot = snapshot; self.openSession = openSession
        reconcile()
    }
    private func reconcile() {
        order.reconcile(MenuBarActivitySnapshot(rows: rows), held: held)
        var items: [ShellItem] = []
        var kept: [String: Row] = [:]
        for row in order.rows(in: .working).prefix(6) {
            let view = views[row.id] ?? Row(id: row.id, owner: self)
            view.update(row, requests: snapshot.requests.filter { $0.id.session.session == row.id })
            kept[row.id] = view
            items.append(.view(view, .fill))
            items.append(.view(DividerView(), .fill))
        }
        views = kept
        stack.items = items
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    fileprivate func hover(_ id: String, _ inside: Bool) {
        let before = held
        if inside { hovered.insert(id) } else { hovered.remove(id) }
        if held != before { reconcile() }
    }
    fileprivate func focus(_ id: String, _ on: Bool) {
        let before = held
        if on { focused = id } else if focused == id { focused = nil }
        if held != before { reconcile() }
    }
    fileprivate func open(_ id: String) { openSession(id) }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() { super.layout(); stack.frame = bounds }

    /// One session: its title and phase (the button that opens it), the
    /// model it is on, and its current rate.
    final class Row: DashView {
        let id: String
        weak var owner: MonitorSessionRows?
        let button: Opener
        private let model = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
        private let rate = PiKit.TextLine(PiKit.Line("—", font: PiKit.Font.monospacedDigits(PiKit.Font.body), color: .labelColor))
        private var tracking: NSTrackingArea?
        init(id: String, owner: MonitorSessionRows) {
            self.id = id; self.owner = owner
            button = Opener()
            super.init(frame: .zero)
            model.truncation = .middle
            for view in [button, model, rate] as [NSView] { addSubview(view) }
            button.setAccessibilityIdentifier("menu-bar-running-session-\(id)")
            button.onPress = { [weak self] in guard let self else { return }; self.owner?.open(self.id) }
            button.onFocus = { [weak self] on in guard let self else { return }; self.owner?.focus(self.id, on) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        func update(_ row: MenuBarActivityRow, requests: [LiveRequestState]) {
            button.set(title: row.title, phase: row.phaseLabel + (row.utility ? " · Utility" : ""))
            button.isEnabled = row.actionable
            model.line.text = requests.first?.model ?? (requests.isEmpty ? row.resolvedModel : nil) ?? "Awaiting model"
            let rates = requests.compactMap(\.intervalRate)
            rate.line.text = rates.isEmpty ? "—" : menuBarRate(rates.reduce(0, +))
            rate.toolTip = "\(rates.count)/\(requests.count) active requests reporting live usage"
            needsLayout = true
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: button.intrinsicContentSize.height + 16) }
        override func layout() {
            super.layout()
            let scale = piScale
            let height = button.intrinsicContentSize.height
            let rateWidth: CGFloat = 68, modelWidth: CGFloat = 116
            let buttonWidth = max(0, bounds.width - rateWidth - modelWidth - 20)
            button.frame = CGRect(x: 0, y: 8, width: buttonWidth, height: height)
            let modelSize = model.intrinsicContentSize
            model.frame = CGRect(x: buttonWidth + 10, y: PiKit.round(8 + (height - modelSize.height) / 2, scale), width: min(modelWidth, modelSize.width), height: modelSize.height)
            let rateSize = rate.intrinsicContentSize
            rate.frame = CGRect(x: bounds.width - min(rateWidth, rateSize.width), y: PiKit.round(8 + (height - rateSize.height) / 2, scale),
                                width: min(rateWidth, rateSize.width), height: rateSize.height)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { owner?.hover(id, true) }
        override func mouseExited(with event: NSEvent) { owner?.hover(id, false) }
    }

    /// The title over the phase, the whole width a plain button.
    final class Opener: PiKit.ButtonBase {
        private var heading = PiKit.Line("", font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        private var phase = PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary)
        var onFocus: ((Bool) -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); pressScales = false; disabledOpacity = PiKit.plainDisabledDimming }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        func set(title: String, phase: String) {
            guard heading.text != title || self.phase.text != phase else { return }
            heading.text = title; self.phase.text = phase
            setAccessibilityLabel(title + ", " + phase)
            redrawContent()
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: heading.lineHeight + 3 + phase.lineHeight) }
        override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            heading.draw(in: CGRect(x: 0, y: 0, width: rect.width, height: heading.lineHeight), scale: piScale)
            phase.draw(in: CGRect(x: 0, y: heading.lineHeight + 3, width: rect.width, height: phase.lineHeight), scale: piScale)
        }
        override func becomeFirstResponder() -> Bool { let became = super.becomeFirstResponder(); if became { onFocus?(true) }; return became }
        override func resignFirstResponder() -> Bool { let resigned = super.resignFirstResponder(); if resigned { onFocus?(false) }; return resigned }
    }
}
