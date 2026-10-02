import AppKit

/// Optional host-provided ink for a piece of a visible line. The engine
/// knows no lexer or application palette; ranges are local UTF-16 units.
public struct FileTextColorRun {
    public let range: NSRange
    public let color: NSColor
    public init(range: NSRange, color: NSColor) { self.range = range; self.color = color }
}

// A file's text, read only: drawn by CoreText a line at a time as lines come
// into view, in a document as tall as the file, inside an ordinary scroll
// view. Nothing is set for lines off screen, so a file of millions of lines
// opens as fast as a short one. (A document view of 150 million points draws
// its lines on the same pixels as a short one; checked before this was
// written.)
//
// The reader selects text as in any Mac text view: click, drag (the view
// scrolls under a drag past its edge), double-click a word, triple-click a
// line, Shift-click to extend, and the keyboard's movement keys with Shift.
// There is no caret to type at, but there is an insertion point, so the
// keyboard can start and extend a selection. VoiceOver reads the same text a
// selection copies (`FileTextSource`).

/// How the viewer sets text: the room around it and how lines are cut, and
/// from the style, the font's measures.
struct FileTextMetrics {
    /// Room around the text: under the tabs above, and after the gutter.
    static let top: CGFloat = 8
    static let bottom: CGFloat = 16
    static let left: CGFloat = 10
    static let right: CGFloat = 24
    /// A tab is four spaces wide.
    static let tabSpaces: CGFloat = 4
    /// Lines longer than this are set in pieces of about this many UTF-16
    /// units, and only the pieces in view are set and drawn.
    static let piece = 1_024
    /// Lines longer than this are set on a grid, a column a UTF-16 unit: where
    /// any part of the line sits is known without setting what comes before
    /// it, so the far end of a line of megabytes is as quick to reach as its
    /// start. Characters wider than a column are drawn narrower there.
    static let gridLine = 65_536

    let font: NSFont
    let numbersFont: NSFont
    let lineHeight: CGFloat
    /// The width of one character of the font.
    let advance: CGFloat
    /// Where a line's baseline sits in its height: the font's ascent and
    /// descent centred, on a whole point.
    let baseline: CGFloat
    /// The width of one digit of the line numbers.
    let digitWidth: CGFloat
    var tabInterval: CGFloat { advance * Self.tabSpaces }

    init(_ style: FileTextStyle) {
        font = style.font; numbersFont = style.lineNumberFont; lineHeight = style.lineHeight
        func width(_ font: NSFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        advance = width(style.font); digitWidth = width(style.lineNumberFont)
        let content = style.font.ascender - style.font.descender
        baseline = (((style.lineHeight - content) / 2) + style.font.ascender).rounded()
    }

    /// Text set with tab stops every four columns from the line's start, when
    /// the text itself starts `origin` points along the line.
    func attributes(origin: CGFloat, tabs: Bool, grid: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        if grid {
            // On the grid a tab is a column, as every character is.
            paragraph.defaultTabInterval = advance
        } else if origin == 0 || !tabs {
            paragraph.defaultTabInterval = tabInterval
        } else {
            // A piece set apart from the line's start keeps the line's stops.
            let first = tabInterval - origin.truncatingRemainder(dividingBy: tabInterval)
            let reach = CGFloat(Self.piece + 1) * tabInterval
            paragraph.tabStops = stride(from: first, through: reach, by: tabInterval).map { NSTextTab(textAlignment: .left, location: $0) }
            paragraph.defaultTabInterval = tabInterval
        }
        // The ink comes from the context, so a line set once draws right in
        // either appearance.
        return [.font: font, .paragraphStyle: paragraph,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    }
}

/// What has been set. A test seam, not diagnostics: a long file must set the
/// text that comes into view and nothing else, and that is only checkable by
/// counting.
@MainActor enum FileTextRenderCount {
    /// Pieces of text set by CoreText.
    private(set) static var pieces = 0
    static func reset() { pieces = 0 }
    static func built() { pieces &+= 1 }
}

/// How a file's text looks: its font and its line numbers', the height of a
/// line, and the colours it is drawn in. The engine knows no app: a
/// monospaced system font and the system's colours unless the host app gives
/// its own.
public struct FileTextStyle {
    public var font: NSFont
    public var lineNumberFont: NSFont
    public var lineHeight: CGFloat
    public var text: NSColor
    public var lineNumber: NSColor
    /// The numbers of the lines selected, or set apart.
    public var strongLineNumber: NSColor
    /// The band behind lines set apart: those a file was opened at.
    public var emphasis: NSColor
    /// Behind every match of a find, and behind the match shown.
    public var findMatch: NSColor
    public var findCurrent: NSColor
    public init(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
                lineNumberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular), lineHeight: CGFloat = 17,
                text: NSColor = .textColor, lineNumber: NSColor = .tertiaryLabelColor, strongLineNumber: NSColor = .secondaryLabelColor,
                emphasis: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.12),
                findMatch: NSColor = NSColor.findHighlightColor.withAlphaComponent(0.35),
                findCurrent: NSColor = NSColor.findHighlightColor.withAlphaComponent(0.8)) {
        self.font = font; self.lineNumberFont = lineNumberFont; self.lineHeight = lineHeight
        self.text = text; self.lineNumber = lineNumber; self.strongLineNumber = strongLineNumber; self.emphasis = emphasis
        self.findMatch = findMatch; self.findCurrent = findCurrent
    }
    @MainActor public static var standard = FileTextStyle()
}

/// One line as CoreText sets it, in pieces, each set when it is first needed.
/// A line up to `FileTextMetrics.gridLine` long is read whole when it is laid
/// out, and kept, then set piece after piece from its start, each piece where
/// the last one ended. A longer line is on the grid: each piece is read when
/// it is drawn, and a piece whose text has not come yet is not drawn until it
/// has.
@MainActor final class FileLineLayout {
    struct Piece {
        let range: Range<Int>
        let x: CGFloat
        /// The width the piece takes along the line.
        let width: CGFloat
        let line: CTLine
        /// On the grid, how much narrower the piece is drawn than set: 1 unless
        /// it holds characters wider than a column.
        let squeeze: CGFloat
    }
    private unowned let source: FileTextSource
    let metrics: FileTextMetrics
    let index: Int
    let length: Int
    let grid: Bool
    /// The line's text, off the grid.
    let text: NSString?
    /// From the line's start, the pieces set so far.
    private var ordered: [Piece] = []
    private var complete = false
    private let syntax: ((Int, Range<Int>, String) -> [FileTextColorRun])?
    /// On the grid, the pieces set, by number, and where pieces start, as
    /// found: a piece drawn again reads nothing.
    private var gridPieces: [Int: Piece] = [:]
    private var gridStarts: [Int: Int] = [:]

    /// Nil for a line off the grid whose text has not come yet.
    init?(source: FileTextSource, line index: Int, metrics: FileTextMetrics, syntax: ((Int, Range<Int>, String) -> [FileTextColorRun])? = nil) {
        self.source = source; self.index = index; self.metrics = metrics
        self.syntax = syntax
        length = source.utf16Length(ofLine: index)
        grid = length > FileTextMetrics.gridLine
        if grid { text = nil } else {
            guard let whole = source.text(ofLine: index, range: 0..<length) else { return nil }
            text = whole as NSString
            if length <= FileTextMetrics.piece { measureNext() }
        }
    }

    /// The whole line's width: exact once every piece is set, and always on the grid.
    var width: CGFloat? {
        if grid { return CGFloat(length) * metrics.advance }
        return complete ? measuredEnd.x : nil
    }
    /// How wide the line is at least, as far as it is known: what is set,
    /// and a column for each unit not yet set. Tabs set so far can make the
    /// line far wider than its length says.
    var extent: CGFloat {
        if let width { return width }
        return measuredEnd.x + CGFloat(length - measuredEnd.index) * metrics.advance
    }
    private var measuredEnd: (index: Int, x: CGFloat) { ordered.last.map { ($0.range.upperBound, $0.x + $0.width) } ?? (0, 0) }

