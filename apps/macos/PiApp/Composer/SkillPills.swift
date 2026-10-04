import AppKit
import Combine

// A skill pill: the composer's inline token and a sent message's pill share
// one face and one press target. The face draws; the target is a button
// over it (or around it, for a composer token), so the press, the hover, the pointer, keyboard focus, Copy
// and the accessibility action belong to one view a popover can anchor to.

/// What a pill looks like: the command glyph, "/name" and, when there are
/// any, the arguments cut short after it. It draws and never takes a click:
/// its pill does.
@MainActor final class SkillPillFaceView: NSView {
    nonisolated static let height: CGFloat = 18
    static let padding: CGFloat = 7
    static let spacing: CGFloat = 4
    var name: String { didSet { if oldValue != name { contentChanged() } } }
    var arguments: String { didSet { if oldValue != arguments { contentChanged() } } }
    var hovered = false { didSet { if oldValue != hovered { styleChanged() } } }
    var open = false { didSet { if oldValue != open { styleChanged() } } }
    private let base = CALayer(), tint = CALayer(), border = CALayer()
    private let content = PiKit.DrawingLayer()

    init(name: String, arguments: String = "") {
        self.name = name; self.arguments = arguments
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [base, tint, border] { layer.cornerRadius = 6; layer.cornerCurve = .continuous; self.layer?.addSublayer(layer) }
        border.borderWidth = 1
        content.drawer = { [weak self] rect in self?.drawContent(in: rect) }
        layer?.addSublayer(content)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let glyph = PiKit.Symbol("command", size: 9, weight: .bold)
    private var nameLine: PiKit.Line { PiKit.Line("/" + name, font: .systemFont(ofSize: 12, weight: .semibold), color: .piAccent) }
    private var shortened: String { SkillPillLabel.arguments(arguments) }
    private var argumentLine: PiKit.Line { PiKit.Line(shortened, font: .systemFont(ofSize: 12), color: .piInkSecondary) }

    /// The width the face takes for its whole label, as SwiftUI sized it.
    static func idealWidth(name: String, arguments: String, scale: CGFloat = 2) -> CGFloat {
        let face = SkillPillFaceView(name: name, arguments: arguments)
        return face.idealWidth(scale: scale)
    }
    func idealWidth(scale: CGFloat) -> CGFloat {
        var width = Self.padding * 2 + Self.glyph.layoutSize.width + Self.spacing + nameLine.size(scale: scale).width
        if !shortened.isEmpty { width += Self.spacing + argumentLine.size(scale: scale).width }
        return width
    }
    override var intrinsicContentSize: NSSize { NSSize(width: idealWidth(scale: piScale), height: Self.height) }

    private func contentChanged() { invalidateIntrinsicContentSize(); content.setNeedsDisplay() }
    private func styleChanged() { needsLayout = true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [base, tint, border, content] as [CALayer] { layer.frame = bounds }
        content.contentsScale = piScale
        styleLayers()
        CATransaction.commit()
        content.setNeedsDisplay()
    }
    /// The card's own surface under a light orange tint, so the pill reads
    /// the same in the white composer and on the tinted bubble, and its
    /// labels keep their contrast on both.
    private func styleLayers() {
        base.backgroundColor = piCGColor(.piSurface)
        tint.backgroundColor = piCGColor(NSColor.piBrandOrange.withAlphaComponent(hovered || open ? 0.19 : 0.12))
        border.borderColor = open ? piCGColor(NSColor.piAccent.withAlphaComponent(0.55)) : CGColor.clear
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        content.appearance = effectiveAppearance
        needsLayout = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        content.appearance = effectiveAppearance; content.contentsScale = piScale
        needsLayout = true
    }

    /// The glyph, the name and the arguments in a row, as an `HStack` lays
    /// them out: the name first in line for room, the arguments cut first.
    private func drawContent(in rect: CGRect) {
        let scale = piScale
        let glyphBox = Self.glyph.layoutSize
        let name = nameLine, nameSize = name.size(scale: scale)
        let arguments = shortened.isEmpty ? nil : argumentLine
        let argumentSize = arguments?.size(scale: scale) ?? .zero
        var room = rect.width - Self.padding * 2 - glyphBox.width - Self.spacing
        if arguments != nil { room -= Self.spacing }
        // A truncating line's least width is its ellipsis.
        let least = arguments.map { PiKit.Line("…", font: $0.font, color: $0.color).size(scale: scale).width } ?? 0
        let fits = nameSize.width + argumentSize.width <= room + 0.25
        let nameWidth = fits ? nameSize.width : min(nameSize.width, max(0, room - least))
        let argumentWidth = fits ? argumentSize.width : min(argumentSize.width, max(0, room - nameWidth))
        let total = glyphBox.width + Self.spacing + nameWidth + (arguments == nil ? 0 : Self.spacing + argumentWidth)
        var x = PiKit.round((rect.width - total) / 2, scale)
        x = max(Self.padding, x)
        Self.glyph.draw(centredIn: CGRect(x: x, y: 0, width: glyphBox.width, height: rect.height), color: .piAccent, scale: scale)
        x += glyphBox.width + Self.spacing
        let y = PiKit.round((rect.height - nameSize.height) / 2, scale)
        name.draw(in: CGRect(x: x, y: y, width: nameWidth, height: nameSize.height), truncation: .middle, scale: scale)
        if let arguments {
            x += nameWidth + Self.spacing
            arguments.draw(in: CGRect(x: x, y: PiKit.round((rect.height - argumentSize.height) / 2, scale), width: argumentWidth, height: argumentSize.height),
                           truncation: .end, scale: scale)
        }
    }
}

/// The keys a focused composer token hands to its composer. `type` is any
/// key that writes: the composer takes focus back and the key goes into the
/// text, so typing on a focused token is never lost.
enum SkillPillKey { case left, right, delete, escape, type }

/// The press target of a skill pill. It draws nothing; the face under it (or
/// inside it, for a composer token) does. A click, Space or Return presses
/// it; the pointer resting on it is reported for the hover card; Copy puts
/// "/name" on the pasteboard. It takes keyboard focus only when keyboard
/// navigation is on or the composer hands focus to it, so a click never pulls
/// focus out of the text being typed.
class SkillPillButton: NSButton {
    var onPress: ((SkillPillButton) -> Void)?
    var onHover: ((SkillPillButton, Bool) -> Void)?
    /// Composer tokens: arrows, Delete and Escape while focused. Returns
    /// whether the composer took the key.
    var onKey: ((SkillPillButton, SkillPillKey) -> Bool)?
    /// Items for the pill's context menu after Copy.
    var menuItems: (() -> [NSMenuItem])?
    var copiedText = ""
    /// Where Copy writes; a test gives its own rather than the clipboard.
    var pasteboard: NSPasteboard = .general
    private(set) var hovering = false
    /// Set while the composer moves keyboard focus onto this token.
    var keyboardFocusRequested = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        title = ""; isBordered = false; imagePosition = .noImage
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self; action = #selector(pressed(_:))
    }
    @objc private func pressed(_ sender: Any?) { onPress?(self) }
    override func draw(_ dirtyRect: NSRect) {}

