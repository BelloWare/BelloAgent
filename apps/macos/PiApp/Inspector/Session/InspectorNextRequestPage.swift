import AppKit

/// Prepared provider input uses the same native outline as retained requests.
@MainActor final class InspectorNextRequestPage: DashView {
    let inspector: SessionInspectorModel
    let next: NextRequestModel
    var compact: Bool { didSet { if compact != oldValue { refresh() } } }
    private var header: NSView?
    private var summary: NSView?
    private let rule = InspectorRule()
    private let outline = InspectorItemsOutline()
    private lazy var content = InspectorContentHost(content: outline)
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    init(inspector: SessionInspectorModel, next: NextRequestModel, compact: Bool) {
        self.inspector = inspector; self.next = next; self.compact = compact
        super.init(frame: .zero); shellAdd([rule, content])
        observer.observe(inspector); observer.observe(next)
        setAccessibilityIdentifier("inspector-next-request"); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let refresh = PiKit.IconButton(symbol: "arrow.clockwise", label: "Prepare it again", size: 26) { [weak inspector, weak next] in
            guard let inspector else { return }
            let latest = inspector.index.latestRequestID.flatMap(inspector.index.request)
            next?.refresh(previous: latest, previousLabel: latest.map { inspector.label(of: $0, from: nil) })
        }
        var views: [NSView] = [InspectorPageHeader("Next request", subtitle: "As the helper would send it now, with your draft. Nothing is sent to the model.", actions: [refresh, InspectorShowInChat { [weak inspector] in inspector?.showInChat() }])]
        if let display = inspector.display { views.append(InspectorContextSummary(workspace: inspector.workspace, display: display, preview: next.summary)) }
        let inset = compact ? PiSpacing.lg : PiSpacing.xl
        header?.removeFromSuperview(); header = InspectorInset(inspectorColumn(views, spacing: 12), insets: NSEdgeInsets(top: PiSpacing.lg, left: inset, bottom: PiSpacing.sm, right: inset)); addSubview(header!)
        summary?.removeFromSuperview(); summary = nil
        let placeholder: NSView?
        switch next.document {
        case .idle: placeholder = InspectorPlaceholder(symbol: "square.stack.3d.up", title: "Preparing the next request…")
        case .loading(let loaded, let total): placeholder = InspectorPlaceholder(symbol: "square.stack.3d.up", title: "Preparing the next request", message: total > 0 ? RequestDocument.charactersLabel(loaded) + " of " + RequestDocument.charactersLabel(total) : nil, progress: total > 0 ? Double(loaded) / Double(total) : nil)
        case .failed(let message): placeholder = InspectorPlaceholder(symbol: "exclamationmark.circle", title: "The next request could not be prepared", message: message)
        case .ready(let document):
            placeholder = nil
            let grouped = next.delta.map { !$0.first } ?? false
            // A same-length edit is still a different prepared request.
            let revision = next.summary["revision"]?.string ?? ""
            outline.update(content: InspectorOutlineContent(key: "next:" + revision + ":\(document.bytes):\(document.items.count)", sections: document.sections, items: document.items, shared: grouped ? next.delta?.shared : nil, marksNew: grouped, openLast: grouped ? min(next.delta?.added ?? 0, 8) : 2)) { InspectorRequestPage.wholeText($0, of: document) }
            let banner: NSView?
            if let delta = next.delta { banner = InspectorBanner(symbol: delta.rewritten ? "arrow.triangle.2.circlepath" : "plus.circle", text: delta.banner(previous: delta.first ? nil : next.previousLabel, cachedShare: nil), notes: delta.notes, tone: delta.rewritten ? .warning : .accent) }
            else if let note = next.deltaNote { banner = InspectorBanner(symbol: "info.circle", text: "\(document.items.count) items, " + RequestDocument.charactersLabel(document.totalCharacters), notes: [note], tone: .neutral) }
            else { banner = nil }
            if let banner { summary = InspectorInset(banner, insets: NSEdgeInsets(top: 12, left: inset, bottom: 8, right: inset)); addSubview(summary!) }
        }
        content.cover(placeholder); needsLayout = true
    }
    override func layout() {
        super.layout(); var y: CGFloat = 0
        if let header { let height = PiKit.height(of: header, width: bounds.width); header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height); y += height }
        rule.frame = CGRect(x: 0, y: y, width: bounds.width, height: 1); y += 1
        if let summary { let height = PiKit.height(of: summary, width: bounds.width); summary.frame = CGRect(x: 0, y: y, width: bounds.width, height: height); y += height }
        let inset = compact ? PiSpacing.sm : PiSpacing.md
        content.frame = CGRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - y))
    }
}

@MainActor private final class InspectorContextSummary: DashView, PiKit.WidthSizing {
    weak var workspace: WorkspaceModel?
    let display: SessionDisplay
    let preview: [String: WireValue]
    private var box: PiKit.Box?
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    init(workspace: WorkspaceModel?, display: SessionDisplay, preview: [String: WireValue]) {
        self.workspace = workspace; self.display = display; self.preview = preview
        super.init(frame: .zero)
        observer.observe(display); observer.observe(display.composerDraft)
        if let workspace { observer.observe(workspace) }
        setAccessibilityIdentifier("inspector-context-summary"); refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func refresh() {
        let meter = ContextMeterPresentation(context: PreparedContextMetrics.context(from: preview) ?? workspace?.displayedContext(display) ?? display.context)
        let count = inspectorRow([.view(PiKit.Ring.context(meter.fraction, size: 30)), .view(inspectorColumn([inspectorText(meter.fraction.flatMap(MetricFormat.occupancyPercent).map { $0 + "% of the context" } ?? meter.compactLabel, font: .systemFont(ofSize: 13, weight: .semibold)), inspectorText(meter.compactFigures + " · " + meter.methodLabel + (meter.estimated ? " · estimated" : ""), color: .piInkSecondary)], spacing: 2), .flexible)], spacing: 10); count.toolTip = meter.detailLabel
        let budgets = inspectorColumn(meter.budgetParts.map { part in inspectorRow([.view(inspectorText(part.name, color: .piInkTertiary)), .view(inspectorText(part.value, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))], spacing: 6) }, spacing: 2)
        let draft = inspectorColumn([inspectorText("Draft", color: .piInkTertiary), inspectorText("≈\(max(0, (display.composerDraft.text as NSString).length / 4)) tokens", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary)], spacing: 2); draft.toolTip = "Characters ÷ 4: a rough size, not the context count"
        let row = inspectorRow([.view(count, .flexible), .view(budgets), .view(draft), .spacer(0)], spacing: 18, alignment: .top)
        box?.removeFromSuperview(); box = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md, padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md), content: row); addSubview(box!)
        invalidateIntrinsicContentSize(); PiKit.sizeChanged(self); needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { box?.height(forWidth: width) ?? 0 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() { super.layout(); box?.frame = bounds }
}
