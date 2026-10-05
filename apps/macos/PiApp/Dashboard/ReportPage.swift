import AppKit
import Combine

/// The report's headline output rate and how it was measured.
/// It is the app's settled decode rate — output tokens after the first over
/// first to last generated token — the figure each route's row, Session info
/// and the pills show.
enum ReportThroughputTile {
    static func rate(_ snapshot: DashboardSnapshot) -> SettledThroughput { snapshot.gateway.settledThroughput }
    static func caption(_ snapshot: DashboardSnapshot) -> String {
        let rate = rate(snapshot)
        return "decode, first to last token · \(rate.samples)/\(snapshot.gateway.requests) measured"
    }
}

/// Usage report as a page inside the main window. The default view is a
/// time range, reported metrics, routing and token splits. Request rows and
/// advanced filters remain available through progressive disclosure.
///
/// It follows its controller and the workspace's chats and projects; each
/// section is rebuilt only when what it shows changed, so an async result
/// replaces the chart or a list without moving the rest of the page.
@MainActor final class ReportPage: DashView, InheritsReducedMotion {
    let model: WorkspaceModel
    let report: ReportController
    private var messageLookup: Task<Void, Never>?
    private var routingPalette = MonitorModelPalette()
    private var observer: ShellObserver!
    private var prepared = false
    /// The window's disabled state, handed down as SwiftUI's environment did.
    var inheritedEnabled = true { didSet { if inheritedEnabled != oldValue { applyEnabled() } } }
    /// The window's reduced motion (`piReduceMotion`), over the system's.
    var inheritedReduceMotion = false

