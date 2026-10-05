import AppKit

// A response's own lines and a finished turn's fold, drawn by AppKit: the
// one line a folded turn reads as (`TurnFoldControlRow`) and the header line
// of one chronological response (`ResponseHeaderRow`). Each reads and
// measures as the SwiftUI row it replaces.

/// A row drawing a block, not a message: the hosted row left no room above
/// or below a block, so the content is the whole row.
@MainActor class TranscriptNativeBlockRow: TranscriptNativeMessageRow {
    override class var rowTop: CGFloat { 0 }
    override class var rowBottom: CGFloat { 0 }
    var block: TranscriptBlock? { if case .block(let block) = inputs.item { return block }; return nil }
}

/// The keyboard's ring over a control: the accent's soft fill under it and
/// a thin accent line just inside it, as `TranscriptFocusRing` drew it, with
/// the marker checks look for while it shows.
@MainActor final class TranscriptNativeFocusRing {
    let fill = TranscriptPanel()
    let stroke = TranscriptPanel()
    private(set) var marker: TranscriptFocusMarkerView?
    private weak var host: NSView?
    init(host: NSView) {
        self.host = host
        fill.cornerRadius = 6; stroke.cornerRadius = 6
        fill.isHidden = true; stroke.isHidden = true
    }
    var shown: Bool { !fill.isHidden }
    func show(_ shown: Bool) {
        fill.isHidden = !shown; stroke.isHidden = !shown
        fill.fill = .piAccentSoft
        stroke.stroke = NSColor.piAccent.withAlphaComponent(0.55)
        if shown, marker == nil, let host {
            let marker = TranscriptFocusMarkerView()
            host.addSubview(marker, positioned: .below, relativeTo: stroke)
            self.marker = marker
            host.needsLayout = true
        } else if !shown, let marker {
            marker.removeFromSuperview(); self.marker = nil
        }
    }
    /// Over `rect`, the stroke inside it as `strokeBorder` draws it.
    func place(_ rect: CGRect) {
        fill.frame = rect
        stroke.frame = rect.insetBy(dx: 0.5, dy: 0.5)
        marker?.frame = rect
    }
}

// MARK: - A finished turn's fold

/// The one line a folded turn reads as, and the control that opens it: the
/// line's words and a chevron that turns, a hairline under them, the whole
/// line one button that keeps focus when it closes the turn.
@MainActor final class TranscriptNativeTurnFoldRow: TranscriptNativeBlockRow {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// The line, eight points under it, and its hairline.
    static let lineHeight: CGFloat = 24
    static let controlHeight: CGFloat = 32
    let control = TranscriptNativeTurnFoldControl()
    static func fold(of item: TranscriptItem) -> (spec: TurnFoldSpec, group: String)? {
        guard case .block(let block) = item, block.presentation == .turnFold,
              let spec = block.foldSummary, let group = block.foldControl else { return nil }
        return (spec, group)
    }
    override class func draws(_ item: TranscriptItem) -> Bool { fold(of: item) != nil }
    /// The control is never itself folded: the keyboard always has somewhere to stand.
    override var drawsNothing: Bool { false }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        addSubview(control)
        // The control is the row's one element.
        setAccessibilityElement(false)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    private var open: Bool { inputs.disclosure.turnFoldOpen }
    override func configure() {
        guard let (spec, group) = Self.fold(of: inputs.item) else { return }
        let toggle = inputs.toggle
        control.update(label: spec.label, open: open, environment: inputs.environment) { toggle(.turnFold(group)) }
    }
    override func apply(_ inputs: TranscriptRowInputs) {
        super.apply(inputs)
        setAccessibilityElement(false)
    }
    /// Four points under an open turn's line, eight under a closed one's.
    override func contentHeight(width: CGFloat) -> CGFloat { Self.controlHeight + (open ? 4 : 8) }
    override func place(in rect: CGRect) {
        control.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Self.controlHeight)
    }
}

