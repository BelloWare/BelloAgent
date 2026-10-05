import AppKit
import Combine

/// One turn's report, with the prompt's native expansion kept in its card.
@MainActor final class InspectorTurnPage: DashView {
    let inspector: SessionInspectorModel
    var turnID: String { didSet { if turnID != oldValue { prompt.collapse(); refresh() } } }
    var compact: Bool { didSet { if compact != oldValue { refresh() } } }
    private let prompt = InspectorPromptExpansion()
    private let column = ShellStack(.vertical, spacing: 18)
    private lazy var scroll = PageScrollView(column: column)
    private lazy var promptCard = InspectorPromptCard(preview: inspector.prompts[turnID], model: prompt, showAll: { [weak self] in guard let self else { return }; self.showPrompt(self.turnID) }, folded: { [weak self] in self?.scrollPromptIntoView() })
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private var turn: InspectorTurn? { inspector.index.turn(turnID) }
    private var summary: TurnSummary? { inspector.summaries[turnID] }
    init(inspector: SessionInspectorModel, turnID: String, compact: Bool) {
        self.inspector = inspector; self.turnID = turnID; self.compact = compact
        super.init(frame: .zero); addSubview(scroll); scroll.maximumWidth = 1_100
        setAccessibilityIdentifier("inspector-turn"); observer.observe(inspector); refresh()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { prompt.collapse() } }
    private func scrollPromptIntoView() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.promptCard.scrollToVisible(self.promptCard.bounds) }
    }
    func refresh() {
        let inset = compact ? PiSpacing.lg : PiSpacing.xl
        scroll.insets = NSEdgeInsets(top: PiSpacing.lg, left: inset, bottom: PiSpacing.lg, right: inset)
        guard let turn else { column.items = [.view(InspectorPlaceholder(symbol: "text.bubble", title: "This turn has no retained requests", message: "Its requests may have expired from the request log, or capture was off."), .fill)]; needsLayout = true; return }
        var views: [NSView] = [header(turn)]
        if !turn.isOther { promptCard.preview = inspector.prompts[turn.id]; views.append(promptCard) }
        views += [usage(turn), requests(turn)]
        column.items = views.map { .view($0, .fill) }; scroll.fit(); needsLayout = true
    }
    private func header(_ turn: InspectorTurn) -> NSView {
        let outcome = summary.map(TurnInfoPresentation.outcome) ?? (turn.running ? "In progress" : turn.requests.contains(where: \.failed) ? "Some requests failed" : "Completed")
        var parts: [String] = []
        if let started = turn.started { parts.append("Started " + Date(timeIntervalSince1970: started).formatted(date: .omitted, time: .standard)) }
        if let elapsed = summary?.elapsedMs ?? turn.span { parts.append(SessionStatsFormat.duration(elapsed)) }
        parts.append(turn.summary)
        let tone: PiTone = turn.running ? .warning : outcome == "Completed" ? .success : .warning
        return InspectorPageHeader(turn.isOther ? "Other requests" : "Turn \(turn.number)", subtitle: parts.joined(separator: " · "), badges: turn.isOther ? [] : [PiKit.Badge(text: outcome, tone: tone, dot: true)], actions: [InspectorShowInChat { [weak inspector] in inspector?.showInChat() }])
    }
    /// The whole prompt, in the card, read from the chat's journal.
    private func showPrompt(_ id: String) {
        guard let workspace = inspector.workspace else { return }
        let sessionID = inspector.scope.sessionID
        prompt.show {
            var text = "", offset = 0, total = 0
            repeat {
                let page = try await workspace.messagePage(id: id, field: "text", offset: offset, sessionID: sessionID)
                text += page.0; offset += (page.0 as NSString).length; total = max(total, page.1)
                if page.0.isEmpty { break }
                if offset >= page.1 { break }
            } while offset < InspectorPromptExpansion.readLimit
            return (text, offset, total)
        }
    }

    private func usage(_ turn: InspectorTurn) -> NSView {
        let accounting = summary?.accounting ?? turn.accounting
        let grid = GridView(columns: .flexible(2), spacing: 24, rowSpacing: 0)
        grid.items = [TokenShareBar(partition: TurnTokenPartition(accounting, input: true, running: turn.running)), TokenShareBar(partition: TurnTokenPartition(accounting, input: false, running: turn.running))]
        var views: [NSView] = [grid, InspectorFigureStrip(figures: turnFigures(accounting))]
        if let summary, let notice = TurnInfoPresentation.coverageNotice(summary) { views.append(inspectorText(notice, font: PiKit.Font.micro, color: .piInkTertiary, lines: .max)) }
        if let notice = summary?.notice, !notice.isEmpty { views.append(inspectorText(notice, color: .piWarning, lines: .max)) }
        let card = PiKit.card(inspectorColumn(views, spacing: 10), padding: PiSpacing.md); card.setAccessibilityIdentifier("inspector-turn-usage"); return card
    }
    private func turnFigures(_ a: TurnAccounting) -> [InspectorFigure] {
        var figures: [InspectorFigure] = []
        if let cost = a.costUSD { figures.append(InspectorFigure(label: "Cost", value: compactGatewayUSD(cost), detail: a.costSamples < a.requests ? "(\(a.costSamples)/\(a.requests))" : nil)) }
        if let summary {
            if summary.modelMs > 0 { figures.append(InspectorFigure(label: "Model", value: SessionStatsFormat.duration(summary.modelMs))) }
            if summary.toolMs > 0 { figures.append(InspectorFigure(label: "Tools", value: SessionStatsFormat.duration(summary.toolMs))) }
            figures.append(InspectorFigure(label: "Replies", value: "\(summary.replies)"))
            if summary.tools > 0 { figures.append(InspectorFigure(label: "Tool calls", value: "\(summary.tools)")) }
            if summary.files > 0 { figures.append(InspectorFigure(label: "Files changed", value: "\(summary.files)")) }
        }
        if let rate = a.throughput.tokensPerSecond { figures.append(InspectorFigure(label: "Speed", value: MetricFormat.throughput(rate))) }
        return figures
    }

    private func requests(_ turn: InspectorTurn) -> NSView {
        let lines = turn.requests.map(TurnRequestLine.init(row:))
        let subtotals = TurnInfoPresentation.subtotals(lines), models = Set(lines.compactMap(\.model)).count
        let heading = InspectorSectionTitle("Requests", subtitle: "\(turn.requests.count) in this turn" + (models > 1 ? " · \(models) models" : "") + " · a row opens its request")
        var rows: [NSView] = []
        for (offset, row) in turn.requests.enumerated() {
            if offset > 0 { rows.append(InspectorInset(InspectorRule(), insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))) }
            rows.append(InspectorTurnRequestRow(row: row, line: lines[offset], number: offset + 1, kind: inspector.index.kind(of: row.id), compact: compact) { [weak inspector] in inspector?.select(.request(row.id)) })
        }
        if subtotals.count > 1 {
            rows.append(InspectorInset(InspectorRule(), insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)))
            let column = inspectorColumn(subtotals.map { inspectorText(TurnInfoPresentation.subtotalLabel($0), font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary) }, spacing: 3, padding: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)); column.setAccessibilityIdentifier("inspector-turn-subtotals"); rows.append(column)
        }
        let result = inspectorColumn([heading, PiKit.card(inspectorColumn(rows, spacing: 0), padding: 6)], spacing: 8)
        result.setAccessibilityIdentifier("inspector-turn-requests"); return result
    }
    override func layout() { super.layout(); scroll.frame = bounds; scroll.fit() }
}

