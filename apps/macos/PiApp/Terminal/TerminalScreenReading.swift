import Foundation

// What a drawer, an accessibility client or a test reads out of the grid.
// None of it changes the emulator; every one of these is a pure view of the
// cells the parser has already written.

extension TerminalEmulator {
    /// Every line the reader can see, oldest first: the scrollback then the screen.
    var lineCount: Int { scrollback.count + rows }
    func line(at index: Int) -> [TerminalCell] {
        if index < scrollback.count { return scrollback[index].cells }
        let row = index - scrollback.count
        return row < rows ? screen[row] : []
    }
    /// The text of one line without building its cells, for readers that only
    /// want to know whether a line has anything on it.
    func text(atLine index: Int) -> String {
        guard index < scrollback.count else {
            let row = index - scrollback.count
            return row < rows ? text(ofRow: row) : ""
        }
        var text = scrollback[index].text
        while text.last == " " { text.removeLast() }
        return text
    }
    /// The text of one screen row without trailing blanks.
    func text(ofRow row: Int) -> String { Self.text(of: screen[row]) }
    static func text(of cells: [TerminalCell]) -> String {
        var end = cells.count
        while end > 0, cells[end - 1].isBlank || cells[end - 1].width == 0 && cells[end - 1].text.isEmpty && end == cells.count { end -= 1 }
        return cells[..<end].map(\.text).joined()
    }
    /// The whole screen as text, rows joined by newlines, for accessibility and tests.
    var screenText: String { (0..<rows).map { text(ofRow: $0) }.joined(separator: "\n") }
}
