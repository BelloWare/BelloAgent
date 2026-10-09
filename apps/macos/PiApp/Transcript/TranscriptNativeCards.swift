import AppKit

// What a work row opens, drawn by AppKit exactly as `TranscriptCards.swift`
// draws it in SwiftUI: a diff for a change, a numbered window for a read, a
// terminal for a command, and the IN/OUT card for everything else. Every
// card is the same rounded panel, set in under the row's title.

/// A number as SwiftUI's `Text("\(n)")` writes it: a localized string
/// key's integer, grouped for the reader's locale ("9,000").
func transcriptNumber(_ value: Int, _ locale: Locale) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = locale
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// The faces the cards set their words in.
enum TranscriptCardFaces {
    /// A payload, a command, a diff's and a read's lines.
    static let code = TranscriptPlainTextFace(size: 12, monospaced: true, lineSpacing: 0, label: "Text")
    nonisolated(unsafe) static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// A read's line number too wide for its gutter, which wraps there.
    static let number = TranscriptPlainTextFace(size: 11.5, monospaced: true, lineSpacing: 0, label: "Line number")
    /// A card's notes.
    static let note = TranscriptPlainTextFace(size: 11.5, monospaced: false, lineSpacing: 0, label: "Note")
    /// A diff too large to draw.
    static let message = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Note")
    /// A diff's banner, which wraps in a narrow card.
    static let banner = TranscriptPlainTextFace(size: 11.5, monospaced: false, lineSpacing: 0, label: "Change", weight: NSFont.Weight.medium.rawValue)
    nonisolated(unsafe) static let pathFont = NSFont.systemFont(ofSize: 11.5)
    nonisolated(unsafe) static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let numberFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    nonisolated(unsafe) static let figureFont = NSFont.systemFont(ofSize: 12)
}

/// The frame every card shares: a rounded panel with one hairline, set in to
/// line up with the row's title, two points under the row and eight above
/// whatever follows. A subclass lays out what is inside it.
@MainActor class TranscriptNativeCard: NSView {
    static let top: CGFloat = 2, bottom: CGFloat = 8
    let panel = TranscriptPanel()
    private(set) var environment = TranscriptRowEnvironment()
    private(set) var link: (() -> Void)?
    var rightToLeft: Bool { environment.layoutDirection == .rightToLeft }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.cornerRadius = 12
        addSubview(panel)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    static func make(_ card: TranscriptToolRow.Card) -> TranscriptNativeCard {
        switch card {
        case .diff: return TranscriptNativeDiffCard()
        case .terminal: return TranscriptNativeTerminalCard()
        case .read: return TranscriptNativeReadCard()
        case .io: return TranscriptNativeIOCard()
        }
    }
    /// Whether two cards are drawn by the same view, which keeps what the
    /// reader did in it (a diff expanded, a section scrolled).
    static func sameKind(_ a: TranscriptToolRow.Card?, _ b: TranscriptToolRow.Card) -> Bool {
        switch (a, b) {
        case (.diff?, .diff), (.terminal?, .terminal), (.read?, .read), (.io?, .io): return true
        default: return false
        }
    }
    func update(_ card: TranscriptToolRow.Card, link: (() -> Void)?, environment: TranscriptRowEnvironment) {
        self.link = link
        self.environment = environment
        panel.fill = TranscriptNSPalette.codeBackground
        panel.stroke = TranscriptNSPalette.hair
        configure(card)
        plans.removeAll()
        needsLayout = true
    }
    /// Sets the card's pieces.
    func configure(_ card: TranscriptToolRow.Card) {}
    /// The panel's content: each piece's frame inside a panel `width` wide,
    /// in the panel's coordinates (a piece inside another after it), and
    /// its height. Worked out without touching any view: it is kept per width.
    struct Plan { var frames: [(NSView, CGRect)]; var height: CGFloat }
    func plan(width: CGFloat) -> Plan { Plan(frames: [], height: 0) }
    private var plans: [(width: CGFloat, plan: Plan)] = []
    func cachedPlan(width: CGFloat) -> Plan {
        if let known = plans.first(where: { $0.width == width }) { return known.plan }
        let made = plan(width: width)
        if plans.count == 4 { plans.removeFirst() }
        plans.append((width, made))
        return made
    }
    /// Forgets the measured plans, when something in the card changed size.
    func invalidatePlans() { plans.removeAll(); needsLayout = true; (superview as? TranscriptNativeActionRow)?.cardChangedSize() }
    /// The card's height under a row `width` wide.
    func height(width: CGFloat) -> CGFloat {
        Self.top + cachedPlan(width: max(1, width - TranscriptRowChrome.indent)).height + Self.bottom
    }
    override func layout() {
        super.layout()
        let width = max(1, bounds.width - TranscriptRowChrome.indent)
        let plan = cachedPlan(width: width)
        let rect = CGRect(x: TranscriptRowChrome.indent, y: Self.top, width: width, height: plan.height)
        panel.frame = TranscriptMotion.mirrored(pixelAligned(rect), width: bounds.width, rightToLeft)
        // Frames are the panel's; a piece inside another is placed after it.
        for (view, frame) in plan.frames {
            let placed = TranscriptMotion.mirrored(frame.offsetBy(dx: rect.minX, dy: rect.minY), of: view, width: bounds.width, rightToLeft)
            view.frame = view.superview === self || view.superview == nil ? placed : view.superview!.convert(placed, from: self)
        }
    }
    func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }

    // MARK: Pieces

    /// A one-pixel rule across the card.
    func rule() -> TranscriptPanel {
        let rule = TranscriptPanel(); rule.cornerRadius = 0; rule.fill = TranscriptNSPalette.hair
        return rule
    }
    /// Text the reader can select, set as SwiftUI sets a `Text`.
    func text(_ face: TranscriptPlainTextFace, selectable: Bool = true) -> TranscriptPlainTextView {
        let view = TranscriptPlainTextView(); view.isSelectable = selectable
        if !selectable { view.setAccessibilityElement(false) }
        return view
    }
    func label(_ font: NSFont, digits: Bool = false) -> TranscriptLabel {
        let label = TranscriptLabel(); label.font = font; label.monospacedDigits = digits
        return label
    }
}