@MainActor private final class InspectorTurnRequestRow: PiKit.ButtonBase, PiKit.WidthSizing {
    private let row: ShellStack
    init(row: InspectorRequestRow, line: TurnRequestLine, number: Int, kind: String, compact: Bool, open: @escaping () -> Void) {
        let route = inspectorText(TurnInfoPresentation.routeLabel(line), font: PiKit.Font.micro, color: .piInkTertiary); route.truncation = .middle
        let labels = inspectorColumn([inspectorText(kind.prefix(1).uppercased() + kind.dropFirst(), font: .systemFont(ofSize: 12.5, weight: .medium)), route], spacing: 1)
        var items: [ShellItem] = [.view(InspectorStatusMark(outcome: row.outcome)), .view(InspectorTrailingText("\(number)", font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 12, weight: .semibold)), color: .piInkSecondary), .fixed(18)), .view(labels, .fill), .view(inspectorText(row.tokenFlow ?? TurnInfoPresentation.lineFigures(line), font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: row.tokenFlow == nil ? .piInkTertiary : .piInkSecondary))]
        if !compact {
            items += [.view(InspectorTrailingText(row.cost.map(compactGatewayUSD) ?? "—", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary), .fixed(74)), .view(InspectorTrailingText((row.duration ?? row.http).map(SessionStatsFormat.duration) ?? "—", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary), .fixed(58))]
        }
        let source = InspectorTrailingText(TurnInfoPresentation.lineSource(line), font: PiKit.Font.micro, color: .piInkTertiary, truncation: .middle)
        items.append(.view(source, .fixed(compact ? 86 : 124)))
        self.row = inspectorRow(items, spacing: 10)
        super.init(frame: .zero); pressScales = false; onPress = open; addSubview(self.row)
        setAccessibilityLabel("Request \(number), \(kind), \(row.route.label), " + (row.tokenFlow ?? TurnInfoPresentation.lineFigures(line)))
        setAccessibilityIdentifier("inspector-turn-request")
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: max(0, width - 16)) + 14 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func cornerRadius(for size: CGSize) -> CGFloat { 8 }
    override func styleFace() { fill.backgroundColor = piCGColor(hovering ? .piFill : .clear); stroke.borderColor = CGColor.clear }
    override func layout() { super.layout(); row.frame = bounds.insetBy(dx: 8, dy: 7) }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

/// A turn's prompt read whole, for its card; nil while the card shows the
/// preview.
@MainActor final class InspectorPromptExpansion: ObservableObject {
    /// The most of a prompt read from the journal; the card says when a
    /// prompt is longer.
    static let readLimit = 8_388_608
    @Published private(set) var expansion: InspectorExpansion?