    // Header
    private lazy var back: PiKit.Button = {
        let button = PiKit.Button("Chats", symbol: "chevron.left", style: .ghost) { [weak self] in self?.model.closeReport() }
        button.toolTip = "Back to chats (Esc)"; button.setAccessibilityIdentifier("reportBack")
        return button
    }()
    private let title = PiKit.TextLine(PiKit.Line("Usage report", font: PiKit.Font.title(17), color: .piInk))
    private let caption = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private let spinner = piSpinner(size: 16)
    private lazy var timeRange: PiKit.Tabs<DashboardWindowPreset> = {
        let tabs = PiKit.Tabs(selection: report.window.preset, items: DashboardWindowPreset.allCases.map { ($0, $0.title) }, accessibilityName: "Time range") { [weak self] preset in
            guard let self else { return }
            self.report.setPreset(preset)
            if preset == .custom { self.report.advancedOpen = true }
        }
        return tabs
    }()
    private lazy var refreshButton = PiKit.IconButton(symbol: "arrow.clockwise", label: "Refresh") { [weak self] in
        guard let self else { return }; Task { await self.report.refresh() }
    }
    private lazy var filters: ReportFiltersButton = {
        let button = ReportFiltersButton { [weak self] in self?.report.advancedOpen.toggle() }
        button.toolTip = "Show or hide advanced filters"; button.setAccessibilityIdentifier("reportFilters")
        return button
    }()
    private let header = ReportHeader()
    private let headerRule = HairlineView()
    // Body
    private let column = ShellStack(.vertical, spacing: PiSpacing.lg)
    private lazy var scroll: PageScrollView = {
        let scroll = PageScrollView(column: column)
        scroll.maximumWidth = 1_280
        scroll.insets = NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.xl, bottom: PiSpacing.lg, right: PiSpacing.xl)
        return scroll
    }()
    private let advanced = ReportAdvancedFilters()
    private let chips = PiKit.FlowView()
    private let failure = ReportFailure()
    private let empty = ReportEmptyState()
    private let summary = GridView(columns: .flexible(6), spacing: PiSpacing.md, rowSpacing: PiSpacing.md)
    private let overview = ReportOverview()
    private var active: ReportActiveSessions?
    private let requestsContent = ShellStack(.vertical, spacing: PiSpacing.sm)
    private lazy var requestsGroup: DisclosureGroupView = {
        let group = DisclosureGroupView("Requests and session details", font: PiKit.Font.heading, color: .labelColor, content: requestsContent)
        group.setAccessibilityIdentifier("analytics-request-details")
        group.onToggle = { [weak self] in self?.report.requestListOpen = $0 }
        return group
    }()
    private let details = ShellStack(.vertical, spacing: PiSpacing.md)
    private lazy var detailsToggle = ReportDetailsToggle { [weak self] in self?.report.detailsOpen.toggle() }
    private let loading = ReportLoadingState()
    private var keys = Keys()
    /// The grouping last seen: any change opens the request list (`.onChange(of: report.grouping)`).
    private var seenGrouping: ReportGrouping?

    /// What each section was last built from: a section rebuilds only when its key changes.
    private struct Keys {
        var summary: String?
        var requests: String?
        var details: String?
        var chips: String?
    }

    convenience init(model: WorkspaceModel) { self.init(model: model, report: model.report) }
    /// A page over a controller with its own queries, for tests.
    init(model: WorkspaceModel, report: ReportController) {
        self.model = model; self.report = report
        super.init(frame: .zero)
        wantsLayer = true
        header.build(back: back, title: title, caption: caption, spinner: spinner, timeRange: timeRange, refresh: refreshButton, filters: filters)
        caption.truncation = .end
        for view in [header, headerRule, scroll] as [NSView] { addSubview(view) }
        advanced.page = self
        chips.spacing = 6; chips.rowSpacing = 6
        failure.retry = { [weak self] in guard let self else { return }; Task { await self.report.refresh() } }
        empty.monthly = { [weak self] in self?.report.setPreset(.month) }
        empty.clear = { [weak self] in self?.report.reset() }
        overview.page = self
        detailsToggle.setAccessibilityIdentifier("reportDetails")
        column.items = [.view(advanced, .fill), .view(chips, .fill), .view(failure, .fill), .view(empty, .fill), .view(summary, .fill),
                        .view(overview, .fill), .view(requestsGroup, .fill), .view(details, .fill), .view(detailsToggle), .view(loading, .fill)]
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Usage report")
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(report)
        observer.observe(publisher: model.$chats)
        observer.observe(publisher: model.$workspaces)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { model.closeReport() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            guard !prepared else { return }
            prepared = true
            Task { [weak self] in await self?.report.prepare() }
        } else if prepared {
            // Off screen (`.onDisappear`): no lookup outlives it, and the report stops reading.
            prepared = false
            messageLookup?.cancel(); messageLookup = nil
            report.suspend()
        }
    }
    /// `.disabled(!enabled)` over the whole report: every control under it
    /// reads and looks disabled and leaves the key loop, and nothing in it
    /// takes the pointer. Each control's own state is kept and given back.
    private var heldEnabled: [ObjectIdentifier: (control: NSControl, enabled: Bool)] = [:]
    private func applyEnabled() {
        if inheritedEnabled {
            releaseControls()
        } else {
            holdControls()
        }
    }
    /// Disables the controls made since the page was disabled, keeping their own state.
    /// Gives every held control its own state back, so an update sees and
    /// sets the controls' own states; `holdControls` disables them again after.
    private func releaseControls() {
        for (_, held) in heldEnabled { held.control.isEnabled = held.enabled }
        heldEnabled = [:]
    }
    private func holdControls() {
        guard !inheritedEnabled else { return }
        for control in PiKit.controls(in: self) where heldEnabled[ObjectIdentifier(control)] == nil {
            heldEnabled[ObjectIdentifier(control)] = (control, control.isEnabled)
            control.isEnabled = false
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { inheritedEnabled ? super.hitTest(point) : nil }

    private var chipList: [ReportFilterChip] { report.activeFilters(workspaces: model.workspaces, chats: model.chats) }
    private var compact: Bool { bounds.width < 880 }

    // MARK: Refresh

    /// Brings the page up to the controller, touching only what moved.
    func refresh() {
        releaseControls()
        if let seenGrouping, seenGrouping != report.grouping, !report.requestListOpen { report.requestListOpen = true }
        seenGrouping = report.grouping
        routingPalette.include((report.modelSummaries ?? []).map(\.distributionID))
        refreshHeader()
        let chips = chipList
        // The deliberate disclosures (filters, chips, details) move with the
        // page's motion; data arriving does not (`.animation(motion, value:)`).
        let disclosing = report.advancedOpen != shownAdvanced || report.detailsOpen != shownDetails || (shownExpanded != nil && report.expandedSessions != shownExpanded)
        let opened = report.expandedSessions.subtracting(shownExpanded ?? report.expandedSessions)
        let closed = (shownExpanded ?? []).subtracting(report.expandedSessions)
        shownAdvanced = report.advancedOpen; shownDetails = report.detailsOpen; shownExpanded = report.expandedSessions
        // A closed session's requests leave as the filters and details do.
        let closedBoxes = closed.compactMap { nestedBoxes[$0]?.box as NSView? }
        let animates = disclosing && window != nil && !piReducesMotion
        let leaving = animates ? ([advanced, self.chips, details] + closedBoxes).filter { !$0.isHidden && $0.window != nil } : []
        // Each leaving part, where it is, before the update moves anything: a
        // section that stays in the column leaves as its picture; a session's
        // box, which leaves the list, leaves as itself (no picture of a long list).
        let departures: [(view: NSView, moving: NSView, host: NSView?, frame: CGRect)] = leaving.compactMap { view in
            if closedBoxes.contains(where: { $0 === view }) { return (view, view, view.superview, view.frame) }
            return DashMotion.snapshot(view).map { (view, $0, view.superview, view.frame) }
        }
        let advancedArrives = report.advancedOpen && advanced.isHidden
        advanced.isHidden = !report.advancedOpen
        if report.advancedOpen { advanced.refresh() }
        let chipsWereHidden = self.chips.isHidden
        self.chips.isHidden = report.advancedOpen || (chips.isEmpty && report.brush == nil)
        let chipsArrive = chipsWereHidden && !self.chips.isHidden
        refreshChips(chips)
        failure.isHidden = report.failure == nil
        failure.message = report.failure ?? ""
        let snapshot = report.snapshot
        let active = report.active ?? snapshot
        let showsEmpty = snapshot.map { $0.scopeCounts.dispatched == 0 && $0.scopeCounts.unobservedDispatch == 0 && report.brush == nil } ?? false
        empty.isHidden = !showsEmpty
        empty.configure(chips: !chips.isEmpty, monthly: report.window.preset != .month)
        let showsContent = snapshot != nil && !showsEmpty
        for view in [summary, overview, requestsGroup] as [NSView] { view.isHidden = !showsContent }
        if let snapshot, let active, showsContent {
            refreshSummary(active, window: snapshot)
            overview.update(snapshot: snapshot, active: active, palette: routingPalette, wide: bounds.width >= 1_050)
            refreshActiveSessions(snapshot)
            requestsGroup.isExpanded = report.requestListOpen
            refreshRequests(active)
        } else {
            self.active?.isHidden = true
        }
        let detailsArrive = details.isHidden && snapshot != nil && report.detailsOpen
        details.isHidden = !(snapshot != nil && report.detailsOpen)
        if let snapshot, let active, report.detailsOpen { refreshDetails(active, window: snapshot) }
        detailsToggle.isHidden = snapshot == nil
        detailsToggle.open = report.detailsOpen
        loading.isHidden = snapshot != nil || report.failure != nil
        holdControls()
        guard disclosing, window != nil, !piReducesMotion else {
            column.relayoutAll(); scroll.fit(); needsLayout = true
            return
        }
        // What stays reflows into place; what leaves fades and moves up from
        // where it was; what comes arrives from above as it fades in
        // (`.opacity` combined with `.move(edge: .top)`, 0.2 s ease-out).
        for departure in departures where departure.view.isHidden || departure.view.superview == nil {
            if let host = departure.host { DashMotion.leave(departure.moving, in: host, at: departure.frame) }
        }
        DashMotion.reflow {
            self.column.relayoutAll(); self.scroll.fit()
            self.layoutSubtreeIfNeeded()
        }
        if advancedArrives { PiKit.arrive(advanced) }
        if chipsArrive { PiKit.arrive(self.chips) }
        if detailsArrive { PiKit.arrive(details) }
        // A session's requests fade in as the rows below make room.
        for id in opened { if let box = nestedBoxes[id]?.box { PiKit.arrive(box) } }
    }
    private var shownAdvanced: Bool?
    private var shownExpanded: Set<String>?
    private var shownDetails: Bool?

    private func refreshHeader() {
        let window = report.appliedWindow
        let count = report.snapshot.map { " · \($0.filter.status == "all" ? "All statuses" : $0.filter.status.capitalized)" } ?? ""
        let pending = report.filtersPending ? " · Updating filters…" : ""
        let text = window.preset == .custom
            ? "\(window.from.formatted(date: .abbreviated, time: .shortened)) – \(window.until.formatted(date: .abbreviated, time: .shortened))" + count + pending
            : "Last \(window.preset.title) · since \(window.from.formatted(date: .abbreviated, time: .shortened))" + count + pending
        caption.line.text = text; caption.toolTip = text
        spinner.isHidden = !report.loading
        timeRange.selection = report.window.preset
        refreshButton.isEnabled = !report.loading
        filters.count = report.activeFilterCount
        filters.open = report.advancedOpen
        header.compact = compact
        header.needsLayout = true
    }

    private func refreshChips(_ list: [ReportFilterChip]) {
        let brushLabel = report.brush.flatMap { brush in report.focused.map { "Selected \(brush.label) · \($0.selectedRequests) requests" } }
        let key = list.map(\.label).joined(separator: "\u{1}") + "|" + (brushLabel ?? "")
        guard key != keys.chips else { return }
        keys.chips = key
        chips.subviews.forEach { $0.removeFromSuperview() }
        for chip in list {
            chips.addSubview(PiKit.Chip(text: chip.label, icon: "line.3.horizontal.decrease", remove: { [weak self] in self?.report.clear(chip) }))
        }
        if let brushLabel {
            chips.addSubview(PiKit.Chip(text: brushLabel, icon: "selection.pin.in.out", help: "Chart selection narrows the tiles and list. The saved filter is unchanged.",
                                        remove: { [weak self] in self?.report.clearBrush() }))
        }
        if list.count > 1 { chips.addSubview(PiKit.Button("Clear all", style: .ghost) { [weak self] in self?.report.reset() }) }
        PiKit.sizeChanged(chips)
    }

    // MARK: Summary

    private func refreshSummary(_ active: DashboardSnapshot, window: DashboardSnapshot) {
        let counts = window.scopeCounts
        let problems = counts.failed + counts.cancelled + counts.truncated + counts.interrupted
        let statusCaption = report.brush != nil ? "\(active.filter.status.capitalized) · selected range"
            : active.filter.status != "all" ? "\(active.filter.status.capitalized) · \(counts.dispatched) across all statuses"
            : "\(counts.completed) completed" + (problems > 0 ? " · \(problems) not completed" : "") + (counts.running > 0 ? " · \(counts.running) running" : "")
        let tokens = active.gateway.tokens
        let tokenValue = tokens.map { "in \(reportTokens($0.input)) · out \(reportTokens($0.output))" } ?? "Not reported"
        let tokenCaption = tokens.map { t in
            // Input and output are summed over their own reporting requests; one
            // shared count would misstate whichever side has more samples.
            let total = active.gateway.requests
            // Coverage is named only where it is partial; "(6/6)" after every figure is noise.
            let cover: (Int) -> String = { $0 < total ? " (\($0)/\(total))" : "" }
            let reported = t.inputSamples == t.samples && t.outputSamples == t.samples ? (t.samples < total ? "\(t.samples)/\(total) reported" : "every request reported") : "in \(t.inputSamples)/\(total) · out \(t.outputSamples)/\(total) reported"
            return "cached \(reportTokens(active.gateway.cacheReadTokens))\(cover(active.gateway.cacheReadSamples)) · uncached \(reportTokens(active.gateway.uncachedInputTokens))\(cover(active.gateway.uncachedInputSampleCount)) · " + reported
        } ?? "The gateway reported no usage tokens"
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        let tiles: [(String, String, String, String, PiTone, String?)] = [
            ("Requests", "\(active.selectedRequests)", statusCaption, "paperplane", .accent, nil),
            ("Reported cost", monitorCost(active.gateway.costUSD), active.gateway.costSamples < active.gateway.requests ? "\(active.gateway.costSamples)/\(active.gateway.requests) requests reported" : "gateway-reported, every request",
             "dollarsign.circle", .success, active.gateway.costLabel + "\n" + reportReasoningDetail(active.gateway)),
            ("Tokens", tokenValue, tokenCaption, "number", .accent, reportReasoningDetail(active.gateway) + "\n" + active.gateway.promptCacheCoverageLabel),
            ("Input cache hit", monitorCacheShare(active.gateway), active.gateway.promptCacheCoverageLabel, "memorychip", .success, nil),
            ("First token", "p50 " + ms(active.ttft.p50), "p99 \(ms(active.ttft.p99)) · HTTP p50 \(ms(active.http.p50))", "timer", .info, nil),
            ("Output tok/s", menuBarRate(ReportThroughputTile.rate(active).tokensPerSecond), ReportThroughputTile.caption(active), "speedometer", .info,
             SettledThroughput.explanation + " Each route's rate is listed under By model."),
        ]
        summary.columns = compact ? .adaptive(minimum: 172, maximum: 320) : .flexible(6)
        let key = tiles.map { "\($0.0)\u{1}\($0.1)\u{1}\($0.2)\u{1}\($0.5 ?? "")" }.joined(separator: "\u{2}")
        guard key != keys.summary else { return }
        keys.summary = key
        summary.items = tiles.map { title, value, caption, symbol, tone, help in
            let tile = dashStatTile(title: title, value: value, caption: caption, symbol: symbol, tone: tone)
            tile.toolTip = help
            return tile
        }
    }

    private func refreshActiveSessions(_ snapshot: DashboardSnapshot) {
        if let active {
            active.isHidden = false
            active.update(workspaceID: snapshot.filter.workspaceID)
            return
        }
        let view = ReportActiveSessions(live: model.liveActivity, workspaceID: snapshot.filter.workspaceID, activity: { [weak model] in model?.menuBarActivity() ?? MenuBarActivitySnapshot() },
                                        openSession: { [weak model] id in
            guard let model else { return }
            Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
        })
        active = view
        var items = column.items
        if let index = items.firstIndex(where: { $0.view === overview }) { items.insert(.view(view, .fill), at: index + 1) }
        column.items = items
    }

    // MARK: Requests

    /// Everything the request list shows: it is laid out again only when this changes.
    private struct RequestsState: Equatable {
        var grouping: ReportGrouping, detailed: Bool
        var offset: Int, requests: [DashboardRequest], rowCount: Int?, hasNext: Bool, selected: Int
        var loading: Bool, pending: Bool
        var models: [DashboardModelSummary]?, sessions: DashboardSessionPage?
        var expanded: Set<String>, nested: [String: [DashboardRequest]], nestedTotals: [String: Int], nestedMore: [String: Bool]
        var titles: [String: String], workspaces: [String: String], available: Set<String>
        var allCost: Double?
    }
    private var requestsState: RequestsState?
    // The list's controls and scroller stay while their contents change: a
    // focused control keeps its focus and the grid its sideways scroll.
    private lazy var requestsHeader = DashSectionHeader("Requests", subtitle: "Click a row for exact retained bytes and model evidence")
    private lazy var groupingTabs: PiKit.Tabs<ReportGrouping> = {
        let tabs = PiKit.Tabs(selection: report.grouping, items: [(ReportGrouping.requests, "Requests"), (.sessions, "By session"), (.models, "By model")]) { [weak self] grouping in
            self?.report.grouping = grouping
        }
        tabs.setAccessibilityIdentifier("reportGrouping")
        return tabs
    }()
    private let pagerText = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private lazy var requestPagerView = PiKit.Pager(previousLabel: "Previous", nextLabel: "Next", center: pagerText, canPrevious: false, canNext: false,
        previous: { [weak self] in self?.pageBack() }, next: { [weak self] in self?.pageOn() })
    private let routesText = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkTertiary))
    private lazy var requestControls = ReportRequestControls(tabs: groupingTabs, pager: requestPagerView)
    private let requestList = ShellStack(.vertical, spacing: 0)
    private lazy var requestGrid = ReportGridScroll(content: ShellInset(requestList), width: 1_100)
    /// Each row's view and what it was made from, by the row's identity.
    private var rowViews: [String: (same: (Any) -> Bool, view: NSView)] = [:]
    private var usedRows: Set<String> = []
    /// The row's view: the one made before when it shows the same thing, else a new one.
    private func row<Value: Equatable>(_ key: String, _ value: Value, make: () -> NSView) -> NSView {
        usedRows.insert(key)
        if let kept = rowViews[key], kept.same(value) { return kept.view }
        let view = make()
        if let old = rowViews[key]?.view { carryOver(from: old, to: view) }
        rowViews[key] = ({ ($0 as? Value) == value }, view)
        return view
    }
    /// A row made again for the same request, session or route keeps what the
    /// reader did in it, as SwiftUI's view identity kept its state: the other
    /// reported names it revealed, and the keyboard on the same control.
    private func carryOver(from old: NSView, to new: NSView) {
        // The disclosure of the other reported names stays open while the name still has others.
        for (before, after) in zip(views(FinalModelLabel.self, in: old), views(FinalModelLabel.self, in: new)) where after.final == nil && after.reported.count > 1 {
            after.revealed = before.revealed
        }
        // A session opened or closed turns its chevron from where it was.
        if !piReducesMotion {
            for (before, after) in zip(views(ExpandChevron.self, in: old), views(ExpandChevron.self, in: new)) where before.drawnTurn != after.drawnTurn {
                after.turn(from: before.drawnTurn)
            }
        }
        guard let window = old.window, let responder = window.firstResponder as? NSView, responder === old || responder.isDescendant(of: old) else { return }
        // The same control by what it is: its class and its name, not its place.
        func identity(_ control: NSView) -> String {
            let id = control.accessibilityIdentifier()
            return "\(type(of: control))|" + (id.isEmpty ? control.accessibilityLabel() ?? "" : id)
        }
        // The control the keyboard is on: the responder, or the nearest control holding it.
        var holder: NSView? = responder
        while let view = holder, !(view is NSControl), view !== old { holder = view.superview }
        let focused = holder as? NSControl
        let target: NSView = focused.flatMap { focused in
            focused === old ? new : PiKit.controls(in: new).first { identity($0) == identity(focused) }
        } ?? new
        DispatchQueue.main.async { [weak target, weak window] in
            guard let target, let window, target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// An open session's box of requests, kept while the session stays open,
    /// so its rows stay in the window (and the keyboard on one stays there).
    private var nestedBoxes: [String: (stack: ShellStack, box: SunkenBox)] = [:]
    private func nestedStack(_ sessionID: String) -> ShellStack {
        if let kept = nestedBoxes[sessionID] { return kept.stack }
        let stack = ShellStack(.vertical, spacing: 0)
        nestedBoxes[sessionID] = (stack, SunkenBox(stack))
        return stack
    }
    /// What a row shows: its data and the words and states around it.
    private struct RowValue<Value: Equatable>: Equatable {
        let value: Value
        let context: [String?]
        init(_ value: Value, _ context: [String?]) { self.value = value; self.context = context }
    }
    private var gridWidth: CGFloat { max(1_100, min(1_280, bounds.width) - 2 * PiSpacing.xl) }

    private func refreshRequests(_ snapshot: DashboardSnapshot) {
        let labels = report.labels(for: model)
        let titles = labels.titles
        let sessions = report.sessions?.sessions ?? []
        let state = RequestsState(grouping: report.grouping, detailed: report.detailsOpen,
                                  offset: snapshot.offset, requests: snapshot.requests, rowCount: snapshot.rowCount, hasNext: snapshot.hasNext, selected: snapshot.selectedRequests,
                                  loading: report.loading, pending: report.filtersPending,
                                  models: report.modelSummaries, sessions: report.sessions,
                                  expanded: report.expandedSessions, nested: report.sessionRequests.mapValues(\.requests),
                                  nestedTotals: report.sessionRequests.mapValues(\.selectedRequests), nestedMore: report.sessionRequests.mapValues(\.hasNext),
                                  titles: titles,
                                  workspaces: report.grouping == .sessions ? labels.workspaces : [:],
                                  available: Set(sessions.map(\.sessionID).filter { model.record($0) != nil }),
                                  allCost: snapshot.gateway.costUSD)
        updateGridWidth()
        guard state != requestsState else { return }
        requestsState = state
        requestsHeader.setTitle(report.grouping == .sessions ? "Sessions" : report.grouping == .models ? "Models" : "Requests")
        requestsHeader.setSubtitle(report.grouping == .sessions ? "Per-chat totals and medians · expand a session for its requests"
                                   : report.grouping == .models ? "Per route: requests, cost, tokens, output rate and first-token median · click a row to filter by it"
                                   : "Click a row for exact retained bytes and model evidence")
        groupingTabs.selection = report.grouping
        refreshPager(snapshot)
        usedRows = []
        requestList.items = listItems(snapshot, titles: titles)
        rowViews = rowViews.filter { usedRows.contains($0.key) }
        nestedBoxes = nestedBoxes.filter { usedRows.contains("box:" + $0.key) }
        if requestsContent.items.isEmpty {
            requestsContent.items = [.view(requestsHeader, .fill), .view(requestControls, .fill), .view(requestGrid, .fill)]
            requestsContent.padding = NSEdgeInsets(top: PiSpacing.md, left: 0, bottom: 0, right: 0)
        }
        requestControls.needsLayout = true
        requestGrid.invalidateIntrinsicContentSize(); requestGrid.needsLayout = true
        requestsContent.relayoutAll()
    }
    /// The grid follows the page's width as the window is resized.
    private func updateGridWidth() {
        let width = gridWidth
        guard requestGrid.width != width else { return }
        requestGrid.width = width
        requestsContent.relayoutAll()
    }

    /// The pager beside the tabs, for the grouping shown.
    private func refreshPager(_ snapshot: DashboardSnapshot) {
        switch report.grouping {
        case .models:
            routesText.line.text = report.modelSummaries.map { $0.isEmpty ? "No routes" : "\($0.count) \($0.count == 1 ? "route" : "routes")" + ($0.count >= PayloadArchive.modelGroupLimit ? " · busiest shown" : "") } ?? "Grouping…"
            requestControls.pager = routesText
        case .sessions:
            if let page = report.sessions {
                pagerText.line.text = page.sessions.isEmpty ? "No sessions" : "\(page.offset + 1)–\(page.offset + page.sessions.count) of \(page.total)"
                requestPagerView.canPrevious = page.offset > 0 && !report.loading
                requestPagerView.canNext = page.hasNext && !report.loading
                requestControls.pager = requestPagerView
            } else {
                routesText.line.text = ""
                requestControls.pager = routesText
            }
        case .requests:
            pagerText.line.text = Self.requestPageLabel(snapshot)
            requestPagerView.canPrevious = snapshot.offset > 0 && !report.loading && !report.filtersPending
            requestPagerView.canNext = snapshot.hasNext && !report.loading && !report.filtersPending
            requestControls.pager = requestPagerView
        }
        pagerText.invalidateIntrinsicContentSize(); routesText.invalidateIntrinsicContentSize()
        requestPagerView.invalidateIntrinsicContentSize(); requestPagerView.needsLayout = true
    }
    /// Previous and Next read the page shown when pressed.
    private func pageBack() {
        if report.grouping == .sessions, let page = report.sessions {
            Task { await report.pageSessions(offset: max(0, page.offset - PayloadArchive.sessionPageSize)) }
        } else if let snapshot = report.active ?? report.snapshot {
            Task { await report.page(offset: max(0, snapshot.offset - 128)) }
        }
    }
    private func pageOn() {
        if report.grouping == .sessions, let page = report.sessions {
            Task { await report.pageSessions(offset: page.offset + PayloadArchive.sessionPageSize) }
        } else if let snapshot = report.active ?? report.snapshot {
            Task { await report.page(offset: snapshot.offset + 128) }
        }
    }
    /// "129–145 of 145": the rows on this page and the total they were read
    /// with. A paged read counts again; the report's own total may be older.
    static func requestPageLabel(_ snapshot: DashboardSnapshot) -> String {
        snapshot.requests.isEmpty ? "No rows" : "\(snapshot.offset + 1)–\(snapshot.offset + snapshot.requests.count) of \(snapshot.rowCount ?? snapshot.selectedRequests)"
    }

    private func listItems(_ snapshot: DashboardSnapshot, titles: [String: String]) -> [ShellItem] {
        // A full-width one-point line (a vertical stack's `.fixed` is a width).
        func rule() -> ShellItem { .view(FixedHeight(HairlineView(), height: 1, fills: true), .fill) }
        var items: [ShellItem] = []
        switch report.grouping {
        case .sessions:
            let workspaces = report.labels(for: model).workspaces
            items.append(.view(ReportGridRow(cells: ["Last active", "Session", "Requests", "Cost", "Tokens", "Cache", "Latency p50", ""], widths: ReportColumns.sessionWidths), .fill))
            items.append(rule())
            if let page = report.sessions {
                for summary in page.sessions {
                    let expanded = report.expandedSessions.contains(summary.sessionID)
                    let available = model.record(summary.sessionID) != nil
                    items.append(.view(row("s:" + summary.sessionID, RowValue(summary, [titles[summary.sessionID], workspaces[summary.workspaceID], "\(available)", "\(expanded)", "\(report.detailsOpen)"])) {
                        ReportSessionRow(summary: summary, title: titles[summary.sessionID], workspace: workspaces[summary.workspaceID],
                                         available: available, expanded: expanded, detailed: report.detailsOpen,
                                         toggle: { [weak self] in self?.report.toggleSession(summary.sessionID) },
                                         open: { [weak model] in guard let model else { return }; Task { await model.revealMessage(sessionID: summary.sessionID, messageID: nil) } })
                    }, .fill))
                    if expanded {
                        let nested = nestedStack(summary.sessionID)
                        var inner: [ShellItem] = []
                        if let page = report.sessionRequests[summary.sessionID] {
                            for item in page.requests {
                                inner.append(.view(row("n:" + item.id, RowValue(item, [titles[item.sessionID], "\(report.detailsOpen)"])) {
                                    ReportRequestRow(item: item, title: nil, detailed: report.detailsOpen, inspect: { [weak self] in self?.inspect(item, title: titles[item.sessionID]) },
                                                     message: { [weak self] in self?.goToMessage(item) }, nested: true)
                                }, .fill))
                                inner.append(rule())
                            }
                            if page.hasNext {
                                inner.append(.view(PiKit.TextLine(PiKit.Line("Showing the first \(page.requests.count) of \(page.selectedRequests) requests · filter by this session for the rest",
                                                                             font: PiKit.Font.caption, color: .piInkTertiary)), insets: NSEdgeInsets(top: 6, left: 44, bottom: 6, right: 0)))
                            }
                        } else {
                            inner.append(.view(ReportInlineLoading("Loading requests…"), insets: NSEdgeInsets(top: 8, left: 44, bottom: 8, right: 0)))
                        }
                        nested.items = inner
                        usedRows.insert("box:" + summary.sessionID)
                        items.append(.view(nestedBoxes[summary.sessionID]!.box, .fill))
                    }
                    items.append(rule())
                }
                if page.sessions.isEmpty { items.append(.view(ReportListNote("No sessions match these filters"), .fill)) }
            } else {
                items.append(.view(ReportListLoading("Grouping by session…"), .fill))
            }
        case .models:
            items.append(.view(ReportGridRow(cells: ["Requested → final model", "Requests", "Cost", "Tokens", "Cache", "Output tok/s", "First token"], widths: ReportColumns.modelWidths), .fill))
            items.append(rule())
            if let summaries = report.modelSummaries {
                for summary in summaries {
                    items.append(.view(row("m:\(summary.id)", RowValue(summary, ["\(snapshot.selectedRequests)", "\(String(describing: snapshot.gateway.costUSD))", "\(report.detailsOpen)"])) {
                        ReportModelRow(summary: summary, allRequests: snapshot.selectedRequests, allCost: snapshot.gateway.costUSD, detailed: report.detailsOpen) { [weak self] in
                            self?.report.narrow(toRoute: summary)
                        }
                    }, .fill))
                    items.append(rule())
                }
                if summaries.isEmpty { items.append(.view(ReportListNote("No routes match these filters"), .fill)) }
            } else {
                items.append(.view(ReportListLoading("Grouping by model…"), .fill))
            }
        case .requests:
            items.append(.view(ReportGridRow(cells: ["Started", "Session", "Requested → final model", "Status", "Cost", "Tokens", "Duration", "Cache"]), .fill))
            items.append(rule())
            for item in snapshot.requests {
                items.append(.view(row("r:" + item.id, RowValue(item, [titles[item.sessionID], "\(report.detailsOpen)"])) {
                    ReportRequestRow(item: item, title: titles[item.sessionID], detailed: report.detailsOpen,
                                     inspect: { [weak self] in self?.inspect(item, title: titles[item.sessionID]) },
                                     message: { [weak self] in self?.goToMessage(item) })
                }, .fill))
                items.append(rule())
            }
            if snapshot.requests.isEmpty { items.append(.view(ReportListNote("No dispatched requests match these filters"), .fill)) }
        }
        return items
    }

    /// A row's request in its chat's Session Inspector. The chat may be gone;
    /// its project and request log are not.
    private func inspect(_ item: DashboardRequest, title: String?) {
        model.openInspector(session: item.sessionID, workspaceID: item.workspaceID, title: title, focus: .request(item.id))
    }
    /// Jumps to the message a request produced (or last consumed). When the
    /// chat is gone or the message left the visible transcript, the model
    /// explains that instead of failing silently.
    private func goToMessage(_ item: DashboardRequest) {
        messageLookup?.cancel()
        messageLookup = Task { [weak self] in
            guard let self else { return }
            let message = await self.report.linkedMessage(attemptID: item.id)
            guard !Task.isCancelled, self.model.page == .report else { return }
            // The lookup belongs to Report; navigation now belongs to the
            // workspace and must survive Report disappearing during select.
            self.messageLookup = nil
            await self.model.revealMessage(sessionID: item.sessionID, messageID: message)
        }
    }

    // MARK: Details

    private func refreshDetails(_ active: DashboardSnapshot, window: DashboardSnapshot) {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        let c = window.scopeCounts
        let key = "\(c)|\(window.filter.status)|\(window.selectedRequests)|\(active.selectedRequests)|\(report.brush != nil)|\(active.gateway)|\(report.notice)|\(active.ttft)|\(active.streaming)|\(active.http)|\(model.configuration.dashboard.metricRetentionDays)"
        guard key != keys.details else { return }
        keys.details = key
        let tiles = ShellStack(.horizontal, spacing: PiSpacing.md, alignment: .top, [
            .view(dashStatTile(title: "Time to first token", value: "p50 " + ms(active.ttft.p50), caption: "p99 \(ms(active.ttft.p99)) · \(active.ttft.samples) observed samples", symbol: "timer"), .fill),
            .view(dashStatTile(title: "Streaming span", value: "p50 " + ms(active.streaming.p50), caption: "p99 \(ms(active.streaming.p99)) · \(active.streaming.samples) observed samples", symbol: "waveform.path.ecg"), .fill),
            .view(dashStatTile(title: "Whole request", value: "p50 " + ms(active.http.p50), caption: "p99 \(ms(active.http.p99)) · \(active.http.samples) observed samples", symbol: "network"), .fill),
        ])
        let badges = PiKit.FlowView()
        badges.spacing = 6; badges.rowSpacing = 6
        for badge in [PiKit.Badge(text: "\(c.completed) completed", tone: .success, dot: true),
                      PiKit.Badge(text: "\(c.failed) failed", tone: c.failed > 0 ? .danger : .neutral, dot: true),
                      PiKit.Badge(text: "\(c.cancelled) cancelled", dot: true),
                      PiKit.Badge(text: "\(c.running) running", tone: c.running > 0 ? .warning : .neutral, dot: true),
                      PiKit.Badge(text: "\(c.truncated) truncated", dot: true),
                      PiKit.Badge(text: "\(c.interrupted) interrupted", dot: true),
                      PiKit.Badge(text: "\(c.unobservedDispatch) without observed dispatch", tone: c.unobservedDispatch > 0 ? .warning : .neutral)] {
            badges.addSubview(badge)
        }
        var coverage: [ShellItem] = [
            .view(DashSectionHeader("Coverage", subtitle: "Every status in the window; the list and metrics above use the selected status. Metrics older than \(model.configuration.dashboard.metricRetentionDays) days have expired and are not counted in any range."), .fill),
            .view(badges, .fill),
            .view(ShellText("Applied status: \(window.filter.status) · \(window.selectedRequests) requests" + (report.brush == nil ? "" : " · \(active.selectedRequests) in the chart selection"), font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 1), .fill),
            .view(ShellText(active.gateway.tokenCacheLabel, font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 1), .fill),
            .view(ShellText(reportReasoningDetail(active.gateway), font: PiKit.Font.caption, color: .piInkSecondary), .fill),
        ]
        if !report.notice.isEmpty { coverage.append(.view(ShellNote(report.notice), .fill)) }
        coverage.append(.view(ShellText("Nearest-rank percentiles: sort n observed values; select rank ceil(p × n). Missing values are excluded, never zero. TTFT = first nonempty model content − dispatch. Streaming span = last output token − first output (the model terminal for records from 0.1.85 and earlier, which have no last-output stamp). Whole request = EOF/error/cancellation − dispatch. Gateway retries and tool calls are not local HTTP attempts.",
                                        font: PiKit.Font.caption, color: .piInkTertiary), .fill))
        details.items = [.view(tiles, .fill), .view(PiKit.card(ShellStack(.vertical, spacing: PiSpacing.sm, coverage), padding: PiSpacing.md), .fill)]
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        header.compact = width < 880
        let headerHeight = header.height(forWidth: width)
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        headerRule.frame = CGRect(x: 0, y: headerHeight, width: width, height: 1)
        scroll.frame = CGRect(x: 0, y: headerHeight + 1, width: width, height: max(0, bounds.height - headerHeight - 1))
        if requestsState != nil { updateGridWidth() }
        let wide = width >= 1_050
        if overview.wide != wide, let snapshot = report.snapshot, let active = report.active ?? report.snapshot {
            overview.update(snapshot: snapshot, active: active, palette: routingPalette, wide: wide)
        }
        let columns: GridView.Columns = width < 880 ? .adaptive(minimum: 172, maximum: 320) : .flexible(6)
        if summary.columns != columns { summary.columns = columns }
        scroll.fit()
    }

    // MARK: Chart

    fileprivate func chartControls() -> PiKit.Dropdown<ReportChartMetric> {
        let picker = PiKit.Dropdown(selection: report.chartMetric, items: [(ReportChartMetric.outputRate, "Output tok/s"), (.requests, "Requests"), (.cost, "Cost"), (.latency, "Latency"), (.cacheRatio, "Cache")],
                                    compact: true, accessibilityName: "Chart metric") { [weak self] in self?.report.chartMetric = $0 }
        return picker
    }
    fileprivate var palette: MonitorModelPalette { routingPalette }
    fileprivate func include(_ names: [String]) {
        let before = routingPalette
        routingPalette.include(names)
        if routingPalette != before { observer.schedule() }
    }
}

/// The page's header: back, the title over the window caption, the spinner,
/// the time range (beside or, compact, under), refresh and Filters.
@MainActor final class ReportHeader: DashView, PiKit.WidthSizing {
    var compact = false { didSet { if compact != oldValue { needsLayout = true; invalidateIntrinsicContentSize() } } }
    private var back: NSView!, title: PiKit.TextLine!, caption: PiKit.TextLine!, spinner: NSView!, timeRange: NSView!, refresh: NSView!, filters: NSView!
    func build(back: NSView, title: PiKit.TextLine, caption: PiKit.TextLine, spinner: NSView, timeRange: NSView, refresh: NSView, filters: NSView) {
        self.back = back; self.title = title; self.caption = caption; self.spinner = spinner; self.timeRange = timeRange; self.refresh = refresh; self.filters = filters
        for view in [back, title, caption, spinner, timeRange, refresh, filters] { addSubview(view) }
    }
    private var rowHeight: CGFloat {
        let text = title.intrinsicContentSize.height + 2 + caption.intrinsicContentSize.height
        return [text, back.intrinsicContentSize.height, timeRange.intrinsicContentSize.height, refresh.intrinsicContentSize.height, filters.intrinsicContentSize.height].max() ?? text
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        12 + rowHeight + (compact ? PiSpacing.sm + timeRange.intrinsicContentSize.height : 0) + 10
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func layout() {
        super.layout()
        let scale = piScale
        let row = rowHeight
        let top: CGFloat = 12
        func centre(_ view: NSView, x: CGFloat, width: CGFloat? = nil) {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: top + PiKit.round((row - size.height) / 2, scale), width: width ?? size.width, height: size.height)
        }
        let left = PiSpacing.lg, right = bounds.width - PiSpacing.lg
        var x = left
        centre(back, x: x); x += back.intrinsicContentSize.width + PiSpacing.md
        // From the trailing edge: Filters, refresh, the range, the spinner.
        var trailing = right
        var placed: [NSView] = [filters, refresh]
        if !compact { placed.append(timeRange) }
        if !spinner.isHidden { placed.append(spinner) }
        for view in placed {
            let size = view.intrinsicContentSize
            trailing -= size.width
            centre(view, x: trailing)
            trailing -= PiSpacing.md
        }
        let textRoom = max(0, trailing + PiSpacing.md - PiSpacing.sm - x)
        let titleSize = title.intrinsicContentSize, captionSize = caption.intrinsicContentSize
        let textHeight = titleSize.height + 2 + captionSize.height
        let textTop = top + PiKit.round((row - textHeight) / 2, scale)
        title.frame = CGRect(x: x, y: textTop, width: min(titleSize.width, textRoom), height: titleSize.height)
        caption.frame = CGRect(x: x, y: textTop + titleSize.height + 2, width: min(captionSize.width, textRoom), height: captionSize.height)
        if compact {
            let size = timeRange.intrinsicContentSize
            timeRange.frame = CGRect(x: left, y: top + row + PiSpacing.sm, width: size.width, height: size.height)
        }
    }
}

/// Filters: its funnel, "Filters", the count of active filters on the
/// accent, and a chevron that turns over while the filters are open.
@MainActor final class ReportFiltersButton: PiKit.ButtonBase {
    var count = 0 { didSet { if count != oldValue { invalidateIntrinsicContentSize(); redrawContent() } } }
    var open = false { didSet { if open != oldValue { redrawContent() } } }
    init(action: @escaping () -> Void) {
        super.init(frame: .zero)
        onPress = action
        setAccessibilityLabel("Filters")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var words: PiKit.Line { PiKit.Line("Filters", font: .systemFont(ofSize: 12, weight: .medium), color: .piInk) }
    private var funnel: PiKit.Symbol { PiKit.Symbol("line.3.horizontal.decrease.circle", size: 11, weight: .semibold) }
    private var chevron: PiKit.Symbol { PiKit.Symbol("chevron.down", size: 9, weight: .semibold) }
    private var badge: PiKit.Line { PiKit.Line("\(count)", font: PiKit.Font.micro, color: .piOnAccent) }
    private var parts: [CGFloat] {
        var widths = [funnel.layoutSize.width, words.size(scale: piScale).width]
        if count > 0 { widths.append(badge.size(scale: piScale).width + 10) }
        widths.append(chevron.layoutSize.width)
        return widths
    }
    override var intrinsicContentSize: NSSize {
        let content = parts.reduce(0, +) + 5 * CGFloat(parts.count - 1)
        let height = max(words.lineHeight, funnel.layoutSize.height)
        return NSSize(width: content + 22, height: height + 10)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(isPressedDown || hovering ? .piFillStrong : .piFill)
        stroke.borderColor = piCGColor(.piHairline)
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        var x: CGFloat = 11
        let f = funnel.layoutSize
        funnel.draw(centredIn: CGRect(x: x, y: 0, width: f.width, height: rect.height), color: .piInk, scale: scale)
        x += f.width + 5
        let text = words
        text.draw(at: CGPoint(x: x, y: PiKit.round((rect.height - text.lineHeight) / 2, scale)), scale: scale)
        x += text.size(scale: scale).width + 5
        if count > 0 {
            let line = badge, size = line.size(scale: scale)
            let box = CGRect(x: x, y: PiKit.round((rect.height - size.height - 2) / 2, scale), width: size.width + 10, height: size.height + 2)
            NSColor.piAccent.setFill(); NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            line.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 1), scale: scale)
            x += box.width + 5
        }
        let c = chevron.layoutSize
        let frame = CGRect(x: x, y: 0, width: c.width, height: rect.height)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if open { context.translateBy(x: frame.midX, y: frame.midY); context.rotate(by: .pi); context.translateBy(x: -frame.midX, y: -frame.midY) }
        chevron.draw(centredIn: frame, color: .piInk, scale: scale)
        context.restoreGState()
    }
}

