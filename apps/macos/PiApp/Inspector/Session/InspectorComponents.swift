import AppKit

// Prepared strings and native Pi views shared by every Inspector page.
@MainActor func inspectorText(_ text: String, font: NSFont = PiKit.Font.caption,
                              color: NSColor = .piInk, lines: Int = 1) -> ShellText {
    ShellText(text, font: font, color: color, maximumLines: lines)
}
@MainActor func inspectorSelectableText(_ text: String, font: NSFont = PiKit.Font.caption,
                                        color: NSColor = .piInk, lines: Int = 1,
                                        truncation: NSLineBreakMode = .byTruncatingTail) -> ShellSelectableText {
    let view = ShellSelectableText(text, font: font, color: color, singleLine: lines == 1, truncation: truncation)
    if lines != 1 { view.maximumLines = lines == .max ? 0 : lines }
    return view
}
@MainActor func inspectorColumn(_ views: [NSView], spacing: CGFloat = 8,
                                padding: NSEdgeInsets = NSEdgeInsets()) -> ShellStack {
    ShellStack(.vertical, spacing: spacing, padding: padding, views.map { .view($0, .fill) })
}
@MainActor func inspectorRow(_ items: [ShellItem], spacing: CGFloat = 8,
                             alignment: ShellStack.Alignment = .center) -> ShellStack {
    ShellStack(.horizontal, spacing: spacing, alignment: alignment, items)
}

/// The route is tracked separately from body identity: a helper's running
/// request can become a durable capture without changing its attempt ID.
enum InspectorBodyRoute: Equatable {
    case archive, live
    static func resolve(row: InspectorRequestRow, kind: String, metadata: [String: WireValue], hasWorkspace: Bool) -> Self {
        guard hasWorkspace else { return .archive }
        let descriptor = metadata[kind]?.object ?? [:]
        let stored = row.source != .live || descriptor["savedToLog"]?.bool == true
        return stored && MessageBodyReader.canReadRetained(descriptor["state"]?.string ?? "") ? .archive : .live
    }
    @MainActor func source(inspector: SessionInspectorModel, request: InspectorRequestModel, row: InspectorRequestRow, kind: String) -> CapturedBodySource {
        if let overridden = request.sourceOverride?(row, kind) { return overridden }
        if self == .live, let workspace = inspector.workspace {
            return .live(workspace, sessionID: inspector.scope.sessionID, attemptID: row.id, kind: kind)
        }
        return .archive(inspector.archive, attemptID: row.id, kind: kind)
    }
}

/// A refreshed card can replace or temporarily detach its button. Keep
/// keyboard focus on the same accessible action after the new layout lands.
@MainActor struct InspectorButtonFocus {
    private weak var window: NSWindow?
    private let previous: PiKit.ButtonBase
    private let identifier: String?
    private let label: String?
    init?(in view: NSView) {
        guard let window = view.window, let button = window.firstResponder as? PiKit.ButtonBase,
              button.isDescendant(of: view) else { return nil }
        let identifier = button.accessibilityIdentifier(), label = button.accessibilityLabel()
        guard !identifier.isEmpty || label?.isEmpty == false else { return nil }
        self.window = window; previous = button; self.identifier = identifier.isEmpty ? nil : identifier; self.label = label
    }
    func restore(in view: NSView) {
        guard let window, window.firstResponder !== previous, view.window === window else { return }
        DispatchQueue.main.async { [weak view, weak window, previous = self.previous, identifier = self.identifier, label = self.label] in
            guard let view, let window, view.window === window, window.firstResponder !== previous else { return }
            // A different control may have deliberately taken focus meanwhile.
            if let focused = window.firstResponder as? NSView, focused !== previous,
               focused is NSControl || focused is NSText { return }
            view.layoutSubtreeIfNeeded()
            @MainActor func find(in view: NSView) -> PiKit.ButtonBase? {
                guard !view.isHidden else { return nil }
                if let button = view as? PiKit.ButtonBase, button.isEnabled,
                   identifier != nil ? button.accessibilityIdentifier() == identifier : button.accessibilityLabel() == label { return button }
                for child in view.subviews { if let found = find(in: child) { return found } }
                return nil
            }
            if let button = find(in: view) { window.makeFirstResponder(button) }
        }
    }
}