    /// Part of the line's text: off the grid from what is kept, on it as read.
    private func read(_ range: Range<Int>) -> String? {
        let low = max(0, min(range.lowerBound, length)), high = max(low, min(range.upperBound, length))
        if let text { return text.substring(with: NSRange(location: low, length: high - low)) }
        return source.text(ofLine: index, range: low..<high)
    }
    /// Where a piece that starts at `start` and should end near `target` ends:
    /// after a space or a tab within reach, else where a character ends, so no
    /// character is cut and words are set whole where they can be.
    private func end(ofPieceFrom start: Int, target: Int) -> Int {
        guard target < length else { return length }
        let base = max(start, target - 64)
        guard let window = read(base..<min(length, target + 16)).map({ $0 as NSString }) else { return target }
        var cut = target - base
        let space = window.rangeOfCharacter(from: .whitespaces, options: .backwards, range: NSRange(location: 0, length: min(cut, window.length)))
        if space.location != NSNotFound, space.location > 0 { cut = space.location + 1 }
        else if cut < window.length {
            let character = window.rangeOfComposedCharacterSequence(at: cut)
            cut = character.location > 0 ? character.location : NSMaxRange(character)
        }
        return max(start + 1, min(length, base + cut))
    }
    private func set(_ range: Range<Int>, x: CGFloat) -> Piece? {
        guard let text = read(range) else { return nil }
        let attributed = NSMutableAttributedString(string: text, attributes: metrics.attributes(origin: x, tabs: text.contains("\t"), grid: grid))
        for run in syntax?(index, range, text) ?? [] where run.range.location >= 0 && NSMaxRange(run.range) <= attributed.length {
            attributed.removeAttribute(NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String), range: run.range)
            attributed.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        let line = CTLineCreateWithAttributedString(attributed)
        FileTextRenderCount.built()
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard grid else { return Piece(range: range, x: x, width: natural, line: line, squeeze: 1) }
        let cell = CGFloat(range.count) * metrics.advance
        return Piece(range: range, x: x, width: cell, line: line, squeeze: natural > cell + 0.5 ? cell / natural : 1)
    }
    private func measureNext() {
        guard !complete, !grid else { return }
        let (start, x) = measuredEnd
        let end = length <= FileTextMetrics.piece ? length : end(ofPieceFrom: start, target: start + FileTextMetrics.piece)
        // Off the grid the text is kept, so a piece is always set.
        guard let piece = set(start..<end, x: x) else { complete = true; return }
        ordered.append(piece)
        if end >= length { complete = true }
    }
    /// On the grid, where piece `number` starts: at a multiple of the piece
    /// length, moved back to where a character starts. Found from the text
    /// around it alone, so no piece before it is read; nil until that text
    /// has come.
    private func gridStart(_ number: Int) -> Int? {
        let target = number * FileTextMetrics.piece
        guard number > 0 else { return 0 }
        guard target < length else { return length }
        if let start = gridStarts[number] { return start }
        let base = max(0, target - 32)
        guard let window = read(base..<min(length, target + 32)).map({ $0 as NSString }) else { return nil }
        let start = base + window.rangeOfComposedCharacterSequence(at: target - base).location
        if gridStarts.count > 256 { gridStarts = gridStarts.filter { abs($0.key - number) < 32 } }
        gridStarts[number] = start
        return start
    }
    /// On the grid, the piece holding a column; nil until its text has come.
    private func gridPiece(containing column: Int) -> Piece? {
        let column = max(0, min(column, length - 1))
        // Starts move back to where a character starts, so a column can
        // belong to the piece before its multiple, or (a character cut by
        // the multiple) to the next piece.
        var number = column / FileTextMetrics.piece
        guard let here = gridStart(number), let next = gridStart(number + 1) else { return nil }
        if number > 0, column < here { number -= 1 }
        else if column >= next { number += 1 }
        if let piece = gridPieces[number] { return piece }
        // Pieces well away from the one asked for are let go of first.
        if gridPieces.count > 64 { gridPieces = gridPieces.filter { abs($0.key - number) < 16 } }
        guard let low = gridStart(number), let high = gridStart(number + 1),
              let piece = set(low..<max(low + 1, high), x: CGFloat(low) * metrics.advance) else { return nil }
        gridPieces[number] = piece
        return piece
    }
    /// On the grid, where a column is: its cell, whether or not its piece is at hand.
    private func gridColumnStart(_ column: Int) -> CGFloat { CGFloat(column) * metrics.advance }

    /// The pieces that reach into `from..<to` along the line.
    func pieces(from: CGFloat, to: CGFloat) -> [Piece] {
        guard length > 0, to > from else { return [] }
        if grid {
            var result: [Piece] = []
            var column = max(0, Int(from / metrics.advance))
            // A column's place is known before its piece is set: nothing past
            // the edge is set.
            while column < length, CGFloat(column) * metrics.advance < to {
                guard let piece = gridPiece(containing: column) else {
                    // Not come yet: the next piece's columns, drawn when it has.
                    column = (column / FileTextMetrics.piece + 1) * FileTextMetrics.piece
                    continue
                }
                if piece.x + piece.width > from { result.append(piece) }
                column = max(column + 1, piece.range.upperBound)
            }
            return result
        }
        while !complete, measuredEnd.x < to { measureNext() }
        return ordered.filter { $0.x + $0.width > from && $0.x < to }
    }
    /// The offsets of the piece holding an offset.
    func pieceRange(containing column: Int) -> Range<Int>? { piece(containing: column)?.range }
    /// The piece holding an offset.
    private func piece(containing column: Int) -> Piece? {
        if grid { return length == 0 ? nil : gridPiece(containing: column) }
        while !complete, measuredEnd.index <= column { measureNext() }
        return ordered.last(where: { $0.range.lowerBound <= column })
    }
    /// Where an offset sits along the line. On the grid, a piece whose text
    /// has not come yet puts it in its column.
    func x(at column: Int) -> CGFloat {
        let column = max(0, min(column, length))
        guard let piece = piece(containing: column) else { return grid ? gridColumnStart(column) : 0 }
        let offset = CGFloat(CTLineGetOffsetForStringIndex(piece.line, min(column, piece.range.upperBound) - piece.range.lowerBound, nil))
        return piece.x + offset * piece.squeeze
    }
    /// What `from..<to` covers along the line, within `window` of it if
    /// given: for each run of text it takes, the span of the glyphs of its
    /// characters. Text that runs right to left places later characters
    /// further left, so a range is never simply from its start's offset to
    /// its end's. Only the pieces that meet the window are set, however long
    /// the range: all of a line of megabytes selected sets what is on screen.
    func spans(from: Int, to: Int, within window: ClosedRange<CGFloat>? = nil) -> [ClosedRange<CGFloat>] {
        let from = max(0, from), to = min(length, to)
        guard to > from else { return [] }
        var spans: [ClosedRange<CGFloat>] = []
        var column = from
        // On the grid, the window's left edge falls in the piece whose columns
        // hold it; inside a piece glyphs sit where they are drawn (squeezed
        // by wide characters), so the piece is started from its beginning.
        if grid, let window {
            let edge = Int(max(0, window.lowerBound) / metrics.advance)
            column = max(from, piece(containing: edge)?.range.lowerBound ?? edge / FileTextMetrics.piece * FileTextMetrics.piece)
        }
        while column < to {
            guard let piece = piece(containing: column) else {
                // A piece whose text has not come yet: its columns.
                guard grid else { break }
                let next = min(to, (column / FileTextMetrics.piece + 1) * FileTextMetrics.piece)
                if let window, gridColumnStart(column) > window.upperBound { break }
                spans.append(gridColumnStart(column)...gridColumnStart(next))
                column = next
                continue
            }
            if let window, piece.x > window.upperBound { break }
            defer { column = max(column + 1, piece.range.upperBound) }
            if let window, piece.x + piece.width < window.lowerBound { continue }
            let low = max(from, piece.range.lowerBound) - piece.range.lowerBound
            let high = min(to, piece.range.upperBound) - piece.range.lowerBound
            for run in (CTLineGetGlyphRuns(piece.line) as? [CTRun]) ?? [] {
                let range = CTRunGetStringRange(run)
                guard range.location < high, range.location + range.length > low,
                      let span = Self.span(of: run, runRange: range, from: low, to: high) else { continue }
                spans.append((piece.x + span.lowerBound * piece.squeeze)...(piece.x + span.upperBound * piece.squeeze))
            }
        }
        return spans
    }
    /// The part of a run's glyphs that draws the characters `from..<to`. A
    /// glyph draws the characters from its own up to the next glyph's (a
    /// ligature draws several); a range that takes part of them takes that
    /// part of the glyph, from its leading side.
    private static func span(of run: CTRun, runRange: CFRange, from: Int, to: Int) -> ClosedRange<CGFloat>? {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return nil }
        var indices = [CFIndex](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
        // Where the characters of each glyph end: the next glyph's first
        // character in the text's order. Found once for the run.
        let starts = Set(indices).sorted()
        let runEnd = runRange.location + runRange.length
        var ends: [CFIndex: CFIndex] = [:]
        for (index, start) in starts.enumerated() { ends[start] = index + 1 < starts.count ? starts[index + 1] : runEnd }
        let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
        var left = CGFloat.infinity, right = -CGFloat.infinity
        for glyph in 0..<count {
            let first = indices[glyph]
            let next = ends[first] ?? runEnd
            let covered = next - first
            let low = max(first, from), high = min(next, to)
            guard covered > 0, high > low else { continue }
            let width = advances[glyph].width, share = width / CGFloat(covered)
            let a = CGFloat(low - first) * share, b = CGFloat(high - first) * share
            let x = positions[glyph].x
            let (lo, hi) = rightToLeft ? (x + width - b, x + width - a) : (x + a, x + b)
            left = min(left, lo); right = max(right, hi)
        }
        return left <= right ? left...right : nil
    }
    /// The offset nearest a point along the line: where a click there puts
    /// the insertion point. On the grid, nil while the piece there has not
    /// come: its column may be inside a character.
    func index(at x: CGFloat) -> Int? {
        guard x > 0, length > 0 else { return 0 }
        let piece: Piece
        if grid {
            guard x < CGFloat(length) * metrics.advance else { return length }
            guard let found = gridPiece(containing: Int(x / metrics.advance)) else { return nil }
            piece = found
        } else {
            while !complete, measuredEnd.x <= x { measureNext() }
            guard let found = ordered.last(where: { $0.x <= x }) else { return 0 }
            piece = found
        }
        guard x < piece.x + piece.width else { return piece.range.upperBound }
        let offset = CTLineGetStringIndexForPosition(piece.line, CGPoint(x: (x - piece.x) / piece.squeeze, y: 0))
        return offset == kCFNotFound ? piece.range.upperBound : piece.range.lowerBound + max(0, min(offset, piece.range.count))
    }
}

