import AppKit
import QuartzCore

// The composer card's own controls: the round send and stop buttons, the
// connection, model and effort pills, the banners that say an earlier or a
// queued message is being rewritten, and the slash-command list.

// MARK: - Round buttons

/// A filled circle with a symbol: Send and Stop. A plain SwiftUI button
/// before: no hover shade, and disabled it dims to half.
@MainActor final class ComposerRoundButton: PiKit.ButtonBase {
    var symbol: String { didSet { if oldValue != symbol { redrawContent() } } }
    var symbolSize: CGFloat
    var fillColor: NSColor { didSet { refreshFace() } }
    var ink: NSColor { didSet { redrawContent() } }
    /// The brand shadow under an armed Send.
    var glows = false { didSet { if oldValue != glows { refreshFace() } } }
    static let diameter: CGFloat = 30

    init(symbol: String, symbolSize: CGFloat, fill: NSColor, ink: NSColor, action: @escaping () -> Void) {
        self.symbol = symbol; self.symbolSize = symbolSize; self.fillColor = fill; self.ink = ink
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        pressScales = false
        circularCorners = true
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = action
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }
    override func drawContent(in rect: CGRect) {
        PiKit.Symbol(symbol, size: symbolSize, weight: .bold).drawPlaced(centredIn: rect, color: ink, scale: piScale)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(fillColor)
        stroke.borderColor = CGColor.clear
        shadowLayer.shadowColor = piCGColor(.piBrandOrange)
        shadowLayer.shadowOpacity = glows ? 0.24 : 0
        shadowLayer.shadowRadius = PiKit.shadowRadius(5); shadowLayer.shadowOffset = CGSize(width: 0, height: 2)
    }
    /// The short press-in and spring-back that confirms a send under the pointer.
    func pulse() {
        guard !PiKit.Motion.reduced else { return }
        let squeeze = CABasicAnimation(keyPath: "transform.scale")
        squeeze.fromValue = 1; squeeze.toValue = 0.92
        squeeze.duration = PiKit.Motion.quick; squeeze.autoreverses = false
        squeeze.timingFunction = PiKit.Motion.timing(.easeOut)
        let back = CABasicAnimation(keyPath: "transform.scale")
        back.fromValue = 0.92; back.toValue = 1
        back.beginTime = 0.12; back.duration = PiKit.Motion.quick
        back.timingFunction = PiKit.Motion.timing(.easeOut)
        let group = CAAnimationGroup()
        group.animations = [squeeze, back]; group.duration = 0.12 + PiKit.Motion.quick
        face.add(group, forKey: "pulse")
    }
}

// MARK: - Pills

/// A compact pill: an icon, an optional label cut in the middle past its
/// width, a spinner while its list loads, and the up-down chevron, on a
/// capsule that warms to the accent while an override is active.
@MainActor final class ComposerPillButton: PiKit.ButtonBase {
    var icon: String { didSet { if oldValue != icon { changed() } } }
    var text: String { didSet { if oldValue != text { changed(fade: true) } } }
    var active: Bool { didSet { if oldValue != active { refreshFace(); redrawContent() } } }
    var loading: Bool { didSet { if oldValue != loading { loadingChanged() } } }
    var maxTextWidth: CGFloat { didSet { if oldValue != maxTextWidth { changed(fade: true) } } }
    /// Icon and chevron only; the help text still names the value.
    var compact: Bool { didSet { if oldValue != compact { changed(fade: true) } } }
    private var spinner: PiSpinnerView?
    static let spacing: CGFloat = 5