/// Pads native content while keeping its width-dependent height.
@MainActor final class InspectorInset: DashView, PiKit.WidthSizing {
    let content: NSView
    var insets: NSEdgeInsets { didSet { needsLayout = true; PiKit.sizeChanged(self) } }
    init(_ content: NSView, insets: NSEdgeInsets) {
        self.content = content; self.insets = insets
        super.init(frame: .zero); addSubview(content)
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat {
        insets.top + PiKit.height(of: content, width: max(0, width - insets.left - insets.right)) + insets.bottom
    }
    override var intrinsicContentSize: NSSize {
        let size = shellNaturalSize(content)
        return NSSize(width: size.width + insets.left + insets.right, height: height(forWidth: max(1, size.width + insets.left + insets.right)))
    }
    override func layout() { super.layout(); content.frame = CGRect(x: insets.left, y: insets.top, width: max(0, bounds.width - insets.left - insets.right), height: max(0, bounds.height - insets.top - insets.bottom)) }
}
@MainActor final class InspectorRule: DashView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) { NSColor.piHairline.setFill(); bounds.fill() }
}

/// Keeps a page's native content mounted under a loading/empty overlay.
@MainActor final class InspectorContentHost: DashView {
    let content: NSView
    private var placeholder: NSView?
    init(content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
    required init?(coder: NSCoder) { nil }
    func cover(_ placeholder: NSView?) {
        self.placeholder?.removeFromSuperview(); self.placeholder = placeholder
        content.isHidden = placeholder != nil
        if let placeholder { addSubview(placeholder) }; needsLayout = true
    }
    override func layout() { super.layout(); content.frame = bounds; placeholder?.frame = bounds }
}

/// Title gives way first; actions keep their names when the header has room.
@MainActor final class InspectorPageHeader: DashView, PiKit.WidthSizing {
    private let titleView: ShellText
    private let subtitleView: ShellSelectableText?
    private let badges: ShellStack
    private let actions: ShellStack
    private let actionViews: [NSView]
    init(_ title: String, subtitle: String? = nil, badges: [NSView] = [], actions: [NSView] = []) {
        titleView = inspectorText(title, font: PiKit.Font.title(18))
        subtitleView = subtitle.flatMap { $0.isEmpty ? nil : inspectorSelectableText($0, color: .piInkSecondary, lines: 2) }
        self.badges = inspectorRow(badges.map { .view($0) }, spacing: 8, alignment: .firstBaseline)
        self.actions = inspectorRow(actions.map { .view($0) }, spacing: 6)
        actionViews = actions
        super.init(frame: .zero)
        shellAdd([titleView, self.badges, self.actions] + (subtitleView.map { [$0] } ?? []))
        setAccessibilityElement(false); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    private func rowHeight(_ width: CGFloat, apply: Bool) -> CGFloat {
        let badge = shellNaturalSize(badges)
        let namedWidth = actionViews.reduce(CGFloat(0)) { $0 + (($1 as? InspectorHeaderAction)?.namedWidth ?? shellNaturalSize($1).width) } + CGFloat(max(0, actionViews.count - 1)) * 6
        let named = titleView.naturalWidth + (badge.width > 0 ? badge.width + 8 : 0) + 12 + 6 + namedWidth <= width
        for case let action as InspectorHeaderAction in actionViews { action.named = named }
        let action = shellNaturalSize(actions)
        let titleWidth = min(titleView.naturalWidth, max(0, width - action.width - (badge.width > 0 ? badge.width + 8 : 0) - 18))
        let titleHeight = titleView.height(forWidth: titleWidth)
        let titleBaseline = shellBaseline(titleView, height: titleHeight)
        let badgeBaseline = badges.items.compactMap { $0.view }.map { shellBaseline($0, height: shellNaturalSize($0).height) }.max() ?? 0
        let baseline = max(titleBaseline, badgeBaseline)
        let groupHeight = baseline + max(titleHeight - titleBaseline, badge.height - badgeBaseline)
        let height = max(groupHeight, action.height)
        if apply {
            let top = (height - groupHeight) / 2
            titleView.frame = CGRect(x: 0, y: PiKit.round(top + baseline - titleBaseline, piScale), width: titleWidth, height: titleHeight)
            badges.frame = CGRect(x: titleWidth + 8, y: PiKit.round(top + baseline - badgeBaseline, piScale), width: badge.width, height: badge.height)
            actions.frame = CGRect(x: max(0, width - action.width), y: PiKit.round((height - action.height) / 2, piScale), width: action.width, height: action.height)
        }
        return height
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        rowHeight(width, apply: false) + (subtitleView.map { 4 + $0.height(forWidth: width) } ?? 0)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() {
        super.layout(); let height = rowHeight(bounds.width, apply: true)
        subtitleView?.frame = CGRect(x: 0, y: height + 4, width: bounds.width, height: subtitleView?.height(forWidth: bounds.width) ?? 0)
    }
}

@MainActor class InspectorHeaderAction: DashView {
    private let full: PiKit.Button
    private let icon: PiKit.IconButton
    var named = true { didSet { guard named != oldValue else { return }; full.isHidden = !named; icon.isHidden = named; invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) } }
    var isEnabled: Bool { get { full.isEnabled } set { full.isEnabled = newValue; icon.isEnabled = newValue } }
    var namedWidth: CGFloat { full.intrinsicContentSize.width }
    init(title: String, symbol: String, help: String, identifier: String, action: @escaping () -> Void) {
        full = PiKit.Button(title, symbol: symbol, style: .ghost, action: action)
        icon = PiKit.IconButton(symbol: symbol, label: title, size: 26, action: action)
        super.init(frame: .zero); addSubview(full); addSubview(icon); icon.isHidden = true
        for view in [full, icon] { view.toolTip = help; view.setAccessibilityIdentifier(identifier) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { named ? full.intrinsicContentSize : icon.intrinsicContentSize }
    override func layout() { super.layout(); full.frame = bounds; icon.frame = bounds }
}
@MainActor final class InspectorShowInChat: InspectorHeaderAction {
    init(action: @escaping () -> Void) { super.init(title: "Show in chat", symbol: "arrow.uturn.left.circle", help: "Bring the chat forward, scrolled to what this page is about", identifier: "inspector-show-in-chat", action: action) }
    required init?(coder: NSCoder) { nil }
}
@MainActor final class InspectorForkFromHere: InspectorHeaderAction {
    init(action: @escaping () -> Void) { super.init(title: "Fork from here", symbol: "arrow.triangle.branch", help: "A new chat, nested under this one, that ends at the reply this request produced", identifier: "inspector-fork-from-here", action: action) }
    required init?(coder: NSCoder) { nil }
}

@MainActor final class InspectorSectionTitle: DashView, PiKit.WidthSizing {
    private let row: ShellStack
    init(_ title: String, subtitle: String? = nil) {
        row = inspectorRow([.view(inspectorText(title, font: PiKit.Font.heading))] + (subtitle.map { [.view(inspectorText($0, color: .piInkTertiary), .flexible)] } ?? []) + [.spacer(0)], spacing: 8, alignment: .firstBaseline)
        super.init(frame: .zero); addSubview(row)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityRoleDescription("heading")
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { row.intrinsicContentSize }
    override func layout() { super.layout(); row.frame = bounds }
}

struct InspectorFigure: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var detail: String? = nil
    var tone: PiTone = .neutral
}

@MainActor final class InspectorFigureStrip: DashView, PiKit.WidthSizing, ShellBaselined {
    private let flow = PiKit.FlowView()
    private var textBaseline: CGFloat = 0
    init(figures: [InspectorFigure]) {
        super.init(frame: .zero); flow.spacing = 16; flow.rowSpacing = 6; addSubview(flow)
        for figure in figures {
            var items: [ShellItem] = [.view(inspectorText(figure.label, color: .piInkTertiary)), .view(inspectorText(figure.value, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 13, weight: .semibold)), color: figure.tone == .neutral ? .piInk : figure.tone.nsColor))]
            if let detail = figure.detail { items.append(.view(inspectorText(detail, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))) }
            let row = inspectorRow(items, spacing: 5, alignment: .firstBaseline)
            if flow.subviews.isEmpty {
                textBaseline = items.compactMap(\.view).map { shellBaseline($0, height: shellNaturalSize($0).height) }.max() ?? 0
            }
            row.setAccessibilityElement(true); row.setAccessibilityRole(.group)
            row.setAccessibilityLabel([figure.label, figure.value, figure.detail].compactMap { $0 }.joined(separator: ", "))
            flow.addSubview(row)
        }
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { flow.height(forWidth: width) }
    /// A wrapped strip keeps its first line aligned with the disclosures
    /// beside it; using the flow's bottom would align them to its last line.
    var firstBaseline: CGFloat { textBaseline }
    override var intrinsicContentSize: NSSize { flow.intrinsicContentSize }
    override func layout() { super.layout(); flow.frame = bounds }
}

@MainActor final class InspectorBanner: DashView, PiKit.WidthSizing {
    private let box: PiKit.Box
    init(symbol: String, text: String, notes: [String] = [], tone: PiTone = .accent) {
        let icon = PiKit.SymbolView(PiKit.Symbol(symbol, size: 12, weight: .semibold), color: tone.nsColor)
        let words = inspectorColumn([inspectorSelectableText(text, font: .systemFont(ofSize: 12.5, weight: .medium), lines: .max)] + notes.map { inspectorSelectableText($0, color: .piInkSecondary, lines: .max) }, spacing: 3)
        let row = inspectorRow([.view(icon, insets: NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)), .view(words, .flexible), .spacer(0)], spacing: 8, alignment: .top)
        box = PiKit.Box(fill: tone == .accent ? .piAccentSoft : tone.nsColor.piOpacity(0.1), cornerRadius: 10, padding: NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12), content: row)
        super.init(frame: .zero); addSubview(box)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(([text] + notes).joined(separator: ". "))
        setAccessibilityIdentifier("inspector-banner")
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { ceil(box.height(forWidth: width)) }
    override var intrinsicContentSize: NSSize { let size = box.intrinsicContentSize; return NSSize(width: size.width, height: ceil(size.height)) }
    override func layout() { super.layout(); box.frame = bounds }
}

@MainActor final class InspectorPlaceholder: DashView {
    private let column: ShellStack
    init(symbol: String, title: String, message: String? = nil, progress: Double? = nil) {
        var views: [NSView] = symbol.isEmpty ? [] : [PiKit.SymbolView(PiKit.Symbol(symbol, size: 22, weight: .light), color: .piInkTertiary)]
        let titleView = inspectorText(title, font: PiKit.Font.heading, color: .piInkSecondary, lines: .max); titleView.centred = true; views.append(titleView)
        if let progress { let bar = PiKit.ShareBar(fraction: progress, tone: .piBrandOrange); views.append(InspectorFixedSize(bar, width: 220, height: 4)) }
        if let message { let words = inspectorText(message, color: .piInkTertiary, lines: .max); words.centred = true; views.append(words) }
        column = ShellStack(.vertical, spacing: 10, alignment: .center, views.map { .view($0, .flexible) })
        super.init(frame: .zero); addSubview(column)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel([title, message].compactMap { $0 }.joined(separator: ". "))
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); let width = min(380, max(0, bounds.width - 48)); let height = column.height(forWidth: width); column.frame = CGRect(x: (bounds.width - width) / 2, y: max(24, (bounds.height - height) / 2), width: width, height: height) }
}
@MainActor final class InspectorFixedSize: DashView, PiKit.WidthSizing {
    let content: NSView
    let width: CGFloat
    let height: CGFloat
    init(_ content: NSView, width: CGFloat, height: CGFloat) { self.content = content; self.width = width; self.height = height; super.init(frame: .zero); addSubview(content) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: height) }
    func height(forWidth width: CGFloat) -> CGFloat { height }
    override func layout() { super.layout(); content.frame = bounds }
}
@MainActor final class InspectorStatusMark: DashView {
    let outcome: String
    init(outcome: String) { self.outcome = outcome; super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(outcome) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch outcome { case "completed", "truncated": color = .piSuccess; case "running", "streaming": color = .piBrandOrange; case "failed", "interrupted", "error": color = .piDanger; case "cancelled": color = .piWarning; default: color = .piInkTertiary }
        let dot = NSBezierPath(ovalIn: bounds); color.setFill(); dot.fill()
        if ["running", "streaming"].contains(outcome) { color.piOpacity(0.35).setStroke(); dot.lineWidth = 3; dot.stroke() }
    }
}

