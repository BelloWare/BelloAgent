import Foundation

// Who last changed each line of a file (`git blame`), read for one version
// of the file: per line, the commit and where the line was in that commit —
// its path there and its line number there — which is what opening the
// change at that line needs once the file has been renamed or lines have
// moved. Lines not committed yet carry no commit.

/// One commit a blame names.
public struct GitBlameCommit: Equatable, Sendable {
    public let hash: String
    public let author: String
    public let email: String
    /// When it was authored, and the author's time zone as git wrote it.
    public let date: Date
    public let timeZone: String
    public let summary: String
    /// The history before it is not in this clone (a shallow clone's edge):
    /// there is no parent to compare it with.
    public internal(set) var historyMissing: Bool
    public var shortHash: String { String(hash.prefix(7)) }
}

/// One line of the file as blamed: its commit (nil when not committed yet),
/// and its path and line number (from 1) in that commit.
public struct GitBlameLine: Equatable, Sendable {
    public let commit: String?
    public let path: String
    public let line: Int
}

public struct GitBlame: Equatable, Sendable {
    /// Per line of the file, from line 1.
    public let lines: [GitBlameLine]
    public let commits: [String: GitBlameCommit]
    func marking(historyMissing hashes: Set<String>) -> GitBlame {
        var commits = commits
        for hash in hashes where commits[hash] != nil { commits[hash]?.historyMissing = true }
        return GitBlame(lines: lines, commits: commits)
    }
    public func commit(ofLine index: Int) -> GitBlameCommit? {
        guard lines.indices.contains(index), let hash = lines[index].commit else { return nil }
        return commits[hash]
    }
}

public enum GitBlameParser {
    static let uncommitted = String(repeating: "0", count: 40)

    struct Malformed: Error {}

    /// `git blame --porcelain`. Each group starts "<hash> <line there> <line
    /// here> [<count>]"; a commit's details follow the first time it is
    /// named, its file name then and again whenever the commit has more than
    /// one path; each line of the file follows its header after a tab.
    /// Anything out of shape throws: no line is attributed from output that
    /// was not read whole.
    public static func parse(_ data: Data, expectedLines: Int? = nil) throws -> GitBlame {
        try parseWithText(data, expectedLines: expectedLines).blame
    }
    /// The blame, and the text git gave for each line: what it blamed.
    static func parseWithText(_ data: Data, expectedLines: Int? = nil) throws -> (blame: GitBlame, text: [Data]) {
        var texts: [Data] = []
        var lines: [GitBlameLine] = []
        var commits: [String: GitBlameCommit] = [:]
        // Details read so far of a commit, until its first line closes them.
        var author = "", email = "", time: TimeInterval = 0, zone = "", summary = ""
        var fileNames: [String: String] = [:]
        var header: (hash: String, original: Int, final: Int)?
        for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if raw.first == UInt8(ascii: "\t") {
                guard let current = header, let path = fileNames[current.hash] else { throw Malformed() }
                if commits[current.hash] == nil {
                    commits[current.hash] = GitBlameCommit(hash: current.hash, author: author, email: email, date: Date(timeIntervalSince1970: time),
                                                           timeZone: zone, summary: summary, historyMissing: false)
                }
                guard current.final == lines.count + 1 else { throw Malformed() }
                lines.append(GitBlameLine(commit: current.hash == uncommitted ? nil : current.hash, path: path, line: current.original))
                texts.append(Data(raw.dropFirst()))
                header = nil
                continue
            }
            if raw.isEmpty { continue }
            let text = String(decoding: raw, as: UTF8.self)
            if header == nil {
                let parts = text.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count >= 3, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit),
                      let original = Int(parts[1]), let final = Int(parts[2]) else { throw Malformed() }
                let hash = String(parts[0])
                header = (hash, original, final)
                if commits[hash] == nil { author = ""; email = ""; time = 0; zone = ""; summary = "" }
                continue
            }
            guard let current = header else { throw Malformed() }
            let space = text.firstIndex(of: " ")
            let key = space.map { String(text[..<$0]) } ?? text
            let value = space.map { String(text[text.index(after: $0)...]) } ?? ""
            switch key {
            case "author": author = value
            case "author-mail": email = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            case "author-time": time = TimeInterval(value) ?? 0
            case "author-tz": zone = value
            case "summary": summary = value
            case "filename": fileNames[current.hash] = unquoted(value)
            default: break   // committer, previous: not needed here
            }
        }
        guard header == nil else { throw Malformed() }
        if let expectedLines, lines.count != expectedLines { throw Malformed() }
        return (GitBlame(lines: lines, commits: commits), texts)
    }

    static func unquoted(_ value: String) -> String { GitQuoting.unquoted(value) }
}

/// Names as git writes them in its output: as they are, or C-quoted ("...",
/// with backslash escapes and octal bytes) when they hold a quote, a
/// backslash or a control character — whatever core.quotePath says.
enum GitQuoting {
    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return decode(Array(value.utf8.dropFirst().dropLast()))
    }
    /// A name at the start of `text`, quoted or not, and what follows it: a
    /// quoted one ends at its closing quote; an unquoted one, at `end`.
    static func leading(_ text: Substring, upTo end: String? = nil) -> (name: String, rest: Substring)? {
        if text.first == "\"" {
            var escaped = false
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    let quoted = text[text.startIndex...index]
                    return (unquoted(String(quoted)), text[text.index(after: index)...])
                }
                index = text.index(after: index)
            }
            return nil
        }
        if let end, let range = text.range(of: end) { return (String(text[..<range.lowerBound]), text[range.lowerBound...]) }
        return (String(text), text[text.endIndex...])
    }
    private static func decode(_ escaped: [UInt8]) -> String {
        var bytes: [UInt8] = []
        var rest = escaped[...]
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = rest.popFirst() else { bytes.append(byte); continue }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    if let digit = rest.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) { octal = octal * 8 + Int(digit - UInt8(ascii: "0")); rest.removeFirst() }
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// How the lines of a file's bytes line up with Git's and a viewer's.
public enum GitBlameText {
    /// Git's lines in these bytes: one per "\n", and one more for text after
    /// the last. Nil when the bytes hold a lone "\r" (an old Mac line end),
    /// which a viewer ends a line at and Git does not, or are UTF-16: then
    /// no line of one can be named as a line of the other.
    public static func lineCount(of data: Data) -> Int? {
        if data.count >= 2, (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE) || (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF) { return nil }
        var lines = 0, previous: UInt8 = 0
        for byte in data {
            if previous == 13, byte != 10 { return nil }
            if byte == 0 { return nil }
            if byte == 10 { lines += 1 }
            previous = byte
        }
        if previous == 13 { return nil }
        if let last = data.last, last != 10 { lines += 1 }
        return lines
    }
    /// Whether git blamed these very lines: each line it gave is the line of
    /// `data` at its place, a trailing "\r" aside (CRLF turned to LF is the
    /// one conversion that keeps lines as they are). Anything a filter did
    /// otherwise — reordered, rewrote, re-encoded — fails.
    static func matches(_ data: Data, _ given: [Data]) -> Bool {
        var shown = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last == 10 { shown.removeLast() }
        guard shown.count == given.count else { return false }
        func bare(_ line: Data.SubSequence) -> Data.SubSequence { line.last == 13 ? line.dropLast() : line }
        for (a, b) in zip(shown, given) where bare(a) != bare(b[...]) { return false }
        return true
    }
}
