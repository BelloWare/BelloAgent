import AppKit

// Text shown exactly as it was written: a message as the reader typed it, and
// a reply's markdown source when the reader asks for it. Nothing in it is
// interpreted — `**`, `#`, backticks, list markers and links read literally,
// and every line break and space stays — and it is one selectable text, so a
// selection can run across its lines and copies exactly what it covers.

/// How literal text is set: its face, its size and the room between lines.
struct TranscriptPlainTextFace: Equatable, Sendable {
    var size: CGFloat
    var monospaced: Bool
    /// Between one line and the next, never after the last.
    var lineSpacing: CGFloat
    /// One line's box at `size`, for estimates: SF is 17 points tall at
    /// 14.5, SF Mono 15 at 12.5.
    var lineHeight: CGFloat { size * (monospaced ? 1.2 : 1.172) }
    /// Roughly how wide one character is, as a fraction of `size`.
    var characterWidth: CGFloat { monospaced ? 0.6 : 0.52 }
    /// What assistive technology calls the text.
    var label: String
    /// The face's weight (`NSFont.Weight`'s raw value); regular unless said.
    var weight: CGFloat = 0
    /// Figures in fixed-width digits, as `monospacedDigit()` sets them.
    var monospacedDigits = false
    /// The system's serif design (New York).
    var serif = false

    /// A message the reader sent: the face, size and colour the bubble has
    /// always read in, the prose's own.
    static let user = TranscriptPlainTextFace(size: MarkdownStyle.user.baseSize, monospaced: false,
                                              lineSpacing: MarkdownStyle.user.baseSize * 0.35, label: "Message")
    /// A reply's markdown source: the face and size of the transcript's code.
    static let source = TranscriptPlainTextFace(size: MarkdownStyle.prose.baseSize * 0.86, monospaced: true,
                                                lineSpacing: MarkdownStyle.prose.baseSize * 0.86 * 0.4, label: "Markdown source")

    var nsFont: NSFont {
        var font: NSFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight)) : .systemFont(ofSize: size, weight: NSFont.Weight(weight))
        if serif, let descriptor = font.fontDescriptor.withDesign(.serif), let serifFont = NSFont(descriptor: descriptor, size: size) { font = serifFont }
        guard monospacedDigits else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}