    init(icon: String, text: String, active: Bool = false, loading: Bool = false, maxTextWidth: CGFloat, compact: Bool = false) {
        self.icon = icon; self.text = text; self.active = active; self.loading = loading
        self.maxTextWidth = maxTextWidth; self.compact = compact
        super.init(frame: .zero)
        pressScales = false
        // The label's own `.opacity(enabled ? 1 : 0.45)`.
        disabledOpacity = 0.45
        loadingChanged()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    private var iconSymbol: PiKit.Symbol { PiKit.Symbol(icon, size: 11, weight: .semibold) }
    private var chevron: PiKit.Symbol { PiKit.Symbol("chevron.up.chevron.down", size: 9, weight: .semibold) }
    private var line: PiKit.Line { PiKit.Line(text, font: .systemFont(ofSize: 12, weight: .medium), color: .piInk) }
    private var textWidth: CGFloat { compact || maxTextWidth <= 0 ? 0 : min(maxTextWidth, line.size(scale: piScale).width) }
    private var hPadding: CGFloat { compact ? 7 : 9 }
    override var intrinsicContentSize: NSSize {
        var pieces: [CGFloat] = [iconSymbol.layoutSize.width]
        var height = max(iconSymbol.layoutSize.height, chevron.layoutSize.height)
        if textWidth > 0 { pieces.append(textWidth); height = max(height, line.lineHeight) }
        if loading { pieces.append(10); height = max(height, 10) }
        pieces.append(chevron.layoutSize.width)
        let width = pieces.reduce(0, +) + CGFloat(pieces.count - 1) * Self.spacing + hPadding * 2
        return NSSize(width: width, height: height + 8)
    }
    private func changed(fade: Bool = false) {
        invalidateIntrinsicContentSize(); needsLayout = true
        if fade, window != nil, !PiKit.Motion.reduced {
            // The same label with new words: they cross-fade while the pill resizes once.
            let transition = CATransition(); transition.type = .fade; transition.duration = 0.18
            transition.timingFunction = PiKit.Motion.timing(.easeInOut)
            content.add(transition, forKey: "text")
        }
        redrawContent()
        PiKit.sizeChanged(self)
    }
    private func loadingChanged() {
        if loading, spinner == nil {
            let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
            view.configure(lineWidth: 1.2, turning: !PiKit.Motion.reduced)
            addSubview(view); spinner = view
        } else if !loading { spinner?.removeFromSuperview(); spinner = nil }
        changed()
    }
    override func layout() {
        super.layout()
        guard let spinner else { return }
        // The spinner sits in its 10-point slot before the chevron.
        let slotX = bounds.width - hPadding - chevron.layoutSize.width - Self.spacing - 10
        spinner.frame = CGRect(x: slotX + 2, y: PiKit.round((bounds.height - 6) / 2, piScale), width: 6, height: 6)
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        var x = hPadding
        let inner = CGRect(x: 0, y: 4, width: rect.width, height: rect.height - 8)
        let box = iconSymbol.layoutSize
        iconSymbol.drawPlaced(centredIn: CGRect(x: x, y: inner.minY, width: box.width, height: inner.height), color: active ? .piAccent : .piInkSecondary, scale: scale)
        x += box.width + Self.spacing
        if textWidth > 0 {
            let size = line.size(scale: scale)
            line.draw(in: CGRect(x: x, y: inner.minY + PiKit.round((inner.height - size.height) / 2, scale), width: textWidth, height: size.height),
                      truncation: .middle, scale: scale)
            x += textWidth + Self.spacing
        }
        if loading { x += 10 + Self.spacing }
        let chevronBox = chevron.layoutSize
        chevron.drawPlaced(centredIn: CGRect(x: x, y: inner.minY, width: chevronBox.width, height: inner.height), color: .piInkTertiary, scale: scale)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(active ? .piAccentSoft : .piSurface)
        stroke.borderColor = piCGColor(active ? NSColor.piAccent.withAlphaComponent(0.45) : .piHairlineStrong)
    }
}

// MARK: - Banners

/// The strip above the composer field while an earlier message, or a queued
/// one, is being rewritten in it: what is happening, Cancel (Escape), and a
/// line of detail under it.
@MainActor final class ComposerEditBanner: NSView, PiKit.WidthSizing {
    let cancel: PiKit.Button
    private let title: PiKit.TextLine
    private let detail: ShellText
    private let spinner: PiSpinnerView
    private let review: PiKit.Button
    private let box: PiKit.Box
    private let stack: ShellStack
    private let row: ShellStack

