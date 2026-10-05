import AppKit
import Combine

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

/// The report's throughput card: its title and the chart metric picker,
/// the live rate now, and the rate chart over the report's window. Only this
/// card follows the paced live snapshot; a chart tick never queries SQLite or
/// rebuilds the report's routing, cost or request tables.
@MainActor final class ReportThroughputPanel: DashView, PiKit.WidthSizing, PiKit.SizeObserver {
    let live: LiveActivityStore
    private(set) var snapshot: DashboardSnapshot
    private(set) var reportWindow: DashboardWindow
    private var palette: MonitorModelPalette
    /// The report's selection: the chart's zoom shows and follows it.
    private(set) var selection: DashboardBrush?
    /// The reader zoomed or reset the chart: the only way this card changes the selection.
    var select: (ClosedRange<Date>?) -> Void = { _ in }
    var registerModels: ([String]) -> Void = { _ in }
    private let observer = UUID().uuidString
    private var zoom = MonitorChartZoom()
    private var metric: MonitorRateMetric?
    private var liveObserver: ShellObserver!
    private var registered: Set<String> = []

    private let header: DashSectionHeader
    private let now = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.heading), color: .labelColor))
    private let coverage = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkSecondary))
    private lazy var nowRow = ShellStack(.horizontal, spacing: 8, [.view(now), .spacer(8), .view(coverage)])
    let chart = MonitorRateChart()
    private let note = ShellText("Showing completed requests matching your filters. Live history is available for whole projects.", font: PiKit.Font.micro, color: .piInkSecondary)
    private lazy var column = ShellStack(.vertical, spacing: 12, [.view(header, .fill), .view(nowRow, .fill), .view(chart, .fill), .view(note, .fill)])
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    private let visibility = WindowVisibilityView()

    init(live: LiveActivityStore, snapshot: DashboardSnapshot, window: DashboardWindow, palette: MonitorModelPalette, controls: NSView) {
        self.live = live; self.snapshot = snapshot; self.reportWindow = window; self.palette = palette
        header = DashSectionHeader("Throughput by model", accessory: controls)
        super.init(frame: .zero)
        addSubview(visibility); addSubview(card)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("analytics-throughput")
        visibility.onChange = { [weak self] visible in guard let self else { return }; self.windowVisible = visible; self.applyVisibility() }
        chart.onSelectMetric = { [weak self] in self?.metric = $0; self?.refresh() }
        chart.onZoom = { [weak self] next in
            guard let self else { return }
            let changed = next.range != self.zoom.range
            self.zoom = next
            // A drag in progress stays here; a committed zoom or a reset goes
            // to the report, whose selection comes back through `update`.
            if changed { self.select(next.range) }
            self.refresh()
        }
        // A card the report hides (an empty filter) does no live work.
        liveObserver = ShellObserver { [weak self] in guard let self, !self.isHiddenOrHasHiddenAncestor else { return }; self.refresh() }
        liveObserver.observe(live)
        refresh()
    }
    private var windowVisible = false
    private var lastHeight: CGFloat?
    /// Live updates while the window shows the card and the report has not hidden it.
    private func applyVisibility() { live.setVisible(windowVisible && window != nil && !isHiddenOrHasHiddenAncestor, owner: observer) }
    override func viewDidHide() { super.viewDidHide(); applyVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); applyVisibility(); refresh() }
    /// Its parts' size changes stop here and go on only as a change of the card's height.
    func contentSizeChanged() { needsLayout = true; reportSize() }
    /// Tells the page only when the card's height moved: a live tick that
    /// changes figures, not size, measures nothing else.
    private func reportSize() {
        guard bounds.width > 0 else { PiKit.sizeChanged(self); return }
        let height = self.height(forWidth: bounds.width)
        guard height != lastHeight else { return }
        lastHeight = height
        PiKit.sizeChanged(self)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { live.setVisible(false, owner: observer) }
    }

    func update(snapshot: DashboardSnapshot, window: DashboardWindow, palette: MonitorModelPalette, selection: DashboardBrush?) {
        self.snapshot = snapshot; self.reportWindow = window; self.palette = palette
        if selection != self.selection || selection == nil && zoom.range != nil {
            self.selection = selection
            // The selection drives the zoom: a refresh that keeps it keeps the
            // zoom, one that drops it (or a cleared chip) resets it.
            zoom.show(selection.map { $0.from...$0.until })
        }
        refresh()
    }
    private func chosenMetric(_ samples: [LiveRateSample]) -> MonitorRateMetric {
        guard snapshot.filter.supportsProjectLiveHistory else { return .average }
        return metric ?? (samples.contains { !$0.hasGap(workspace: snapshot.filter.workspaceID) && !$0.models(workspace: snapshot.filter.workspaceID).isEmpty } ? .live : .average)
    }
    private var retained: MenuBarSnapshot {
        MenuBarSnapshot(period: .day, from: snapshot.filter.from, until: snapshot.filter.until,
            counts: snapshot.scopeCounts, gateway: snapshot.gateway, workspaces: 0, sessions: 0,
            compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: [], modelGroups: 0, offset: 0,
            buckets: snapshot.buckets.map { MenuBarBucket(id: $0.id, start: $0.start, end: $0.end, gateway: $0.gateway) })
    }
    func refresh() {
        let names = live.snapshot.rateHistory.modelNames
        if !names.isSubset(of: registered) { registered.formUnion(names); registerModels(Array(names)) }
        let liveDomain = ReportThroughputDomain.live(reportWindow, observedAt: live.snapshot.observedAt)
        // Filtered once per update: the metric choice and the chart share it.
        let samples = live.snapshot.rateHistory.samples(in: zoom.domain(following: liveDomain))
        let metric = chosenMetric(samples)
        let whole = snapshot.filter.supportsProjectLiveHistory
        if whole {
            let current = live.snapshot.currentRates(workspace: snapshot.filter.workspaceID)
            now.line.text = "Now \(menuBarRate(current.rate)) tok/s"
            coverage.line.text = "\(current.reported)/\(current.active) requests reporting live"
        }
        nowRow.isHidden = !whole
        note.isHidden = whole
        chart.update(MonitorRateChart.Inputs(samples: samples, usage: retained, workspace: snapshot.filter.workspaceID,
                                             following: ReportThroughputDomain.following(metric: metric, live: liveDomain, retained: snapshot.filter),
                                             zoom: zoom, metric: metric, palette: palette, showsMetricSelection: whole, chartHeight: 180))
        column.relayoutAll()
        reportSize()
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() { super.layout(); visibility.frame = .zero; card.frame = bounds }
}

