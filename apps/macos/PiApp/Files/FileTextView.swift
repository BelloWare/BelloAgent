import AppKit

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

/// How the viewer sets text.
@MainActor enum FileTextMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let numbersFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let lineHeight: CGFloat = 17
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
    /// The width of one character of the font.
    static let advance: CGFloat = {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }()
    static var tabInterval: CGFloat { advance * tabSpaces }
    /// Where a line's baseline sits in its 17 points: the font's ascent and
    /// descent centred, on a whole point.
    static let baseline: CGFloat = {
        let content = font.ascender - font.descender
        return (((lineHeight - content) / 2) + font.ascender).rounded()
    }()
    /// Text set with tab stops every four columns from the line's start, when
    /// the text itself starts `origin` points along the line.
    static func attributes(origin: CGFloat, tabs: Bool, grid: Bool) -> [NSAttributedString.Key: Any] {
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
            let reach = CGFloat(piece + 1) * tabInterval
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

/// One line as CoreText sets it: its text in pieces, each read and set when
/// it is first needed. A line up to `FileTextMetrics.gridLine` long is set
/// piece after piece from its start, each piece where the last one ended; a
/// longer one on the grid.
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
    let index: Int
    let length: Int
    let grid: Bool
    /// From the line's start, the pieces set so far.
    private var ordered: [Piece] = []
    private var complete = false
    /// On the grid, the pieces set, by number.
    private var gridPieces: [Int: Piece] = [:]

    init(source: FileTextSource, line index: Int) {
        self.source = source; self.index = index
        length = source.utf16Length(ofLine: index)
        grid = length > FileTextMetrics.gridLine
        if !grid, length <= FileTextMetrics.piece { measureNext() }
    }

    /// The whole line's width: exact once every piece is set, and always on the grid.
    var width: CGFloat? {
        if grid { return CGFloat(length) * FileTextMetrics.advance }
        return complete ? measuredEnd.x : nil
    }
    /// How wide the line is at least, as far as it is known: what is set,
    /// and a column for each unit not yet set. Tabs set so far can make the
    /// line far wider than its length says.
    var extent: CGFloat {
        if let width { return width }
        return measuredEnd.x + CGFloat(length - measuredEnd.index) * FileTextMetrics.advance
    }
    private var measuredEnd: (index: Int, x: CGFloat) { ordered.last.map { ($0.range.upperBound, $0.x + $0.width) } ?? (0, 0) }

    /// Where a piece that starts at `start` and should end near `target` ends:
    /// after a space or a tab within reach, else where a character ends, so no
    /// character is cut and words are set whole where they can be.
    private func end(ofPieceFrom start: Int, target: Int) -> Int {
        guard target < length else { return length }
        let base = max(start, target - 64)
        let window = source.text(ofLine: index, range: base..<min(length, target + 16)) as NSString
        var cut = target - base
        let space = window.rangeOfCharacter(from: .whitespaces, options: .backwards, range: NSRange(location: 0, length: min(cut, window.length)))
        if space.location != NSNotFound, space.location > 0 { cut = space.location + 1 }
        else if cut < window.length {
            let character = window.rangeOfComposedCharacterSequence(at: cut)
            cut = character.location > 0 ? character.location : NSMaxRange(character)
        }
        return max(start + 1, min(length, base + cut))
    }
    private func set(_ range: Range<Int>, x: CGFloat) -> Piece {
        let text = source.text(ofLine: index, range: range)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: FileTextMetrics.attributes(origin: x, tabs: text.contains("\t"), grid: grid)))
        FileTextRenderCount.built()
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard grid else { return Piece(range: range, x: x, width: natural, line: line, squeeze: 1) }
        let cell = CGFloat(range.count) * FileTextMetrics.advance
        return Piece(range: range, x: x, width: cell, line: line, squeeze: natural > cell + 0.5 ? cell / natural : 1)
    }
    private func measureNext() {
        guard !complete, !grid else { return }
        let (start, x) = measuredEnd
        let end = length <= FileTextMetrics.piece ? length : end(ofPieceFrom: start, target: start + FileTextMetrics.piece)
        ordered.append(set(start..<end, x: x))
        if end >= length { complete = true }
    }
    /// On the grid, where piece `number` starts: at a multiple of the piece
    /// length, moved back to where a character starts. Found from the text
    /// around it alone, so no piece before it is read.
    private func gridStart(_ number: Int) -> Int {
        let target = number * FileTextMetrics.piece
        guard number > 0 else { return 0 }
        guard target < length else { return length }
        let base = max(0, target - 32)
        let window = source.text(ofLine: index, range: base..<min(length, target + 32)) as NSString
        return base + window.rangeOfComposedCharacterSequence(at: target - base).location
    }
    /// On the grid, the piece holding a column.
    private func gridPiece(containing column: Int) -> Piece {
        let column = max(0, min(column, length - 1))
        // Starts move back to where a character starts, so a column can
        // belong to the piece before its multiple, or (a character cut by
        // the multiple) to the next piece.
        var number = column / FileTextMetrics.piece
        if number > 0, column < gridStart(number) { number -= 1 }
        else if column >= gridStart(number + 1) { number += 1 }
        if let piece = gridPieces[number] { return piece }
        // Pieces well away from the one asked for are let go of first.
        if gridPieces.count > 64 { gridPieces = gridPieces.filter { abs($0.key - number) < 16 } }
        let low = gridStart(number)
        let piece = set(low..<max(low + 1, gridStart(number + 1)), x: CGFloat(low) * FileTextMetrics.advance)
        gridPieces[number] = piece
        return piece
    }

    /// The pieces that reach into `from..<to` along the line.
    func pieces(from: CGFloat, to: CGFloat) -> [Piece] {
        guard length > 0, to > from else { return [] }
        if grid {
            var result: [Piece] = []
            var column = max(0, Int(from / FileTextMetrics.advance))
            // A column's place is known before its piece is set: nothing past
            // the edge is set.
            while column < length, CGFloat(column) * FileTextMetrics.advance < to {
                let piece = gridPiece(containing: column)
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
    /// Where an offset sits along the line.
    func x(at column: Int) -> CGFloat {
        let column = max(0, min(column, length))
        guard let piece = piece(containing: column) else { return 0 }
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
        if grid, let window, let first = piece(containing: Int(max(0, window.lowerBound) / FileTextMetrics.advance)) {
            column = max(from, first.range.lowerBound)
        }
        while column < to, let piece = piece(containing: column) {
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
    /// the insertion point.
    func index(at x: CGFloat) -> Int {
        guard x > 0, length > 0 else { return 0 }
        let piece: Piece
        if grid {
            guard x < CGFloat(length) * FileTextMetrics.advance else { return length }
            piece = gridPiece(containing: Int(x / FileTextMetrics.advance))
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
@MainActor final class FileTextView: NSView {
    private(set) var source: FileTextSource = FileTextLines("")
    /// What accessibility calls the text: "Contents of Main.swift".
    private(set) var name = ""
    /// Lines to set apart, softly: the lines a file was opened at.
    var emphasized: ClosedRange<Int>? { didSet { if emphasized != oldValue { needsDisplay = true; ruler?.needsDisplay = true } } }
    /// Where Copy puts text. The general pasteboard; a test's own otherwise.
    var pasteboard: NSPasteboard = .general
    weak var ruler: FileLineNumberRuler?

    /// The selection runs from the anchor to the focus, either way round. The
    /// two are equal when nothing is selected: the insertion point.
    private(set) var anchor = FileTextPosition.start
    private(set) var focus = FileTextPosition.start
    /// Where Up and Down keep the insertion point, across short lines.
    private var goalX: CGFloat?
    private var layouts: [Int: FileLineLayout] = [:]
    private var layoutGeneration = 0
    /// How wide the widest line drawn so far turned out to be.
    private var measuredWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityIdentifier("file-text-view")
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// Shows a text from its start, with nothing selected.
    func show(_ source: FileTextSource, name: String) {
        self.source = source; self.name = name
        layouts = [:]; layoutGeneration = source.generation; measuredWidth = 0; goalX = nil; emphasized = nil
        anchor = .start; focus = .start
        updateFrame()
        needsDisplay = true; ruler?.textChanged()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Geometry

    var lineHeight: CGFloat { FileTextMetrics.lineHeight }
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
    var visibleLines: ClosedRange<Int> { lines(in: visibleRect) }
    /// The line under a point, clamped to the text.
    func line(at y: CGFloat) -> Int { max(0, min(source.lineCount - 1, Int(floor((y - FileTextMetrics.top) / lineHeight)))) }

    func layout(_ index: Int) -> FileLineLayout {
        if layoutGeneration != source.generation { layouts = [:]; layoutGeneration = source.generation }
        if let layout = layouts[index] { return layout }
        // Lines well away from the screen are let go of before more are set.
        if layouts.count > max(256, 4 * (visibleLines.count + 1)) {
            let keep = visibleLines
            layouts = layouts.filter { keep.contains($0.key) }
        }
        let layout = FileLineLayout(source: source, line: index)
        layouts[index] = layout
        return layout
    }

    /// Where a position is drawn, in this view.
    func point(of position: FileTextPosition) -> NSPoint {
        NSPoint(x: FileTextMetrics.left + layout(position.line).x(at: position.column), y: top(ofLine: position.line))
    }
    /// The position a point in this view puts the insertion point at: above
    /// the text is its start, below it its end.
    func position(at point: NSPoint) -> FileTextPosition {
        if point.y < FileTextMetrics.top { return .start }
        if point.y >= top(ofLine: source.lineCount) { return end }
        let line = line(at: point.y)
        return FileTextPosition(line: line, column: layout(line).index(at: point.x - FileTextMetrics.left))
    }
    /// The end of the text.
    var end: FileTextPosition { FileTextPosition(line: source.lineCount - 1, column: source.utf16Length(ofLine: source.lineCount - 1)) }

    /// As tall as the text, and as wide as its longest line, or the view it
    /// is shown in.
    func updateFrame() {
        let visible = enclosingScrollView?.contentView.bounds.size ?? frame.size
        let estimate = CGFloat(source.longestLine) * FileTextMetrics.advance
        let width = max(visible.width, FileTextMetrics.left + max(estimate, measuredWidth) + FileTextMetrics.right)
        let height = max(visible.height, top(ofLine: source.lineCount) + FileTextMetrics.bottom)
        let size = NSSize(width: width.rounded(.up), height: height.rounded(.up))
        if frame.size != size { setFrameSize(size) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true; clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        updateFrame()
    }
    @objc private func clipResized(_ note: Notification) { updateFrame() }
    @objc private func clipScrolled(_ note: Notification) { ruler?.needsDisplay = true }

    // MARK: Drawing

    private var selectionActive: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
    }
    @objc private func keyChanged(_ note: Notification) { if hasSelection { needsDisplay = true } }
    override func becomeFirstResponder() -> Bool {
        if hasSelection { needsDisplay = true }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }
    override func resignFirstResponder() -> Bool { if hasSelection { needsDisplay = true }; return true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = lines(in: dirtyRect)
        let (start, end) = selectedRange
        let selectionColor = (selectionActive ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
        if let emphasized, emphasized.overlaps(rows) {
            context.setFillColor(NSColor.piAccentSoft.cgColor)
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
                let from = index == start.line ? start.column : 0
                let to = index == end.line ? end.column : layout.length
                context.setFillColor(selectionColor)
                let window = (dirtyRect.minX - left)...(dirtyRect.maxX - left)
                for span in layout.spans(from: from, to: to, within: window) where span.upperBound > span.lowerBound {
                    context.fill(CGRect(x: left + span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: lineHeight))
                }
                // A line selected through its end fills on to the view's edge.
                if index < end.line {
                    let edge = layout.extent
                    context.fill(CGRect(x: left + edge, y: top, width: max(0, max(bounds.width, dirtyRect.maxX) - left - edge), height: lineHeight))
                }
            }
            let shown = layout.pieces(from: from, to: to)
            if layout.extent > measuredWidth { measuredWidth = layout.extent; scheduleWidth() }
            guard !shown.isEmpty else { continue }
            context.saveGState()
            context.setFillColor(NSColor.piInk.cgColor)
            context.translateBy(x: left, y: top + FileTextMetrics.baseline)
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

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }

    // MARK: Selection

    var hasSelection: Bool { anchor != focus }
    var selectedRange: (start: FileTextPosition, end: FileTextPosition) { (min(anchor, focus), max(anchor, focus)) }
    var selectedText: String { hasSelection ? source.text(from: selectedRange.start, to: selectedRange.end) : "" }

    /// Selects from `anchor` to `focus`, redrawing the lines either selection
    /// touched, and telling accessibility.
    func select(from anchor: FileTextPosition, to focus: FileTextPosition, keepGoal: Bool = false) {
        let anchor = clamp(anchor), focus = clamp(focus)
        if !keepGoal { goalX = nil }
        guard anchor != self.anchor || focus != self.focus else { return }
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
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
    private func clamp(_ position: FileTextPosition) -> FileTextPosition {
        let line = max(0, min(position.line, source.lineCount - 1))
        return FileTextPosition(line: line, column: max(0, min(position.column, source.utf16Length(ofLine: line))))
    }
    /// A few characters of a line around a column: enough to find a
    /// character's or a word's edges without reading the whole line.
    private func surroundings(of position: FileTextPosition, radius: Int) -> (text: NSString, base: Int) {
        let length = source.utf16Length(ofLine: position.line)
        let low = max(0, position.column - radius), high = min(length, position.column + radius)
        return (source.text(ofLine: position.line, range: low..<high) as NSString, low)
    }
    /// A line whole, with its line ending: what a triple-click takes.
    func lineRange(_ index: Int) -> (FileTextPosition, FileTextPosition) {
        let start = FileTextPosition(line: index, column: 0)
        return index + 1 < source.lineCount ? (start, FileTextPosition(line: index + 1, column: 0))
            : (start, FileTextPosition(line: index, column: source.utf16Length(ofLine: index)))
    }
    /// The word or run a double-click at a position takes. The text around
    /// the position is read wider while the word reaches its edges, up to a
    /// megabyte either way.
    func wordRange(at position: FileTextPosition) -> (FileTextPosition, FileTextPosition) {
        let length = source.utf16Length(ofLine: position.line)
        var radius = 256
        while true {
            let (text, base) = surroundings(of: position, radius: radius)
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
    func scrollToVisible(_ position: FileTextPosition) {
        let point = point(of: position)
        scrollToVisible(NSRect(x: point.x - 24, y: point.y - lineHeight, width: 48, height: lineHeight * 3))
    }
    /// Shows a line near the top third of the view, as a jump to it should.
    func scrollTo(line index: Int) {
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

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        let hit = position(at: convert(event.locationInWindow, from: nil))
        // A double click takes a word, a triple click the line; dragging on
        // from either keeps what the click took and extends by words or lines.
        let clicks = event.clickCount
        var taken: (FileTextPosition, FileTextPosition)?
        switch clicks {
        case ...1: event.modifierFlags.contains(.shift) ? select(from: anchor, to: hit) : select(from: hit, to: hit)
        case 2: taken = wordRange(at: hit)
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
            if let taken {
                if moved >= taken.0 && moved <= taken.1 { select(from: taken.0, to: taken.1) }
                else if moved > taken.1 { select(from: taken.0, to: clicks == 2 ? max(wordRange(at: moved).1, moved) : lineRange(moved.line).1) }
                else { select(from: taken.1, to: clicks == 2 ? min(wordRange(at: moved).0, moved) : lineRange(moved.line).0) }
            } else {
                select(from: anchor, to: moved)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        PiMenus.menu([
            .button("Copy", enabled: hasSelection, identifier: "file-text-copy") { [weak self] in self?.copy(nil) },
            .button("Select All", identifier: "file-text-select-all") { [weak self] in self?.selectAll(nil) },
        ])
    }

    // MARK: Copy

    @objc func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    override func selectAll(_ sender: Any?) { select(from: .start, to: end) }

    // MARK: Keys

    /// The space bar pages, as it does in a read-only page. Everything else
    /// goes through the key bindings to the commands below.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            event.modifierFlags.contains(.shift) ? scrollPageUp(nil) : scrollPageDown(nil)
            return
        }
        interpretKeyEvents([event])
    }
    /// Commands that would change the text do nothing: there is nothing to
    /// insert into or delete from. Anything else this view does not take goes
    /// on, as it would from any view: Escape first.
    override func doCommand(by selector: Selector) {
        if responds(to: selector) { _ = perform(selector, with: nil); return }
        let name = NSStringFromSelector(selector)
        let edits = ["insert", "delete", "transpose", "yank", "capitalize", "lowercase", "uppercase", "indent", "complete", "changeCase"]
        if edits.contains(where: { name.hasPrefix($0) }) { return }
        super.doCommand(by: selector)
    }
    override func insertText(_ insertString: Any) {}
    override func cancelOperation(_ sender: Any?) { nextResponder?.doCommand(by: #selector(cancelOperation(_:))) }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

    /// Moves the insertion point, or with `extend` the selection's focus, and
    /// shows where it went.
    private func move(_ extend: Bool, keepGoal: Bool = false, _ to: (FileTextPosition) -> FileTextPosition) {
        let target = to(focus)
        select(from: extend ? anchor : target, to: target, keepGoal: keepGoal)
        scrollToVisible(focus)
    }
    /// Left and Right without Shift first collapse a selection to that side.
    private func collapse(toStart: Bool) -> Bool {
        guard hasSelection else { return false }
        let side = toStart ? selectedRange.start : selectedRange.end
        select(from: side, to: side); scrollToVisible(side)
        return true
    }

    private func character(from position: FileTextPosition, forward: Bool) -> FileTextPosition {
        let length = source.utf16Length(ofLine: position.line)
        if forward, position.column >= length {
            return position.line + 1 < source.lineCount ? FileTextPosition(line: position.line + 1, column: 0) : position
        }
        if !forward, position.column <= 0 {
            return position.line > 0 ? FileTextPosition(line: position.line - 1, column: source.utf16Length(ofLine: position.line - 1)) : position
        }
        let (text, base) = surroundings(of: position, radius: 64)
        if forward { return FileTextPosition(line: position.line, column: base + NSMaxRange(text.rangeOfComposedCharacterSequence(at: position.column - base))) }
        return FileTextPosition(line: position.line, column: base + text.rangeOfComposedCharacterSequence(at: position.column - base - 1).location)
    }
    private func word(from position: FileTextPosition, forward: Bool) -> FileTextPosition {
        let length = source.utf16Length(ofLine: position.line)
        if forward, position.column >= length { return character(from: position, forward: true) }
        if !forward, position.column <= 0 { return character(from: position, forward: false) }
        var radius = 256
        while true {
            let (text, base) = surroundings(of: position, radius: radius)
            let next = NSAttributedString(string: text as String).nextWord(from: position.column - base, forward: forward)
            // A word that runs to the edge of what was read may go on past it.
            let atEdge = forward ? (next >= text.length && base + text.length < length) : (next <= 0 && base > 0)
            if !atEdge || radius >= 1 << 20 { return FileTextPosition(line: position.line, column: base + next) }
            radius *= 4
        }
    }
    private func vertical(from position: FileTextPosition, lines: Int) -> FileTextPosition {
        let x = goalX ?? layout(position.line).x(at: position.column)
        goalX = x
        let target = position.line + lines
        if target < 0 { return .start }
        if target >= source.lineCount { return end }
        return FileTextPosition(line: target, column: layout(target).index(at: x))
    }
    private var pageLines: Int { max(1, Int((enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / lineHeight) - 1) }

    override func moveLeft(_ sender: Any?) { if !collapse(toStart: true) { move(false) { character(from: $0, forward: false) } } }
    override func moveRight(_ sender: Any?) { if !collapse(toStart: false) { move(false) { character(from: $0, forward: true) } } }
    override func moveBackward(_ sender: Any?) { moveLeft(sender) }
    override func moveForward(_ sender: Any?) { moveRight(sender) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(true) { character(from: $0, forward: false) } }
    override func moveRightAndModifySelection(_ sender: Any?) { move(true) { character(from: $0, forward: true) } }
    override func moveBackwardAndModifySelection(_ sender: Any?) { moveLeftAndModifySelection(sender) }
    override func moveForwardAndModifySelection(_ sender: Any?) { moveRightAndModifySelection(sender) }
    override func moveUp(_ sender: Any?) { move(false, keepGoal: true) { vertical(from: $0, lines: -1) } }
    override func moveDown(_ sender: Any?) { move(false, keepGoal: true) { vertical(from: $0, lines: 1) } }
    override func moveUpAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { vertical(from: $0, lines: -1) } }
    override func moveDownAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { vertical(from: $0, lines: 1) } }
    override func moveWordLeft(_ sender: Any?) { move(false) { word(from: $0, forward: false) } }
    override func moveWordRight(_ sender: Any?) { move(false) { word(from: $0, forward: true) } }
    override func moveWordBackward(_ sender: Any?) { moveWordLeft(sender) }
    override func moveWordForward(_ sender: Any?) { moveWordRight(sender) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { move(true) { word(from: $0, forward: false) } }
    override func moveWordRightAndModifySelection(_ sender: Any?) { move(true) { word(from: $0, forward: true) } }
    override func moveWordBackwardAndModifySelection(_ sender: Any?) { moveWordLeftAndModifySelection(sender) }
    override func moveWordForwardAndModifySelection(_ sender: Any?) { moveWordRightAndModifySelection(sender) }
    override func moveToBeginningOfLine(_ sender: Any?) { move(false) { FileTextPosition(line: $0.line, column: 0) } }
    override func moveToEndOfLine(_ sender: Any?) { move(false) { FileTextPosition(line: $0.line, column: source.utf16Length(ofLine: $0.line)) } }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(true) { FileTextPosition(line: $0.line, column: 0) } }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(true) { FileTextPosition(line: $0.line, column: source.utf16Length(ofLine: $0.line)) } }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    // A file's line is its paragraph.
    override func moveToBeginningOfParagraph(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToEndOfParagraph(_ sender: Any?) { moveToEndOfLine(sender) }
    override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        move(true) { $0.column > 0 ? FileTextPosition(line: $0.line, column: 0) : FileTextPosition(line: max(0, $0.line - 1), column: 0) }
    }
    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
        move(true) { position in
            let length = source.utf16Length(ofLine: position.line)
            if position.column < length { return FileTextPosition(line: position.line, column: length) }
            let next = min(source.lineCount - 1, position.line + 1)
            return FileTextPosition(line: next, column: source.utf16Length(ofLine: next))
        }
    }
    override func moveToBeginningOfDocument(_ sender: Any?) { move(false) { _ in .start } }
    override func moveToEndOfDocument(_ sender: Any?) { move(false) { _ in end } }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(true) { _ in .start } }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(true) { _ in end } }
    override func pageUp(_ sender: Any?) { move(false, keepGoal: true) { vertical(from: $0, lines: -pageLines) } }
    override func pageDown(_ sender: Any?) { move(false, keepGoal: true) { vertical(from: $0, lines: pageLines) } }
    override func pageUpAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { vertical(from: $0, lines: -pageLines) } }
    override func pageDownAndModifySelection(_ sender: Any?) { move(true, keepGoal: true) { vertical(from: $0, lines: pageLines) } }
    override func selectLine(_ sender: Any?) { let range = lineRange(focus.line); select(from: range.0, to: range.1) }
    override func selectParagraph(_ sender: Any?) { selectLine(sender) }
    override func selectWord(_ sender: Any?) { let range = wordRange(at: focus); select(from: range.0, to: range.1) }
    override func centerSelectionInVisibleArea(_ sender: Any?) {
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
    override func scrollPageUp(_ sender: Any?) { scroll(by: -CGFloat(pageLines) * lineHeight) }
    override func scrollPageDown(_ sender: Any?) { scroll(by: CGFloat(pageLines) * lineHeight) }
    override func scrollLineUp(_ sender: Any?) { scroll(by: -lineHeight) }
    override func scrollLineDown(_ sender: Any?) { scroll(by: lineHeight) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(by: -.greatestFiniteMagnitude) }
    override func scrollToEndOfDocument(_ sender: Any?) { scroll(by: .greatestFiniteMagnitude) }

    // MARK: Accessibility

    /// The whole text is the value only up to a million UTF-16 units; beyond
    /// that VoiceOver reads it through the ranges below, as far as it asks.
    /// No request builds more than that much text at once.
    static let accessibleTextLimit = 1_000_000

    override func accessibilityLabel() -> String? { name.isEmpty ? "File contents" : "Contents of \(name)" }
    override func accessibilityValue() -> Any? {
        source.utf16Length <= Self.accessibleTextLimit ? source.text(from: .start, to: end) : nil
    }
    /// The text is read only: its selection can be set, the text itself not.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) || selector == #selector(setAccessibilitySelectedText(_:)) { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func setAccessibilityValue(_ value: Any?) {}
    override func setAccessibilitySelectedText(_ text: String?) {}
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { window?.makeFirstResponder(self) } }
    override func accessibilityNumberOfCharacters() -> Int { source.utf16Length }
    override func accessibilitySelectedText() -> String? {
        accessibilitySelectedTextRange().length <= Self.accessibleTextLimit ? selectedText : nil
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        let start = source.utf16Offset(of: selectedRange.start), end = source.utf16Offset(of: selectedRange.end)
        return NSRange(location: start, length: end - start)
    }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let start = source.position(atUTF16: range.location), end = source.position(atUTF16: range.location + max(0, range.length))
        select(from: start, to: end)
        scrollToVisible(end)
    }
    override func accessibilitySelectedTextRanges() -> [NSValue]? { [NSValue(range: accessibilitySelectedTextRange())] }
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        if let first = ranges?.first { setAccessibilitySelectedTextRange(first.rangeValue) }
    }
    override func accessibilityInsertionPointLineNumber() -> Int { focus.line }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let lines = visibleLines
        let start = source.utf16Start(ofLine: lines.lowerBound)
        let end = source.utf16Start(ofLine: lines.upperBound) + source.utf16Length(ofLine: lines.upperBound)
        return NSRange(location: start, length: end - start)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let clamped = clamped(range)
        guard clamped.length <= Self.accessibleTextLimit else { return nil }
        return source.text(from: source.position(atUTF16: clamped.location), to: source.position(atUTF16: NSMaxRange(clamped)))
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = accessibilityString(for: range) else { return nil }
        let font = FileTextMetrics.font
        let described: [String: Any] = [
            NSAccessibility.FontAttributeKey.fontName.rawValue: font.fontName,
            NSAccessibility.FontAttributeKey.fontFamily.rawValue: font.familyName ?? font.fontName,
            NSAccessibility.FontAttributeKey.visibleName.rawValue: font.displayName ?? font.fontName,
            NSAccessibility.FontAttributeKey.fontSize.rawValue: font.pointSize,
        ]
        return NSAttributedString(string: text, attributes: [.accessibilityFont: described, .accessibilityForegroundColor: NSColor.piInk.cgColor])
    }
    override func accessibilityLine(for index: Int) -> Int { source.line(atUTF16: max(0, min(index, source.utf16Length))) }
    /// A line with its "\n", as a text view counts it.
    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0, line < source.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        let start = source.utf16Start(ofLine: line)
        let length = source.utf16Length(ofLine: line) + (line + 1 < source.lineCount ? 1 : 0)
        return NSRange(location: start, length: length)
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        let position = source.position(atUTF16: index)
        let length = source.utf16Length(ofLine: position.line)
        guard position.column < length else {
            // The "\n" at a line's end, or the text's end.
            return NSRange(location: source.utf16Offset(of: position), length: position.line + 1 < source.lineCount ? 1 : 0)
        }
        let (text, base) = surroundings(of: position, radius: 64)
        let character = text.rangeOfComposedCharacterSequence(at: position.column - base)
        return NSRange(location: source.utf16Start(ofLine: position.line) + base + character.location, length: character.length)
    }
    /// One style throughout a line: a line is a style run.
    override func accessibilityStyleRange(for index: Int) -> NSRange {
        accessibilityRange(forLine: accessibilityLine(for: index))
    }
    /// The character under a point: the one whose glyphs hold it, or past a
    /// line's end its "\n".
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let caret = position(at: local)
        let x = local.x - FileTextMetrics.left
        let layout = layout(caret.line)
        let (text, base) = surroundings(of: caret, radius: 64)
        var candidates: [NSRange] = []
        if caret.column < layout.length { candidates.append(text.rangeOfComposedCharacterSequence(at: caret.column - base)) }
        if caret.column > 0 { candidates.append(text.rangeOfComposedCharacterSequence(at: caret.column - base - 1)) }
        for character in candidates {
            let spans = layout.spans(from: base + character.location, to: base + NSMaxRange(character))
            if spans.contains(where: { $0.contains(x) }) {
                return NSRange(location: source.utf16Start(ofLine: caret.line) + base + character.location, length: character.length)
            }
        }
        return accessibilityRange(for: source.utf16Offset(of: caret))
    }
    /// Where a range is drawn, on the screen. Within a line, exactly; across
    /// lines, the band from its first line to its last, the width of the view
    /// (no line between is set to measure it).
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let clamped = clamped(range)
        let start = source.position(atUTF16: clamped.location), end = source.position(atUTF16: NSMaxRange(clamped))
        let rect: NSRect
        if start.line == end.line {
            let layout = layout(start.line)
            let from: CGFloat, to: CGFloat
            if layout.grid, end.column - start.column > 4 * FileTextMetrics.piece,
               let head = layout.pieceRange(containing: start.column), let tail = layout.pieceRange(containing: end.column - 1) {
                // A long range on the grid: its end pieces are measured, and
                // every piece between keeps its glyphs inside its columns,
                // which lie between them. Nothing else is set.
                let first = layout.spans(from: start.column, to: min(end.column, head.upperBound))
                let last = layout.spans(from: max(start.column, tail.lowerBound), to: end.column)
                from = first.map(\.lowerBound).min() ?? CGFloat(start.column) * FileTextMetrics.advance
                to = last.map(\.upperBound).max() ?? CGFloat(end.column) * FileTextMetrics.advance
            } else {
                let spans = layout.spans(from: start.column, to: end.column)
                from = spans.map(\.lowerBound).min() ?? layout.x(at: start.column)
                to = spans.map(\.upperBound).max() ?? from
            }
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
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return hasSelection }
        return true
    }
}

/// The line numbers beside the text, in the scroll view's vertical ruler, so
/// they stay put when the text scrolls sideways and move with it up and down.
/// A click on a number selects that line; a drag, the lines it crosses.
@MainActor final class FileLineNumberRuler: NSRulerView {
    weak var textView: FileTextView?

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
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// Wide enough for the last line's number, and room either side.
    func textChanged() {
        let digits = CGFloat(String(textView?.source.lineCount ?? 1).count)
        let thickness = (max(2, digits) * Self.digitWidth + 12 + 8).rounded(.up)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }
    private static let digitWidth: CGFloat = {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: FileTextMetrics.numbersFont]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }()
    override var requiredThickness: CGFloat { ruleThickness }

    /// The lines whose numbers are drawn stronger: the selected ones, or the
    /// insertion point's.
    private func strong(_ textView: FileTextView) -> ClosedRange<Int> {
        let (start, end) = textView.selectedRange
        guard textView.hasSelection else { return start.line...start.line }
        return start.line...max(start.line, end.column == 0 && end.line > start.line ? end.line - 1 : end.line)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = strong(textView)
        context.textMatrix = .identity
        for index in textView.lines(in: textView.visibleRect) {
            let y = convert(NSPoint(x: 0, y: textView.top(ofLine: index)), from: textView).y
            guard y + textView.lineHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            let emphasized = selected.contains(index) || textView.emphasized?.contains(index) == true
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(index + 1), attributes: [
                .font: FileTextMetrics.numbersFont,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.setFillColor((emphasized ? NSColor.piInkSecondary : NSColor.piInkTertiary).cgColor)
            context.translateBy(x: bounds.width - 12 - width, y: y + FileTextMetrics.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let window else { return }
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
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .arrow) }
}

/// A file's text in a scroll view with its line numbers: what a file tab shows.
@MainActor final class FileTextScrollView: NSScrollView {
    let textView = FileTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    private(set) var numbers: FileLineNumberRuler!

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        borderType = .noBorder; drawsBackground = false
        documentView = textView
        numbers = FileLineNumberRuler(textView: textView, scrollView: self)
        verticalRulerView = numbers
        hasHorizontalRuler = false; hasVerticalRuler = true; rulersVisible = true
    }
    required init?(coder: NSCoder) { nil }
}