    init(title text: String, accessibilityName: String, cancel: @escaping () -> Void, review: @escaping () -> Void = {}) {
        self.cancel = PiKit.Button("Cancel", style: .ghost, action: cancel)
        title = PiKit.TextLine(PiKit.Line(text, font: .systemFont(ofSize: 11.5, weight: .semibold), color: .labelColor))
        detail = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
        spinner = PiKit.spinner(controlSize: .mini)
        spinner.setAccessibilityLabel("Waiting for the helper")
        self.review = PiKit.Button("Use text only / I've reselected the needed inputs", style: .ghost, action: review)
        row = ShellStack(.horizontal, spacing: 6, [
            .view(PiKit.SymbolView(PiKit.Symbol("pencil.line", size: 13), color: .piAccent)),
            .view(title),
            .spacer(4),
            .view(spinner),
            .view(self.cancel),
        ])
        stack = ShellStack(.vertical, spacing: 4, padding: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8), [
            .view(row, .fill), .view(detail, .fill), .view(self.review),
        ])
        box = PiKit.Box(fill: .piAccentSoft, cornerRadius: 10, content: stack)
        super.init(frame: .zero)
        addSubview(box)
        spinner.isHidden = true; self.review.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(accessibilityName)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// Sets what it says and offers; returns whether anything changed.
    func update(title text: String? = nil, detail value: String, detailColor: NSColor = .piInkSecondary, maximumLines: Int = .max,
                waiting: Bool = false, cancelEnabled: Bool, offersReview: Bool = false, reviewEnabled: Bool = true) {
        var changed = false
        if let text, title.line.text != text { title.line.text = text; changed = true }
        if detail.runs != [ShellText.Run(text: value, color: detailColor)] { detail.set(value, color: detailColor); changed = true }
        if detail.maximumLines != maximumLines { detail.maximumLines = maximumLines; changed = true }
        if spinner.isHidden == waiting { spinner.isHidden = !waiting; changed = true }
        if cancel.isEnabled != cancelEnabled { cancel.isEnabled = cancelEnabled }
        if review.isHidden == offersReview { review.isHidden = !offersReview; changed = true }
        if review.isEnabled != reviewEnabled { review.isEnabled = reviewEnabled }
        if changed { stack.relayoutAll(); invalidateIntrinsicContentSize(); needsLayout = true }
    }
    /// The banner sits eight points in from the card's sides and top.
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: box, width: width - 16) + 8 }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        box.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: max(0, bounds.height - 8))
    }
}

// MARK: - The slash-command list

/// The slash-command list's rows: the height and highlight of a Pi list row.
enum SlashCompletionMetrics {
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    static let inset = PiSpacing.xs
    /// Eight rows show before the list scrolls.
    static let visibleRows = 8
    static func listHeight(count: Int) -> CGFloat {
        let rows = CGFloat(min(visibleRows, max(1, count)))
        return rows * rowHeight + (rows - 1) * rowSpacing + 2 * inset
    }
}

