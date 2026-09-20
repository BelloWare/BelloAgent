import Foundation

/// A unified diff parsed for rendering: files, hunks and lines with old/new
/// line numbers. Binary and mode-only changes keep a note instead of hunks.
struct GitDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, added, removed, note }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

struct GitDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let lines: [GitDiffLine]
}

struct GitDiffFile: Identifiable, Equatable, Sendable {
    let oldPath: String
    let newPath: String
    let binary: Bool
    let hunks: [GitDiffHunk]
    let notes: [String]
    /// Counted once while parsing: a file card must not re-scan every line each
    /// time the diff is drawn.
    let added: Int
    let removed: Int
    let lineCount: Int
    init(oldPath: String, newPath: String, binary: Bool, hunks: [GitDiffHunk], notes: [String]) {
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
    var id: String { newPath.isEmpty ? oldPath : newPath }
    var path: String { newPath == "/dev/null" || newPath.isEmpty ? oldPath : newPath }
    var renamed: Bool { !oldPath.isEmpty && !newPath.isEmpty && oldPath != newPath && oldPath != "/dev/null" && newPath != "/dev/null" }
}

enum GitDiffParser {
    static let maximumLines = 20_000

    static func parse(_ text: String) -> [GitDiffFile] {
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
        // Swift reads "\r\n" as one Character, so splitting on "\n" alone leaves
        // every line of a file with Windows endings joined into one row.
        var rawLines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        // A trailing newline is a terminator, not an empty context line.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }
        for raw in rawLines {
            total += 1
            if total > maximumLines { notes.append("Diff truncated after \(maximumLines) lines."); break }
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                let spec = line.dropFirst("diff --git ".count)
                if let (a, b) = splitPaths(String(spec)) { oldPath = a; newPath = b }
                continue
            }
            if current == nil {
                if line.hasPrefix("--- ") { oldPath = strip(String(line.dropFirst(4))); continue }
                if line.hasPrefix("+++ ") { newPath = strip(String(line.dropFirst(4))); continue }
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { binary = true; notes.append("Binary file changed."); continue }
                if line.hasPrefix("rename from ") { oldPath = String(line.dropFirst("rename from ".count)); continue }
                if line.hasPrefix("rename to ") { newPath = String(line.dropFirst("rename to ".count)); continue }
                if line.hasPrefix("new file mode") { notes.append("New file."); continue }
                if line.hasPrefix("deleted file mode") { notes.append("File deleted."); continue }
                if line.hasPrefix("old mode") || line.hasPrefix("new mode") { notes.append(line); continue }
                if line.hasPrefix("similarity index") { notes.append(line.replacingOccurrences(of: "similarity index", with: "Similarity")); continue }
            }
            if line.hasPrefix("@@") {
                closeHunk()
                let numbers = hunkNumbers(line)
                current = (header: line, lines: [], old: numbers.old, new: numbers.new)
                continue
            }
            guard var hunk = current else { continue }
            let kind: GitDiffLine.Kind
            var body = line
            if line.hasPrefix("+") { kind = .added; body.removeFirst() }
            else if line.hasPrefix("-") { kind = .removed; body.removeFirst() }
            else if line.hasPrefix("\\") { kind = .note; body = String(line.dropFirst(2)) }
            else { kind = .context; if !body.isEmpty { body.removeFirst() } }
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
        let trimmed = path.split(separator: "\t").first.map(String.init) ?? path
        if trimmed == "/dev/null" { return trimmed }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }
    /// "a/x b/y" with paths that may contain spaces: split at " b/" after "a/".
    private static func splitPaths(_ spec: String) -> (String, String)? {
        guard spec.hasPrefix("a/"), let range = spec.range(of: " b/") else { return nil }
        return (String(spec[spec.index(spec.startIndex, offsetBy: 2)..<range.lowerBound]), String(spec[range.upperBound...]))
    }
    private static func hunkNumbers(_ header: String) -> (old: Int, new: Int) {
        // @@ -12,7 +12,9 @@ optional context
        let parts = header.split(separator: " ")
        func start(_ token: Substring) -> Int { Int(token.dropFirst().split(separator: ",").first ?? "0") ?? 0 }
        let old = parts.count > 1 ? start(parts[1]) : 0, new = parts.count > 2 ? start(parts[2]) : 0
        return (max(old, 1), max(new, 1))
    }
}

/// One row of a side-by-side diff: the old line on the left, the new on the
/// right. Context appears on both sides; a removed/added block is paired
/// line by line and the shorter side is padded with blanks.
struct GitSplitRow: Identifiable, Equatable, Sendable {
    let id: Int
    let left: GitDiffLine?
    let right: GitDiffLine?
}

extension GitDiffHunk {
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
