import AppKit

/// Native Inspector chrome and lazy navigator around a stable current page.
@MainActor final class SessionInspectorView: DashView {
    let inspector: SessionInspectorModel
    static let compactWidth: CGFloat = 900
    private let topInset: CGFloat
    private let bar = PiWindowBarView(frame: .zero)
    private let title = inspectorText("Session Inspector", font: PiKit.Font.title(14))
    private let sessionTitle: ShellText
    private let refreshButton: PiKit.IconButton
    private let navigator: InspectorNavigator
    private var pageView: NSView?
    private var notice: NSView?
    private var shownPage: InspectorPage?
    private var isCompact = false
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    init(inspector: SessionInspectorModel, topInset: CGFloat = 0) {
        self.inspector = inspector
        self.topInset = topInset
        sessionTitle = inspectorText(inspector.title, color: .piInkSecondary); sessionTitle.truncation = .middle
        refreshButton = PiKit.IconButton(symbol: "arrow.clockwise", label: "Read this session's requests again", size: 24) { [weak inspector] in inspector?.refresh() }
        navigator = InspectorNavigator(inspector: inspector)
        super.init(frame: .zero)
        shellAdd([bar, title, sessionTitle, refreshButton, navigator])
        refreshButton.setAccessibilityIdentifier("inspector-refresh"); setAccessibilityIdentifier("session-inspector")
        observer.observe(inspector); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        sessionTitle.set(inspector.title, color: .piInkSecondary)
        notice?.removeFromSuperview(); notice = nil
        if let message = inspector.focusNotice ?? inspector.failure { notice = InspectorInset(InspectorBanner(symbol: "exclamationmark.circle", text: message, tone: .warning), insets: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.xl, bottom: 0, right: PiSpacing.xl)); addSubview(notice!) }
        switch inspector.page {
        case .overview:
            if !(pageView is InspectorOverviewPage) { install(InspectorOverviewPage(inspector: inspector, compact: isCompact)) }
        case .nextRequest:
            if !(pageView is InspectorNextRequestPage) { install(InspectorNextRequestPage(inspector: inspector, next: inspector.next, compact: isCompact)) }
        case .turn(let id):
            if let view = pageView as? InspectorTurnPage { view.turnID = id }
            else { install(InspectorTurnPage(inspector: inspector, turnID: id, compact: isCompact)) }
        case .request:
            if !(pageView is InspectorRequestPage) { install(InspectorRequestPage(inspector: inspector, request: inspector.request, compact: isCompact)) }
        }
        shownPage = inspector.page; needsLayout = true
    }
    private func install(_ page: NSView) { pageView?.removeFromSuperview(); pageView = page; addSubview(page) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "[": inspector.step(-1); return true
        case "]": inspector.step(1); return true
        case "f":
            if case .request = inspector.page {} else if let latest = inspector.index.latestRequestID { inspector.select(.request(latest)) }
            inspector.request.tab = .raw; inspector.request.searchFocus &+= 1; return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func layout() {
        super.layout()
        let compact = bounds.width < Self.compactWidth
        if compact != isCompact {
            isCompact = compact
            (pageView as? InspectorOverviewPage)?.compact = compact
            (pageView as? InspectorNextRequestPage)?.compact = compact
            (pageView as? InspectorTurnPage)?.compact = compact
            (pageView as? InspectorRequestPage)?.compact = compact
        }
        bar.frame = CGRect(x: 0, y: topInset, width: bounds.width, height: 48)
        refreshButton.frame = CGRect(x: max(0, bounds.width - PiSpacing.md - 24), y: topInset + 12, width: 24, height: 24)
        let width = max(0, refreshButton.frame.minX - 8 - PiKit.Sheet.trafficLightInset)
        let top = PiKit.round((48 - title.intrinsicContentSize.height - 1 - sessionTitle.intrinsicContentSize.height) / 2, piScale)
        title.frame = CGRect(x: PiKit.Sheet.trafficLightInset, y: topInset + top, width: width, height: title.intrinsicContentSize.height)
        sessionTitle.frame = CGRect(x: PiKit.Sheet.trafficLightInset, y: title.frame.maxY + 1, width: width, height: sessionTitle.intrinsicContentSize.height)
        let navWidth: CGFloat = compact ? 214 : 262
        let bodyTop = topInset + 49
        navigator.frame = CGRect(x: 0, y: bodyTop, width: navWidth, height: max(0, bounds.height - bodyTop))
        let pageX = navWidth + 1, pageWidth = max(0, bounds.width - pageX)
        var y = bodyTop
        if let notice { let height = PiKit.height(of: notice, width: pageWidth); notice.frame = CGRect(x: pageX, y: y, width: pageWidth, height: height); y += height }
        pageView?.frame = CGRect(x: pageX, y: y, width: pageWidth, height: max(0, bounds.height - y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.piContent.setFill(); bounds.fill()
        NSColor.piWindow.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: topInset + 48).fill()
        let navWidth: CGFloat = isCompact ? 214 : 262
        let bodyTop = topInset + 49
        CGRect(x: 0, y: bodyTop, width: navWidth, height: max(0, bounds.height - bodyTop)).fill()
        NSColor.piHairline.setFill(); CGRect(x: 0, y: topInset + 48, width: bounds.width, height: 1).fill(); CGRect(x: navWidth, y: bodyTop, width: 1, height: max(0, bounds.height - bodyTop)).fill()
    }
}

/// Only visible rows are built. Each descriptor is prepared from typed index
/// rows: navigating or folding this list never reads a body or metadata blob.
@MainActor final class InspectorNavigator: DashView {
    let inspector: SessionInspectorModel
    let list = LazyStackView()
    private let glide = PiKit.SelectionGlide()
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private var rows: [Descriptor] = []
    private var lastPage: InspectorPage?
    enum Descriptor: Equatable {
        case overview(String, Bool), next(Bool), section(Bool), message(String)
        case turn(InspectorTurn, String?, Bool, Bool)
        case version(InspectorTurn, String?, Bool)
        case compaction(InspectorCompaction, CGFloat, Bool, Bool)
        case request(InspectorRequestRow, Int, String, CGFloat, Bool)
        var key: String {
            switch self { case .overview: return "overview"; case .next: return "next"; case .section: return "section"; case .message(let text): return "message:" + text; case .turn(let turn, _, _, _), .version(let turn, _, _): return turn.id; case .compaction(let group, _, _, _): return group.id; case .request(let row, _, _, _, _): return row.id }
        }
        var height: CGFloat { switch self { case .overview, .next: return 46; case .turn: return 44; case .version: return 36; case .section: return 31; case .message(let text): return text.contains("older requests") ? 29 : 30; default: return 30 } }
        var selected: Bool {
            switch self { case .overview(_, let selected), .next(let selected), .turn(_, _, _, let selected), .version(_, _, let selected), .request(_, _, _, _, let selected): return selected; case .compaction(_, _, let expanded, let selected): return selected && !expanded; default: return false }
        }
        /// Selection and disclosure changes update the mounted controls.
        var contentIdentity: Descriptor {
            switch self { case .overview(let text, _): return .overview(text, false); case .next: return .next(false); case .turn(let turn, let prompt, _, _): return .turn(turn, prompt, false, false); case .version(let turn, let prompt, _): return .version(turn, prompt, false); case .compaction(let group, let indent, _, _): return .compaction(group, indent, false, false); case .request(let row, let number, let kind, let indent, _): return .request(row, number, kind, indent, false); default: return self }
        }
        func canReuse(_ next: Descriptor) -> Bool {
            if case .turn(let turn, _, _, _) = self, case .turn(let following, _, _, _) = next { return turn.id == following.id }
            return contentIdentity == next.contentIdentity
        }
    }
    init(inspector: SessionInspectorModel) {
        self.inspector = inspector; super.init(frame: .zero); addSubview(list)
        list.spacing = 1; list.insets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        list.setAccessibilityIdentifier("inspector-navigator"); observer.observe(inspector); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let requests = inspector.index.requests.filter { $0.source != .record }.count, turns = inspector.index.turns.filter { !$0.isOther }.count
        let subtitle = requests > 0 ? "\(turns) turn" + (turns == 1 ? "" : "s") + " · \(requests) request" + (requests == 1 ? "" : "s") : "Cost, tokens and time"
        var built: [Descriptor] = [.overview(subtitle, inspector.page == .overview), .next(inspector.page == .nextRequest), .section(inspector.indexLoaded && inspector.index.turns.contains(where: \.running))]
        if inspector.index.isEmpty { built.append(.message(inspector.indexLoaded ? "No requests yet" : "Reading requests…")) }
        func entries(_ entries: [InspectorTurn.Entry], indent: CGFloat) {
            for entry in entries {
                switch entry {
                case .request(let row, let number): built.append(.request(row, number, inspector.index.kind(of: row.id), indent, inspector.page == .request(row.id)))
                case .compaction(let group):
                    let expanded = inspector.expanded.contains(group.id)
                    built.append(.compaction(group, indent, expanded, group.requests.contains { inspector.page == .request($0.id) }))
                    if expanded { for (offset, row) in group.requests.enumerated() { built.append(.request(row, group.first + offset, inspector.summaryLabel(row.id) ?? "summary request \(offset + 1)", indent + 16, inspector.page == .request(row.id))) } }
                }
            }
        }
        for turn in inspector.index.turns {
            let expanded = inspector.expanded.contains(turn.id)
            built.append(.turn(turn, inspector.prompts[turn.id], expanded, inspector.page == .turn(turn.id)))
            if expanded {
                entries(turn.entries, indent: 26)
                for version in turn.earlier { built.append(.version(version, inspector.prompts[version.id], inspector.page == .turn(version.id))); entries(version.entries, indent: 40) }
            }
        }
        if inspector.index.olderRequests > 0 { built.append(.message("\(inspector.index.olderRequests) older requests are not listed")) }
        let previousKeys = rows.map(\.key); rows = built
        let source = LazyStackView.Source(count: built.count, key: { built[$0].key }, height: { index, _ in built[index].height }, view: { [weak self] index, existing in
            guard let self else { return NSView() }
            let descriptor = built[index]
            if let existing = existing as? Holder, existing.descriptor.canReuse(descriptor) {
                existing.update(descriptor); return existing
            }
            return Holder(descriptor: descriptor, content: self.make(descriptor))
        })
        if previousKeys == built.map(\.key) { list.update(source) } else { list.reload(source) }
        if lastPage != inspector.page {
            lastPage = inspector.page
            let target: String
            switch inspector.page { case .overview: target = "overview"; case .nextRequest: target = "next"; case .turn(let id), .request(let id): target = id }
            DispatchQueue.main.async { [weak self] in guard let self, let index = self.rows.firstIndex(where: { $0.key == target }) else { return }; self.list.scrollToRow(index) }
        }
    }
    private func make(_ descriptor: Descriptor) -> NSView {
        switch descriptor {
        case .overview(let subtitle, let selected): return navigation(symbol: "chart.bar.xaxis", title: "Overview", subtitle: subtitle, selected: selected) { [weak inspector] in inspector?.select(.overview) }
        case .next(let selected): return navigation(symbol: "square.stack.3d.up", title: "Next request", subtitle: "What the model receives next", selected: selected) { [weak inspector] in inspector?.select(.nextRequest) }
        case .section(let running):
            var items: [ShellItem] = [.view(PiKit.TextLine(PiKit.Line("TURNS", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.6))), .spacer(0)]
            if running { items.append(.view(PiKit.ShimmerText("running", size: 10))) }
            let row = inspectorRow(items); row.padding = NSEdgeInsets(top: 14, left: 12, bottom: 4, right: 12); row.setAccessibilityRoleDescription("heading"); return row
        case .message(let text): return InspectorInset(inspectorText(text, font: text.contains("older requests") ? PiKit.Font.micro : PiKit.Font.caption, color: .piInkTertiary), insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        case .turn(let turn, let prompt, let expanded, let selected):
            return InspectorTurnNavRow(inspector: inspector, turn: turn, prompt: prompt, expanded: expanded, selected: selected, glide: glide)
        case .version(let version, let prompt, let selected):
            let label = version.version.map { "Version \($0.index) of \($0.count)" } ?? "Earlier version"
            let line = [Self.firstLine(prompt), version.summary].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            let face = inspectorRow([.view(InspectorFixedSize(PiKit.SymbolView(PiKit.Symbol("clock.arrow.circlepath", size: 10.5, weight: .medium), color: selected ? .piAccent : .piInkTertiary), width: 16, height: 14)), .view(inspectorColumn([inspectorText(label, font: .systemFont(ofSize: 12, weight: .medium)), inspectorText(line, font: PiKit.Font.micro, color: .piInkTertiary)], spacing: 1), .flexible), .spacer(0)], spacing: 7)
            let row = PiKit.SelectableRow(content: face, selected: selected, glide: glide) { [weak inspector] in inspector?.select(.turn(version.id)) }; row.setAccessibilityIdentifier("inspector-version-row"); row.setAccessibilityLabel("Earlier version: " + label + (line.isEmpty ? "" : ", " + line)); return InspectorInset(row, insets: NSEdgeInsets(top: 0, left: 26, bottom: 0, right: 0))
        case .compaction(let group, let indent, let expanded, let selected):
            let cost = group.requests.compactMap(\.cost)
            let face = InspectorCompactLine(symbol: "arrow.down.right.and.arrow.up.left", number: nil, kind: group.title, model: nil, flow: cost.isEmpty ? nil : compactGatewayUSD(cost.reduce(0, +)), kindColor: .piInk, symbolColor: group.requests.contains(where: \.failed) ? .piDanger : .piInkSecondary)
            let row = PiKit.SelectableRow(content: face, selected: selected && !expanded, glide: glide) { [weak inspector] in if let first = group.requests.first { inspector?.select(.request(first.id)) } }
            row.setAccessibilityIdentifier("inspector-compaction-open")
            row.setAccessibilityLabel(group.title + (cost.isEmpty ? "" : ", " + compactGatewayUSD(cost.reduce(0, +))))
            let toggle = InspectorDisclosure(expanded: expanded, symbolSize: 8.5, width: 16, height: 30, label: expanded ? "Hide this compaction's requests" : "Show this compaction's requests") { [weak inspector] in inspector?.toggle(group.id) }
            let content = inspectorRow([.view(toggle, .fixed(16)), .view(row, .fill)], spacing: 0); content.setAccessibilityIdentifier("inspector-compaction-row"); content.setAccessibilityLabel(group.title); return InspectorInset(content, insets: NSEdgeInsets(top: 0, left: indent - 16, bottom: 0, right: 0))
        case .request(let request, let number, let kind, let indent, let selected):
            let model = request.model ?? request.alias ?? ""
            let face = InspectorCompactLine(symbol: nil, number: number, kind: kind, model: model, flow: request.tokenFlow, kindColor: request.source == .record ? .piInkTertiary : .piInk, symbolColor: .piInkTertiary, outcome: request.outcome)
            let row = PiKit.SelectableRow(content: face, selected: selected, glide: glide) { [weak inspector] in inspector?.select(.request(request.id)) }
            row.toolTip = model.isEmpty ? kind : kind + " · " + model
            row.setAccessibilityIdentifier("inspector-request-row"); row.setAccessibilityLabel("Request \(number), \(kind), " + (model.isEmpty ? "model unreported" : model) + (request.tokenFlow.map { ", " + $0 } ?? ""))
            return InspectorInset(row, insets: NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0))
        }
    }
    fileprivate static func firstLine(_ prompt: String?) -> String? { prompt.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) }?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
    private func navigation(symbol: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> NSView {
        let face = inspectorRow([.view(InspectorNavIcon(symbol: symbol, selected: selected)), .view(inspectorColumn([inspectorText(title, font: .systemFont(ofSize: 13, weight: .semibold)), inspectorText(subtitle, color: .piInkTertiary)], spacing: 1), .flexible), .spacer(0)], spacing: 10)
        let row = PiKit.SelectableRow(content: face, selected: selected, glide: glide, action: action); row.setAccessibilityLabel(title + ", " + subtitle); return row
    }
    override func layout() { super.layout(); list.frame = bounds }
    final class Holder: DashView {
        private(set) var descriptor: Descriptor
        let content: NSView
        init(descriptor: Descriptor, content: NSView) { self.descriptor = descriptor; self.content = content; super.init(frame: .zero); addSubview(content) }
        required init?(coder: NSCoder) { nil }
        func update(_ descriptor: Descriptor) {
            guard self.descriptor != descriptor else { return }
            self.descriptor = descriptor
            if case .turn(let turn, let prompt, let expanded, let selected) = descriptor {
                (content as? InspectorTurnNavRow)?.update(turn: turn, prompt: prompt, expanded: expanded, selected: selected)
            }
            func update(_ view: NSView) {
                (view as? PiKit.SelectableRow)?.selected = descriptor.selected
                (view as? InspectorTurnNumber)?.selected = descriptor.selected
                (view as? InspectorNavIcon)?.selected = descriptor.selected
                if let disclosure = view as? InspectorDisclosure {
                    switch descriptor {
                    case .turn(_, _, let expanded, _): disclosure.update(expanded: expanded, label: expanded ? "Hide this turn's requests" : "Show this turn's requests")
                    case .compaction(_, _, let expanded, _): disclosure.update(expanded: expanded, label: expanded ? "Hide this compaction's requests" : "Show this compaction's requests")
                    default: break
                    }
                }
                for child in view.subviews { update(child) }
            }
            update(content)
        }
        override func layout() {
            super.layout()
            // Fixed row wrappers centre their label's natural height; the
            // background and text can extend half a point beyond the row.
            let height = PiKit.height(of: content, width: bounds.width)
            content.frame = CGRect(x: 0, y: PiKit.round((bounds.height - height) / 2, piScale), width: bounds.width, height: height)
        }
    }
}

/// Prompts and request metrics arrive independently of selection. Keeping
/// these controls mounted lets a focused disclosure survive both updates.
@MainActor private final class InspectorTurnNavRow: DashView, PiKit.WidthSizing {
    private let heading: ShellText
    private let detail: ShellText
    private let running: InspectorStatusMark
    private let detailLine: ShellStack
    private let number: InspectorTurnNumber
    private let disclosure: InspectorDisclosure
    private let selectedRow: PiKit.SelectableRow
    private let row: ShellStack
    init(inspector: SessionInspectorModel, turn: InspectorTurn, prompt: String?, expanded: Bool, selected: Bool, glide: PiKit.SelectionGlide) {
        let id = turn.id
        let heading = inspectorText("", font: .systemFont(ofSize: 12.5, weight: .medium)); self.heading = heading
        let detail = inspectorText("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary); self.detail = detail
        let running = InspectorStatusMark(outcome: "running"); self.running = running
        let number = InspectorTurnNumber(turn.isOther ? "·" : "\(turn.number)", selected: selected); self.number = number
        let detailLine = inspectorRow([.view(running), .view(detail, .flexible)], spacing: 5); self.detailLine = detailLine
        let labels = inspectorColumn([heading, detailLine], spacing: 1)
        let face = inspectorRow([.view(number), .view(labels, .flexible), .spacer(0)], spacing: 8)
        let selectedRow = PiKit.SelectableRow(content: face, selected: selected, glide: glide) { [weak inspector] in inspector?.select(.turn(id)) }; self.selectedRow = selectedRow
        let disclosure = InspectorDisclosure(expanded: expanded, symbolSize: 9, width: 18, height: 40, label: expanded ? "Hide this turn's requests" : "Show this turn's requests") { [weak inspector] in inspector?.toggle(id) }; self.disclosure = disclosure
        row = inspectorRow([.view(disclosure, .fixed(18)), .view(selectedRow, .fill)], spacing: 0)
        super.init(frame: .zero); addSubview(row); setAccessibilityIdentifier("inspector-turn-row")
        update(turn: turn, prompt: prompt, expanded: expanded, selected: selected)
    }
    required init?(coder: NSCoder) { nil }
    func update(turn: InspectorTurn, prompt: String?, expanded: Bool, selected: Bool) {
        let title = turn.isOther ? "Other requests" : InspectorNavigator.firstLine(prompt) ?? turn.started.map { "Turn at " + Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "Turn \(turn.number)"
        heading.set(title, color: .piInk); detail.set(turn.summary, color: .piInkTertiary)
        number.text = turn.isOther ? "·" : "\(turn.number)"; number.selected = selected; selectedRow.selected = selected
        if running.isHidden != !turn.running { running.isHidden = !turn.running; detailLine.changed() }
        disclosure.update(expanded: expanded, label: expanded ? "Hide this turn's requests" : "Show this turn's requests")
        selectedRow.setAccessibilityLabel(title + ", " + turn.summary)
        setAccessibilityLabel((turn.isOther ? "Other requests" : "Turn \(turn.number)") + ": " + title + ", " + turn.summary)
    }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 262)) }
    override func layout() { super.layout(); row.frame = bounds }
}

