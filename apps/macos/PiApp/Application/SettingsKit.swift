import AppKit

// The settings screens' AppKit pieces (0.1.120): a settings group whose card
// holds any rows (`PiSettingsGroup`, whose rows were any views), a vertical
// stack of width-sized views, a row of views laid out as an `HStack`, and
// text inset in a card.

/// A settings group: its title in small capitals, its rows on a white card,
/// and an optional footnote, 8 points apart (`PiSettingsGroup`). A row is
/// any view that sizes to a width; `PiKit.Row`s draw their own hairlines.
@MainActor final class SettingsCard: NSView, PiKit.WidthSizing {
    private let titleView: PiKit.TextLine
    private let card = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md)
    private let stack = PiKit.Box.ClipView()
    private let footerView = TextBlock("", font: PiKit.Font.caption, color: .piInkTertiary)
    private(set) var rows: [NSView] = []

    init(title: String, footer: String? = nil, rows: [NSView] = []) {
        titleView = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.micro, color: .piInkSecondary, tracking: 0.5, uppercased: true))
        super.init(frame: .zero)
        card.content = stack
        for view in [titleView, card, footerView] as [NSView] { addSubview(view) }
        setFooter(footer)
        setRows(rows)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func setTitle(_ title: String) { titleView.line.text = title; needsLayout = true }
    func setFooter(_ footer: String?) { footerView.text = footer ?? ""; footerView.isHidden = footer == nil; needsLayout = true }
    func setRows(_ next: [NSView]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = next
        for row in rows { stack.addSubview(row) }
        // A row marked last draws no hairline; the group's last does not either
        // when the row says so itself (SwiftUI drew what each row said).
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = titleView.intrinsicContentSize.height + PiSpacing.sm
        height += rows.reduce(0) { $0 + PiKit.height(of: $1, width: width) }
        if !footerView.isHidden { height += PiSpacing.sm + footerView.height(forWidth: width - 8) }
        return height
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        let titleSize = titleView.intrinsicContentSize
        titleView.frame = CGRect(x: 4, y: 0, width: min(titleSize.width, width - 4), height: titleSize.height)
        var y: CGFloat = 0
        for row in rows {
            let height = PiKit.height(of: row, width: width)
            row.frame = CGRect(x: 0, y: y, width: width, height: height); y += height
        }
        card.frame = CGRect(x: 0, y: titleSize.height + PiSpacing.sm, width: width, height: y)
        if !footerView.isHidden {
            let height = footerView.height(forWidth: width - 8)
            footerView.frame = CGRect(x: 4, y: card.frame.maxY + PiSpacing.sm, width: width - 8, height: height)
        }
    }
}

