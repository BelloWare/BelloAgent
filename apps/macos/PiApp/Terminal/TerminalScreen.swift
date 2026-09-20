import Foundation

// The cell grid a terminal emulator writes into: one cell per column, the
// style it carries, and the history line it becomes when it scrolls off.

struct TerminalColor: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable { case standard, indexed(UInt8), rgb(UInt8, UInt8, UInt8) }
    var kind: Kind
    static let standard = TerminalColor(kind: .standard)
    static func indexed(_ index: UInt8) -> TerminalColor { TerminalColor(kind: .indexed(index)) }
    static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> TerminalColor { TerminalColor(kind: .rgb(red, green, blue)) }
}

struct CellStyle: Equatable, Hashable, Sendable {
    var foreground = TerminalColor.standard
    var background = TerminalColor.standard
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    var strikethrough = false
    var hidden = false
    static let plain = CellStyle()
}

struct TerminalCell: Equatable, Sendable {
    /// One grapheme: a base scalar with any combining marks. Empty for the trailing half of a wide character.
    var text: String = " "
    /// 1 for a normal cell, 2 for the leading half of a wide character, 0 for the trailing half.
    var width: UInt8 = 1
    var style = CellStyle.plain
    var combiningTruncated = false
    static let blank = TerminalCell()
    var isBlank: Bool { width == 1 && text == " " }
}

/// One line that has left the screen, kept as its characters and the runs of
/// style over them rather than as one `TerminalCell` per column. A cell costs
/// 32 bytes, nearly all of it a `String` holding a single character, so ten
/// thousand lines of history cost tens of megabytes per terminal and there is
/// one terminal per project. The line decodes back to cells on demand, which
/// only happens for the rows a reader who has scrolled back can see.
struct TerminalHistoryLine: Sendable {
    struct StyleRun: Sendable { var length: Int32; var style: CellStyle }
    /// One character per cell that starts one; the trailing half of a wide
    /// character carries no text and none is stored for it.
    let text: String
    /// Styles over the cells, the trailing halves included.
    let styles: [StyleRun]
    /// Cells the line occupies, a wide character counting twice.
    let cellCount: Int
    /// The text of each cell, kept only when joining the cells' characters
    /// would merge two of them into one grapheme — a flag, or an emoji joined
    /// with a zero-width joiner. Nil for every ordinary line.
    let exact: [String]?
    var retainedBytes: Int { text.utf8.count + styles.count * MemoryLayout<StyleRun>.stride + (exact?.reduce(0) { $0 + $1.utf8.count + MemoryLayout<String>.stride } ?? 0) + 128 }

    init(_ cells: ArraySlice<TerminalCell>) {
        // The text is built as bytes and decoded once: appending a hundred
        // short strings costs far more than one pass over their UTF-8.
        var utf8: [UInt8] = [], runs: [StyleRun] = [], count = 0, written = 0
        utf8.reserveCapacity(cells.count + 16)
        var suspicious = false, previousJoins = false
        // The run being gathered is kept in locals: reaching back into the
        // array for every cell costs a third again as much.
        var runStyle = CellStyle.plain, runLength: Int32 = 0
        for cell in cells {
            if cell.width != 0 {
                let bytes = cell.text.utf8
                if let single = bytes.count == 1 ? bytes.first : nil {
                    // Plain ASCII, which is nearly every cell: one byte can
                    // neither carry a joiner nor extend the grapheme before it.
                    utf8.append(single); previousJoins = false
                } else {
                    let scalars = cell.text.unicodeScalars
                    if written > 0, previousJoins || scalars.first.map(Self.joinsPrevious) == true { suspicious = true }
                    if scalars.count > 1 { suspicious = true }
                    previousJoins = scalars.last.map { $0.value == 0x200d || (0xfe00...0xfe0f).contains($0.value) } ?? false
                    utf8.append(contentsOf: bytes)
                }
                written += 1
            }
            count += 1
            if runLength > 0, runStyle == cell.style, runLength < Int32.max { runLength += 1 }
            else {
                if runLength > 0 { runs.append(StyleRun(length: runLength, style: runStyle)) }
                runStyle = cell.style; runLength = 1
            }
        }
        if runLength > 0 { runs.append(StyleRun(length: runLength, style: runStyle)) }
        let text = String(decoding: utf8, as: UTF8.self)
        self.text = text; self.styles = runs; self.cellCount = count
        // One character per cell is what reading the text back assumes. Only a
        // line that could have run two cells' characters together is counted,
        // and only such a line keeps its pieces.
        if suspicious, text.count != written { self.exact = cells.filter { $0.width != 0 }.map(\.text) } else { self.exact = nil }
    }
    /// Scalars that join the grapheme before them across a cell boundary: the
    /// two halves of a flag, and conjoining Hangul.
    private static func joinsPrevious(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1f1e6...0x1f1ff).contains(value) || (0x1160...0x11ff).contains(value)
    }

    /// The line as the screen held it. Widths come back from the characters
    /// themselves, which is where they came from when the line was printed.
    var cells: [TerminalCell] {
        var result: [TerminalCell] = []
        result.reserveCapacity(cellCount)
        var runIndex = 0, used: Int32 = 0
        func nextStyle() -> CellStyle {
            while runIndex < styles.count, used >= styles[runIndex].length { runIndex += 1; used = 0 }
            guard runIndex < styles.count else { return .plain }
            used += 1
            return styles[runIndex].style
        }
        func append(_ piece: String) {
            guard result.count < cellCount else { return }
            let width = piece.unicodeScalars.first.map { max(1, TerminalEmulator.width(of: $0)) } ?? 1
            result.append(TerminalCell(text: piece, width: UInt8(width), style: nextStyle()))
            if width == 2, result.count < cellCount { result.append(TerminalCell(text: "", width: 0, style: nextStyle())) }
        }
        if let exact { for piece in exact { append(piece) } }
        else { for character in text { append(String(character)) } }
        while result.count < cellCount { result.append(TerminalCell(text: " ", width: 1, style: nextStyle())) }
        return result
    }
}

struct TerminalCursor: Equatable, Sendable {
    var x = 0
    var y = 0
}

/// The cursor shape a program asked for through DECSCUSR.
enum TerminalCursorShape: Equatable, Sendable { case block, underline, bar }