/// The sessions running now in the report's project, as the monitor lists them.
@MainActor final class ReportActiveSessions: DashView, PiKit.WidthSizing, PiKit.SizeObserver {
    let live: LiveActivityStore
    private var workspaceID: String?
    private let activity: () -> MenuBarActivitySnapshot
    private let openSession: (String) -> Void
    private let observer = UUID().uuidString
    private var liveObserver: ShellObserver!
    private let header = DashSectionHeader("Active sessions", subtitle: "")
    private let rows = MonitorSessionRows()
    private let quiet = PiKit.TextLine(PiKit.Line("All quiet. No sessions are working.", font: PiKit.Font.caption, color: .piInkSecondary))
    private let more = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private lazy var column = ShellStack(.vertical, spacing: 8, [.view(header, .fill), .view(rows, .fill), .view(quiet), .view(more)])
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    private let visibility = WindowVisibilityView()
    init(live: LiveActivityStore, workspaceID: String?, activity: @escaping () -> MenuBarActivitySnapshot, openSession: @escaping (String) -> Void) {
        self.live = live; self.workspaceID = workspaceID; self.activity = activity; self.openSession = openSession
        super.init(frame: .zero)
        addSubview(visibility); addSubview(card)
        visibility.onChange = { [weak self] visible in guard let self else { return }; self.windowVisible = visible; self.applyVisibility() }
        // A card the report hides (an empty filter) does no live work.
        liveObserver = ShellObserver { [weak self] in guard let self, !self.isHiddenOrHasHiddenAncestor else { return }; self.refresh() }
        liveObserver.observe(live)
        refresh()
    }
    private var windowVisible = false
    private var lastHeight: CGFloat?
    /// Live updates while the window shows the card and the report has not hidden it.
    private func applyVisibility() { live.setVisible(windowVisible && window != nil && !isHiddenOrHasHiddenAncestor, owner: observer) }
    override func viewDidHide() { super.viewDidHide(); applyVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); applyVisibility(); refresh() }
    /// Its parts' size changes stop here and go on only as a change of the card's height.
    func contentSizeChanged() { needsLayout = true; reportSize() }
    /// Tells the page only when the card's height moved: a live tick that
    /// changes figures, not size, measures nothing else.
    private func reportSize() {
        guard bounds.width > 0 else { PiKit.sizeChanged(self); return }
        let height = self.height(forWidth: bounds.width)
        guard height != lastHeight else { return }
        lastHeight = height
        PiKit.sizeChanged(self)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { live.setVisible(false, owner: observer) }
    }
    func update(workspaceID: String?) { if self.workspaceID != workspaceID { self.workspaceID = workspaceID }; refresh() }
    func refresh() {
        let running = activity().runningRows.filter { workspaceID == nil || $0.workspaceID == workspaceID }
        header.setSubtitle("Running now in the selected project · \(running.count) sessions")
        rows.update(rows: running, snapshot: live.snapshot, project: workspaceID, openSession: openSession)
        quiet.isHidden = !running.isEmpty
        more.line.text = "Showing 6 of \(running.count) running sessions"
        more.isHidden = running.count <= 6
        column.relayoutAll()
        reportSize()
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() { super.layout(); visibility.frame = .zero; card.frame = bounds }
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

/// Each requested alias, branching to the models the gateway returned for it.
@MainActor final class ModelRoutingMap: DashView, PiKit.WidthSizing {
    private var rows: [DashboardModelSummary] = []
    private var palette = MonitorModelPalette()
    private var loading = false
    private var showAll = false
    private let column = ShellStack(.vertical, spacing: 14)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(card)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("analytics-model-routing")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(rows: [DashboardModelSummary], palette: MonitorModelPalette, loading: Bool) {
        guard rows != self.rows || palette != self.palette || loading != self.loading || column.items.isEmpty else { return }
        self.rows = rows; self.palette = palette; self.loading = loading
        rebuild()
    }
    private var aliases: [String] { Array(Set(rows.map(\.alias))).sorted() }
    private func rebuild() {
        var items: [ShellItem] = [
            .view(PiKit.TextLine(PiKit.Line("Model routing", font: PiKit.Font.heading, color: .labelColor))),
            .view(PiKit.TextLine(PiKit.Line("Requested → returned by the gateway", font: PiKit.Font.micro, color: .piInkSecondary))),
        ]
        if rows.isEmpty {
            items.append(.view(PiKit.TextLine(PiKit.Line(loading ? "Reading routes…" : "No model routes reported in this range.", font: PiKit.Font.caption, color: .piInkSecondary))))
        }
        for alias in aliases.prefix(showAll ? 64 : 2) {
            let destinations = rows.filter { $0.alias == alias }
            items.append(.view(RoutingGroup(alias: alias, destinations: Array(destinations.prefix(showAll ? 64 : 4)), palette: palette), .fill))
        }
        if aliases.count > 2 || aliases.contains(where: { alias in rows.filter { $0.alias == alias }.count > 4 }) {
            items.append(.view(PiKit.Button(showAll ? "Show fewer routes" : "Show all \(rows.count) routes", style: .ghost) { [weak self] in
                guard let self else { return }; self.showAll.toggle(); self.rebuild()
            }))
        }
        column.items = items
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 350)) }
    override func layout() { super.layout(); card.frame = bounds }

    /// An alias in its box, curves to each of its models.
    final class RoutingGroup: DashView, PiKit.WidthSizing {
        private let aliasBox: AliasBox
        private let branches: Branches
        private let destinations: [Destination]
        init(alias: String, destinations: [DashboardModelSummary], palette: MonitorModelPalette) {
            aliasBox = AliasBox(alias: alias)
            branches = Branches(count: destinations.count)
            self.destinations = destinations.map { Destination(alias: alias, row: $0, color: .monitorModel(palette.index($0.distributionID))) }
            super.init(frame: .zero)
            addSubview(aliasBox); addSubview(branches)
            for view in self.destinations { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func layoutParts(_ width: CGFloat) -> (CGFloat, [CGRect]) {
            let inner = max(0, width - 116 - 30)
            var y: CGFloat = 0
            var frames: [CGRect] = []
            for view in destinations {
                let h = view.height(forWidth: inner)
                frames.append(CGRect(x: 146, y: y, width: inner, height: h))
                y += h + 8
            }
            let right = destinations.isEmpty ? 0 : y - 8
            return (max(right, aliasBox.height(forWidth: 116)), frames)
        }
        func height(forWidth width: CGFloat) -> CGFloat { layoutParts(width).0 }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 350)) }
        override func layout() {
            super.layout()
            let (height, frames) = layoutParts(bounds.width)
            let box = aliasBox.height(forWidth: 116)
            aliasBox.frame = CGRect(x: 0, y: PiKit.round((height - box) / 2, piScale), width: 116, height: box)
            branches.frame = CGRect(x: 116, y: 0, width: 30, height: height)
            // The destinations' column sits in the middle of the row when the alias is taller.
            let right = frames.last.map { $0.maxY } ?? 0
            let offset = PiKit.round((height - right) / 2, piScale)
            for (view, frame) in zip(destinations, frames) { view.frame = frame.offsetBy(dx: 0, dy: offset) }
        }
    }
    /// The alias: a branch glyph over its name, on a soft fill.
    final class AliasBox: DashView, PiKit.WidthSizing {
        private let symbol = PiKit.SymbolView(PiKit.Symbol("arrow.triangle.branch", size: 18), color: .labelColor)
        private let name: ShellSelectableText
        init(alias: String) {
            name = ShellSelectableText(alias, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .labelColor)
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(symbol); addSubview(name)
            toolTip = alias
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = piCGColor(.piFill); layer?.cornerRadius = 10; layer?.cornerCurve = .continuous }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        /// `Text` takes its lines' height rounded up to the point (14 for one caption line).
        private func textHeight(_ width: CGFloat) -> CGFloat { Foundation.ceil(min(name.height(forWidth: width - 18), PiKit.Line("Ag", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .black).lineHeight * 3) - 0.01) }
        /// This image's VStack slot also takes a whole-point height. Keeping
        /// its fractional symbol height made the centred alias box shorter.
        private var imageSize: CGSize {
            let size = symbol.intrinsicContentSize
            return CGSize(width: size.width, height: Foundation.ceil(size.height - 0.01))
        }
        func height(forWidth width: CGFloat) -> CGFloat { 9 + imageSize.height + 5 + textHeight(width) + 9 }
        override func layout() {
            super.layout()
            let size = imageSize
            symbol.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: 9, width: size.width, height: size.height)
            let textWidth = min(bounds.width - 18, name.intrinsicContentSize.width)
            name.frame = CGRect(x: PiKit.round((bounds.width - textWidth) / 2, piScale), y: 9 + size.height + 5, width: textWidth, height: textHeight(bounds.width))
        }
    }
    /// The curves from the alias's middle to each destination's.
    final class Branches: DashView {
        let count: Int
        init(count: Int) { self.count = count; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.piAccent.piOpacity(0.45).setStroke()
            for index in 0..<count {
                let y = (CGFloat(index) + 0.5) * bounds.height / CGFloat(max(1, count))
                let path = NSBezierPath()
                path.move(to: CGPoint(x: 0, y: bounds.height / 2))
                path.curve(to: CGPoint(x: bounds.width, y: y), controlPoint1: CGPoint(x: bounds.width / 2, y: bounds.height / 2), controlPoint2: CGPoint(x: bounds.width / 2, y: y))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
    /// A returned model: its dot, name and figures on its colour's wash.
    final class Destination: DashView, PiKit.WidthSizing {
        private let color: NSColor
        private let name: ShellText
        private let figures: PiKit.TextLine
        init(alias: String, row: DashboardModelSummary, color: NSColor) {
            self.color = color
            name = ShellText(row.resolutionLabel, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .labelColor, maximumLines: 2)
            figures = PiKit.TextLine(PiKit.Line("\(row.requests) requests · \(monitorCost(row.gateway.costUSD))", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkSecondary))
            super.init(frame: .zero)
            addSubview(name); addSubview(figures)
            toolTip = "\(alias) → \(row.resolutionLabel)\n\(row.gateway.costLabel)"
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func textHeight(_ width: CGFloat) -> CGFloat { name.height(forWidth: textWidth(width)) + 3 + figures.intrinsicContentSize.height }
        private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 18 - 7 - 7) }
        func height(forWidth width: CGFloat) -> CGFloat { max(54, textHeight(width) + 18) }
        override func draw(_ dirtyRect: NSRect) {
            color.piOpacity(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 9, y: PiKit.round((bounds.height - 7) / 2, piScale), width: 7, height: 7)).fill()
        }
        override func layout() {
            super.layout()
            let width = textWidth(bounds.width)
            let top = PiKit.round((bounds.height - textHeight(bounds.width)) / 2, piScale)
            let nameHeight = name.height(forWidth: width)
            name.frame = CGRect(x: 23, y: top, width: width, height: nameHeight)
            let size = figures.intrinsicContentSize
            figures.frame = CGRect(x: 23, y: top + nameHeight + 3, width: min(width, size.width), height: size.height)
        }
    }
}

