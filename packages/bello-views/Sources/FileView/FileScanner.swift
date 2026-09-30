import Foundation

// One pass over a file's bytes, a chunk at a time, finding where its lines
// start and how long each is in UTF-16 units: what the viewer needs to place
// any line of a file without reading it (`FileDocument`). The pass runs away
// from the main thread; it keeps nothing of the text itself.
//
// Line endings are "\n", "\r\n" and "\r", one each wherever a chunk ends.
// UTF-8 is checked as it goes: the first byte that cannot be UTF-8 ends the
// pass, and the file is read again as Latin-1, where every byte is one
// character. UTF-16 files are known by their byte order mark.

/// How a file's bytes are text.
public enum FileEncoding: Sendable, Equatable {
    case utf8
    /// Every byte one character: a file that is not valid UTF-8, shown this
    /// way and said to be.
    case latin1
    case utf16LittleEndian
    case utf16BigEndian

    /// Bytes per code unit.
    var unit: Int { self == .utf16LittleEndian || self == .utf16BigEndian ? 2 : 1 }
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .latin1: return .isoLatin1
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        }
    }
}

/// Where a run of lines starts: its first line, that line's first byte in the
/// file, and where it starts in the whole text (lines joined by one "\n").
struct FileCheckpoint: Sendable, Equatable {
    var line: Int
    var byte: Int64
    var utf16: Int64
}

/// A line too long to read whole: places along it, every 16 KiB of bytes,
/// where a character starts, with how far into the line's text each is.
struct FileLongLine: Sendable, Equatable {
    struct Mark: Sendable, Equatable {
        /// From the line's first byte.
        var byte: Int64
        /// From the line's first UTF-16 unit.
        var utf16: Int64
    }
    var line: Int
    var byte: Int64
    /// Its text's length in bytes, without its line ending; so far, while it
    /// is still being read.
    var bytes: Int64
    var marks: [Mark]
}

/// What a pass found since it was last asked.
struct FileIndexDelta: Sendable, Equatable {
    /// The UTF-16 length of each line finished, in order.
    var lengths: [UInt32] = []
    var checkpoints: [FileCheckpoint] = []
    var longLines: [FileLongLine] = []
    /// How much of the line still being read has been read, in UTF-16 units.
    var provisional = 0
    /// The line still being read, if it is already long: what of it can be
    /// read by range so far.
    var provisionalLong: FileLongLine?
    /// A line longer than a UInt32 counts stopped the pass.
    var overflow = false
    /// How far into the file the pass has read.
    var scanned: Int64 = 0
    /// Where the bytes stopped being UTF-8, if they did.
    var invalidAt: Int64?
}

/// The pass itself: fed bytes in order, it finds lines as they end.
struct FileScanner: Sendable {
    /// A run of lines is at most this many lines and this many bytes, so a
    /// page read to show part of it is bounded either way.
    static let checkpointLines = 128
    static let checkpointBytes: Int64 = 256 << 10
    /// A line longer than this is a long line: read by the range asked for,
    /// through its marks, never whole. It is the length past which the view
    /// sets a line piece by piece on its grid (`FileTextMetrics.gridLine`,
    /// in UTF-16 units, never more than there are bytes), so the view never
    /// needs such a line whole, and a screen of lines is never more than
    /// a screen of these.
    static let longLineBytes: Int64 = 64 << 10
    static let markBytes: Int64 = 16 << 10

    let encoding: FileEncoding
    /// The most UTF-16 units a line may have: its length is kept as a UInt32.
    let unitLimit: Int
    private var delta = FileIndexDelta()

    /// Where the next byte is in the file.
    private(set) var position: Int64
    /// Lines begun, the one being read included.
    private(set) var lineCount = 0
    /// Where the line being read starts in the whole text.
    private var lineStartUTF16: Int64 = 0
    private var lineStartByte: Int64
    private var lineUnits = 0
    /// A line is open from its first byte (or the file's end) until its ending.
    private var lineOpen = false
    private var afterCR = false
    private var lastCheckpoint: FileCheckpoint?
    private var previousWasLong = false
    private var marks: [FileLongLine.Mark] = []
    private var nextMark: Int64 = FileScanner.markBytes
    private var madeLong = false
    // UTF-8 checking: continuation bytes still due, and the range the next may take.
    private var due = 0
    private var low: UInt8 = 0x80, high: UInt8 = 0xBF
    // UTF-16: a byte waiting for its pair, and whether the unit before was
    // the first half of a pair.
    private var pendingByte: UInt8?
    private var previousHigh = false
    private(set) var invalid = false
    /// A line too long to count in a UInt32 stopped the pass.
    private(set) var overflow = false
    private(set) var longest = 0

