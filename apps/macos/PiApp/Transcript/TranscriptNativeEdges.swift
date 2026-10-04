import AppKit

// The edges' controls, drawn by AppKit as the SwiftUI views before them
// were (`TranscriptEdges.swift` says what each edge shows and when). Each
// reports the size SwiftUI gave it, so the pane places it where it stood.

/// A word to press inside an edge control (`TranscriptEdgeLinkStyle`): accent
/// text that lights up on hover in a soft capsule, eight points either side
/// and four above and below. The quiet form reads in the muted ink until
/// the pointer is over it. It may carry a symbol before the words, as a
/// `Label` does.
@MainActor final class TranscriptEdgeLinkButton: NSView {
    static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let quietFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    let title: String
    let quiet: Bool
    var perform: () -> Void
    var enabled = true
    private let face = TranscriptPanel()
    private let label = TranscriptLabel()
    private let icon = TranscriptSymbol()
    private let symbolName: String?
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var pressed = false { didSet { alphaValue = pressed ? 0.7 : 1 } }
    override var isFlipped: Bool { true }

    init(title: String, quiet: Bool = false, symbol: String? = nil, perform: @escaping () -> Void) {
        self.title = title; self.quiet = quiet; self.perform = perform; symbolName = symbol
        super.init(frame: .zero)
        face.cornerRadius = nil
        addSubview(face); addSubview(label)
        label.text = title; label.font = quiet ? Self.quietFont : Self.font
        if let symbol {
            icon.show(symbol, size: 11.5, weight: quiet ? .medium : .semibold)
            addSubview(icon)
        }
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    /// The symbol's outline and the eight points SwiftUI's `Label` leaves
    /// after it (as `TranscriptPillButton` measured).
    private var glyph: CGRect? { icon.image.map { $0.alignmentRect } }
    private var iconWidth: CGFloat { glyph.map { $0.width + 8 } ?? 0 }
    private var labelHeight: CGFloat {
        let line = label.intrinsicSize.height
        guard let image = icon.image else { return line }
        return symbolName.flatMap { TranscriptPillButton.swiftUILabelHeights[$0] } ?? max(line, (icon.swiftUIFrame?.height ?? image.size.height) + 1)
    }
    var size: CGSize { CGSize(width: iconWidth + label.intrinsicSize.width + 16, height: labelHeight + 8) }
    override var intrinsicContentSize: NSSize { size }
    override func layout() {
        super.layout()
        face.frame = bounds
        let text = label.intrinsicSize
        if let image = icon.image, let glyph {
            icon.frame = CGRect(x: 8 - glyph.minX, y: (bounds.height - glyph.height) / 2 - (image.size.height - glyph.maxY),
                                width: image.size.width, height: image.size.height)
        }
        label.frame = CGRect(x: 8 + iconWidth, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
    }
    private func refresh() {
        label.color = quiet && !hovering ? TranscriptNSPalette.muted : TranscriptNSPalette.accent
        icon.contentTintColor = label.color
        face.fill = hovering ? TranscriptNSPalette.accentSoft : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, enabled { perform() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    /// A button the keyboard reaches, as SwiftUI's was.
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    /// For a test: the pointer over it, or not.
    func setHovering(_ value: Bool) { hovering = value }
}

/// The floating surface every edge control stands on
/// (`TranscriptEdgeSurface`): the transcript's card colour, a hairline and a
/// soft shadow, four points around its content and three above and below.
@MainActor class TranscriptEdgeSurfaceView: NSView {
    let panel = TranscriptPanel()
    override var isFlipped: Bool { true }
    init(radius: CGFloat = 14) {
        super.init(frame: .zero)
        panel.cornerRadius = radius
        panel.fill = TranscriptNSPalette.surface
        panel.stroke = TranscriptNSPalette.hairStrong
        panel.castShadow = (NSColor.black.withAlphaComponent(0.14), 10, 3)
        addSubview(panel)
    }
    required init?(coder: NSCoder) { nil }
    /// The content's size at `width` for it, and how it lays itself out.
    func contentSize(width: CGFloat) -> CGSize { .zero }
    func layoutContent(in rect: CGRect) {}
    /// The surface's size when offered `width`.
    func size(offered width: CGFloat) -> CGSize {
        let content = contentSize(width: max(0, width - 8))
        return CGSize(width: content.width + 8, height: content.height + 6)
    }
    override func layout() {
        super.layout()
        panel.frame = bounds
        layoutContent(in: bounds.insetBy(dx: 4, dy: 3))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The surface itself is not a control: only what stands on it is.
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A run of edge links (and the faint dot between two) on one line, centred
/// on it, `spacing` apart.
@MainActor private func placeInLine(_ views: [NSView], sizes: [CGSize], in rect: CGRect, spacing: CGFloat, scale: CGFloat) {
    var x = rect.minX
    for (view, size) in zip(views, sizes) {
        view.frame = TranscriptMotion.pixelAligned(CGRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height), scale: scale)
        x += size.width + spacing
    }
}

/// The faint "·" between two links, in the body's face (a `Text` without a
/// font of its own).
@MainActor private func edgeDot() -> TranscriptLabel {
    let dot = TranscriptLabel()
    dot.text = "·"; dot.font = .systemFont(ofSize: 13); dot.color = TranscriptNSPalette.faint
    return dot
}

/// "Load earlier messages", and the way to the turn's question beside it
/// when the turn began before the page does.
@MainActor final class TranscriptEdgeWaitingView: TranscriptEdgeSurfaceView {
    let load: TranscriptEdgeLinkButton
    let partial: TranscriptEdgeLinkButton?
    private let dot: TranscriptLabel?
    init(load: @escaping () -> Void, partial: (() -> Void)?) {
        self.load = TranscriptEdgeLinkButton(title: "Load earlier messages", perform: load)
        self.partial = partial.map { TranscriptEdgeLinkButton(title: "Earlier work in this turn", quiet: true, perform: $0) }
        dot = partial == nil ? nil : edgeDot()
        super.init()
        self.load.setAccessibilityIdentifier("loadEarlierHistory")
        for view in [self.load, dot, self.partial] as [NSView?] { if let view { addSubview(view) } }
    }
    required init?(coder: NSCoder) { nil }
    private var pieces: [(NSView, CGSize)] {
        var pieces: [(NSView, CGSize)] = [(load, load.size)]
        if let dot, let partial { pieces += [(dot, dot.intrinsicSize), (partial, partial.size)] }
        return pieces
    }
    override func contentSize(width: CGFloat) -> CGSize {
        let pieces = self.pieces
        return CGSize(width: pieces.reduce(0) { $0 + $1.1.width } + CGFloat(pieces.count - 1) * 2, height: pieces.map(\.1.height).max() ?? 0)
    }
    override func layoutContent(in rect: CGRect) {
        let pieces = self.pieces
        placeInLine(pieces.map(\.0), sizes: pieces.map(\.1), in: rect, spacing: 2, scale: window?.backingScaleFactor ?? 2)
    }
}

/// The way to the question a long turn began with (`TranscriptPartialTurnChip`).
@MainActor final class TranscriptPartialTurnChipView: TranscriptEdgeSurfaceView {
    let link: TranscriptEdgeLinkButton
    init(inspect: @escaping () -> Void) {
        link = TranscriptEdgeLinkButton(title: "Earlier work in this turn", quiet: true, symbol: "arrow.up.to.line", perform: inspect)
        super.init()
        addSubview(link)
        toolTip = "Show the question this turn began with"
    }
    required init?(coder: NSCoder) { nil }
    override func contentSize(width: CGFloat) -> CGSize { link.size }
    override func layoutContent(in rect: CGRect) {
        link.frame = TranscriptMotion.pixelAligned(CGRect(origin: rect.origin, size: link.size), scale: window?.backingScaleFactor ?? 2)
    }
}

/// A read that failed, or a page that lost its place (`TranscriptEdgeProblem`):
/// one line saying so with the thing to do about it, and the error under it,
/// centred, at most three lines, selectable.
@MainActor final class TranscriptEdgeProblemView: TranscriptEdgeSurfaceView {
    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let detailFace = TranscriptPlainTextFace(size: 10.5, monospaced: false, lineSpacing: 0, label: "Error")
    static let maximumWidth: CGFloat = 460
    let action: TranscriptEdgeLinkButton
    let partial: TranscriptEdgeLinkButton?
    private let icon = TranscriptSymbol()
    private let title = TranscriptLabel()
    private let dot: TranscriptLabel?
    let detail = TranscriptPlainTextView()
    init(title text: String, detail message: String, action name: String, perform: @escaping () -> Void,
         partial: (() -> Void)? = nil, icon symbol: String = "exclamationmark.circle") {
        action = TranscriptEdgeLinkButton(title: name, perform: perform)
        self.partial = partial.map { TranscriptEdgeLinkButton(title: "Earlier work in this turn", quiet: true, perform: $0) }
        dot = partial == nil ? nil : edgeDot()
        super.init(radius: 12)
        icon.show(symbol, size: 11, weight: .semibold); icon.contentTintColor = TranscriptNSPalette.warning
        title.text = text; title.font = Self.titleFont; title.color = TranscriptNSPalette.text
        detail.centred = true; detail.maximumLines = 3
        detail.update(text: message, face: Self.detailFace, environment: TranscriptRowEnvironment(), swiftUILines: true, color: TranscriptNSPalette.muted)
        for view in [icon, title, action, dot, self.partial, detail] as [NSView?] { if let view { addSubview(view) } }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(text + ". " + message)
    }
    required init?(coder: NSCoder) { nil }
    private var iconSize: CGSize { icon.swiftUIFrame ?? icon.image?.size ?? .zero }
    private var line: [(NSView, CGSize)] {
        var pieces: [(NSView, CGSize)] = [(icon, iconSize), (title, title.intrinsicSize), (action, action.size)]
        if let dot, let partial { pieces += [(dot, dot.intrinsicSize), (partial, partial.size)] }
        return pieces
    }
    private var lineSize: CGSize {
        let pieces = line
        return CGSize(width: pieces.reduce(0) { $0 + $1.1.width } + CGFloat(pieces.count - 1) * 4, height: pieces.map(\.1.height).max() ?? 0)
    }
    /// The error's room: what the surface was offered, less its padding.
    private func detailRoom(_ width: CGFloat) -> CGFloat { max(1, width - 4 - 12) }
    override func size(offered width: CGFloat) -> CGSize { super.size(offered: min(width, Self.maximumWidth)) }
    /// The error's room when the surface was last sized: the error is set
    /// in what it was offered, not in what it then took.
    private var offeredRoom: CGFloat?
    override func contentSize(width: CGFloat) -> CGSize {
        let line = lineSize, room = detailRoom(width)
        offeredRoom = room
        let text = CGSize(width: detail.usedWidth(width: room), height: detail.exactHeight(width: room))
        return CGSize(width: 4 + max(line.width, text.width + 12), height: line.height + 1 + text.height + 3)
    }
    override func layoutContent(in rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let inner = CGRect(x: rect.minX + 4, y: rect.minY, width: rect.width - 4, height: rect.height)
        let line = lineSize
        let lineRect = CGRect(x: inner.midX - line.width / 2, y: inner.minY, width: line.width, height: line.height)
        let pieces = self.line
        placeInLine(pieces.map(\.0), sizes: pieces.map(\.1), in: lineRect, spacing: 4, scale: scale)
        // The image drawn whole, centred where SwiftUI lays the symbol out.
        icon.place(in: icon.frame)
        let room = offeredRoom ?? detailRoom(bounds.width - 8)
        let used = detail.usedWidth(width: room), height = detail.exactHeight(width: room)
        detail.frame = TranscriptMotion.pixelAligned(CGRect(x: inner.midX - used / 2, y: lineRect.maxY + 1, width: used, height: ceil(height)), scale: scale)
    }
}

/// The small spinner an edge shows while a slow read is under way
/// (`TranscriptEdgeSpinner`): 26 points of surface with a hairline and a
/// shadow, the transcript's spinner in its middle.
@MainActor final class TranscriptEdgeSpinnerView: NSView {
    static let diameter: CGFloat = 26
    private let disc = TranscriptPanel()
    let spinner = TranscriptSpinner()
    override var isFlipped: Bool { true }
    init(label: String) {
        super.init(frame: .zero)
        disc.circular = true; disc.cornerRadius = nil
        disc.fill = TranscriptNSPalette.surface; disc.stroke = TranscriptNSPalette.hairStrong
        disc.castShadow = (NSColor.black.withAlphaComponent(0.14), 8, 2)
        addSubview(disc); addSubview(spinner)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
    var size: CGSize { CGSize(width: Self.diameter, height: Self.diameter) }
    override func layout() {
        super.layout()
        disc.frame = bounds
        let side = TranscriptSpinner.size
        spinner.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Marks an edge control in the view tree, so a check can find what the
/// reader would see at an edge and press it. It draws nothing and takes no
/// clicks; it lies behind the control, its own size.
final class TranscriptEdgeMarkerView: NSView {
    /// Which edge: "earlier" or "newer".
    private(set) var edge = ""
    /// What it shows: a `TranscriptEdge` name, "partial" or "latest".
    private(set) var kind = ""
    /// The words it shows, or the error it reports.
    private(set) var text = ""
    /// What pressing it does.
    private(set) var action: (() -> Void)?
    func mark(edge: String, kind: String, text: String, action: (() -> Void)?) {
        self.edge = edge; self.kind = kind; self.text = text; self.action = action
    }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One edge's control and its marker, as they come and go: a new kind of
/// control fades in over the quick ease as the old one fades out, and the
/// same kind updates in place. They stand in a stack of the larger's size,
/// each centred in it, as SwiftUI's `ZStack` with an opacity transition.
@MainActor final class TranscriptEdgeSlot: NSView {
    struct Shown { let key: String; let view: NSView; let marker: TranscriptEdgeMarkerView; let size: (CGFloat) -> CGSize }
    private(set) var shown: Shown?
    private var leaving: [Shown] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    /// Shows `next` (nil: nothing), fading when `animated`.
    func show(_ next: Shown?, animated: Bool) {
        if let shown, next?.key == shown.key, next?.view === shown.view { return }
        if let old = shown {
            if animated {
                leaving.append(old)
                for view in [old.view, old.marker] as [NSView] { fade(view, to: 0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + PiKit.Motion.quick) { [weak self] in
                    guard let self else { return }
                    self.leaving.removeAll { $0.view === old.view }
                    if self.shown?.view !== old.view { old.view.removeFromSuperview(); old.marker.removeFromSuperview() }
                    self.superview?.needsLayout = true
                }
            } else {
                old.view.removeFromSuperview(); old.marker.removeFromSuperview()
            }
        }
        shown = next
        if let next {
            addSubview(next.marker, positioned: .below, relativeTo: nil)
            addSubview(next.view)
            if animated { next.view.alphaValue = 0; fade(next.view, to: 1) } else { next.view.alphaValue = 1 }
        }
        superview?.needsLayout = true
    }
    private func fade(_ view: NSView, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PiKit.Motion.quick
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }
    }
    private var all: [Shown] { leaving + (shown.map { [$0] } ?? []) }
    /// The stack's size when offered `width`.
    func size(offered width: CGFloat) -> CGSize {
        let sizes = all.map { $0.size(width) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }
    /// Lays the controls out in `bounds`, which is `size(offered:)` big.
    func place(offered width: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        for item in all {
            let size = item.size(width)
            let frame = TranscriptMotion.pixelAligned(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                             width: size.width, height: size.height), scale: scale)
            item.view.frame = frame; item.marker.frame = frame
        }
    }
    var isEmpty: Bool { all.isEmpty }
}
