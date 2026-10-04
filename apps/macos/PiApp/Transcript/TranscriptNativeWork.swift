import AppKit

/// The one line every piece of work reads as, drawn by AppKit exactly as
/// `TranscriptWorkRow` draws its line: `[icon] Title · summary   suffix  0.4s`,
/// 24 points tall, the whole line a button for the pointer and the keyboard.
/// The icon cross-fades into the chevron under the pointer; an open row is the
/// chevron outright. A failed or stopped call shows its dot in the icon's
/// place, a running one sweeps slowly.
@MainActor final class TranscriptNativeWorkLine: NSView {
    struct Content: Equatable {
        var icon: String
        var title: String
        var summary = ""
        var suffix: String? = nil
        var state: TranscriptRowState = .ok
        var expandable = true
        var open = false
        var trailing: String? = nil
        /// The summary elides its beginning: a line still being written.
        var follow = false
        var help: String? = nil
        /// Whether the summary is the file's path, and so the link.
        var linksSummary = true
    }
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let summaryFont = NSFont.systemFont(ofSize: 12.5)
    static let trailingFont = NSFont.systemFont(ofSize: 11.5)
    static let iconSize: CGFloat = 12
    static let chevronSize: CGFloat = 11

    private(set) var content = Content(icon: "circle", title: "")
    var toggle: () -> Void = {}
    /// Opens the row's file; VoiceOver has it as the row's "Open File".
    private(set) var link: (() -> Void)?
    private(set) var enabled = true
    private(set) var rightToLeft = false
    /// Under Reduce Motion nothing sweeps and nothing turns.
    var reduceMotion = PiMotion.reducesMotion