/// The routing overview: the chart and the routing map, then cost and
/// tokens — side by side when the page is wide, stacked when not. One view
/// tree at every width: the chart keeps its zoom and the map its "Show all".
@MainActor final class ReportOverview: DashView, PiKit.WidthSizing {
    weak var page: ReportPage?
    private(set) var wide = false
    private var throughput: ReportThroughputPanel?
    private let retained = ReportRetainedChart()
    let routing = ModelRoutingMap()
    let costs = ModelCostBreakdown()
    let tokens = AnalyticsTokenBreakdown()
    private var metric: ReportChartMetric?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [retained, routing, costs, tokens] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var chart: NSView { (metric == .outputRate ? throughput : nil) ?? retained }

    func update(snapshot: DashboardSnapshot, active: DashboardSnapshot, palette: MonitorModelPalette, wide: Bool) {
        guard let page else { return }
        let report = page.report
        self.wide = wide
        metric = report.chartMetric
        if report.chartMetric == .outputRate {
            if let throughput {
                throughput.update(snapshot: snapshot, window: report.appliedWindow, palette: palette, selection: report.chartSelection)
            } else {
                let panel = ReportThroughputPanel(live: page.model.liveActivity, snapshot: snapshot, window: report.appliedWindow, palette: palette, controls: ReportRetainedChart.Fixed140(page.chartControls()))
                panel.registerModels = { [weak page] in page?.include($0) }
                panel.select = { [weak report] range in
                    guard let report else { return }
                    // The filter now shown, not the one the panel was made with.
                    if let range, let filter = report.snapshot?.filter, let brush = DashboardBrush(range.lowerBound, range.upperBound, in: filter) { report.applyBrush(brush) } else { report.clearBrush() }
                }
                panel.update(snapshot: snapshot, window: report.appliedWindow, palette: palette, selection: report.chartSelection)
                throughput = panel
                addSubview(panel)
            }
            throughput?.isHidden = false
            retained.isHidden = true
        } else {
            throughput?.removeFromSuperview(); throughput = nil
            retained.isHidden = false
            retained.update(snapshot: snapshot, report: report, controls: page.chartControls())
        }
        let rows = report.modelSummaries ?? []
        let loading = report.modelSummaries == nil
        routing.update(rows: rows, palette: palette, loading: loading)
        costs.update(models: MonitorDistribution.report(rows, total: active.gateway), total: active.gateway, palette: palette, loading: loading)
        tokens.update(gateway: active.gateway)
        invalidateIntrinsicContentSize(); needsLayout = true
        PiKit.sizeChanged(self)
    }
    private func frames(_ width: CGFloat) -> (CGFloat, [(NSView, CGRect)]) {
        let gap = PiSpacing.md
        if wide {
            let chartWidth = max(0, width - 350 - gap)
            let first = max(PiKit.height(of: chart, width: chartWidth), PiKit.height(of: routing, width: 350))
            let half = (width - gap) / 2
            let second = max(PiKit.height(of: costs, width: half), PiKit.height(of: tokens, width: half))
            let y2 = first + PiSpacing.lg
            return (y2 + second, [(chart, CGRect(x: 0, y: 0, width: chartWidth, height: PiKit.height(of: chart, width: chartWidth))),
                                   (routing, CGRect(x: chartWidth + gap, y: 0, width: 350, height: PiKit.height(of: routing, width: 350))),
                                   (costs, CGRect(x: 0, y: y2, width: half, height: PiKit.height(of: costs, width: half))),
                                   (tokens, CGRect(x: half + gap, y: y2, width: width - half - gap, height: PiKit.height(of: tokens, width: width - half - gap)))])
        }
        var y: CGFloat = 0
        var frames: [(NSView, CGRect)] = []
        // Narrower, every card takes the width, one under the other.
        for view in [chart, routing, costs, tokens] {
            let h = PiKit.height(of: view, width: width)
            frames.append((view, CGRect(x: 0, y: y, width: width, height: h))); y += h + PiSpacing.lg
        }
        return (y - PiSpacing.lg, frames)
    }
    func height(forWidth width: CGFloat) -> CGFloat { frames(width).0 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 1_000)) }
    override func layout() {
        super.layout()
        let scale = piScale
        for (view, frame) in frames(bounds.width).1 {
            view.frame = CGRect(x: PiKit.round(frame.minX, scale), y: PiKit.round(frame.minY, scale), width: PiKit.round(frame.width, scale), height: frame.height)
        }
    }
}

