import Foundation

// What a folder outside any repository ignores, as git would if it were one:
// the `.gitignore` files in it and the user's global ignore file, read as
// gitignore(5) reads them and matched as git's wildmatch matches (a port of
// git's dir.c and wildmatch.c, byte for byte, case sensitive). A repository's
// files are listed by git itself (`FileListing`); this is only for the rest.

/// One line of an ignore file.
struct IgnorePattern: Sendable, Equatable {
    /// The pattern's bytes, without its "!" or its trailing "/".
    let bytes: [UInt8]
    /// "!": a match re-includes.
    let negated: Bool
    /// A trailing "/": only a directory matches.
    let directoryOnly: Bool
    /// No "/" but a trailing one: matched against the name alone, at any
    /// depth below the file's folder. Otherwise against the path below it.
    let basenameOnly: Bool

    /// A line of an ignore file, or nil for one that is not a pattern (blank,
    /// a comment). Trailing spaces are dropped unless escaped.
    init?(line: [UInt8]) {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty, line[0] != 0x23 else { return nil }  // "#"
        line = Self.trimmingTrailingSpaces(line)
        var negated = false, start = 0
        if line.first == 0x21 { negated = true; start = 1 }  // "!"
        var end = line.count, directoryOnly = false
        if end > start, line[end - 1] == 0x2F { end -= 1; directoryOnly = true }  // "/"
        let bytes = Array(line[start..<end])
        self.bytes = bytes; self.negated = negated; self.directoryOnly = directoryOnly
        basenameOnly = !bytes.contains(0x2F)
    }

    /// gitignore(5): trailing spaces go unless quoted with a backslash.
    static func trimmingTrailingSpaces(_ line: [UInt8]) -> [UInt8] {
        var lastSpace: Int?, index = 0
        while index < line.count {
            switch line[index] {
            case 0x20:
                if lastSpace == nil { lastSpace = index }
            case 0x5C:  // "\": the next byte is kept whatever it is
                index += 1
                if index >= line.count { return line }
                lastSpace = nil
            default:
                lastSpace = nil
            }
            index += 1
        }
        return lastSpace.map { Array(line[..<$0]) } ?? line
    }

    /// Whether this pattern matches `path` (relative to the walk's root, no
    /// leading "/"), whose last component starts at `nameStart`, for a file
    /// in the folder `base` ("" for the root, else ending in "/").
    func matches(_ path: [UInt8], nameStart: Int, isDirectory: Bool, base: [UInt8]) -> Bool {
        if directoryOnly, !isDirectory { return false }
        if basenameOnly {
            return Wildmatch.match(bytes[...], path[nameStart...], pathname: false)
        }
        // Relative to the file's folder: the path must be below it.
        guard path.count > base.count, path.starts(with: base) else { return false }
        var pattern = bytes[...]
        if pattern.first == 0x2F { pattern = pattern.dropFirst() }
        return Wildmatch.match(pattern, path[base.count...], pathname: true)
    }
}

/// An ignore file's patterns and the folder they apply below.
struct IgnoreFile: Sendable {
    /// "" for the root, else the folder's path and "/".
    let base: [UInt8]
    let patterns: [IgnorePattern]

    init(base: [UInt8], contents: Data) {
        self.base = base
        var bytes = [UInt8](contents)
        // A byte order mark is skipped, as git skips it.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        patterns = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).compactMap { IgnorePattern(line: Array($0)) }
    }

    /// The outcome of this file's last matching pattern: true ignored, false
    /// re-included, nil when none matches.
    func decides(_ path: [UInt8], nameStart: Int, isDirectory: Bool) -> Bool? {
        for pattern in patterns.reversed() where pattern.matches(path, nameStart: nameStart, isDirectory: isDirectory, base: base) {
            return !pattern.negated
        }
        return nil
    }
}

/// The ignore files in force at a point of a walk: the global one, then the
/// root's `.gitignore`, then each folder's below it. A deeper file decides
/// before a shallower one, the global file last.
struct IgnoreRules: Sendable {
    var global: IgnoreFile?
    var stack: [IgnoreFile] = []

    func isIgnored(_ path: [UInt8], nameStart: Int, isDirectory: Bool) -> Bool {
        for file in stack.reversed() {
            if let decided = file.decides(path, nameStart: nameStart, isDirectory: isDirectory) { return decided }
        }
        return global?.decides(path, nameStart: nameStart, isDirectory: isDirectory) ?? false
    }
}

/// git's wildmatch (wildmatch.c), with and without WM_PATHNAME, case
/// sensitive, on bytes: ported line for line, so a pattern means here what
/// it means to git, quirks and all ("**" is special only between slashes).
enum Wildmatch {
    enum Outcome { case match, noMatch, abortAll, abortToStarStar }

    static func match(_ pattern: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>, pathname: Bool) -> Bool {
        let p = Array(pattern), t = Array(text)
        return dowild(p, 0, t, 0, pathname) == .match
    }

    private static func isGlobSpecial(_ byte: UInt8) -> Bool { byte == 0x2A || byte == 0x3F || byte == 0x5B || byte == 0x5C }

