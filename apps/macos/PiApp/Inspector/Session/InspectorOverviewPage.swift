import AppKit

/// Session statistics, native Pi charts, the retained ledger, and cost controls.
@MainActor final class InspectorOverviewPage: DashView {
    let inspector: SessionInspectorModel
    private let usage: SessionUsageController
    var compact: Bool { didSet { if compact != oldValue { refresh() } } }
    private var methodology = false
    private let column = ShellStack(.vertical, spacing: 18)
    private lazy var scroll = PageScrollView(column: column)
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private lazy var footerObserver = ShellObserver { [weak self] in self?.refresh() }
    private weak var followedFooter: SessionMetrics?
    private var limitCard: NSView?
    private var chartViews: [NSView] = []
    private var shownTime: SessionTimeCharts?
    private var shownTokens: SessionTokenCharts?
    private var shownChartCompact: Bool?
    private var shownFailure: String?
    private var shownIndexLoaded: Bool?
    private var ledgerView: SessionRequestLedgerView?

    init(inspector: SessionInspectorModel, compact: Bool) {
        self.inspector = inspector; self.compact = compact; usage = inspector.usage
        super.init(frame: .zero); addSubview(scroll); scroll.maximumWidth = 1_100
        setAccessibilityIdentifier("inspector-overview")
        observer.observe(inspector); observer.observe(usage); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let focus = InspectorButtonFocus(in: self); defer { focus?.restore(in: self) }
        SessionStatsRenderCount.panelBuilt()
        let inset = compact ? PiSpacing.lg : PiSpacing.xl
        scroll.insets = NSEdgeInsets(top: PiSpacing.lg, left: inset, bottom: PiSpacing.lg, right: inset)
        var views: [NSView] = [InspectorPageHeader("Overview", subtitle: subtitle, actions: [InspectorShowInChat { [weak inspector] in inspector?.showInChat() }]), figures()]
        if followedFooter !== inspector.display?.footer {
            footerObserver.reset(); followedFooter = inspector.display?.footer
            if let footer = followedFooter, let workspace = inspector.workspace {
                footerObserver.observe(footer)
                let id = inspector.scope.sessionID
                limitCard = PiKit.card(CostLimitLiveEditor(footer: footer, choose: { [weak workspace] limit in try await workspace?.setCostLimit(limit, for: id) }), padding: PiSpacing.lg)
                limitCard?.setAccessibilityIdentifier("inspector-cost-limit")
            } else { limitCard = nil }
        }
        if let limitCard { views.append(limitCard) }
        if shownTime != inspector.timeCharts || shownTokens != inspector.tokenCharts || shownChartCompact != compact || (!inspector.timeCharts.historyLoaded && (shownFailure != inspector.failure || shownIndexLoaded != inspector.indexLoaded)) {
            shownTime = inspector.timeCharts; shownTokens = inspector.tokenCharts; shownChartCompact = compact; shownFailure = inspector.failure; shownIndexLoaded = inspector.indexLoaded
            chartViews = charts()
        }
        views += chartViews
        if let snapshot = usage.snapshot { views.append(models(snapshot)) }
        if ledgerView == nil { ledgerView = SessionRequestLedgerView(ledger: inspector.ledger, open: { [weak inspector] in inspector?.select(.request($0)) }, limit: 40); ledgerView?.setAccessibilityIdentifier("inspector-ledger") }
        else { ledgerView?.update(ledger: inspector.ledger) }
        if let ledgerView { views.append(ledgerView) }
        views.append(howCounted())
        column.items = views.map { .view($0, .fill) }; scroll.fit(); needsLayout = true
    }
    private var subtitle: String {
        let gateway = inspector.inputs.gateway.requests > 0 ? inspector.inputs.gateway : usage.snapshot?.gateway ?? GatewayTotals()
        var parts: [String] = []
        let turns = inspector.index.turns.filter { !$0.isOther }.count
        if gateway.requests > 0 || turns > 0 { parts.append("\(turns) turn" + (turns == 1 ? "" : "s") + " · \(gateway.requests) request" + (gateway.requests == 1 ? "" : "s")) }
        if let started = inspector.index.requests.first(where: { $0.wall > 0 })?.wall { parts.append("since " + Date(timeIntervalSince1970: started).formatted(date: .abbreviated, time: .shortened)) }
        if let snapshot = usage.snapshot, snapshot.modelGroups > 1 { parts.append("\(snapshot.modelGroups) routes") }
        return parts.isEmpty ? "No requests yet" : parts.joined(separator: " · ")
    }
    private func figures() -> NSView {
        let hero = inspector.tokenCharts.hero + inspector.timeCharts.hero.filter { $0.id == "speed" } + inspector.timeCharts.details.filter { $0.id == "ttft" }
        let details = inspector.timeCharts.hero.filter { $0.id != "speed" } + inspector.timeCharts.details.filter { $0.id != "ttft" }
        let heroGrid = GridView(columns: .adaptive(minimum: compact ? 120 : 150, maximum: .greatestFiniteMagnitude), spacing: PiSpacing.md, rowSpacing: 14)
        heroGrid.items = hero.map { figure in
            let view: NSView
            if figure.id == "cost", let footer = inspector.display?.footer { view = costFigure(figure, footer: footer) }
            else { view = PiKit.Figure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial, large: true) }
            view.setAccessibilityIdentifier("inspector-figure-" + figure.id); return view
        }
        let detailsGrid = GridView(columns: .adaptive(minimum: compact ? 110 : 130, maximum: .greatestFiniteMagnitude), spacing: PiSpacing.md, rowSpacing: 12)
        detailsGrid.items = details.map { figure in let view = PiKit.Figure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial); view.setAccessibilityIdentifier("inspector-figure-" + figure.id); return view }
        var views: [NSView] = [heroGrid, InspectorRule(), detailsGrid]
        if let coverage = inspector.tokenCharts.coverage { views.append(inspectorText(coverage, font: PiKit.Font.micro, color: .piWarning, lines: .max)) }
        let card = PiKit.card(inspectorColumn(views, spacing: 16), padding: PiSpacing.lg); card.setAccessibilityIdentifier("inspector-overview-figures"); return card
    }
    private func costFigure(_ figure: SessionStatsFigure, footer: SessionMetrics) -> PiKit.Figure {
        let reading = footer.cost
        let presentation = SessionStatsPresentation(gateway: footer.gateway, work: nil, cost: reading)
        var value = figure.value, caption: [String] = []
        if let cap = reading.limit.usd {
            if let spent = presentation.costFigure?.components(separatedBy: " of ").first { value = spent }
            caption.append("of " + CostLimit.dollars(cap) + " limit")
        } else if let own = figure.caption { caption.append(own) }
        if let unreported = reading.unreportedNote { caption.append(unreported) }
        return PiKit.Figure(value: value, title: figure.title, caption: caption.joined(separator: " · "), partial: figure.partial || presentation.costWarning || reading.unreportedNote != nil, large: true, warning: presentation.costWarning)
    }
    private func charts() -> [NSView] {
        let time = inspector.timeCharts, tokens = inspector.tokenCharts
        let open: (String) -> Void = { [weak inspector] in inspector?.select(.request($0)) }
        func card(_ content: NSView) -> NSView { PiKit.card(content, padding: PiSpacing.md) }
        guard time.historyLoaded else { return [PiKit.card(SessionStatsLoadingNote(loading: !inspector.indexLoaded, failure: inspector.failure), padding: PiSpacing.lg)] }
        var views: [NSView] = []
        if let timeline = time.timeline { views.append(card(SessionTimelineChart(timeline: timeline, selection: inspector.timelineSelection, open: open))) }
        let grid = GridView(columns: .adaptive(minimum: compact ? 300 : 420, maximum: .greatestFiniteMagnitude), spacing: PiSpacing.md, rowSpacing: PiSpacing.md)
        var charts: [NSView] = []
        if let speed = time.speed { charts.append(card(SessionSpeedChart(speed: speed, selection: inspector.speedSelection, open: open))) }
        if let bars = tokens.perRequest { charts.append(card(SessionTokenBarsChart(bars: bars, selection: inspector.tokenSelection, open: open))) }
        if let cost = tokens.cost { charts.append(card(SessionCostChart(cost: cost, selection: inspector.costSelection, open: open))) }
        if let split = time.split { charts.append(card(SessionTimeSplitView(split: split))) }
        if let composition = tokens.composition { charts.append(card(SessionCompositionView(composition: composition))) }
        grid.items = charts; if !charts.isEmpty { views.append(grid) }
        if time.models.count > 1 || tokens.models.count > 1 {
            let modelGrid = GridView(columns: grid.columns, spacing: PiSpacing.md, rowSpacing: PiSpacing.md)
            if !time.models.isEmpty { modelGrid.items.append(card(SessionModelTimeTable(rows: time.models))) }
            if !tokens.models.isEmpty { modelGrid.items.append(card(SessionModelTokenTable(rows: tokens.models))) }
            if !modelGrid.items.isEmpty { views.append(modelGrid) }
        }
        return views
    }
    private func models(_ snapshot: MenuBarSnapshot) -> NSView {
        var views: [NSView] = [PiKit.SectionHeader("Models", subtitle: snapshot.modelGroups > 1 ? "\(snapshot.modelGroups) routes · speed and first token per model" : "One route · its speed and first-token time")]
        if snapshot.models.isEmpty { views.append(inspectorText("No retained requests for this session yet.", color: .piInkSecondary)) }
        else { for item in snapshot.models { views.append(InspectorRule()); views.append(InspectorModelRow(item: item, compact: compact)) } }
        if snapshot.modelGroups > MenuBarSnapshot.pageSize { views.append(PiKit.Pager(center: inspectorText("\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)"), canPrevious: usage.offset > 0 && !usage.loading, canNext: snapshot.hasNext && !usage.loading, previous: { [weak usage] in usage?.previousPage() }, next: { [weak usage] in usage?.nextPage() })) }
        let card = PiKit.card(inspectorColumn(views, spacing: PiSpacing.sm), padding: PiSpacing.md)
        card.toolTip = snapshot.observationHelp; card.setAccessibilityIdentifier("inspector-models"); return card
    }
    private func howCounted() -> NSView {
        let toggle = InspectorInlineDisclosure("How these figures are counted", expanded: methodology, plain: true) { [weak self] in self?.methodology.toggle(); self?.refresh() }
        toggle.setAccessibilityIdentifier("inspector-how-counted")
        var items: [ShellItem] = [.view(toggle, .natural)]
        if methodology {
            let notes = inspectorColumn([SessionStatsNotes(notes: inspector.timeCharts.notes + inspector.tokenCharts.notes), inspectorText("Each dispatched request counts once, tool rounds included. Only this session's own requests count; inherited parent messages add no cost. Reasoning is part of output and of the total cost; cached input is part of input. A missing figure stays missing, never a zero.", font: PiKit.Font.micro, color: .piInkTertiary, lines: .max), inspectorText(SettledThroughput.explanation, font: PiKit.Font.micro, color: .piInkTertiary, lines: .max)], spacing: 6)
            items.append(.view(notes, .fill, insets: NSEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)))
        }
        return ShellStack(.vertical, spacing: 8, items)
    }
    override func layout() { super.layout(); scroll.frame = bounds; scroll.fit() }
}