/// The retained chart card: requests, cost, latency or cache over the
/// report's window; drag across it to select a range.
@MainActor final class ReportRetainedChart: DashView, PiKit.WidthSizing {
    private var header: DashSectionHeader?
    let chart = PiChartView()
    private let brush = ReportBrush()
    private lazy var resetSelection = PiKit.Button("Reset selection", style: .ghost) { [weak self] in self?.report?.clearBrush() }
    private var latencyTabs: PiKit.Tabs<ReportLatencyMetric>?
    private let column = ShellStack(.vertical, spacing: PiSpacing.sm)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    private weak var report: ReportController?
    private let chartBox = ChartBox()
    override init(frame: NSRect) {
        super.init(frame: frame)
        chartBox.addSubview(chart); chartBox.addSubview(brush)
        chartBox.chart = chart; chartBox.brush = brush
        brush.chart = chart
        addSubview(card)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(snapshot: DashboardSnapshot, report: ReportController, controls: @autoclosure () -> PiKit.Dropdown<ReportChartMetric>) {
        self.report = report
        let metric = report.chartMetric
        let header = self.header ?? DashSectionHeader("Throughput & activity", subtitle: Self.subtitle(metric), accessory: Fixed140(controls()))
        self.header = header
        header.setSubtitle(Self.subtitle(metric))
        ((header.accessory as? Fixed140)?.content as? PiKit.Dropdown<ReportChartMetric>)?.selection = metric
        let domain = snapshot.filter.from...snapshot.filter.until
        chart.spec = ReportChartSpec.make(buckets: snapshot.buckets, metric: metric, latency: report.latencyMetric, domain: domain)
        chart.setAccessibilityLabel("Throughput & activity")
        brush.filter = snapshot.filter
        brush.committed = report.chartSelection
        brush.commit = { [weak report] in report?.applyBrush($0) }
        if metric == .latency, latencyTabs == nil {
            latencyTabs = PiKit.Tabs(selection: report.latencyMetric, items: [(ReportLatencyMetric.firstToken, "First token"), (.streaming, "Streaming"), (.wholeRequest, "Whole request")]) { [weak report] in
                report?.latencyMetric = $0
            }
        }
        latencyTabs?.selection = report.latencyMetric
        var items: [ShellItem] = [.view(header, .fill), .view(chartBox, .fill)]
        if report.brush != nil { items.append(.view(resetSelection)) }
        if metric == .latency, let latencyTabs { items.append(.view(latencyTabs)) }
        column.items = items
        PiKit.sizeChanged(self)
    }
    static func subtitle(_ metric: ReportChartMetric) -> String {
        switch metric {
        case .outputRate: return "Output tokens after the first / first-to-last-token time · drag to select a range"
        case .cost: return "Reported USD over time · drag to select a range"
        case .latency: return "p50 and p99 over time, in milliseconds · drag to select a range"
        case .cacheRatio: return "Cache hit ratio over time, % of reported · drag to select a range"
        case .requests: return "Requests over time · drag to select a range"
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() { super.layout(); card.frame = bounds }

    /// The chart, 200 points tall, and its brush over it.
    final class ChartBox: DashView, PiKit.WidthSizing {
        weak var chart: PiChartView?
        weak var brush: ReportBrush?
        func height(forWidth width: CGFloat) -> CGFloat { 200 }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 200) }
        override func layout() { super.layout(); chart?.frame = bounds; brush?.frame = bounds }
    }

    /// The metric picker in its 140-point slot (`.frame(width: 140)`).
    final class Fixed140: DashView, ShellBaselined {
        let content: NSView
        /// Where `HStack(alignment: .firstTextBaseline)` puts the compact dropdown's
        /// baseline: a point above its drawn words (five points in), as measured
        /// against the SwiftUI header.
        var firstBaseline: CGFloat { 4 + PiKit.Line("Ag", font: .systemFont(ofSize: 12, weight: .medium), color: .black).baseline(scale: piScale) }
        init(_ content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: content.intrinsicContentSize.height) }
        override var firstBaselineOffsetFromTop: CGFloat { content.firstBaselineOffsetFromTop }
        override func layout() {
            super.layout()
            let size = content.intrinsicContentSize
            let width = min(140, size.width)
            content.frame = CGRect(x: PiKit.round((140 - width) / 2, piScale), y: 0, width: width, height: bounds.height)
        }
    }
}

