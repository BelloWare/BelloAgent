import Foundation
import GitProcessSafety

/// An immutable, complete, single-file Git patch. These bytes come directly
/// from Git, never from GitDiffParser (which is a lossy display parser).
/// Deliberately accepts only ordinary text modifications, not metadata edits.
public struct GitPatch: Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    public struct Hunk: Sendable {
        public let header: String
        public let rawRange: Range<Int>
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        let before: Data, after: Data
    }
    public let raw: Data
    public let path: String
    public let hunks: [Hunk]
    public let mode: String

    public init(raw: Data, path: String) throws {
        func refuse() -> GitFailure { GitFailure(message: "This change needs whole-file staging: its raw text patch is incomplete or unsupported.") }
        guard !raw.isEmpty, raw.count <= Self.maximumBytes, raw.last == 10,
              !raw.contains(0), String(data: raw, encoding: .utf8) != nil else { throw refuse() }
        let lines = Self.lines(raw)
        // The complete patch must fit the display parser too. Never activate
        // a hunk that the reader only saw part of.
        guard lines.count <= GitDiffParser.maximumLines, lines.count >= 6 else { throw refuse() }
        func text(_ n: Int) -> String { String(decoding: raw[lines[n]].dropLast(), as: UTF8.self) }
        guard text(0).gitHasPrefix("diff --git "), text(1).gitHasPrefix("index "),
              text(2).gitHasPrefix("--- "), text(3).gitHasPrefix("+++ ") else { throw refuse() }
        let index = text(1).gitSplit(separator: 32)
        guard index.count == 3, ["100644", "100755"].contains(String(index[2])) else { throw refuse() }
        func decodedPath(_ line: String, prefix: String) -> Data? {
            let value = String(line.gitDropFirst(4))
            let decoded: String
            if value.utf8.first == 34 {
                guard let parsed = GitQuoting.leading(value[...]), (parsed.rest.isEmpty || parsed.rest == "\t") else { return nil }
                decoded = parsed.name
            } else { decoded = value.gitHasSuffix("\t") ? String(value.gitDropLast()) : value }
            guard decoded.gitHasPrefix(prefix) else { return nil }
            return Data(decoded.gitDropFirst(2).utf8)
        }
        guard decodedPath(text(2), prefix: "a/") == Data(path.utf8),
              decodedPath(text(3), prefix: "b/") == Data(path.utf8) else { throw refuse() }
        let expression = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$"#)
        var hunks: [Hunk] = [], n = 4
        while n < lines.count {
            let begin = n, header = text(n), source = header as NSString
            guard let match = expression.firstMatch(in: header, range: NSRange(location: 0, length: source.length)) else { throw refuse() }
            func number(_ group: Int, default fallback: Int) throws -> Int {
                let range = match.range(at: group)
                if range.location == NSNotFound { return fallback }
                guard let value = Int(source.substring(with: range)), value <= 100_000_000 else { throw refuse() }
                return value
            }
            let oldStart = try number(1, default: 0), oldCount = try number(2, default: 1)
            let newStart = try number(3, default: 0), newCount = try number(4, default: 1)
            guard (oldCount == 0 || oldStart > 0), (newCount == 0 || newStart > 0) else { throw refuse() }
            if let previous = hunks.last {
                guard oldStart >= previous.oldStart + previous.oldCount,
                      newStart >= previous.newStart + previous.newCount else { throw refuse() }
            }
            n += 1
            var before = Data(), after = Data(), old = 0, new = 0, changed = false
            var previous: UInt8?, oldEnded = false, newEnded = false
            while n < lines.count, !text(n).gitHasPrefix("@@ ") {
                let bytes = raw[lines[n]]
                guard let kind = bytes.first else { throw refuse() }
                if kind == 92 {
                    guard text(n) == "\\ No newline at end of file", let prior = previous else { throw refuse() }
                    if prior != 43 { guard before.last == 10 else { throw refuse() }; before.removeLast(); oldEnded = true }
                    if prior != 45 { guard after.last == 10 else { throw refuse() }; after.removeLast(); newEnded = true }
                    previous = nil
                } else {
                    guard [32, 43, 45].contains(kind) else { throw refuse() }
                    if kind != 43 { guard !oldEnded else { throw refuse() }; before.append(contentsOf: bytes.dropFirst()); old += 1 }
                    if kind != 45 { guard !newEnded else { throw refuse() }; after.append(contentsOf: bytes.dropFirst()); new += 1 }
                    if kind != 32 { changed = true }
                    previous = kind
                }
                guard old <= oldCount, new <= newCount else { throw refuse() }
                n += 1
            }
            guard changed, old == oldCount, new == newCount else { throw refuse() }
            hunks.append(Hunk(header: header, rawRange: lines[begin].lowerBound..<lines[n - 1].upperBound,
                              oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, before: before, after: after))
        }
        guard !hunks.isEmpty else { throw refuse() }
        self.raw = raw; self.path = path; self.hunks = hunks; mode = String(index[2])
    }

    /// Applies precisely one raw hunk to the captured index blob. No offset
    /// search, whitespace normalization, context reduction or three-way path.
    public func applying(hunk index: Int, to blob: Data, reverse: Bool) throws -> Data {
        guard hunks.indices.contains(index) else { throw GitFailure(message: "Choose a hunk from the current diff.") }
        let hunk = hunks[index]
        let start = reverse ? hunk.newStart : hunk.oldStart, count = reverse ? hunk.newCount : hunk.oldCount
        let before = reverse ? hunk.after : hunk.before, after = reverse ? hunk.before : hunk.after
        let lines = Self.lines(blob), offset = count == 0 ? start : start - 1
        guard offset >= 0, offset <= lines.count, count <= lines.count - offset else {
            throw GitFailure(message: "The hunk no longer matches the index. Refresh and review it again.")
        }
        let lower = offset < lines.count ? lines[offset].lowerBound : blob.count
        let upper = count > 0 ? lines[offset + count - 1].upperBound : lower
        guard blob[lower..<upper] == before,
              (before.isEmpty || before.last == 10 || upper == blob.count),
              (after.isEmpty || after.last == 10 || upper == blob.count) else {
            throw GitFailure(message: "The hunk no longer matches the index. Refresh and review it again.")
        }
        var result = blob
        result.replaceSubrange(lower..<upper, with: after)
        return result
    }

    /// LF is a byte terminator here. A CR before it belongs to the content.
    static func lines(_ data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = [], start = 0
        for i in data.indices where data[i] == 10 { result.append(start..<(i + 1)); start = i + 1 }
        if start < data.count { result.append(start..<data.count) }
        return result
    }
}