/// A file's path in a card that opens the file: underlined under the pointer,
/// over a press target of its own, as `TranscriptPathText` is.
@MainActor final class TranscriptNativePath {
    let label = TranscriptLabel()
    private(set) var trigger: PiPopoverTriggerButton?
    init() { label.font = TranscriptCardFaces.pathFont; label.truncation = .middle }
    func update(path: String, color: NSColor, open: (() -> Void)?, enabled: Bool, in host: NSView) {
        label.text = path; label.color = color
        // Without a link the path is words VoiceOver reads; with one, its trigger.
        label.speak(open == nil && !path.isEmpty ? path : nil)
        if let open {
            let trigger = self.trigger ?? {
                let trigger = PiPopoverTriggerButton(frame: .zero)
                trigger.setAccessibilityIdentifier("transcript-open-file")
                host.addSubview(trigger); self.trigger = trigger
                return trigger
            }()
            let name = "Open \((path as NSString).lastPathComponent)"
            trigger.setAccessibilityLabel(name)
            if trigger.toolTip != path { trigger.toolTip = path }
            trigger.onHover = { [weak label] inside in label?.underlined = inside }
            trigger.onPress = { _ in open() }
            trigger.isEnabled = enabled
        } else if let trigger {
            trigger.removeFromSuperview(); self.trigger = nil; label.underlined = false
        }
    }
    /// The line piece the path is in an `HStack`: as wide as it is, at most,
    /// and cut in its middle to fit.
    var piece: TranscriptLinePiece {
        let ideal = label.intrinsicSize, label = label
        return TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { CGSize(width: label.width(truncatedTo: $0), height: ideal.height) })
    }
    /// The path's frame and its press target's, which covers it.
    func frames(_ frame: CGRect) -> [(NSView, CGRect)] {
        [(label, frame)] + (trigger.map { [($0, frame)] } ?? [])
    }
}