/// The retained chart's range selection: a drag of three points or more
/// previews a range over the plot; letting go commits it.
@MainActor final class ReportBrush: DashView {
    weak var chart: PiChartView?
    var filter: DashboardFilter?
    var committed: DashboardBrush? { didSet { if committed != oldValue { needsDisplay = true } } }
    var commit: (DashboardBrush?) -> Void = { _ in }
    private var preview: DashboardBrush? { didSet { needsDisplay = true } }
    private var start: CGPoint?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let chart else { return nil }
        let local = convert(point, from: superview)
        return chart.resolved().plot.contains(local) ? self : nil
    }
    private func date(_ x: CGFloat) -> Date? {
        guard let chart else { return nil }
        let geometry = chart.resolved()
        let clamped = min(geometry.plot.maxX, max(geometry.plot.minX, x))
        return Date(timeIntervalSinceReferenceDate: geometry.x.value(at: clamped))
    }
    private func range(to point: CGPoint) -> DashboardBrush? {
        guard let start, let filter, let a = date(start.x), let b = date(point.x) else { return nil }
        return DashboardBrush(a, b, in: filter)
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start, hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        preview = range(to: point)
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { start = nil; preview = nil }
        guard let start, hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        commit(range(to: point))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let chart, let span = preview ?? committed else { return }
        let geometry = chart.resolved()
        let x0 = geometry.x.position(span.from.timeIntervalSinceReferenceDate), x1 = geometry.x.position(span.until.timeIntervalSinceReferenceDate)
        let rect = CGRect(x: x0, y: geometry.plot.minY, width: max(1, x1 - x0), height: geometry.plot.height)
        NSColor.piAccent.piOpacity(preview == nil ? 0.12 : 0.18).setFill(); rect.fill()
        NSColor.piAccent.setFill()
        CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
}

