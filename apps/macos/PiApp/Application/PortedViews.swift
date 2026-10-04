import AppKit

// Small AppKit pieces the screens ported from SwiftUI share (0.1.120): a
// hairline, a filled background, a plain text button, a symbol button, a
// label with its symbol, selectable one-line text, a popover over a view, a
// view whose right click builds a menu, and a centred notice. Each draws what
// its SwiftUI form drew, measured as `PiKit` measures text and symbols.

/// A view filled with one colour, followed through appearance changes
/// (`Rectangle().fill(...)`, `.background(...)`).
@MainActor class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(color) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A one-point hairline: frame it one point thick.
@MainActor final class HairlineView: FillView {
    init() { super.init(.piHairline) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A button with no chrome: its words in a font and colour
/// (`.buttonStyle(.plain)` over a `Text`). Dimmed when disabled, as SwiftUI
/// dims a plain button's label.
@MainActor final class PlainTextButton: PiKit.ButtonBase {
    var line: PiKit.Line { didSet { invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(line.text) } }
    init(_ title: String, font: NSFont, color: NSColor, action: (() -> Void)? = nil) {
        line = PiKit.Line(title, font: font, color: color)
        super.init(frame: .zero)
        pressScales = false
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = action
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) { line.draw(in: rect, scale: piScale) }
}

/// A symbol as a plain button, in a frame of its own size: the Changes
/// panel's ticks (`checkmark.square.fill`, `minus.square.fill`, `square`).
@MainActor final class SymbolButton: PiKit.ButtonBase {
    var symbol: PiKit.Symbol { didSet { redrawContent() } }
    var color: NSColor { didSet { redrawContent() } }
    let side: CGSize
    init(symbol: PiKit.Symbol, color: NSColor, size: CGSize, label: String, action: (() -> Void)? = nil) {
        self.symbol = symbol; self.color = color; side = size
        super.init(frame: CGRect(origin: .zero, size: size))
        pressScales = false
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = action
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { side }
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) { SymbolButton.draw(symbol, centredIn: rect, color: color, scale: piScale) }
    /// A symbol centred in a frame larger than it, as `Image` in `.frame(width:height:)`:
    /// its image's top on the pixel grid.
    static func draw(_ symbol: PiKit.Symbol, centredIn rect: CGRect, color: NSColor, scale: CGFloat) {
        guard let image = symbol.image(color),
              let base = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbol.size, weight: symbol.weight)) else { return }
        let drawn = image.size, align = base.alignmentRect
        // The alignment box on the pixel grid, the image around it.
        let x = PiKit.round(rect.midX - align.width / 2, scale) - align.minX
        let y = PiKit.round(rect.midY - align.height / 2, scale) - (drawn.height - align.maxY)
        image.draw(in: CGRect(x: x, y: y, width: drawn.width, height: drawn.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// `Label(title, systemImage:)` as text: the symbol in the text's font, then
/// the title, on one line; the title is cut (in the middle, or at the end)
/// when the label is narrower than it.
@MainActor final class LabelView: NSView {
    var line: PiKit.Line { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(line.text) } }
    var symbolName: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var truncation: CTLineTruncationType = .end
    /// Between the symbol and the title.
    static let spacing: CGFloat = 8
    init(_ line: PiKit.Line, symbol: String) {
        self.line = line; symbolName = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(line.text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var glyph: PiKit.Symbol { PiKit.Symbol(symbolName, size: line.font.pointSize, weight: line.font.piWeight) }
    var symbolWidth: CGFloat { glyph.layoutSize.width + Self.spacing }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale), image = glyph.layoutSize
        return NSSize(width: image.width + Self.spacing + text.width, height: max(text.height, image.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        let image = glyph.layoutSize, text = line.size(scale: piScale)
        glyph.draw(centredIn: CGRect(x: 0, y: 0, width: image.width, height: bounds.height), color: line.color, scale: piScale)
        let x = image.width + Self.spacing
        line.draw(in: CGRect(x: x, y: PiKit.round((bounds.height - text.height) / 2, piScale), width: max(0, bounds.width - x), height: text.height),
                  truncation: truncation, scale: piScale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `Label(text, systemImage:)` whose text wraps: the symbol beside the first
/// line, the text in the rest of the width.
@MainActor final class WrappingLabelView: NSView, PiKit.WidthSizing {
    private let block: TextBlock
    private let font: NSFont
    private let symbolName: String
    var text: String { get { block.text } set { block.text = newValue; setAccessibilityLabel(newValue); needsLayout = true } }
    init(font: NSFont, color: NSColor, symbol: String) {
        self.font = font; symbolName = symbol
        block = TextBlock("", font: font, color: color)
        super.init(frame: .zero)
        addSubview(block)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var glyph: PiKit.Symbol { PiKit.Symbol(symbolName, size: font.pointSize, weight: font.piWeight) }
    private var indent: CGFloat { glyph.layoutSize.width + LabelView.spacing }
    func height(forWidth width: CGFloat) -> CGFloat { max(block.height(forWidth: max(0, width - indent)), glyph.layoutSize.height) }
    override func layout() {
        super.layout()
        block.frame = CGRect(x: indent, y: 0, width: max(0, bounds.width - indent), height: block.height(forWidth: max(0, bounds.width - indent)))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let line = PiKit.Line("", font: font, color: block.color).lineHeight
        glyph.draw(centredIn: CGRect(x: 0, y: 0, width: glyph.layoutSize.width, height: line), color: block.color, scale: piScale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSFont {
    /// The font's weight, as `Symbol` takes it.
    var piWeight: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat).map { NSFont.Weight($0) } ?? .regular
    }
}

/// One line of text the reader can select and copy (`.textSelection(.enabled)`
/// on a one-line `Text`), placed where `Text` puts its glyphs: the field's
/// cell inset is taken back on either side.
@MainActor final class SelectableLine: NSTextField {
    let lineFont: NSFont
    init(_ text: String, font: NSFont, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail) {
        lineFont = font
        super.init(frame: .zero)
        isEditable = false; isSelectable = true; isBordered = false; isBezeled = false; drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true; cell?.wraps = false; cell?.isScrollable = false
        lineBreakMode = truncation; cell?.truncatesLastVisibleLine = true
        self.font = font; textColor = color
        stringValue = text
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    var text: String {
        get { stringValue }
        set { if stringValue != newValue { stringValue = newValue; invalidateIntrinsicContentSize() } }
    }
    /// The text's own size, as `Text` measures it.
    var textSize: CGSize { PiKit.Line(stringValue, font: lineFont, color: .black).size(scale: window?.backingScaleFactor ?? 2) }
    /// Puts the glyphs at `frame` as `Text` would place them there.
    func place(_ frame: CGRect) {
        self.frame = CGRect(x: frame.minX - PiKit.fieldInset, y: frame.minY, width: frame.width + PiKit.fieldInset * 2, height: frame.height)
    }
}

/// A view that builds its right-click menu when asked: its rows' context menus.
@MainActor final class MenuHostView: NSView {
    var entries: (() -> [PiMenuEntry])?
    override var isFlipped: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = entries?(), !entries.isEmpty else { return nil }
        return PiMenus.menu(entries)
    }
}

/// A popover with AppKit content, as SwiftUI's `.popover(isPresented:arrowEdge:)`
/// shows one: transient, its arrow on the anchor's edge, the content at its
/// own size.
@MainActor final class AnchoredPopover: NSObject, NSPopoverDelegate {
    private(set) var popover: NSPopover?
    var isShown: Bool { popover?.isShown == true }
    var onClose: (() -> Void)?
    /// Shows `content` (sized by its fitting size, `width` wide) below `anchor`.
    func show(_ content: NSView, width: CGFloat, below anchor: NSView, focus: NSView? = nil) {
        close()
        let controller = NSViewController()
        let height = PiKit.height(of: content, width: width)
        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view = content
        controller.preferredContentSize = content.frame.size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !PiKit.Motion.reduced
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        if let focus { content.window?.makeFirstResponder(focus) }
    }
    func close() { popover?.close() }
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        onClose?()
    }
}

/// A centred notice in place of content: a large symbol, a title and a
/// sentence or two, and optionally a button, each 12 points apart.
@MainActor final class NoticeView: NSView {
    private let symbol: PiKit.SymbolView
    private let title: PiKit.TextLine
    let detail: TextBlock
    let button: NSView?
    /// The detail's widest.
    var detailWidth: CGFloat = 360
    var spacing: CGFloat = PiSpacing.md
    var padding: CGFloat = PiSpacing.xl
    init(symbol: PiKit.Symbol, symbolColor: NSColor = .piInkTertiary, title: String, titleFont: NSFont = PiKit.Font.heading,
         detail: String, detailFont: NSFont = PiKit.Font.body, button: NSView? = nil) {
        self.symbol = PiKit.SymbolView(symbol, color: symbolColor)
        self.title = PiKit.TextLine(PiKit.Line(title, font: titleFont, color: .piInk))
        self.detail = TextBlock(detail, font: detailFont, color: .piInkSecondary, centred: true)
        self.button = button
        super.init(frame: .zero)
        for view in [self.symbol, self.title, self.detail] as [NSView] { addSubview(view) }
        if let button { addSubview(button) }
        // Read as one: its title and its sentence (`.accessibilityElement(children: .combine)`).
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel([title, detail].joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func set(title: String, detail: String) {
        guard self.title.line.text != title || self.detail.text != detail else { return }
        self.title.line.text = title; self.detail.text = detail
        setAccessibilityLabel([title, detail].joined(separator: ", ")); needsLayout = true
    }
    func set(detail: String) { set(title: title.line.text, detail: detail) }
    override func layout() {
        super.layout()
        let scale = piScale
        let inner = max(0, bounds.width - padding * 2)
        let detailSize = CGSize(width: min(detailWidth, inner, detail.idealWidth), height: 0)
        let detailHeight = detail.height(forWidth: detailSize.width)
        var parts: [(NSView, CGSize)] = [(symbol, symbol.intrinsicContentSize), (title, title.intrinsicContentSize), (detail, CGSize(width: detailSize.width, height: detailHeight))]
        if let button, !button.isHidden { parts.append((button, button.intrinsicContentSize)) }
        let total = parts.reduce(0) { $0 + $1.1.height } + spacing * CGFloat(parts.count - 1)
        var y = PiKit.round((bounds.height - total) / 2, scale)
        for (view, size) in parts {
            view.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, scale), y: y, width: size.width, height: size.height)
            y += size.height + spacing
        }
    }
}

/// Text that wraps to the width it is given, as `Text` wraps it: left-aligned
/// or centred (`multilineTextAlignment(.center)`), up to `maximumLines`
/// (`lineLimit`), the last line cut with "…".
@MainActor final class TextBlock: NSView, PiKit.WidthSizing {
    var text: String { didSet { guard oldValue != text else { return }; changed() } }
    var font: NSFont { didSet { changed() } }
    var color: NSColor { didSet { needsDisplay = true } }
    var centred: Bool { didSet { needsDisplay = true } }
    var maximumLines: Int { didSet { changed() } }
    init(_ text: String, font: NSFont, color: NSColor, centred: Bool = false, maximumLines: Int = .max) {
        self.text = text; self.font = font; self.color = color; self.centred = centred; self.maximumLines = maximumLines
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func changed() { needsDisplay = true; invalidateIntrinsicContentSize(); setAccessibilityLabel(text); PiKit.sizeChanged(self) }
    override var isFlipped: Bool { true }
    private var lineHeight: CGFloat { PiKit.Line(text, font: font, color: .black).lineHeight }
    /// Its widest line unwrapped: the width it takes when nothing limits it.
    var idealWidth: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return text.components(separatedBy: "\n").map { PiKit.Line($0, font: font, color: .black).size(scale: scale).width }.max() ?? 0
    }
    func lineCount(forWidth width: CGFloat) -> Int { min(maximumLines, PiKit.wrappedLines(text, font: font, width: width).count) }
    func height(forWidth width: CGFloat) -> CGFloat { text.isEmpty ? 0 : CGFloat(lineCount(forWidth: width)) * lineHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : idealWidth)) }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let scale = piScale
        guard centred else { PiKit.drawWrapped(text, font: font, color: color, in: bounds, scale: scale, maximumLines: maximumLines); return }
        var y: CGFloat = 0
        for line in PiKit.wrappedLines(text, font: font, width: bounds.width).prefix(maximumLines) {
            let drawn = PiKit.Line(line, font: font, color: color), size = drawn.size(scale: scale)
            drawn.draw(in: CGRect(x: PiKit.round((bounds.width - size.width) / 2, scale), y: y, width: min(size.width, bounds.width), height: size.height), scale: scale)
            y += size.height
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The app's ring spinner at a size (`PiSpinner(size:)`), turning unless motion is reduced.
@MainActor func piSpinner(size: CGFloat, lineWidth: CGFloat = 1.6) -> PiSpinnerView {
    let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.fixedSize = CGSize(width: size, height: size)
    view.configure(lineWidth: lineWidth, turning: !PiKit.Motion.reduced)
    return view
}