/// A card's text that scrolls on its own past `cap`, as a SwiftUI
/// `ScrollView` with a `maxHeight` does: the text, selectable, as wide as
/// the section.
@MainActor final class TranscriptCappedText: NSScrollView {
    let text = TranscriptPlainTextView()
    let cap: CGFloat
    init(cap: CGFloat) {
        self.cap = cap
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = text
    }
    required init?(coder: NSCoder) { nil }
    func update(_ string: String, face: TranscriptPlainTextFace, color: NSColor, environment: TranscriptRowEnvironment) {
        text.update(text: string, face: face, environment: environment, swiftUILines: true, color: color)
        // Text that grew is scrolled through at its new height.
        tile()
    }
    /// The section's height at `width`: its text's, up to the cap.
    func height(width: CGFloat) -> CGFloat { min(text.exactHeight(width: width), cap) }
    override func tile() {
        super.tile()
        let width = contentView.bounds.width
        guard width > 0 else { return }
        let frame = CGRect(x: 0, y: 0, width: width, height: ceil(text.exactHeight(width: width)))
        if text.frame != frame { text.frame = frame }
    }
    /// A section that has nothing to scroll leaves the wheel to the
    /// conversation around it.
    override func scrollWheel(with event: NSEvent) {
        if text.frame.height <= contentView.bounds.height + 0.5 { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// A group VoiceOver reads as one thing with a name: a card's section.
@MainActor final class TranscriptCardSection: NSView {
    override var isFlipped: Bool { true }
    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
}

/// The middle of a capped list: how many lines it is not showing, and the way
/// to see them — a plain button the width of the card.
@MainActor final class TranscriptCardMoreLines: NSView {
    private let label = TranscriptLabel()
    var perform: () -> Void = {}
    var enabled = true
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = TranscriptCardFaces.codeFont
        addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    func update(hidden: Int, expanded: Bool) {
        label.text = expanded ? "Show fewer lines" : TranscriptCardMetrics.moreLines(hidden)
        label.color = TranscriptNSPalette.faint
        setAccessibilityLabel(expanded ? "Show fewer lines" : "Show \(hidden) more lines")
        needsLayout = true
    }
    /// Four points above and below its line.
    var height: CGFloat { 4 + label.intrinsicSize.height + 4 }
    override func layout() {
        super.layout()
        let size = label.intrinsicSize
        let width = min(size.width, max(0, bounds.width - 32))
        label.truncation = width < size.width ? .tail : nil
        let frame = CGRect(x: 16, y: 4, width: width, height: size.height)
        label.frame = rightToLeft ? label.mirrored(frame, width: bounds.width) : frame
    }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { perform() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
}

// MARK: - IN/OUT

/// The request and the result of one call, each in its own capped, scrolling
/// section under a gutter label that stays put while its payload scrolls.
@MainActor final class TranscriptNativeIOCard: TranscriptNativeCard {
    private let path = TranscriptNativePath()
    private let headerRule = TranscriptPanel()
    private let inSection = TranscriptCardSection(label: "Tool input")
    private let outSection = TranscriptCardSection(label: "Tool output")
    private let inLabel = TranscriptLabel(), outLabel = TranscriptLabel()
    private let inText = TranscriptCappedText(cap: TranscriptCardMetrics.sectionCap)
    private let outText = TranscriptCappedText(cap: TranscriptCardMetrics.sectionCap)
    private let middleRule = TranscriptPanel()
    private let note = TranscriptPlainTextView()
    private var hasPath = false, hasInput = false, hasOutput = false, hasNote = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        for rule in [headerRule, middleRule] { rule.cornerRadius = 0 }
        for (label, text) in [(inLabel, "IN"), (outLabel, "OUT")] { label.font = TranscriptCardFaces.gutterFont; label.text = text }
        inSection.addSubview(inLabel); inSection.addSubview(inText)
        outSection.addSubview(outLabel); outSection.addSubview(outText)
        note.isSelectable = false
        note.setAccessibilityIdentifier("tool-card-note")
        for view in [path.label, headerRule, inSection, middleRule, outSection, note] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func configure(_ card: TranscriptToolRow.Card) {
        guard case let .io(pathText, input, output, failed, noteText) = card else { return }
        hasPath = pathText != nil
        path.update(path: pathText ?? "", color: TranscriptNSPalette.muted, open: link, enabled: environment.isEnabled, in: self)
        hasInput = !input.isEmpty
        hasOutput = !(output ?? "").isEmpty
        hasNote = noteText != nil
        for rule in [headerRule, middleRule] { rule.fill = TranscriptNSPalette.hair }
        for label in [inLabel, outLabel] { label.color = TranscriptNSPalette.faint }
        inText.update(input, face: TranscriptCardFaces.code, color: TranscriptNSPalette.muted, environment: environment)
        outText.update(output ?? "", face: TranscriptCardFaces.code, color: failed ? TranscriptNSPalette.danger : TranscriptNSPalette.muted, environment: environment)
        note.update(text: noteText ?? "", face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        path.label.isHidden = !hasPath; headerRule.isHidden = !hasPath
        inSection.isHidden = !hasInput; outSection.isHidden = !hasOutput
        middleRule.isHidden = !(hasInput && hasOutput)
        note.isHidden = !hasNote
    }
    /// One section: the gutter label and, fourteen points on, its payload,
    /// twelve points of room above and below and sixteen at the sides.
    private func section(_ view: TranscriptCardSection, label: TranscriptLabel, text: TranscriptCappedText, width: CGFloat, y: CGFloat,
                         into frames: inout [(NSView, CGRect)]) -> CGFloat {
        let textWidth = max(1, width - 32 - TranscriptCardMetrics.gutter - 14)
        let labelSize = label.intrinsicSize
        let textHeight = text.height(width: textWidth)
        let height = 12 + max(labelSize.height, textHeight) + 12
        frames.append((view, CGRect(x: 0, y: y, width: width, height: height)))
        frames.append((label, CGRect(x: 16, y: y + 12, width: labelSize.width, height: labelSize.height)))
        frames.append((text, pixelAligned(CGRect(x: 16 + TranscriptCardMetrics.gutter + 14, y: y + 12, width: textWidth, height: textHeight))))
        return height
    }
    override func plan(width: CGFloat) -> Plan {
        var frames: [(NSView, CGRect)] = []
        var y: CGFloat = 0
        if hasPath {
            let line = TranscriptLineLayout.sizes([path.piece, .spacer()], spacing: [8], width: width - 32)
            frames += path.frames(CGRect(x: 16, y: 8, width: line[0].width, height: line[0].height))
            y = 8 + line[0].height + 8
            frames.append((headerRule, CGRect(x: 0, y: y, width: width, height: 1))); y += 1
        }
        if hasInput { y += section(inSection, label: inLabel, text: inText, width: width, y: y, into: &frames) }
        if hasInput && hasOutput { frames.append((middleRule, CGRect(x: 0, y: y, width: width, height: 1))); y += 1 }
        if hasOutput { y += section(outSection, label: outLabel, text: outText, width: width, y: y, into: &frames) }
        if hasNote {
            let height = note.exactHeight(width: max(1, width - 32))
            frames.append((note, CGRect(x: 16, y: y, width: max(1, width - 32), height: ceil(height))))
            y += height + 10
        }
        return Plan(frames: frames, height: y)
    }
}

// MARK: - Lines of a diff or a read

/// Rows of monospaced text one under another, each its own selectable text,
/// with a mark or a number before it: a diff's rows or a read's window. Only
/// the rows that can be seen are built, so a long list costs its height and
/// what is on screen.
@MainActor final class TranscriptCardLines: NSView {
    struct Line: Equatable {
        var mark: String
        var text: String
        var markColor: NSColor
        var background: NSColor?
    }
    enum Style { case diff, numbered }
    let style: Style
    private(set) var lines: [Line] = []
    private var environment = TranscriptRowEnvironment()
    private var heights: [(width: CGFloat, rows: [CGFloat])] = []
    @MainActor private final class Row {
        let background: TranscriptPanel?
        /// The sign or the number: selectable text, as SwiftUI's `Text` in a
        /// selectable stack was, which a number wider than its gutter wraps in.
        let mark = TranscriptPlainTextView()
        let text = TranscriptPlainTextView()
        init(background: TranscriptPanel?) { self.background = background }
        var views: [NSView] { [background, mark, text].compactMap { $0 } }
    }
    private var built: [Int: Row] = [:]
    /// Lays out every row, rather than the ones in view.
    var buildsAll = false
    override var isFlipped: Bool { true }
    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    /// What each row's mark is set in, and how far its text stands from the edge.
    private var markFont: NSFont { style == .diff ? TranscriptCardFaces.codeFont : TranscriptCardFaces.numberFont }
    private var markWidth: CGFloat { style == .diff ? 10 : 34 }
    private var gap: CGFloat { style == .diff ? 8 : 12 }
    func update(_ lines: [Line], environment: TranscriptRowEnvironment) {
        let geometry = self.environment.hasSameGeometry(as: environment)
        if lines.map(\.text) != self.lines.map(\.text) || lines.map(\.mark) != self.lines.map(\.mark) || !geometry { heights.removeAll() }
        self.lines = lines
        self.environment = environment
        for (index, row) in built {
            if index < lines.count { configure(row, lines[index]) } else { remove(index) }
        }
        needsLayout = true
    }
    private var markFace: TranscriptPlainTextFace { style == .diff ? TranscriptCardFaces.code : TranscriptCardFaces.number }
    private func configure(_ row: Row, _ line: Line) {
        row.background?.fill = line.background
        row.mark.update(text: line.mark, face: markFace, environment: environment, swiftUILines: true, color: line.markColor)
        row.text.update(text: line.text.isEmpty ? " " : line.text, face: TranscriptCardFaces.code, environment: environment,
                        swiftUILines: true, color: TranscriptNSPalette.text)
    }
    private func holdsSelection(_ index: Int) -> Bool {
        guard let row = built[index] else { return false }
        return [row.text, row.mark].contains { $0.selectedRange().length > 0 || window?.firstResponder === $0 }
    }
    private func remove(_ index: Int) {
        guard let row = built.removeValue(forKey: index) else { return }
        for view in row.views { view.removeFromSuperview() }
    }
    /// Measures a row's text without building it.
    private static let measurer: TranscriptPlainTextView = { let view = TranscriptPlainTextView(); view.isSelectable = false; return view }()
    private func rowHeights(width: CGFloat) -> [CGFloat] {
        if let known = heights.first(where: { $0.width == width }) { return known.rows }
        let rows = lines.map { rowHeight($0, width: width) }
        if heights.count == 4 { heights.removeFirst() }
        heights.append((width, rows))
        return rows
    }
    /// The lines' height at `width`, or `limit` once they reach it: what a
    /// capped scroll needs, without measuring the rows past its cap.
    func height(width: CGFloat, upTo limit: CGFloat) -> CGFloat {
        if let known = heights.first(where: { $0.width == width }) { return min(limit, known.rows.reduce(0, +)) }
        var total: CGFloat = 0
        for line in lines {
            total += rowHeight(line, width: width)
            if total >= limit { return limit }
        }
        return total
    }
    /// How many rows have been measured, as evidence for the checks.
    nonisolated(unsafe) static var rowsMeasured = 0
    private func rowHeight(_ line: Line, width: CGFloat) -> CGFloat {
        Self.rowsMeasured += 1
        let textWidth = max(1, width - 32 - markWidth - gap)
        let markHeight = TranscriptLabel.lineHeight(markFont)
        let measurer = Self.measurer
        return { () -> CGFloat in
            var mark = markHeight
            if style == .numbered {
                // A number wider than its gutter wraps there.
                measurer.update(text: line.mark, face: markFace, environment: environment, swiftUILines: true)
                mark = max(mark, measurer.exactHeight(width: markWidth))
            }
            measurer.update(text: line.text.isEmpty ? " " : line.text, face: TranscriptCardFaces.code, environment: environment, swiftUILines: true)
            return max(mark, measurer.exactHeight(width: textWidth))
        }()
    }
    func height(width: CGFloat) -> CGFloat { rowHeights(width: width).reduce(0, +) }
    /// The text view drawing line `index`, while it is built.
    func builtText(at index: Int) -> NSTextView? { built[index]?.text }
    /// Where line `index` stands among these lines, whether or not it is
    /// built: a find goes there, and the line is built as it comes into view.
    func lineRect(at index: Int) -> CGRect? {
        guard bounds.width > 0, lines.indices.contains(index) else { return nil }
        let rows = rowHeights(width: bounds.width)
        guard index < rows.count else { return nil }
        return CGRect(x: 0, y: rows[..<index].reduce(0, +), width: bounds.width, height: rows[index])
    }
    override func layout() {
        super.layout()
        mountVisibleRows()
    }
    // The rows in view follow the scroll view the lines are read through:
    // the card's own, or the conversation's.
    private weak var observedClip: NSClipView?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
        observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        needsLayout = true
    }
    @objc private func scrolled() { mountVisibleRows() }
    /// Builds and places the rows that can be seen, and lets the others go.
    func mountVisibleRows() {
        guard bounds.width > 0 else { return }
        let rows = rowHeights(width: bounds.width)
        // The scroll view's viewport around the lines, buffered as the
        // document buffers it; an empty visible rect is the lines out of it.
        let seen = visibleRect
        let viewport = seen.isEmpty ? (observedClip.map { convert($0.bounds, from: $0) } ?? .null) : seen
        // Read through no scroll view, every row is in view; out of any
        // window, none is.
        let visible = buildsAll || (window != nil && observedClip == nil) ? bounds
            : window == nil || viewport.isNull ? CGRect.null : TranscriptNativeDocument.buffered(viewport)
        let rtl = environment.layoutDirection == .rightToLeft
        let textWidth = max(1, bounds.width - 32 - markWidth - gap)
        var y: CGFloat = 0
        for (index, height) in rows.enumerated() {
            defer { y += height }
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            // A row out of view goes, unless the reader is selecting in it.
            guard (!visible.isNull && frame.intersects(visible)) || holdsSelection(index) else { remove(index); continue }
            let row = built[index] ?? {
                let made = Row(background: style == .diff ? { let panel = TranscriptPanel(); panel.cornerRadius = 0; return panel }() : nil)
                for view in made.views { addSubview(view) }
                configure(made, lines[index])
                built[index] = made
                return made
            }()
            row.background?.frame = pixelAligned(frame)
            // A number ends at the right of its gutter, its lines as wide as
            // its widest; a diff's sign stands at the left.
            let used = row.mark.usedWidth(width: markWidth)
            let markX: CGFloat = style == .numbered ? 16 + markWidth - used : 16
            row.mark.frame = TranscriptMotion.mirrored(CGRect(x: markX, y: y, width: style == .numbered ? used : markWidth,
                                                              height: ceil(row.mark.exactHeight(width: style == .numbered ? used : markWidth))),
                                                       width: bounds.width, rtl)
            row.text.frame = TranscriptMotion.mirrored(CGRect(x: 16 + markWidth + gap, y: y, width: textWidth, height: ceil(height)), width: bounds.width, rtl)
        }
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }
    /// The texts built now, for checks.
    var builtTexts: [TranscriptPlainTextView] { built.keys.sorted().compactMap { built[$0]?.text } }
    var builtCount: Int { built.count }
}

/// Lines in a scroll of their own past `cap`, building only the rows in view.
@MainActor final class TranscriptCappedLines: NSScrollView {
    let lines: TranscriptCardLines
    let cap: CGFloat
    init(style: TranscriptCardLines.Style, cap: CGFloat) {
        lines = TranscriptCardLines(style: style)
        self.cap = cap
        super.init(frame: .zero)
        drawsBackground = false; contentView.drawsBackground = false
        borderType = .noBorder; hasVerticalScroller = true; autohidesScrollers = true
        documentView = lines
    }
    required init?(coder: NSCoder) { nil }
    /// Fits the lines' new height, once they changed and can be seen.
    func refresh() { if window != nil { tile() } else { needsLayout = true } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { tile() } }
    func height(width: CGFloat) -> CGFloat { lines.height(width: width, upTo: cap) }
    override func tile() {
        super.tile()
        // Out of any window the lines wait: every row is measured only to
        // scroll through them.
        guard window != nil else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        let frame = CGRect(x: 0, y: 0, width: width, height: lines.height(width: width))
        if lines.frame != frame { lines.frame = frame }
        lines.mountVisibleRows()
    }
}

// MARK: - A diff

/// A requested file change: the rows of the diff, capped head and tail, with
/// the total the collapsed row already showed repeated at its foot.
@MainActor final class TranscriptNativeDiffCard: TranscriptNativeCard {
    private let banner = TranscriptPlainTextView()
    private let path = TranscriptNativePath()
    private let bannerRule = TranscriptPanel()
    /// What dims together when the change did not land.
    private let body = TranscriptCardBody()
    private let tooLarge = TranscriptPlainTextView()
    private let disclosure = TranscriptCardDisclosure()
    private let before = TranscriptCardSource(label: "Before")
    private let after = TranscriptCardSource(label: "After")
    private let head = TranscriptCardLines(style: .diff)
    private let tail = TranscriptCardLines(style: .diff)
    private let more = TranscriptCardMoreLines()
    private let scrolled = TranscriptCappedLines(style: .diff, cap: TranscriptCardMetrics.terminalCap)
    private let hiddenNote = TranscriptPlainTextView()
    private let incomplete = TranscriptPlainTextView()
    private let footer = TranscriptCardSection(label: "")
    private let corner = TranscriptLabel(), plus = TranscriptLabel(), minus = TranscriptLabel()
    /// Whether the reader asked for every line.
    private(set) var expanded = false
    private var request: TranscriptActivity.EditRequest?
    private var showsFooter = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        banner.isSelectable = false
        bannerRule.cornerRadius = 0
        tooLarge.setAccessibilityIdentifier("diff-too-large")
        disclosure.title = "View full content"
        disclosure.toggled = { [weak self] in self?.configureSources(); self?.invalidatePlans() }
        corner.font = TranscriptCardFaces.codeFont; corner.text = "└ "
        for label in [plus, minus] { label.font = TranscriptCardFaces.figureFont; label.monospacedDigits = true }
        for view in [corner, plus, minus] { footer.addSubview(view) }
        for view in [tooLarge, disclosure, before, after, head, more, tail, scrolled, hiddenNote, incomplete] as [NSView] { body.addSubview(view) }
        for view in [banner, path.label, bannerRule, body, footer] as [NSView] { addSubview(view) }
        more.perform = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
    }
    required init?(coder: NSCoder) { nil }
    /// Shows every line, or the head and the tail again, as the more-lines button does.
    func setExpanded(_ value: Bool) {
        expanded = value
        configureLines()
        invalidatePlans()
    }
    override func configure(_ card: TranscriptToolRow.Card) {
        guard case let .diff(request, pathText, outcome, added, removed) = card else { return }
        self.request = request
        let environment = environment
        // What became of the request. A call stopped while it ran may have
        // written already, so it is never "not applied": its outcome is unknown.
        let label = (request.mode == "edit" ? "Requested edit" : "Requested content")
            + (outcome == .done ? "" : outcome == .running ? " · in progress" : outcome == .unknown ? " · outcome unknown"
               : request.mode == "edit" ? " · not applied" : " · not written")
            + (request.complete ? "" : " · arguments truncated")
        let tint = outcome == .done ? TranscriptNSPalette.muted : [.running, .unknown].contains(outcome) ? TranscriptNSPalette.warning : TranscriptNSPalette.danger
        banner.update(text: label, face: TranscriptCardFaces.banner, environment: environment, swiftUILines: true, color: tint)
        path.update(path: pathText ?? "", color: TranscriptNSPalette.faint, open: link, enabled: environment.isEnabled, in: self)
        path.label.isHidden = pathText == nil
        bannerRule.fill = TranscriptNSPalette.hair
        body.alphaValue = [.failed, .cancelled, .unknown].contains(outcome) ? 0.72 : 1
        tooLarge.update(text: "Diff preview unavailable — \(transcriptNumber(request.lines, environment.locale)) lines. Full content is available below.", face: TranscriptCardFaces.message,
                        environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        // The whole texts are set only where they can be shown: a diff that
        // streams never copies its growing document into views nobody sees.
        configureSources()
        after.title = request.mode == "edit" ? "After" : "Content"
        for view in [before, after] { view.rightToLeft = rightToLeft }
        disclosure.rightToLeft = rightToLeft
        disclosure.enabled = environment.isEnabled
        hiddenNote.update(text: TranscriptCardMetrics.moreLines(request.hiddenRows), face: TranscriptCardFaces.code, environment: environment,
                      swiftUILines: true, color: TranscriptNSPalette.faint)
        incomplete.update(text: "The host bounded this call's arguments. This is the part that arrived, not the whole request.",
                          face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        showsFooter = !request.tooLarge || added != nil || removed != nil
        let plusCount = added ?? request.rows.filter { $0.kind == .added }.count
        let minusCount = removed ?? request.rows.filter { $0.kind == .removed }.count
        corner.color = TranscriptNSPalette.faint
        plus.text = "+\(transcriptNumber(plusCount, environment.locale))"; plus.color = TranscriptNSPalette.success
        minus.text = " −\(transcriptNumber(minusCount, environment.locale))"; minus.color = TranscriptNSPalette.danger
        footer.setAccessibilityLabel("\(plusCount) lines added, \(minusCount) removed")
        more.enabled = environment.isEnabled; more.rightToLeft = rightToLeft
        configureLines()
    }
    /// The whole texts are set only while they are shown: a write that
    /// streams never copies its growing document into views nobody sees.
    private func configureSources() {
        guard let request, request.tooLarge, disclosure.open else { return }
        before.update(request.before, environment: environment)
        after.update(request.after, environment: environment)
    }
    private var cap: (hidden: Int, capped: Bool, head: Int, tail: Int) {
        TranscriptCardMetrics.headTail(total: request?.rows.count ?? 0, maxLines: TranscriptCardMetrics.diffLines, expanded: expanded)
    }
    private func lines(_ rows: ArraySlice<DiffRow>) -> [TranscriptCardLines.Line] {
        rows.map { row in
            TranscriptCardLines.Line(mark: row.kind == .added ? "+" : row.kind == .removed ? "−" : " ", text: row.text,
                                     markColor: row.kind == .added ? TranscriptNSPalette.diffAddedMark : row.kind == .removed ? TranscriptNSPalette.danger : TranscriptNSPalette.faint,
                                     background: row.kind == .added ? TranscriptNSPalette.diffAdded : row.kind == .removed ? TranscriptNSPalette.danger.withAlphaComponent(0.1) : nil)
        }
    }
    private func configureLines() {
        guard let request else { return }
        let rows = request.rows, cap = cap
        if cap.capped {
            head.update(lines(rows.prefix(cap.head)), environment: environment)
            tail.update(lines(rows.suffix(cap.tail)), environment: environment)
            scrolled.lines.update([], environment: environment)
        } else if expanded {
            scrolled.lines.update(lines(rows[...]), environment: environment)
            scrolled.refresh()
            head.update([], environment: environment); tail.update([], environment: environment)
        } else {
            head.update(lines(rows[...]), environment: environment)
            tail.update([], environment: environment); scrolled.lines.update([], environment: environment)
        }
        more.update(hidden: cap.hidden, expanded: !cap.capped)
    }
    override func plan(width: CGFloat) -> Plan {
        guard let request else { return Plan(frames: [], height: 0) }
        var frames: [(NSView, CGRect)] = []
        // The banner: what became of the change, and the file's path.
        var pieces: [TranscriptLinePiece] = [.text(ideal: banner.idealWidth, used: { [banner] in banner.usedWidth(width: $0) },
                                                   height: { [banner] in banner.exactHeight(width: $0) }), .spacer()]
        if !path.label.isHidden { pieces.append(path.piece) }
        let spacing = [CGFloat](repeating: 8, count: pieces.count - 1)
        let sizes = TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width - 32)
        let line = sizes.map(\.height).max() ?? 0
        let placed = TranscriptLineLayout.frames(sizes, spacing: spacing, x: 16, midY: 8 + line / 2)
        frames.append((banner, CGRect(x: placed[0].minX, y: placed[0].minY, width: placed[0].width, height: ceil(placed[0].height))))
        if !path.label.isHidden { frames += path.frames(placed[2]) }
        var y = 8 + line + 8
        frames.append((bannerRule, CGRect(x: 0, y: y, width: width, height: 1))); y += 1
        // The body, which dims as one when the change did not land.
        var inner: [(NSView, CGRect)] = []
        let top = y
        var b: CGFloat = 0
        let textWidth = max(1, width - 32)
        func hide(_ views: NSView...) { for view in views { view.isHidden = true } }
        func show(_ view: NSView, _ frame: CGRect) { view.isHidden = false; inner.append((view, frame.offsetBy(dx: 0, dy: top))) }
        if request.tooLarge {
            let height = tooLarge.exactHeight(width: textWidth)
            show(tooLarge, CGRect(x: 16, y: b + 8, width: textWidth, height: ceil(height))); b += 8 + height + 8
            show(disclosure, CGRect(x: 16, y: b + 8, width: textWidth, height: disclosure.headerHeight))
            // What it opens stands under its line, set in past the triangle.
            var s = b + 8 + disclosure.headerHeight
            if disclosure.open {
                for source in request.mode == "edit" ? [before, after] : [after] {
                    let height = source.height(width: textWidth - disclosure.indent)
                    show(source, CGRect(x: 16 + disclosure.indent, y: s, width: textWidth - disclosure.indent, height: height))
                    s += height
                }
                if request.mode != "edit" { hide(before) }
            } else { hide(before, after) }
            b = s + 8
        } else { hide(tooLarge, disclosure, before, after) }
        let cap = cap
        if cap.capped {
            let headHeight = head.height(width: width)
            show(head, CGRect(x: 0, y: b, width: width, height: headHeight)); b += headHeight
            show(more, CGRect(x: 0, y: b, width: width, height: more.height)); b += more.height
            let tailHeight = tail.height(width: width)
            show(tail, CGRect(x: 0, y: b, width: width, height: tailHeight)); b += tailHeight
            hide(scrolled)
        } else {
            hide(tail)
            if expanded {
                let height = scrolled.height(width: width)
                show(scrolled, pixelAligned(CGRect(x: 0, y: b, width: width, height: height))); b += height
                hide(head)
            } else {
                let height = head.height(width: width)
                show(head, CGRect(x: 0, y: b, width: width, height: height)); b += height
                hide(scrolled)
            }
            if TranscriptCardMetrics.collapses(hidden: cap.hidden) {
                show(more, CGRect(x: 0, y: b, width: width, height: more.height)); b += more.height
            } else { hide(more) }
        }
        if request.hiddenRows > 0 {
            let height = hiddenNote.exactHeight(width: textWidth)
            show(hiddenNote, CGRect(x: 16, y: b + 2, width: textWidth, height: ceil(height))); b += 2 + height + 2
        } else { hide(hiddenNote) }
        if !request.complete {
            let height = incomplete.exactHeight(width: textWidth)
            show(incomplete, CGRect(x: 16, y: b + 6, width: textWidth, height: ceil(height))); b += 6 + height + 6
        } else { hide(incomplete) }
        frames.append((body, CGRect(x: 0, y: y, width: width, height: b))); frames += inner; y += b
        if showsFooter {
            let parts = [corner, plus, minus].map(\.intrinsicSize)
            let height = parts.map(\.height).max() ?? 0
            footer.isHidden = false
            frames.append((footer, CGRect(x: 0, y: y, width: width, height: 6 + height + 6)))
            var x: CGFloat = 16
            for (view, size) in zip([corner, plus, minus], parts) {
                frames.append((view, CGRect(x: x, y: y + 6 + (height - size.height) / 2, width: size.width, height: size.height)))
                x += size.width
            }
            y += 6 + height + 6
        } else { footer.isHidden = true }
        return Plan(frames: frames, height: y)
    }
}

/// A card's part that dims as one.
@MainActor final class TranscriptCardBody: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
}

/// "View full content": a disclosure triangle and its title, as SwiftUI's
/// `DisclosureGroup` draws one, opening what it holds under it.
@MainActor final class TranscriptCardDisclosure: NSView {
    private let button = NSButton()
    private let label = TranscriptLabel()
    var title = "" { didSet { label.text = title; button.setAccessibilityLabel(title) } }
    var open = false
    var enabled = true { didSet { button.isEnabled = enabled } }
    var toggled: () -> Void = {}
    /// How far what it opens is set in, and how tall its own line is.
    /// (Not measured: SwiftUI's opened group could not be opened in a
    /// test; what it opens lines up with its title.)
    let indent: CGFloat = 11.5
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    var headerHeight: CGFloat { 24 }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .disclosure
        button.setButtonType(.pushOnPushOff)
        button.title = ""
        button.target = self; button.action = #selector(flip)
        label.font = .systemFont(ofSize: 13)
        label.color = .labelColor
        addSubview(button); addSubview(label)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func flip() { open = button.state == .on; toggled() }
    func height(width: CGFloat) -> CGFloat { headerHeight }
    override func layout() {
        super.layout()
        let size = button.fittingSize
        // Where SwiftUI's `DisclosureGroup` puts its triangle and its title (measured).
        button.frame = TranscriptMotion.mirrored(CGRect(x: -3.5, y: (headerHeight - size.height) / 2, width: size.width, height: size.height),
                                                 width: bounds.width, rightToLeft)
        let text = label.intrinsicSize
        label.frame = TranscriptMotion.mirrored(CGRect(x: 11.5, y: (headerHeight - text.height) / 2, width: text.width, height: text.height),
                                                of: label, width: bounds.width, rightToLeft)
    }
}

/// One side of a change too large to diff: its label and its text, which
/// scrolls on its own past the terminal's cap.
@MainActor final class TranscriptCardSource: NSView {
    private let label = TranscriptLabel()
    private let text = TranscriptCappedText(cap: TranscriptCardMetrics.terminalCap)
    var title: String { get { label.text } set { label.text = newValue; label.speak(newValue) } }
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    override var isFlipped: Bool { true }
    init(label title: String) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11.5, weight: .medium); label.text = title
        label.speak(title)
        addSubview(label); addSubview(text)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ string: String, environment: TranscriptRowEnvironment) {
        label.color = TranscriptNSPalette.faint
        text.update(string, face: TranscriptCardFaces.code, color: TranscriptNSPalette.text, environment: environment)
    }
    func height(width: CGFloat) -> CGFloat { label.intrinsicSize.height + 4 + text.height(width: width) }
    override func layout() {
        super.layout()
        let size = label.intrinsicSize
        label.frame = TranscriptMotion.mirrored(CGRect(x: 0, y: 0, width: size.width, height: size.height), of: label, width: bounds.width, rightToLeft)
        text.frame = CGRect(x: 0, y: size.height + 4, width: bounds.width, height: text.height(width: bounds.width))
    }
}

// MARK: - A read

/// A file read: the window that came back, numbered as the file numbers it,
/// and how much of the result the card is showing.
@MainActor final class TranscriptNativeReadCard: TranscriptNativeCard {
    private let path = TranscriptNativePath()
    private let windowLabel = TranscriptLabel()
    private let headerRule = TranscriptPanel()
    private let body = TranscriptCardBody()
    private let head = TranscriptCardLines(style: .numbered)
    private let tail = TranscriptCardLines(style: .numbered)
    private let more = TranscriptCardMoreLines()
    private let note = TranscriptPlainTextView()
    private(set) var expanded = false
    private var lines: [String] = []
    private var firstLine = 1
    private var hasPath = false, hasNote = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        windowLabel.font = TranscriptCardFaces.pathFont; windowLabel.monospacedDigits = true
        headerRule.cornerRadius = 0
        note.setAccessibilityIdentifier("read-card-note")
        for view in [head, more, tail, note] as [NSView] { body.addSubview(view) }
        for view in [path.label, windowLabel, headerRule] as [NSView] { body.addSubview(view) }
        addSubview(body)
        more.perform = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
    }
    required init?(coder: NSCoder) { nil }
    func setExpanded(_ value: Bool) { expanded = value; configureLines(); invalidatePlans() }
    override func configure(_ card: TranscriptToolRow.Card) {
        guard case let .read(text, firstLine, pathText, failed) = card else { return }
        let window = TranscriptReadCardText.window(of: text)
        lines = window.lines; self.firstLine = max(1, firstLine)
        hasPath = pathText != nil; hasNote = window.note != nil
        path.update(path: pathText ?? "", color: TranscriptNSPalette.muted, open: link, enabled: environment.isEnabled, in: body)
        path.label.isHidden = !hasPath
        headerRule.fill = TranscriptNSPalette.hair
        note.update(text: window.note ?? "", face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        note.isHidden = !hasNote
        body.alphaValue = failed ? 0.72 : 1
        more.enabled = environment.isEnabled; more.rightToLeft = rightToLeft
        configureLines()
    }
    private var cap: (hidden: Int, capped: Bool, head: Int, tail: Int) {
        TranscriptCardMetrics.headTail(total: lines.count, maxLines: TranscriptCardMetrics.readLines, expanded: expanded)
    }
    private func numbered(_ lines: ArraySlice<String>, from start: Int) -> [TranscriptCardLines.Line] {
        lines.enumerated().map { offset, line in
            TranscriptCardLines.Line(mark: transcriptNumber(start + offset, environment.locale), text: line, markColor: TranscriptNSPalette.faint, background: nil)
        }
    }
    private func configureLines() {
        let cap = cap
        let shown = cap.capped ? cap.head + cap.tail : lines.count
        windowLabel.text = TranscriptReadCardText.window(shown: shown, total: lines.count)
        windowLabel.color = TranscriptNSPalette.faint
        windowLabel.speak(windowLabel.text, identifier: "read-card-window")
        if cap.capped {
            head.update(numbered(lines.prefix(cap.head), from: firstLine), environment: environment)
            tail.update(numbered(lines.suffix(cap.tail), from: firstLine + lines.count - cap.tail), environment: environment)
        } else {
            head.update(numbered(lines[...], from: firstLine), environment: environment)
            tail.update([], environment: environment)
        }
        more.update(hidden: cap.hidden, expanded: !cap.capped)
    }
    override func plan(width: CGFloat) -> Plan {
        var inner: [(NSView, CGRect)] = []
        var pieces: [TranscriptLinePiece] = []
        if hasPath { pieces.append(path.piece) }
        pieces += [.spacer(), .fixed(windowLabel.intrinsicSize)]
        let spacing = [CGFloat](repeating: 8, count: pieces.count - 1)
        let sizes = TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width - 32)
        let line = sizes.map(\.height).max() ?? 0
        let placed = TranscriptLineLayout.frames(sizes, spacing: spacing, x: 16, midY: 8 + line / 2)
        if hasPath { inner += path.frames(placed[0]) }
        inner.append((windowLabel, placed[placed.count - 1]))
        var y = 8 + line + 8
        inner.append((headerRule, CGRect(x: 0, y: y, width: width, height: 1))); y += 1
        let cap = cap
        let headHeight = head.height(width: width)
        inner.append((head, CGRect(x: 0, y: y, width: width, height: headHeight))); y += headHeight
        if cap.capped || TranscriptCardMetrics.collapses(hidden: cap.hidden) {
            more.isHidden = false
            inner.append((more, CGRect(x: 0, y: y, width: width, height: more.height))); y += more.height
        } else { more.isHidden = true }
        if cap.capped {
            tail.isHidden = false
            let tailHeight = tail.height(width: width)
            inner.append((tail, CGRect(x: 0, y: y, width: width, height: tailHeight))); y += tailHeight
        } else { tail.isHidden = true }
        if hasNote {
            let height = note.exactHeight(width: max(1, width - 32))
            inner.append((note, CGRect(x: 16, y: y + 8, width: max(1, width - 32), height: ceil(height)))); y += 8 + height + 8
        }
        return Plan(frames: [(body, CGRect(x: 0, y: 0, width: width, height: y))] + inner, height: y)
    }
}