@MainActor private final class InspectorModelRow: DashView, PiKit.WidthSizing {
    private let row: ShellStack
    init(item: MenuBarModelDistribution, compact: Bool) {
        let alias = inspectorText(item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium)); alias.truncation = .middle; alias.toolTip = item.requestedAlias
        let resolved = inspectorText(item.resolutionLabel, color: item.resolvedModel == nil ? .piWarning : .piInkSecondary); resolved.truncation = .middle; resolved.toolTip = item.resolutionLabel
        let labels = inspectorColumn([alias, inspectorRow([.view(PiKit.SymbolView(PiKit.Symbol("arrow.turn.down.right", size: 10), color: item.resolvedModel == nil ? .piWarning : .piInkSecondary)), .view(resolved, .flexible)], spacing: 4)], spacing: 2)
        func share(_ value: String, _ fraction: Double, _ tone: NSColor) -> NSView { inspectorColumn([inspectorText(value, font: PiKit.Font.monospacedDigits(PiKit.Font.caption)), InspectorFixedSize(PiKit.ShareBar(fraction: fraction, tone: tone), width: 96, height: 4)], spacing: 3) }
        func figure(_ value: String, _ caption: String) -> NSView { inspectorColumn([inspectorText(value, font: PiKit.Font.monospacedDigits(PiKit.Font.caption)), inspectorText(caption, font: PiKit.Font.micro, color: .piInkTertiary)], spacing: 2) }
        var items: [ShellItem] = [.view(labels, .fill), .view(share("\(item.gateway.requests) req", item.requestShare, .piAccent), .fixed(96)), .view(share(compactGatewayUSD(item.gateway.costUSD), item.costShare ?? 0, .piSuccess), .fixed(96))]
        if !compact { items += [.view(figure(SessionUsagePresentation.rate(item.gateway.settledThroughput.tokensPerSecond) + " tok/s", "\(item.gateway.settledThroughput.samples)/\(item.gateway.requests) measured"), .fixed(118)), .view(figure(SessionUsagePresentation.milliseconds(item.ttftP50), item.ttftSamples > 0 ? "first token, median" : "not measured"), .fixed(118))] }
        row = inspectorRow(items, spacing: PiSpacing.md, alignment: .top)
        super.init(frame: .zero); addSubview(row); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel([item.requestedAlias, item.resolutionLabel, "\(item.gateway.requests) requests", compactGatewayUSD(item.gateway.costUSD)].joined(separator: ", "))
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) + 10 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() { super.layout(); row.frame = bounds.insetBy(dx: 0, dy: 5) }
}
