import Foundation

// A project's files as a finder searches them, made once a listing is done
// and never changed: every path, one after another, as it is and folded to
// lower case, with where each one's name starts and a mask of the letters
// in it, so a query rejects most paths without reading them.

/// Folding for finding: case aside, and one character however it is
/// spelled (an "é" of two scalars as the "é" of one: composed, lower-cased,
/// composed); each character on its own, so a folded byte always comes from
/// one character of the original (`FileFinderSearch` maps a match back
/// through it). ASCII folds in place.
enum FinderFold {
    /// Characters of one scalar folded before, by it: most of a project's
    /// are met again and again.
    typealias Memo = [Unicode.Scalar: [UInt8]]

    static func fold(_ bytes: some Collection<UInt8>, memo: inout Memo) -> (folded: [UInt8], ascii: Bool) {
        if bytes.allSatisfy({ $0 < 0x80 }) { return (bytes.map(lower), true) }
        var folded: [UInt8] = []
        folded.reserveCapacity(bytes.count)
        for character in String(decoding: bytes, as: UTF8.self) { fold(character, into: &folded, memo: &memo) }
        return (folded, false)
    }
    /// For a path that is not ASCII: the original UTF-8 offset each folded
    /// byte comes from (the start of its character), and one past the end.
    static func origins(_ bytes: some Collection<UInt8>) -> [Int] {
        var origins: [Int] = [], offset = 0, folded: [UInt8] = [], memo = Memo()
        for character in String(decoding: bytes, as: UTF8.self) {
            folded.removeAll(keepingCapacity: true)
            fold(character, into: &folded, memo: &memo)
            origins.append(contentsOf: repeatElement(offset, count: folded.count))
            offset += character.utf8.count
        }
        origins.append(offset)
        return origins
    }
    /// One character, folded, after `folded`.
    static func fold(_ character: Character, into folded: inout [UInt8], memo: inout Memo) {
        if character.utf8.count == 1, let byte = character.utf8.first { folded.append(lower(byte)); return }
        let scalars = character.unicodeScalars
        let single = scalars.first.flatMap { scalars.index(after: scalars.startIndex) == scalars.endIndex ? $0 : nil }
        if let single, let known = memo[single] { folded.append(contentsOf: known); return }
        let made = Array(String(character).precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping.utf8)
        if let single { memo[single] = made }
        folded.append(contentsOf: made)
    }
    @inline(__always) static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
    /// The letters and digits in a folded path, one bit each; bit 63 for any
    /// byte that is not ASCII.
    static func mask(_ folded: some Collection<UInt8>) -> UInt64 {
        var mask: UInt64 = 0
        for byte in folded { mask |= bit(byte) }
        return mask
    }
    @inline(__always) static func bit(_ byte: UInt8) -> UInt64 {
        switch byte {
        case 0x61...0x7A: return 1 << UInt64(byte - 0x61)          // a-z: bits 0-25
        case 0x30...0x39: return 1 << UInt64(26 + byte - 0x30)     // 0-9: bits 26-35
        case 0x2E: return 1 << 36                                   // "."
        case 0x5F: return 1 << 37                                   // "_"
        case 0x2D: return 1 << 38                                   // "-"
        case 0x2F: return 1 << 39                                   // "/"
        case 0x20: return 1 << 40                                   // " "
        case 0x80...: return 1 << 63
        default: return 1 << 62
        }
    }
}

/// A project's files, as found: search it with `FileFinderSearch`.
public final class FileFinderIndex: Sendable {
    /// The folders the files were found in; each file says which.
    public let roots: [String]
    /// Every path below its root, one after another.
    let bytes: [UInt8]
    let ends: [UInt32]
    /// The same, folded (`FinderFold`), with their own ends.
    let folded: [UInt8]
    let foldedEnds: [UInt32]
    /// Where each folded path's name starts, after its last "/".
    let nameStarts: [UInt32]
    let masks: [UInt64]
    /// Which root each path is in.
    let rootIndexes: [UInt16]
    /// Whether each path is ASCII: folded in place, byte for byte.
    let ascii: [Bool]
    /// The listing stopped at a limit: these are not all the files.
    public let truncated: Bool
    /// What the listing left out or could not apply, for the reader.
    public let warnings: [String]
    /// When the listing that made this ended.
    public let madeAt: Date

    public var count: Int { ends.count }

    /// Throws when its task is cancelled meanwhile.
    init(roots: [String], listings: [FolderListing], truncated: Bool, madeAt: Date = Date()) throws {
        self.roots = roots
        var bytes: [UInt8] = [], ends: [UInt32] = [], folded: [UInt8] = [], foldedEnds: [UInt32] = []
        var nameStarts: [UInt32] = [], masks: [UInt64] = [], rootIndexes: [UInt16] = [], ascii: [Bool] = []
        let total = listings.reduce(0) { $0 + $1.count }, totalBytes = listings.reduce(0) { $0 + $1.bytes.count }
        bytes.reserveCapacity(totalBytes); folded.reserveCapacity(totalBytes)
        ends.reserveCapacity(total); foldedEnds.reserveCapacity(total); nameStarts.reserveCapacity(total)
        masks.reserveCapacity(total); rootIndexes.reserveCapacity(total); ascii.reserveCapacity(total)
        var memo = FinderFold.Memo()
        for (root, listing) in listings.enumerated() {
            for index in 0..<listing.count {
                if index & 4_095 == 4_095 { try Task.checkCancellation() }
                let path = listing.path(index)
                bytes.append(contentsOf: path); ends.append(UInt32(bytes.count))
                let (fold, isASCII) = FinderFold.fold(path, memo: &memo)
                let start = folded.count
                folded.append(contentsOf: fold); foldedEnds.append(UInt32(folded.count))
                let name = fold.lastIndex(of: 0x2F).map { $0 + 1 } ?? 0
                nameStarts.append(UInt32(start + name))
                masks.append(FinderFold.mask(fold))
                rootIndexes.append(UInt16(root)); ascii.append(isASCII)
            }
        }
        self.bytes = bytes; self.ends = ends; self.folded = folded; self.foldedEnds = foldedEnds
        self.nameStarts = nameStarts; self.masks = masks; self.rootIndexes = rootIndexes; self.ascii = ascii
        self.truncated = truncated; self.madeAt = madeAt
        var warnings: [String] = []
        for listing in listings { for warning in listing.warnings where !warnings.contains(warning) { warnings.append(warning) } }
        self.warnings = warnings
    }

    /// The path below its root of file `index`.
    public func path(_ index: Int) -> String { String(decoding: pathBytes(index), as: UTF8.self) }
    func pathBytes(_ index: Int) -> ArraySlice<UInt8> { bytes[Int(index == 0 ? 0 : ends[index - 1])..<Int(ends[index])] }
    func foldedRange(_ index: Int) -> Range<Int> { Int(index == 0 ? 0 : foldedEnds[index - 1])..<Int(foldedEnds[index]) }
    /// The root file `index` is in.
    public func root(_ index: Int) -> String { roots[Int(rootIndexes[index])] }
    /// Where file `index` is.
    public func url(_ index: Int) -> URL {
        URL(fileURLWithPath: root(index)).appendingPathComponent(path(index))
    }
}