/// A persistent selectable leaf for literal text. TextKit owns the text, its
/// wrapping and its selection; nothing in it is interpreted, detected or
/// edited, and a copy is the plain characters the selection covers.
@MainActor final class TranscriptPlainTextView: NSTextView {
    /// From this many bytes a message's text is laid out by TextKit
    /// directly (a SwiftUI `Text` below it, in the rows this replaced).
    static let textKitBytes = 2_048
    static func usesTextKit(_ text: String) -> Bool { text.utf8.count >= textKitBytes }
    // TextKit's back-pointers are weak. Own the storage before constructing
    // the text view, including the interval before super.init adopts it.
    private var ownedStorage: NSTextStorage?
    private(set) var text = ""
    private var face: TranscriptPlainTextFace?
    private var environment: TranscriptRowEnvironment?
    private var sizes: [CGSize] = []
    /// How often the text has been laid out in full: once per width it is
    /// asked about, never again for a width it already knows.
    private(set) var layoutPasses = 0
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // Unlike NSTextView(frame:), the designated initializer does not
        // create a text system when passed a nil container.
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), manager = NSLayoutManager()
            ownedStorage = storage
            resolved = NSTextContainer(containerSize: NSSize(width: TranscriptMetrics.proseWidth, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isEditable = false; isSelectable = true; isRichText = false; importsGraphics = false
        drawsBackground = false; textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
    }
    required init?(coder: NSCoder) { nil }

    /// Lines set in the box SwiftUI gives a `Text` of this face, rather than
    /// TextKit's own: a short text drawn natively reads exactly as the
    /// SwiftUI text it replaces. A long text keeps TextKit's box, as it
    /// always had.
    private(set) var swiftUILines = false
    /// The text's colour; the transcript's text colour unless a row says otherwise.
    private(set) var color: NSColor = TranscriptNSPalette.text
    func update(text next: String, face: TranscriptPlainTextFace, environment: TranscriptRowEnvironment, swiftUILines: Bool,
                color: NSColor = TranscriptNSPalette.text) {
        if swiftUILines != self.swiftUILines || color != self.color {
            self.swiftUILines = swiftUILines; self.color = color; self.face = nil
        }
        update(text: next, face: face, environment: environment)
    }
    /// The language the text is code in, coloured as the transcript colours
    /// code (`SyntaxHighlighter`); nil for text that is not code.
    var codeLanguage: String? { didSet { if codeLanguage != oldValue { face = nil } } }
    /// Colours `code`'s tokens in `storage`, as `SyntaxHighlighter.attributed` colours them.
    static func colour(_ storage: NSTextStorage, code: String, language name: String, font: NSFont) {
        guard let grammar = SyntaxHighlighter.language(named: name), code.utf8.count <= SyntaxHighlighter.limit,
              storage.length == (code as NSString).length else { return }
        // Where each scalar begins in the storage.
        var utf16 = [0]
        utf16.reserveCapacity(code.unicodeScalars.count + 1)
        for scalar in code.unicodeScalars { utf16.append(utf16[utf16.count - 1] + (scalar.value > 0xffff ? 2 : 1)) }
        for token in SyntaxHighlighter.tokens(code, language: grammar) where token.range.upperBound < utf16.count {
            let range = NSRange(location: utf16[token.range.lowerBound], length: utf16[token.range.upperBound] - utf16[token.range.lowerBound])
            let color: NSColor
            switch token.kind {
            case .keyword: color = TranscriptNSPalette.keyword
            case .string: color = TranscriptNSPalette.string
            case .number, .title: color = TranscriptNSPalette.number
            case .comment:
                color = TranscriptNSPalette.comment
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: range)
            }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
    /// SwiftUI's line box for a font: its whole line, rounded up to a point.
    static func swiftUILine(_ font: NSFont) -> (height: CGFloat, baseline: CGFloat) {
        // A face whose line SwiftUI sets taller than its metrics give (11
        // points) has its measured line box.
        (TranscriptLabel.measured(font)?.height ?? ceil(font.ascender - font.descender + font.leading), ceil(font.ascender))
    }
    func update(text next: String, face: TranscriptPlainTextFace, environment: TranscriptRowEnvironment) {
        // Bytes, compared as memory: a long paste is not walked a character
        // at a time on every update of its row.
        // A new writing direction realigns the text, so it is set again.
        let sameText = self.face == face && text.hasSameUTF8(as: next)
            && environment.layoutDirection == (self.environment?.layoutDirection ?? environment.layoutDirection)
        guard !sameText || self.environment != environment, let storage = textStorage else { return }
        if sameText, let current = self.environment, current.hasSameGeometry(as: environment) {
            // Painted again, measured the same: the colours are dynamic and
            // resolve against the appearance they are drawn in.
            self.environment = environment
            needsDisplay = true
            return
        }
        let ranges = selectedRanges, previousLength = storage.length
        if !sameText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = face.lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            // The text's leading edge, as SwiftUI aligns it.
            paragraph.alignment = centred ? .center : environment.layoutDirection == .rightToLeft ? .right : .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: face.nsFont, .foregroundColor: color, .paragraphStyle: paragraph
            ]
            if swiftUILines {
                let font = face.nsFont, line = Self.swiftUILine(font)
                paragraph.minimumLineHeight = line.height; paragraph.maximumLineHeight = line.height
                // SwiftUI's text breaks lines as a label does: it pushes a
                // word down rather than leave one alone on the last line.
                paragraph.lineBreakStrategy = .standard
            }
            storage.setAttributedString(NSAttributedString(string: Self.limited(next, lines: maximumLines), attributes: attributes))
            if let codeLanguage { Self.colour(storage, code: next, language: codeLanguage, font: face.nsFont) }
            text = next; self.face = face
            setAccessibilityLabel(face.label)
        }
        self.environment = environment
        sizes.removeAll(keepingCapacity: true); exactSizes.removeAll(keepingCapacity: true); ideal = nil
        // New text keeps whatever of the reader's selection still fits it.
        if previousLength > 0 {
            selectedRanges = ranges.map { value in
                let range = value.rangeValue, location = min(range.location, storage.length)
                return NSValue(range: NSRange(location: location, length: min(range.length, storage.length - location)))
            }
        }
        needsDisplay = true
    }

    /// Sets the glyphs where SwiftUI draws them in its line box. TextKit puts
    /// a taller line's extra room above the glyphs; SwiftUI's sit lower. Only
    /// where the glyphs sit changes, never the line box, so no height does.
    /// `glyphOffsetOverride` is for the calibration sweep only.
    nonisolated(unsafe) static var glyphOffsetOverride: CGFloat?
    /// How far TextKit's glyphs are raised to sit where SwiftUI draws them,
    /// for a text `height` tall before rounding, drawn at `scale` pixels a
    /// point. Measured, not derived (TranscriptTextCalibrationTests sweeps
    /// and checks it): the user's face sits a point lower, less half the room
    /// SwiftUI's whole-point frame adds below the text, to the nearest pixel;
    /// 11.5 pt text a point lower; the other faces where TextKit puts them.
    static func glyphOffset(_ font: NSFont, height: CGFloat, scale: CGFloat) -> CGFloat {
        if let glyphOffsetOverride { return glyphOffsetOverride }
        // The faces whose glyphs SwiftUI sets lower by a fixed amount, in
        // either design (9.5 to 11.5 pt, a read's wrapped line number too).
        if let fixed = [9.5: 1.0, 10: 1.0, 10.5: 1.0, 11: 1.0, 11.5: 1.0][Double(font.pointSize)] { return CGFloat(fixed) }
        guard !font.isFixedPitch else { return 0 }
        // The serif design (New York) a point lower too.
        if font.fontName.lowercased().contains("newyork") { return 1 }
        guard font.pointSize == TranscriptPlainTextFace.user.size else { return 0 }
        let room = (ceil(height) - height) / 2
        return 1 - (room * scale).rounded() / scale
    }
    /// Sets the glyphs for the width the text is drawn at.
    private var placingGlyphs = false
    private func placeGlyphsAsSwiftUI(width: CGFloat) {
        guard swiftUILines, !placingGlyphs, let face, let storage = textStorage, storage.length > 0 else { return }
        // A text drawn narrower than it was measured (as wide as its widest
        // line) is measured where it is drawn, once.
        placingGlyphs = true
        let height = exactSizes.last(where: { $0.width == width })?.height ?? { _ = measure(width: width); return exactSizes.last(where: { $0.width == width })?.height }()
        placingGlyphs = false
        guard let height else { return }
        let offset = Self.glyphOffset(face.nsFont, height: height, scale: window?.backingScaleFactor ?? 2)
        guard (storage.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat) != offset else { return }
        storage.addAttribute(.baselineOffset, value: offset, range: NSRange(location: 0, length: storage.length))
    }
    /// The text stands on the pixel nearest where it is put, as SwiftUI sets
    /// a text (in a parent on the pixel grid). The reader's own message keeps
    /// its exact place: its glyph offsets (`glyphOffset`) were measured so.
    var snapsToPixels = true
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        guard snapsToPixels else { return super.setFrameOrigin(newOrigin) }
        let scale = window?.backingScaleFactor ?? 2
        super.setFrameOrigin(NSPoint(x: (newOrigin.x * scale).rounded() / scale, y: (newOrigin.y * scale).rounded() / scale))
    }
    /// Lines centred, as `multilineTextAlignment(.center)` sets them.
    var centred = false { didSet { if centred != oldValue { face = nil } } }
    /// How wide the text's widest line is at `width`, as SwiftUI sizes a
    /// text that wraps.
    func usedWidth(width: CGFloat) -> CGFloat {
        guard !text.isEmpty, let container = textContainer, let manager = layoutManager else { return 0 }
        _ = measure(width: width)
        let previous = container.containerSize
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        var widest: CGFloat = 0
        var lastLine = NSRange(location: NSNotFound, length: 0)
        // A line set from the right leaves its trailing spaces out of its
        // used rect; SwiftUI counts them, as it does for a line set from the left.
        let fromRight = environment?.layoutDirection == .rightToLeft && !centred
        let storage = textStorage
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, glyphs, _ in
            var line = used.width
            if fromRight, let storage {
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let typeset = CTLineCreateWithAttributedString(storage.attributedSubstring(from: characters))
                line = CGFloat(CTLineGetTypographicBounds(typeset, nil, nil, nil))
            }
            widest = max(widest, line)
            lastLine = glyphs
        }
        // A centred text cut short by its line limit takes all the room it
        // was offered, as SwiftUI sizes one (one set from its leading edge
        // keeps its widest line).
        let cut = centred && maximumLines > 0 && lastLine.location != NSNotFound
            && manager.truncatedGlyphRange(inLineFragmentForGlyphAt: lastLine.location).location != NSNotFound
        container.containerSize = previous
        if cut { return width }
        // Up to a whole pixel, as SwiftUI sizes a text; set at that width, the
        // text wraps where it did.
        widest = ceil(widest * 2) / 2
        return min(width, widest)
    }
    /// At most this many lines, the last cut short with an ellipsis, as
    /// SwiftUI's `lineLimit` does; zero for no limit.
    var maximumLines = 0 {
        didSet {
            guard maximumLines != oldValue else { return }
            textContainer?.maximumNumberOfLines = maximumLines
            textContainer?.lineBreakMode = maximumLines > 0 ? .byTruncatingTail : .byWordWrapping
            sizes.removeAll(); exactSizes.removeAll(); ideal = nil
            face = nil
        }
    }
    /// `text` cut to `lines` written lines, the last ending in an ellipsis
    /// when anything was cut, as `lineLimit` shows a text with more line
    /// breaks than it allows (a trailing break counts). Lines that wrap are
    /// cut by TextKit itself.
    static func limited(_ text: String, lines: Int) -> String {
        guard lines > 0 else { return text }
        // Every newline form is one break (CRLF is one Character).
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard parts.count > lines else { return text }
        return parts.prefix(lines).joined(separator: "\n") + "…"
    }
    /// How wide the text is with all the room it wants: its widest line.
    private var ideal: CGFloat?
    var idealWidth: CGFloat {
        if let ideal { return ideal }
        guard !text.isEmpty, let container = textContainer, let manager = layoutManager else { return 0 }
        let previous = container.containerSize
        container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let width = ceil(manager.usedRect(for: container).width * 2) / 2
        container.containerSize = previous
        ideal = width
        return width
    }
    /// The text's height at `width` before it is rounded up to a point.
    func exactHeight(width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        _ = measure(width: width)
        return exactSizes.last(where: { $0.width == width })?.height ?? measure(width: width).height
    }
    /// What `measure` found at each width before rounding, from the same pass.
    private var exactSizes: [CGSize] = []
    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? TranscriptMetrics.pageWidth
        // SwiftUI probes several widths, including cached ones. A probe must
        // not leave the selectable view wrapping at a different width from
        // its current frame when that frame itself did not change.
        defer { alignTextToBounds() }
        if let size = sizes.last(where: { $0.width == width }) { return size }
        guard !text.isEmpty, let container = textContainer, let manager = layoutManager else { return CGSize(width: width, height: 0) }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        layoutPasses += 1
        // The used rect ends at the last line's own box: TextKit puts line
        // spacing between lines, and a trailing line break is a line.
        var height = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        if maximumLines > 0 {
            // No more than the lines allowed, a trailing line break's empty
            // line included, as SwiftUI's `lineLimit` counts them.
            var lines = 0, bottom: CGFloat = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, stop in
                lines += 1; bottom = rect.maxY; if lines == self.maximumLines { stop.pointee = true }
            }
            // A trailing break's empty line is a line too, while the limit allows it.
            if lines < maximumLines, manager.extraLineFragmentRect.height > 0 { bottom = manager.extraLineFragmentRect.maxY }
            height = min(height, bottom)
        }
        if exactSizes.count == 4 { exactSizes.removeFirst() }; exactSizes.append(CGSize(width: width, height: height))
        let result = CGSize(width: width, height: max(1, ceil(height)))
        if sizes.count == 4 { sizes.removeFirst() }; sizes.append(result)
        return result
    }
    override func layout() {
        super.layout()
        alignTextToBounds()
    }
    /// Where the glyphs sit depends on the pixel grid they land on.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if bounds.width > 0 { placeGlyphsAsSwiftUI(width: bounds.width) }
    }
    private func alignTextToBounds() {
        if bounds.width > 0, textContainer?.containerSize.width != bounds.width {
            textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        if bounds.width > 0 { placeGlyphsAsSwiftUI(width: bounds.width) }
    }
    /// A right-click on a selection is the text's own: Copy, Look Up. Any
    /// other is the row's, as it is on the rest of the row and on a short
    /// text: a reply's menu, with View rendered in it.
    override func menu(for event: NSEvent) -> NSMenu? {
        selectedRange().length > 0 ? super.menu(for: event) : nil
    }
}