@MainActor private final class InspectorTurnNumber: DashView {
    var text: String { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; PiKit.sizeChanged(self) } } }
    var selected: Bool { didSet { if selected != oldValue { needsDisplay = true } } }
    init(_ text: String, selected: Bool) { self.text = text; self.selected = selected; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    private var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 10.5, weight: .semibold)), color: selected ? .piAccent : .piInkSecondary) }
    override var intrinsicContentSize: NSSize { NSSize(width: max(20, line.size(scale: piScale).width), height: 20) }
    override func draw(_ dirtyRect: NSRect) { (selected ? NSColor.piAccentSoft : .piFill).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill(); let size = line.size(scale: piScale); line.draw(at: CGPoint(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale)), scale: piScale) }
}
@MainActor private final class InspectorDisclosure: PiKit.ButtonBase {
    private(set) var expanded: Bool
    let symbolSize: CGFloat, width: CGFloat, height: CGFloat
    init(expanded: Bool, symbolSize: CGFloat, width: CGFloat, height: CGFloat, label: String, action: @escaping () -> Void) { self.expanded = expanded; self.symbolSize = symbolSize; self.width = width; self.height = height; super.init(frame: .zero); pressScales = false; onPress = action; setAccessibilityLabel(label); setAccessibilityValue(expanded ? "Expanded" : "Collapsed") }
    required init?(coder: NSCoder) { nil }
    func update(expanded: Bool, label: String) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded; setAccessibilityLabel(label); setAccessibilityValue(expanded ? "Expanded" : "Collapsed"); redrawContent()
    }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: height) }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) { PiKit.Symbol(expanded ? "chevron.down" : "chevron.right", size: symbolSize, weight: .semibold).draw(centredIn: rect, color: .piInkTertiary, scale: piScale) }
}

