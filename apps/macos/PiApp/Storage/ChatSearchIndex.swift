import Foundation
import SQLite3

// The sidebar's search inside chats: a full-text index of what each chat's
// transcript shows (the reader's messages, the replies, tool inputs and
// outputs; never reasoning), kept in one SQLite database beside the desktop
// metadata. It holds transcript text, so it is private like that database:
// a 0700 folder, 0600 files, deleted rows zeroed, and nothing it holds is
// ever written to a log.
//
// One writer (`ChatSearchIndex`) keeps the index current from the journals,
// one chat at a time, in the background; one reader (`ChatSearchQuery`)
// answers queries on a connection of its own, so typing never waits for a
// long chat to be indexed: a query sees what was last committed.

/// A chat the index should hold: its id and journal.
struct ChatSearchSource: Sendable, Hashable {
    var id: String
    var path: String
    /// An imported journal can be edited in place, before its end: any
    /// change indexes it again from its start.
    var rebuildsOnChange = false
}

/// Which part of a chat a match is in.
enum ChatSearchKind: String, Sendable {
    case user, assistant, toolInput, toolOutput
}

/// One chat's best match for a query: its newest matching message, where to
/// open the transcript for it, and the text around the match.
struct ChatSearchHit: Sendable, Equatable {
    var chatID: String
    /// The message to open at: the one that holds the match, a tool's
    /// result row for its output (the transcript shows it in its call's card).
    var messageID: String
    var kind: ChatSearchKind
    /// The match with some text around it, on one line.
    var excerpt: String
    /// The match within `excerpt`, in UTF-16 units.
    var highlight: NSRange
    /// Text to look in again for a longer query while its own answer is on
    /// its way (`ChatSearchHit.refined`): a bounded window around the match.
    var context: String
}

