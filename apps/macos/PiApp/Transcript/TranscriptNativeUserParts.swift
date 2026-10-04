import AppKit
import Combine

// The parts of a sent message beyond its words, drawn by AppKit: the skills
// it used as pills leading its bubble, and the switcher between the versions
// an edit made. They read exactly as `TranscriptSkillPills` and
// `VersionSwitcher` did.

/// One skill a sent message used, as `SkillPillFace` drew it — the command
/// glyph, "/name" and the arguments cut short on a tinted face — with the
/// AppKit `SkillPillButton` over it taking the press, the pointer, the
/// keyboard, Copy and the accessibility action, as it always did.
@MainActor final class TranscriptNativeSkillPill: NSView {
    static let height = SkillPillFace.height
    static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let argumentsFont = NSFont.systemFont(ofSize: 12)
    static let padding: CGFloat = 7
    static let spacing: CGFloat = 4
    private let base = TranscriptPanel()
    private let tint = TranscriptPanel()
    private let edge = TranscriptPanel()
    private let glyph = TranscriptSymbol()
    private let name = TranscriptLabel()
    private let arguments = TranscriptLabel()
    let button = SkillPillButton(frame: .zero)
    private(set) var use: TranscriptSkillUse
    private var messageID = ""
    private var actions = TranscriptActions()
    private var key = ""
    private var open = false
    private var hovering = false
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    private var observation: AnyCancellable?
    override var isFlipped: Bool { true }