/// A request's kind remains whole; model and token flow give way in order.
@MainActor private final class InspectorCompactLine: DashView {
    private let mark: NSView
    private let number: ShellText?
    private let kind: ShellText, model: ShellText?, flow: ShellText?
    init(symbol: String?, number: Int?, kind: String, model: String?, flow: String?, kindColor: NSColor, symbolColor: NSColor, outcome: String? = nil) {
        mark = symbol.map { PiKit.SymbolView(PiKit.Symbol($0, size: 10.5, weight: .medium), color: symbolColor) } ?? InspectorStatusMark(outcome: outcome ?? "")
        self.number = number.map { inspectorText(String($0), font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 11, weight: .semibold)), color: .piInkSecondary) }
        self.kind = inspectorText(kind, font: .systemFont(ofSize: 12, weight: symbol == nil ? .regular : .medium), color: kindColor)
        self.model = model.flatMap { $0.isEmpty ? nil : inspectorText($0, font: PiKit.Font.micro, color: .piInkTertiary) }
        self.flow = flow.map { inspectorText($0, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 10.5)), color: .piInkTertiary) }
        super.init(frame: .zero); shellAdd([mark, self.kind] + [self.number, self.model, self.flow].compactMap { $0 })
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: max(kind.intrinsicContentSize.height, mark.intrinsicContentSize.height)) }
    override func layout() {
        super.layout(); var x: CGFloat = 0
        func place(_ view: NSView, width: CGFloat? = nil) { let size = view.intrinsicContentSize; let w = width ?? size.width; view.frame = CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: w, height: size.height); x += w + 7 }
        place(mark); if let number { place(number) }; place(kind)
        let remaining = max(0, bounds.width - x)
        let flowWidth = flow?.naturalWidth ?? 0, modelWidth = model?.naturalWidth ?? 0
        let showsFlow = flowWidth + 4 <= remaining
        let showsModel = model != nil && showsFlow && modelWidth + flowWidth + (flow == nil ? 4 : 11) <= remaining
        if let model { model.isHidden = !showsModel; if showsModel { place(model) } }
        if let flow { flow.isHidden = !showsFlow; if showsFlow { let height = flow.intrinsicContentSize.height; flow.frame = CGRect(x: bounds.width - flowWidth, y: PiKit.round((bounds.height - height) / 2, piScale), width: flowWidth, height: height) } }
    }
}

@MainActor private final class InspectorNavIcon: DashView {
    let symbol: String
    var selected: Bool { didSet { if selected != oldValue { needsDisplay = true } } }
    init(symbol: String, selected: Bool) { self.symbol = symbol; self.selected = selected; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        let tone: PiTone = selected ? .accent : .neutral
        tone.nsColor.piOpacity(0.13).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7.8, yRadius: 7.8).fill()
        PiKit.Symbol(symbol, size: 26 * 0.46, weight: .semibold).draw(centredIn: bounds, color: tone.nsColor, scale: piScale)
    }
}