/// The text view. Its frame is the whole document; it draws what is asked of it.
@MainActor public final class FileTextView: NSView {
    public var syntax: ((Int, Range<Int>, String) -> [FileTextColorRun])? { didSet { layouts = [:]; needsDisplay = true } }
    public func invalidateSyntax(inLine line: Int) { layouts[line] = nil; needsDisplay = true }
    public private(set) var source: FileTextSource = FileTextLines("")
    /// What accessibility calls the text: "Contents of Main.swift".
    public private(set) var name = ""
    /// Lines to set apart, softly: the lines a file was opened at.
    public var emphasized: ClosedRange<Int>? { didSet { if emphasized != oldValue { needsDisplay = true; ruler?.needsDisplay = true } } }
    /// Finding in the text, while a find bar is open (`FileFind`): its
    /// matches are drawn on the lines drawn, the one shown more strongly.
    public internal(set) weak var find: FileFind? { didSet { if find !== oldValue { needsDisplay = true } } }
    /// How the text looks: the host app's font and colours, or the system's.
    public var style = FileTextStyle.standard {
        didSet {
            metrics = FileTextMetrics(style)
            // Everything placed in the old font's points is placed again: the
            // lines set, the column Up and Down keep, and the screen read
            // ahead for, which now shows other columns.
            layouts = [:]; measuredWidth = 0; goalX = nil; readAhead = nil
            updateFrame(); needsDisplay = true; ruler?.textChanged()
        }
    }
    private(set) var metrics = FileTextMetrics(FileTextStyle.standard)
    /// Where Copy puts text. The general pasteboard; a test's own otherwise.
    public var pasteboard: NSPasteboard = .general
    weak var ruler: FileLineNumberRuler?