/// The grouping tabs and the pager: on one line when they fit, else stacked.
@MainActor final class ReportRequestControls: DashView, PiKit.WidthSizing {
    let tabs: NSView
    /// The pager, or the line that stands in for it.
    var pager: NSView {
        didSet {
            guard pager !== oldValue else { return }
            oldValue.removeFromSuperview(); addSubview(pager)
            invalidateIntrinsicContentSize(); needsLayout = true
        }
    }
    init(tabs: NSView, pager: NSView) {
        self.tabs = tabs; self.pager = pager
        super.init(frame: .zero)
        addSubview(tabs); addSubview(pager)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func fits(_ width: CGFloat) -> Bool { tabs.intrinsicContentSize.width + PiSpacing.sm + pager.intrinsicContentSize.width <= width }
    func height(forWidth width: CGFloat) -> CGFloat {
        let a = tabs.intrinsicContentSize.height, b = pager.intrinsicContentSize.height
        return fits(width) ? max(a, b) : a + PiSpacing.sm + b
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 1_000)) }
    override func layout() {
        super.layout()
        let scale = piScale
        let a = tabs.intrinsicContentSize, b = pager.intrinsicContentSize
        if fits(bounds.width) {
            let h = max(a.height, b.height)
            tabs.frame = CGRect(x: 0, y: PiKit.round((h - a.height) / 2, scale), width: a.width, height: a.height)
            pager.frame = CGRect(x: bounds.width - b.width, y: PiKit.round((h - b.height) / 2, scale), width: b.width, height: b.height)
        } else {
            tabs.frame = CGRect(x: 0, y: 0, width: a.width, height: a.height)
            pager.frame = CGRect(x: 0, y: a.height + PiSpacing.sm, width: b.width, height: b.height)
        }
    }
}