/// The eight costliest routes, each with its share of the cost.
@MainActor final class ModelCostBreakdown: DashView, PiKit.WidthSizing {
    private var models: [MonitorDistribution] = []
    private var total = GatewayTotals()
    private var palette = MonitorModelPalette()
    private var loading = false
    private let column = ShellStack(.vertical, spacing: 13)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(card)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("analytics-model-costs")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(models: [MonitorDistribution], total: GatewayTotals, palette: MonitorModelPalette, loading: Bool) {
        guard models != self.models || total != self.total || palette != self.palette || loading != self.loading || column.items.isEmpty else { return }
        self.models = models; self.total = total; self.palette = palette; self.loading = loading
        var items: [ShellItem] = [.view(ShellStack(.horizontal, spacing: 8, [
            .view(PiKit.TextLine(PiKit.Line("Cost by model", font: PiKit.Font.heading, color: .labelColor))), .spacer(8),
            .view(PiKit.TextLine(PiKit.Line(monitorCost(total.costUSD), font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .labelColor)))]), .fill)]
        for row in Self.shown(models) { items.append(.view(CostRow(row: row, color: .monitorModel(palette.index(row.id))), .fill)) }
        if models.isEmpty {
            items.append(.view(PiKit.TextLine(PiKit.Line(loading ? "Reading routes…" : "No model costs reported.", font: PiKit.Font.caption, color: .piInkSecondary))))
        }
        items.append(.view(PiKit.TextLine(PiKit.Line("\(total.costSamples)/\(total.requests) requests reported cost · reasoning included in total", font: PiKit.Font.micro, color: .piInkSecondary))))
        column.items = items
        PiKit.sizeChanged(self)
    }
    /// The eight costliest routes. The distribution arrives ranked by output
    /// tokens, which could leave an expensive, terse route off a cost card.
    static func shown(_ models: [MonitorDistribution]) -> [MonitorDistribution] { Array(MonitorDistribution.byCost(models).prefix(8)) }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() { super.layout(); card.frame = bounds }