    /// The selection runs from the anchor to the focus, either way round. The
    /// two are equal when nothing is selected: the insertion point.
    public private(set) var anchor = FileTextPosition.start
    public private(set) var focus = FileTextPosition.start
    /// Where Up and Down keep the insertion point, across short lines.
    private var goalX: CGFloat?
    private var layouts: [Int: FileLineLayout] = [:]
    private var layoutGeneration = 0
    /// How wide the widest line drawn so far turned out to be.
    private var measuredWidth: CGFloat = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityIdentifier("file-text-view")
    }
    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); if syntax != nil { layouts = [:] }; needsDisplay = true }

    /// Shows a text from its start, with nothing selected.
    public func show(_ source: FileTextSource, name: String, preservingPosition: Bool = false) {
        let savedAnchor = anchor, savedFocus = focus, savedEmphasis = emphasized
        let savedOrigin = enclosingScrollView?.contentView.bounds.origin
        self.source.arrival = nil
        self.source = source; self.name = name
        pending = []
        dropPending(); accessibilityHold?.release(); accessibilityHold = nil; revealing = nil
        source.arrival = { [weak self] lines in self?.arrived(lines) }
        layouts = [:]; layoutGeneration = source.generation; measuredWidth = 0; goalX = nil; emphasized = nil; readAhead = nil
        showing &+= 1; answers = []; answering = []
        anchor = .start; focus = .start
        updateFrame()
        if preservingPosition {
            anchor = clamp(savedAnchor); focus = clamp(savedFocus); emphasized = savedEmphasis
            if let savedOrigin, let scroll = enclosingScrollView {
                scroll.contentView.scroll(to: savedOrigin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        needsDisplay = true; ruler?.textChanged()
        announce(.valueChanged)
    }

    // MARK: Geometry

    var lineHeight: CGFloat { metrics.lineHeight }
    /// The top of a line.
    func top(ofLine index: Int) -> CGFloat { FileTextMetrics.top + CGFloat(index) * lineHeight }
    /// The lines that meet a rect, clamped to the text.
    func lines(in rect: NSRect) -> ClosedRange<Int> {
        let first = Int(floor((rect.minY - FileTextMetrics.top) / lineHeight))
        let last = Int(ceil((rect.maxY - FileTextMetrics.top) / lineHeight)) - 1
        let count = source.lineCount
        let low = max(0, min(first, count - 1)), high = max(low, min(last, count - 1))
        return low...high
    }
    /// The lines on screen.
    public var visibleLines: ClosedRange<Int> { lines(in: visibleRect) }
    /// The line under a point, clamped to the text.
    func line(at y: CGFloat) -> Int { max(0, min(source.lineCount - 1, Int(floor((y - FileTextMetrics.top) / lineHeight)))) }

    /// A line as set, nil while its text has not come (it is then asked for).
    func layout(_ index: Int) -> FileLineLayout? {
        if layoutGeneration != source.generation { layouts = [:]; layoutGeneration = source.generation }
        if let layout = layouts[index] { return layout }
        // Lines well away from the screen are let go of before more are set.
        if layouts.count > max(256, 4 * (visibleLines.count + 1)) {
            let keep = visibleLines
            layouts = layouts.filter { keep.contains($0.key) }
        }
        guard let layout = FileLineLayout(source: source, line: index, metrics: metrics, syntax: syntax) else { return nil }
        layouts[index] = layout
        return layout
    }
    /// Where a column is along a line: where it is set, or while the line's
    /// text has not come, in its column.
    func x(of position: FileTextPosition) -> CGFloat {
        layout(position.line)?.x(at: position.column) ?? CGFloat(max(0, position.column)) * metrics.advance
    }

    /// Where a position is drawn, in this view.
    func point(of position: FileTextPosition) -> NSPoint {
        NSPoint(x: FileTextMetrics.left + x(of: position), y: top(ofLine: position.line))
    }
    /// The position a point in this view puts the insertion point at: above
    /// the text is its start, below it its end.
    func position(at point: NSPoint) -> FileTextPosition {
        if point.y < FileTextMetrics.top { return .start }
        if point.y >= top(ofLine: source.lineCount) { return end }
        let line = line(at: point.y), x = point.x - FileTextMetrics.left
        let column = layout(line)?.index(at: x) ?? Int((max(0, x) / metrics.advance).rounded())
        return FileTextPosition(line: line, column: min(column, source.utf16Length(ofLine: line)))
    }
    /// The end of the text.
    var end: FileTextPosition { FileTextPosition(line: source.lineCount - 1, column: source.utf16Length(ofLine: source.lineCount - 1)) }

    /// As tall as the text, and as wide as its longest line, or the view it
    /// is shown in.
    func updateFrame() {
        let visible = enclosingScrollView?.contentView.bounds.size ?? frame.size
        let estimate = CGFloat(source.longestLine) * metrics.advance
        let width = max(visible.width, FileTextMetrics.left + max(estimate, measuredWidth) + FileTextMetrics.right)
        let height = max(visible.height, top(ofLine: source.lineCount) + FileTextMetrics.bottom)
        let size = NSSize(width: width.rounded(.up), height: height.rounded(.up))
        if frame.size != size { setFrameSize(size) }
    }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true; clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        updateFrame()
    }
    @objc private func clipResized(_ note: Notification) { updateFrame(); revealIfReady() }
    @objc private func clipScrolled(_ note: Notification) { ruler?.needsDisplay = true }

    // MARK: Drawing

    private var selectionActive: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
        // Lines to reveal wait for the view to be laid out in its window.
        if revealing != nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.revealIfReady() } } }
    }
    @objc private func keyChanged(_ note: Notification) { if hasSelection { needsDisplay = true } }
    public override func becomeFirstResponder() -> Bool {
        if hasSelection { needsDisplay = true }
        announce(.focusedUIElementChanged)
        return true
    }
    public override func resignFirstResponder() -> Bool { if hasSelection { needsDisplay = true }; return true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #if DEBUG
        matchedColumns = [:]
        #endif
        let rows = lines(in: dirtyRect)
        // The source is told the screen, its lines and the columns in view,
        // once for each screen, up and down or sideways: drawing part of it
        // again (a line that came) is not a new screen, and must not tell
        // the source it is. The columns reach two pieces either side, which
        // setting the pieces at the edges reads.
        // What is drawn is what is on screen and what AppKit draws ahead of
        // scrolling there (its prepared content, never more than a screen
        // around it): all of it is the screen.
        let drawn = visibleRect.union(preparedContentRect).intersection(aroundScreen)
        let screen = lines(in: drawn)
        let shown = Screen(lines: screen, left: drawn.minX.rounded(), width: drawn.width.rounded())
        if shown != readAhead {
            readAhead = shown
            let reach = 2 * FileTextMetrics.piece
            let from = max(0, Int((drawn.minX - FileTextMetrics.left) / metrics.advance) - reach)
            let to = max(from + 1, Int(((drawn.maxX - FileTextMetrics.left) / metrics.advance).rounded(.up)) + reach)
            source.showScreen(lines: screen, columns: from..<to)
        }
        let (start, end) = selectedRange
        let selectionColor = (selectionActive ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
        if let emphasized, emphasized.overlaps(rows) {
            context.setFillColor(style.emphasis.cgColor)
            let band = CGRect(x: dirtyRect.minX, y: top(ofLine: emphasized.lowerBound), width: dirtyRect.width,
                              height: CGFloat(emphasized.count) * lineHeight)
            context.fill(band.intersection(dirtyRect))
        }
        let left = FileTextMetrics.left
        let from = dirtyRect.minX - left, to = dirtyRect.maxX - left
        context.textMatrix = .identity
        for index in rows {
            let layout = layout(index)
            let top = top(ofLine: index)
            if start != end, index >= start.line, index <= end.line {
                let length = source.utf16Length(ofLine: index)
                let from = index == start.line ? start.column : 0
                let to = index == end.line ? end.column : length
                context.setFillColor(selectionColor)
                let window = (dirtyRect.minX - left)...(dirtyRect.maxX - left)
                // A line whose text has not come is selected by its columns.
                let spans = layout?.spans(from: from, to: to, within: window)
                    ?? (to > from ? [CGFloat(from) * metrics.advance...CGFloat(to) * metrics.advance] : [])
                for span in spans where span.upperBound > span.lowerBound {
                    context.fill(CGRect(x: left + span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: lineHeight))
                }
                // A line selected through its end fills on to the view's edge.
                if index < end.line {
                    let edge = layout?.extent ?? CGFloat(length) * metrics.advance
                    context.fill(CGRect(x: left + edge, y: top, width: max(0, max(bounds.width, dirtyRect.maxX) - left - edge), height: lineHeight))
                }
            }
            // Not come yet: drawn when it has (`arrived`).
            guard let layout else { continue }
            let shown = layout.pieces(from: from, to: to)
            if let find, let search = find.search {
                drawMatches(of: search, current: find.current, line: index, layout: layout, pieces: shown, top: top, dirtyRect: dirtyRect, in: context)
            }
            if layout.extent > measuredWidth { measuredWidth = layout.extent; scheduleWidth() }
            guard !shown.isEmpty else { continue }
            context.saveGState()
            context.setFillColor(style.text.cgColor)
            context.translateBy(x: left, y: top + metrics.baseline)
            context.scaleBy(x: 1, y: -1)
            for piece in shown {
                if piece.squeeze < 1 {
                    // On the grid, a piece of wide characters keeps to its columns.
                    context.saveGState()
                    context.clip(to: CGRect(x: piece.x, y: -lineHeight, width: piece.width, height: lineHeight * 3))
                    context.translateBy(x: piece.x, y: 0); context.scaleBy(x: piece.squeeze, y: 1)
                    context.textPosition = .zero
                    CTLineDraw(piece.line, context)
                    context.restoreGState()
                } else {
                    context.textPosition = CGPoint(x: piece.x, y: 0)
                    CTLineDraw(piece.line, context)
                }
            }
            context.restoreGState()
        }
    }
    /// A find's matches on a line: a soft band behind each, a stronger one
    /// behind the match shown. A line set whole is matched whole; along a
    /// long line, the columns drawn.
    private func drawMatches(of search: FileSearch, current: FileSearchHit?, line index: Int, layout: FileLineLayout,
                             pieces: [FileLineLayout.Piece], top: CGFloat, dirtyRect: NSRect, in context: CGContext) {
        let left = FileTextMetrics.left
        let window = (dirtyRect.minX - left)...(dirtyRect.maxX - left)
        // The columns of the pieces drawn: no band sets a piece off screen, and
        // on the grid, wide characters drawn narrower may sit anywhere in theirs.
        guard let low = pieces.map(\.range.lowerBound).min(), let high = pieces.map(\.range.upperBound).max() else { return }
        let columns = low..<high
        #if DEBUG
        matchedColumns[index] = columns
        #endif
        guard let matches = search.matches(inLine: index, columns: columns) else { return }
        for match in matches {
            let shown = current.map { $0.line == index && $0.columns == match } ?? false
            context.setFillColor((shown ? style.findCurrent : style.findMatch).cgColor)
            for span in layout.spans(from: match.lowerBound, to: match.upperBound, within: window) where span.upperBound > span.lowerBound {
                context.fill(CGRect(x: left + span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: lineHeight))
            }
        }
    }
    #if DEBUG
    /// Test seam: the columns of each line matched to be drawn, in the last
    /// drawing.
    private(set) var matchedColumns: [Int: Range<Int>] = [:]
    #endif
    /// The screen the source was last told of: its lines, and where it is
    /// sideways.
    private struct Screen: Equatable { let lines: ClosedRange<Int>; let left: CGFloat; let width: CGFloat }
    private var readAhead: Screen?
    /// The screen and a screen on every side of it: as far as AppKit is let
    /// draw ahead of scrolling (responsive scrolling's overdraw), so all it
    /// draws is what the source was told is the screen.
    private var aroundScreen: NSRect { visibleRect.insetBy(dx: -visibleRect.width, dy: -visibleRect.height) }
    public override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect.intersection(aroundScreen))
    }
    private var widthScheduled = false
    /// A line wider than the view was drawn: the view widens after this pass.
    private func scheduleWidth() {
        guard !widthScheduled else { return }
        widthScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.widthScheduled = false
                self?.updateFrame()
            }
        }
    }

    public override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }

    // MARK: Selection

    public var hasSelection: Bool { anchor != focus }
    public var selectedRange: (start: FileTextPosition, end: FileTextPosition) { (min(anchor, focus), max(anchor, focus)) }
    /// The selection's text, if all of it is at hand.
    public var selectedText: String? { hasSelection ? source.text(from: selectedRange.start, to: selectedRange.end) : "" }

    /// Selects from `anchor` to `focus`, redrawing the lines either selection
    /// touched, and telling accessibility.
    public func select(from anchor: FileTextPosition, to focus: FileTextPosition, keepGoal: Bool = false) {
        let anchor = clamp(anchor), focus = clamp(focus)
        if !keepGoal { goalX = nil }
        guard anchor != self.anchor || focus != self.focus else { return }
        selectionRevision &+= 1
        let before = min(self.anchor, self.focus).line...max(self.anchor, self.focus).line
        self.anchor = anchor; self.focus = focus
        let after = min(anchor, focus).line...max(anchor, focus).line
        // What is on screen, and what scrolling has drawn ahead of it.
        let drawn = visibleRect.union(preparedContentRect)
        for range in [before, after] {
            let rect = NSRect(x: drawn.minX, y: top(ofLine: range.lowerBound), width: drawn.width, height: CGFloat(range.count) * lineHeight)
            let dirty = rect.intersection(drawn)
            if !dirty.isNull, !dirty.isEmpty { setNeedsDisplay(dirty) }
        }
        ruler?.needsDisplay = true
        announce(.selectedTextChanged)
        find?.selectionChanged()
        selectionDidChange?()
    }
    /// Told when the selection moves, by the keys, the pointer or a reveal:
    /// for what a host shows of the selected line.
    public var selectionDidChange: (() -> Void)?
    private func clamp(_ position: FileTextPosition) -> FileTextPosition {
        let line = max(0, min(position.line, source.lineCount - 1))
        return FileTextPosition(line: line, column: max(0, min(position.column, source.utf16Length(ofLine: line))))
    }
    /// A few characters of a line around a column: enough to find a
    /// character's or a word's edges without reading the whole line.
    private func surroundings(of position: FileTextPosition, radius: Int) -> (text: NSString, base: Int)? {
        let length = source.utf16Length(ofLine: position.line)
        let low = max(0, position.column - radius), high = min(length, position.column + radius)
        return source.text(ofLine: position.line, range: low..<high).map { ($0 as NSString, low) }
    }
    /// A line whole, with its line ending: what a triple-click takes.
    func lineRange(_ index: Int) -> (FileTextPosition, FileTextPosition) {
        let start = FileTextPosition(line: index, column: 0)
        return index + 1 < source.lineCount ? (start, FileTextPosition(line: index + 1, column: 0))
            : (start, FileTextPosition(line: index, column: source.utf16Length(ofLine: index)))
    }
    /// The word or run a double-click at a position takes. The text around
    /// the position is read wider while the word reaches its edges, up to a
    /// megabyte either way. Nil while that text has not come.
    func wordRange(at position: FileTextPosition) -> (FileTextPosition, FileTextPosition)? {
        let length = source.utf16Length(ofLine: position.line)
        var radius = 256
        while true {
            guard let (text, base) = surroundings(of: position, radius: radius) else { return nil }
            guard text.length > 0 else { return (position, position) }
            let range = NSAttributedString(string: text as String).doubleClick(at: max(0, min(position.column - base, text.length - 1)))
            let cut = (range.location == 0 && base > 0) || (NSMaxRange(range) == text.length && base + text.length < length)
            if !cut || radius >= 1 << 20 {
                return (FileTextPosition(line: position.line, column: base + range.location), FileTextPosition(line: position.line, column: base + NSMaxRange(range)))
            }
            radius *= 4
        }
    }

    /// Scrolls just enough to show a position, with a line to spare.
    public func scrollToVisible(_ position: FileTextPosition) {
        let point = point(of: position)
        scrollToVisible(NSRect(x: point.x - 24, y: point.y - lineHeight, width: 48, height: lineHeight * 3))
    }
    /// Selects a match and shows it: near the top third if its line is off
    /// screen, as a jump does, and sideways into view along a long line.
    public func show(match: FileSearchHit) {
        select(from: match.start, to: match.end)
        if !lines(in: visibleRect.insetBy(dx: 0, dy: lineHeight)).contains(match.line) { scrollTo(line: match.line) }
        let from = point(of: match.start), to = point(of: match.end)
        scrollToVisible(NSRect(x: from.x - 24, y: from.y, width: max(48, to.x - from.x + 48), height: lineHeight))
    }
    /// Shows a line near the top third of the view, as a jump to it should.
    public func scrollTo(line index: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let y = max(0, min(top(ofLine: index) - clip.bounds.height / 3, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Mouse

    /// How long a press waits for its next event before checking the button
    /// is still down: a release that goes missing (the window closes under
    /// the press) must not leave the main thread waiting.
    static let pressPoll: TimeInterval = 0.1

    public override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        // A press is a new selection: keys still waiting for text are not done.
        dropPending()
        let hit = position(at: convert(event.locationInWindow, from: nil))
        // A double click takes a word, a triple click the line; dragging on
        // from either keeps what the click took and extends by words or lines.
        let clicks = event.clickCount
        var taken: (FileTextPosition, FileTextPosition)?
        switch clicks {
        case ...1: event.modifierFlags.contains(.shift) ? select(from: anchor, to: hit) : select(from: hit, to: hit)
        case 2:
            taken = wordRange(at: hit)
            if taken == nil {
                // A word whose text has not come yet is taken when it has,
                // unless the reader has moved on (dragged, clicked) since.
                select(from: hit, to: hit)
                deferredWord = nil
                move(false, scrolls: false) { view, _ in view.wordRange(at: hit)?.0 }
                move(true, scrolls: false) { view, _ in
                    // Found while its text is held, and kept for the press
                    // still going on, which may no longer have that text.
                    let word = view.wordRange(at: hit)
                    view.deferredWord = word
                    return word?.1
                }
            }
        default: taken = lineRange(hit.line)
        }
        if let taken { select(from: taken.0, to: taken.1) }
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while true {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                             until: Date(timeIntervalSinceNow: Self.pressPoll), inMode: .eventTracking, dequeue: true) else {
                guard NSEvent.pressedMouseButtons & 1 == 1, self.window === window else { return }
                continue
            }
            if next.type == .leftMouseUp || self.window !== window { break }
            // The periodic events that scroll under a held press keep coming
            // after a release that went missing: each asks the button again.
            if next.type == .periodic, NSEvent.pressedMouseButtons & 1 == 0 { break }
            if next.type == .leftMouseDragged { last = next }
            autoscroll(with: last)
            let moved = position(at: convert(last.locationInWindow, from: nil))
            // A word whose text came while the press is held is taken from
            // then, as if it had been there at the click.
            if clicks == 2, taken == nil, let word = deferredWord { taken = word }
            if let taken {
                if moved >= taken.0 && moved <= taken.1 { select(from: taken.0, to: taken.1) }
                else if moved > taken.1 { select(from: taken.0, to: clicks == 2 ? max(wordRange(at: moved)?.1 ?? moved, moved) : lineRange(moved.line).1) }
                else { select(from: taken.1, to: clicks == 2 ? min(wordRange(at: moved)?.0 ?? moved, moved) : lineRange(moved.line).0) }
            } else {
                select(from: anchor, to: moved)
            }
        }
    }

    /// The menu a secondary click opens: the host app's own if it gives
    /// one, else Copy and Select All.
    public var contextMenu: ((FileTextView) -> NSMenu?)?
    public override func menu(for event: NSEvent) -> NSMenu? {
        if let contextMenu { return contextMenu(self) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self; copy.isEnabled = hasSelection
        let all = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(copy); menu.addItem(all)
        return menu
    }

    // MARK: Copy

    /// Copies the selection: at once when its text is at hand, else when it
    /// has been read (a later Copy of another selection supersedes it).
    @objc public func copy(_ sender: Any?) {
        guard hasSelection else { return }
        let (start, end) = selectedRange
        copies += 1
        let ticket = copies
        source.fetch(from: start, to: end) { [weak self] text in
            guard let self, ticket == self.copies, let text, !text.isEmpty else { return }
            self.pasteboard.clearContents(); self.pasteboard.setString(text, forType: .string)
        }
    }
    private var copies = 0
    public override func selectAll(_ sender: Any?) { select(from: .start, to: end) }

    // MARK: Keys

    /// Shows lines set apart, near the top third, the insertion point at the
    /// first of them: at once if the text has them, else when it does, and
    /// the last line if the text ends before them. Until the text is read
    /// through: read again (as Latin-1, say), they are shown again.
    public func reveal(lines: ClosedRange<Int>) {
        revealing = lines; revealShown = false; revealGeneration = source.generation
        revealIfReady()
    }
    /// Shows the file from its start with nothing set apart: the insertion
    /// point before its first character, and the view scrolled to its top
    /// left, whatever was shown or waiting to be before it (lines being
    /// revealed, keys waiting for their text).
    public func showTop() {
        revealing = nil; revealShown = false; emphasized = nil
        dropPending(); deferredWord = nil
        let revision = selectionRevision
        select(from: .start, to: .start)
        // Already there: a find still going to a match would take the view
        // away again, and is dropped all the same.
        if selectionRevision == revision { find?.readerMoved() }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.scroll(to: .zero)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    /// The reading of the text the lines were shown in: read again (as
    /// Latin-1, say), they are shown again once found again.
    private var revealGeneration = 0
    private var revealing: ClosedRange<Int>?
    /// Whether the lines being revealed have been scrolled to: once their
    /// first is found. Their band grows until their last is.
    private var revealShown = false
    private func revealIfReady() {
        guard let target = revealing, window != nil, (enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else { return }
        if source.generation != revealGeneration { revealGeneration = source.generation; revealShown = false }
        let count = source.lineCount, indexing = source.isIndexing
        guard target.lowerBound < count || !indexing else { return }
        let first = max(0, min(target.lowerBound, count - 1)), last = min(max(first, target.upperBound), count - 1)
        emphasized = first...last
        if !revealShown {
            revealShown = true
            select(from: FileTextPosition(line: first, column: 0), to: FileTextPosition(line: first, column: 0))
            scrollTo(line: first)
        }
        if !indexing { revealing = nil }
    }

    /// The space bar pages, as it does in a read-only page. Everything else
    /// goes through the key bindings to the commands below.
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            event.modifierFlags.contains(.shift) ? scrollPageUp(nil) : scrollPageDown(nil)
            return
        }
        interpretKeyEvents([event])
    }
    /// Commands that would change the text do nothing: there is nothing to
    /// insert into or delete from. Anything else this view does not take goes
    /// on, as it would from any view: Escape first.
    public override func doCommand(by selector: Selector) {
        if responds(to: selector) { _ = perform(selector, with: nil); return }
        let name = NSStringFromSelector(selector)
        let edits = ["insert", "delete", "transpose", "yank", "capitalize", "lowercase", "uppercase", "indent", "complete", "changeCase"]
        if edits.contains(where: { name.hasPrefix($0) }) { return }
        super.doCommand(by: selector)
    }
    public override func insertText(_ insertString: Any) {}
    public override func cancelOperation(_ sender: Any?) { nextResponder?.doCommand(by: #selector(cancelOperation(_:))) }
    public override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    public override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

    /// A movement waiting for text to come.
    private struct Pending {
        let extend: Bool, keepGoal: Bool
        /// Whether the view scrolls to show where it went: a key's movement
        /// does, a click's word does not (the click was where the reader looks).
        let scrolls: Bool
        let to: @MainActor (FileTextView, FileTextPosition) -> FileTextPosition?
    }
    /// Movements waiting for text to come, in the order the keys were
    /// pressed, and the selection they wait at: done when the text has come,
    /// unless the selection has been changed by anything else since, even if
    /// it came back (every change counts, `selectionRevision`), or the text
    /// can no longer come.
    private var pending: [Pending] = []
    private var pendingRevision = 0
    private(set) var selectionRevision = 0
    /// What the movement waiting now needs, kept until it is done or dropped.
    private var pendingHold: FileTextHold?
    /// A double-clicked word found once its text came.
    private var deferredWord: (FileTextPosition, FileTextPosition)?
    /// What accessibility's latest small read needs, until the next.
    private var accessibilityHold: FileTextHold?
    private func dropPending() { pending = []; pendingHold?.release(); pendingHold = nil }

    /// Moves the insertion point, or with `extend` the selection's focus, and
    /// shows where it went. A movement that needs text not come yet waits
    /// for it, the selection left as it was; so do the movements after it,
    /// each from where the one before it ends.
    /// `to` is handed the view, and holds nothing of its own, so a movement
    /// left waiting keeps no view alive.
    private func move(_ extend: Bool, keepGoal: Bool = false, scrolls: Bool = true, _ to: @escaping @MainActor (FileTextView, FileTextPosition) -> FileTextPosition?) {
        if !pending.isEmpty, pendingRevision == selectionRevision, source.isReading {
            pending.append(Pending(extend: extend, keepGoal: keepGoal, scrolls: scrolls, to: to))
            return
        }
        dropPending()
        pending = [Pending(extend: extend, keepGoal: keepGoal, scrolls: scrolls, to: to)]
        pendingRevision = selectionRevision
        runPending()
    }
    /// Does the waiting movements in turn, as far as the text at hand goes.
    /// A movement whose text will not come (the file stopped being read) is
    /// dropped with those after it.
    private func runPending() {
        var moved = false
        while let next = pending.first {
            // Each movement holds what it needs while it waits: tried again,
            // it reads what it held before letting go of that, and once done
            // it holds nothing when the next is tried.
            let (target, hold) = source.holding { next.to(self, focus) }
            pendingHold?.release(); pendingHold = nil
            guard let target else {
                if source.isReading { pendingHold = hold } else { hold?.release(); dropPending() }
                break
            }
            hold?.release()
            pending.removeFirst()
            select(from: next.extend ? anchor : target, to: target, keepGoal: next.keepGoal)
            pendingRevision = selectionRevision
            moved = moved || next.scrolls
        }
        if moved { scrollToVisible(focus) }
    }
    /// Text asked for has come, or lines changed: those lines are drawn again
    /// (and set again, if they were), the view fits the text, and a movement
    /// waiting for them is done.
    func arrived(_ lines: ClosedRange<Int>) {
        layouts = layouts.filter { !lines.contains($0.key) }
        updateFrame()
        revealIfReady()
        let clamped = (clamp(anchor), clamp(focus))
        if clamped.0 != anchor || clamped.1 != focus { select(from: clamped.0, to: clamped.1) }
        let drawn = visibleRect.union(preparedContentRect)
        let rect = NSRect(x: drawn.minX, y: top(ofLine: lines.lowerBound), width: drawn.width, height: CGFloat(lines.count) * lineHeight).intersection(drawn)
        if !rect.isNull, !rect.isEmpty { setNeedsDisplay(rect) }
        ruler?.textChanged()
        if !pending.isEmpty {
            if pendingRevision == selectionRevision { runPending() } else { dropPending() }
        }
        // What was read comes to accessibility too: once for all that comes
        // in one turn of the run loop.
        if lines.overlaps(visibleLines) || lines.overlaps(selectedRange.start.line...selectedRange.end.line) { announceArrival() }
    }
    private var arrivalAnnounced = false
    private func announceArrival() {
        guard !arrivalAnnounced else { return }
        arrivalAnnounced = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.arrivalAnnounced = false
                self.announce(.valueChanged)
                if self.hasSelection { self.announce(.selectedTextChanged) }
            }
        }
    }
    /// Tells accessibility; a test listens in its place.
    lazy var announce: (NSAccessibility.Notification) -> Void = { [weak self] notification in
        if let self { NSAccessibility.post(element: self, notification: notification) }
    }
    /// Left and Right without Shift first collapse a selection to that side:
    /// decided when the movement is done, after any waiting before it.
    private func stepOrCollapse(from position: FileTextPosition, forward: Bool) -> FileTextPosition? {
        if hasSelection { return forward ? selectedRange.end : selectedRange.start }
        return character(from: position, forward: forward)
    }

    private func character(from position: FileTextPosition, forward: Bool) -> FileTextPosition? {
        let length = source.utf16Length(ofLine: position.line)
        if forward, position.column >= length {
            return position.line + 1 < source.lineCount ? FileTextPosition(line: position.line + 1, column: 0) : position
        }
        if !forward, position.column <= 0 {
            return position.line > 0 ? FileTextPosition(line: position.line - 1, column: source.utf16Length(ofLine: position.line - 1)) : position
        }
        guard let (text, base) = surroundings(of: position, radius: 64) else { return nil }
        if forward { return FileTextPosition(line: position.line, column: base + NSMaxRange(text.rangeOfComposedCharacterSequence(at: position.column - base))) }
        return FileTextPosition(line: position.line, column: base + text.rangeOfComposedCharacterSequence(at: position.column - base - 1).location)
    }
    private func word(from position: FileTextPosition, forward: Bool) -> FileTextPosition? {
        let length = source.utf16Length(ofLine: position.line)
        if forward, position.column >= length { return character(from: position, forward: true) }
        if !forward, position.column <= 0 { return character(from: position, forward: false) }
        var radius = 256
        while true {
            guard let (text, base) = surroundings(of: position, radius: radius) else { return nil }
            let next = NSAttributedString(string: text as String).nextWord(from: position.column - base, forward: forward)
            // A word that runs to the edge of what was read may go on past it.
            let atEdge = forward ? (next >= text.length && base + text.length < length) : (next <= 0 && base > 0)
            if !atEdge || radius >= 1 << 20 { return FileTextPosition(line: position.line, column: base + next) }
            radius *= 4
        }
    }
    private func vertical(from position: FileTextPosition, lines: Int) -> FileTextPosition? {
        let target = position.line + lines
        if target < 0 { return .start }
        if target >= source.lineCount { return end }
        guard let layout = layout(target) else { return nil }
        let x = goalX ?? self.x(of: position)
        goalX = x
        guard let column = layout.index(at: x) else { return nil }
        return FileTextPosition(line: target, column: column)
    }
    private var pageLines: Int { max(1, Int((enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / lineHeight) - 1) }

    public override func moveLeft(_ sender: Any?) { move(false) { $0.stepOrCollapse(from: $1, forward: false) } }
    public override func moveRight(_ sender: Any?) { move(false) { $0.stepOrCollapse(from: $1, forward: true) } }
    public override func moveBackward(_ sender: Any?) { moveLeft(sender) }
    public override func moveForward(_ sender: Any?) { moveRight(sender) }
    public override func moveLeftAndModifySelection(_ sender: Any?) { move(true) { $0.character(from: $1, forward: false) } }
    public override func moveRightAndModifySelection(_ sender: Any?) { move(true) { $0.character(from: $1, forward: true) } }
    public override func moveBackwardAndModifySelection(_ sender: Any?) { moveLeftAndModifySelection(sender) }
    public override func moveForwardAndModifySelection(_ sender: Any?) { moveRightAndModifySelection(sender) }
    public override func moveUp(_ sender: Any?) { move(false, keepGoal: true) { $0.vertical(from: $1, lines: -1) } }
    public override func moveDown(_ sender: Any?) { move(false, keepGoal: true) { $0.vertical(from: $1, lines: 1) } }
    public override func moveUpAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { $0.vertical(from: $1, lines: -1) } }
    public override func moveDownAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { $0.vertical(from: $1, lines: 1) } }
    public override func moveWordLeft(_ sender: Any?) { move(false) { $0.word(from: $1, forward: false) } }
    public override func moveWordRight(_ sender: Any?) { move(false) { $0.word(from: $1, forward: true) } }
    public override func moveWordBackward(_ sender: Any?) { moveWordLeft(sender) }
    public override func moveWordForward(_ sender: Any?) { moveWordRight(sender) }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) { move(true) { $0.word(from: $1, forward: false) } }
    public override func moveWordRightAndModifySelection(_ sender: Any?) { move(true) { $0.word(from: $1, forward: true) } }
    public override func moveWordBackwardAndModifySelection(_ sender: Any?) { moveWordLeftAndModifySelection(sender) }
    public override func moveWordForwardAndModifySelection(_ sender: Any?) { moveWordRightAndModifySelection(sender) }
    public override func moveToBeginningOfLine(_ sender: Any?) { move(false) { FileTextPosition(line: $1.line, column: 0) } }
    public override func moveToEndOfLine(_ sender: Any?) { move(false) { FileTextPosition(line: $1.line, column: $0.source.utf16Length(ofLine: $1.line)) } }
    public override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    public override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(true) { FileTextPosition(line: $1.line, column: 0) } }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(true) { FileTextPosition(line: $1.line, column: $0.source.utf16Length(ofLine: $1.line)) } }
    public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    // A file's line is its paragraph.
    public override func moveToBeginningOfParagraph(_ sender: Any?) { moveToBeginningOfLine(sender) }
    public override func moveToEndOfParagraph(_ sender: Any?) { moveToEndOfLine(sender) }
    public override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    public override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        move(true) { $1.column > 0 ? FileTextPosition(line: $1.line, column: 0) : FileTextPosition(line: max(0, $1.line - 1), column: 0) }
    }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
        move(true) { view, position in
            let length = view.source.utf16Length(ofLine: position.line)
            if position.column < length { return FileTextPosition(line: position.line, column: length) }
            let next = min(view.source.lineCount - 1, position.line + 1)
            return FileTextPosition(line: next, column: view.source.utf16Length(ofLine: next))
        }
    }
    public override func moveToBeginningOfDocument(_ sender: Any?) { move(false) { _, _ in .start } }
    public override func moveToEndOfDocument(_ sender: Any?) { move(false) { view, _ in view.end } }
    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(true) { _, _ in .start } }
    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(true) { view, _ in view.end } }
    public override func pageUp(_ sender: Any?) { move(false, keepGoal: true) { $0.vertical(from: $1, lines: -$0.pageLines) } }
    public override func pageDown(_ sender: Any?) { move(false, keepGoal: true) { $0.vertical(from: $1, lines: $0.pageLines) } }
    public override func pageUpAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { $0.vertical(from: $1, lines: -$0.pageLines) } }
    public override func pageDownAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { $0.vertical(from: $1, lines: $0.pageLines) } }
    public override func selectLine(_ sender: Any?) { let range = lineRange(focus.line); select(from: range.0, to: range.1) }
    public override func selectParagraph(_ sender: Any?) { selectLine(sender) }
    public override func selectWord(_ sender: Any?) { if let range = wordRange(at: focus) { select(from: range.0, to: range.1) } }
    public override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let y = max(0, min(top(ofLine: focus.line) - (clip.bounds.height - lineHeight) / 2, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // Scrolling that leaves the selection where it is: Home, End, Page Up
    // and Page Down, and the space bar.
    private func scroll(by delta: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let y = max(0, min(frame.height - clip.bounds.height, clip.bounds.minY + delta))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    public override func scrollPageUp(_ sender: Any?) { scroll(by: -CGFloat(pageLines) * lineHeight) }
    public override func scrollPageDown(_ sender: Any?) { scroll(by: CGFloat(pageLines) * lineHeight) }
    public override func scrollLineUp(_ sender: Any?) { scroll(by: -lineHeight) }
    public override func scrollLineDown(_ sender: Any?) { scroll(by: lineHeight) }
    public override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(by: -.greatestFiniteMagnitude) }
    public override func scrollToEndOfDocument(_ sender: Any?) { scroll(by: .greatestFiniteMagnitude) }

    // MARK: Accessibility

    /// The whole text is the value only up to a million UTF-16 units; beyond
    /// that VoiceOver reads it through the ranges below, as far as it asks.
    /// No request builds more than that much text at once.
    static let accessibleTextLimit = 1_000_000

    public override func accessibilityLabel() -> String? { name.isEmpty ? "File contents" : "Contents of \(name)" }
    /// Only text at hand: what has not been read yet is not handed over, but
    /// read, in one go and away from the screen's own, and kept here for when
    /// accessibility asks again, which it is told to (`announce`).
    public override func accessibilityValue() -> Any? {
        guard source.utf16Length <= Self.accessibleTextLimit else { return nil }
        return accessibleText(from: .start, to: end)
    }
    private struct Span: Hashable { let start: FileTextPosition; let end: FileTextPosition }
    /// The latest texts read for accessibility, newest last, for the text
    /// shown now and its generation; and the reads for it under way.
    private var answers: [(span: Span, text: String)] = []
    private var answering: Set<Span> = []
    private var answersFor = (showing: 0, generation: 0)
    /// Bumped by `show`: what was read for the text shown before is not used.
    private var showing = 0
    private var answeringNow = 0
    /// At most this many reads for accessibility at once; it asks again.
    static let answeringLimit = 4
    /// Text for accessibility: at hand, or read for it and kept a while.
    private func accessibleText(from start: FileTextPosition, to end: FileTextPosition) -> String? {
        let span = Span(start: start, end: end), current = (showing: showing, generation: source.generation)
        if answersFor != current { answers = []; answering = []; answersFor = current }
        if let answer = answers.last(where: { $0.span == span }) { return answer.text }
        if let text = source.textAtHand(from: start, to: end) { return text }
        guard !answering.contains(span), answering.count < Self.answeringLimit else { return nil }
        answering.insert(span)
        answeringNow += 1
        source.fetch(from: start, to: end) { [weak self] text in
            guard let self, self.answersFor == current, self.showing == current.showing, self.source.generation == current.generation else { return }
            self.answering.remove(span)
            guard let text else { return }
            self.answers.append((span, text))
            if self.answers.count > 4 { self.answers.removeFirst() }
            // Come later, not at once: accessibility is told to ask again.
            if self.answeringNow == 0 { self.announceArrival() }
        }
        answeringNow -= 1
        return answers.last { $0.span == span }?.text
    }
    /// The text is read only: its selection can be set, the text itself not.
    public override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) || selector == #selector(setAccessibilitySelectedText(_:)) { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    public override func setAccessibilityValue(_ value: Any?) {}
    public override func setAccessibilitySelectedText(_ text: String?) {}
    public override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    public override func setAccessibilityFocused(_ focused: Bool) { if focused { window?.makeFirstResponder(self) } }
    public override func accessibilityNumberOfCharacters() -> Int { source.utf16Length }
    public override func accessibilitySelectedText() -> String? {
        guard accessibilitySelectedTextRange().length <= Self.accessibleTextLimit else { return nil }
        return hasSelection ? accessibleText(from: selectedRange.start, to: selectedRange.end) : ""
    }
    public override func accessibilitySelectedTextRange() -> NSRange {
        let start = source.utf16Offset(of: selectedRange.start), end = source.utf16Offset(of: selectedRange.end)
        return NSRange(location: start, length: end - start)
    }
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let start = source.position(atUTF16: range.location), end = source.position(atUTF16: range.location + max(0, range.length))
        select(from: start, to: end)
        scrollToVisible(end)
    }
    public override func accessibilitySelectedTextRanges() -> [NSValue]? { [NSValue(range: accessibilitySelectedTextRange())] }
    public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        if let first = ranges?.first { setAccessibilitySelectedTextRange(first.rangeValue) }
    }
    public override func accessibilityInsertionPointLineNumber() -> Int { focus.line }
    public override func accessibilityVisibleCharacterRange() -> NSRange {
        let lines = visibleLines
        let start = source.utf16Start(ofLine: lines.lowerBound)
        let end = source.utf16Start(ofLine: lines.upperBound) + source.utf16Length(ofLine: lines.upperBound)
        return NSRange(location: start, length: end - start)
    }
    public override func accessibilityString(for range: NSRange) -> String? {
        let clamped = clamped(range)
        guard clamped.length <= Self.accessibleTextLimit else { return nil }
        let start = source.position(atUTF16: clamped.location), end = source.position(atUTF16: NSMaxRange(clamped))
        return accessibleText(from: start, to: end)
    }
    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = accessibilityString(for: range) else { return nil }
        let font = metrics.font
        let described: [String: Any] = [
            NSAccessibility.FontAttributeKey.fontName.rawValue: font.fontName,
            NSAccessibility.FontAttributeKey.fontFamily.rawValue: font.familyName ?? font.fontName,
            NSAccessibility.FontAttributeKey.visibleName.rawValue: font.displayName ?? font.fontName,
            NSAccessibility.FontAttributeKey.fontSize.rawValue: font.pointSize,
        ]
        return NSAttributedString(string: text, attributes: [.accessibilityFont: described, .accessibilityForegroundColor: style.text.cgColor])
    }
    public override func accessibilityLine(for index: Int) -> Int { source.line(atUTF16: max(0, min(index, source.utf16Length))) }
    /// A line with its "\n", as a text view counts it.
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0, line < source.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        let start = source.utf16Start(ofLine: line)
        let length = source.utf16Length(ofLine: line) + (line + 1 < source.lineCount ? 1 : 0)
        return NSRange(location: start, length: length)
    }
    /// Accessibility's small reads hold what they need until its next: asked
    /// again once told the text came, it is all there.
    private func heldForAccessibility<T>(_ body: () -> T) -> T {
        let (result, hold) = source.holding(body)
        accessibilityHold?.release()
        accessibilityHold = hold
        return result
    }
    public override func accessibilityRange(for index: Int) -> NSRange { heldForAccessibility { characterRange(at: index) } }
    private func characterRange(at index: Int) -> NSRange {
        let position = source.position(atUTF16: index)
        let length = source.utf16Length(ofLine: position.line)
        guard position.column < length else {
            // The "\n" at a line's end, or the text's end.
            return NSRange(location: source.utf16Offset(of: position), length: position.line + 1 < source.lineCount ? 1 : 0)
        }
        // Not come yet: not known, which asking has read for next time.
        guard let (text, base) = surroundings(of: position, radius: 64) else { return NSRange(location: NSNotFound, length: 0) }
        let character = text.rangeOfComposedCharacterSequence(at: position.column - base)
        return NSRange(location: source.utf16Start(ofLine: position.line) + base + character.location, length: character.length)
    }
    /// One style throughout a line: a line is a style run.
    public override func accessibilityStyleRange(for index: Int) -> NSRange {
        accessibilityRange(forLine: accessibilityLine(for: index))
    }
    /// The character under a point: the one whose glyphs hold it, or past a
    /// line's end its "\n".
    public override func accessibilityRange(for point: NSPoint) -> NSRange { heldForAccessibility { characterRange(atPoint: point) } }
    private func characterRange(atPoint point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let caret = position(at: local)
        let x = local.x - FileTextMetrics.left
        guard let layout = layout(caret.line), let (text, base) = surroundings(of: caret, radius: 64) else {
            return characterRange(at: source.utf16Offset(of: caret))
        }
        var candidates: [NSRange] = []
        if caret.column < layout.length { candidates.append(text.rangeOfComposedCharacterSequence(at: caret.column - base)) }
        if caret.column > 0 { candidates.append(text.rangeOfComposedCharacterSequence(at: caret.column - base - 1)) }
        for character in candidates {
            let spans = layout.spans(from: base + character.location, to: base + NSMaxRange(character))
            if spans.contains(where: { $0.contains(x) }) {
                return NSRange(location: source.utf16Start(ofLine: caret.line) + base + character.location, length: character.length)
            }
        }
        return characterRange(at: source.utf16Offset(of: caret))
    }
    /// Where a range is drawn, on the screen. Within a line, exactly; across
    /// lines, the band from its first line to its last, the width of the view
    /// (no line between is set to measure it).
    public override func accessibilityFrame(for range: NSRange) -> NSRect { heldForAccessibility { frame(for: range) } }
    private func frame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let clamped = clamped(range)
        let start = source.position(atUTF16: clamped.location), end = source.position(atUTF16: NSMaxRange(clamped))
        let rect: NSRect
        if start.line == end.line, let layout = layout(start.line) {
            let from: CGFloat, to: CGFloat
            if layout.grid, end.column - start.column > 4 * FileTextMetrics.piece {
                // A long range on the grid: its end pieces are measured, and
                // every piece between keeps its glyphs inside its columns,
                // which lie between them. Nothing else is set, or read: an
                // end whose piece has not come is where its column is.
                let head = layout.pieceRange(containing: start.column), tail = layout.pieceRange(containing: end.column - 1)
                let first = head.map { layout.spans(from: start.column, to: min(end.column, $0.upperBound)) } ?? []
                let last = tail.map { layout.spans(from: max(start.column, $0.lowerBound), to: end.column) } ?? []
                from = first.map(\.lowerBound).min() ?? CGFloat(start.column) * metrics.advance
                to = last.map(\.upperBound).max() ?? CGFloat(end.column) * metrics.advance
            } else {
                let spans = layout.spans(from: start.column, to: end.column)
                from = spans.map(\.lowerBound).min() ?? layout.x(at: start.column)
                to = spans.map(\.upperBound).max() ?? from
            }
            rect = NSRect(x: FileTextMetrics.left + from, y: top(ofLine: start.line), width: max(1, to - from), height: lineHeight)
        } else if start.line == end.line {
            // Not come yet: its columns.
            let from = CGFloat(start.column) * metrics.advance, to = CGFloat(end.column) * metrics.advance
            rect = NSRect(x: FileTextMetrics.left + from, y: top(ofLine: start.line), width: max(1, to - from), height: lineHeight)
        } else {
            rect = NSRect(x: FileTextMetrics.left, y: top(ofLine: start.line), width: max(1, bounds.width - FileTextMetrics.left - FileTextMetrics.right),
                          height: CGFloat(end.line - start.line + 1) * lineHeight)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }
    private func clamped(_ range: NSRange) -> NSRange {
        let total = source.utf16Length
        let location = max(0, min(range.location == NSNotFound ? 0 : range.location, total))
        return NSRange(location: location, length: max(0, min(range.length, total - location)))
    }
}

