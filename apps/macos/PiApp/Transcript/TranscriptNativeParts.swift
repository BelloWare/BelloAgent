import AppKit

// Small AppKit pieces the transcript's native rows are built from: a label
// set like SwiftUI's text, a capsule pill, a rounded panel and the hover
// tracking a row needs. They live with the transcript until the app's Pi
// components have AppKit versions of their own.

/// The appearance a row is drawn in, from the values it is given.
@MainActor enum TranscriptAppearance {
    static func named(_ environment: TranscriptRowEnvironment) -> NSAppearance.Name {
        let dark = environment.colorScheme == .dark
        if environment.contrast == .increased { return dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua }
        return dark ? .darkAqua : .aqua
    }
    /// Gives `view` the row's appearance, if it does not have it already.
    static func apply(_ environment: TranscriptRowEnvironment, to view: NSView) {
        let name = named(environment)
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

/// The quick ease the rows' decorative changes use (`PiMotion.quick`).
@MainActor enum TranscriptMotion {
    static func fade(_ view: NSView, to alpha: CGFloat) {
        guard view.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(PiMotion.quickMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }
    }
    /// A pill arriving: it fades in and rises the 2 points it used to.
    static func arrive(_ view: NSView) {
        let final = view.frame
        view.alphaValue = 0
        view.setFrameOrigin(CGPoint(x: final.minX, y: final.minY + 2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(PiMotion.quickMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
            view.animator().setFrameOrigin(final.origin)
        }
    }
    /// `rect` in a row `width` wide laid out right to left.
    static func mirrored(_ rect: CGRect, width: CGFloat, _ rightToLeft: Bool) -> CGRect {
        rightToLeft ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
    }
}

/// One line of text, drawn as SwiftUI draws a `Text`: the font's own line box
/// (ascender to descender, plus its leading), the first baseline at the
/// ascender, and nothing wrapped. It never takes clicks or focus.
@MainActor final class TranscriptLabel: NSView {
    var text = "" { didSet { if text != oldValue { invalidate() } } }
    var font: NSFont = .systemFont(ofSize: 12) { didSet { if font != oldValue { invalidate() } } }
    var color: NSColor = TranscriptNSPalette.muted { didSet { if color != oldValue { attributed = nil; needsDisplay = true } } }
    var monospacedDigits = false { didSet { if monospacedDigits != oldValue { invalidate() } } }
    private var attributed: NSAttributedString?
    private var measured: CGSize?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Makes the label something assistive technology reads, as `label`.
    func speak(_ label: String?, identifier: String? = nil) {
        setAccessibilityElement(label != nil)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }
    private func invalidate() { attributed = nil; measured = nil; needsDisplay = true }
    private var resolvedFont: NSFont {
        guard monospacedDigits else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    private var string: NSAttributedString {
        if let attributed { return attributed }
        let value = NSAttributedString(string: text, attributes: [.font: resolvedFont, .foregroundColor: color])
        attributed = value
        return value
    }
    /// The line box SwiftUI gives this font.
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil((font.ascender - font.descender + font.leading) * 2) / 2 }
    /// The size the text needs on one line.
    var intrinsicSize: CGSize {
        if let measured { return measured }
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let size = CGSize(width: ceil(width * 2) / 2, height: Self.lineHeight(resolvedFont))
        measured = size
        return size
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let font = resolvedFont
        let string = string
        context.saveGState()
        // A flipped view: CoreText draws upward from the baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = CGPoint(x: 0, y: font.ascender + font.leading / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// A capsule of colour or a rounded panel behind a row's content: the bubble
/// a message sits in, a pill's face. Drawn by its layer, so moving or resizing
/// it is a frame change and nothing redraws.
@MainActor final class TranscriptPanel: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Nil is a capsule.
    var cornerRadius: CGFloat? = 14 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius ?? bounds.height / 2
        layer.cornerCurve = .continuous
        var background: CGColor?, border: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = fill?.cgColor
            border = stroke?.cgColor
        }
        layer.backgroundColor = background
        layer.borderColor = border
        layer.borderWidth = border == nil ? 0 : strokeWidth
    }
    override func layout() {
        super.layout()
        if cornerRadius == nil { needsDisplay = true }
    }
}

/// One of a row's pill buttons (Edit, Copy, Details…): its title in a
/// capsule that lights under the pointer, as `TranscriptPillStyle` drew it.
@MainActor final class TranscriptPillButton: NSView {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let face = TranscriptPanel()
    private let label = TranscriptLabel()
    let title: String
    let accent: Bool
    var perform: () -> Void
    /// A row in a pane that takes no input draws its pills and acts on none.
    var enabled = true
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var pressed = false { didSet { alphaValue = pressed ? 0.7 : 1 } }
    override var isFlipped: Bool { true }
    init(title: String, accent: Bool, perform: @escaping () -> Void) {
        self.title = title; self.accent = accent; self.perform = perform
        super.init(frame: .zero)
        face.cornerRadius = nil
        addSubview(face); addSubview(label)
        label.text = title; label.font = Self.font
        setAccessibilityElement(false)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    var pillSize: CGSize {
        let text = label.intrinsicSize
        return CGSize(width: text.width + 20, height: text.height + 8)
    }
    override func layout() {
        super.layout()
        face.frame = bounds
        let text = label.intrinsicSize
        label.frame = CGRect(x: 10, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
    }
    private func refresh() {
        label.color = hovering ? (accent ? TranscriptNSPalette.accent : TranscriptNSPalette.text) : TranscriptNSPalette.muted
        face.fill = hovering ? TranscriptNSPalette.panelStrong : nil
        face.stroke = hovering && accent ? TranscriptNSPalette.accent : TranscriptNSPalette.hairStrong
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
}

/// Watches the pointer over a view without taking anything from it.
@MainActor final class TranscriptHoverTracker {
    private weak var view: NSView?
    private var area: NSTrackingArea?
    var changed: (Bool) -> Void
    private(set) var inside = false
    init(view: NSView, changed: @escaping (Bool) -> Void) { self.view = view; self.changed = changed }
    /// Called from the view's `updateTrackingAreas`, with the part of it that counts.
    func update(rect: CGRect) {
        guard let view else { return }
        if let area { view.removeTrackingArea(area) }
        let next = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: view)
        view.addTrackingArea(next); area = next
        // A view that moved under a resting pointer learns where it is now.
        if let window = view.window {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            set(rect.contains(point))
        }
    }
    func set(_ value: Bool) { guard value != inside else { return }; inside = value; changed(value) }
}

/// Copies a markdown target and says so for two seconds, as `CopyButton`
/// does: a 64-point face so "Copy" turning into "Copied" moves nothing.
@MainActor final class TranscriptCopyButton: NSView {
    static let size = CGSize(width: 64, height: 21)
    private let face = TranscriptPanel()
    private let icon = NSImageView()
    private let label = TranscriptLabel()
    var target: MarkdownCopyTarget? { didSet { setAccessibilityLabel(target?.label); toolTip = target?.label } }
    var enabled = true
    private var hovering = false { didSet { refresh() } }
    private var copied = false { didSet { refresh() } }
    private var reset: Timer?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        face.cornerRadius = 5
        addSubview(face); addSubview(icon); addSubview(label)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    deinit { MainActor.assumeIsolated { reset?.invalidate() } }
    private func refresh() {
        let tint = copied ? TranscriptNSPalette.accent : hovering ? TranscriptNSPalette.text : TranscriptNSPalette.muted
        label.text = copied ? "Copied" : "Copy"; label.color = tint
        let symbol = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        icon.image = symbol; icon.contentTintColor = tint
        face.fill = hovering ? TranscriptNSPalette.panelStrong : TranscriptNSPalette.codeBackground
        face.stroke = copied ? TranscriptNSPalette.accent.withAlphaComponent(0.4) : hovering ? TranscriptNSPalette.hairStrong : nil
        needsLayout = true
    }
    override func layout() {
        super.layout()
        face.frame = bounds
        let iconSize = icon.image?.size ?? CGSize(width: 10, height: 10)
        let text = label.intrinsicSize
        let width = iconSize.width + 4 + text.width
        let x = (bounds.width - width) / 2
        icon.frame = CGRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
        label.frame = CGRect(x: x + iconSize.width + 4, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = accessibilityPerformPress()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let target, enabled else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.text, forType: .string)
        copied = true
        reset?.invalidate()
        reset = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.copied = false }
        }
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
