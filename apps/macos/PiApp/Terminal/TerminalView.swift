import AppKit
import Carbon
import CoreText

/// Draws a TerminalEmulator with CoreText and turns keys, mouse and paste into
/// the bytes a program expects. The view owns scrollback viewing, selection
/// and copy; the emulator owns everything about the screen.
@MainActor final class TerminalView: NSView, NSTextInputClient {
    let emulator: TerminalEmulator
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    /// Observes redraw requests before AppKit coalesces them or ignores a
    /// detached view. Tests can measure refreshes without an onscreen window.
    var onDisplayInvalidation: ((NSRect) -> Void)?
    /// The Option key sends ESC before the character, the way most shells expect Meta.
    var optionSendsMeta = true
    var font: NSFont {
        didSet {
            let oldHeight = cellHeight
            measureFont()
            scrollFraction *= cellHeight / oldHeight
            normalScrollFraction *= cellHeight / oldHeight
            clearLineCache(); fitGrid(); needsDisplay = true
        }
    }

    struct Position: Equatable, Comparable, Sendable {
        var line: Int   // absolute: TerminalEmulator.trimmedLines + index into lines
        var column: Int
        static func < (a: Position, b: Position) -> Bool { a.line != b.line ? a.line < b.line : a.column < b.column }
    }
    private struct Selection { var start: Position; var end: Position }
    private struct LineKey: Hashable { var text: String; var foreground: TerminalColor; var bold: Bool; var italic: Bool; var dim: Bool; var dark: Bool }

    private var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 8, cellHeight: CGFloat = 16, ascent: CGFloat = 12
    private let inset: CGFloat = 8
    private var scrollOffset = 0
    /// Points beyond `scrollOffset` complete rows, always in 0..<cellHeight.
    private var scrollFraction: CGFloat = 0
    private var scrollAccumulator: CGFloat = 0
    private var showingAlternateScreen = false
    private var normalScrollOffset = 0
    private var normalScrollFraction: CGFloat = 0
    private var historyGeneration = 0
    private var selection: Selection?
    private var selectionAnchor: Position?
    private var selectionDragPoint: NSPoint?
    private var selectionAutoscrollTimer: Timer?
    var selectionAutoscrollActive: Bool { selectionAutoscrollTimer != nil }
    private var markedText = ""
    /// Hands key events to the text input system; a seam, so a test can stand
    /// in for an input method that holds repeats back.
    var interpretKeys: (([NSEvent]) -> Void)?
    /// Whether the keyboard is a plain layout rather than an input method. A
    /// seam for the same reason.
    var keyboardIsLayout: () -> Bool = TerminalView.currentKeyboardIsLayout
    /// A run's line, and whether every glyph in it starts on its own cell.
    private struct CachedLine { let line: CTLine; let onGrid: Bool }
    private var lineCache: [LineKey: CachedLine] = [:]
    private(set) var decodedHistoryLineCount = 0
    private struct DecodedHistoryLine {
        var cells: [TerminalCell]
        var lastUse: Int
        var bytes: Int
    }
    private var decodedHistory: [Int: DecodedHistoryLine] = [:]
    private var historyCacheClock = 0
    private(set) var decodedHistoryBytes = 0
    var decodedHistoryCacheCount: Int { decodedHistory.count }
    static let decodedHistoryLineLimit = 256
    static let decodedHistoryByteLimit = 2 * 1024 * 1024
    private(set) var lineCacheBytes = 0
    static let lineCacheByteLimit = 8 * 1024 * 1024
    private func clearLineCache() { lineCache.removeAll(keepingCapacity: true); lineCacheBytes = 0 }
    private var focused = false
    /// The key that went down in this view and has not come up. Only its
    /// repeats are typed: a key held to answer a question went down in the
    /// question's sheet, and its repeats, which come to this window once the
    /// sheet goes, are not the shell's.
    private var heldKeyCode: UInt16?
    private var resignKeyObserver: NSObjectProtocol?

