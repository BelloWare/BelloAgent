import Foundation
import GitProcessSafety

/// A unified diff parsed for rendering: files, hunks and lines with old/new
/// line numbers. Binary and mode-only changes keep a note instead of hunks.
public struct GitDiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed, note }
    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String
}

public struct GitDiffHunk: Identifiable, Equatable, Sendable {
    public let id: Int
    public let header: String
    public let lines: [GitDiffLine]
}

public struct GitDiffFile: Identifiable, Equatable, Sendable {
    public let oldPath: String
    public let newPath: String
    public let binary: Bool
    public let hunks: [GitDiffHunk]
    public let notes: [String]
    /// Counted once while parsing: a file card must not re-scan every line each
    /// time the diff is drawn.
    public let added: Int
    public let removed: Int
    public let lineCount: Int
    public init(oldPath: String, newPath: String, binary: Bool, hunks: [GitDiffHunk], notes: [String]) {
        self.oldPath = oldPath; self.newPath = newPath; self.binary = binary; self.hunks = hunks; self.notes = notes
        var added = 0, removed = 0, lines = 0
        for hunk in hunks {
            lines += hunk.lines.count
            for line in hunk.lines {
                if line.kind == .added { added += 1 } else if line.kind == .removed { removed += 1 }
            }
        }
        self.added = added; self.removed = removed; self.lineCount = lines
    }
    public var id: String { newPath.isEmpty ? oldPath : newPath }
    public var path: String { newPath == "/dev/null" || newPath.isEmpty ? oldPath : newPath }
    public var renamed: Bool { !oldPath.isEmpty && !newPath.isEmpty && oldPath != newPath && oldPath != "/dev/null" && newPath != "/dev/null" }
}

public enum GitDiffParser {
    public static let maximumLines = 20_000