// MARK: - A reply's source

/// A reply read as its markdown source: which rows can switch, what the
/// switch is called, and the per-reply state it keeps in the conversation's
/// disclosure (`TranscriptDisclosure.Part.source`).
enum ReplySource {
    /// The id of the reply whose view this row draws, if the row draws a
    /// reply's text: a reply's body, or one text part of a reply read in
    /// order. A response's header line, its cards, its reasoning and its
    /// figures draw none, so switching a reply never re-measures them.
    static func replyID(of item: TranscriptItem) -> String? {
        switch item {
        case .message(let message):
            return drawsReply(message) ? message.id : nil
        case .block(let block):
            guard let message = block.message, drawsReply(message) else { return nil }
            switch block.presentation {
            case .body, .reply: return message.id
            case .timeline: return block.part.map { ["text", "refusal"].contains($0.part.kind) } == true ? message.id : nil
            case .work, .summary, .response, .turnFold: return nil
            }
        }
    }
    private static func drawsReply(_ message: TranscriptMessage) -> Bool {
        message.role == "assistant" && message.kind == nil
    }
    /// Whether a row offers the switch: on a reply's finished text only.
    /// Text still arriving is always drawn rendered, by the surface that
    /// takes its tokens.
    static func offered(_ message: TranscriptMessage) -> Bool {
        drawsReply(message) && !message.isStreaming && TaskTranscriptPlan.visible(message.text)
    }
    /// Whether a row draws this reply as its source.
    static func shows(_ message: TranscriptMessage, raw: Bool) -> Bool {
        raw && drawsReply(message) && !message.isStreaming
    }
    /// The pill's and the accessibility action's name.
    static func title(raw: Bool) -> String { raw ? "View rendered" : "View raw" }
    /// The reply menu's command.
    static func menuTitle(raw: Bool) -> String { raw ? "View Rendered" : "View Raw" }
    static let menuIdentifier = "reply-raw"
}

/// A row's switch between its reply rendered and its source, as the pill,
/// the reply menu and the accessibility action offer it.
struct ReplySourceToggle {
    /// Whether the reply reads as its source now.
    let raw: Bool
    let toggle: () -> Void
}