extension InspectorRequestRow {
    /// `Completed`, `Running`, `Failed`.
    var outcomeLabel: String {
        switch outcome {
        case "completed": return "Completed"
        case "truncated": return "Output limit"
        case "running", "streaming": return "Running"
        case "interrupted": return "Interrupted"
        case "cancelled": return "Stopped"
        case "failed", "error": return "Failed"
        default: return outcome.isEmpty ? "Unknown" : outcome.prefix(1).uppercased() + outcome.dropFirst()
        }
    }
    var outcomeTone: PiTone {
        switch outcome {
        case "completed": return .success
        case "running", "streaming", "truncated", "cancelled": return .warning
        case "failed", "interrupted", "error": return .danger
        default: return .neutral
        }
    }
    /// `In 18,240 (15,112 cached) · Out 1,104 · reasoning 640 · $0.0213 · TTFT 820 ms · 96 tok/s · 3.4 s`
    var figures: [InspectorFigure] {
        var figures: [InspectorFigure] = []
        if let input { figures.append(InspectorFigure(label: "In", value: MetricFormat.exactTokens(input), detail: cached.map { "(" + MetricFormat.exactTokens($0) + " cached)" })) }
        if let output { figures.append(InspectorFigure(label: "Out", value: MetricFormat.exactTokens(output))) }
        if let reasoning { figures.append(InspectorFigure(label: "reasoning", value: MetricFormat.exactTokens(reasoning))) }
        if let cost { figures.append(InspectorFigure(label: "Cost", value: compactGatewayUSD(cost))) }
        if let ttft { figures.append(InspectorFigure(label: "TTFT", value: MetricFormat.latency(ttft))) }
        if let settledRate { figures.append(InspectorFigure(label: "Speed", value: MetricFormat.throughput(settledRate))) }
        if let duration = duration ?? http { figures.append(InspectorFigure(label: "Time", value: SessionStatsFormat.duration(duration))) }
        return figures
    }
}