// MARK: - A command

/// A command and what it printed.
@MainActor final class TranscriptNativeTerminalCard: TranscriptNativeCard {
    private let prompt = TranscriptLabel()
    private let command = TranscriptPlainTextView()
    private let rule = TranscriptPanel()
    private let output = TranscriptCappedText(cap: TranscriptCardMetrics.terminalCap)
    private var hasOutput = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        prompt.font = TranscriptCardFaces.codeFont; prompt.text = "$"
        rule.cornerRadius = 0
        output.setAccessibilityLabel("Command output")
        for view in [prompt, command, rule, output] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func configure(_ card: TranscriptToolRow.Card) {
        guard case let .terminal(commandText, outputText, failed) = card else { return }
        prompt.color = TranscriptNSPalette.faint
        command.update(text: commandText, face: TranscriptCardFaces.code, environment: environment, swiftUILines: true, color: TranscriptNSPalette.text)
        hasOutput = !outputText.isEmpty
        rule.fill = TranscriptNSPalette.hair
        output.update(outputText, face: TranscriptCardFaces.code, color: failed ? TranscriptNSPalette.danger : TranscriptNSPalette.muted, environment: environment)
        rule.isHidden = !hasOutput; output.isHidden = !hasOutput
    }
    override func plan(width: CGFloat) -> Plan {
        var frames: [(NSView, CGRect)] = []
        let promptSize = prompt.intrinsicSize
        let commandWidth = max(1, width - 32 - promptSize.width - 8)
        let commandHeight = command.exactHeight(width: commandWidth)
        let line = max(promptSize.height, commandHeight)
        frames.append((prompt, CGRect(x: 16, y: 10, width: promptSize.width, height: promptSize.height)))
        frames.append((command, CGRect(x: 16 + promptSize.width + 8, y: 10, width: commandWidth, height: ceil(commandHeight))))
        var y = 10 + line + 10
        if hasOutput {
            frames.append((rule, CGRect(x: 0, y: y, width: width, height: 1))); y += 1
            let height = output.height(width: max(1, width - 32))
            frames.append((output, pixelAligned(CGRect(x: 16, y: y + 10, width: max(1, width - 32), height: height))))
            y += 10 + height + 10
        }
        return Plan(frames: frames, height: y)
    }
}