    /// `p` from `start` against `t` from `textStart`: git's dowild, where a
    /// byte past either end reads as NUL.
    static func dowild(_ p: [UInt8], _ start: Int, _ t: [UInt8], _ textStart: Int, _ pathname: Bool) -> Outcome {
        var pi = start, ti = textStart
        func pAt(_ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }
        func tAt(_ i: Int) -> UInt8 { i < t.count ? t[i] : 0 }
        while pAt(pi) != 0 {
            var pCh = pAt(pi)
            var tCh = tAt(ti)
            if tCh == 0, pCh != 0x2A { return .abortAll }
            switch pCh {
            case 0x5C:  // "\": the next byte literally
                pi += 1; pCh = pAt(pi)
                if tCh != pCh { return .noMatch }
            case 0x3F:  // "?": any byte but "/" with WM_PATHNAME
                if pathname, tCh == 0x2F { return .noMatch }
            case 0x2A:  // "*"
                var matchSlash: Bool
                pi += 1
                if pAt(pi) == 0x2A {
                    let previous = pi - 2
                    repeat { pi += 1 } while pAt(pi) == 0x2A
                    let next = pAt(pi)
                    if (previous < start || pAt(previous) == 0x2F) && (next == 0 || next == 0x2F || (next == 0x5C && pAt(pi + 1) == 0x2F)) {
                        // "**/" may match no folder at all: try that first.
                        if next == 0x2F, dowild(p, pi + 1, t, ti, pathname) == .match { return .match }
                        matchSlash = true
                    } else {
                        matchSlash = false
                    }
                } else {
                    matchSlash = !pathname
                }
                if pAt(pi) == 0 {
                    // A trailing "**" matches everything; a trailing "*" only
                    // what has no more "/".
                    if !matchSlash, ti < t.count, t[ti...].contains(0x2F) { return .noMatch }
                    return .match
                } else if !matchSlash, pAt(pi) == 0x2F {
                    // One "*" and a "/": the rest of this name; the "/" is
                    // then taken by the loop's own step.
                    guard ti < t.count, let slash = t[ti...].firstIndex(of: 0x2F) else { return .noMatch }
                    ti = slash
                    break
                }
                while true {
                    if tCh == 0 { break }
                    if !isGlobSpecial(pAt(pi)) {
                        // A literal next: what comes before it is the "*"'s.
                        pCh = pAt(pi)
                        while true {
                            tCh = tAt(ti)
                            if tCh == 0 || (!matchSlash && tCh == 0x2F) { break }
                            if tCh == pCh { break }
                            ti += 1
                        }
                        if tCh != pCh { return .noMatch }
                    }
                    let matched = dowild(p, pi, t, ti, pathname)
                    if matched != .noMatch {
                        if !matchSlash || matched != .abortToStarStar { return matched }
                    } else if !matchSlash, tCh == 0x2F {
                        return .abortToStarStar
                    }
                    ti += 1
                    tCh = tAt(ti)
                }
                return .abortAll
            case 0x5B:  // "[": a class
                pi += 1; pCh = pAt(pi)
                if pCh == 0x5E { pCh = 0x21 }  // "^" as "!"
                let negated = pCh == 0x21
                if negated { pi += 1; pCh = pAt(pi) }
                var previous: UInt8 = 0, matched = false
                repeat {
                    if pCh == 0 { return .abortAll }
                    if pCh == 0x5C {
                        pi += 1; pCh = pAt(pi)
                        if pCh == 0 { return .abortAll }
                        if tCh == pCh { matched = true }
                    } else if pCh == 0x2D, previous != 0, pAt(pi + 1) != 0, pAt(pi + 1) != 0x5D {  // "a-z"
                        pi += 1; pCh = pAt(pi)
                        if pCh == 0x5C {
                            pi += 1; pCh = pAt(pi)
                            if pCh == 0 { return .abortAll }
                        }
                        if tCh <= pCh, tCh >= previous { matched = true }
                        pCh = 0  // so "previous" is 0 after a range
                    } else if pCh == 0x5B, pAt(pi + 1) == 0x3A {  // "[:name:]"
                        let nameStart = pi + 2
                        pi = nameStart
                        while pAt(pi) != 0, pAt(pi) != 0x5D { pi += 1 }
                        pCh = pAt(pi)
                        if pCh == 0 { return .abortAll }
                        let length = pi - nameStart - 1
                        if length < 0 || pAt(pi - 1) != 0x3A {
                            // No ":]": an ordinary "[" in the class.
                            pi = nameStart - 2; pCh = 0x5B
                            if tCh == pCh { matched = true }
                        } else {
                            guard let inClass = posixClass(p[nameStart..<(nameStart + length)], tCh) else { return .abortAll }
                            if inClass { matched = true }
                            pCh = 0
                        }
                    } else if tCh == pCh {
                        matched = true
                    }
                    previous = pCh
                    pi += 1; pCh = pAt(pi)
                } while pCh != 0x5D
                if matched == negated || (pathname && tCh == 0x2F) { return .noMatch }
            default:
                if tCh != pCh { return .noMatch }
            }
            pi += 1; ti += 1
        }
        return tAt(ti) != 0 ? .noMatch : .match
    }

    /// The POSIX classes wildmatch knows, in the C locale; nil for a name it
    /// does not, which makes the whole pattern fail.
    private static func posixClass(_ name: ArraySlice<UInt8>, _ byte: UInt8) -> Bool? {
        let digit = byte >= 0x30 && byte <= 0x39, upper = byte >= 0x41 && byte <= 0x5A, lower = byte >= 0x61 && byte <= 0x7A
        let print = byte >= 0x20 && byte < 0x7F, space = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
        switch String(decoding: name, as: UTF8.self) {
        case "alnum": return digit || upper || lower
        case "alpha": return upper || lower
        case "blank": return byte == 0x20 || byte == 0x09
        case "cntrl": return byte < 0x20 || byte == 0x7F
        case "digit": return digit
        case "graph": return print && !space
        case "lower": return lower
        case "print": return print
        case "punct": return print && !space && !(digit || upper || lower)
        case "space": return space
        case "upper": return upper
        case "xdigit": return digit || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        default: return nil
        }
    }
}