/// Text in a fixed trailing column, with the same one-line truncation.
@MainActor final class InspectorTrailingText: DashView {
    let line: PiKit.Line
    let truncation: CTLineTruncationType
    init(_ text: String, font: NSFont = PiKit.Font.caption, color: NSColor = .piInkSecondary, truncation: CTLineTruncationType = .end) {
        line = PiKit.Line(text, font: font, color: color); self.truncation = truncation
        super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(text)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
    override func draw(_ dirtyRect: NSRect) { let width = min(bounds.width, line.size(scale: piScale).width); line.draw(in: CGRect(x: max(0, bounds.width - width), y: 0, width: width, height: bounds.height), truncation: truncation, scale: piScale) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Disclosure copy is drawn with its own small chevron, rather than a
/// Label's full-size symbol. Plain form is used by the methodology footer.
@MainActor final class InspectorInlineDisclosure: PiKit.ButtonBase, ShellBaselined {
    let text: String, expanded: Bool, plain: Bool
    init(_ text: String, expanded: Bool, plain: Bool = false, action: @escaping () -> Void) {
        self.text = text; self.expanded = expanded; self.plain = plain
        super.init(frame: .zero); pressScales = !plain; onPress = action
        setAccessibilityLabel(text); setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
    required init?(coder: NSCoder) { nil }
    private var line: PiKit.Line { PiKit.Line(text, font: .systemFont(ofSize: plain ? PiKit.Font.captionSize : 12.5, weight: .medium), color: .piInkSecondary) }
    private var glyph: PiKit.Symbol { PiKit.Symbol(plain ? (expanded ? "chevron.down" : "chevron.right") : (expanded ? "chevron.up" : "chevron.down"), size: plain ? 9 : 8.5, weight: .semibold) }
    override var intrinsicContentSize: NSSize { let label = line.size(scale: piScale); return NSSize(width: label.width + glyph.layoutSize.width + (plain ? 6 : 4) + (plain ? 0 : 20), height: max(label.height, glyph.layoutSize.height) + (plain ? 0 : 12)) }
    var firstBaseline: CGFloat {
        PiKit.round((intrinsicContentSize.height - line.size(scale: piScale).height) / 2, piScale) + line.baseline(scale: piScale)
    }
    override func styleFace() { fill.backgroundColor = piCGColor(plain ? .clear : isPressedDown ? .piFillStrong : hovering ? .piFill : .clear); stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) {
        let label = line.size(scale: piScale), icon = glyph.layoutSize
        let textX: CGFloat = plain ? icon.width + 6 : 10
        line.draw(at: CGPoint(x: textX, y: PiKit.round((rect.height - label.height) / 2, piScale)), scale: piScale)
        glyph.draw(centredIn: CGRect(x: plain ? 0 : textX + label.width + 4, y: 0, width: icon.width, height: rect.height), color: .piInkSecondary, scale: piScale)
    }
}