    /// A pass over bytes that start at `start`: after a byte order mark, or 0.
    init(encoding: FileEncoding, start: Int64, unitLimit: Int = Int(UInt32.max)) {
        self.encoding = encoding; self.unitLimit = unitLimit
        position = start; lineStartByte = start
    }

    /// What was found since the last time, handed over and forgotten here.
    mutating func take() -> FileIndexDelta {
        var taken = delta
        taken.provisional = lineOpen ? lineUnits : 0
        taken.scanned = position
        if lineOpen, madeLong {
            taken.provisionalLong = FileLongLine(line: lineCount - 1, byte: lineStartByte, bytes: position - lineStartByte, marks: marks)
        }
        delta = FileIndexDelta()
        if invalid { delta.invalidAt = taken.invalidAt }
        return taken
    }

    // MARK: Lines

    private mutating func beginLine() {
        lineOpen = true
        lineStartByte = position; lineUnits = 0
        marks = []; nextMark = Self.markBytes; madeLong = false; previousHigh = false
        let due: Bool
        if let last = lastCheckpoint {
            due = lineCount - last.line >= Self.checkpointLines || lineStartByte - last.byte >= Self.checkpointBytes || previousWasLong
        } else { due = true }
        if due { checkpoint() }
        lineCount += 1
    }
    /// A run of lines starts at the line being begun.
    private mutating func checkpoint() {
        let point = FileCheckpoint(line: lineCount, byte: lineStartByte, utf16: lineStartUTF16)
        guard lastCheckpoint?.line != point.line else { return }
        delta.checkpoints.append(point); lastCheckpoint = point
    }
    /// Ends the line being read; false when it is too long to keep.
    private mutating func endLine(terminatorBytes: Int64) -> Bool {
        if lineUnits > unitLimit { overflow = true; fail(); return false }
        if !lineOpen { beginLine() }
        let length = Int64(position) - lineStartByte
        if madeLong || length > Self.longLineBytes {
            delta.longLines.append(FileLongLine(line: lineCount - 1, byte: lineStartByte, bytes: length, marks: marks))
            previousWasLong = true
        } else { previousWasLong = false }
        delta.lengths.append(UInt32(clamping: lineUnits))
        longest = max(longest, lineUnits)
        lineStartUTF16 += Int64(lineUnits) + 1
        lineOpen = false
        position += terminatorBytes
        return true
    }
    /// Past the long-line length, a line is long from its start: it becomes a
    /// run of its own, so no page read of the lines before it reads it too.
    /// False when the line is too long to keep.
    private mutating func noteLength() -> Bool {
        if lineUnits > unitLimit { overflow = true; fail(); return false }
        let length = position - lineStartByte
        if !madeLong, length > Self.longLineBytes {
            madeLong = true
            if let last = lastCheckpoint, last.line != lineCount - 1 {
                let point = FileCheckpoint(line: lineCount - 1, byte: lineStartByte, utf16: lineStartUTF16)
                delta.checkpoints.append(point); lastCheckpoint = point
            }
        }
        return true
    }
    /// Every 16 KiB of a line, where a character starts.
    private mutating func mark() {
        marks.append(FileLongLine.Mark(byte: position - lineStartByte, utf16: Int64(lineUnits)))
        nextMark = (position - lineStartByte) + Self.markBytes
    }

    // MARK: Bytes

    /// Reads the next bytes of the file.
    mutating func feed(_ bytes: UnsafeRawBufferPointer) {
        guard !invalid else { return }
        switch encoding {
        case .utf8, .latin1: feedBytes(bytes)
        case .utf16LittleEndian, .utf16BigEndian: feedUnits(bytes)
        }
    }