    func show(read: @escaping @MainActor () async throws -> (text: String, length: Int, total: Int)) {
        guard expansion == nil else { return }
        let expansion = InspectorExpansion(title: "Prompt", style: InspectorTextStyle(face: .body))
        expansion.showLess = { [weak self] in self?.collapse() }
        self.expansion = expansion
        expansion.load(read)
    }
    func collapse() {
        guard let expansion else { return }
        expansion.cancel()
        self.expansion = nil
    }
}

/// The prompt's preview and worker-produced whole text share this stable card.
@MainActor final class InspectorPromptCard: DashView, PiKit.WidthSizing {
    var preview: String? { didSet { if preview != oldValue { refresh() } } }
    let model: InspectorPromptExpansion
    let showAll: () -> Void
    let folded: () -> Void
    private let column = ShellStack(.vertical, spacing: 8)
    private lazy var card = PiKit.card(column, padding: PiSpacing.md)
    private let block = InspectorTextBlockView()
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private lazy var expansionObserver = ShellObserver { [weak self] in self?.refresh() }
    private weak var observedExpansion: InspectorExpansion?

    init(preview: String?, model: InspectorPromptExpansion, showAll: @escaping () -> Void, folded: @escaping () -> Void = {}) {
        self.preview = preview; self.model = model; self.showAll = showAll; self.folded = folded
        super.init(frame: .zero); addSubview(card); setAccessibilityIdentifier("inspector-turn-prompt")
        observer.observe(model); refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func refresh() {
        let expansion = model.expansion
        if observedExpansion !== expansion { expansionObserver.reset(); if let expansion { expansionObserver.observe(expansion) }; observedExpansion = expansion; block.show(expansion) }
        let toggle = PiKit.Button(expansion == nil ? "Show all" : "Show less", style: .ghost) { [weak self] in guard let self else { return }; if self.model.expansion == nil { self.showAll() } else { self.model.collapse() } }
        toggle.isEnabled = expansion != nil || preview?.isEmpty == false; toggle.setAccessibilityIdentifier("inspector-prompt-toggle")
        let heading = inspectorRow([.view(PiKit.SymbolView(PiKit.Symbol("person.crop.circle", size: 12, weight: .medium), color: .piInfo)), .view(inspectorText("Prompt", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInkSecondary)), .spacer(0), .view(toggle)], spacing: 6)
        var items: [ShellItem] = [.view(heading, .fill)]
        if let expansion {
            if expansion.layout != nil { items.append(.view(block, .fill)) }
            else if let preview, !preview.isEmpty { items.append(.view(inspectorSelectableText(preview, font: PiKit.Font.body, lines: 8), .fill)) }
            // Offer a width even before the first layout has arrived.
            if expansion.layout == nil { items.append(.view(block, .fill)) }
            switch expansion.phase {
            case .loading: items.append(.view(inspectorRow([.view(PiKit.spinner(controlSize: .small)), .view(inspectorText(expansion.loaded ? "Laying out the whole prompt…" : "Reading the whole prompt…", color: .piInkTertiary), .flexible)], spacing: 6), .fill))
            case .failed(let message): items.append(.view(inspectorText("The whole prompt could not be read: " + message, color: .piWarning, lines: .max), .fill))
            case .shown: break
            }
            if expansion.capped {
                let reveal = PiKit.Button(expansion.laying ? "Laying out…" : "Show \(MetricFormat.tokens(Double(expansion.nextStep))) more", style: .ghost) { [weak expansion] in expansion?.reveal() }
                reveal.isEnabled = !expansion.laying; reveal.setAccessibilityIdentifier("inspector-prompt-reveal")
                items.append(.view(inspectorRow([.view(inspectorText("Showing the first \(MetricFormat.tokens(Double(expansion.shown))) of \(MetricFormat.tokens(Double(expansion.length))) characters", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary), .flexible), .view(reveal)], spacing: 8), .fill))
            }
            if expansion.loaded, expansion.total > expansion.length { items.append(.view(inspectorText("The first \(MetricFormat.tokens(Double(expansion.length))) of the prompt's \(MetricFormat.tokens(Double(expansion.total))) characters were read.", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary, lines: .max), .fill)) }
            if (expansion.layout?.height ?? 0) > 320 {
                let less = PiKit.Button("Show less", style: .ghost) { [weak self] in self?.model.collapse(); self?.folded() }; less.setAccessibilityIdentifier("inspector-prompt-less")
                items.append(.view(less, .natural))
            }
        } else if let preview, !preview.isEmpty { items.append(.view(inspectorSelectableText(preview, font: PiKit.Font.body, lines: 8), .fill)) }
        else { items.append(.view(inspectorText(preview == nil ? "Reading the prompt…" : "The prompt's text was not retained.", color: .piInkTertiary), .fill)) }
        column.items = items; PiKit.sizeChanged(self); needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { card.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() { super.layout(); card.frame = bounds }
}