extension FileTextView: NSMenuItemValidation {
    /// Copy only with something selected.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return hasSelection }
        return true
    }
}

/// What a host puts beside a line's number (its blame): a short text, and
/// the detail its tooltip shows. `actionable` lines can be clicked.
public struct FileLineAnnotation: Equatable {
    public var text: String
    public var detail: String
    public var actionable: Bool
    public init(text: String, detail: String, actionable: Bool) { self.text = text; self.detail = detail; self.actionable = actionable }
}

/// The line numbers beside the text, in the scroll view's vertical ruler, so
/// they stay put when the text scrolls sideways and move with it up and down.
/// A click on a number selects that line; a drag, the lines it crosses. A
/// host may put an annotation column before the numbers (`annotations`):
/// drawn for the lines on screen only, and a click there is the host's, never
/// a selection.
@MainActor public final class FileLineNumberRuler: NSRulerView, NSViewToolTipOwner {
    weak var textView: FileTextView?
    /// Each line's annotation, by line (from 0); nil for none. Setting it
    /// shows the column; nil hides it.
    public var annotations: ((Int) -> FileLineAnnotation?)? { didSet { textChanged() } }
    /// Told the line of an actionable annotation clicked.
    public var annotationClicked: ((Int) -> Void)?
    public static let annotationWidth: CGFloat = 176
    private var annotationColumn: CGFloat { annotations == nil ? 0 : Self.annotationWidth }
    private var tipTag: NSView.ToolTipTag?