/// One command or skill: its symbol, its name, and where it comes from. The
/// selected row takes the accent wash the keyboard moves; the pointer's row
/// takes the fill every other Pi list uses for hover.
@MainActor final class SlashCompletionRowView: PiKit.ButtonBase {
    private(set) var choice: CommandCompletion
    var selected: Bool { didSet { if oldValue != selected { refreshFace(); redrawContent() } } }
    init(choice: CommandCompletion, selected: Bool, action: @escaping () -> Void) {
        self.choice = choice; self.selected = selected
        super.init(frame: .zero)
        pressScales = false
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = action
        apply(choice)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// Takes the newest choice for its press, without drawing again.
    func payload(_ choice: CommandCompletion) { self.choice = choice }
    func apply(_ choice: CommandCompletion) {
        self.choice = choice
        toolTip = choice.detail
        setAccessibilityLabel("/" + choice.name + ", " + choice.detail)
        redrawContent()
    }
    override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
    override func styleFace() {
        fill.backgroundColor = piCGColor(selected ? .piAccentSoft : hovering ? .piFill : .clear)
        stroke.borderColor = CGColor.clear
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        let glyph = PiKit.Symbol(choice.skill == nil ? "terminal" : "command", size: 11.5, weight: .semibold)
        var x = PiSpacing.sm
        glyph.draw(centredIn: CGRect(x: x, y: 0, width: 16, height: rect.height), color: selected ? .piAccent : .piInkSecondary, scale: scale)
        x += 16 + PiSpacing.sm
        let name = PiKit.Line("/" + choice.name, font: .systemFont(ofSize: 13, weight: .semibold), color: .piInk)
        let detail = PiKit.Line(choice.detail, font: PiKit.Font.caption, color: .piInkSecondary)
        let room = rect.width - x - PiSpacing.sm
        // The name first in line for room, the detail cut in the middle.
        let nameSize = name.size(scale: scale), detailSize = detail.size(scale: scale)
        let least = PiKit.Line("…", font: PiKit.Font.caption, color: .piInkSecondary).size(scale: scale).width
        let fits = nameSize.width + PiSpacing.sm + detailSize.width <= room
        let nameWidth = fits ? nameSize.width : min(nameSize.width, max(0, room - PiSpacing.sm - least))
        name.draw(in: CGRect(x: x, y: PiKit.round((rect.height - nameSize.height) / 2, scale), width: nameWidth, height: nameSize.height), scale: scale)
        x += nameWidth + PiSpacing.sm
        let detailWidth = min(detailSize.width, max(0, rect.width - PiSpacing.sm - x))
        detail.draw(in: CGRect(x: x, y: PiKit.round((rect.height - detailSize.height) / 2, scale), width: detailWidth, height: detailSize.height),
                    truncation: .middle, scale: scale)
    }
}

/// The list itself, in the chrome of the other Pi popovers: the surface, a
/// strong hairline and the hover card's shadow. It floats above the
/// composer's top edge rather than taking part in the pane's layout.
@MainActor final class SlashCompletionListView: NSView {
    /// The surface, clipped to its shape with its outline inside it: SwiftUI
    /// clipped the stroked shape, so only the stroke's inner half shows.
    private let card = PiKit.Box(fill: .piSurface, cornerRadius: PiRadius.md)
    private let body = ListBody()
    private let scroll = NSScrollView()
    private let document = ListBody()
    private let status = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkTertiary))
    private let notice = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
    private let retry: PiKit.Button
    private let all: PiKit.Button
    private let footer: ShellStack
    private let divider = CALayer()
    private var rows: [String: SlashCompletionRowView] = [:]
    private var order: [String] = []
    private var selection: String?
    var choose: ((CommandCompletion) -> Void)?
    var onRetry: (() -> Void)?
    var onAllSkills: (() -> Void)?

    final class ListBody: NSView { override var isFlipped: Bool { true } }

    init() {
        retry = PiKit.Button("Retry", style: .ghost)
        all = PiKit.Button("All Skills…", style: .ghost)
        footer = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: PiSpacing.xs, left: PiSpacing.md, bottom: PiSpacing.xs, right: PiSpacing.md),
                            [.view(status, .flexible), .spacer(PiSpacing.sm), .view(self.retry), .view(all)])
        super.init(frame: .zero)
        retry.onPress = { [weak self] in self?.onRetry?() }
        all.onPress = { [weak self] in self?.onAllSkills?() }
        card.clipsContent = true
        card.shadowColor = .piShadow; card.shadowRadius = 10; card.shadowOffsetY = 3
        card.content = body
        addSubview(card)
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        body.addSubview(scroll); body.addSubview(footer); body.addSubview(notice)
        body.wantsLayer = true; body.layer?.addSublayer(divider)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Slash command suggestions")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// What the list last showed: an update that changes none of it is left alone.
    private var shownKey: [String] = []
    /// Shows `choices` with `selection` washed, and the catalog's state.
    /// Returns whether anything it shows changed (and it laid out again).
    @discardableResult
    func update(choices: [CommandCompletion], selection: String?, catalog: SkillCatalog, enabled: Bool = true) -> Bool {
        let key = choices.map { $0.id + "\u{1}" + $0.name + "\u{1}" + $0.detail + ($0.skill == nil ? "" : "\u{1}s") }
            + ["\(selection ?? "")", "\(catalog.state)", catalog.notice, "\(enabled)"]
        guard key != shownKey else {
            // Nothing it shows changed; each row's choice (its skill descriptor) is still the newest.
            for choice in choices { rows[choice.id]?.payload(choice) }
            return false
        }
        shownKey = key
        for button in [retry, all] { button.isEnabled = enabled }
        let ids = choices.map(\.id)
        var kept: [String: SlashCompletionRowView] = [:]
        for choice in choices {
            let row = rows[choice.id] ?? SlashCompletionRowView(choice: choice, selected: false) { [weak self] in
                guard let self, let current = self.rows[choice.id]?.choice else { return }
                self.choose?(current)
            }
            if row.choice.name != choice.name || row.choice.detail != choice.detail || (row.choice.skill == nil) != (choice.skill == nil) { row.apply(choice) }
            else { row.payload(choice) }
            row.selected = choice.id == selection
            row.isEnabled = enabled
            kept[choice.id] = row
            if row.superview !== document { document.addSubview(row) }
        }
        for (id, row) in rows where kept[id] == nil { row.removeFromSuperview() }
        rows = kept
        let moved = ids != order
        order = ids
        status.line.text = catalog.state == .loading ? "Discovering skills…" : catalog.state == .failed ? "Discovery failed"
            : choices.isEmpty ? "No matches" : "\(choices.count) results · ↑↓ Choose · Tab/Return Select"
        retry.isHidden = !(catalog.state == .failed || catalog.state == .partial)
        notice.set(catalog.notice, color: .piInkSecondary)
        notice.toolTip = catalog.notice
        notice.isHidden = catalog.notice.isEmpty || catalog.state == .loading
        footer.relayoutAll()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selection != self.selection || moved, let id = selection, let row = rows[id] {
            // As `scrollTo(id)`: only as far as it takes to show the row.
            row.scrollToVisible(row.bounds)
        }
        self.selection = selection
        return true
    }

    private var listHeight: CGFloat { SlashCompletionMetrics.listHeight(count: order.count) }
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = listHeight + 1 + PiKit.height(of: footer, width: width)
        if !notice.isHidden { height += notice.height(forWidth: width - PiSpacing.md * 2) + PiSpacing.sm }
        return height
    }
    override func layout() {
        super.layout()
        card.frame = bounds
        let width = bounds.width
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: listHeight)
        let inset = SlashCompletionMetrics.inset
        var y = inset
        for id in order {
            rows[id]?.frame = CGRect(x: inset, y: y, width: width - inset * 2, height: SlashCompletionMetrics.rowHeight)
            y += SlashCompletionMetrics.rowHeight + SlashCompletionMetrics.rowSpacing
        }
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(listHeight, y - SlashCompletionMetrics.rowSpacing + inset))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 0, y: listHeight, width: width, height: 1)
        divider.backgroundColor = piCGColor(.piHairline)
        body.layer?.cornerRadius = PiRadius.md; body.layer?.cornerCurve = .continuous
        body.layer?.borderWidth = 0.5; body.layer?.borderColor = piCGColor(.piHairlineStrong)
        CATransaction.commit()
        let footerHeight = PiKit.height(of: footer, width: width)
        footer.frame = CGRect(x: 0, y: listHeight + 1, width: width, height: footerHeight)
        if !notice.isHidden {
            notice.frame = CGRect(x: PiSpacing.md, y: footer.frame.maxY, width: width - PiSpacing.md * 2,
                                  height: notice.height(forWidth: width - PiSpacing.md * 2))
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}