    /// A route: its dot, name and cost over a capsule of its share.
    final class CostRow: DashView, PiKit.WidthSizing {
        let row: MonitorDistribution
        let color: NSColor
        init(row: MonitorDistribution, color: NSColor) {
            self.row = row; self.color = color
            super.init(frame: .zero)
            toolTip = "\(row.id): \(gatewayUSD(row.cost)) · \(row.requests) requests"
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
            setAccessibilityLabel(row.id + ", " + monitorCost(row.cost))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private var name: PiKit.Line { PiKit.Line(row.id, font: PiKit.Font.caption, color: .labelColor) }
        private var figure: PiKit.Line { PiKit.Line(monitorCost(row.cost), font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .labelColor) }
        func height(forWidth width: CGFloat) -> CGFloat { name.lineHeight + 5 + 5 }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: 400)) }
        override func draw(_ dirtyRect: NSRect) {
            let scale = piScale
            let line = name.lineHeight
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 0, y: PiKit.round((line - 7) / 2, scale), width: 7, height: 7)).fill()
            let figureSize = figure.size(scale: scale)
            figure.draw(at: CGPoint(x: bounds.width - figureSize.width, y: 0), scale: scale)
            let x: CGFloat = 7 + 8
            name.draw(in: CGRect(x: x, y: 0, width: max(0, min(name.size(scale: scale).width, bounds.width - figureSize.width - 8 - x)), height: line), truncation: .middle, scale: scale)
            let track = CGRect(x: 0, y: line + 5, width: bounds.width, height: 5)
            NSColor.piFillStrong.setFill(); NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let fill = CGRect(x: 0, y: track.minY, width: track.width * min(1, max(0, row.costShare ?? 0)), height: 5)
            color.setFill(); NSBezierPath(roundedRect: fill, xRadius: min(2.5, fill.width / 2), yRadius: 2.5).fill()
        }
    }
}