    init(use: TranscriptSkillUse) {
        self.use = use
        super.init(frame: .zero)
        for panel in [base, tint, edge] { panel.cornerRadius = 6 }
        edge.cornerRadius = 5.5
        glyph.show("command", size: 9, weight: .bold)
        name.font = Self.nameFont; name.truncation = .middle
        arguments.font = Self.argumentsFont; arguments.truncation = .tail
        for view in [base, tint, edge, glyph, name, arguments, button] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
        button.onHover = { [weak self] anchor, inside in
            guard let self else { return }
            self.hovering = inside; self.refresh()
            self.actions.skillHovered?(self.messageID, self.use, anchor, inside)
        }
        button.onPress = { [weak self] anchor in
            guard let self else { return }
            self.actions.skillPressed?(self.messageID, self.use, anchor)
        }
        // Lit while its popover is open, as the face observed `SkillPopovers`.
        observation = SkillPopovers.shared.$openKey.sink { [weak self] openKey in
            MainActor.assumeIsolated {
                guard let self else { return }
                let open = openKey == self.key
                if open != self.open { self.open = open; self.refresh() }
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(messageID: String, use: TranscriptSkillUse, actions: TranscriptActions, environment: TranscriptRowEnvironment) {
        if use.name != self.use.name || use.arguments != self.use.arguments { needsLayout = true }
        self.use = use; self.messageID = messageID; self.actions = actions
        key = SkillPopovers.sentKey(messageID: messageID, skillID: use.id)
        open = SkillPopovers.shared.openKey == key
        name.text = "/" + use.name
        arguments.text = SkillPillLabel.arguments(use.arguments)
        arguments.isHidden = arguments.text.isEmpty
        // What the pill says without the catalog: the row cannot see it, and
        // must not wait for it. The popover compares with the current one.
        let detail = SkillDetail.sent(use, catalog: SkillCatalog())
        button.copiedText = SkillPillLabel.copied(use.name)
        if button.accessibilityLabel() != detail.accessibilityLabel { button.setAccessibilityLabel(detail.accessibilityLabel) }
        let help = detail.accessibilityHelp + ". Press to show its details."
        if button.accessibilityHelp() != help { button.setAccessibilityHelp(help) }
        if button.accessibilityIdentifier() != "skill-pill-" + use.name { button.setAccessibilityIdentifier("skill-pill-" + use.name) }
        button.isEnabled = environment.isEnabled
        rightToLeft = environment.layoutDirection == .rightToLeft
        refresh()
    }
    private func refresh() {
        base.fill = .piSurface
        tint.fill = NSColor.piBrandOrange.withAlphaComponent(hovering || open ? 0.19 : 0.12)
        edge.stroke = open ? NSColor.piAccent.withAlphaComponent(0.55) : nil
        glyph.contentTintColor = .piAccent
        name.color = .piAccent
        arguments.color = .piInkSecondary
    }

    private var glyphSize: CGSize { glyph.swiftUIFrame ?? glyph.image?.size ?? .zero }
    /// The face's width with all the room it wants.
    var idealWidth: CGFloat {
        var width = 2 * Self.padding + glyphSize.width + Self.spacing + name.intrinsicSize.width
        if !arguments.isHidden { width += Self.spacing + arguments.intrinsicSize.width }
        return width
    }
    /// The widths of the name and the arguments in a face `width` wide: the
    /// name gives way last (`layoutPriority(1)`), each cut short as its text is.
    private func textWidths(in width: CGFloat) -> (name: CGFloat, arguments: CGFloat) {
        let nameIdeal = name.intrinsicSize.width, argumentsIdeal = arguments.isHidden ? 0 : arguments.intrinsicSize.width
        guard width < idealWidth else { return (nameIdeal, argumentsIdeal) }
        var room = width - 2 * Self.padding - glyphSize.width - Self.spacing
        if arguments.isHidden { return (name.width(truncatedTo: max(0, room)), 0) }
        room -= Self.spacing
        let argumentsLeast = arguments.width(truncatedTo: 0)
        let nameWidth = name.width(truncatedTo: max(0, min(nameIdeal, room - argumentsLeast)))
        return (nameWidth, arguments.width(truncatedTo: max(0, room - nameWidth)))
    }
    override func layout() {
        super.layout()
        for panel in [base, tint] { panel.frame = bounds }
        // `strokeBorder`: the line inside the face.
        edge.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        button.frame = bounds
        let widths = textWidths(in: bounds.width)
        var x = Self.padding
        let symbol = glyphSize
        glyph.place(in: pixelAligned(CGRect(x: x, y: (bounds.height - symbol.height) / 2, width: symbol.width, height: symbol.height)))
        x += symbol.width + Self.spacing
        let line = name.intrinsicSize.height
        name.frame = CGRect(x: x, y: (bounds.height - line) / 2, width: widths.name, height: line)
        x += widths.name + Self.spacing
        arguments.frame = CGRect(x: x, y: (bounds.height - line) / 2, width: widths.arguments, height: line)
        if rightToLeft {
            glyph.frame = TranscriptMotion.mirrored(glyph.frame, width: bounds.width, true)
            for label in [name, arguments] { label.frame = TranscriptMotion.mirrored(label.frame, of: label, width: bounds.width, true) }
        }
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }
}

/// The skills a sent message used, as pills that flow like words, six points
/// apart, at the start of its bubble (`TranscriptSkillPills`).
@MainActor final class TranscriptNativeSkillPills: NSView {
    static let spacing = TranscriptSkillPills.spacing
    private(set) var pills: [TranscriptNativeSkillPill] = []
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("transcript-skill-pills")
    }
    required init?(coder: NSCoder) { nil }
    func update(messageID: String, skills: [TranscriptSkillUse], actions: TranscriptActions, environment: TranscriptRowEnvironment) {
        if pills.map(\.use.id) != skills.map(\.id) {
            pills.forEach { $0.removeFromSuperview() }
            pills = skills.map { TranscriptNativeSkillPill(use: $0) }
            for pill in pills { addSubview(pill) }
            needsLayout = true
        }
        for (pill, use) in zip(pills, skills) { pill.update(messageID: messageID, use: use, actions: actions, environment: environment) }
        rightToLeft = environment.layoutDirection == .rightToLeft
        setAccessibilityLabel(skills.count == 1 ? "Skill used by this message" : "Skills used by this message")
    }
    /// Each pill's frame at `width`, as `PiFlow` places them.
    private func frames(width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, frames: [CGRect] = []
        for pill in pills {
            let ideal = pill.idealWidth
            // A pill wider than a whole row is laid out within it.
            let size = CGSize(width: ideal > width ? width : ideal, height: TranscriptNativeSkillPill.height)
            if x > 0, x + size.width > width { x = 0; y += TranscriptNativeSkillPill.height + Self.spacing }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + Self.spacing
        }
        return frames
    }
    func height(width: CGFloat) -> CGFloat { frames(width: width).last?.maxY ?? 0 }
    override func layout() {
        super.layout()
        for (pill, frame) in zip(pills, frames(width: bounds.width)) {
            pill.frame = TranscriptMotion.pixelAligned(TranscriptMotion.mirrored(frame, width: bounds.width, rightToLeft), scale: window?.backingScaleFactor ?? 2)
        }
    }
}

/// `‹ 2 / 2 ›` under an edited message (`VersionSwitcher`): the chevrons
/// show the version before or after, the figure which one is on screen.
/// The marker view checks look for stays in it.
@MainActor final class TranscriptNativeVersionSwitcher: NSView {
    static let height: CGFloat = 22
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    let marker = VersionSwitcherMarkerView()
    let earlier = TranscriptNativeVersionChevron(symbol: "chevron.left", label: "Earlier version")
    let later = TranscriptNativeVersionChevron(symbol: "chevron.right", label: "Later version")
    private let figure = TranscriptLabel()
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        figure.font = Self.font; figure.monospacedDigits = true
        for view in [marker, earlier, figure, later] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("version-switcher")
    }
    required init?(coder: NSCoder) { nil }
    func update(messageID: String, mark: MessageVersionMark, environment: TranscriptRowEnvironment, step: @escaping (Int) -> Void) {
        if marker.messageID != messageID { marker.messageID = messageID }
        if marker.mark != mark { marker.mark = mark }
        figure.text = "\(mark.index) / \(mark.count)"; figure.color = TranscriptNSPalette.muted
        earlier.update(enabled: mark.index > 1, environment: environment) { step(-1) }
        later.update(enabled: mark.index < mark.count, environment: environment) { step(1) }
        rightToLeft = environment.layoutDirection == .rightToLeft
        toolTip = "Version \(mark.index) of \(mark.count) · ⌥← and ⌥→ switch versions"
        setAccessibilityLabel("Version \(mark.index) of \(mark.count)")
        needsLayout = true
    }
    var width: CGFloat { 2 * TranscriptNativeVersionChevron.side + 4 + figure.intrinsicSize.width }
    override func layout() {
        super.layout()
        marker.frame = bounds
        let side = TranscriptNativeVersionChevron.side, text = figure.intrinsicSize
        let midY = bounds.height / 2
        earlier.frame = CGRect(x: 0, y: midY - side / 2, width: side, height: side)
        figure.frame = CGRect(x: side + 2, y: midY - text.height / 2, width: text.width, height: text.height)
        later.frame = CGRect(x: side + 4 + text.width, y: midY - side / 2, width: side, height: side)
        if rightToLeft {
            for view in [earlier, later] as [NSView] { view.frame = TranscriptMotion.mirrored(view.frame, width: bounds.width, true) }
            figure.frame = TranscriptMotion.mirrored(figure.frame, of: figure, width: bounds.width, true)
        }
    }
}

/// One of the switcher's chevrons: 18 points square, a circle behind it
/// under the pointer, faded and inert at the first or last version.
@MainActor final class TranscriptNativeVersionChevron: NSView {
    static let side: CGFloat = 18
    private let circle = TranscriptPanel()
    private let symbol = TranscriptSymbol()
    private var perform: () -> Void = {}
    /// Whether there is a version that way; a pane that takes no input acts on neither.
    private(set) var available = true
    private(set) var enabled = true
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    private var pressing = false
    override var isFlipped: Bool { true }
    init(symbol name: String, label: String) {
        super.init(frame: .zero)
        circle.cornerRadius = nil; circle.circular = true
        symbol.show(name, size: 9.5, weight: .semibold)
        addSubview(circle); addSubview(symbol)
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.hovering = inside; self?.refresh() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
    func update(enabled available: Bool, environment: TranscriptRowEnvironment, perform: @escaping () -> Void) {
        self.available = available
        enabled = available && environment.isEnabled
        self.perform = perform
        if !enabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        refresh()
        window?.invalidateCursorRects(for: self)
    }
    private func refresh() {
        symbol.contentTintColor = !available ? TranscriptNSPalette.faint.withAlphaComponent(0.45) : hovering ? TranscriptNSPalette.text : TranscriptNSPalette.muted
        circle.fill = hovering && available ? TranscriptNSPalette.panelStrong : nil
    }
    override func layout() {
        super.layout()
        circle.frame = bounds
        let size = symbol.swiftUIFrame ?? symbol.image?.size ?? .zero
        symbol.place(in: TranscriptMotion.pixelAligned(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                              width: size.width, height: size.height), scale: window?.backingScaleFactor ?? 2))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: bounds)
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { pressing = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressing = false }
        guard pressing, enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
}
