import AppKit

// The AppKit views the inspector's outline is drawn with: the outline view,
// its two row backgrounds, and a cell for each kind of row — a heading or
// link, one line of a preview, and a whole text.

/// The outline without the system disclosure triangle: each row draws its own
/// chevron, and a right click builds its menu on the spot.
final class InspectorOutlineView: NSOutlineView {
    weak var coordinator: InspectorItemsOutline.Coordinator?
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let node = item(atRow: row) as? InspectorItemsOutline.Node, let coordinator else { return nil }
        return coordinator.menu(for: node)
    }
    override func keyDown(with event: NSEvent) {
        // Return and space open or close the row under the selection, or
        // press its link.
        if [36, 49].contains(event.keyCode), selectedRow >= 0, let node = item(atRow: selectedRow) as? InspectorItemsOutline.Node {
            coordinator?.activate(node, in: self, keyboard: true); return
        }
        super.keyDown(with: event)
    }
    /// A press in a whole text selects in it, rather than the row.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is InspectorTextView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// A row's background: a soft rounded fill under the pointer.
final class InspectorOutlineRowView: NSTableRowView {
    var hoverable = true
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = hoverable }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func prepareForReuse() { super.prepareForReuse(); hovering = false }
    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.piFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// The row of a whole text: it draws nothing, so a row taller than any layer
/// holds no backing store, and its text view draws only what is on screen.
final class InspectorTextRowView: NSTableRowView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// A whole text in the outline: the expansion's text view, where the preview's
/// lines were drawn. It tells the expansion the width it has; the text is laid
/// out to a new width on the worker.
final class InspectorFullTextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("inspector-full-text-cell")
    /// Where the preview's lines start, and end, in their cells.
    static let leading: CGFloat = 30
    static let trailing: CGFloat = 12
    /// Room under the text, before "Show less".
    static let bottom: CGFloat = 4
    private(set) weak var expansion: InspectorExpansion?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        clipsToBounds = true
        // The text view is the element: a text area with the whole text.
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func show(_ expansion: InspectorExpansion?) {
        self.expansion = expansion
        let view = expansion?.textView
        for case let other as InspectorTextView in subviews where other !== view { other.removeFromSuperview() }
        if let view, view.superview !== self { addSubview(view) }
        needsLayout = true
    }
    /// The text view hosted now, for tests.
    var textView: InspectorTextView? { subviews.lazy.compactMap { $0 as? InspectorTextView }.first }
    override func setFrameSize(_ newSize: NSSize) {
        let wider = newSize.width != frame.width
        super.setFrameSize(newSize)
        if wider { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let expansion else { return }
        if let view = expansion.textView, view.superview === self {
            let frame = NSRect(x: Self.leading, y: 0, width: view.laidOut.width, height: view.laidOut.height)
            if view.frame != frame { view.frame = frame }
        }
        expansion.offer(width: bounds.width - Self.leading - Self.trailing)
    }
}