/// The fold's button: focusable from the keyboard like a row of work, with
/// its own ring, opened by a click, Space or Return.
@MainActor final class TranscriptNativeTurnFoldControl: TranscriptNativeToggle {
    private let label = TranscriptLabel()
    private let chevron = TranscriptSymbol()
    private let hair = TranscriptPanel()
    private lazy var ring = TranscriptNativeFocusRing(host: self)
    private(set) var open = false
    private var ringShown = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = TranscriptNativeTurnFoldRow.font
        label.monospacedDigits = true
        label.truncation = .tail
        chevron.show("chevron.down", size: 10, weight: .semibold)
        chevron.square = true
        hair.cornerRadius = 0
        addSubview(ring.fill)
        for view in [label, chevron, hair] as [NSView] { addSubview(view) }
        addSubview(ring.stroke)
        setAccessibilityIdentifier("turn-fold")
    }
    required init?(coder: NSCoder) { nil }
    var isRingShown: Bool { ring.shown }

    func update(label text: String, open: Bool, environment: TranscriptRowEnvironment, toggle: @escaping () -> Void) {
        let turning = open != self.open && window != nil
        if text != label.text { needsLayout = true }
        self.open = open
        label.text = text
        set(environment: environment, toggle: toggle)
        chevron.mirroredAcross = rightToLeft
        chevron.setRotation(open ? 0 : -90, animated: turning && !PiMotion.reducesMotion)
        let help = open ? "Hide this turn's work" : "Show this turn's work"
        if toolTip != help { toolTip = help }
        setAccessibilityLabel(text)
        setAccessibilityValue(open ? "Open" : "Closed")
        setAccessibilityHelp(help)
        if !enabled { ringShown = false }
        refresh()
        needsLayout = true
    }
    override func hoverChanged() { refresh() }
    private func refresh() {
        let lit = hovering && enabled
        label.color = lit ? TranscriptNSPalette.text : TranscriptNSPalette.muted
        chevron.contentTintColor = lit ? TranscriptNSPalette.text : TranscriptNSPalette.faint
        hair.fill = TranscriptNSPalette.hair
        ring.show(ringShown && enabled)
    }
    override func layout() {
        super.layout()
        let width = bounds.width, line = TranscriptNativeTurnFoldRow.lineHeight
        let size = chevron.swiftUIFrame ?? chevron.image?.size ?? .zero
        let ideal = label.intrinsicSize, text = label
        let pieces = [TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { CGSize(width: text.width(truncatedTo: $0), height: ideal.height) }),
                      .fixed(size), .spacer(minLength: 0)]
        let spacing: [CGFloat] = [6, 6]
        let frames = TranscriptLineLayout.frames(TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width), spacing: spacing, x: 0, midY: line / 2)
        label.frame = TranscriptMotion.mirrored(frames[0], of: label, width: width, rightToLeft)
        chevron.place(in: pixelAligned(TranscriptMotion.mirrored(frames[1], width: width, rightToLeft)))
        hair.frame = CGRect(x: 0, y: bounds.height - 1, width: width, height: 1)
        ring.place(bounds)
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }

    // The keyboard: `.focusable()` puts the line in the key loop whatever the
    // system's keyboard navigation setting, and the ring shows only for
    // focus that came from the keyboard.
    override var canBecomeKeyView: Bool { enabled }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { ringShown = !hovering; refresh(); needsLayout = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { ringShown = false; refresh() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        // A click leaves no ring behind.
        ringShown = false; refresh()
        super.mouseDown(with: event)
    }
}

// MARK: - A response's header line

