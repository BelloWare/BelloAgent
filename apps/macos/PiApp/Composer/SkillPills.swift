import SwiftUI
import AppKit

// A skill pill: the composer's inline token and a sent message's pill share
// one face and one press target. The face is SwiftUI; the target is an AppKit
// button over it, so the press, the hover, the pointer, keyboard focus, Copy
// and the accessibility action belong to one view a popover can anchor to.

/// What a pill looks like: the command glyph, "/name" and, when there are
/// any, the arguments cut short after it.
struct SkillPillFace: View {
    let name: String
    var arguments = ""
    var hovered = false
    var open = false
    nonisolated static let height: CGFloat = 18
    var body: some View {
        let shortened = SkillPillLabel.arguments(arguments)
        HStack(spacing: 4) {
            Image(systemName: "command").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piAccent)
            Text("/" + name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.piAccent)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !shortened.isEmpty {
                Text(shortened).font(.system(size: 12)).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: Self.height)
        .background {
            // The card's own surface under a light orange tint, so the pill
            // reads the same in the white composer and on the tinted bubble,
            // and its labels keep their contrast on both.
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Color.piSurface)
                .overlay { shape.fill(Color.piBrandOrange.opacity(hovered || open ? 0.19 : 0.12)) }
                .overlay { if open { shape.strokeBorder(Color.piAccent.opacity(0.55), lineWidth: 1) } }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

/// The face, lit while the pointer is over its pill or its popover is open.
private struct SkillPillFaceHost: View {
    let name: String
    let arguments: String
    let key: String
    let hovered: Bool
    @ObservedObject var popovers: SkillPopovers
    var body: some View {
        SkillPillFace(name: name, arguments: arguments, hovered: hovered, open: popovers.openKey == key)
    }
}

/// A hosting view that draws and never takes a click: its pill does.
private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
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
            case 36, 76, 49: performClick(nil); return
            case 123: if onKey?(self, .left) == true { return }
            case 124: if onKey?(self, .right) == true { return }
            case 51, 117: if onKey?(self, .delete) == true { return }
            case 53: if onKey?(self, .escape) == true { return }
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
    private let face: PassiveHostingView<SkillPillFaceHost>
    /// The width the face needs for its whole label.
    private(set) var idealWidth: CGFloat = 0
    let popoverKey: String

    init(chip: SkillChip, sessionID: String) {
        self.chip = chip
        popoverKey = SkillPopovers.composerKey(sessionID: sessionID, skillID: chip.id)
        face = PassiveHostingView(rootView: SkillPillFaceHost(name: chip.name, arguments: chip.arguments, key: popoverKey,
                                                               hovered: false, popovers: .shared))
        super.init(frame: .zero)
        face.sizingOptions = []
        face.translatesAutoresizingMaskIntoConstraints = true
        face.autoresizingMask = [.width, .height]
        addSubview(face)
        apply(chip)
    }
    /// Tokens are made in code only.
    required init?(coder: NSCoder) { return nil }

    /// Takes the chip's current values: its arguments may have been edited.
    func apply(_ chip: SkillChip) {
        let measured = self.chip.name != chip.name || self.chip.arguments != chip.arguments || idealWidth == 0
        self.chip = chip
        copiedText = SkillPillLabel.copied(chip.name)
        refreshFace()
        if measured {
            let probe = NSHostingView(rootView: SkillPillFace(name: chip.name, arguments: chip.arguments))
            idealWidth = ceil(probe.fittingSize.width)
        }
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
    override func hoverChanged() { refreshFace() }
    private func refreshFace() {
        face.rootView = SkillPillFaceHost(name: chip.name, arguments: chip.arguments, key: popoverKey, hovered: hovering, popovers: .shared)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        face.frame = bounds
    }
}
