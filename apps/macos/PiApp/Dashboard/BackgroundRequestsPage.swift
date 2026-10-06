import AppKit

/// Every request the app asked a mini model on its own — chat titles, the
/// rename sheet's title suggestions and webhook notifications — newest first,
/// as a page inside the main window beside the usage report. Selecting one
/// shows what it sent and got back; its captured requests are in the Session
/// Inspector. The rows are worked out by `BackgroundRequestsController`
/// when the records change; this view only lays them out.
@MainActor final class BackgroundRequestsPage: DashView, InheritsReducedMotion {
    let model: WorkspaceModel
    let requests: BackgroundRequestsController
    /// The window's disabled state, handed down as SwiftUI's environment did.
    var inheritedEnabled = true { didSet { if inheritedEnabled != oldValue { applyEnabled() } } }
    /// The window's reduced motion (`piReduceMotion`): no selection glide under it.
    var inheritedReduceMotion = false { didSet { if inheritedReduceMotion != oldValue { shownRows = []; refresh() } } }
    private var observer: ShellObserver!
    private var prepared = false
    private let glide = PiKit.SelectionGlide()

    // Header
    private lazy var back: PiKit.Button = {
        let button = PiKit.Button("Chats", symbol: "chevron.left", style: .ghost) { [weak self] in self?.model.closeReport() }
        button.toolTip = "Back to chats (Esc)"; button.setAccessibilityIdentifier("backgroundRequestsBack")
        return button
    }()
    private let title = PiKit.TextLine(PiKit.Line("Background requests", font: PiKit.Font.title(17), color: .piInk))
    private let caption = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private lazy var filterTabs: PiKit.Tabs<BackgroundRequestFilter> = {
        let tabs = PiKit.Tabs(selection: requests.filter, items: BackgroundRequestFilter.allCases.map { ($0, $0.title) }, accessibilityName: "Kind of request") { [weak self] in
            self?.requests.filter = $0
        }
        tabs.setAccessibilityIdentifier("backgroundRequestsFilter")
        return tabs
    }()
    private let headerRule = HairlineView()

    // Body
    private let list = LazyStackView()
    /// Keeps the pointer off the list while the details cover it (`.allowsHitTesting`).
    private let listGate = HitGate()
    private let empty = BackgroundRequestsEmptyState()
    private let detailRule = HairlineView()
    private var detail: BackgroundRequestDetailPane?
    /// The minute the "3m ago" stamps are worked out against (`TimelineView(.everyMinute)`).
    private var minute = Date()
    private var minuteTimer: Timer?
    private var shownRows: [BackgroundRequestRow] = []
    private var shownSelection: String?
    private var shownMinute: Date?
    /// Opened on a request (the menu bar's running one, the report's row): shown once it is laid out.
    /// The request the page opened on (the menu bar's running one, the
    /// report's row): scrolled to the middle once laid out (`.onAppear`).
    private var revealSelection: String?