extension ChatSearchHit {
    /// The excerpt and highlight for `query` in `text`, or nil when `query`
    /// is not in it. Whitespace runs read as one space, as a sidebar line shows them.
    static func excerpt(of query: String, in source: String, before: Int = 40, after: Int = 160) -> (excerpt: String, highlight: NSRange, context: String)? {
        let needle = collapsed(query), text = source.precomposedStringWithCanonicalMapping
        guard !needle.isEmpty, let found = text.range(of: needle, options: [.caseInsensitive]) ?? collapsedRange(of: needle, in: text) else { return nil }
        // A window of the source around the match, collapsed, then cut at words.
        let lower = text.index(found.lowerBound, offsetBy: -(before * 3), limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(found.upperBound, offsetBy: after * 3, limitedBy: text.endIndex) ?? text.endIndex
        let window = collapsed(String(text[lower..<upper]))
        guard let match = window.range(of: needle, options: [.caseInsensitive]) else { return nil }
        var start = window.index(match.lowerBound, offsetBy: -before, limitedBy: window.startIndex) ?? window.startIndex
        if start > window.startIndex, let space = window[start..<match.lowerBound].firstIndex(of: " ") { start = window.index(after: space) }
        var end = window.index(match.upperBound, offsetBy: after, limitedBy: window.endIndex) ?? window.endIndex
        if end < window.endIndex, let space = window[match.upperBound..<end].lastIndex(of: " ") { end = space }
        let head = start > window.startIndex || lower > text.startIndex ? "…" : ""
        let tail = end < window.endIndex || upper < text.endIndex ? "…" : ""
        let excerpt = head + String(window[start..<end]) + tail
        let offset = (head as NSString).length + (String(window[start..<match.lowerBound]) as NSString).length
        let length = (String(window[match]) as NSString).length
        return (excerpt, NSRange(location: offset, length: length), window)
    }
    /// This hit for a longer query that still matches inside its context, or nil.
    func refined(to query: String) -> ChatSearchHit? {
        // Typing on usually extends the match where it stands: only its
        // highlight grows, when the longer match still fits in the excerpt.
        let shown = excerpt as NSString, needle = Self.collapsed(query)
        if highlight.length > 0, highlight.location < shown.length {
            let found = shown.range(of: needle, options: [.caseInsensitive, .anchored],
                                    range: NSRange(location: highlight.location, length: shown.length - highlight.location))
            if found.location != NSNotFound, NSMaxRange(found) < shown.length {
                var hit = self; hit.highlight = found; return hit
            }
        }
        guard let value = Self.excerpt(of: query, in: context) else { return nil }
        var hit = self; hit.excerpt = value.excerpt; hit.highlight = value.highlight; return hit
    }
    /// Whitespace runs as one space, in composed form: the index and the
    /// query read "é" alike however it was typed.
    static func collapsed(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
    /// A query with spaces in a text whose spaces are newlines or runs.
    private static func collapsedRange(of needle: String, in text: String) -> Range<String.Index>? {
        guard needle.contains(" ") else { return nil }
        let pattern = needle.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }
}

/// The database both sides open: where it is and how it is made.
enum ChatSearchDatabase {
    static let fileName = "search-index.sqlite"
    /// Bumped when what is indexed or how changes: the index is built again.
    static let schemaVersion = 1
    /// A long text (a tool's output can be a whole file) is indexed in
    /// pieces of this many characters, each overlapping the next by the
    /// longest query, so every match lies whole inside one piece. This
    /// bounds one document, not what is indexed: every piece is.
    static let chunkCharacters = 32_768
    /// The longest query content search answers, and the pieces' overlap.
    static let maximumQuery = 256
    /// Shortest query the content index can answer: three characters, as
    /// the trigram index reads text.
    static let minimumQuery = 3
    /// Whether the index can answer `query` (already collapsed): counted in
    /// Unicode scalars, as the trigram tokenizer counts characters.
    static func answers(_ query: String) -> Bool {
        (minimumQuery...maximumQuery).contains(query.unicodeScalars.count)
    }
    /// Where each piece of `text` the index holds lies: positions only, so
    /// a long output is copied one piece at a time, never whole.
    static func chunkRanges(_ text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = [], start = text.startIndex
        while true {
            let end = text.index(start, offsetBy: chunkCharacters, limitedBy: text.endIndex) ?? text.endIndex
            result.append(start..<end)
            if end == text.endIndex { return result }
            start = text.index(end, offsetBy: -maximumQuery)
        }
    }

    static func open(_ url: URL, readOnly: Bool) throws -> OpaquePointer {
        var handle: OpaquePointer?
        // The reader opens read-write but asks for queries only: a read-only
        // connection cannot make the WAL's shared-memory file when it is missing.
        let flags = readOnly ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        if !readOnly {
            // The folder is this user's alone, as the desktop database's is,
            // even when it was made before with looser permissions.
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // The file exists with its permissions before SQLite writes anything to it.
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StoreError.unavailable }
            }
            try protect(url)
        }
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.unavailable
        }
        sqlite3_busy_timeout(handle, 2_000)
        if readOnly { _ = sqlite3_exec(handle, "PRAGMA query_only=1", nil, nil, nil) }
        return handle
    }
    /// The database's own files, each readable by this user alone (SQLite
    /// gives its WAL and shared-memory files the database's permissions).
    /// Throws rather than index into a file others can read.
    static func protect(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path + suffix)[.posixPermissions] as? Int
            guard mode == 0o600 else { throw StoreError.unavailable }
        }
    }
    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
    }
    /// Quoted as one FTS5 string, so nothing typed is read as query syntax.
    static func phrase(_ query: String) -> String { "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// Keeps the index current: one chat at a time, page by page, from the same
/// visible timeline the transcript shows (its own `HistoryReader`, so it
/// never waits on, or evicts, the reader the chats are drawn from).
actor ChatSearchIndex {
    nonisolated let url: URL
    private var db: OpaquePointer?
    private let history: HistoryReader
    /// What one pass did, for tests and nothing else: chats indexed from
    /// their start, chats given only their new rows, chats removed.
    struct Pass: Sendable, Equatable {
        var rebuilt: [String] = []
        var extended: [String] = []
        var removed: [String] = []
        var unreadable: [String] = []
        var changed: Bool { !rebuilt.isEmpty || !extended.isEmpty || !removed.isEmpty }
    }
    /// Stops a pass between chats or pages (shutdown, a newer pass).
    private var stopping = false
    /// Chats deleted this launch. Chat ids are never reused, so these stay:
    /// a pass that listed one before it was deleted never writes it again.
    private var forgotten: Set<String> = []
    /// Deleted chats whose rows are still to go, once no pass is writing.
    private var unremoved: Set<String> = []

    /// The chats were deleted: their rows go now, or, while a pass is
    /// writing, as soon as it lets go; a chat being read is not committed.
    func forget(_ chats: Set<String>) {
        guard !chats.isEmpty else { return }
        forgotten.formUnion(chats); unremoved.formUnion(chats)
        if !passing { removeForgotten() }
    }
    private func removeForgotten() {
        guard !unremoved.isEmpty, let db = try? ready() else { return }
        for chat in unremoved where (try? remove(chat, db: db)) != nil { unremoved.remove(chat) }
        scrubLog()
    }

    /// A chat's rows were deleted, but the write-ahead log can still hold
    /// the pages they were on: a passive checkpoint copies the log into the
    /// database and leaves its frames, and a reader holding an older
    /// snapshot keeps them past any checkpoint. The log is emptied
    /// (`TRUNCATE`) once no reader holds it, retried with backoff for a
    /// while, and again after the next pass or deletion if it never could be.
    /// Every opening starts with one too: a launch after a crash may find
    /// the log of a deletion that was never emptied.
    private var logHoldsDeleted = false
    private var scrubbing: Task<Void, Never>?
    static let scrubPatience: Duration = .seconds(30)
    private func scrubLog() {
        guard logHoldsDeleted, scrubbing == nil, !stopping else { return }
        scrubbing = Task { await self.scrubUntilEmpty() }
    }
    private func scrubUntilEmpty() async {
        defer { scrubbing = nil }
        let deadline = ContinuousClock.now + Self.scrubPatience
        var wait = Duration.milliseconds(20)
        while logHoldsDeleted {
            // A pass may be inside a transaction: it scrubs when it lets go.
            guard !passing, let db else { return }
            if truncateLog(db) { logHoldsDeleted = false; return }
            guard ContinuousClock.now + wait < deadline else { return }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(1))
        }
    }
    /// One try at copying the log into the database and emptying it, without
    /// waiting on readers: true once the log file holds nothing.
    private func truncateLog(_ db: OpaquePointer) -> Bool {
        sqlite3_busy_timeout(db, 0); defer { sqlite3_busy_timeout(db, 2_000) }
        guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0
        return size == 0
    }

    init(url: URL, indexDirectory: URL = FileManager.default.temporaryDirectory) {
        self.url = url
        history = HistoryReader(indexDirectory: indexDirectory)
    }

    private func ready() throws -> OpaquePointer {
        if let db { return db }
        let handle = try ChatSearchDatabase.open(url, readOnly: false)
        do {
            // Deleted chats' text is zeroed on disk, not left in free pages.
            try ChatSearchDatabase.execute(handle, "PRAGMA secure_delete=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE")
            var version = 0
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
                version = Int(sqlite3_column_int64(statement, 0))
            }
            sqlite3_finalize(statement)
            if version != ChatSearchDatabase.schemaVersion {
                try ChatSearchDatabase.execute(handle, """
                    DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS content; DROP TABLE IF EXISTS chats;
                    CREATE TABLE chats(chat TEXT PRIMARY KEY, path TEXT NOT NULL, revision TEXT NOT NULL, incarnation TEXT, lineage TEXT,
                                       total INTEGER NOT NULL DEFAULT 0, newest TEXT, unreadable INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE content(id INTEGER PRIMARY KEY, chat TEXT NOT NULL, msg TEXT NOT NULL, call TEXT, kind TEXT NOT NULL,
                                         pos INTEGER NOT NULL, text TEXT NOT NULL);
                    CREATE INDEX content_chat ON content(chat, pos);
                    CREATE INDEX content_call ON content(chat, call);
                    CREATE VIRTUAL TABLE docs USING fts5(text, content='content', content_rowid='id', tokenize='trigram');
                    INSERT INTO docs(docs, rank) VALUES('secure-delete', 1);
                    CREATE TRIGGER content_ai AFTER INSERT ON content BEGIN INSERT INTO docs(rowid, text) VALUES (new.id, new.text); END;
                    CREATE TRIGGER content_ad AFTER DELETE ON content BEGIN INSERT INTO docs(docs, rowid, text) VALUES ('delete', old.id, old.text); END;
                    PRAGMA user_version=\(ChatSearchDatabase.schemaVersion);
                    """)
            }
            try ChatSearchDatabase.protect(url)
        } catch { sqlite3_close_v2(handle); throw error }
        db = handle
        logHoldsDeleted = true; scrubLog()
        return handle
    }

    /// A pass is running: it may be waiting on a page in the middle of a
    /// transaction, so `close()` leaves the database to the pass's end.
    private var passing = false
    func close() {
        stopping = true
        if !passing { removeForgotten(); closeNow() }
    }
    private func closeNow() {
        // One last try while a query may still be open (closing the last
        // connection empties the log by itself).
        if let db, logHoldsDeleted, truncateLog(db) { logHoldsDeleted = false }
        scrubbing?.cancel()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// One pass over every chat the sidebar can list: rows of chats no
    /// longer there go, and each listed chat whose journal changed since it
    /// was indexed is brought up to date, the most recently written first.
    /// `progress` hears after each chat that changed what a query finds.
    func reconcile(_ sources: [ChatSearchSource], progress: (@Sendable () async -> Void)? = nil) async -> Pass {
        var pass = Pass()
        guard !stopping, !passing, let db = try? ready() else { return pass }
        passing = true
        // A deleted chat's rows go before anything else, shutdown included.
        defer { passing = false; removeForgotten(); scrubLog(); if stopping { closeNow() } }
        let known = states(db)
        let listed = Set(sources.map(\.id)).subtracting(forgotten)
        for chat in known.keys where !listed.contains(chat) {
            if (try? remove(chat, db: db)) != nil { pass.removed.append(chat) }
        }
        // Newest journals first: the chats being worked in become searchable soonest.
        var ordered: [(ChatSearchSource, HistoryRevision?, Int)] = sources.map { source in
            var info = stat()
            let modified = stat(source.path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
            return (source, HistoryReader.currentRevision(path: source.path), modified)
        }
        ordered.sort { $0.2 > $1.2 }
        for (source, revision, _) in ordered where !forgotten.contains(source.id) {
            if stopping || Task.isCancelled { break }
            let state = known[source.id]
            guard let revision else {
                // The journal is gone (a chat whose file was moved or not
                // written yet): nothing of it is searchable.
                if state != nil, (try? remove(source.id, db: db)) != nil { pass.removed.append(source.id) }
                continue
            }
            if let state, state.path == source.path, state.revision == revision.stamp { continue }
            do {
                switch try await update(source, revision: revision, state: state?.path == source.path ? state : nil, db: db) {
                case .rebuilt: pass.rebuilt.append(source.id)
                case .extended: pass.extended.append(source.id)
                case .unchanged: continue
                case .unreadable: pass.unreadable.append(source.id); continue
                }
                await progress?()
            } catch is CancellationError {
                // A chat deleted while it was read is skipped; a stop ends the pass.
                if forgotten.contains(source.id), !stopping, !Task.isCancelled { continue }
                break
            }
            catch { pass.unreadable.append(source.id) }
        }
        await history.releaseIndexes()
        _ = try? ChatSearchDatabase.execute(db, "PRAGMA wal_checkpoint(PASSIVE)")
        return pass
    }

    // MARK: One chat

    private struct State { var path: String; var revision: String; var incarnation: String?; var lineage: String?; var total: Int; var newest: String? }
    private enum Outcome { case rebuilt, extended, unchanged, unreadable }

    private func states(_ db: OpaquePointer) -> [String: State] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT chat, path, revision, incarnation, lineage, total, newest FROM chats", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: State] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let chat = ChatSearchDatabase.text(statement!, 0), let path = ChatSearchDatabase.text(statement!, 1),
                  let revision = ChatSearchDatabase.text(statement!, 2) else { continue }
            result[chat] = State(path: path, revision: revision, incarnation: ChatSearchDatabase.text(statement!, 3),
                                 lineage: ChatSearchDatabase.text(statement!, 4), total: Int(sqlite3_column_int64(statement, 5)),
                                 newest: ChatSearchDatabase.text(statement!, 6))
        }
        return result
    }

    private func remove(_ chat: String, db: OpaquePointer) throws {
        try ChatSearchDatabase.execute(db, "BEGIN IMMEDIATE")
        do {
            try run(db, "DELETE FROM content WHERE chat=?", [chat])
            try run(db, "DELETE FROM chats WHERE chat=?", [chat])
            try ChatSearchDatabase.execute(db, "COMMIT")
        } catch { _ = try? ChatSearchDatabase.execute(db, "ROLLBACK"); throw error }
        logHoldsDeleted = true
    }

    /// One row of the visible timeline, at its position.
    private struct Row { var position: Int; var message: TranscriptMessage }

    private func update(_ source: ChatSearchSource, revision: HistoryRevision, state: State?, db: OpaquePointer) async throws -> Outcome {
        // Only the newest rows are needed when the chat only grew; a rebuild
        // reads the whole journal, so its index is built once, whole.
        let state = source.rebuildsOnChange ? nil : state
        let latest = try await history.read(path: source.path, whole: state == nil)
        try checkStillWanted(source.id)
        guard latest.notice == nil, let incarnation = latest.incarnation, let stamp = latest.revision?.stamp else {
            // Damaged, or its last record is still being written: tried
            // again when the journal next changes.
            try record(source, revision: revision.stamp, incarnation: nil, lineage: nil, total: state?.total ?? 0, newest: state?.newest, unreadable: true, db: db)
            return .unreadable
        }
        let total = latest.total
        if let state, state.incarnation == incarnation, state.lineage == latest.lineage, total >= state.total {
            if total == state.total, latest.messages.last?.id == state.newest {
                try record(source, revision: stamp, incarnation: incarnation, lineage: latest.lineage, total: total, newest: state.newest, unreadable: false, db: db)
                return .unchanged
            }
            if try await extend(source, latest: latest, after: state, db: db) { return .extended }
        }
        let whole = state == nil ? latest : try await history.read(path: source.path, whole: true)
        guard whole.notice == nil, whole.incarnation == incarnation else { return .unreadable }
        try await rebuild(source, latest: whole, db: db)
        return .rebuilt
    }

    /// A chat deleted, or a pass told to stop, since this chat's reading
    /// began: nothing more of it is written.
    private func checkStillWanted(_ chat: String) throws {
        if stopping || Task.isCancelled || forgotten.contains(chat) { throw CancellationError() }
    }
    /// Every page of one reading is of the same file, branch and length as
    /// the first; anything else is read again from the start.
    private static func consistent(_ page: HistoryPage, with latest: HistoryPage) -> Bool {
        page.notice == nil && page.incarnation == latest.incarnation && page.lineage == latest.lineage && page.total == latest.total
    }
    /// Commits what a reading wrote only while the journal is still the file
    /// it read and the chat is still wanted; else takes it back.
    private func commit(_ source: ChatSearchSource, latest: HistoryPage, db: OpaquePointer) throws {
        try checkStillWanted(source.id)
        guard HistoryReader.currentRevision(path: source.path) == latest.revision else { throw StoreError.unreadableRecord }
        try record(source, revision: latest.revision?.stamp ?? "", incarnation: latest.incarnation, lineage: latest.lineage,
                   total: latest.total, newest: latest.messages.last?.id, unreadable: false, db: db)
        try ChatSearchDatabase.execute(db, "COMMIT")
    }

    /// Adds the rows after the newest one indexed, when the timeline only
    /// grew: the newest indexed row is still where it was and everything
    /// after it is new. Rows are written page by page as they are read, in
    /// one transaction taken back (false: the chat is rebuilt) when anything
    /// else changed.
    private func extend(_ source: ChatSearchSource, latest: HistoryPage, after state: State, db: OpaquePointer) async throws -> Bool {
        guard let newest = state.newest else { return false }
        let expected = latest.total - state.total
        try ChatSearchDatabase.execute(db, "BEGIN IMMEDIATE")
        do {
            var added = 0, page = latest, end = latest.total
            reading: while true {
                try checkStillWanted(source.id)
                guard Self.consistent(page, with: latest) else { throw StoreError.unreadableRecord }
                let start = end - page.messages.count
                for (offset, message) in page.messages.enumerated().reversed() {
                    let position = start + offset
                    if message.id == newest {
                        guard position == state.total - 1, added == expected else { throw StoreError.unreadableRecord }
                        break reading
                    }
                    try insert(Row(position: position, message: message), chat: source.id, db: db)
                    added += 1
                    if added > expected { throw StoreError.unreadableRecord }
                }
                guard let older = page.older?.entry, start > 0 else { throw StoreError.unreadableRecord }
                page = try await history.read(path: source.path, before: older)
                end = start
            }
            try commit(source, latest: latest, db: db)
            return true
        } catch is CancellationError { _ = try? ChatSearchDatabase.execute(db, "ROLLBACK"); throw CancellationError() }
        catch { _ = try? ChatSearchDatabase.execute(db, "ROLLBACK"); return false }
    }

    /// The whole chat again, in one transaction: a query sees the chat as it
    /// was until the new one is complete.
    private func rebuild(_ source: ChatSearchSource, latest: HistoryPage, db: OpaquePointer) async throws {
        try ChatSearchDatabase.execute(db, "BEGIN IMMEDIATE")
        do {
            try run(db, "DELETE FROM content WHERE chat=?", [source.id])
            var page = latest, end = latest.total
            while true {
                try checkStillWanted(source.id)
                guard Self.consistent(page, with: latest) else { throw StoreError.unreadableRecord }
                let start = end - page.messages.count
                for (offset, message) in page.messages.enumerated() { try insert(Row(position: start + offset, message: message), chat: source.id, db: db) }
                guard let older = page.older?.entry, start > 0 else { break }
                page = try await history.read(path: source.path, before: older)
                end = start
            }
            // Written to while it was read: indexed again on the next pass.
            try commit(source, latest: latest, db: db)
        } catch { _ = try? ChatSearchDatabase.execute(db, "ROLLBACK"); throw error }
    }

    /// What one transcript row indexes: its text, and a reply's tool
    /// inputs; a tool result's output. Reasoning, markers and summaries are
    /// not what the reader searches for. In the form queries are matched in:
    /// composed, each whitespace run one space ("retry loop" finds "retry\nloop").
    static func pieces(of message: TranscriptMessage) -> [(kind: ChatSearchKind, call: String?, text: String)] {
        if ["execution", "requestLedger", "branch", "compaction"].contains(message.kind ?? "") { return [] }
        var result: [(ChatSearchKind, String?, String)] = []
        switch message.role {
        case "user":
            result.append((.user, nil, message.text))
        case "assistant":
            result.append((.assistant, nil, message.text))
            for tool in message.tools ?? [] { result.append((.toolInput, tool.id, tool.name + " " + tool.input)) }
        case "tool":
            result.append((.toolOutput, message.toolCallID, message.text))
        default:
            break
        }
        return result.compactMap { kind, call, text in
            let normalized = ChatSearchHit.collapsed(text)
            return normalized.isEmpty ? nil : (kind, call, normalized)
        }
    }

    private func insert(_ row: Row, chat: String, db: OpaquePointer) throws {
        for (kind, call, text) in Self.pieces(of: row.message) {
            for range in ChatSearchDatabase.chunkRanges(text) {
                try insert(chat: chat, message: row.message.id, kind: kind, call: call, position: row.position, text: String(text[range]), db: db)
            }
        }
    }
    private func insert(chat: String, message: String, kind: ChatSearchKind, call: String?, position: Int, text: String, db: OpaquePointer) throws {
        do {
            let document = (kind: kind, call: call, text: text)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO content(chat, msg, call, kind, pos, text) VALUES(?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, chat, -1, ChatSearchDatabase.transient)
            sqlite3_bind_text(statement, 2, message, -1, ChatSearchDatabase.transient)
            if let call = document.call { sqlite3_bind_text(statement, 3, call, -1, ChatSearchDatabase.transient) } else { sqlite3_bind_null(statement, 3) }
            sqlite3_bind_text(statement, 4, document.kind.rawValue, -1, ChatSearchDatabase.transient)
            sqlite3_bind_int64(statement, 5, Int64(position))
            sqlite3_bind_text(statement, 6, document.text, -1, ChatSearchDatabase.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        }
    }

    private func record(_ source: ChatSearchSource, revision: String, incarnation: String?, lineage: String?, total: Int, newest: String?,
                        unreadable: Bool, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO chats(chat, path, revision, incarnation, lineage, total, newest, unreadable) VALUES(?,?,?,?,?,?,?,?)",
                                 -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [source.id, source.path, revision, incarnation, lineage].enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, ChatSearchDatabase.transient) } else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        sqlite3_bind_int64(statement, 6, Int64(total))
        if let newest { sqlite3_bind_text(statement, 7, newest, -1, ChatSearchDatabase.transient) } else { sqlite3_bind_null(statement, 7) }
        sqlite3_bind_int(statement, 8, unreadable ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, ChatSearchDatabase.transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
    }

    // MARK: Test seams

    /// How many documents the index holds for `chat` (all chats when nil).
    func documentCount(chat: String? = nil) -> Int {
        guard let db = try? ready() else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, chat == nil ? "SELECT count(*) FROM content" : "SELECT count(*) FROM content WHERE chat=?", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        if let chat { sqlite3_bind_text(statement, 1, chat, -1, ChatSearchDatabase.transient) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
    func indexedChats() -> Set<String> { guard let db = try? ready() else { return [] }; return Set(states(db).keys) }
}

/// Answers queries from the index on its own connection. A newer query
/// stops the one before it at once (`cancel`), from any thread.
final class ChatSearchQuery: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    /// Bumped by `cancel()`: a query running under an older value stops.
    private var generation = 0
    private var running = 0
    private let queue = DispatchQueue(label: "bello.search.query", qos: .userInitiated)

    /// Test seam: how long each query takes at least, on the query's own thread.
    var delay: TimeInterval = 0
    init(url: URL) { self.url = url }
    deinit { if let db { sqlite3_close_v2(db) } }

    /// Stops whatever query is running now.
    func cancel() { lock.lock(); generation &+= 1; lock.unlock() }
    private var stale: Bool { lock.lock(); defer { lock.unlock() }; return generation != running }

    /// Each listed chat's newest match for `query`, or throws
    /// `CancellationError` when a newer query (or `cancel()`) stopped it.
    func search(_ query: String) async throws -> [String: ChatSearchHit] {
        let mine = lock.withLock { generation }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result { try self.run(query, generation: mine) })
                }
            }
        } onCancel: { [weak self] in self?.cancel() }
    }

    private func connection() throws -> OpaquePointer? {
        if let db { return db }
        // Nothing indexed yet: nothing to find.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try ChatSearchDatabase.open(url, readOnly: true)
        sqlite3_progress_handler(handle, 2_000, { context in
            guard let context else { return 0 }
            return Unmanaged<ChatSearchQuery>.fromOpaque(context).takeUnretainedValue().stale ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        db = handle
        return handle
    }

    private func run(_ query: String, generation mine: Int) throws -> [String: ChatSearchHit] {
        lock.lock(); running = mine; let current = generation == mine; lock.unlock()
        guard current else { throw CancellationError() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let needle = ChatSearchHit.collapsed(query)
        guard ChatSearchDatabase.answers(needle), let db = try connection() else { return [:] }
        // One read transaction: the winners and their text come from the
        // same version of the index, while a pass
        // may be replacing rows (and reusing their ids) underneath.
        try ChatSearchDatabase.execute(db, "BEGIN")
        defer { _ = sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        // Each chat's newest matching document; within one message, its
        // text before its tool inputs, as they were written. Ranked by id
        // alone, and only the winners' text read: a common word in long
        // histories matches thousands of large pieces.
        var statement: OpaquePointer?
        let sql = """
            SELECT c.chat, c.msg, c.call, c.kind, c.pos, c.text FROM content c JOIN (
                SELECT id FROM (SELECT m.id AS id, ROW_NUMBER() OVER (PARTITION BY m.chat ORDER BY m.pos DESC, m.id ASC) AS n
                                FROM docs JOIN content m ON m.id = docs.rowid WHERE docs MATCH ?) WHERE n = 1
            ) winner ON c.id = winner.id
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, ChatSearchDatabase.phrase(needle), -1, ChatSearchDatabase.transient)
        var hits: [String: ChatSearchHit] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            if status == SQLITE_INTERRUPT || stale { throw CancellationError() }
            guard status == SQLITE_ROW, let chat = ChatSearchDatabase.text(statement!, 0), let message = ChatSearchDatabase.text(statement!, 1),
                  let kind = ChatSearchDatabase.text(statement!, 3).flatMap(ChatSearchKind.init(rawValue:)),
                  let text = ChatSearchDatabase.text(statement!, 5) else { throw StoreError.unavailable }
            // The match as a line of the sidebar; the trigram index folds case
            // a little differently, so a document it found may read without one.
            let excerpt = ChatSearchHit.excerpt(of: needle, in: text)
                ?? (String(ChatSearchHit.collapsed(String(text.prefix(400))).prefix(200)), NSRange(location: 0, length: 0), "")
            // A tool's output names its own result row, not the reply whose card
            // shows it: a page read around that reply can stop before a later
            // result (a large one ahead of it fills the page), while one read
            // around the result always holds it. The transcript draws it in
            // its call's card when the page holds the call (`drawingMessageID`).
            hits[chat] = ChatSearchHit(chatID: chat, messageID: message, kind: kind, excerpt: excerpt.excerpt, highlight: excerpt.highlight, context: excerpt.context)
        }
        return hits
    }
}