/// The window's input and output tokens, each split into its two shares.
@MainActor final class AnalyticsTokenBreakdown: DashView, PiKit.WidthSizing {
    private var gateway: GatewayTotals?
    private let column = ShellStack(.vertical, spacing: 16)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(card)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("analytics-token-breakdown")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    static func accounting(_ gateway: GatewayTotals) -> TurnAccounting {
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
    func update(gateway: GatewayTotals) {
        guard gateway != self.gateway else { return }
        self.gateway = gateway
        let accounting = Self.accounting(gateway)
        var items: [ShellItem] = [
            .view(PiKit.TextLine(PiKit.Line("Token breakdown", font: PiKit.Font.heading, color: .labelColor))),
            .view(TokenShareBar(partition: TurnTokenPartition(accounting, input: true)), .fill),
            .view(TokenShareBar(partition: TurnTokenPartition(accounting, input: false)), .fill),
        ]
        if let pair = accounting.outputSplit, pair.samples < gateway.requests {
            items.append(.view(PiKit.TextLine(PiKit.Line("Output split: \(pair.samples)/\(gateway.requests) requests supplied both counters.", font: PiKit.Font.micro, color: .piInkSecondary))))
        }
        if let pair = accounting.inputSplit, pair.samples < gateway.requests {
            items.append(.view(PiKit.TextLine(PiKit.Line("Input split: \(pair.samples)/\(gateway.requests) requests supplied both counters.", font: PiKit.Font.micro, color: .piInkSecondary))))
        }
        items.append(.view(PiKit.TextLine(PiKit.Line("Gateway-reported · cached tokens are part of input; reasoning is part of output.", font: PiKit.Font.micro, color: .piInkSecondary))))
        column.items = items
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() { super.layout(); card.frame = bounds }
}