    init(emulator: TerminalEmulator, font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.emulator = emulator
        self.font = font
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        wantsLayer = true
        measureFont()
        publishDefaultColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { onDisplayInvalidation?(bounds) }
            super.needsDisplay = newValue
        }
    }
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        onDisplayInvalidation?(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }

    /// The shell was asked for the keyboard before this view was in a window
    /// (`TerminalSession.focus`); it takes the keyboard once it is.
    var focusWhenInWindow = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A key released while another window had the keyboard never came up here.
        heldKeyCode = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.heldKeyCode = nil
                    self?.selectionAnchor = nil
                    self?.stopSelectionAutoscroll()
                }
            }
        }
        guard focusWhenInWindow, window != nil else { return }
        focusWhenInWindow = false
        // After the SwiftUI update that added the view, not inside it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Metrics and colours

    private func measureFont() {
        let manager = NSFontManager.shared
        boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
        italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = manager.convert(boldFont, toHaveTrait: .italicFontMask)
        let sample = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(sample)
        var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0, lineLeading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading)
        // The cell is exactly one advance wide. A run of text is drawn as one
        // line at the font's own advances, so a cell rounded up to whole
        // points left the glyphs behind the grid by a fraction of a point per
        // column: the cursor, drawn on the grid, ended up cells to the right
        // of the text and of where the next character appeared.
        cellWidth = CGFloat(advance)
        cellHeight = ceil(lineAscent + lineDescent + max(lineLeading, 2))
        ascent = lineAscent + max(lineLeading, 2) / 2
        emulator.cellPixelSize = (Double(cellWidth), Double(cellHeight))
    }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var defaultForeground: NSColor { .piInk }
    var defaultBackground: NSColor { .piTerminalSurface }
    private var accent: NSColor { .piBrandOrange }
    private static let lightPalette: [NSColor] = ["1d1b17", "b3312c", "2f7d3b", "9a6a00", "2a5aa6", "8a3fb0", "1f7a8c", "c9c3b8", "6e6a61", "d1453f", "3d8a57", "b97a1e", "3b6fc4", "a35bd1", "2c96a8", "f2ede5"].map(NSColor.init(hex:))
    private static let darkPalette: [NSColor] = ["3a3129", "ea7c7c", "7cc48f", "e3b15c", "a8c9fc", "d7a5ee", "7fd3e0", "d9d4cb", "78746b", "f19a9a", "98d6a8", "f0c67c", "bcd6ff", "e4c0f5", "9fe0eb", "f5f1ea"].map(NSColor.init(hex:))
    func color(_ colour: TerminalColor, foreground: Bool) -> NSColor {
        switch colour.kind {
        case .standard: return foreground ? defaultForeground : defaultBackground
        case .rgb(let r, let g, let b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let index):
            if index < 16 { return (isDark ? Self.darkPalette : Self.lightPalette)[Int(index)] }
            if index < 232 {
                let value = Int(index) - 16
                let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return NSColor(srgbRed: steps[value / 36] / 255, green: steps[value / 6 % 6] / 255, blue: steps[value % 6] / 255, alpha: 1)
            }
            let gray = CGFloat(8 + 10 * (Int(index) - 232)) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
    }
    private func publishDefaultColors() {
        func components(_ color: NSColor) -> (UInt8, UInt8, UInt8) {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return (UInt8(clamping: Int(rgb.redComponent * 255)), UInt8(clamping: Int(rgb.greenComponent * 255)), UInt8(clamping: Int(rgb.blueComponent * 255)))
        }
        emulator.defaultForegroundRGB = components(defaultForeground)
        emulator.defaultBackgroundRGB = components(defaultBackground)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clearLineCache(); publishDefaultColors(); needsDisplay = true
    }

    // MARK: Layout

    var columns: Int { emulator.columns }
    var rows: Int { emulator.rows }
    override func layout() { super.layout(); fitGrid() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fitGrid() }
    private func fitGrid() {
        // A view laid out at no size (a terminal not shown yet, a collapsing
        // panel) keeps its grid: fitting the screen to two columns and a row
        // would cut every line and move the cursor before the view shows again.
        guard bounds.width >= inset * 2 + cellWidth * 2, bounds.height >= inset * 2 + cellHeight else { return }
        let columns = max(2, Int((bounds.width - inset * 2) / cellWidth))
        let rows = max(1, Int((bounds.height - inset * 2) / cellHeight))
        guard columns != emulator.columns || rows != emulator.rows else { return }
        // Account for output before moving rows between history and the grid.
        // Resizing is not output: both directions keep the bottom visible line.
        refresh()
        let bottom = CGFloat(emulator.trimmedLines + emulator.lineCount) * cellHeight - scrolledBackPoints
        emulator.resize(columns: columns, rows: rows)
        if isScrolledBack {
            setScrollDistance(CGFloat(emulator.trimmedLines + emulator.lineCount) * cellHeight - bottom)
        }
        producedLines = emulator.trimmedLines + emulator.scrollback.count
        onResize?(columns, rows)
        needsDisplay = true
    }
    /// The first line on screen, in emulator line indices.
    private var partialRow: Int { scrollFraction > 0 ? 1 : 0 }
    private var firstVisibleLine: Int { max(0, emulator.scrollback.count - scrollOffset - partialRow) }
    private var visibleRowCount: Int { emulator.rows + partialRow }
    private var rowOrigin: CGFloat { inset + scrollFraction - CGFloat(partialRow) * cellHeight }
    private var gridRect: NSRect { NSRect(x: 0, y: inset, width: bounds.width, height: CGFloat(emulator.rows) * cellHeight) }
    private func rowRect(_ row: Int) -> NSRect { NSRect(x: 0, y: rowOrigin + CGFloat(row) * cellHeight, width: bounds.width, height: cellHeight) }
    private func cellRect(column: Int, row: Int, width: Int = 1) -> NSRect {
        NSRect(x: inset + CGFloat(column) * cellWidth, y: rowOrigin + CGFloat(row) * cellHeight, width: cellWidth * CGFloat(width), height: cellHeight)
    }
    /// A painted rectangle with its edges on device pixels, so cells, the
    /// cursor and backgrounds stay crisp though a cell is a fractional width.
    /// Glyphs keep their exact origins.
    private func pixelAligned(_ rect: CGRect) -> CGRect { backingAlignedRect(rect, options: .alignAllEdgesNearest) }

    /// Lines the emulator has ever pushed out of the screen, so new output can
    /// be told from lines the scrollback has dropped.
    private var producedLines = 0
    /// Redraws what the emulator changed since the last refresh.
    func refresh() {
        let produced = emulator.trimmedLines + emulator.scrollback.count
        defer { emulator.clearDirty(); producedLines = produced; historyGeneration = emulator.historyGeneration }
        let historyWasCleared = historyGeneration != emulator.historyGeneration
        if historyWasCleared {
            setScrollDistance(0); normalScrollOffset = 0; normalScrollFraction = 0
            decodedHistory.removeAll(keepingCapacity: true); decodedHistoryBytes = 0
            clearLineCache()
            selection = nil; selectionAnchor = nil
            stopSelectionAutoscroll()
        }
        if showingAlternateScreen != emulator.alternateScreen {
            if emulator.alternateScreen {
                if isScrolledBack { setScrollDistance(scrolledBackPoints + CGFloat(max(0, produced - producedLines)) * cellHeight) }
                normalScrollOffset = scrollOffset; normalScrollFraction = scrollFraction
                setScrollDistance(0)
            } else {
                setScrollDistance(CGFloat(normalScrollOffset) * cellHeight + normalScrollFraction)
            }
            showingAlternateScreen = emulator.alternateScreen
            scrollAccumulator = 0
            selection = nil; selectionAnchor = nil
            stopSelectionAutoscroll()
            needsDisplay = true
        }
        if isScrolledBack {
            let previousFirst = producedLines - scrollOffset - partialRow
            let previousFraction = scrollFraction
            let previousScrollOffset = scrollOffset
            // A reader who has scrolled back stays on the lines they are
            // reading: output arriving underneath pushes the bottom further
            // away instead of dragging the text out from under them.
            setScrollDistance(scrolledBackPoints + CGFloat(max(0, produced - producedLines)) * cellHeight)
            if produced - scrollOffset - partialRow != previousFirst || scrollFraction != previousFraction {
                needsDisplay = true
            } else {
                // Rows archived in this chunk could have changed while they
                // were still live. Repaint their old visible area as well.
                if produced > producedLines, previousScrollOffset < emulator.rows {
                    let firstLive = rowRect(previousScrollOffset + partialRow)
                    setNeedsDisplay(firstLive.union(rowRect(visibleRowCount - 1)).intersection(gridRect))
                } else if let dirty = emulator.dirtyRows {
                    for row in dirty where row + scrollOffset + partialRow < visibleRowCount {
                        setNeedsDisplay(rowRect(row + scrollOffset + partialRow).intersection(gridRect))
                    }
                } else if scrollOffset < emulator.rows {
                    let firstLive = rowRect(scrollOffset + partialRow)
                    setNeedsDisplay(firstLive.union(rowRect(visibleRowCount - 1)).intersection(gridRect))
                }
            }
            return
        }
        if historyWasCleared { needsDisplay = true; return }
        guard let dirty = emulator.dirtyRows else { needsDisplay = true; return }
        for row in dirty { setNeedsDisplay(rowRect(row)) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Inside a SwiftUI-hosted hierarchy the dirty rectangle can arrive in
        // the host's coordinates; only this view's own bounds are ever painted.
        let area = dirtyRect.intersection(bounds)
        guard !area.isNull else { return }
        context.clip(to: bounds)
        context.setFillColor(defaultBackground.cgColor)
        context.fill(area)
        context.clip(to: gridRect)
        let first = firstVisibleLine
        let firstRow = max(0, Int(floor((area.minY - rowOrigin) / cellHeight)))
        let lastRow = min(visibleRowCount - 1, Int(floor((area.maxY - rowOrigin) / cellHeight)))
        guard firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            let index = first + row
            guard index < emulator.lineCount else { continue }
            drawRow(row, absoluteLine: emulator.trimmedLines + index, cells: cellsForDrawing(at: index), in: context)
        }
        drawCursor(in: context, firstVisible: first)
    }

    func cellsForDrawing(at index: Int) -> [TerminalCell] {
        guard index >= 0, index < emulator.lineCount else { return [] }
        guard index < emulator.scrollback.count else { return emulator.line(at: index) }
        let history = emulator.scrollback[index]
        historyCacheClock += 1
        if var cached = decodedHistory[history.id] {
            cached.lastUse = historyCacheClock
            decodedHistory[history.id] = cached
            return cached.cells
        }
        decodedHistoryLineCount += 1
        let cells = history.cells
        let bytes = cells.count * MemoryLayout<TerminalCell>.stride + cells.reduce(128) { $0 + $1.text.utf8.count }
        if bytes <= Self.decodedHistoryByteLimit {
            while decodedHistory.count >= Self.decodedHistoryLineLimit || decodedHistoryBytes + bytes > Self.decodedHistoryByteLimit {
                guard let oldest = decodedHistory.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                decodedHistoryBytes -= oldest.value.bytes
                decodedHistory.removeValue(forKey: oldest.key)
            }
            decodedHistory[history.id] = DecodedHistoryLine(cells: cells, lastUse: historyCacheClock, bytes: bytes)
            decodedHistoryBytes += bytes
        }
        return cells
    }

    private func drawRow(_ row: Int, absoluteLine: Int, cells: [TerminalCell], in context: CGContext) {
        let top = rowOrigin + CGFloat(row) * cellHeight
        // Backgrounds first, in runs of one colour.
        var column = 0
        while column < cells.count {
            let cell = cells[column]
            var end = column + 1
            let colour = background(of: cell.style)
            while end < cells.count, background(of: cells[end].style) == colour { end += 1 }
            if let colour {
                context.setFillColor(colour.cgColor)
                context.fill(pixelAligned(CGRect(x: inset + CGFloat(column) * cellWidth, y: top, width: CGFloat(end - column) * cellWidth, height: cellHeight)))
            }
            column = end
        }
        if let selection, absoluteLine >= selection.start.line, absoluteLine <= selection.end.line {
            let from = absoluteLine == selection.start.line ? selection.start.column : 0
            let to = absoluteLine == selection.end.line ? selection.end.column : max(cells.count, emulator.columns)
            if to > from {
                context.setFillColor(accent.withAlphaComponent(0.22).cgColor)
                context.fill(pixelAligned(CGRect(x: inset + CGFloat(from) * cellWidth, y: top, width: CGFloat(to - from) * cellWidth, height: cellHeight)))
            }
        }
        // Then the glyphs: ASCII runs of one style in a single line, everything else cell by cell.
        column = 0
        while column < cells.count {
            let cell = cells[column]
            if cell.width == 0 || cell.style.hidden { column += 1; continue }
            var end = column + 1
            let plain = cell.width == 1 && cell.text.utf8.count == 1
            if plain { while end < cells.count, cells[end].width == 1, cells[end].text.utf8.count == 1, cells[end].style == cell.style { end += 1 } }
            let text = cells[column..<end].map(\.text).joined()
            let isBlank = text.allSatisfy { $0 == " " }
            let x = inset + CGFloat(column) * cellWidth
            if !isBlank {
                let run = line(for: text, style: cell.style)
                if plain && !run.onGrid {
                    // A font whose glyphs do not keep to one advance each: every cell on its own.
                    for (offset, character) in text.enumerated() where character != " " {
                        draw(line(for: String(character), style: cell.style).line, at: CGPoint(x: x + CGFloat(offset) * cellWidth, y: top + ascent), in: context)
                    }
                } else {
                    draw(run.line, at: CGPoint(x: x, y: top + ascent), in: context)
                }
            }
            let width = CGFloat(plain ? end - column : Int(cell.width)) * cellWidth
            if cell.style.underline || cell.style.strikethrough {
                context.setFillColor(foreground(of: cell.style).cgColor)
                if cell.style.underline { context.fill(pixelAligned(CGRect(x: x, y: top + cellHeight - 1.5, width: width, height: 1))) }
                if cell.style.strikethrough { context.fill(pixelAligned(CGRect(x: x, y: top + cellHeight / 2, width: width, height: 1))) }
            }
            column = plain ? end : column + max(1, Int(cell.width))
        }
    }
    private func foreground(of style: CellStyle) -> NSColor {
        let colour = style.inverse ? color(style.background, foreground: false) : color(style.foreground, foreground: true)
        return style.dim ? colour.withAlphaComponent(0.6) : colour
    }
    /// A background to paint, or nil when the cell shows the view's own background.
    private func background(of style: CellStyle) -> NSColor? {
        if style.inverse { return color(style.foreground, foreground: true) }
        if case .standard = style.background.kind { return nil }
        return color(style.background, foreground: false)
    }
    private func draw(_ line: CTLine, at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }
    private func line(for text: String, style: CellStyle) -> CachedLine {
        let key = LineKey(text: text, foreground: style.inverse ? style.background : style.foreground, bold: style.bold, italic: style.italic, dim: style.dim, dark: isDark)
        if let cached = lineCache[key] { return cached }
        let typeface = style.bold && style.italic ? boldItalicFont : style.bold ? boldFont : style.italic ? italicFont : font
        // No kerning and no ligatures: each character keeps its own cell.
        let attributed = NSAttributedString(string: text, attributes: [.font: typeface, .foregroundColor: foreground(of: style), .kern: 0, .ligature: 0])
        let line = CTLineCreateWithAttributedString(attributed)
        // Only ASCII runs, one UTF-16 unit per cell, are drawn as one line;
        // each character there must start where its cell does.
        var onGrid = true
        if text.utf8.count == text.utf16.count, text.utf16.count > 1 {
            for index in 0...text.utf16.count where abs(CTLineGetOffsetForStringIndex(line, index, nil) - CGFloat(index) * cellWidth) > 0.25 { onGrid = false; break }
        }
        let cached = CachedLine(line: line, onGrid: onGrid)
        let cost = text.utf8.count + text.utf16.count * 32 + 256
        if lineCache.count >= 4_096 || cost > Self.lineCacheByteLimit - lineCacheBytes { clearLineCache() }
        if cost <= Self.lineCacheByteLimit { lineCache[key] = cached; lineCacheBytes += cost }
        return cached
    }
    private func drawCursor(in context: CGContext, firstVisible: Int) {
        guard !isScrolledBack, emulator.cursorVisible else { return }
        let cursor = emulator.cursor
        let row = emulator.scrollback.count + cursor.y - firstVisible
        guard row >= 0, row < emulator.rows else { return }
        let cell = emulator.screen[cursor.y][min(cursor.x, emulator.columns - 1)]
        let cellArea = cellRect(column: cursor.x, row: row, width: cell.width == 2 ? 2 : 1)
        let rect = pixelAligned(cellArea)
        if !markedText.isEmpty {
            // Text being composed sits at the cursor until the input method commits it.
            let width = max(1, markedText.unicodeScalars.reduce(0) { $0 + TerminalEmulator.width(of: $1) })
            let markedRect = pixelAligned(NSRect(x: cellArea.minX, y: cellArea.minY, width: CGFloat(width) * cellWidth, height: cellHeight))
            context.setFillColor(accent.withAlphaComponent(0.15).cgColor); context.fill(markedRect)
            draw(line(for: markedText, style: .plain).line, at: CGPoint(x: cellArea.minX, y: cellArea.minY + ascent), in: context)
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: markedRect.minX, y: markedRect.maxY - 2, width: markedRect.width, height: 2))
            return
        }
        guard focused else {
            context.setStrokeColor(accent.cgColor); context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            return
        }
        switch emulator.cursorShape {
        case .block:
            context.setFillColor(accent.cgColor); context.fill(rect)
            if !cell.text.isEmpty, cell.text != " " {
                var style = cell.style; style.foreground = .standard; style.inverse = false
                let attributed = NSAttributedString(string: cell.text, attributes: [.font: font, .foregroundColor: defaultBackground])
                // At the cell's own origin, where the glyph it covers is drawn.
                draw(CTLineCreateWithAttributedString(attributed), at: CGPoint(x: cellArea.minX, y: cellArea.minY + ascent), in: context)
            }
        case .underline:
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .bar:
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        focused = true; needsDisplay = true; heldKeyCode = nil
        if emulator.focusReporting { send("\u{1b}[I") }
        return true
    }
    override func resignFirstResponder() -> Bool {
        focused = false; needsDisplay = true
        if emulator.focusReporting { send("\u{1b}[O") }
        return true
    }
    /// AppKit takes the keyboard from a view it removes without asking it to
    /// resign: showing another terminal left this one's program focused.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopSelectionAutoscroll(); selectionAnchor = nil }
        if newWindow !== window, let window, window.firstResponder === self {
            focused = false
            if emulator.focusReporting { send("\u{1b}[O") }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Keyboard

    private func send(_ text: String) { send(Data(text.utf8)) }
    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        scrollToBottom()
        onInput?(data)
    }
    override func keyDown(with event: NSEvent) {
        if event.isARepeat { guard event.keyCode == heldKeyCode else { return } } else { heldKeyCode = event.keyCode }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: event); return }
        let shift = flags.contains(.shift), control = flags.contains(.control), option = flags.contains(.option)
        if let key = TerminalKeyEncoder.key(forKeyCode: event.keyCode, shift: shift) {
            send(TerminalKeyEncoder.encode(key, applicationCursor: emulator.applicationCursorKeys, shift: shift, control: control, option: option))
            return
        }
        if control, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            let value = scalar.value
            var byte: UInt8? = nil
            if (0x61...0x7a).contains(value) { byte = UInt8(value - 0x60) }
            else if (0x41...0x5a).contains(value) { byte = UInt8(value - 0x40) }
            else {
                switch scalar {
                case " ", "@", "2": byte = 0
                case "[", "3": byte = 0x1b
                case "\\", "4": byte = 0x1c
                case "]", "5": byte = 0x1d
                case "^", "6": byte = 0x1e
                case "_", "7", "-": byte = 0x1f
                case "?", "8": byte = 0x7f
                default: break
                }
            }
            if let byte { send(option ? Data([0x1b, byte]) : Data([byte])); return }
        }
        if option, optionSendsMeta, !control, let characters = event.charactersIgnoringModifiers, characters.utf8.count == 1, characters.unicodeScalars.first!.value < 0x80 {
            send(Data([0x1b]) + Data(characters.utf8)); return
        }
        // macOS's press-and-hold holds a held key's repeats back to offer
        // its accents, through the text input system; a terminal repeats the
        // key instead. Only for a plain keyboard layout and nothing being
        // composed, so input methods and dead keys work as before.
        if event.isARepeat, markedText.isEmpty, let characters = event.characters, Self.repeatsAsTyped(characters), keyboardIsLayout() {
            send(characters); return
        }
        if let interpretKeys { interpretKeys([event]) } else { interpretKeyEvents([event]) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == heldKeyCode { heldKeyCode = nil }
        super.keyUp(with: event)
    }
    /// Printable text: no control characters and none of AppKit's function-key characters.
    nonisolated static func repeatsAsTyped(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && !(0x80..<0xa0).contains($0.value) && !(0xf700...0xf8ff).contains($0.value) }
    }
    static func currentKeyboardIsLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return (Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String) == (kTISTypeKeyboardLayout as String)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V and ⌘C reach copy: and paste: through the responder chain; nothing else is captured.
        super.performKeyEquivalent(with: event)
    }

    // MARK: NSTextInputClient
    // The protocol's requirements are nonisolated; AppKit calls them on the main thread.

    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        MainActor.assumeIsolated {
            markedText = ""
            send(text)
            needsDisplay = true
        }
    }
    nonisolated override func doCommand(by selector: Selector) {
        MainActor.assumeIsolated {
            switch selector {
            case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)): send("\r")
            case #selector(insertTab(_:)): send("\t")
            case #selector(insertBacktab(_:)): send("\u{1b}[Z")
            case #selector(deleteBackward(_:)): send("\u{7f}")
            case #selector(cancelOperation(_:)): send("\u{1b}")
            default: break
            }
        }
    }
    nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        MainActor.assumeIsolated { markedText = text; needsDisplay = true }
    }
    nonisolated func unmarkText() { MainActor.assumeIsolated { markedText = ""; needsDisplay = true } }
    nonisolated func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    nonisolated func markedRange() -> NSRange {
        MainActor.assumeIsolated { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    }
    nonisolated func hasMarkedText() -> Bool { MainActor.assumeIsolated { !markedText.isEmpty } }
    nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        MainActor.assumeIsolated {
            let row = emulator.scrollback.count + emulator.cursor.y - firstVisibleLine
            let rect = cellRect(column: emulator.cursor.x, row: max(0, row))
            // The view is flipped; converting to the window accounts for that.
            guard let window else { return rect }
            return window.convertToScreen(convert(rect, to: nil))
        }
    }
    nonisolated func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Copy, paste, selection

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(text)
    }
    /// Sends pasted text as one paste, bracketed when the program asked for that.
    /// A bracketed paste carries no ESC or C1 CSI of its own, as in iTerm2,
    /// kitty and VTE: a pasted "ESC[201~" would otherwise end the paste early
    /// and run the rest, newlines included, as typed input.
    func pasteText(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste {
            var payload = normalized
            payload.unicodeScalars.removeAll { $0 == "\u{1b}" || $0 == "\u{9b}" }
            send("\u{1b}[200~" + payload + "\u{1b}[201~")
        } else { send(normalized) }
    }
    @objc override func selectAll(_ sender: Any?) {
        // Everything with content: the blank rows under the cursor add nothing.
        let first = emulator.alternateScreen ? emulator.scrollback.count : 0
        guard let last = (first..<emulator.lineCount).last(where: { !emulator.text(atLine: $0).isEmpty }) else { selection = nil; needsDisplay = true; return }
        selection = Selection(start: Position(line: emulator.trimmedLines + first, column: 0), end: Position(line: emulator.trimmedLines + last, column: emulator.line(at: last).count))
        needsDisplay = true
    }
    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil }
        return item.action == #selector(paste(_:)) || item.action == #selector(selectAll(_:))
    }
    var selectedText: String? {
        guard let selection else { return nil }
        var result = ""
        let first = max(selection.start.line, emulator.trimmedLines + (emulator.alternateScreen ? emulator.scrollback.count : 0))
        let last = min(selection.end.line, emulator.trimmedLines + emulator.lineCount - 1)
        guard first <= last else { return result }
        for absolute in first...last {
            let index = absolute - emulator.trimmedLines
            guard index >= 0, index < emulator.lineCount else { continue }
            let cells = emulator.line(at: index)
            let wrappedAt = emulator.wrappedAt(line: index)
            let from = absolute == selection.start.line ? selection.start.column : 0
            let end = absolute == selection.end.line ? min(selection.end.column, cells.count) : cells.count
            let to = min(end, wrappedAt ?? end)
            if from < to {
                var text = cells[from..<to].map(\.text).joined()
                if wrappedAt == nil, absolute != selection.end.line || to >= cells.count { while text.last == " " { text.removeLast() } }
                result += text
            }
            if absolute < last, wrappedAt == nil { result += "\n" }
        }
        return result
    }
    private func position(at point: NSPoint) -> Position {
        let column = min(max(0, Int((point.x - inset) / cellWidth)), emulator.columns)
        let row = min(max(0, Int(floor((point.y - rowOrigin) / cellHeight))), visibleRowCount - 1)
        return Position(line: emulator.trimmedLines + firstVisibleLine + row, column: column)
    }
    override func mouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let position = position(at: point)
        switch event.clickCount {
        case 2: selectWord(at: position)
        case 3: selection = Selection(start: Position(line: position.line, column: 0), end: Position(line: position.line, column: emulator.columns)); selectionAnchor = nil
        default: selectionAnchor = position; selection = nil
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        extendSelection(to: point)
        if !emulator.alternateScreen, point.y < gridRect.minY || point.y > gridRect.maxY {
            selectionDragPoint = point
            if selectionAutoscrollTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    MainActor.assumeIsolated { self.advanceSelectionAutoscroll() }
                }
                selectionAutoscrollTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            advanceSelectionAutoscroll()
        } else { stopSelectionAutoscroll() }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        stopSelectionAutoscroll()
        if let selection, selection.start == selection.end { self.selection = nil; needsDisplay = true }
        selectionAnchor = nil
    }
    private func extendSelection(to point: NSPoint) {
        guard let anchor = selectionAnchor else { return }
        var current = position(at: point)
        if point.y < gridRect.minY { current.column = 0 }
        if point.y > gridRect.maxY { current.column = emulator.columns }
        selection = current < anchor ? Selection(start: current, end: anchor) : Selection(start: anchor, end: current)
    }
    /// The same tick runs immediately on a drag and while the pointer is held
    /// outside the grid. Absolute selection endpoints survive every scroll.
    func advanceSelectionAutoscroll() {
        guard selectionAnchor != nil, let point = selectionDragPoint, !emulator.alternateScreen else {
            stopSelectionAutoscroll(); return
        }
        let distance = point.y < gridRect.minY ? gridRect.minY - point.y : gridRect.maxY - point.y
        let steps = min(4, max(1, ceil(abs(distance) / cellHeight)))
        guard setScrollDistance(scrolledBackPoints + (distance > 0 ? steps : -steps) * cellHeight) else {
            stopSelectionAutoscroll(); return
        }
        extendSelection(to: point)
        needsDisplay = true
    }
    private func stopSelectionAutoscroll() {
        selectionAutoscrollTimer?.invalidate(); selectionAutoscrollTimer = nil
        selectionDragPoint = nil
    }
    private func selectWord(at position: Position) {
        let index = position.line - emulator.trimmedLines
        guard index >= 0, index < emulator.lineCount else { return }
        let cells = emulator.line(at: index)
        guard position.column < cells.count else { return }
        func isWord(_ cell: TerminalCell) -> Bool { cell.text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-./~".unicodeScalars.contains($0) } && !cell.isBlank }
        guard isWord(cells[position.column]) else { return }
        var start = position.column, end = position.column + 1
        while start > 0, isWord(cells[start - 1]) { start -= 1 }
        while end < cells.count, isWord(cells[end]) { end += 1 }
        selection = Selection(start: Position(line: position.line, column: start), end: Position(line: position.line, column: end))
        selectionAnchor = nil
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        if emulator.alternateScreen {
            let lines: Int
            if event.hasPreciseScrollingDeltas {
                scrollAccumulator += event.scrollingDeltaY
                lines = Int(scrollAccumulator / cellHeight)
                scrollAccumulator -= CGFloat(lines) * cellHeight
            } else {
                lines = Int(event.scrollingDeltaY.rounded(.towardZero)) * 3
            }
            guard lines != 0 else { return }
            // Full-screen programs have no scrollback; the wheel moves their cursor instead.
            let key: TerminalKeyEncoder.Key = lines > 0 ? .up : .down
            for _ in 0..<min(abs(lines), 20) { onInput?(TerminalKeyEncoder.encode(key, applicationCursor: emulator.applicationCursorKeys)) }
            return
        }
        let distance = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY.rounded(.towardZero) * 3 * cellHeight
        if setScrollDistance(scrolledBackPoints + distance) { needsDisplay = true }
    }
    /// Lines the reader has scrolled back from the newest output.
    var scrolledBackLines: Int { scrollOffset }
    var scrolledBackPoints: CGFloat { CGFloat(scrollOffset) * cellHeight + scrollFraction }
    private var isScrolledBack: Bool { scrollOffset > 0 || scrollFraction > 0 }
    @discardableResult private func setScrollDistance(_ points: CGFloat) -> Bool {
        let next = min(max(0, points), CGFloat(emulator.scrollback.count) * cellHeight)
        let changed = next != scrolledBackPoints
        scrollOffset = Int(next / cellHeight)
        scrollFraction = next - CGFloat(scrollOffset) * cellHeight
        return changed
    }
    func scrollToBottom() { if setScrollDistance(0) { needsDisplay = true } }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    /// Which terminal this is ("Terminal 2", or the reader's own name), so
    /// VoiceOver can tell a project's terminals apart.
    var accessibilityName = "Terminal" { didSet { NSAccessibility.post(element: self, notification: .titleChanged) } }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityValue() -> Any? { emulator.screenText }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
