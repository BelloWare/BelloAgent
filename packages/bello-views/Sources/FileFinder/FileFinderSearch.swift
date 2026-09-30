import Foundation

// Finding a file by part of its name: a query's characters in order,
// anywhere in the path, case aside; the best matches first. Scored as fzf
// scores a path (its v1 algorithm and path scheme: a match at the start of a
// word, after a "/", "_", "-" or ".", or a capital in camel case, is worth
// more, as is one run of characters over scattered ones), and a match within
// the file's name over one that needs its folders. A query ending ":N" asks
// for line N. Spaces in a query are not part of it.

/// What a reader typed, ready to search with.
public struct FileFinderQuery: Sendable, Equatable {
    /// The longest query searched, in characters: more is cut.
    public static let characterLimit = 128
    /// The query as typed, trimmed.
    public let text: String
    /// Line N of a query ending ":N".
    public let line: Int?
    /// The folded query, as runs of bytes, one a character (`FinderFold`):
    /// each must be found whole, in order.
    let units: [[UInt8]]
    let mask: UInt64
    /// Whether the query names folders ("/"), which the file's name alone
    /// cannot match.
    let crossesFolders: Bool

    public init(_ typed: String) {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var line: Int?
        if let colon = text.lastIndex(of: ":"), let number = Int(text[text.index(after: colon)...]), number > 0,
           text[text.index(after: colon)...].allSatisfy(\.isASCII) {
            line = number
            text = String(text[..<colon])
        }
        self.text = text; self.line = line
        var units: [[UInt8]] = [], memo = FinderFold.Memo()
        for character in text where !character.isWhitespace {
            guard units.count < Self.characterLimit else { break }
            var unit: [UInt8] = []
            FinderFold.fold(character, into: &unit, memo: &memo)
            // A mark on its own folds to nothing.
            if !unit.isEmpty { units.append(unit) }
        }
        self.units = units
        mask = units.reduce(0) { $0 | FinderFold.mask($1) }
        crossesFolders = units.contains([0x2F])
    }

    /// Nothing to search for: every file matches.
    public var isEmpty: Bool { units.isEmpty }
}

/// One file a query found: where it is, how well it matched, and where in
/// its path (UTF-8 offsets, `highlights`) the query's characters are.
public struct FileFinderMatch: Sendable, Equatable {
    /// The file's place in the index it was found in.
    public let index: Int
    public let score: Int
    /// The file's path below its root.
    public let path: String
    /// Where the matched characters are, as UTF-8 ranges of `path`.
    public let highlights: [Range<Int>]
}

public enum FileFinderSearch {
    /// How many files a search keeps, best first.
    public static let defaultLimit = 50

    // fzf's scores (algo.go), with its path scheme's bonuses.
    static let scoreMatch = 16, scoreGapStart = -3, scoreGapExtension = -1
    static let bonusBoundary = 8, bonusNonWord = 8, bonusCamel123 = 7, bonusConsecutive = 4, bonusFirstCharMultiplier = 2
    static let bonusBoundaryWhite = 8, bonusBoundaryDelimiter = 9
    /// What a match within the file's name alone is worth over one that
    /// needs its folders: enough that a name match comes first.
    static let nameBonus = 64
    /// A name that is the query, or the query and an extension.
    static let wholeNameBonus = 48

    /// Searches `index` for `query`: at most `limit` files, best first, the
    /// highlights of those only. Runs on the calling thread, across cores
    /// for a large index; stops early once `cancelled` says so.
    public static func search(_ query: FileFinderQuery, in index: FileFinderIndex, limit: Int = defaultLimit,
                              cancelled: @escaping @Sendable () -> Bool = { false }) -> [FileFinderMatch] {
        guard limit > 0, index.count > 0 else { return [] }
        if query.isEmpty { return [] }
        let chunk = 16_384, chunks = (index.count + chunk - 1) / chunk
        let results = ChunkResults(count: chunks)
        let work: @Sendable (Int) -> Void = { part in
            if cancelled() { return }
            var best = TopScores(limit: limit)
            let range = (part * chunk)..<min(index.count, (part + 1) * chunk)
            index.folded.withUnsafeBufferPointer { folded in
                for file in range {
                    if file & 1_023 == 0, cancelled() { return }
                    guard query.mask & ~index.masks[file] == 0 else { continue }
                    let path = index.foldedRange(file)
                    if let found = score(query, folded, path: path, nameStart: Int(index.nameStarts[file]), original: index, file: file) {
                        best.offer(Scored(file: file, score: found.score, length: path.count))
                    }
                }
            }
            results.set(part, best.items)
        }
        if chunks == 1 { work(0) } else { DispatchQueue.concurrentPerform(iterations: chunks, execute: work) }
        if cancelled() { return [] }
        var best = TopScores(limit: limit)
        for part in 0..<chunks { for item in results.get(part) { best.offer(item) } }
        return best.items.map { match(query, $0, in: index) }
    }

