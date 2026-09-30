import Foundation

// The lines a file viewer shows (`FileTextView`), read by index as they come
// into view. A file of any size is read this way: the view never holds more
// than the lines on screen, and nothing asks for the whole text at once.
//
// Positions are counted as AppKit counts text, in UTF-16 units, over the
// file's lines joined by one "\n" whatever the file's own line endings. That
// is the text a selection copies and the text accessibility reads, so a
// position means the same thing to the reader, the pasteboard and VoiceOver.

/// The text of a file, a line at a time, and a part of a line at a time: a
/// line of a hundred megabytes is read only where it is on screen.
@MainActor protocol FileTextSource: AnyObject {
    /// At least 1: an empty file is one empty line.
    var lineCount: Int { get }
    /// A line's length in UTF-16 units, without its line ending.
    func utf16Length(ofLine index: Int) -> Int
    /// Part of a line, `range` in UTF-16 units clamped to the line.
    func text(ofLine index: Int, range: Range<Int>) -> String
    /// Where a line starts in the whole text: the lines before it, each with
    /// its "\n".
    func utf16Start(ofLine index: Int) -> Int
    /// The line an offset in the whole text falls in. An offset on a line's
    /// "\n" is in that line; the end of the text is in the last line.
    func line(atUTF16 offset: Int) -> Int
    /// The whole text's length: every line and a "\n" between each two.
    var utf16Length: Int { get }
    /// The longest line's length, in UTF-16 units: how wide the view may
    /// need to be before any long line has been measured.
    var longestLine: Int { get }
    /// Changes whenever the text does: what was set or measured of the text
    /// before is not used after.
    var generation: Int { get }
}

extension FileTextSource {
    /// A whole line. For a line of any length, read a part (`text(ofLine:range:)`).
    func line(_ index: Int) -> String { text(ofLine: index, range: 0..<utf16Length(ofLine: index)) }
    /// The text from one position to another, the lines between joined by
    /// "\n": what a selection copies and what accessibility reads.
    func text(from start: FileTextPosition, to end: FileTextPosition) -> String {
        guard start < end else { return "" }
        var parts: [String] = []
        for index in start.line...min(end.line, lineCount - 1) {
            let length = utf16Length(ofLine: index)
            let from = index == start.line ? min(start.column, length) : 0
            let to = index == end.line ? min(end.column, length) : length
            parts.append(text(ofLine: index, range: from..<max(from, to)))
        }
        return parts.joined(separator: "\n")
    }
    /// The position of an offset in the whole text, clamped to it.
    func position(atUTF16 offset: Int) -> FileTextPosition {
        let clamped = max(0, min(offset, utf16Length))
        let line = line(atUTF16: clamped)
        return FileTextPosition(line: line, column: min(clamped - utf16Start(ofLine: line), utf16Length(ofLine: line)))
    }
    /// A position's offset in the whole text.
    func utf16Offset(of position: FileTextPosition) -> Int {
        let line = max(0, min(position.line, lineCount - 1))
        return utf16Start(ofLine: line) + max(0, min(position.column, utf16Length(ofLine: line)))
    }
}

/// A place in a file's text: a line, and a UTF-16 offset into it.
struct FileTextPosition: Comparable, Hashable, Sendable {
    var line: Int
    var column: Int
    static func < (a: Self, b: Self) -> Bool { a.line != b.line ? a.line < b.line : a.column < b.column }
    static let start = FileTextPosition(line: 0, column: 0)
}

/// A text held whole, split into its lines: a small file, or a test's.
@MainActor final class FileTextLines: FileTextSource {
    private let lines: [String]
    /// Where each line starts in the whole text, and the text's end.
    private let starts: [Int]
    let longestLine: Int

    init(_ text: String) {
        var lines: [String] = []
        // "\r\n", "\n" and "\r" each end a line; a text that ends with one
        // has an empty last line, as an editor shows it. Both are ASCII, so
        // the text's UTF-8 is searched and cut where they are.
        let utf8 = text.utf8
        var start = utf8.startIndex, index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            guard byte == 0x0A || byte == 0x0D else { index = utf8.index(after: index); continue }
            lines.append(String(text[start..<index]))
            var next = utf8.index(after: index)
            if byte == 0x0D, next < utf8.endIndex, utf8[next] == 0x0A { next = utf8.index(after: next) }
            index = next; start = next
        }
        lines.append(String(text[start..<utf8.endIndex]))
        self.lines = lines
        var starts: [Int] = [], offset = 0, longest = 0
        starts.reserveCapacity(lines.count + 1)
        for line in lines {
            starts.append(offset)
            let length = line.utf16.count
            longest = max(longest, length)
            offset += length + 1
        }
        starts.append(offset - 1)
        self.starts = starts
        longestLine = longest
    }

    var lineCount: Int { lines.count }
    let generation = 0
    func utf16Length(ofLine index: Int) -> Int {
        guard lines.indices.contains(index) else { return 0 }
        return starts[index + 1] - starts[index] - (index + 1 < lines.count ? 1 : 0)
    }
    func text(ofLine index: Int, range: Range<Int>) -> String {
        guard lines.indices.contains(index) else { return "" }
        let line = lines[index] as NSString
        let low = max(0, min(range.lowerBound, line.length)), high = max(low, min(range.upperBound, line.length))
        return low == 0 && high == line.length ? lines[index] : line.substring(with: NSRange(location: low, length: high - low))
    }
    func utf16Start(ofLine index: Int) -> Int { starts[max(0, min(index, lines.count - 1))] }
    var utf16Length: Int { starts[lines.count] }
    func line(atUTF16 offset: Int) -> Int {
        // The last line whose start is at or before the offset.
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