    // MARK: Pointer
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    func setHovering(_ inside: Bool) {
        guard hovering != inside else { return }
        hovering = inside
        hoverChanged()
        onHover?(self, inside)
    }
    /// For subclasses that draw a hover state.
    func hoverChanged() {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A pill that leaves the screen (another chat, a row scrolled far
        // away, a token removed) takes its card and its popover with it.
        if window == nil { setHovering(false); SkillPopovers.shared.anchorLeft(self) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: Keyboard
    override var acceptsFirstResponder: Bool { keyboardFocusRequested || NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    /// Moves keyboard focus onto this pill, whatever the keyboard navigation setting.
    @discardableResult func focusFromKeyboard() -> Bool {
        keyboardFocusRequested = true
        guard window?.makeFirstResponder(self) == true else { keyboardFocusRequested = false; return false }
        return true
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocusRequested = false }
        return resigned
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers.isEmpty {
            switch event.keyCode {
            case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.space: performClick(nil); return
            case KeyCode.leftArrow: if onKey?(self, .left) == true { return }
            case KeyCode.rightArrow: if onKey?(self, .right) == true { return }
            case KeyCode.delete, KeyCode.forwardDelete: if onKey?(self, .delete) == true { return }
            case KeyCode.escape: if onKey?(self, .escape) == true { return }
            default:
                if Self.writes(event), onKey?(self, .type) == true, let responder = window?.firstResponder, responder !== self {
                    responder.keyDown(with: event); return
                }
            }
        }
        super.keyDown(with: event)
    }
    /// A key that puts characters in text, as opposed to one that moves,
    /// deletes or commands.
    static func writes(_ event: NSEvent) -> Bool {
        guard let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Copy
    @objc func copy(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString(copiedText, forType: .string)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy “\(copiedText)”", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let extra = menuItems?() ?? []
        if !extra.isEmpty { menu.addItem(.separator()) }
        for item in extra { menu.addItem(item) }
        return menu
    }
}

/// A composer token: the pill, drawn inside the composer's text view where
/// the text's first line begins. The composer lays it out; the token only
/// knows its skill and how wide its face wants to be.
final class ComposerSkillToken: SkillPillButton {
    private(set) var chip: SkillChip
    private let face: SkillPillFaceView
    private var openObservation: AnyCancellable?
    /// The width the face needs for its whole label.
    private(set) var idealWidth: CGFloat = 0
    let popoverKey: String

    init(chip: SkillChip, sessionID: String) {
        self.chip = chip
        popoverKey = SkillPopovers.composerKey(sessionID: sessionID, skillID: chip.id)
        face = SkillPillFaceView(name: chip.name, arguments: chip.arguments)
        super.init(frame: .zero)
        face.autoresizingMask = [.width, .height]
        addSubview(face)
        // Lit while its popover is open.
        let key = popoverKey
        openObservation = SkillPopovers.shared.$openKey.sink { [weak self] open in
            MainActor.assumeIsolated { self?.face.open = open == key }
        }
        apply(chip)
    }
    /// Tokens are made in code only.
    required init?(coder: NSCoder) { return nil }

    /// Takes the chip's current values: its arguments may have been edited.
    func apply(_ chip: SkillChip) {
        let measured = self.chip.name != chip.name || self.chip.arguments != chip.arguments || idealWidth == 0
        self.chip = chip
        copiedText = SkillPillLabel.copied(chip.name)
        face.name = chip.name; face.arguments = chip.arguments
        if measured { idealWidth = ceil(face.idealWidth(scale: piScale)) }
    }
    /// What the token's card and popover say, asked for when an assistive
    /// technology reads the token rather than on every keystroke.
    var describe: ((SkillChip) -> SkillDetail?)?
    override func accessibilityLabel() -> String? {
        describe?(chip)?.accessibilityLabel ?? "Skill \(chip.name), explicit for this message"
    }
    override func accessibilityHelp() -> String? {
        (describe?(chip)?.accessibilityHelp).map { $0 + ". Press to show its details." }
    }
    override func hoverChanged() { face.hovered = hovering }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        face.frame = bounds
    }
}