    private mutating func feedBytes(_ bytes: UnsafeRawBufferPointer) {
        let count = bytes.count
        var index = 0
        let latin1 = encoding == .latin1
        while index < count {
            let byte = bytes[index]
            if afterCR {
                afterCR = false
                if byte == 0x0A { position += 1; index += 1; continue }
            }
            if !lineOpen { beginLine() }
            if byte == 0x0A || byte == 0x0D {
                if due > 0 { fail(); return }
                guard endLine(terminatorBytes: 1) else { return }
                if byte == 0x0D { afterCR = true }
                index += 1
                continue
            }
            // Eight plain ASCII characters at once, with no line ending among
            // them and no mark due within them.
            if due == 0, index + 8 <= count, position - lineStartByte + 8 < nextMark {
                let word = bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                if word & 0x8080_8080_8080_8080 == 0, !Self.holds(word, 0x0A), !Self.holds(word, 0x0D) {
                    lineUnits += 8; position += 8; index += 8
                    continue
                }
            }
            if position - lineStartByte >= nextMark, due == 0 { mark() }
            if latin1 {
                lineUnits += 1
            } else if due == 0 {
                switch byte {
                case 0x00...0x7F: lineUnits += 1
                case 0xC2...0xDF: due = 1; low = 0x80; high = 0xBF; lineUnits += 1
                case 0xE0: due = 2; low = 0xA0; high = 0xBF; lineUnits += 1
                case 0xE1...0xEC, 0xEE, 0xEF: due = 2; low = 0x80; high = 0xBF; lineUnits += 1
                case 0xED: due = 2; low = 0x80; high = 0x9F; lineUnits += 1
                case 0xF0: due = 3; low = 0x90; high = 0xBF; lineUnits += 2
                case 0xF1...0xF3: due = 3; low = 0x80; high = 0xBF; lineUnits += 2
                case 0xF4: due = 3; low = 0x80; high = 0x8F; lineUnits += 2
                default: fail(); return
                }
            } else {
                guard byte >= low, byte <= high else { fail(); return }
                due -= 1; low = 0x80; high = 0xBF
            }
            position += 1; index += 1
            guard noteLength() else { return }
        }
    }
    /// Whether any byte of a word is `byte`.
    static func holds(_ word: UInt64, _ byte: UInt8) -> Bool {
        let x = word ^ (0x0101_0101_0101_0101 &* UInt64(byte))
        return (x &- 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080 != 0
    }

    private mutating func feedUnits(_ bytes: UnsafeRawBufferPointer) {
        var index = 0
        let count = bytes.count
        let little = encoding == .utf16LittleEndian
        while index < count {
            let first: UInt8, second: UInt8
            if let pending = pendingByte {
                first = pending; second = bytes[index]; pendingByte = nil
                index += 1
                position -= 1 // the waiting byte was counted when it came
            } else if index + 1 < count {
                first = bytes[index]; second = bytes[index + 1]; index += 2
            } else {
                pendingByte = bytes[index]; position += 1; index += 1
                continue
            }
            let unit = little ? UInt16(first) | UInt16(second) << 8 : UInt16(first) << 8 | UInt16(second)
            if afterCR {
                afterCR = false
                if unit == 0x0A { position += 2; continue }
            }
            if !lineOpen { beginLine() }
            if unit == 0x0A || unit == 0x0D {
                guard endLine(terminatorBytes: 2) else { return }
                if unit == 0x0D { afterCR = true }
                continue
            }
            // A mark where a character starts: not between the halves of a
            // pair (a low surrogate on its own is a character of its own).
            if position - lineStartByte >= nextMark, !(previousHigh && (0xDC00...0xDFFF).contains(unit)) { mark() }
            previousHigh = (0xD800...0xDBFF).contains(unit)
            lineUnits += 1; position += 2
            guard noteLength() else { return }
        }
    }

    private mutating func fail() {
        invalid = true
        delta.invalidAt = position
        delta.overflow = overflow
    }

    /// The file's end: the last line, empty after a final line ending.
    mutating func finish() {
        guard !invalid else { return }
        if due > 0 { fail(); return }
        if pendingByte != nil {
            // A lone byte at the end of a UTF-16 file: one replacement
            // character, on a line that starts at it (the byte was counted
            // when it came).
            position -= 1
            if !lineOpen { beginLine() }
            lineUnits += 1; pendingByte = nil
            position += 1
        }
        if !lineOpen { beginLine() }
        _ = endLine(terminatorBytes: 0)
    }
}