/// A settings row's control area or a card's inset text: a view padded on
/// either side, its height what its content needs at its width.
@MainActor final class InsetView: NSView, PiKit.WidthSizing {
    let content: NSView
    let insets: NSEdgeInsets
    /// A fixed height for the content, when it has one (an editor's frame).
    var contentHeight: CGFloat?
    init(_ content: NSView, insets: NSEdgeInsets, contentHeight: CGFloat? = nil) {
        self.content = content; self.insets = insets; self.contentHeight = contentHeight
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func inner(_ width: CGFloat) -> CGFloat { max(0, width - insets.left - insets.right) }
    func height(forWidth width: CGFloat) -> CGFloat {
        (contentHeight ?? PiKit.height(of: content, width: inner(width))) + insets.top + insets.bottom
    }
    override func layout() {
        super.layout()
        let width = inner(bounds.width)
        content.frame = CGRect(x: insets.left, y: insets.top, width: width, height: contentHeight ?? PiKit.height(of: content, width: width))
    }
}

/// Views stacked down, `spacing` apart inside `padding`, each its height
/// at the stack's width (a `VStack(alignment: .leading)` of full-width views).
@MainActor final class VerticalStack: NSView, PiKit.WidthSizing {
    var spacing: CGFloat
    var padding: NSEdgeInsets
    private(set) var items: [NSView] = []
    init(spacing: CGFloat, padding: NSEdgeInsets = NSEdgeInsets()) {
        self.spacing = spacing; self.padding = padding
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func setItems(_ next: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = next
        for item in items { addSubview(item) }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - padding.left - padding.right
        let shown = items.filter { !$0.isHidden }
        return shown.reduce(0) { $0 + PiKit.height(of: $1, width: inner) } + spacing * CGFloat(max(0, shown.count - 1)) + padding.top + padding.bottom
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func layout() {
        super.layout()
        let inner = bounds.width - padding.left - padding.right
        var y = padding.top
        for item in items where !item.isHidden {
            let height = PiKit.height(of: item, width: inner)
            item.frame = CGRect(x: padding.left, y: y, width: inner, height: height)
            y += height + spacing
        }
    }
}

/// Views in a row, laid out as an `HStack` lays them out and centred on the
/// row's middle. Its own width is its children's ideal unless `flexible`.
@MainActor final class HStackView: NSView, PiKit.WidthSizing {
    var spacing: CGFloat
    /// Takes the width it is given (it holds a field), rather than its ideal.
    var flexible: Bool
    /// The children and how each sizes; built when asked, so it reads the
    /// views as they are now.
    var items: () -> [StackLayout.Item] = { [] } { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    init(spacing: CGFloat, flexible: Bool = false, views: [NSView] = []) {
        self.spacing = spacing; self.flexible = flexible
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { StackLayout.height(items(), spacing: spacing, width: width) }
    override var intrinsicContentSize: NSSize {
        let items = items()
        return NSSize(width: flexible ? NSView.noIntrinsicMetric : StackLayout.width(items, spacing: spacing, proposal: .infinity),
                      height: StackLayout.height(items, spacing: spacing, width: bounds.width > 0 ? bounds.width : .infinity))
    }
    override func layout() {
        super.layout()
        StackLayout.place(items(), spacing: spacing, in: bounds, scale: piScale)
    }
}

/// A control that knows when it may be used, whatever the form says.
@MainActor protocol OwnEnabled: NSControl { var ownEnabled: Bool { get } }

/// Walks a view's controls and sets them enabled as the screen says, each
/// also needing its own reason (`.disabled(…)` on a whole form, over each
/// control's own `.disabled`).
@MainActor final class EnabledState {
    private var own: [ObjectIdentifier: Bool] = [:]
    /// A control's own state, before the form's.
    func set(_ control: NSControl, _ enabled: Bool) { own[ObjectIdentifier(control)] = enabled }
    /// Applies the form's state under `root`: a control is enabled when the
    /// form is and its own state allows (what was set here, or what the
    /// control says of itself).
    func apply(to root: NSView, formEnabled: Bool) {
        for control in PiKit.controls(in: root) {
            let own = self.own[ObjectIdentifier(control)] ?? (control as? OwnEnabled)?.ownEnabled ?? true
            let enabled = formEnabled && own
            if control.isEnabled != enabled { control.isEnabled = enabled }
        }
    }
    /// The form's state over hosted SwiftUI too.
    var formEnabled = true
}

/// Text reads to VoiceOver as SwiftUI's `Text` did: its words as the static
/// text's value, with no name of its own, so a control named after the same
/// words is the only element named so. (`PiKit.TextLine` and `WrappedText`
/// do so themselves now; this moves the words over for `TextBlock`.)
@MainActor enum StaticTextAccessibility {
    static func asValues(in view: NSView) {
        if view is PiKit.TextLine || view is PiKit.WrappedText || view is TextBlock {
            let words = view.accessibilityLabel() ?? ""
            if !words.isEmpty { view.setAccessibilityValue(words); view.setAccessibilityLabel(nil) }
        }
        for subview in view.subviews { asValues(in: subview) }
    }
}

/// A control that, like a SwiftUI view, takes a width of its own choosing
/// for each width it is offered (a flow of chips).
@MainActor protocol ProposedWidthSizing: AnyObject { func width(forProposal proposal: CGFloat) -> CGFloat }

/// One settings row as SwiftUI's `PiRow` laid it out: the label (and a
/// quieter detail) at least 180 points wide on the left, the control in a
/// frame up to 380 wide on the right, 16 apart, inside 16 by 10 points,
/// sharing the width as `HStack` shares it; a hairline under it, 16 in,
/// unless it is the last. `PiKit.Row` now shares the width the same way;
/// this one stays for what it adds: controls that size to what they are
/// offered (`ProposedWidthSizing`), `TextBlock` text and any row in a
/// `SettingsCard`.
@MainActor final class SettingsRow: NSView, PiKit.WidthSizing {
    let label: String, detail: String?
    let control: NSView?
    let last: Bool
    private let labelView: TextBlock
    private let detailView: TextBlock?
    private let rule = HairlineView()
    init(label: String, detail: String? = nil, last: Bool = false, control: NSView?) {
        self.label = label; self.detail = detail; self.control = control; self.last = last
        labelView = TextBlock(label, font: PiKit.Font.body, color: .piInk)
        detailView = detail.map { TextBlock($0, font: PiKit.Font.caption, color: .piInkSecondary) }
        super.init(frame: .zero)
        for view in [labelView, detailView, control].compactMap({ $0 }) as [NSView] { addSubview(view) }
        if !last { addSubview(rule) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// A wrapping text's width when offered `width`: its widest line there.
    private func textWidth(_ block: TextBlock, _ width: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return PiKit.wrappedLines(block.text, font: block.font, width: width).map { PiKit.Line($0, font: block.font, color: .black).size(scale: scale).width }.max() ?? 0
    }
    private var textItem: StackLayout.Item {
        StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { [weak self] proposal in
            guard let self else { return 0 }
            let offered = max(proposal, 180)
            let width = max(self.textWidth(self.labelView, offered), self.detailView.map { self.textWidth($0, offered) } ?? 0)
            return max(180, min(width, offered))
        }, height: { [weak self] width in self?.textHeight(width) ?? 0 }))
    }
    private func textHeight(_ width: CGFloat) -> CGFloat {
        labelView.height(forWidth: width) + (detailView.map { 2 + $0.height(forWidth: width) } ?? 0)
    }
    /// The control's frame: as wide as offered up to 380, never narrower than a control of fixed width.
    private var controlItem: StackLayout.Item? {
        guard let control else { return nil }
        if let sized = control as? ProposedWidthSizing {
            // The frame takes what it is offered up to 380; what is in it, its own width there.
            return StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { proposal in
                min(380, max(sized.width(forProposal: 0), proposal.isFinite ? proposal : 380))
            }, height: { width in PiKit.height(of: control, width: sized.width(forProposal: width)) }))
        }
        return StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { proposal in
            let ideal = control.intrinsicContentSize.width
            let least = ideal == NSView.noIntrinsicMetric ? 0 : ideal
            return min(380, max(least, proposal.isFinite ? proposal : 380))
        }, height: { width in
            let ideal = control.intrinsicContentSize.width
            return PiKit.height(of: control, width: ideal == NSView.noIntrinsicMetric ? width : min(ideal, width))
        }))
    }
    private var items: [StackLayout.Item] { [textItem, .spacer(0)] + (controlItem.map { [$0] } ?? []) }
    func height(forWidth width: CGFloat) -> CGFloat {
        StackLayout.height(items, spacing: PiSpacing.lg, width: width - PiSpacing.lg * 2) + 20 + (last ? 0 : 1)
    }
    override func layout() {
        super.layout()
        let inner = CGRect(x: PiSpacing.lg, y: 10, width: bounds.width - PiSpacing.lg * 2, height: bounds.height - 20 - (last ? 0 : 1))
        let frames = StackLayout.place(items, spacing: PiSpacing.lg, in: inner, scale: piScale)
        let text = frames[0]
        let labelHeight = labelView.height(forWidth: text.width)
        labelView.frame = CGRect(x: text.minX, y: text.minY, width: text.width, height: labelHeight)
        if let detailView { detailView.frame = CGRect(x: text.minX, y: text.minY + labelHeight + 2, width: text.width, height: detailView.height(forWidth: text.width)) }
        if let control, frames.count > 2 {
            // The control at the trailing edge of its frame, at its own width when it has one.
            let frame = frames[2], ideal = control.intrinsicContentSize.width
            let width = (control as? ProposedWidthSizing)?.width(forProposal: frame.width)
                ?? (ideal == NSView.noIntrinsicMetric ? frame.width : min(ideal, frame.width))
            let height = PiKit.height(of: control, width: width)
            control.frame = CGRect(x: frame.maxX - width, y: PiKit.round(inner.minY + (inner.height - height) / 2, piScale), width: width, height: height)
        }
        rule.frame = CGRect(x: PiSpacing.lg, y: bounds.height - 1, width: bounds.width - PiSpacing.lg, height: 1)
    }
}

/// Gives a `PiKit.Note` an accessibility identifier on the element VoiceOver
/// reads: its text.
@MainActor func identify(_ note: PiKit.Note, _ identifier: String) {
    note.setAccessibilityIdentifier(identifier)
    for case let field as NSTextField in note.subviews { field.setAccessibilityIdentifier(identifier) }
}

/// What the last action said, as `PiStatusLine(…).lineLimit(2)`: the note's
/// symbol and its words, at most two lines, cut at the end.
@MainActor final class StatusNote: NSView, PiKit.WidthSizing {
    let text: String, tone: PiTone
    private let icon: PiKit.SymbolView
    private let label: PiKit.SelectableText
    init(_ text: String, tone: PiTone) {
        self.text = text; self.tone = tone
        let name = tone == .danger ? "exclamationmark.triangle.fill" : tone == .warning ? "exclamationmark.circle" : "info.circle"
        icon = PiKit.SymbolView(PiKit.Symbol(name, size: 11), color: tone == .neutral ? .piInkTertiary : tone.nsColor)
        // Selectable, to copy what went wrong, and two lines at most.
        label = PiKit.SelectableText(text, font: PiKit.Font.caption, color: tone == .danger ? tone.nsColor : .piInkSecondary)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        super.init(frame: .zero)
        addSubview(icon); addSubview(label)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var iconWidth: CGFloat { icon.symbol.layoutSize.width }
    private var lineHeight: CGFloat { PiKit.Line(text, font: PiKit.Font.caption, color: .black).lineHeight }
    var naturalWidth: CGFloat {
        iconWidth + 6 + (text.components(separatedBy: "\n").map { PiKit.Line($0, font: PiKit.Font.caption, color: .black).size(scale: window?.backingScaleFactor ?? 2).width }.max() ?? 0)
    }
    private func labelHeight(_ width: CGFloat) -> CGFloat { min(label.height(forWidth: width), lineHeight * 2) }
    func height(forWidth width: CGFloat) -> CGFloat { max(labelHeight(width - iconWidth - 6), 1 + icon.symbol.layoutSize.height) }
    override func layout() {
        super.layout()
        let box = icon.symbol.layoutSize
        icon.frame = CGRect(x: 0, y: 1, width: box.width, height: box.height)
        let width = max(0, bounds.width - box.width - 6)
        // A field's cell insets its text two points; the field sits that far out.
        label.frame = CGRect(x: box.width + 6 - PiKit.fieldInset, y: 0, width: width + PiKit.fieldInset * 2, height: labelHeight(width))
    }
}

/// Wrapping text as a settings row's control: its own width up to what it
/// is offered, its lines wrapping there.
@MainActor final class RowText: NSView, PiKit.WidthSizing, ProposedWidthSizing {
    let block: TextBlock
    init(_ text: String, font: NSFont, color: NSColor) {
        block = TextBlock(text, font: font, color: color)
        super.init(frame: .zero)
        addSubview(block)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func width(forProposal proposal: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return PiKit.wrappedLines(block.text, font: block.font, width: max(1, proposal)).map { PiKit.Line($0, font: block.font, color: .black).size(scale: scale).width }.max() ?? 0
    }
    func height(forWidth width: CGFloat) -> CGFloat { block.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func layout() { super.layout(); block.frame = bounds }
}
