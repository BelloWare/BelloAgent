import AppKit
import CoreText
import SwiftUI

/// Draws a TerminalEmulator with CoreText and turns keys, mouse and paste into
/// the bytes a program expects. The view owns scrollback viewing, selection
/// and copy; the emulator owns everything about the screen.
@MainActor final class TerminalView: NSView, NSTextInputClient {
    let emulator: TerminalEmulator
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    /// The Option key sends ESC before the character, the way most shells expect Meta.
    var optionSendsMeta = true
    var font: NSFont { didSet { measureFont(); lineCache.removeAll(); fitGrid(); needsDisplay = true } }

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
    private var scrollAccumulator: CGFloat = 0
    private var selection: Selection?
    private var selectionAnchor: Position?
    private var markedText = ""
    private var lineCache: [LineKey: CTLine] = [:]
    private var focused = false

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
        cellWidth = ceil(CGFloat(advance))
        cellHeight = ceil(lineAscent + lineDescent + max(lineLeading, 2))
        ascent = lineAscent + max(lineLeading, 2) / 2
        emulator.cellPixelSize = (Int(cellWidth), Int(cellHeight))
    }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var defaultForeground: NSColor { NSColor(Color.piInk) }
    var defaultBackground: NSColor { NSColor(Color.piTerminalSurface) }
    private var accent: NSColor { NSColor(Color.piBrandOrange) }
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
        lineCache.removeAll(); publishDefaultColors(); needsDisplay = true
    }

    // MARK: Layout

    var columns: Int { emulator.columns }
    var rows: Int { emulator.rows }
    override func layout() { super.layout(); fitGrid() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fitGrid() }
    private func fitGrid() {
        let columns = max(2, Int((bounds.width - inset * 2) / cellWidth))
        let rows = max(1, Int((bounds.height - inset * 2) / cellHeight))
        guard columns != emulator.columns || rows != emulator.rows else { return }
        emulator.resize(columns: columns, rows: rows)
        onResize?(columns, rows)
        needsDisplay = true
    }
    /// The first line on screen, in emulator line indices.
    private var firstVisibleLine: Int { max(0, emulator.lineCount - emulator.rows - scrollOffset) }
    private func rowRect(_ row: Int) -> NSRect { NSRect(x: 0, y: inset + CGFloat(row) * cellHeight, width: bounds.width, height: cellHeight) }
    private func cellRect(column: Int, row: Int, width: Int = 1) -> NSRect {
        NSRect(x: inset + CGFloat(column) * cellWidth, y: inset + CGFloat(row) * cellHeight, width: cellWidth * CGFloat(width), height: cellHeight)
    }

    /// Lines the emulator has ever pushed out of the screen, so new output can
    /// be told from lines the scrollback has dropped.
    private var producedLines = 0
    /// Redraws what the emulator changed since the last refresh.
    func refresh() {
        let produced = emulator.trimmedLines + emulator.scrollback.count
        defer { emulator.clearDirty(); producedLines = produced }
        if scrollOffset > 0 {
            // A reader who has scrolled back stays on the lines they are
            // reading: output arriving underneath pushes the bottom further
            // away instead of dragging the text out from under them.
            scrollOffset = min(scrollOffset + max(0, produced - producedLines), emulator.scrollback.count)
            needsDisplay = true
            return
        }
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
        let first = firstVisibleLine
        let firstRow = max(0, Int((area.minY - inset) / cellHeight))
        let lastRow = min(emulator.rows - 1, Int((area.maxY - inset) / cellHeight))
        guard firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            let index = first + row
            guard index < emulator.lineCount else { continue }
            drawRow(row, absoluteLine: emulator.trimmedLines + index, cells: emulator.line(at: index), in: context)
        }
        drawCursor(in: context, firstVisible: first)
    }

    private func drawRow(_ row: Int, absoluteLine: Int, cells: [TerminalCell], in context: CGContext) {
        let top = inset + CGFloat(row) * cellHeight
        // Backgrounds first, in runs of one colour.
        var column = 0
        while column < cells.count {
            let cell = cells[column]
            var end = column + 1
            let colour = background(of: cell.style)
            while end < cells.count, background(of: cells[end].style) == colour { end += 1 }
            if let colour {
                context.setFillColor(colour.cgColor)
                context.fill(CGRect(x: inset + CGFloat(column) * cellWidth, y: top, width: CGFloat(end - column) * cellWidth, height: cellHeight))
            }
            column = end
        }
        if let selection, absoluteLine >= selection.start.line, absoluteLine <= selection.end.line {
            let from = absoluteLine == selection.start.line ? selection.start.column : 0
            let to = absoluteLine == selection.end.line ? selection.end.column : max(cells.count, emulator.columns)
            if to > from {
                context.setFillColor(accent.withAlphaComponent(0.22).cgColor)
                context.fill(CGRect(x: inset + CGFloat(from) * cellWidth, y: top, width: CGFloat(to - from) * cellWidth, height: cellHeight))
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
                let line = line(for: text, style: cell.style)
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: x, y: top + ascent)
                CTLineDraw(line, context)
                context.restoreGState()
            }
            let width = CGFloat(plain ? end - column : Int(cell.width)) * cellWidth
            if cell.style.underline || cell.style.strikethrough {
                context.setFillColor(foreground(of: cell.style).cgColor)
                if cell.style.underline { context.fill(CGRect(x: x, y: top + cellHeight - 1.5, width: width, height: 1)) }
                if cell.style.strikethrough { context.fill(CGRect(x: x, y: top + cellHeight / 2, width: width, height: 1)) }
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
    private func line(for text: String, style: CellStyle) -> CTLine {
        let key = LineKey(text: text, foreground: style.inverse ? style.background : style.foreground, bold: style.bold, italic: style.italic, dim: style.dim, dark: isDark)
        if let cached = lineCache[key] { return cached }
        let typeface = style.bold && style.italic ? boldItalicFont : style.bold ? boldFont : style.italic ? italicFont : font
        let attributed = NSAttributedString(string: text, attributes: [.font: typeface, .foregroundColor: foreground(of: style)])
        let line = CTLineCreateWithAttributedString(attributed)
        if lineCache.count > 4_096 { lineCache.removeAll(keepingCapacity: true) }
        lineCache[key] = line
        return line
    }
    private func drawCursor(in context: CGContext, firstVisible: Int) {
        guard scrollOffset == 0, emulator.cursorVisible else { return }
        let cursor = emulator.cursor
        let row = emulator.scrollback.count + cursor.y - firstVisible
        guard row >= 0, row < emulator.rows else { return }
        let cell = emulator.screen[cursor.y][min(cursor.x, emulator.columns - 1)]
        let rect = cellRect(column: cursor.x, row: row, width: cell.width == 2 ? 2 : 1)
        if !markedText.isEmpty {
            // Text being composed sits at the cursor until the input method commits it.
            let width = markedText.unicodeScalars.reduce(0) { $0 + max(1, TerminalEmulator.width(of: $1)) }
            let markedRect = NSRect(x: rect.minX, y: rect.minY, width: CGFloat(width) * cellWidth, height: cellHeight)
            context.setFillColor(accent.withAlphaComponent(0.15).cgColor); context.fill(markedRect)
            let line = line(for: markedText, style: .plain)
            context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1); context.textPosition = CGPoint(x: rect.minX, y: rect.minY + ascent)
            CTLineDraw(line, context); context.restoreGState()
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
                let line = CTLineCreateWithAttributedString(attributed)
                context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1); context.textPosition = CGPoint(x: rect.minX, y: rect.minY + ascent)
                CTLineDraw(line, context); context.restoreGState()
            }
        case .underline:
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .bar:
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        focused = true; needsDisplay = true
        if emulator.focusReporting { send("\u{1b}[I") }
        return true
    }
    override func resignFirstResponder() -> Bool {
        focused = false; needsDisplay = true
        if emulator.focusReporting { send("\u{1b}[O") }
        return true
    }

    // MARK: Keyboard

    private func send(_ text: String) { send(Data(text.utf8)) }
    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
        onInput?(data)
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: event); return }
        let shift = flags.contains(.shift), control = flags.contains(.control), option = flags.contains(.option)
        func special(_ key: TerminalKeyEncoder.Key) { send(TerminalKeyEncoder.encode(key, applicationCursor: emulator.applicationCursorKeys, shift: shift, control: control, option: option)) }
        switch event.keyCode {
        case 126: special(.up); return
        case 125: special(.down); return
        case 123: special(.left); return
        case 124: special(.right); return
        case 115: special(.home); return
        case 119: special(.end); return
        case 116: special(.pageUp); return
        case 121: special(.pageDown); return
        case 117: special(.delete); return
        case 114: special(.insert); return
        case 53: special(.escape); return
        case 48: special(shift ? .backTab : .tab); return
        case 36, 76: special(.enter); return
        case 51: special(.backspace); return
        case 122: special(.function(1)); return
        case 120: special(.function(2)); return
        case 99: special(.function(3)); return
        case 118: special(.function(4)); return
        case 96: special(.function(5)); return
        case 97: special(.function(6)); return
        case 98: special(.function(7)); return
        case 100: special(.function(8)); return
        case 101: special(.function(9)); return
        case 109: special(.function(10)); return
        case 103: special(.function(11)); return
        case 111: special(.function(12)); return
        default: break
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
        interpretKeyEvents([event])
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
            let flipped = NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            guard let window else { return flipped }
            return window.convertToScreen(convert(flipped, to: nil))
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
    func pasteText(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste { send("\u{1b}[200~" + normalized + "\u{1b}[201~") } else { send(normalized) }
    }
    @objc override func selectAll(_ sender: Any?) {
        // Everything with content: the blank rows under the cursor add nothing.
        guard let last = (0..<emulator.lineCount).last(where: { !emulator.text(atLine: $0).isEmpty }) else { selection = nil; needsDisplay = true; return }
        selection = Selection(start: Position(line: emulator.trimmedLines, column: 0), end: Position(line: emulator.trimmedLines + last, column: emulator.columns))
        needsDisplay = true
    }
    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil }
        return item.action == #selector(paste(_:)) || item.action == #selector(selectAll(_:))
    }
    var selectedText: String? {
        guard let selection else { return nil }
        var lines: [String] = []
        for absolute in selection.start.line...selection.end.line {
            let index = absolute - emulator.trimmedLines
            guard index >= 0, index < emulator.lineCount else { continue }
            let cells = emulator.line(at: index)
            let from = absolute == selection.start.line ? selection.start.column : 0
            let to = absolute == selection.end.line ? min(selection.end.column, cells.count) : cells.count
            guard from < to else { lines.append(""); continue }
            var text = cells[from..<to].map(\.text).joined()
            if absolute != selection.end.line || to >= cells.count { while text.last == " " { text.removeLast() } }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
    private func position(at point: NSPoint) -> Position {
        let column = min(max(0, Int((point.x - inset) / cellWidth)), emulator.columns)
        let row = min(max(0, Int((point.y - inset) / cellHeight)), emulator.rows - 1)
        return Position(line: emulator.trimmedLines + firstVisibleLine + row, column: column)
    }
    override func mouseDown(with event: NSEvent) {
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
        guard let anchor = selectionAnchor else { return }
        let current = position(at: convert(event.locationInWindow, from: nil))
        selection = current < anchor ? Selection(start: current, end: anchor) : Selection(start: anchor, end: current)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let selection, selection.start == selection.end { self.selection = nil; needsDisplay = true }
        selectionAnchor = nil
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
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / cellHeight)
            scrollAccumulator -= CGFloat(lines) * cellHeight
        } else {
            lines = Int(event.scrollingDeltaY.rounded(.towardZero)) * 3
        }
        guard lines != 0 else { return }
        if emulator.alternateScreen {
            // Full-screen programs have no scrollback; the wheel moves their cursor instead.
            let key: TerminalKeyEncoder.Key = lines > 0 ? .up : .down
            for _ in 0..<min(abs(lines), 20) { onInput?(TerminalKeyEncoder.encode(key, applicationCursor: emulator.applicationCursorKeys)) }
            return
        }
        let next = min(max(0, scrollOffset + lines), emulator.scrollback.count)
        guard next != scrollOffset else { return }
        scrollOffset = next
        needsDisplay = true
    }
    /// Lines the reader has scrolled back from the newest output.
    var scrolledBackLines: Int { scrollOffset }
    func scrollToBottom() { if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true } }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { emulator.screenText }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