/// A heading row: a section, the earlier context, a page of items, an item or
/// a link ("Show all", "Show less"). It draws itself: no subviews and no
/// constraints, so a page of new rows costs the main thread almost nothing to
/// lay out.
final class InspectorRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("inspector-row-cell")
    /// What pressing a link row does, for VoiceOver and keyboard access.
    var press: (() -> Void)? {
        didSet { setAccessibilityRole(press == nil ? .staticText : .button) }
    }
    private var expandable = false
    private var expanded = false
    private var leadingInset: CGFloat = 6
    private var showsChevron = true
    private var symbol: String?
    private var tint: NSColor = .piInkTertiary
    private var title = ""
    private var titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var titleColor: NSColor = .piInk
    private var detail = ""
    private var detailFont = NSFont.systemFont(ofSize: 12)
    private var detailColor: NSColor = .piInkSecondary
    private var size = ""
    /// A capsule after the title: NEW, or a summary request's name.
    private var badge: String?
    private var badgeFont = InspectorRowCell.badgeFont
    /// The detail repeats the first line: an open row, whose lines follow, leaves it out.
    private var detailRepeatsLines = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // The cell draws its words, so it says them itself.
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }

    func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded; needsDisplay = true
    }

    func configure(_ node: InspectorItemsOutline.Node, expanded: Bool, link: InspectorLink? = nil) {
        expandable = node.expandable; self.expanded = expanded; detailRepeatsLines = false
        leadingInset = 6; showsChevron = true; badge = nil; badgeFont = Self.badgeFont; symbol = nil; tint = .piInkTertiary
        title = ""; titleFont = .systemFont(ofSize: 13, weight: .medium); titleColor = .piInk
        detail = ""; detailFont = .systemFont(ofSize: 12); detailColor = .piInkSecondary; size = ""
        switch node.kind {
        case .summary(let heading):
            symbol = "arrow.down.right.and.arrow.up.left"; tint = .piAccent
            title = "Summary request"
            badge = heading.name; badgeFont = Self.nameFont
            detail = heading.subject; detailColor = .piInkTertiary
            size = RequestDocument.charactersLabel(heading.info.characters)
            setAccessibilityLabel("Summary request, " + heading.name + ", " + heading.subject)
        case .section(let section):
            symbol = section.id == .system ? "text.alignleft" : section.id == .tools ? "hammer" : "slider.horizontal.3"
            title = section.title; titleColor = .piInkSecondary
            detail = section.summary; detailColor = .piInkTertiary
            size = RequestDocument.byteLabel(section.size)
            setAccessibilityLabel(section.title + ", " + section.summary)
        case .earlier(let count, let characters):
            symbol = "clock.arrow.circlepath"
            title = "Earlier context"; titleColor = .piInkSecondary
            detail = "\(count) item" + (count == 1 ? "" : "s") + " sent before, unchanged"; detailColor = .piInkTertiary
            size = RequestDocument.charactersLabel(characters)
            setAccessibilityLabel("Earlier context, \(count) items")
        case .group(let range, let characters, let isNew):
            symbol = "square.stack"
            title = "Items \(range.lowerBound + 1)–\(range.upperBound)"
            detail = "\(range.count) items"; detailColor = .piInkTertiary
            badge = isNew ? "NEW" : nil
            size = RequestDocument.charactersLabel(characters)
            setAccessibilityLabel("Items \(range.lowerBound + 1) to \(range.upperBound)" + (isNew ? ", new" : ""))
        case .item(let item, let isNew):
            let (name, color) = Self.symbol(item.kind)
            symbol = name; tint = color
            if item.kind == .toolCall {
                title = item.title + "(" + (item.detail ?? "") + ")"
                titleFont = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
            } else {
                title = item.title
                detail = item.detail ?? Self.firstLine(item)
                detailRepeatsLines = item.detail == nil
            }
            badge = isNew ? "NEW" : nil
            size = RequestDocument.charactersLabel(item.characters)
            setAccessibilityLabel(item.title + (isNew ? ", new" : "") + ", " + (item.detail ?? ""))
        case .entry(let entry, let mono):
            showsChevron = false; leadingInset = 30
            title = entry.name
            titleFont = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12.5, weight: .medium)
            titleColor = mono ? .piInkSecondary : .piInk
            detail = entry.value; detailColor = mono ? .piInk : .piInkSecondary
            detailFont = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            size = entry.detail ?? ""
            setAccessibilityLabel(entry.name + ": " + entry.value)
        case .more, .reveal, .less:
            let link = link ?? InspectorLink(symbol: "arrow.up.left.and.arrow.down.right", title: "")
            showsChevron = false; leadingInset = 26
            symbol = link.symbol
            let ink: NSColor = link.tone == .warning ? .piWarning : link.tone == .quiet ? .piInkTertiary : .piAccent
            tint = ink; title = link.title; titleColor = ink; titleFont = .systemFont(ofSize: 12, weight: .medium)
            detail = link.detail; detailColor = .piInkTertiary; detailFont = .systemFont(ofSize: 11.5)
            size = link.size
            setAccessibilityLabel(link.detail.isEmpty ? link.title : link.title + ", " + link.detail)
        case .line, .text:
            break
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x = leadingInset
        if showsChevron {
            if expandable { Self.drawSymbol(expanded ? "chevron.down" : "chevron.right", pointSize: 9, weight: .semibold, color: .piInkTertiary, center: NSPoint(x: x + 5, y: mid)) }
            x += 16
        }
        if let symbol { Self.drawSymbol(symbol, pointSize: 12, weight: .medium, color: tint, center: NSPoint(x: x + 9, y: mid)); x += 24 }
        var right = bounds.maxX - 12
        if !size.isEmpty {
            let width = Self.width(size, font: Self.sizeFont)
            Self.drawLine(size, font: Self.sizeFont, color: .piInkTertiary, in: NSRect(x: right - width, y: mid, width: width + 1, height: 0))
            right -= width + 12
        }
        guard right > x else { return }
        x += Self.drawLine(title, font: titleFont, color: titleColor, in: NSRect(x: x, y: mid, width: right - x, height: 0)) + 8
        if let badge, x + Self.badgeWidth(badge, font: badgeFont) < right {
            x = Self.drawBadge(badge, font: badgeFont, at: NSPoint(x: x, y: mid)) + 8
        }
        if !detail.isEmpty, !(expanded && detailRepeatsLines), right - x > 24 {
            Self.drawLine(detail, font: detailFont, color: detailColor, in: NSRect(x: x, y: mid, width: right - x, height: 0))
        }
    }

    /// One line of text, vertically centred on `rect.minY`, cut with an
    /// ellipsis at `rect.width`: a Core Text line, much cheaper to make and
    /// draw than laying the string out through the text system. Returns the
    /// width drawn.
    @discardableResult
    static func drawLine(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) -> CGFloat {
        guard !text.isEmpty, rect.width > 4, let context = NSGraphicsContext.current?.cgContext else { return 0 }
        // A row shows a line at most: nothing past this many characters could fit.
        let string = text.utf16.count > 400 ? String(text.prefix(400)) : text
        let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        if width > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            if let cut = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) {
                line = cut; width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        context.saveGState()
        // The row is flipped; Core Text draws upright in an unflipped text space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: rect.minX, y: (rect.minY + (ascent - descent) / 2).rounded())
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
    /// A line's width, measured the way `drawLine` draws it.
    static func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = text.utf16.count > 400 ? String(text.prefix(400)) : text
        return ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font])), nil, nil, nil)))
    }

    /// Symbol images by name, size, weight, colour and appearance: a page of
    /// rows shares a handful, and looking one up is not free.
    @MainActor private static var symbols: [String: NSImage] = [:]
    static func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, center: NSPoint) {
        let appearance = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(ObjectIdentifier(color).hashValue)|\(appearance)"
        let image: NSImage
        if let cached = symbols[key] { image = cached }
        else {
            // The colour resolved now, for this appearance: the cached image never changes with it.
            var resolved = color
            NSAppearance.currentDrawing().performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [resolved]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            if symbols.count > 256 { symbols.removeAll() }
            symbols[key] = made; image = made
        }
        let size = image.size
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    /// A summary request's name, as `PiBadge` sets it.
    static let nameFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static func badgeWidth(_ text: String, font: NSFont) -> CGFloat { width(text, font: font) + 13 }

    /// A mark after the title (NEW, a summary request's name): the accent on a
    /// soft accent capsule. Returns its right edge.
    static func drawBadge(_ text: String, font: NSFont, at origin: NSPoint) -> CGFloat {
        let capsule = NSRect(x: origin.x, y: origin.y - 8, width: badgeWidth(text, font: font), height: 16)
        NSColor.piAccentSoft.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 8, yRadius: 8).fill()
        drawLine(text, font: font, color: .piAccent, in: NSRect(x: capsule.minX + 6.5, y: capsule.midY, width: capsule.width, height: 0))
        return capsule.maxX
    }

    static func symbol(_ kind: RequestDocument.Item.Kind) -> (String, NSColor) {
        switch kind {
        case .user: return ("person.crop.circle", .piInfo)
        case .assistant: return ("sparkle", .piAccent)
        case .system, .developer: return ("text.alignleft", .piInkSecondary)
        case .toolCall: return ("arrow.right.circle", .piWarning)
        case .toolResult: return ("arrow.left.circle", .piSuccess)
        case .reasoning: return ("brain", .piPurple)
        case .image: return ("photo", .piInkSecondary)
        case .other: return ("curlybraces", .piInkTertiary)
        }
    }
    private static func firstLine(_ item: RequestDocument.Item) -> String {
        item.lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

/// One line of an item's preview, drawn. Copy is on the row's right-click
/// menu, and "Show all" puts the whole text, selectable, in the preview's place.
final class InspectorLineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("inspector-line-cell")
    static let monoFont = NSFont.monospacedSystemFont(ofSize: InspectorTextStyle.monoSize, weight: .regular)
    static let textFont = NSFont.systemFont(ofSize: InspectorTextStyle.textSize)
    private var text = ""
    private var mono = false
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func configure(text: String, mono: Bool) {
        self.text = text; self.mono = mono
        setAccessibilityValue(text)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        InspectorRowCell.drawLine(text, font: mono ? Self.monoFont : Self.textFont, color: mono ? .piInkSecondary : .piInk,
                                  in: NSRect(x: InspectorFullTextCell.leading, y: bounds.midY, width: bounds.width - InspectorFullTextCell.leading - InspectorFullTextCell.trailing, height: 0))
    }
}