    /// Every file in order, when there is nothing typed: at most `limit`.
    public static func first(_ limit: Int, in index: FileFinderIndex) -> [FileFinderMatch] {
        (0..<min(limit, index.count)).map { FileFinderMatch(index: $0, score: 0, path: index.path($0), highlights: []) }
    }

    // MARK: Scoring

    struct Scored: Sendable { let file: Int; let score: Int; let length: Int }

    /// The best that a file of the chunk found, kept to `limit`.
    struct TopScores {
        let limit: Int
        private(set) var items: [Scored] = []
        init(limit: Int) { self.limit = limit; items.reserveCapacity(limit + 1) }
        /// Better: a higher score, then a shorter path, then the one found first.
        static func better(_ a: Scored, _ b: Scored) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.file < b.file
        }
        mutating func offer(_ item: Scored) {
            if items.count == limit, let worst = items.last, !Self.better(item, worst) { return }
            let at = items.firstIndex { Self.better(item, $0) } ?? items.count
            items.insert(item, at: at)
            if items.count > limit { items.removeLast() }
        }
    }

    final class ChunkResults: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [[Scored]]
        init(count: Int) { parts = Array(repeating: [], count: count) }
        func set(_ part: Int, _ items: [Scored]) { lock.lock(); parts[part] = items; lock.unlock() }
        func get(_ part: Int) -> [Scored] { lock.lock(); defer { lock.unlock() }; return parts[part] }
    }

    /// Where a match lies: the file's name alone, or its whole path.
    struct Alignment { let start: Int; let end: Int; let inName: Bool; let score: Int }

    /// The score of `query` against one folded path, or nil when it does not
    /// match: within the file's name if it can, else the whole path.
    static func score(_ query: FileFinderQuery, _ folded: UnsafeBufferPointer<UInt8>, path: Range<Int>, nameStart: Int,
                      original: FileFinderIndex, file: Int) -> Alignment? {
        let units = query.units
        if !query.crossesFolders, let name = window(units, folded, nameStart..<path.upperBound) {
            var score = calculate(units, folded, name, lowerBound: path.lowerBound, original: original, file: file, positions: nil) + nameBonus
            // The whole name, or the name before its extension.
            let length = name.upperBound - name.lowerBound
            if name.lowerBound == nameStart, units.reduce(0, { $0 + $1.count }) == length {
                let rest = path.upperBound - name.upperBound
                if rest == 0 || folded[name.upperBound] == 0x2E { score += wholeNameBonus }
            }
            return Alignment(start: name.lowerBound, end: name.upperBound, inName: true, score: score)
        }
        guard let whole = window(units, folded, path) else { return nil }
        let score = calculate(units, folded, whole, lowerBound: path.lowerBound, original: original, file: file, positions: nil)
        return Alignment(start: whole.lowerBound, end: whole.upperBound, inName: false, score: score)
    }

    /// fzf v1's window: the first place the query's characters are found in
    /// order in `range`, then back from its end to the latest start.
    static func window(_ units: [[UInt8]], _ folded: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Range<Int>? {
        var unit = 0, at = range.lowerBound, end = -1
        while at < range.upperBound {
            if matches(units[unit], folded, at, range.upperBound) {
                at += units[unit].count
                unit += 1
                if unit == units.count { end = at; break }
            } else {
                at += 1
            }
        }
        guard end >= 0 else { return nil }
        // Back from the end: the latest start that still takes every unit.
        unit = units.count - 1
        var back = end - units[unit].count
        var start = back
        while back >= range.lowerBound {
            if matches(units[unit], folded, back, range.upperBound) {
                start = back
                if unit == 0 { break }
                unit -= 1
                back -= units[unit].count
            } else {
                back -= 1
            }
        }
        return start..<end
    }

    @inline(__always) static func matches(_ unit: [UInt8], _ folded: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int) -> Bool {
        guard at >= 0, at + unit.count <= end, folded[at] == unit[0] else { return false }
        var offset = 1
        while offset < unit.count { if folded[at + offset] != unit[offset] { return false }; offset += 1 }
        return true
    }

    enum CharClass: Int { case white = 0, nonWord, delimiter, lower, upper, letter, number }

    /// A character's class, read from the original path where it is ASCII
    /// (so a capital is still one), else from the folded byte.
    @inline(__always) static func charClass(_ byte: UInt8) -> CharClass {
        switch byte {
        case 0x61...0x7A: return .lower
        case 0x41...0x5A: return .upper
        case 0x30...0x39: return .number
        case 0x2F: return .delimiter
        case 0x20, 0x09, 0x0A, 0x0D: return .white
        case 0x80...: return .letter
        default: return .nonWord
        }
    }

    static func bonus(_ previous: CharClass, _ current: CharClass) -> Int {
        if current.rawValue > CharClass.nonWord.rawValue && current != .delimiter {
            switch previous {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if (previous == .lower && current == .upper) || (previous != .number && current == .number) { return bonusCamel123 }
        switch current {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// fzf v1's score of the window `range`, from the path's start
    /// `lowerBound`; with `positions`, the folded offsets matched too.
    static func calculate(_ units: [[UInt8]], _ folded: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, lowerBound: Int,
                          original: FileFinderIndex, file: Int, positions: UnsafeMutablePointer<[Int]>?) -> Int {
        let ascii = original.ascii[file]
        let originalStart = file == 0 ? 0 : Int(original.ends[file - 1])
        func classAt(_ offset: Int) -> CharClass {
            // In an ASCII path the folded offset is the original's.
            if ascii { return charClass(original.bytes[originalStart + offset - lowerBound]) }
            return charClass(folded[offset])
        }
        var unit = 0, score = 0, inGap = false, consecutive = 0, firstBonus = 0
        var previous: CharClass = range.lowerBound > lowerBound ? classAt(range.lowerBound - 1) : .delimiter
        var at = range.lowerBound
        while at < range.upperBound {
            let current = classAt(at)
            if unit < units.count, matches(units[unit], folded, at, range.upperBound) {
                positions?.pointee.append(at)
                score += scoreMatch
                var bonus = bonus(previous, current)
                if consecutive == 0 {
                    firstBonus = bonus
                } else {
                    if bonus >= bonusBoundary, bonus > firstBonus { firstBonus = bonus }
                    bonus = max(max(bonus, firstBonus), bonusConsecutive)
                }
                score += unit == 0 ? bonus * bonusFirstCharMultiplier : bonus
                inGap = false
                consecutive += 1
                let length = units[unit].count
                unit += 1
                previous = current
                // A character of more than one byte is one step.
                if length > 1 { previous = classAt(at + length - 1) }
                at += length
                continue
            }
            score += inGap ? scoreGapExtension : scoreGapStart
            inGap = true
            consecutive = 0
            firstBonus = 0
            previous = current
            // A character of more than one byte is one step of the gap.
            at += sequenceLength(folded[at])
        }
        return score
    }

    /// How many bytes the UTF-8 character starting with `lead` takes: one
    /// for ASCII and for a byte that is not a lead byte.
    @inline(__always) static func sequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }

    /// The match a search keeps: its path, and where in it the query is.
    static func match(_ query: FileFinderQuery, _ scored: Scored, in index: FileFinderIndex) -> FileFinderMatch {
        let file = scored.file
        let path = index.foldedRange(file)
        var offsets: [Int] = []
        index.folded.withUnsafeBufferPointer { folded in
            guard let alignment = score(query, folded, path: path, nameStart: Int(index.nameStarts[file]), original: index, file: file) else { return }
            withUnsafeMutablePointer(to: &offsets) { pointer in
                _ = calculate(query.units, folded, alignment.start..<alignment.end, lowerBound: path.lowerBound,
                              original: index, file: file, positions: pointer)
            }
        }
        // Folded offsets, as UTF-8 ranges of the original path.
        let original = index.pathBytes(file)
        let origins: [Int]? = index.ascii[file] ? nil : FinderFold.origins(original)
        var highlights: [Range<Int>] = []
        var unit = 0
        for offset in offsets {
            let relative = offset - path.lowerBound, length = unit < query.units.count ? query.units[unit].count : 1
            unit += 1
            let range: Range<Int>
            if let origins {
                let start = origins[relative], last = origins[min(relative + length - 1, origins.count - 2)]
                // The whole character the last folded byte came from.
                let end = origins.first { $0 > last } ?? origins[origins.count - 1]
                range = start..<max(end, start + 1)
            } else {
                range = relative..<(relative + length)
            }
            if let previous = highlights.last, previous.upperBound >= range.lowerBound {
                highlights[highlights.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                highlights.append(range)
            }
        }
        return FileFinderMatch(index: file, score: scored.score, path: index.path(file), highlights: highlights)
    }
}