/// The request grid in a scroll view that moves sideways when the page is
/// narrower than the grid.
@MainActor final class ReportGridScroll: DashView, PiKit.WidthSizing {
    let content: NSView
    /// The grid's width: the page's, from 1,100 to 1,232 points.
    var width: CGFloat { didSet { if width != oldValue { needsLayout = true } } }
    private let scroll = NSScrollView()
    private let document = DashView()
    init(content: NSView, width: CGFloat) {
        self.content = content; self.width = width
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.verticalScrollElasticity = .none
        document.addSubview(content)
        scroll.documentView = document
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var contentHeight: CGFloat { PiKit.height(of: (content as? ShellInset)?.content ?? content, width: width) }
    func height(forWidth width: CGFloat) -> CGFloat { contentHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let height = contentHeight
        document.frame = CGRect(x: 0, y: 0, width: width, height: height)
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// A box on the sunken surface at 60 per cent: a session's nested requests.
@MainActor final class SunkenBox: DashView, PiKit.WidthSizing {
    let content: NSView
    init(_ content: NSView) { self.content = content; super.init(frame: .zero); wantsLayer = true; addSubview(content) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(NSColor.piSurfaceSunken.piOpacity(0.6)) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: content, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 1_100)) }
    override func layout() { super.layout(); content.frame = bounds }
}

/// "No … match these filters": caption, tertiary, centred with room around it.
@MainActor final class ReportListNote: DashView {
    let line: PiKit.Line
    init(_ text: String) {
        line = PiKit.Line(text, font: PiKit.Font.caption, color: .piInkTertiary)
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: line.lineHeight + PiSpacing.lg * 2) }
    override func draw(_ dirtyRect: NSRect) {
        let size = line.size(scale: piScale)
        line.draw(at: CGPoint(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiSpacing.lg), scale: piScale)
    }
}

/// A small spinner and what it waits for.
@MainActor final class ReportInlineLoading: DashView {
    private let spinner = piSpinner(size: 10)
    private let text: PiKit.TextLine
    init(_ words: String) {
        text = PiKit.TextLine(PiKit.Line(words, font: PiKit.Font.caption, color: .piInkTertiary))
        super.init(frame: .zero)
        addSubview(spinner); addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize {
        let t = text.intrinsicContentSize
        return NSSize(width: 10 + 6 + t.width, height: max(10, t.height))
    }
    override func layout() {
        super.layout()
        let t = text.intrinsicContentSize
        spinner.frame = CGRect(x: 0, y: PiKit.round((bounds.height - 10) / 2, piScale), width: 10, height: 10)
        text.frame = CGRect(x: 16, y: PiKit.round((bounds.height - t.height) / 2, piScale), width: t.width, height: t.height)
    }
}

/// "Grouping by model…" centred in the list with room around it.
@MainActor final class ReportListLoading: DashView {
    private let inner: ReportInlineLoading
    init(_ words: String) { inner = ReportInlineLoading(words); super.init(frame: .zero); addSubview(inner) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: inner.intrinsicContentSize.height + PiSpacing.lg * 2) }
    override func layout() {
        super.layout()
        let size = inner.intrinsicContentSize
        inner.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiSpacing.lg, width: size.width, height: size.height)
    }
}

/// Before the first read lands: a spinner and what is being read.
@MainActor final class ReportLoadingState: DashView {
    private let spinner = piSpinner(size: 20)
    private let text = PiKit.TextLine(PiKit.Line("Reading retained request metrics…", font: PiKit.Font.caption, color: .piInkSecondary))
    override init(frame: NSRect) { super.init(frame: frame); addSubview(spinner); addSubview(text) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 320) }
    override func layout() {
        super.layout()
        let t = text.intrinsicContentSize
        let total = 20 + 10 + t.height
        let top = PiKit.round((bounds.height - total) / 2, piScale)
        spinner.frame = CGRect(x: PiKit.round((bounds.width - 20) / 2, piScale), y: top, width: 20, height: 20)
        text.frame = CGRect(x: PiKit.round((bounds.width - t.width) / 2, piScale), y: top + 30, width: t.width, height: t.height)
    }
}

/// No requests in the range: what to do, and the ways to widen it.
@MainActor final class ReportEmptyState: DashView {
    var monthly: () -> Void = {}
    var clear: () -> Void = {}
    private let symbol = PiKit.SymbolView(PiKit.Symbol("chart.xyaxis.line", size: 28), color: .piInkTertiary)
    private let title = PiKit.TextLine(PiKit.Line("No requests in this range", font: PiKit.Font.title(16), color: .piInk))
    private let detail = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private lazy var month = PiKit.Button("Last 30 days", style: .secondary, compact: true) { [weak self] in self?.monthly() }
    private lazy var clearButton = PiKit.Button("Clear filters", style: .ghost) { [weak self] in self?.clear() }
    private lazy var buttons = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(month), .view(clearButton)])
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [symbol, title, detail, buttons] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func configure(chips: Bool, monthly: Bool) {
        detail.line.text = chips ? "Widen the time range or clear a filter." : "Send a message, or widen the time range."
        month.isHidden = !monthly; clearButton.isHidden = !chips
        buttons.relayoutAll(); needsLayout = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 320) }
    override func layout() {
        super.layout()
        let scale = piScale
        let showsButtons = !month.isHidden || !clearButton.isHidden
        let parts: [NSView] = showsButtons ? [symbol, title, detail, buttons] : [symbol, title, detail]
        let sizes = parts.map { $0 === buttons ? CGSize(width: buttons.naturalWidth, height: buttons.height(forWidth: buttons.naturalWidth)) : $0.intrinsicContentSize }
        let total = sizes.reduce(0) { $0 + $1.height } + 10 * CGFloat(parts.count - 1)
        var y = PiKit.round((bounds.height - total) / 2, scale)
        for (view, size) in zip(parts, sizes) {
            view.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, scale), y: y, width: size.width, height: size.height)
            y += size.height + 10
        }
        buttons.isHidden = !showsButtons
    }
}

/// A failed read: the reason on a danger wash, and Retry.
@MainActor final class ReportFailure: DashView, PiKit.WidthSizing {
    var retry: () -> Void = {}
    var message = "" { didSet { if message != oldValue { text.set(message, color: .piInk); needsLayout = true } } }
    private let symbol = PiKit.SymbolView(PiKit.Symbol("exclamationmark.triangle.fill", size: 13), color: .piDanger)
    private let text = ShellText("", font: PiKit.Font.caption, color: .piInk, maximumLines: 2)
    private lazy var button = PiKit.Button("Retry", style: .secondary, compact: true) { [weak self] in self?.retry() }
    private lazy var row = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md),
                                      [.view(symbol), .view(text, .flexible), .spacer(8), .view(button)])
    override init(frame: NSRect) { super.init(frame: frame); addSubview(row) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() { super.layout(); row.frame = bounds }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.piDanger.piOpacity(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: PiRadius.md, yRadius: PiRadius.md).fill()
    }
}

/// "Details · timings, coverage and methodology" / "Hide details", its
/// chevron turning over while open.
@MainActor final class ReportDetailsToggle: PiKit.ButtonBase {
    var open = false { didSet { if open != oldValue { invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(words) } } }
    init(action: @escaping () -> Void) { super.init(frame: .zero); onPress = action; setAccessibilityLabel(words) }
    private var words: String { open ? "Hide details" : "Details · timings, coverage and methodology" }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var line: PiKit.Line { PiKit.Line(words, font: .systemFont(ofSize: 12.5, weight: .medium), color: .piInkSecondary) }
    private var chevron: PiKit.Symbol { PiKit.Symbol("chevron.down", size: 9, weight: .semibold) }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale)
        return NSSize(width: text.width + 5 + chevron.layoutSize.width + 20, height: text.height + 12)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(isPressedDown ? .piFillStrong : hovering ? .piFill : .clear)
        stroke.borderColor = CGColor.clear
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        let text = line.size(scale: scale)
        line.draw(at: CGPoint(x: 10, y: PiKit.round((rect.height - text.height) / 2, scale)), scale: scale)
        let c = chevron.layoutSize
        let frame = CGRect(x: 10 + text.width + 5, y: 0, width: c.width, height: rect.height)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if open { context.translateBy(x: frame.midX, y: frame.midY); context.rotate(by: .pi); context.translateBy(x: -frame.midX, y: -frame.midY) }
        chevron.draw(centredIn: frame, color: .piInkSecondary, scale: scale)
        context.restoreGState()
    }
}