    init(model: WorkspaceModel) {
        self.model = model; requests = model.backgroundRequests
        super.init(frame: .zero)
        wantsLayer = true
        caption.truncation = .end
        list.spacing = 2
        list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.md, bottom: PiSpacing.sm, right: PiSpacing.md)
        listGate.addSubview(list)
        for view in [back, title, caption, filterTabs, headerRule, listGate, empty, detailRule] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Background requests")
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(requests)
        // `.onChange(of: model.chatsRevision)` and `workspacesRevision`: the records changed.
        observer.observe(publisher: model.$chats)
        observer.observe(publisher: model.$workspaces)
        seenRevisions = (model.chatsRevision, model.workspacesRevision)
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
            revealSelection = requests.selectedID
            requests.prepare(model)
            startMinuteClock()
        } else if prepared {
            // Off screen (`.onDisappear`).
            prepared = false
            requests.suspend()
            minuteTimer?.invalidate(); minuteTimer = nil
        }
    }
    /// Ticks on each minute, as the stamps change.
    private func startMinuteClock() {
        minuteTimer?.invalidate()
        minute = Date()
        let next = (minute.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.minute = Date(); self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }
    /// `.disabled(!enabled)` over the page: every control under it disabled,
    /// each control's own state kept and given back; nothing takes the pointer.
    private var heldEnabled: [ObjectIdentifier: (control: NSControl, enabled: Bool)] = [:]
    private func applyEnabled() {
        if inheritedEnabled {
            for (_, held) in heldEnabled { held.control.isEnabled = held.enabled }
            heldEnabled = [:]
        } else {
            holdControls()
        }
    }
    /// Gives every held control its own state back, so an update sees and
    /// sets the controls' own states; `holdControls` disables them again after.
    private func releaseControls() {
        for (_, held) in heldEnabled { held.control.isEnabled = held.enabled }
        heldEnabled = [:]
    }
    private func holdControls(in root: NSView? = nil) {
        guard !inheritedEnabled else { return }
        for control in PiKit.controls(in: root ?? self) where heldEnabled[ObjectIdentifier(control)] == nil {
            heldEnabled[ObjectIdentifier(control)] = (control, control.isEnabled)
            control.isEnabled = false
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { inheritedEnabled ? super.hitTest(point) : nil }

    private var selectedRow: BackgroundRequestRow? { requests.selectedID.flatMap { id in requests.rows.first { $0.id == id } } }
    private var sideBySide: Bool { bounds.width >= 900 }
    private var compact: Bool { bounds.width < 760 }

    // MARK: Refresh

    private var seenRevisions = (0, 0)
    func refresh() {
        releaseControls()
        let revisions = (model.chatsRevision, model.workspacesRevision)
        if revisions != seenRevisions { seenRevisions = revisions; requests.recordsChanged() }
        caption.line.text = Self.caption(requests.summary); caption.toolTip = caption.line.text
        filterTabs.selection = requests.filter
        let rows = requests.rows
        if rows != shownRows || requests.selectedID != shownSelection || minute != shownMinute {
            let reload = rows.map(\.id) != shownRows.map(\.id)
            shownRows = rows; shownSelection = requests.selectedID; shownMinute = minute
            let source = LazyStackView.Source(count: rows.count, key: { rows[$0].id }, height: { [weak self] index, width in
                self?.rowHeight(rows[index], width: width) ?? 0
            }, view: { [weak self] index, existing in
                guard let self else { return NSView() }
                return self.rowView(rows[index], existing: existing)
            })
            if reload { list.reload(source) } else { list.update(source) }
        }
        empty.filter = requests.filter
        empty.isHidden = !rows.isEmpty
        if let row = selectedRow {
            if let detail { detail.update(row: row, detail: requests.detail, loading: requests.detailLoading) }
            else {
                let pane = BackgroundRequestDetailPane(row: row, detail: requests.detail, loading: requests.detailLoading,
                    openSource: { [weak self] id in self?.model.openBackgroundRequestSource(id) },
                    inspect: { [weak self] id in self?.model.inspectBackgroundRequest(id) },
                    close: { [weak self] in self?.requests.selectedID = nil })
                detail = pane
                addSubview(pane)
            }
        } else if let detail {
            detail.removeFromSuperview(); self.detail = nil
        }
        holdControls()
        needsLayout = true
    }

    /// What the mini model was asked in the background, and what the listed requests add up to.
    static func caption(_ summary: BackgroundRequestSummary) -> String {
        var parts = ["Asked of the mini model in the background · \(summary.requests) request\(summary.requests == 1 ? "" : "s")"]
        if summary.running > 0 { parts.append("\(summary.running) running") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if let tokens = summary.tokens { parts.append(compactTokens(tokens) + " tokens") }
        if let cost = summary.cost { parts.append(compactGatewayUSD(cost)) }
        return parts.joined(separator: " · ")
    }

    private func rowHeight(_ row: BackgroundRequestRow, width: CGFloat) -> CGFloat {
        BackgroundRequestRowContent.height + PiKit.SelectableRow.padding.top + PiKit.SelectableRow.padding.bottom
    }
    private func rowView(_ row: BackgroundRequestRow, existing: NSView?) -> NSView {
        let selected = requests.selectedID == row.id
        if let view = existing as? PiKit.SelectableRow, let content = view.contentView as? BackgroundRequestRowContent {
            content.update(row: row, minute: minute)
            view.glide = piReducesMotion ? nil : glide
            view.selected = selected
            view.setAccessibilityLabel(content.spoken)
            return view
        }
        let content = BackgroundRequestRowContent(row: row, minute: minute) { [weak self] in self?.model.openBackgroundRequestSource(row.id) }
        let view = PiKit.SelectableRow(content: content, selected: selected, glide: piReducesMotion ? nil : glide) { [weak self] in self?.requests.selectedID = content.row.id }
        view.setAccessibilityIdentifier("backgroundRequest-" + row.id)
        view.setAccessibilityLabel(content.spoken)
        content.openSource = { [weak self, weak content] in guard let self, let content else { return }; self.model.openBackgroundRequestSource(content.row.id) }
        // A row made while the page is disabled (scrolled or resized into view) is disabled too.
        holdControls(in: view)
        return view
    }

    // MARK: Layout

    private var headerRowHeight: CGFloat {
        max(title.intrinsicContentSize.height + 2 + caption.intrinsicContentSize.height, back.intrinsicContentSize.height, filterTabs.intrinsicContentSize.height)
    }
    private var headerHeight: CGFloat {
        12 + headerRowHeight + (compact ? PiSpacing.sm + filterTabs.intrinsicContentSize.height : 0) + 10
    }
    override func layout() {
        super.layout()
        let scale = piScale, width = bounds.width
        let row = headerRowHeight, top: CGFloat = 12
        func centre(_ view: NSView, x: CGFloat) {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: top + PiKit.round((row - size.height) / 2, scale), width: size.width, height: size.height)
        }
        var x = PiSpacing.lg
        centre(back, x: x); x += back.intrinsicContentSize.width + PiSpacing.md
        var trailing = width - PiSpacing.lg
        let tabs = filterTabs.intrinsicContentSize
        if compact {
            filterTabs.frame = CGRect(x: PiSpacing.lg, y: top + row + PiSpacing.sm, width: tabs.width, height: tabs.height)
            // The old HStack ended in a spacer, with one 12-point gap.
            trailing -= PiSpacing.md + PiSpacing.sm
        } else {
            trailing -= tabs.width
            centre(filterTabs, x: trailing)
            // The spacer sat between the title column and tabs: two gaps.
            trailing -= 2 * PiSpacing.md + PiSpacing.sm
        }
        let room = max(0, trailing - x)
        let titleSize = title.intrinsicContentSize, captionSize = caption.intrinsicContentSize
        let textTop = top + PiKit.round((row - titleSize.height - 2 - captionSize.height) / 2, scale)
        title.frame = CGRect(x: x, y: textTop, width: min(titleSize.width, room), height: titleSize.height)
        caption.frame = CGRect(x: x, y: textTop + titleSize.height + 2, width: min(captionSize.width, room), height: captionSize.height)
        let header = headerHeight
        headerRule.frame = CGRect(x: 0, y: header, width: width, height: 1)
        let body = CGRect(x: 0, y: header + 1, width: width, height: max(0, bounds.height - header - 1))
        var listFrame = body
        if let detail {
            if sideBySide {
                let paneWidth: CGFloat = width >= 1_100 ? 440 : 360
                listFrame.size.width = max(0, width - paneWidth - 1)
                detailRule.isHidden = false
                detailRule.frame = CGRect(x: listFrame.maxX, y: body.minY, width: 1, height: body.height)
                detail.frame = CGRect(x: listFrame.maxX + 1, y: body.minY, width: paneWidth, height: body.height)
            } else {
                // Narrower, the details take the page and the list waits under them, where it was.
                detailRule.isHidden = true
                detail.frame = body
            }
        } else {
            detailRule.isHidden = true
        }
        let covered = detail != nil && !sideBySide
        list.alphaValue = covered ? 0 : 1
        listGate.passes = !covered
        listGate.frame = listFrame
        list.frame = listGate.bounds
        let emptySize = empty.size(forWidth: listFrame.width)
        empty.frame = CGRect(x: PiKit.round((listFrame.width - emptySize.width) / 2, scale), y: listFrame.minY + PiKit.round((listFrame.height - emptySize.height) / 2, scale),
                             width: emptySize.width, height: emptySize.height)
        empty.alphaValue = covered ? 0 : 1
        if let id = revealSelection, listFrame.height > 0 {
            revealSelection = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let index = self.requests.rows.firstIndex(where: { $0.id == id }) else { return }
                self.list.scrollToRowCentred(index)
            }
        }
    }
}

/// "No background requests yet": the badge, a title and what appears here.
@MainActor final class BackgroundRequestsEmptyState: DashView {
    var filter: BackgroundRequestFilter = .all { didSet { if filter != oldValue { apply() } } }
    private let badge = PiKit.IconBadge(symbol: "sparkles.rectangle.stack", tone: .accent, size: 36)
    private let title = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.heading, color: .piInk))
    private let detail = TextBlock("Chat titles, title suggestions and webhook notifications appear here as the mini model writes them.",
                                   font: PiKit.Font.caption, color: .piInkSecondary, centred: true)
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [badge, title, detail] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func apply() {
        title.line.text = filter == .all ? "No background requests yet" : "No \(filter.title.lowercased()) yet"
        setAccessibilityLabel(title.line.text + ", " + detail.text)
        needsLayout = true
    }
    private func detailWidth(_ width: CGFloat) -> CGFloat { min(360, detail.idealWidth, max(0, width - PiSpacing.xl * 2)) }
    func size(forWidth width: CGFloat) -> CGSize {
        let inner = max(badge.frame.width, title.intrinsicContentSize.width, detailWidth(width))
        let height = 36 + 10 + title.intrinsicContentSize.height + 10 + detail.height(forWidth: detailWidth(width))
        return CGSize(width: inner + PiSpacing.xl * 2, height: height + PiSpacing.xl * 2)
    }
    override func layout() {
        super.layout()
        let scale = piScale, width = bounds.width
        var y = PiSpacing.xl
        badge.frame = CGRect(x: PiKit.round((width - 36) / 2, scale), y: y, width: 36, height: 36); y += 36 + 10
        let t = title.intrinsicContentSize
        title.frame = CGRect(x: PiKit.round((width - t.width) / 2, scale), y: y, width: t.width, height: t.height); y += t.height + 10
        let w = detailWidth(size(forWidth: width).width)
        detail.frame = CGRect(x: PiKit.round((width - w) / 2, scale), y: y, width: w, height: detail.height(forWidth: w))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// How a request stands, as a badge: a spinner while it runs.
@MainActor func backgroundRequestBadge(_ status: BackgroundRequestStatus) -> PiKit.Badge {
    let badge = PiKit.Badge(text: status.label)
    styleBackgroundRequestBadge(badge, status)
    return badge
}
@MainActor func styleBackgroundRequestBadge(_ badge: PiKit.Badge, _ status: BackgroundRequestStatus) {
    badge.text = status.label
    switch status {
    case .running: badge.tone = .warning; badge.dot = false; badge.spinning = true
    case .completed: badge.tone = .success; badge.dot = true; badge.spinning = false
    case .failed: badge.tone = .danger; badge.dot = true; badge.spinning = false
    case .interrupted: badge.tone = .neutral; badge.dot = true; badge.spinning = false
    }
}

/// One request: what it was for and what it produced or why it did not,
/// how it stands and how long it took; then when, for which chat and project,
/// on which connection and model, and what it cost.
@MainActor final class BackgroundRequestRowContent: DashView {
    private(set) var row: BackgroundRequestRow
    private var minute: Date
    var openSource: () -> Void
    private var icon: PiKit.IconBadge
    private let kind = PiKit.TextLine(PiKit.Line("", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInkSecondary))
    private let headline = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.body, color: .piInk))
    private let duration = PiKit.TextLine(PiKit.Line("", font: BackgroundRequestRowContent.metaFont, color: .piInkSecondary))
    private let badge = PiKit.Badge(text: "")
    private let meta = Metadata()
    static var metaFont: NSFont { PiKit.Font.monospacedDigits(PiKit.Font.caption) }
    /// The two lines, 4 apart, the first as tall as its badge.
    static let height: CGFloat = {
        let first = max(PiKit.Line("Ag", font: PiKit.Font.body, color: .black).lineHeight, PiKit.Badge(text: "Done", dot: true).intrinsicContentSize.height)
        return max(26, first + 4 + PiKit.Line("Ag", font: metaFont, color: .black).lineHeight)
    }()

    init(row: BackgroundRequestRow, minute: Date, openSource: @escaping () -> Void) {
        self.row = row; self.minute = minute; self.openSource = openSource
        icon = PiKit.IconBadge(symbol: row.kind.symbol, tone: .accent, size: 26)
        super.init(frame: .zero)
        headline.truncation = .end
        meta.owner = self
        for view in [icon, kind, headline, duration, badge, meta] as [NSView] { addSubview(view) }
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(row: BackgroundRequestRow, minute: Date) {
        guard row != self.row || minute != self.minute else { return }
        if row.kind != self.row.kind { icon.removeFromSuperview(); icon = PiKit.IconBadge(symbol: row.kind.symbol, tone: .accent, size: 26); addSubview(icon) }
        self.row = row; self.minute = minute
        apply()
    }
    /// The line the row leads with: the result, or what stands in its place.
    private var lead: (text: String, color: NSColor) {
        switch row.status {
        case .running: return ("Waiting for the mini model…", .piInkSecondary)
        case .completed: return row.resultLine.map { ($0, NSColor.piInk) } ?? ("No result was kept", .piInkSecondary)
        case .failed(let why): return (why, .piDanger)
        case .interrupted(let why): return (row.resultLine ?? why, .piInkSecondary)
        }
    }
    /// What the row says, for VoiceOver: its words and its drawn metadata.
    var spoken: String {
        ([row.kind.label, lead.text, duration.isHidden ? nil : duration.line.text, row.status.label] + [meta.spoken]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private func apply() {
        kind.line.text = row.kind.label
        let lead = self.lead
        headline.line = PiKit.Line(lead.text, font: PiKit.Font.body, color: lead.color)
        headline.toolTip = row.result ?? row.status.reason ?? ""
        duration.line.text = row.durationMs.map { TranscriptActivity.formatDuration($0) } ?? ""
        duration.isHidden = row.durationMs == nil
        duration.toolTip = "From sent to answered"
        styleBackgroundRequestBadge(badge, row.status)
        meta.apply()
        for view in [kind, headline, duration, badge] as [NSView] { view.invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let scale = piScale, width = bounds.width
        icon.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        let x = 26 + PiSpacing.md, inner = max(0, width - x)
        let b = badge.intrinsicContentSize, k = kind.intrinsicContentSize, h = headline.intrinsicContentSize, d = duration.intrinsicContentSize
        let first = max(h.height, b.height, k.height)
        func centred(_ view: NSView, _ size: CGSize, _ left: CGFloat, _ w: CGFloat) {
            view.frame = CGRect(x: left, y: PiKit.round((first - size.height) / 2, scale), width: w, height: size.height)
        }
        var right = width - b.width
        centred(badge, b, right, b.width)
        if !duration.isHidden { right -= PiSpacing.sm + d.width; centred(duration, d, right, d.width) }
        centred(kind, k, x, k.width)
        let headX = x + k.width + PiSpacing.sm
        // HStack's spacer keeps its 8 points plus a gap on each side.
        centred(headline, h, headX, max(0, min(h.width, right - 3 * PiSpacing.sm - headX)))
        meta.frame = CGRect(x: x, y: first + 4, width: inner, height: PiKit.Line("Ag", font: Self.metaFont, color: .black).lineHeight)
    }

    /// When, for which chat and project, on which connection and model, and
    /// what it cost. A narrow row leaves out the connection, then the
    /// project, then the model, whole: never half of each.
    final class Metadata: DashView, NSViewToolTipOwner {
        weak var owner: BackgroundRequestRowContent?
        /// The help for each drawn part, by where it is drawn.
        private var tips: [(rect: CGRect, text: String)] = []
        /// The drawn words, for the row's VoiceOver name.
        var spoken: String {
            guard owner != nil else { return "" }
            return (context(project: true, connection: true, model: true) + trailing).map(\.0).filter { $0 != "·" }.joined(separator: ", ")
        }
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
            tips.first { $0.rect.contains(point) }?.text ?? ""
        }
        /// The help a drawn part carries (`.help`): the date in full, the model's name, the exact tokens and cost.
        private func help(for text: String) -> String? {
            guard let row = owner?.row else { return nil }
            if let started = row.startedAt, text == ChatRowStats.relative(started, now: owner!.minute) { return started.formatted(date: .complete, time: .standard) }
            if let model = row.model, text == model { return model }
            if let totals = row.totals {
                if let tokens = totals.billedTotalTokens, text == compactTokens(tokens) + " tok" {
                    return "Input \(menuBarTokens(totals.tokens?.input)) · output \(menuBarTokens(totals.tokens?.output)) tokens, as the gateway reported them"
                }
                if totals.costSamples > 0, text == compactGatewayUSD(totals.costUSD) { return gatewayUSD(totals.costUSD) }
            }
            return nil
        }
        private let source = PlainTextButton("", font: BackgroundRequestRowContent.metaFont, color: .piAccent)
        private var parts: [(text: String, color: NSColor, help: String?)] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            source.onPress = { [weak self] in self?.owner?.openSource() }
            addSubview(source)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func line(_ text: String, _ color: NSColor) -> PiKit.Line { PiKit.Line(text, font: BackgroundRequestRowContent.metaFont, color: color) }
        func apply() {
            guard let row = owner?.row else { return }
            source.line = line(row.sourceTitle ?? "", .piAccent)
            source.toolTip = row.sourceTitle.map { "Open “\($0)”" }
            source.setAccessibilityIdentifier("backgroundRequestSource-" + row.id)
            needsLayout = true; needsDisplay = true
        }
        /// The leading words, as the form chosen draws them: (text, colour, the source title's place).
        private func context(project: Bool, connection: Bool, model: Bool) -> [(String, NSColor)] {
            guard let owner else { return [] }
            let row = owner.row
            var parts: [(String, NSColor)] = []
            if let started = row.startedAt { parts.append((ChatRowStats.relative(started, now: owner.minute), .piInkSecondary)); parts.append(("·", .piInkTertiary)) }
            parts.append((row.sourceTitle ?? "Deleted chat", row.sourceTitle == nil ? .piInkTertiary : .piAccent))
            if project, let name = row.project { parts += [("·", .piInkTertiary), (name, .piInkSecondary)] }
            if connection, let name = row.connection { parts += [("·", .piInkTertiary), (name, .piInkSecondary)] }
            if model, let name = row.model { parts += [("·", .piInkTertiary), (name, .piInkSecondary)] }
            return parts
        }
        private func width(_ parts: [(String, NSColor)]) -> CGFloat {
            let scale = piScale
            return parts.reduce(0) { $0 + line($1.0, $1.1).size(scale: scale).width } + CGFloat(max(0, parts.count - 1)) * 5
        }
        /// The tokens and the cost at the trailing edge.
        private var trailing: [(String, NSColor)] {
            guard let totals = owner?.row.totals else { return [] }
            var parts: [(String, NSColor)] = []
            if let tokens = totals.billedTotalTokens { parts.append((compactTokens(tokens) + " tok", .piInkSecondary)) }
            if totals.costSamples > 0 {
                if totals.billedTotalTokens != nil { parts.append(("·", .piInkTertiary)) }
                parts.append((compactGatewayUSD(totals.costUSD), .piInkSecondary))
            }
            return parts
        }
        /// The first form that fits whole (`ViewThatFits`); the last fits by cutting the chat's title.
        private func chosen(room: CGFloat) -> (parts: [(String, NSColor)], whole: Bool) {
            for (project, connection, model) in [(true, true, true), (true, false, true), (false, false, true)] {
                let parts = context(project: project, connection: connection, model: model)
                if width(parts) <= room { return (parts, true) }
            }
            return (context(project: false, connection: false, model: false), false)
        }
        /// What is drawn where, worked out in layout.
        private var plan: [(line: PiKit.Line, frame: CGRect)] = []
        override func layout() {
            super.layout()
            guard let owner else { return }
            let scale = piScale
            plan = []
            let tail = trailing
            let tailWidth = width(tail)
            var x = bounds.width - tailWidth
            for (text, color) in tail {
                let drawn = line(text, color), w = drawn.size(scale: scale).width
                plan.append((drawn, CGRect(x: x, y: 0, width: w, height: drawn.lineHeight)))
                x += w + 5
            }
            // The room left of the spacer's 8 and the spacing either side of it.
            let room = bounds.width - (tail.isEmpty ? 5 + 8 : tailWidth + 5 + 8 + 5)
            let (parts, whole) = chosen(room: room)
            let title = titleIndex(parts)
            let others = parts.enumerated().filter { $0.offset != title }.reduce(0) { $0 + line($1.element.0, $1.element.1).size(scale: scale).width }
                + CGFloat(max(0, parts.count - 1)) * 5
            x = 0
            source.isHidden = true
            for (index, part) in parts.enumerated() {
                let drawn = line(part.0, part.1)
                var w = drawn.size(scale: scale).width
                if index == title, !whole { w = max(0, min(w, room - others)) }
                let frame = CGRect(x: x, y: 0, width: w, height: drawn.lineHeight)
                if index == title, owner.row.sourceTitle != nil { source.frame = frame; source.isHidden = false }
                else { plan.append((drawn, frame)) }
                x += w + 5
            }
            removeAllToolTips()
            tips = plan.compactMap { item in help(for: item.line.text).map { (item.frame, $0) } }
            for tip in tips { addToolTip(tip.rect, owner: self, userData: nil) }
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let scale = piScale
            for (drawn, frame) in plan { drawn.draw(in: frame, scale: scale) }
        }
        private func titleIndex(_ parts: [(String, NSColor)]) -> Int { owner?.row.startedAt == nil ? 0 : 2 }
    }
}

/// The selected request: how it stands, what it produced, where it came
/// from and what it cost, what it sent and got back, and the ways further in.
@MainActor final class BackgroundRequestDetailPane: DashView {
    private(set) var row: BackgroundRequestRow
    private var detail: BackgroundRequestDetail?
    private var loading: Bool
    private let openSource: (String) -> Void
    private let inspect: (String) -> Void
    private let close: () -> Void
    private let scroll = NSScrollView()
    private let column = ShellStack(.vertical, spacing: PiSpacing.lg, padding: NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg))
    private let document = FlippedColumn()

    init(row: BackgroundRequestRow, detail: BackgroundRequestDetail?, loading: Bool,
         openSource: @escaping (String) -> Void, inspect: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.row = row; self.detail = detail; self.loading = loading
        self.openSource = openSource; self.inspect = inspect; self.close = close
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.column = column
        document.addSubview(column)
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Background request details")
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func update(row: BackgroundRequestRow, detail: BackgroundRequestDetail?, loading: Bool) {
        guard row != self.row || detail != self.detail || loading != self.loading else { return }
        self.row = row; self.detail = detail; self.loading = loading
        rebuild()
    }
    /// Each part is made again only when what it shows changed, so a
    /// selection in the result, the keyboard on a button or the scroll stays
    /// when the journal's read lands or the record is written again.
    private var parts: [String: (state: AnyHashable, view: NSView)] = [:]
    /// The header stays (and the keyboard on its close button) while its badge changes.
    private var header: BackgroundRequestDetailHeader?
    private func part(_ name: String, _ state: AnyHashable, make: () -> NSView?) -> NSView? {
        if let kept = parts[name], kept.state == state { return kept.view }
        guard let view = make() else { parts[name] = nil; return nil }
        parts[name] = (state, view)
        return view
    }
    private func rebuild() {
        var views: [NSView?] = []
        if header == nil {
            header = BackgroundRequestDetailHeader(close: { [weak self] in self?.close() })
        }
        header?.update(row)
        views.append(header)
        views.append(part("result", row.result ?? "\u{0}") {
            row.result.map { result in
                let text = ShellSelectableText(result, font: PiKit.Font.body, color: .piInk)
                text.setAccessibilityIdentifier("backgroundRequestResult")
                return sunken(text)
            }
        })
        views.append(part("reason", [row.status.reason ?? "\u{0}", row.status.label] as [String]) {
            row.status.reason.map { reason in PiKit.Note(reason, tone: row.status == .failed(reason) ? .danger : .neutral) }
        })
        views.append(part("actions", [row.id, "\(row.sourceTitle != nil)"] as [String]) {
            BackgroundRequestActions(row: row, openSource: { [weak self] in guard let self else { return }; self.openSource(self.row.id) },
                                     inspect: { [weak self] in guard let self else { return }; self.inspect(self.row.id) })
        })
        views.append(part("facts", factsState) { facts() })
        views.append(part("exchange", ExchangeState(loading: loading, detail: loading ? nil : detail, running: row.status == .running)) { exchange() })
        let items = views.compactMap { $0 }.map { ShellItem.view($0, .fill) }
        if items.map(\.view) != column.items.map(\.view) { column.items = items }
        column.relayoutAll()
        needsLayout = true
    }
    private struct ExchangeState: Hashable { let loading: Bool; let detail: BackgroundRequestDetail?; let running: Bool }
    private var factsState: [String] {
        [row.sourceTitle ?? "\u{0}", row.project ?? "\u{0}", row.connection ?? "\u{0}", row.model ?? "\u{0}",
         row.endedAt.map { "\($0.timeIntervalSince1970)" } ?? "", row.durationMs.map { "\($0)" } ?? "", "\(String(describing: row.totals))"]
    }
    private func sunken(_ content: NSView) -> NSView {
        PiKit.inset(PaddedView(content, padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md)), sunken: true)
    }
    private func facts() -> NSView {
        var rows: [ShellItem] = []
        func add(_ key: String, _ value: String, mono: Bool = false) { rows.append(.view(PiKit.KeyValue(key: key, value: value, mono: mono), .fill)) }
        add("Chat", row.sourceTitle ?? "Deleted chat")
        if let project = row.project { add("Project", project) }
        add("Connection", row.connection ?? "Deleted connection")
        if let model = row.model { add("Model", model, mono: true) }
        if let ended = row.endedAt { add("Ended", ended.formatted(date: .abbreviated, time: .standard)) }
        if let duration = row.durationMs { add("Duration", TranscriptActivity.formatDuration(duration)) }
        if let totals = row.totals, totals.requests > 0 {
            add("Tokens", totals.billedTotalTokens == nil ? "Not reported" : "in \(menuBarTokens(totals.tokens?.input)) · out \(menuBarTokens(totals.tokens?.output))")
            add("Cost", totals.costSamples > 0 ? gatewayUSD(totals.costUSD) : "Not reported")
            add("Requests", "\(totals.requests)")
        } else {
            add("Usage", "Nothing captured for this request")
        }
        return ShellStack(.vertical, spacing: 6, rows)
    }
    private func exchange() -> NSView? {
        if loading {
            return ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .center, [
                .view(piSpinner(size: 12)), .view(PiKit.TextLine(PiKit.Line("Reading the request's journal…", font: PiKit.Font.caption, color: .piInkSecondary)))])
        }
        guard let detail else { return nil }
        var items: [ShellItem] = []
        if let unavailable = detail.unavailable { items.append(.view(PiKit.Note(unavailable), .fill)) }
        if let prompt = detail.prompt { items.append(.view(section("Prompt sent", text: prompt, identifier: "backgroundRequestPrompt"), .fill)) }
        if let reply = detail.reply { items.append(.view(section("Reply", text: reply, identifier: "backgroundRequestReply"), .fill)) }
        else if detail.prompt != nil, row.status == .running { items.append(.view(PiKit.Note("The reply has not come yet."), .fill)) }
        return items.isEmpty ? nil : ShellStack(.vertical, spacing: PiSpacing.lg, items)
    }
    private func section(_ title: String, text: String, identifier: String) -> NSView {
        let heading = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
        let body = ShellSelectableText(text, font: PiKit.Font.mono, color: .piInk)
        body.setAccessibilityIdentifier(identifier)
        return ShellStack(.vertical, spacing: 6, [.view(heading), .view(sunken(body), .fill)])
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        document.fit(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
    }

    /// The pane's document: the column at the pane's width, as tall as it needs.
    final class FlippedColumn: DashView, PiKit.SizeObserver {
        weak var column: NSView?
        func contentSizeChanged() { enclosingScrollView?.superview?.needsLayout = true }
        func fit(width: CGFloat, minimumHeight: CGFloat) {
            guard let column else { return }
            let height = PiKit.height(of: column, width: width)
            let size = NSSize(width: width, height: max(height, minimumHeight))
            if frame.size != size { setFrameSize(size) }
            column.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }
}

/// Open Source Chat and Inspect Requests: side by side when they fit, else
/// one under the other (`ViewThatFits`).
@MainActor final class BackgroundRequestActions: DashView, PiKit.WidthSizing {
    private let open: PiKit.Button
    private let inspect: PiKit.Button
    init(row: BackgroundRequestRow, openSource: @escaping () -> Void, inspect: @escaping () -> Void) {
        open = PiKit.Button("Open Source Chat", symbol: "bubble.left", style: .secondary, compact: true, action: openSource)
        open.isEnabled = row.sourceTitle != nil
        open.setAccessibilityIdentifier("backgroundRequestOpenSource")
        self.inspect = PiKit.Button("Inspect Requests", symbol: "ladybug", style: .secondary, compact: true, action: inspect)
        self.inspect.toolTip = "The Session Inspector: this request's captured bodies, usage and timing"
        self.inspect.setAccessibilityIdentifier("backgroundRequestInspect")
        super.init(frame: .zero)
        addSubview(open); addSubview(self.inspect)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func fits(_ width: CGFloat) -> Bool { open.intrinsicContentSize.width + PiSpacing.sm + inspect.intrinsicContentSize.width <= width }
    func height(forWidth width: CGFloat) -> CGFloat {
        let a = open.intrinsicContentSize.height, b = inspect.intrinsicContentSize.height
        return fits(width) ? max(a, b) : a + PiSpacing.sm + b
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() {
        super.layout()
        let a = open.intrinsicContentSize, b = inspect.intrinsicContentSize
        if fits(bounds.width) {
            let h = max(a.height, b.height)
            open.frame = CGRect(x: 0, y: PiKit.round((h - a.height) / 2, piScale), width: a.width, height: a.height)
            inspect.frame = CGRect(x: a.width + PiSpacing.sm, y: PiKit.round((h - b.height) / 2, piScale), width: b.width, height: b.height)
        } else {
            open.frame = CGRect(x: 0, y: 0, width: a.width, height: a.height)
            inspect.frame = CGRect(x: 0, y: a.height + PiSpacing.sm, width: b.width, height: b.height)
        }
    }
}

/// The selected request's header: its kind's badge, its name and when it
/// started, how it stands, and the close button; updated in place.
@MainActor final class BackgroundRequestDetailHeader: DashView, PiKit.WidthSizing {
    private var kind: BackgroundRequestKind?
    private var icon: PiKit.IconBadge?
    private let name = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.heading, color: .piInk))
    private let date = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let badge = PiKit.Badge(text: "")
    private let closeButton: PiKit.IconButton
    init(close: @escaping () -> Void) {
        closeButton = PiKit.IconButton(symbol: "xmark", label: "Close the details", size: 24, action: close)
        super.init(frame: .zero)
        for view in [name, date, badge, closeButton] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(_ row: BackgroundRequestRow) {
        if row.kind != kind {
            kind = row.kind
            icon?.removeFromSuperview()
            let made = PiKit.IconBadge(symbol: row.kind.symbol, tone: .accent, size: 28)
            addSubview(made); icon = made
        }
        name.line.text = row.kind.label
        date.isHidden = row.startedAt == nil
        date.line.text = row.startedAt?.formatted(date: .abbreviated, time: .standard) ?? ""
        styleBackgroundRequestBadge(badge, row.status)
        for view in [name, date, badge] as [NSView] { view.invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    private var textHeight: CGFloat { name.intrinsicContentSize.height + (date.isHidden ? 0 : 1 + date.intrinsicContentSize.height) }
    func height(forWidth width: CGFloat) -> CGFloat { max(28, textHeight, badge.intrinsicContentSize.height, 24) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func layout() {
        super.layout()
        let scale = piScale, h = bounds.height
        func centre(_ view: NSView, x: CGFloat, size: CGSize) { view.frame = CGRect(x: x, y: PiKit.round((h - size.height) / 2, scale), width: size.width, height: size.height) }
        icon.map { centre($0, x: 0, size: CGSize(width: 28, height: 28)) }
        var right = bounds.width - 24
        centre(closeButton, x: right, size: CGSize(width: 24, height: 24))
        let b = badge.intrinsicContentSize
        right -= PiSpacing.sm + b.width
        centre(badge, x: right, size: b)
        let x = 28 + PiSpacing.sm, room = max(0, right - PiSpacing.sm - x)
        let top = PiKit.round((h - textHeight) / 2, scale)
        let n = name.intrinsicContentSize
        name.frame = CGRect(x: x, y: top, width: min(n.width, room), height: n.height)
        let d = date.intrinsicContentSize
        date.frame = CGRect(x: x, y: top + n.height + 1, width: min(d.width, room), height: d.height)
    }
}