    private let focusFill = TranscriptPanel()
    private let hoverPanel = TranscriptPanel()
    private let shimmer = TranscriptShimmer()
    private let dot = TranscriptPanel()
    private let icon = TranscriptSymbol()
    private let chevron = TranscriptSymbol()
    private let title = TranscriptLabel()
    private let separator = TranscriptPanel()
    private let summary = TranscriptLabel()
    private let suffix = TranscriptLabel()
    private let trailing = TranscriptLabel()
    private var trigger: PiPopoverTriggerButton?
    private let focusStroke = TranscriptPanel()
    /// Kept while the ring shows, where checks look for a row's focus ring.
    private var marker: TranscriptFocusMarkerView?
    private var hover: TranscriptHoverTracker!
    private(set) var hovering = false
    /// Whether the ring shows: only for focus that came from the keyboard.
    private(set) var ringShown = false
    private var pressing = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for panel in [focusFill, hoverPanel, focusStroke] { panel.cornerRadius = 6 }
        dot.cornerRadius = nil; dot.circular = true
        separator.cornerRadius = 1
        title.font = Self.titleFont
        summary.font = Self.summaryFont
        suffix.font = Self.summaryFont; suffix.monospacedDigits = true
        trailing.font = Self.trailingFont; trailing.monospacedDigits = true
        chevron.show("chevron.down", size: Self.chevronSize, weight: .semibold)
        // Square, so the chevron can turn inside its own bounds.
        chevron.square = true
        for view in [focusFill, hoverPanel, shimmer, dot, icon, chevron, title, separator, summary, suffix, trailing, focusStroke] as [NSView] {
            addSubview(view)
        }
        focusFill.isHidden = true; focusStroke.isHidden = true
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.setHovering(inside) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ next: Content, link: (() -> Void)?, toggle: @escaping () -> Void, environment: TranscriptRowEnvironment) {
        self.toggle = toggle
        self.link = link
        let changed = next != content || enabled != environment.isEnabled || rightToLeft != (environment.layoutDirection == .rightToLeft)
        // Opening and closing turn the chevron and cross-fade the icon, as
        // SwiftUI animated them; anything else is set as it is.
        let turning = next.open != content.open && window != nil
        content = next
        enabled = environment.isEnabled
        rightToLeft = environment.layoutDirection == .rightToLeft
        if !enabled { setHovering(false) }
        if !(next.expandable && enabled), window?.firstResponder === self { window?.makeFirstResponder(nil) }
        configure(animated: turning)
        if changed { needsLayout = true }
    }

    private var summaryLinks: Bool { link != nil && content.linksSummary && !content.summary.isEmpty }

    private func configure(animated: Bool) {
        let content = content
        title.text = content.title
        title.color = hovering ? TranscriptNSPalette.text : TranscriptNSPalette.muted
        summary.text = content.summary
        summary.truncation = content.follow ? .head : .tail
        summary.color = content.state == .failed ? TranscriptNSPalette.danger : TranscriptNSPalette.faint
        suffix.text = content.suffix ?? ""
        suffix.color = TranscriptNSPalette.faint
        trailing.text = content.trailing ?? ""
        trailing.color = TranscriptNSPalette.faint
        separator.fill = TranscriptNSPalette.faint
        hoverPanel.fill = hovering ? TranscriptNSPalette.panel : nil
        // The leading box: the dot, or the icon and the chevron it becomes.
        let marked = content.state == .failed || content.state == .stopped
        dot.fill = content.state == .failed ? TranscriptNSPalette.danger : TranscriptNSPalette.warning
        icon.show(content.icon, size: Self.iconSize, weight: .medium)
        icon.contentTintColor = content.state == .running ? TranscriptNSPalette.accent : TranscriptNSPalette.faint
        chevron.contentTintColor = hovering ? TranscriptNSPalette.text : TranscriptNSPalette.faint
        dot.isHidden = !marked; icon.isHidden = marked
        chevron.isHidden = !content.expandable
        let animate = animated && !reduceMotion
        Self.set(icon, alpha: content.expandable && (content.open || hovering) ? 0 : 1, animated: animate)
        Self.set(chevron, alpha: content.open || hovering ? 1 : 0, animated: animate)
        chevron.setRotation(content.open ? 0 : -90, animated: animate)
        for view in [separator, summary] as [NSView] { view.isHidden = content.summary.isEmpty }
        suffix.isHidden = content.suffix == nil
        trailing.isHidden = (content.trailing ?? "").isEmpty
        shimmer.isHidden = content.state != .running || reduceMotion
        shimmer.running = !shimmer.isHidden
        configureLink()
        configureRing()
        // What assistive technology hears and what the pointer says.
        setAccessibilityLabel([content.state.spokenStatus, content.title, content.summary, content.suffix]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(content.expandable ? (content.open ? "Open" : "Closed") : "")
        let help = content.help ?? content.summary
        setAccessibilityHelp(help.isEmpty ? nil : help)
        if toolTip != (help.isEmpty ? nil : help) { toolTip = help.isEmpty ? nil : help }
        setAccessibilityCustomActions(link == nil ? nil : [NSAccessibilityCustomAction(name: "Open File") { [weak self] in
            guard let self, self.enabled, let link = self.link else { return false }
            link(); return true
        }])
    }
    private static func set(_ view: NSView, alpha: CGFloat, animated: Bool) {
        guard view.alphaValue != alpha else { return }
        guard animated else { view.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TranscriptRowChrome.chevronSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }
    }
    /// The summary's own press target, when the summary is the file's path.
    private func configureLink() {
        if summaryLinks {
            let trigger = self.trigger ?? {
                let trigger = PiPopoverTriggerButton(frame: .zero)
                trigger.setAccessibilityIdentifier("transcript-open-file")
                // The row is the one accessible element; its "Open File" is the link.
                trigger.setAccessibilityElement(false)
                addSubview(trigger, positioned: .below, relativeTo: focusStroke)
                self.trigger = trigger
                return trigger
            }()
            let label = "Open \(content.summary)"
            trigger.setAccessibilityLabel(label)
            let help = content.help ?? label
            if trigger.toolTip != help { trigger.toolTip = help }
            trigger.onHover = { [weak self] inside in self?.summary.underlined = inside }
            trigger.onPress = { [weak self] _ in self?.link?() }
            trigger.isEnabled = enabled
        } else if let trigger {
            trigger.removeFromSuperview(); self.trigger = nil
            summary.underlined = false
        }
    }
    private func configureRing() {
        let shown = ringShown && content.expandable
        focusFill.isHidden = !shown; focusStroke.isHidden = !shown
        focusFill.fill = .piAccentSoft
        focusStroke.stroke = NSColor.piAccent.withAlphaComponent(0.55)
        if shown, marker == nil {
            let marker = TranscriptFocusMarkerView()
            addSubview(marker, positioned: .below, relativeTo: focusStroke)
            self.marker = marker
            needsLayout = true
        } else if !shown, let marker {
            marker.removeFromSuperview(); self.marker = nil
        }
    }
    private func setHovering(_ value: Bool) {
        let value = value && enabled
        guard value != hovering else { return }
        hovering = value
        configure(animated: true)
    }

    // MARK: Geometry

    /// The line as SwiftUI's `HStack` shares it out: the leading box and its
    /// gap, the title, the dot and the summary (which gives way first), the
    /// suffix, a spacer of at least 4 points, and the trailing figure.
    private func pieces() -> (pieces: [TranscriptLinePiece], views: [NSView?]) {
        var pieces: [TranscriptLinePiece] = [.fixed(CGSize(width: TranscriptRowChrome.indent, height: TranscriptRowChrome.leading)),
                                             .fixed(title.intrinsicSize)]
        var views: [NSView?] = [nil, title]
        if !content.summary.isEmpty {
            let ideal = summary.intrinsicSize, label = summary
            pieces.append(.fixed(CGSize(width: 18, height: 2))); views.append(separator)
            pieces.append(TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { CGSize(width: label.width(truncatedTo: $0), height: ideal.height) }))
            views.append(summary)
        }
        if content.suffix != nil {
            let size = suffix.intrinsicSize
            pieces.append(.fixed(CGSize(width: size.width + 8, height: size.height))); views.append(suffix)
        }
        pieces.append(.spacer(minLength: 4)); views.append(nil)
        if !(content.trailing ?? "").isEmpty { pieces.append(.fixed(trailing.intrinsicSize)); views.append(trailing) }
        return (pieces, views)
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = TranscriptRowChrome.height
        let line = CGRect(x: 0, y: 0, width: width, height: height)
        let (pieces, views) = pieces()
        let spacing = [CGFloat](repeating: 0, count: max(0, pieces.count - 1))
        let sizes = TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width)
        let frames = TranscriptLineLayout.frames(sizes, spacing: spacing, x: 0, midY: height / 2)
        var placed: [NSView] = []
        func put(_ view: NSView, _ frame: CGRect) { view.frame = frame; placed.append(view) }
        for (view, frame) in zip(views, frames) {
            guard let view else { continue }
            switch view {
            case separator: put(separator, pixelAligned(CGRect(x: frame.minX + 8, y: frame.midY - 1, width: 2, height: 2)))
            case suffix: put(suffix, CGRect(x: frame.minX + 8, y: frame.minY, width: frame.width - 8, height: frame.height))
            default: put(view, frame)
            }
        }
        // The leading box, 16 points square, its marks in its middle.
        let box = CGRect(x: frames[0].minX, y: frames[0].minY, width: TranscriptRowChrome.leading, height: TranscriptRowChrome.leading)
        put(dot, pixelAligned(CGRect(x: box.midX - 3.5, y: box.midY - 3.5, width: 7, height: 7)))
        for symbol in [icon, chevron] {
            // SwiftUI's frame for the symbol, on the side the reader reads
            // from, then on the pixel grid: the symbol itself is never mirrored.
            let size = symbol.swiftUIFrame ?? symbol.image?.size ?? .zero
            let frame = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
            symbol.place(in: pixelAligned(TranscriptMotion.mirrored(frame, width: width, rightToLeft)))
        }
        for panel in [hoverPanel, shimmer, focusFill, focusStroke] as [NSView] { put(panel, line) }
        // The stroke lies inside the row, as `strokeBorder` draws it.
        focusStroke.frame = line.insetBy(dx: 0.5, dy: 0.5)
        if let marker { put(marker, line) }
        if let trigger { put(trigger, summary.frame) }
        if rightToLeft { for view in placed { view.frame = TranscriptMotion.mirrored(view.frame, of: view, width: width, true) } }
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: bounds)
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
    override func resetCursorRects() {
        if enabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    /// Who had the keyboard when the pointer came down on the row: a click
    /// opens the row and leaves focus where it was, as a button's click
    /// does, so the composer keeps its typing.
    private weak var responderBeforeClick: NSResponder?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self, let current = window?.firstResponder, current !== self {
            // A text field's editor is given back through its field.
            if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                responderBeforeClick = field
            } else {
                responderBeforeClick = current
            }
        }
        return hit
    }
    override func mouseDown(with event: NSEvent) {
        pressing = true
        if window?.firstResponder === self, let before = responderBeforeClick, before !== self {
            ringShown = false; configureRing()
            window?.makeFirstResponder(before)
        }
        responderBeforeClick = nil
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressing = false }
        guard pressing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func activate() {
        guard content.expandable, enabled else { return }
        toggle()
    }

    // MARK: The keyboard

    override var acceptsFirstResponder: Bool { content.expandable && enabled }
    override var canBecomeKeyView: Bool { content.expandable && enabled }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { ringShown = !hovering; configureRing(); needsLayout = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { ringShown = false; configureRing() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        // Space and Return open the row; everything else is the conversation's.
        guard content.expandable, enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        toggle()
    }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool {
        guard content.expandable, enabled else { return false }
        toggle(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
}

/// A slow band of light crossing a running row, moved by the render server:
/// nothing on the main thread runs for it. It paints over the row and decides
/// no geometry, so it cannot move anything.
@MainActor final class TranscriptShimmer: NSView {
    private let band = CAGradientLayer()
    var running = false {
        didSet {
            guard running != oldValue else { return }
            if !running { band.removeAnimation(forKey: "sweep") }
            needsDisplay = true
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
    override func layout() { super.layout(); needsDisplay = true }
    override func updateLayer() {
        let width = max(1, bounds.width), wide = min(300, width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            band.colors = [NSColor.clear.cgColor, TranscriptNSPalette.panelStrong.cgColor, NSColor.clear.cgColor]
        }
        band.bounds = CGRect(x: 0, y: 0, width: wide, height: bounds.height)
        band.position = CGPoint(x: -wide / 2, y: bounds.height / 2)
        CATransaction.commit()
        let key = "sweep"
        let sweep = band.animation(forKey: key) as? CABasicAnimation
        guard running, window != nil else { band.removeAnimation(forKey: key); return }
        let to = width + wide / 2
        if (sweep?.toValue as? CGFloat) == to { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -wide / 2; animation.toValue = to
        animation.duration = TranscriptRowChrome.shimmerSeconds; animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // Every running row sweeps in step, as they did on the clock.
        animation.beginTime = CACurrentMediaTime() - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: TranscriptRowChrome.shimmerSeconds)
        band.add(animation, forKey: key)
    }
}

/// One tool call drawn natively, as `ActionRowView` draws it: its work line
/// and, while it is open, the card it opens.
@MainActor final class TranscriptNativeActionRow: NSView {
    let line = TranscriptNativeWorkLine()
    private(set) var card: TranscriptNativeCard?
    private(set) var tool: ToolView?
    private var open = false
    private var fetched: ToolInputDocument?
    private var environment = TranscriptRowEnvironment()
    private var cardModel: ActionRowView.Card?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// Takes the call as it is now. `openFile` opens a file at its lines.
    func update(tool: ToolView, open: Bool, fetched: ToolInputDocument?, environment: TranscriptRowEnvironment,
                toggle: @escaping () -> Void, openFile: ((String, ClosedRange<Int>?) -> Void)?) {
        let model = ActionRowView.model(of: tool)
        let link: (() -> Void)? = {
            guard environment.opensFiles, let openFile, let file = model.file else { return nil }
            return { openFile(file.path, file.lines) }
        }()
        TranscriptAppearance.apply(environment, to: self)
        let content = TranscriptNativeWorkLine.Content(icon: model.icon, title: model.title, summary: model.summary, suffix: model.suffix,
                                                       state: model.state, expandable: true, open: open, trailing: model.trailing,
                                                       help: model.help, linksSummary: model.linksSummary)
        line.update(content, link: link, toggle: toggle, environment: environment)
        self.tool = tool; self.open = open; self.fetched = fetched; self.environment = environment
        // What a closed row opens costs nothing: it is not built at all.
        if open {
            let next = ActionRowView.card(of: tool, fetched: fetched, model: model, linked: link != nil)
            if card == nil || !TranscriptNativeCard.sameKind(cardModel, next) {
                card?.removeFromSuperview()
                let made = TranscriptNativeCard.make(next)
                addSubview(made); card = made
            }
            card?.update(next, link: link, environment: environment)
            cardModel = next
        } else if let card {
            card.removeFromSuperview(); self.card = nil; cardModel = nil
        }
        needsLayout = true
    }
    /// Called when the open card changed its own height (a diff expanded,
    /// a disclosure opened), so whoever placed the row measures it again.
    var sizeChanged: () -> Void = {}
    func cardChangedSize() {
        needsLayout = true
        sizeChanged()
    }
    /// The row's height at `width`, unrounded: the line and its open card.
    func height(width: CGFloat) -> CGFloat {
        TranscriptRowChrome.height + (card?.height(width: width) ?? 0)
    }
    override func layout() {
        super.layout()
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TranscriptRowChrome.height)
        if let card { card.frame = CGRect(x: 0, y: TranscriptRowChrome.height, width: bounds.width, height: card.height(width: bounds.width)) }
    }
}

extension TranscriptSymbol {
    /// Turns the symbol about its middle, in degrees clockwise on screen.
    func setRotation(_ degrees: CGFloat, animated: Bool) {
        guard rotation != degrees else { return }
        guard animated else { rotation = degrees; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TranscriptRowChrome.chevronSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().rotation = degrees
        }
    }
}