/// The advanced filters card: custom dates, the project, session, status,
/// API and purpose pickers, the model pickers, reset and save.
@MainActor final class ReportAdvancedFilters: DashView, PiKit.WidthSizing {
    weak var page: ReportPage? { didSet { if page != nil, oldValue == nil { build() } } }
    private let column = ShellStack(.vertical, spacing: PiSpacing.sm)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    // Built once and updated in place: a field being typed in, a date being
    // edited or a list being read keeps its editor, caret and focus.
    private let dates = PiKit.FlowView()
    private var from: ReportDatePill!
    private var until: ReportDatePill!
    private let first = PiKit.FlowView()
    private var project: ReportDropdown!
    private var session: ReportDropdown!
    private var sessionField: PiKit.TextField!
    private var sessionFieldBox: Sized!
    private var status: ReportDropdown!
    private var api: ReportDropdown!
    private var purpose: ReportDropdown!
    private let second = PiKit.FlowView()
    private var alias: ReportDropdown!
    private var finalModel: ReportDropdown!
    private var unreported: PiKit.Checkbox!
    private var reset: PiKit.Button!
    private var save: PiKit.Button!
    private let note = ShellText("Filters apply as you change them. The summary, chart and list use the selected status. Details also show totals across all statuses.", font: PiKit.Font.caption, color: .piInkTertiary)
    private var shownCustom: Bool?
    private var finalModelOwn = true, resetOwn = true, saveOwn = true
    override init(frame: NSRect) { super.init(frame: frame); addSubview(card) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    private func build() {
        guard let report = page?.report else { return }
        for flow in [dates, first, second] { flow.spacing = PiSpacing.sm; flow.rowSpacing = PiSpacing.sm }
        from = ReportDatePill(label: "From", date: report.window.from) { [weak report] in report?.setCustomBound($0, anchorFrom: true) }
        until = ReportDatePill(label: "Until", date: report.window.until) { [weak report] in report?.setCustomBound($0, anchorFrom: false) }
        dates.addSubview(from); dates.addSubview(until)
        project = ReportDropdown(selection: "", items: [], icon: "folder") { [weak report] in report?.setWorkspace($0.isEmpty ? nil : $0) }
        session = ReportDropdown(selection: "", items: [], icon: "bubble.left") { [weak report] in report?.chooseSession($0) }
        sessionField = PiKit.TextField(placeholder: "Session id", text: report.preferences.sessionID ?? "", icon: "number", mono: true,
                                       onChange: { [weak report] in report?.preferences.sessionID = $0.isEmpty ? nil : $0 })
        sessionFieldBox = Sized(sessionField, width: 220)
        status = ReportDropdown(selection: "", items: [("completed", "Completed"), ("all", "All statuses"), ("failed", "Failed"), ("cancelled", "Cancelled"), ("running", "Running"), ("truncated", "Truncated"), ("interrupted", "Interrupted")], icon: "checkmark.circle") { [weak report] in report?.preferences.status = $0 }
        api = ReportDropdown(selection: "", items: [("", "All API history"), ("openai-responses", "Responses"), ("anthropic-messages", "Messages · history")], icon: "arrow.left.arrow.right") { [weak report] in report?.preferences.api = $0.isEmpty ? nil : $0 }
        purpose = ReportDropdown(selection: "", items: [], icon: "tag") { [weak report] in report?.preferences.purpose = $0.isEmpty ? nil : $0 }
        for view in [project, session, sessionFieldBox, status, api, purpose] as [NSView] { first.addSubview(view) }
        alias = ReportDropdown(selection: "", items: [], icon: "arrow.triangle.branch") { [weak report] in report?.preferences.requestedAlias = $0.isEmpty ? nil : $0 }
        finalModel = ReportDropdown(selection: "", items: [], icon: "cpu") { [weak report] in report?.preferences.effectiveModel = $0.isEmpty ? nil : $0 }
        unreported = PiKit.Checkbox(isOn: false, label: "Final model not reported") { [weak report] in report?.unreportedOnly = $0 }
        unreported.labelFont = PiKit.Font.caption
        unreported.toolTip = "Includes unreported, conflicting or incomplete model evidence; the inspector preserves the distinct status and provenance."
        reset = PiKit.Button("Reset", style: .ghost) { [weak report] in report?.reset() }
        save = PiKit.Button("Save as Default", style: .ghost) { [weak report] in guard let report else { return }; Task { await report.save() } }
        for view in [alias, finalModel, unreported, reset, save] as [NSView] { second.addSubview(view) }
    }

    func refresh() {
        guard let page, from != nil else { return }
        let report = page.report, model = page.model
        let custom = report.window.preset == .custom
        if custom != shownCustom {
            shownCustom = custom
            column.items = (custom ? [.view(dates, .fill)] : []) + [.view(first, .fill), .view(second, .fill), .view(note, .fill)]
        }
        if custom {
            from.date = report.preferences.customFrom ?? report.window.from
            until.date = report.preferences.customUntil ?? report.window.until
        }
        project.items = projectItems(report, model)
        project.selection = report.preferences.workspaceID ?? ""
        session.items = sessionItems(report, model)
        session.selection = report.sessionEntry ? ReportController.manualSession : (report.preferences.sessionID ?? "")
        sessionFieldBox.isHidden = !report.sessionEntry
        // The field is the reader's while they type in it.
        if !report.sessionEntry || sessionField.window?.firstResponder !== sessionField.field.currentEditor() {
            sessionField.text = report.preferences.sessionID ?? ""
        }
        status.selection = report.preferences.status
        api.selection = report.preferences.api ?? ""
        purpose.items = valueItems(report.purposes, any: "Any purpose", current: report.preferences.purpose)
        purpose.selection = report.preferences.purpose ?? ""
        alias.items = valueItems(report.aliases, any: "Any requested model", current: report.preferences.requestedAlias)
        alias.selection = report.preferences.requestedAlias ?? ""
        finalModel.items = valueItems(report.models, any: "Any final model", current: report.preferences.effectiveModel)
        finalModel.selection = report.preferences.effectiveModel ?? ""
        finalModelOwn = !report.unreportedOnly
        finalModel.alphaValue = report.unreportedOnly ? 0.5 : 1
        unreported.isOn = report.unreportedOnly
        resetOwn = !report.loading
        saveOwn = !report.loading && model.configurationLoaded
        // Its controls' own states; the page disables them over that when it is.
        applyEnabled(true)
        for flow in [dates, first, second] { flow.invalidateIntrinsicContentSize(); flow.needsLayout = true }
        column.relayoutAll()
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    /// The page's disabled state over every control here, each also needing its own reason.
    func applyEnabled(_ enabled: Bool) {
        guard from != nil else { return }
        for control in [project, session, status, api, purpose, alias, unreported] as [NSControl] { control.isEnabled = enabled }
        finalModel.isEnabled = enabled && finalModelOwn
        reset.isEnabled = enabled && resetOwn
        save.isEnabled = enabled && saveOwn
        sessionField.field.isEnabled = enabled
        from.isEnabled = enabled; until.isEnabled = enabled
    }
    private func projectItems(_ report: ReportController, _ model: WorkspaceModel) -> [(String, String)] {
        var items: [(String, String)] = [("", "All projects")]
        items += model.workspaces.map { ($0.id, URL(fileURLWithPath: $0.path).lastPathComponent) }
        if model.chats.contains(where: { $0.workspaceID == WorkspaceRecord.scratchID }) { items.append((WorkspaceRecord.scratchID, "No project")) }
        if let id = report.preferences.workspaceID, id != WorkspaceRecord.scratchID, !model.workspaces.contains(where: { $0.id == id }) { items.append((id, "Retained: " + id)) }
        return items
    }
    private func sessionItems(_ report: ReportController, _ model: WorkspaceModel) -> [(String, String)] {
        let chats = model.chats.filter { report.preferences.workspaceID == nil || $0.workspaceID == report.preferences.workspaceID }.prefix(200)
        var items: [(String, String)] = [("", "Any session")] + chats.map { ($0.id, $0.title.isEmpty ? String($0.id.prefix(8)) : $0.title) }
        if let id = report.preferences.sessionID, !report.sessionEntry, !chats.contains(where: { $0.id == id }) { items.append((id, "Retained: " + String(id.prefix(8)))) }
        items.append((ReportController.manualSession, "Enter id…"))
        return items
    }
    private func valueItems(_ values: [String], any: String, current: String?) -> [(String, String)] {
        var items = [("", any)] + values.map { ($0, $0) }
        if let current, !current.isEmpty, !values.contains(current) { items.append((current, current + " (not in window)")) }
        return items
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: card, width: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 1_000)) }
    override func layout() { super.layout(); card.frame = bounds }

    /// A view at a fixed width (`.frame(width:)`).
    final class Sized: DashView {
        let content: NSView, width: CGFloat
        init(_ content: NSView, width: CGFloat) { self.content = content; self.width = width; super.init(frame: .zero); addSubview(content) }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { NSSize(width: width, height: content.intrinsicContentSize.height) }
        override func layout() { super.layout(); content.frame = bounds }
    }
}

/// A custom bound: its label in small capitals and the date field, in a
/// hairline capsule on the surface.
@MainActor final class ReportDatePill: DashView {
    private let label: PiKit.TextLine
    private let field: NSDatePicker
    private let changed: (Date) -> Void
    init(label: String, date: Date, changed: @escaping (Date) -> Void) {
        self.label = PiKit.TextLine(PiKit.Line(label, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
        field = PiKit.dateField(date)
        self.changed = changed
        super.init(frame: .zero)
        wantsLayer = true
        field.target = self; field.action = #selector(dateChanged)
        field.setAccessibilityLabel(label)
        addSubview(self.label); addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    @objc private func dateChanged() { changed(field.dateValue) }
    /// The bound shown; set from the report without disturbing an edit of the same value.
    var date: Date {
        get { field.dateValue }
        set { if field.dateValue != newValue { field.dateValue = newValue } }
    }
    var isEnabled: Bool {
        get { field.isEnabled }
        set { field.isEnabled = newValue; alphaValue = newValue ? 1 : 0.5 }
    }
    override var intrinsicContentSize: NSSize {
        let l = label.intrinsicContentSize, f = field.intrinsicContentSize
        return NSSize(width: 10 + l.width + 6 + f.width + 6, height: max(l.height, f.height) + 6)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piSurface); layer?.borderColor = piCGColor(.piHairlineStrong); layer?.borderWidth = 1
        layer?.cornerRadius = bounds.height / 2
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func layout() {
        super.layout()
        let scale = piScale
        let l = label.intrinsicContentSize, f = field.intrinsicContentSize
        label.frame = CGRect(x: 10, y: PiKit.round((bounds.height - l.height) / 2, scale), width: l.width, height: l.height)
        field.frame = CGRect(x: 10 + l.width + 6, y: PiKit.round((bounds.height - f.height) / 2, scale), width: f.width, height: f.height)
        needsDisplay = true
    }
}