    public static func parse(_ text: String) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var oldPath = "", newPath = "", binary = false, notes: [String] = []
        var hunks: [GitDiffHunk] = []
        var current: (header: String, lines: [GitDiffLine], old: Int, new: Int)?
        var lineID = 0, hunkID = 0, total = 0
        func closeHunk() {
            if let hunk = current { hunks.append(GitDiffHunk(id: hunkID, header: hunk.header, lines: hunk.lines)); hunkID += 1 }
            current = nil
        }
        func closeFile() {
            closeHunk()
            if !oldPath.isEmpty || !newPath.isEmpty { files.append(GitDiffFile(oldPath: oldPath, newPath: newPath, binary: binary, hunks: hunks, notes: notes)) }
            oldPath = ""; newPath = ""; binary = false; notes = []; hunks = []
        }
        var rawLines = text.gitSplit(separator: 10, omittingEmptySubsequences: false)
        // A trailing newline is a terminator, not an empty context line.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }
        for raw in rawLines {
            total += 1
            if total > maximumLines { notes.append("Diff truncated after \(maximumLines) lines."); break }
            let line = raw.utf8.last == 13 ? raw.gitDropLast() : raw
            if line.gitHasPrefix("diff --git ") {
                closeFile()
                let spec = line.gitDropFirst("diff --git ".count)
                if let (a, b) = splitPaths(String(spec)) { oldPath = a; newPath = b }
                continue
            }
            if current == nil {
                if line.gitHasPrefix("--- ") { oldPath = strip(String(line.gitDropFirst(4))); continue }
                if line.gitHasPrefix("+++ ") { newPath = strip(String(line.gitDropFirst(4))); continue }
                if line.gitHasPrefix("Binary files") || line.gitHasPrefix("GIT binary patch") { binary = true; notes.append("Binary file changed."); continue }
                if line.gitHasPrefix("rename from ") { oldPath = GitQuoting.unquoted(String(line.gitDropFirst("rename from ".count))); continue }
                if line.gitHasPrefix("rename to ") { newPath = GitQuoting.unquoted(String(line.gitDropFirst("rename to ".count))); continue }
                if line.gitHasPrefix("new file mode") { notes.append("New file."); continue }
                if line.gitHasPrefix("deleted file mode") { notes.append("File deleted."); continue }
                if line.gitHasPrefix("old mode") || line.gitHasPrefix("new mode") { notes.append(line); continue }
                if line.gitHasPrefix("similarity index") { notes.append("Similarity" + line.gitDropFirst(16)); continue }
            }
            if line.gitHasPrefix("@@") {
                closeHunk()
                let numbers = hunkNumbers(line)
                current = (header: line, lines: [], old: numbers.old, new: numbers.new)
                continue
            }
            guard var hunk = current else { continue }
            let kind: GitDiffLine.Kind
            var body = line
            if line.gitHasPrefix("+") { kind = .added; body = body.gitDropFirst() }
            else if line.gitHasPrefix("-") { kind = .removed; body = body.gitDropFirst() }
            else if line.gitHasPrefix("\\") { kind = .note; body = String(line.gitDropFirst(2)) }
            else { kind = .context; if !body.isEmpty { body = body.gitDropFirst() } }
            switch kind {
            case .added: hunk.lines.append(GitDiffLine(id: lineID, kind: .added, oldNumber: nil, newNumber: hunk.new, text: body)); hunk.new += 1
            case .removed: hunk.lines.append(GitDiffLine(id: lineID, kind: .removed, oldNumber: hunk.old, newNumber: nil, text: body)); hunk.old += 1
            case .context: hunk.lines.append(GitDiffLine(id: lineID, kind: .context, oldNumber: hunk.old, newNumber: hunk.new, text: body)); hunk.old += 1; hunk.new += 1
            case .note: hunk.lines.append(GitDiffLine(id: lineID, kind: .note, oldNumber: nil, newNumber: nil, text: body))
            }
            lineID += 1
            current = hunk
        }
        closeFile()
        return files
    }

    private static func strip(_ path: String) -> String {
        // A quoted name keeps its tabs; an unquoted one may be followed by a
        // tab and a timestamp.
        let trimmed = path.utf8.first == 34 ? (GitQuoting.leading(path[...])?.name ?? path) : (path.gitSplit(separator: 9).first ?? path)
        if trimmed == "/dev/null" { return trimmed }
        if trimmed.gitHasPrefix("a/") || trimmed.gitHasPrefix("b/") { return String(trimmed.gitDropFirst(2)) }
        return trimmed
    }
    /// "a/x b/y" with paths that may contain spaces: split at " b/" after "a/".
    private static func splitPaths(_ spec: String) -> (String, String)? {
        // Either name may be quoted: "a/x\ty" "b/x\ty".
        if spec.utf8.first == 34 || spec.gitContains(" \"b/") {
            guard let (old, rest) = GitQuoting.leading(spec[...], upTo: spec.gitContains(" \"b/") ? " \"b/" : " b/"), rest.utf8.first == 32 else { return nil }
            guard let (new, _) = GitQuoting.leading(rest.gitDropFirst()[...]) else { return nil }
            guard old.gitHasPrefix("a/"), new.gitHasPrefix("b/") else { return nil }
            return (old.gitDropFirst(2), new.gitDropFirst(2))
        }
        let bytes = Data(spec.utf8)
        guard spec.gitHasPrefix("a/"), let range = bytes.range(of: Data(" b/".utf8)) else { return nil }
        return (String(decoding: bytes[2..<range.lowerBound], as: UTF8.self), String(decoding: bytes[range.upperBound...], as: UTF8.self))
    }
    private static func hunkNumbers(_ header: String) -> (old: Int, new: Int) {
        // @@ -12,7 +12,9 @@ optional context
        let parts = header.gitSplit(separator: 32)
        func start(_ token: String) -> Int { Int(token.gitDropFirst().gitSplit(separator: 44).first ?? "0") ?? 0 }
        let old = parts.count > 1 ? start(parts[1]) : 0, new = parts.count > 2 ? start(parts[2]) : 0
        return (max(old, 1), max(new, 1))
    }
}

/// One row of a side-by-side diff: the old line on the left, the new on the
/// right. Context appears on both sides; a removed/added block is paired
/// line by line and the shorter side is padded with blanks.
public struct GitSplitRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let left: GitDiffLine?
    public let right: GitDiffLine?
}

public extension GitDiffHunk {
    /// Pairs the hunk's lines, stopping once `limit` rows exist. The limit is
    /// what the card is about to draw: pairing every line of a 20,000-line
    /// patch on every pass over the view's body is work nobody sees.
    func splitRows(limit: Int = .max) -> [GitSplitRow] {
        guard limit > 0 else { return [] }
        var rows: [GitSplitRow] = []
        rows.reserveCapacity(min(limit, lines.count))
        var removed: [GitDiffLine] = [], added: [GitDiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(GitSplitRow(id: rows.count, left: index < removed.count ? removed[index] : nil, right: index < added.count ? added[index] : nil))
            }
            removed = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .removed: if !added.isEmpty { flush() }; removed.append(line)
            case .added: added.append(line)
            case .context, .note: flush(); rows.append(GitSplitRow(id: rows.count, left: line, right: line))
            }
            if rows.count >= limit { return Array(rows.prefix(limit)) }
        }
        flush()
        return rows.count > limit ? Array(rows.prefix(limit)) : rows
    }
}