    init(textView: FileTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        textView.ruler = self
        textChanged()
        // An element of its own, as a ruler is: hidden from accessibility, it
        // made the scroll view fail to list any of its children, and VoiceOver
        // found no text in it at all.
        setAccessibilityLabel("Line numbers")
    }
    public required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    /// Wide enough for the last line's number, and room either side.
    func textChanged() {
        let digits = CGFloat(String(textView?.source.lineCount ?? 1).count)
        let thickness = (max(2, digits) * (textView?.metrics.digitWidth ?? 7) + 12 + 8 + annotationColumn).rounded(.up)
        if ruleThickness != thickness { ruleThickness = thickness }
        updateTip()
        needsDisplay = true
    }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateTip() }
    /// One tooltip area over the annotation column, its text asked for where
    /// the pointer rests.
    private func updateTip() {
        if let tipTag { removeToolTip(tipTag); self.tipTag = nil }
        guard annotations != nil else { return }
        tipTag = addToolTip(NSRect(x: 0, y: 0, width: annotationColumn, height: bounds.height), owner: self, userData: nil)
    }
    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let textView, let annotations else { return "" }
        return annotations(textView.line(at: textView.convert(point, from: self).y))?.detail ?? ""
    }
    public override var requiredThickness: CGFloat { ruleThickness }

    /// The lines whose numbers are drawn stronger: the selected ones, or the
    /// insertion point's.
    private func strong(_ textView: FileTextView) -> ClosedRange<Int> {
        let (start, end) = textView.selectedRange
        guard textView.hasSelection else { return start.line...start.line }
        return start.line...max(start.line, end.column == 0 && end.line > start.line ? end.line - 1 : end.line)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let textView, let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = strong(textView)
        context.textMatrix = .identity
        for index in textView.lines(in: textView.visibleRect) {
            let y = convert(NSPoint(x: 0, y: textView.top(ofLine: index)), from: textView).y
            guard y + textView.lineHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            let emphasized = selected.contains(index) || textView.emphasized?.contains(index) == true
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(index + 1), attributes: [
                .font: textView.metrics.numbersFont,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.setFillColor((emphasized ? textView.style.strongLineNumber : textView.style.lineNumber).cgColor)
            context.translateBy(x: bounds.width - 12 - width, y: y + textView.metrics.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            if let annotation = annotations?(index) { drawAnnotation(annotation, at: y, emphasized: emphasized, in: context, textView: textView) }
        }
    }
    /// An annotation, cut to its column with an ellipsis.
    private func drawAnnotation(_ annotation: FileLineAnnotation, at y: CGFloat, emphasized: Bool, in context: CGContext, textView: FileTextView) {
        let attributed = NSAttributedString(string: annotation.text, attributes: [
            .font: textView.metrics.numbersFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let full = CTLineCreateWithAttributedString(attributed)
        let room = Double(annotationColumn - 16)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
            .font: textView.metrics.numbersFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        let line = CTLineCreateTruncatedLine(full, room, .end, ellipsis) ?? full
        context.saveGState()
        context.setFillColor((emphasized ? textView.style.strongLineNumber : textView.style.lineNumber).cgColor)
        context.translateBy(x: 8, y: y + textView.metrics.baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    public override func mouseDown(with event: NSEvent) {
        guard let textView, let window else { return }
        // The annotation column is the host's: a click there opens what the
        // annotation names, and selects nothing.
        let point = convert(event.locationInWindow, from: nil)
        if let annotations, point.x < annotationColumn {
            let line = textView.line(at: textView.convert(event.locationInWindow, from: nil).y)
            if annotations(line)?.actionable == true { annotationClicked?(line) }
            return
        }
        window.makeFirstResponder(textView)
        func line(_ event: NSEvent) -> Int { textView.line(at: textView.convert(event.locationInWindow, from: nil).y) }
        let first = line(event)
        let anchorLine = event.modifierFlags.contains(.shift) ? textView.anchor.line : first
        func select(to index: Int) {
            let low = textView.lineRange(min(anchorLine, index)), high = textView.lineRange(max(anchorLine, index))
            index >= anchorLine ? textView.select(from: low.0, to: high.1) : textView.select(from: high.1, to: low.0)
        }
        select(to: first)
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while true {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                             until: Date(timeIntervalSinceNow: FileTextView.pressPoll), inMode: .eventTracking, dequeue: true) else {
                guard NSEvent.pressedMouseButtons & 1 == 1, self.window === window else { return }
                continue
            }
            if next.type == .leftMouseUp || self.window !== window { break }
            if next.type == .periodic, NSEvent.pressedMouseButtons & 1 == 0 { break }
            if next.type == .leftMouseDragged { last = next }
            textView.autoscroll(with: last)
            select(to: line(last))
        }
    }
    public override func resetCursorRects() { addCursorRect(visibleRect, cursor: .arrow) }
}

/// A file's text in a scroll view with its line numbers: what a file tab shows.
@MainActor public final class FileTextScrollView: NSScrollView {
    public let textView = FileTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    public private(set) var numbers: FileLineNumberRuler!

    public override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        borderType = .noBorder; drawsBackground = false
        // The text starts under whatever its host puts above it, never under
        // a title bar it is not under.
        automaticallyAdjustsContentInsets = false
        documentView = textView
        numbers = FileLineNumberRuler(textView: textView, scrollView: self)
        verticalRulerView = numbers
        hasHorizontalRuler = false; hasVerticalRuler = true; rulersVisible = true
    }
    public required init?(coder: NSCoder) { nil }
    /// The line numbers beside the text, not over it: AppKit lays a vertical
    /// ruler over the clip view's left edge, so the clip view is moved to
    /// start where the ruler ends.
    public override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView, !ruler.isHidden else { return }
        var clip = contentView.frame
        let edge = ruler.frame.maxX
        guard clip.minX < edge else { return }
        clip.size.width = max(0, clip.width - (edge - clip.minX)); clip.origin.x = edge
        contentView.frame = clip
    }
}