/// The header line of one response: what it did, and the one control that
/// folds it down to this line, as `ResponseHeaderRow` drew it. The whole
/// strip is the control for the pointer; the fold button is the one for
/// assistive technology.
@MainActor final class TranscriptNativeResponseRow: TranscriptNativeBlockRow {
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let compactFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let spinner = TranscriptSpinner()
    private let label = TranscriptLabel()
    private let button = TranscriptNativeResponseFoldButton()
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    private var pressing = false
    static func header(of item: TranscriptItem) -> (line: ResponseLine, message: TranscriptMessage, response: String, live: Bool)? {
        guard case .block(let block) = item, block.presentation == .response, let line = block.responseSummary,
              let message = block.message, let response = block.responseID else { return nil }
        return (line, message, response, block.live)
    }
    override class func draws(_ item: TranscriptItem) -> Bool { header(of: item) != nil }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        label.monospacedDigits = true
        label.truncation = .tail
        for view in [spinner, label, button] as [NSView] { addSubview(view) }
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.setHovering(inside) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    private var header: (line: ResponseLine, message: TranscriptMessage, response: String, live: Bool)? { Self.header(of: inputs.item) }
    private var collapsed: Bool { inputs.disclosure.responseLine }
    private var folded: Bool { inputs.disclosure.responseFolded }
    /// A response with nothing inside to fold keeps a short strip.
    private var compact: Bool { !(header?.line.foldable ?? false) && !collapsed }
    /// A plain answer says nothing until the pointer is over it.
    private var quiet: Bool { compact && !folded && !hovering }
    var summary: String {
        guard !quiet, let line = header?.line else { return "" }
        var parts = [line.work]
        if let duration = line.duration, !duration.isEmpty { parts.append(duration) }
        if collapsed, line.parts > 0 { parts.append("\(line.parts) " + (line.parts == 1 ? "part" : "parts") + " folded") }
        if let figures = line.figures, folded { parts.append(figures) }
        return parts.joined(separator: " · ")
    }
    private func fold() {
        guard let response = header?.response, inputs.environment.isEnabled else { return }
        inputs.toggle(.responseLine(response))
    }
    override func configure() {
        guard let header else { return }
        if !inputs.environment.isEnabled { hovering = false }
        let lit = hovering || collapsed
        label.text = summary
        label.font = compact ? Self.compactFont : Self.font
        label.color = lit ? TranscriptNSPalette.muted : TranscriptNSPalette.faint
        button.update(collapsed: collapsed, compact: compact, hovering: hovering, environment: inputs.environment) { [weak self] in self?.fold() }
        button.alphaValue = lit ? 1 : 0
        setAccessibilityLabel("Response · \(summary)")
        _ = header
    }
    override func hides(_ view: NSView) -> Bool { view === spinner && !(header?.live ?? false) }
    private func setHovering(_ value: Bool) {
        let value = value && inputs.environment.isEnabled
        guard value != hovering else { return }
        hovering = value
        configure()
        needsLayout = true
    }
    /// The strip's height: a line with nothing to say takes the room of
    /// paragraph spacing, never of a line of text.
    private var stripHeight: CGFloat { compact ? 14 : 20 }
    private var top: CGFloat { compact ? 0 : 4 }
    override func contentHeight(width: CGFloat) -> CGFloat {
        top + stripHeight + (collapsed ? 10 : compact ? 0 : 2)
    }
    /// Where the strip is, in the row.
    private var strip: CGRect {
        let total = contentHeight(width: bounds.width), height = ceil(total)
        return CGRect(x: 0, y: (height - total) / 2 + top, width: bounds.width, height: stripHeight)
    }
    override func place(in rect: CGRect) {
        let strip = CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: stripHeight)
        var pieces: [TranscriptLinePiece] = [], views: [NSView?] = []
        if header?.live == true { pieces.append(.fixed(CGSize(width: TranscriptSpinner.size, height: TranscriptSpinner.size))); views.append(spinner) }
        let ideal = label.text.isEmpty ? .zero : label.intrinsicSize, text = label
        pieces.append(TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { CGSize(width: text.text.isEmpty ? 0 : text.width(truncatedTo: $0), height: ideal.height) }))
        views.append(label)
        pieces.append(.spacer(minLength: 0)); views.append(nil)
        pieces.append(.fixed(button.size)); views.append(button)
        let spacing = [CGFloat](repeating: 4, count: pieces.count - 1)
        let frames = TranscriptLineLayout.frames(TranscriptLineLayout.sizes(pieces, spacing: spacing, width: strip.width), spacing: spacing,
                                                 x: strip.minX, midY: strip.midY)
        for (view, frame) in zip(views, frames) {
            guard let view else { continue }
            view.frame = view === label ? frame : pixelAligned(frame)
        }
    }

    // MARK: The pointer and the menu

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: strip)
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The strip is one tap target, the fold button included.
        return strip.contains(convert(point, from: superview)) ? self : hit
    }
    override func mouseDown(with event: NSEvent) {
        pressing = strip.contains(convert(event.locationInWindow, from: nil))
        if !pressing { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressing = false }
        guard pressing, strip.contains(convert(event.locationInWindow, from: nil)) else { return }
        fold()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if inputs.environment.isEnabled, button.alphaValue > 0 { addCursorRect(button.frame, cursor: .pointingHand) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let header else { return nil }
        let title = collapsed ? "Show This Response" : "Fold This Response to One Line"
        return TranscriptNativeMenus.offered(PiMenus.menu(ReplyMenu.entries(header.message, actions: inputs.actions, forks: inputs.environment.forks,
                                                                           fold: (title, { [weak self] in self?.fold() }))),
                                             enabled: inputs.environment.isEnabled)
    }
}

/// The response's fold button: two arrows meeting or parting in an 18-point
/// box that lights under the pointer.
@MainActor final class TranscriptNativeResponseFoldButton: NSView {
    private let panel = TranscriptPanel()
    private let icon = TranscriptSymbol()
    private(set) var compact = false
    private var press: () -> Void = {}
    private var enabled = true
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.cornerRadius = 5
        addSubview(panel); addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    var size: CGSize { CGSize(width: 18, height: compact ? 14 : 16) }
    func update(collapsed: Bool, compact: Bool, hovering: Bool, environment: TranscriptRowEnvironment, press: @escaping () -> Void) {
        if compact != self.compact { needsLayout = true }
        self.compact = compact; self.press = press; enabled = environment.isEnabled
        icon.show(collapsed ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left", size: 10, weight: .semibold)
        icon.contentTintColor = hovering ? TranscriptNSPalette.text : TranscriptNSPalette.faint
        panel.fill = hovering ? TranscriptNSPalette.panel : nil
        let title = collapsed ? "Show this response" : "Fold this response to one line"
        if toolTip != title { toolTip = title }
        setAccessibilityLabel(title)
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        panel.frame = bounds
        let size = icon.swiftUIFrame ?? icon.image?.size ?? .zero
        icon.place(in: TranscriptMotion.pixelAligned(CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                                            width: size.width, height: size.height), scale: window?.backingScaleFactor ?? 2))
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        press(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    // A plain button: in the key loop where keyboard navigation reaches
    // buttons, and Space or Return presses it.
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        press()
    }
}

/// A row's menu in a pane that takes no input: offered, as SwiftUI offered a
/// disabled row's menu, with every command refused.
@MainActor enum TranscriptNativeMenus {
    static func offered(_ menu: NSMenu, enabled: Bool) -> NSMenu {
        guard !enabled else { return menu }
        func refuse(_ menu: NSMenu) {
            menu.autoenablesItems = false
            for item in menu.items { item.isEnabled = false; if let submenu = item.submenu { refuse(submenu) } }
        }
        refuse(menu)
        return menu
    }
}
