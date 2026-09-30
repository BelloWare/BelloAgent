import Foundation

// What a search in a file matches (`FileSearch`, and the bands the view
// draws behind matches): the query's text, literally, within one line, with
// or without matching case. Positions are UTF-16 units, as everywhere in the
// viewer.
//
// Without matching case, each character is folded to one character of the
// same UTF-16 length (the simple folding), so a match is always exactly as
// long as the query: "ß" does not match "SS", while the Kelvin sign matches
// "k". Matches are found leftmost first, each sought again from where the
// one before ended, from the start of the line: that is the one definition
// the count, the navigation and the bands all keep to.

public struct FileMatcher: Sendable, Equatable {
    /// The longest query searched, in characters, as the conversation
    /// search has it, and in UTF-16 units, which bounds the work around
    /// every place a line is cut however many marks a character carries.
    public static let characterLimit = 256
    public static let unitLimit = 1_024

    public let query: String
    public let matchCase: Bool
    /// The query's UTF-16 units, folded unless matching case.
    let units: [UInt16]
    /// Whether two matches could overlap, were they all taken: a proper
    /// prefix of the (folded) query is also its suffix, as in "aba" or "Aa".
    /// Then where matching resumes depends on the matches before, and a line
    /// can only be matched from its start; otherwise every occurrence is a
    /// match, and any stretch of a line can be matched alone.
    let overlaps: Bool

    public init(query: String, matchCase: Bool) {
        self.query = query; self.matchCase = matchCase
        // Too long, nothing more is done with it: a pasted page is neither
        // copied, folded nor looked through for overlaps.
        isTooLong = query.utf16.count > Self.unitLimit || query.count > Self.characterLimit
        var units = isTooLong ? [] : Array(query.utf16)
        if !matchCase { units.withUnsafeMutableBufferPointer { Self.fold($0) } }
        self.units = units
        overlaps = Self.hasBorder(units)
        matchesNothing = isTooLong || units.isEmpty || units.contains(0x0A) || units.contains(0x0D)
    }

    /// Longer than a query may be: nothing is searched.
    public let isTooLong: Bool
    /// Nothing can match: an empty query, one too long, or one holding a
    /// line ending (a match never spans lines).
    public let matchesNothing: Bool
    /// A match's length, in UTF-16 units.
    public var length: Int { units.count }

    // MARK: Matching

    /// The matches in a line's text, leftmost first, each sought from where
    /// the one before ended: UTF-16 ranges.
    public func matches(in line: String) -> [Range<Int>] {
        var text = Array(line.utf16)
        var found: [Range<Int>] = []
        text.withUnsafeMutableBufferPointer { buffer in
            prepare(buffer)
            scan(UnsafeBufferPointer(buffer), from: 0) { found.append($0..<($0 + units.count)); return true }
        }
        return found
    }

    /// Makes a run of units ready to be matched, in place: folded unless
    /// matching case.
    func prepare(_ text: UnsafeMutableBufferPointer<UInt16>) {
        if !matchCase { Self.fold(text) }
    }

    /// Matches in a prepared run of a line's units: each match's start,
    /// leftmost first, the first sought from `from`, the next from where one
    /// ends, every match ending within the run; `found` returns false to
    /// stop. Returns where matching resumes after the last match found (or
    /// `from`, if none was).
    @discardableResult
    func scan(_ text: UnsafeBufferPointer<UInt16>, from: Int, found: (Int) -> Bool) -> Int {
        guard !matchesNothing, let base = text.baseAddress else { return from }
        return units.withUnsafeBufferPointer { pattern in
            let count = text.count, length = pattern.count, first = pattern[0]
            var at = max(0, from), resume = at
            while at + length <= count {
                // The next place the query's first unit is.
                var candidate = at
                let last = count - length
                while candidate <= last, base[candidate] != first { candidate += 1 }
                guard candidate <= last else { break }
                if length == 1 || memcmp(base + candidate + 1, pattern.baseAddress! + 1, (length - 1) * 2) == 0 {
                    resume = candidate + length
                    guard found(candidate) else { return resume }
                    at = resume
                } else {
                    at = candidate + 1
                }
            }
            return resume
        }
    }

    /// Whether a proper prefix of these units is also their suffix.
    static func hasBorder(_ units: [UInt16]) -> Bool {
        guard units.count > 1 else { return false }
        // The prefix function's last value: the longest proper border.
        var border = [Int](repeating: 0, count: units.count)
        var length = 0
        for index in 1..<units.count {
            while length > 0, units[index] != units[length] { length = border[length - 1] }
            if units[index] == units[length] { length += 1 }
            border[index] = length
        }
        return border[units.count - 1] > 0
    }

    // MARK: Folding

    /// Folds units in place, a character at a time, each to a character of
    /// the same UTF-16 length: ASCII by table, the rest by Foundation's
    /// folding of that one character when it is one character as long, else
    /// left as it is. A surrogate on its own is left as it is.
    static func fold(_ text: UnsafeMutableBufferPointer<UInt16>) {
        let table = Self.table
        var index = 0
        let count = text.count
        while index < count {
            let unit = text[index]
            if unit < 0x80 {
                if unit >= 0x41, unit <= 0x5A { text[index] = unit | 0x20 }
                index += 1
            } else if unit & 0xFC00 == 0xD800, index + 1 < count, text[index + 1] & 0xFC00 == 0xDC00 {
                let scalar = 0x10000 + (UInt32(unit & 0x3FF) << 10 | UInt32(text[index + 1] & 0x3FF))
                if let folded = table.supplementary[scalar] {
                    text[index] = UInt16(0xD800 + ((folded - 0x10000) >> 10))
                    text[index + 1] = UInt16(0xDC00 + ((folded - 0x10000) & 0x3FF))
                }
                index += 2
            } else {
                text[index] = table.basic[Int(unit)]
                index += 1
            }
        }
    }

    /// The folding of every character that has one of its own length: built
    /// once, from the characters that change with case (a few thousand).
    private struct Table: Sendable {
        var basic: [UInt16]
        var supplementary: [UInt32: UInt32]
    }
    private static let table: Table = {
        var basic = (0..<65_536).map { UInt16($0) }
        var supplementary: [UInt32: UInt32] = [:]
        // No character past the first two planes has case.
        for value in UInt32(0x80)..<UInt32(0x20000) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            guard properties.changesWhenCaseFolded || properties.changesWhenCaseMapped else { continue }
            let folded = String(scalar).folding(options: .caseInsensitive, locale: nil).unicodeScalars
            guard folded.count == 1, let to = folded.first, to.value != value, (to.value > 0xFFFF) == (value > 0xFFFF) else { continue }
            if value <= 0xFFFF { basic[Int(value)] = UInt16(to.value) } else { supplementary[value] = to.value }
        }
        return Table(basic: basic, supplementary: supplementary)
    }()
}
