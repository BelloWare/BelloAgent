import CryptoKit
import Foundation
import SQLite3

enum StoreError: Error, Equatable, LocalizedError {
    case unavailable, invalidRecord, staleRevision, draftConflict
    /// A conversation file could not be read. Distinct from `invalidRecord`,
    /// which is about writing desktop metadata: reporting a read failure with a
    /// write message told the user a save had failed when nothing was saved.
    case unreadableRecord
    case missingJournal(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Desktop storage is unavailable."
        case .invalidRecord: "The desktop record could not be saved."
        case .staleRevision: "A newer version of this desktop record has already been saved."
        case .draftConflict: "Another app instance saved this draft. Both copies are saved. Reopen this chat to recover a conflicting draft."
        case .unreadableRecord: "This conversation file could not be read. Its bytes were left untouched."
        case .missingJournal(let path): "The conversation file is no longer at \(path). Nothing was written in its place."
        }
    }
}

/// Owned only by MetadataStore. SQLite calls remain actor-isolated; the wrapper
/// also releases the handle when initialization throws or the actor is dropped.
private final class MetadataDatabase {
    let identity = UUID()
    private(set) var handle: OpaquePointer?
    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw StoreError.unavailable
        }
        handle = opened
        do {
            guard sqlite3_exec(opened, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000; CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(kind,id));", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { close(); throw error }
    }
    func close() {
        guard let handle else { return }
        self.handle = nil
        sqlite3_close_v2(handle)
    }
    deinit { close() }
}

// Native is SQLite's only writer. JSON documents are small desktop metadata;
// authoritative conversation messages and raw capture bodies never enter this database.
/// Told of every committed draft write (`MetadataStore`): the chat, whether
/// its draft now holds unsent work, and the write's place in the order of
/// writes. The sidebar's draft marker follows these (`WorkspaceDraftMarks.swift`).
final class DraftWriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String, Bool, Int) -> Void)?
    func observe(_ handler: @escaping @Sendable (String, Bool, Int) -> Void) { lock.lock(); self.handler = handler; lock.unlock() }
    func send(_ id: String, _ holdsDraft: Bool, _ sequence: Int) {
        lock.lock(); let handler = handler; lock.unlock()
        handler?(id, holdsDraft, sequence)
    }
}

/// A display's last loaded or committed draft. Store transactions advance
/// this shared version only after commit, so overlapping local saves use the
/// same revision while a second app instance keeps its independent baseline.
final class DraftVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (draft: DraftRecord?, revision: Int64?)
    private var conflicts: [DraftRecord] = []
    init(draft: DraftRecord? = nil, revision: Int64? = nil) { value = (draft, revision) }
    var snapshot: (draft: DraftRecord?, revision: Int64?) { lock.withLock { value } }
    var unsavedConflicts: [DraftRecord] { lock.withLock { conflicts } }
    var hasUnsavedConflict: Bool { lock.withLock { !conflicts.isEmpty } }
    fileprivate func conflicted(_ draft: DraftRecord) { lock.withLock { if !conflicts.contains(draft) { conflicts.append(draft) } } }
    fileprivate func preserved(_ draft: DraftRecord) { lock.withLock { conflicts.removeAll { $0 == draft } } }
    fileprivate func committed(_ draft: DraftRecord, revision: Int64) { lock.withLock { value = (draft, revision) } }
}

final class AnchorVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (anchor: TranscriptAnchor?, revision: Int64?)
    init(anchor: TranscriptAnchor? = nil, revision: Int64? = nil) { value = (anchor, revision) }
    var snapshot: (anchor: TranscriptAnchor?, revision: Int64?) { lock.withLock { value } }
    fileprivate func committed(_ anchor: TranscriptAnchor?, revision: Int64) { lock.withLock { value = (anchor, revision) } }
}

struct SavedDraftConflict: Sendable, Identifiable, Equatable {
    let id: String
    let draft: DraftRecord
}

actor MetadataStore {
    /// Input records can hold an edited message, its displaced draft and a
    /// queued rewrite. Each supported 256 KiB text can expand sixfold in JSON
    /// (control characters), with room left for image and skill descriptors.
    /// This is desktop input storage, independent of request capture.
    static let inputRecordByteLimit = 8 * 1024 * 1024
    private static func recordByteLimit(_ kind: String) -> Int {
        kind == "draft" || kind.hasPrefix("draft-conflict:") || kind.hasPrefix("pending:") ? inputRecordByteLimit : 524_288
    }
    nonisolated let draftWrites = DraftWriteEvents()
    /// Draft writes so far, and those of a transaction not yet committed.
    private var draftSequence = 0
    private var transactionDrafts: [(String, Bool)]?
    private var transactionDraftVersions: [(DraftVersion, DraftRecord, Int64)] = []
    private var transactionConflicts: [DraftVersion] = []
    private func noteDraftWrite(_ id: String, _ holdsDraft: Bool) {
        if transactionDrafts != nil { transactionDrafts?.append((id, holdsDraft)); return }
        draftSequence += 1; draftWrites.send(id, holdsDraft, draftSequence)
    }
    private func flushTransactionDrafts() {
        let drafts = transactionDrafts ?? []; transactionDrafts = nil
        for (id, holds) in drafts { noteDraftWrite(id, holds) }
    }
    /// Which chats' saved drafts hold unsent work, as of the write numbered
    /// `sequence`: launch's starting point for the draft markers.
    func draftMarks() throws -> (ids: Set<String>, sequence: Int) {
        let drafts = try list(DraftRecord.self, kind: "draft")
        return (Set(drafts.filter(\.holdsUnsentDraft).map(\.id)), draftSequence)
    }
    private let url: URL
    private var connection: MetadataDatabase?
    private var attempted = false
    private var lastReservedRevision: Int64 = 0
    /// Chats the last listing could not show: rows this build cannot decode
    /// plus rows past the listing limit. The sidebar used to drop them in
    /// silence, so a chat could vanish with its file still on disk.
    private(set) var unlistedChats = 0
    /// Test seam: full `ChatRecord` decodes performed. Tests pin how much of
    /// the database an operation has to materialise; grouping used to
    /// materialise all of it. One addition per decode when nothing reads it.
    private(set) var decodedChats = 0
    private(set) var organizationCommits = 0
    /// Cheap and non-throwing. Opening SQLite runs WAL recovery, which used to
    /// happen on whichever thread built the model — for the app, the main actor
    /// during its first `body`. The database opens inside the actor instead, on
    /// first use or when `open()` asks for it.
    init(url: URL) { self.url = url }
    /// Opens the database now and reports why it could not be opened, for the
    /// caller that needs to know there is no storage at all.
    func open() throws { _ = try ready() }
    private func ready() throws -> OpaquePointer {
        if !attempted {
            attempted = true
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            connection = try? MetadataDatabase(url: url)
        }
        guard let database = connection?.handle else { throw StoreError.unavailable }
        return database
    }
    /// Reserve before an asynchronous debounce. Persisted revisions, rather
    /// than the wall clock alone, keep edits ordered across clock corrections.
    func reserveRevision(kind: String, id: String) throws -> Int64 {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT revision FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw StoreError.unavailable }
        let previous = result == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
        let latest = max(lastReservedRevision, previous)
        guard latest < Int64.max else { throw StoreError.invalidRecord }
        lastReservedRevision = max(latest + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        return lastReservedRevision
    }
    func put<T: Encodable & Sendable>(_ value: T, kind: String, id: String, revision: Int64? = nil, releasingTitleClaim: Bool = false, draftVersion: DraftVersion? = nil) throws {
        if let draftVersion, kind == "draft", let draft = value as? DraftRecord {
            try putDraft(draft, version: draftVersion, revision: revision); return
        }
        let database = try ready()
        let savedRevision: Int64
        if kind == TopicRecord.recordKind {
            // Topic callers carry their own persisted revision. Reserving a new
            // one here would let a delayed snapshot overwrite a newer rename.
            guard let topic = value as? TopicRecord, topic.id == id, topic.isValid, topic.revision > 0,
                  revision == nil || revision == topic.revision,
                  try get(Int64.self, kind: TopicRecord.deletedRecordKind, id: id) == nil else { throw StoreError.invalidRecord }
            if let previous = try get(TopicRecord.self, kind: kind, id: id) {
                guard previous.workspaceID == topic.workspaceID, previous.createdAt == topic.createdAt else { throw StoreError.invalidRecord }
                guard topic.revision > previous.revision || topic == previous else { throw StoreError.staleRevision }
            }
            savedRevision = topic.revision
        } else { savedRevision = try revision ?? reserveRevision(kind: kind, id: id) }
        let data: Data
        if kind == "chat", var chat = value as? ChatRecord {
            guard try get(String.self, kind: "session-deleted", id: id) == nil else { throw StoreError.invalidRecord }
            // A chat's record is written from many places at once; what an
            // older copy may not take back is in `ChatRecordMerge.swift`.
            if let previous = try get(ChatRecord.self, kind: kind, id: id) { chat = chat.merged(over: previous, releasingTitleClaim: releasingTitleClaim) }
            if let topicID = chat.topicID { chat = chat.fitting(topic: try get(TopicRecord.self, kind: TopicRecord.recordKind, id: topicID)) }
            data = try JSONEncoder().encode(chat)
        } else { data = try JSONEncoder().encode(value) }
        guard data.count <= Self.recordByteLimit(kind) else { throw StoreError.invalidRecord }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO records VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET value=excluded.value,revision=excluded.revision WHERE excluded.revision>=records.revision", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_int64(statement, 4, savedRevision)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        guard sqlite3_changes(database) == 1 else { throw StoreError.staleRevision }
        if kind == "draft", let draft = value as? DraftRecord { noteDraftWrite(id, draft.holdsUnsentDraft) }
        if kind.hasPrefix("receipt:") { try prune(kind: kind, keeping: 128) }
    }
    private func putDraft(_ draft: DraftRecord, version: DraftVersion, revision: Int64?) throws {
        _ = try ready()
        let previous = version.snapshot
        // An unchanged stale composer owns no write, even at Quit. Normalize
        // optional empty arrays used by older drafts before comparing them.
        guard version.hasUnsavedConflict || !draft.hasSameContents(as: previous.draft ?? DraftRecord(id: draft.id, text: "")) else { return }
        func save() throws {
            let current = try draftVersion(id: draft.id).snapshot
            guard !version.hasUnsavedConflict, current.revision == previous.revision else {
                version.conflicted(draft); transactionConflicts.append(version)
                throw StoreError.draftConflict
            }
            let next = try revision ?? reserveRevision(kind: "draft", id: draft.id)
            try put(draft, kind: "draft", id: draft.id, revision: next)
            transactionDraftVersions.append((version, draft, next))
        }
        // BEGIN IMMEDIATE makes the comparison and write indivisible across
        // independent MetadataStore actors and app processes.
        if transactionDrafts != nil { try save() } else { try transaction(save) }
    }
    func draftVersion(id: String) throws -> DraftVersion {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value,revision FROM records WHERE kind='draft' AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return DraftVersion() }
        guard result == SQLITE_ROW else { throw StoreError.unavailable }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard size <= Self.inputRecordByteLimit, let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
        let draft = try JSONDecoder().decode(DraftRecord.self, from: Data(bytes: bytes, count: size))
        return DraftVersion(draft: draft, revision: sqlite3_column_int64(statement, 1))
    }
    /// Complete draft copies, separate from the winning draft and never
    /// pruned. Raw attachment references participate in the existing sweep.
    func draftConflicts(id: String) throws -> [SavedDraftConflict] {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,value FROM records WHERE kind=? ORDER BY revision DESC,id", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "draft-conflict:" + id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var copies: [SavedDraftConflict] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 1))
            guard size <= Self.inputRecordByteLimit, let key = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { throw StoreError.invalidRecord }
            copies.append(.init(id: String(cString: key), draft: try JSONDecoder().decode(DraftRecord.self, from: Data(bytes: bytes, count: size))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.unavailable }
        return copies
    }
    func preserveDraftConflicts(_ version: DraftVersion) throws {
        for draft in version.unsavedConflicts { try preserveConflict(draft); version.preserved(draft) }
    }
    private func preserveConflict(_ draft: DraftRecord) throws {
        guard try !draftConflicts(id: draft.id).contains(where: { $0.draft.hasSameContents(as: draft) }) else { return }
        try put(draft, kind: "draft-conflict:" + draft.id, id: UUID().uuidString)
    }
    /// An explicit choice from the recovery banner. Preserve the current
    /// saved and live copies before replacing either; nothing is submitted.
    func restoreConflict(_ conflict: SavedDraftConflict, replacing live: DraftRecord, version: DraftVersion) throws {
        let pending = version.unsavedConflicts
        try transaction {
            for draft in pending { try preserveConflict(draft) }
            guard live.id == conflict.draft.id,
                  try get(DraftRecord.self, kind: "draft-conflict:" + live.id, id: conflict.id) == conflict.draft else { throw StoreError.staleRevision }
            if let saved = try get(DraftRecord.self, kind: "draft", id: live.id), !saved.hasSameContents(as: conflict.draft) { try preserveConflict(saved) }
            if !live.hasSameContents(as: conflict.draft) { try preserveConflict(live) }
            let revision = try reserveRevision(kind: "draft", id: live.id)
            try put(conflict.draft, kind: "draft", id: live.id, revision: revision)
            transactionDraftVersions.append((version, conflict.draft, revision))
            try remove(kind: "draft-conflict:" + live.id, id: conflict.id)
        }
        for draft in pending { version.preserved(draft) }
    }
    func anchorVersion(id: String) throws -> AnchorVersion {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT kind,value,revision FROM records WHERE kind IN ('anchor','anchor-deleted') AND id=? ORDER BY revision DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return AnchorVersion() }
        guard result == SQLITE_ROW, let kind = sqlite3_column_text(statement, 0) else { throw StoreError.unavailable }
        let revision = sqlite3_column_int64(statement, 2)
        if String(cString: kind) == "anchor-deleted" { return AnchorVersion(revision: revision) }
        let size = Int(sqlite3_column_bytes(statement, 1))
        guard size <= Self.recordByteLimit("anchor"), let bytes = sqlite3_column_blob(statement, 1) else { throw StoreError.invalidRecord }
        return AnchorVersion(anchor: try JSONDecoder().decode(TranscriptAnchor.self, from: Data(bytes: bytes, count: size)), revision: revision)
    }
    func putAnchor(_ anchor: TranscriptAnchor?, id: String, version: AnchorVersion) throws {
        let previous = version.snapshot
        guard anchor != previous.anchor else { return }
        let revision: Int64? = try transaction {
            guard try anchorVersion(id: id).snapshot.revision == previous.revision else { return nil }
            guard (previous.revision ?? 0) < Int64.max else { throw StoreError.invalidRecord }
            let next = max(try reserveRevision(kind: "anchor", id: id), (previous.revision ?? 0) + 1)
            if let anchor {
                try put(anchor, kind: "anchor", id: id, revision: next)
                try remove(kind: "anchor-deleted", id: id)
            } else {
                // Keep a revision for absence: an old missing-row baseline
                // cannot resurrect a position after another instance clears it.
                try put(next, kind: "anchor-deleted", id: id, revision: next)
                try remove(kind: "anchor", id: id)
            }
            return next
        }
        if let revision { version.committed(anchor, revision: revision) }
    }
    /// Update only the cost choice from the latest durable chat. The revision
    /// also protects it from unrelated writes holding an older chat copy.
    func updateChatCostLimit(id: String, limit: CostLimit?) throws -> ChatRecord {
        guard var chat = try get(ChatRecord.self, kind: "chat", id: id), limit?.isValid != false else { throw StoreError.invalidRecord }
        let revision = try reserveRevision(kind: "chat", id: id)
        chat.costLimit = limit; chat.costLimitRevision = revision
        try put(chat, kind: "chat", id: id, revision: revision)
        return chat
    }
    /// Freeze the previous sidebar order once when upgrading older records.
    /// Later metadata writes (renaming, opening or changing a model) cannot move
    /// a chat unexpectedly. This only migrates desktop metadata, never journals.
    func loadChats(profiles: [ProfileRecord] = []) throws -> [ChatRecord] {
        let database = try ready()
        var statement: OpaquePointer?
        // Preserve the ordinary-chat window. Managed children are durable
        // members of a family, not competing roots: they must neither evict
        // their owner nor disappear behind this unrelated desktop limit.
        let query = """
            WITH chats AS (
                SELECT value,revision,id,CASE WHEN length(value)>524288 THEN NULL WHEN json_valid(CAST(value AS TEXT))
                    THEN json_type(CAST(value AS TEXT),'$.delegation') ELSE NULL END AS delegation
                FROM records WHERE kind='chat'
            ), roots AS (
                SELECT value,revision,id FROM chats WHERE delegation IS NOT 'object'
                ORDER BY revision DESC,id ASC LIMIT 10000
            )
            SELECT value,revision FROM (
                SELECT value,revision,id FROM roots UNION ALL
                SELECT value,revision,id FROM chats WHERE delegation='object'
            ) ORDER BY revision DESC,id ASC
            """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        var values: [(ChatRecord, Int64)] = []
        do {
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let size = Int(sqlite3_column_bytes(statement, 0))
                // One oversized or undecodable row (a record shape written by
                // another version) must not hide every other chat.
                if size <= 524_288, let bytes = sqlite3_column_blob(statement, 0) {
                    decodedChats += 1
                    if let chat = try? JSONDecoder().decode(ChatRecord.self, from: Data(bytes: bytes, count: size)) {
                        values.append((chat, sqlite3_column_int64(statement, 1)))
                    }
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw StoreError.unavailable }
        }
        values += try budgetAncestorRecords(of: values.map(\.0))
        unlistedChats = max(0, try count(kind: "chat") - values.count)
        return try migrateLoadedChats(values, profiles: profiles)
    }

    /// The complete durable graph, independent of the presentation window.
    /// Reads metadata only; discarded draft content is never materialized.
    func sideBudgetAncestry() throws -> [String: [String: [String]]] {
        let (records, present) = try durableChatGraph()
        var result: [String:[String:[String]]] = [:]
        for chat in records.values where !chat.isSubagent && chat.parentSessionID != nil {
            var current = chat, parents: [String] = [], seen: Set<String> = [chat.id], valid = true
            while let id = current.persistedBudgetParentID {
                guard seen.insert(id).inserted, parents.count < 128 else { valid = false; break }
                guard let parent = records[id] else {
                    // Undecodable metadata is not proof of deletion. Preserve
                    // its prior projection until the damaged record is repaired.
                    if present.contains(id) { valid = false }
                    break
                }
                guard parent.workspaceID == chat.workspaceID, !parent.isSubagent else { break }
                parents.append(id); current = parent
            }
            if valid { result[chat.workspaceID,default:[:]][chat.id] = parents }
        }
        return result
    }

    /// Saved sides at every depth below `owner`, from the complete durable
    /// graph, so sides outside the chat-list window go with their chat too.
    /// Parents precede their children. Forks are provenance, never members;
    /// a damaged intermediate record keeps its descendants out of the set.
    func savedSideDescendants(of owner: String, workspaceID: String) throws -> [(chat: ChatRecord, depth: Int)] {
        var records = try durableChatGraph().records
        // A side whose journal was published but whose chat row was never
        // registered keeps only its keep intent. It is still a saved side of
        // this family, and launch recovery would otherwise register it.
        for intent in try list(SideKeepIntent.self, kind: "side-keep") where records[intent.chat.id] == nil {
            guard try get(String.self, kind: "session-deleted", id: intent.chat.id) == nil else { continue }
            records[intent.chat.id] = intent.chat
        }
        var children: [String: [ChatRecord]] = [:]
        for chat in records.values where chat.workspaceID == workspaceID && !chat.isSubagent && !chat.imported {
            if let parent = chat.persistedBudgetParentID { children[parent, default: []].append(chat) }
        }
        var result: [(chat: ChatRecord, depth: Int)] = [], queue = [(owner, 0)], seen: Set<String> = [owner], next = 0
        while next < queue.count {
            let (id, depth) = queue[next]; next += 1
            guard depth < 128 else { continue }
            for child in (children[id] ?? []).sorted(by: { $0.id < $1.id }) where seen.insert(child.id).inserted {
                result.append((child, depth + 1)); queue.append((child.id, depth + 1))
            }
        }
        return result
    }

    /// Every decodable, non-deleted chat record, and the ids present at all.
    private func durableChatGraph() throws -> (records: [String: ChatRecord], present: Set<String>) {
        let database = try ready()
        var statement: OpaquePointer?
        let sql = "SELECT c.id,c.value FROM records c WHERE c.kind='chat' AND NOT EXISTS(SELECT 1 FROM records d WHERE d.kind='session-deleted' AND d.id=c.id)"
        guard sqlite3_prepare_v2(database,sql,-1,&statement,nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        var records: [String:ChatRecord] = [:], present = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let text = sqlite3_column_text(statement,0) {
                let id = String(cString:text); present.insert(id)
                let size = Int(sqlite3_column_bytes(statement,1))
                if size <= Self.recordByteLimit("chat"), let bytes = sqlite3_column_blob(statement,1),
                   let chat = try? JSONDecoder().decode(ChatRecord.self,from:Data(bytes:bytes,count:size)), chat.id == id { records[id] = chat }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw StoreError.unavailable }
        return (records, present)
    }

    /// Loaded sides and managed children retain their actual budget ancestry
    /// outside the ordinary chat window. A fork source is only provenance.
    /// Chat records by id, outside `loadChats`' window too: a paused side a
    /// family Resume must reach. Deleted, missing or unreadable ones are left out.
    func loadChats(ids: [String], profiles: [ProfileRecord] = []) throws -> [ChatRecord] {
        let database = try ready()
        var values: [(ChatRecord, Int64)] = []
        for id in Set(ids) {
            guard try get(String.self, kind: "session-deleted", id: id) == nil else { continue }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT value,revision FROM records WHERE kind='chat' AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { continue }
            guard result == SQLITE_ROW else { throw StoreError.unavailable }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= Self.recordByteLimit("chat"), let bytes = sqlite3_column_blob(statement, 0) else { continue }
            decodedChats += 1
            guard let chat = try? JSONDecoder().decode(ChatRecord.self, from: Data(bytes: bytes, count: size)), chat.id == id else { continue }
            values.append((chat, sqlite3_column_int64(statement, 1)))
        }
        return try migrateLoadedChats(values, profiles: profiles)
    }
    func loadBudgetAncestors(of chats: [ChatRecord], profiles: [ProfileRecord] = []) throws -> [ChatRecord] {
        try migrateLoadedChats(budgetAncestorRecords(of: chats), profiles: profiles)
    }
    private func budgetAncestorRecords(of chats: [ChatRecord]) throws -> [(ChatRecord, Int64)] {
        let database = try ready()
        var seen = Set(chats.map(\.id)), checked = Set<String>(), pending = chats, values: [(ChatRecord, Int64)] = []
        while let child = pending.popLast() {
            guard let id = child.persistedBudgetParentID, !seen.contains(id), checked.insert(child.workspaceID + "\u{0}" + id).inserted,
                  try get(String.self, kind: "session-deleted", id: id) == nil else { continue }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT value,revision FROM records WHERE kind='chat' AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { continue }
            guard result == SQLITE_ROW else { throw StoreError.unavailable }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= Self.recordByteLimit("chat"), let bytes = sqlite3_column_blob(statement, 0) else { continue }
            decodedChats += 1
            guard let parent = try? JSONDecoder().decode(ChatRecord.self, from: Data(bytes: bytes, count: size)),
                  parent.id == id, !parent.isSubagent, parent.workspaceID == child.workspaceID else { continue }
            seen.insert(id); values.append((parent, sqlite3_column_int64(statement, 1))); pending.append(parent)
        }
        return values
    }
    private func migrateLoadedChats(_ records: [(ChatRecord, Int64)], profiles: [ProfileRecord]) throws -> [ChatRecord] {
        var values = records
        var upgraded: [(ChatRecord, Int64)] = []
        for index in values.indices {
            let previous = values[index].0
            if values[index].0.sidebarOrder == nil { values[index].0.sidebarOrder = values[index].1 }
            if let profile = profiles.first(where: { $0.id == values[index].0.profileID }) {
                values[index].0.migrateOutputBudget(profile: profile)
            }
            if values[index].0 != previous { upgraded.append((values[index].0, values[index].1)) }
        }
        // The upgrade commits once. Per-chat commits cost one fsync each
        // (synchronous=FULL), which the first launch after an upgrade pays
        // before a single row of the sidebar can render.
        if !upgraded.isEmpty {
            try transaction { for (chat, revision) in upgraded { try put(chat, kind: "chat", id: chat.id, revision: revision) } }
        }
        return values.map(\.0).sorted(by: ChatRecord.sidebarPrecedes)
    }
    private func count(kind: String) throws -> Int {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM records WHERE kind=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.unavailable }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func updateChatOrganization(id: String, change: ChatOrganizationChange, now: Date = Date()) throws -> ChatRecord {
        let result = try updateChatOrganizations(ids: [id], change: change, now: now)
        guard let chat = result.records.first else { throw StoreError.invalidRecord }
        return chat
    }

    /// Validate every patch before writing. Missing/unsupported rows are reported
    /// individually; a storage failure rolls back the entire durable batch.
    /// Actor isolation prevents any await or concurrent writer inside this transaction.
    func updateChatOrganizations(ids: [String], change: ChatOrganizationChange, now: Date = Date()) throws -> ChatOrganizationBatch {
        guard !ids.isEmpty, ids.count <= 500, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw StoreError.invalidRecord }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try transaction {
            var result = ChatOrganizationBatch(), seen: Set<String> = []
            var family: Set<String> = []
            if case .archived = change {
                let owners = try ids.compactMap { try get(ChatRecord.self, kind: "chat", id: $0) }.filter { !$0.isSubagent }
                let projects = Dictionary(owners.map { ($0.id, $0.workspaceID) }, uniquingKeysWith: { first, _ in first })
                for row in try organizationRows() {
                    if let link = row.delegation, link.valid, link.childSessionID == row.id,
                       projects[link.budgetOwnerSessionID] == row.workspaceID { family.insert(row.id) }
                }
            }
            var patches: [ChatRecord] = []
            for id in ids + family.sorted() where seen.insert(id).inserted {
                do {
                    guard let original = try get(ChatRecord.self, kind: "chat", id: id) else { result.missing.insert(id); continue }
                    guard original.id == id, !original.isSubagent || family.contains(id) else { result.rejected.insert(id); continue }
                    var chat = original
                    try changeOrganization(&chat, change: change, now: now)
                    if chat == original { result.unchanged.insert(id) }
                    else {
                        chat.organizationRevision = try nextOrganizationRevision(original)
                        guard try JSONEncoder().encode(chat).count <= 524_288 else { throw StoreError.invalidRecord }
                        patches.append(chat)
                    }
                    result.records.append(chat)
                } catch StoreError.invalidRecord { result.rejected.insert(id) }
                  catch is DecodingError { result.rejected.insert(id) }
            }
            for chat in patches { try put(chat, kind: "chat", id: chat.id) }
            result.changed = Set(patches.map(\.id))
            return result
        }
        organizationCommits += 1
        var measured = result
        measured.transactionMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        return measured
    }

    private func changeOrganization(_ chat: inout ChatRecord, change: ChatOrganizationChange, now: Date) throws {
        switch change {
        case .title(let title):
            guard !chat.isBackgroundTask else { throw StoreError.invalidRecord }
            chat.title = try ChatRecord.normalizedTitle(title); chat.titleWasEdited = true; chat.titleWasGenerated = nil
        case .pinned(let pinned):
            chat.pinnedAt = pinned ? (chat.pinnedAt ?? now) : nil
        case .archived(let archived):
            chat.archivedAt = archived ? (chat.archivedAt ?? now) : nil
        }
    }
    private func nextOrganizationRevision(_ chat: ChatRecord) throws -> Int64 {
        let revision = chat.organizationRevision ?? 0
        guard revision >= 0, revision < Int64.max else { throw StoreError.invalidRecord }
        return revision + 1
    }

    func listTopics() throws -> [TopicRecord] {
        try list(TopicRecord.self, kind: TopicRecord.recordKind).filter { $0.isValid && $0.revision > 0 }.sorted(by: TopicRecord.sidebarPrecedes)
    }

    /// IDs are never reused after deletion: a delayed create or sidebar write
    /// cannot resurrect a removed topic, including across a process restart.
    func createTopic(_ proposed: TopicRecord) throws -> TopicRecord {
        try transaction {
            var topic = proposed
            topic.title = try TopicRecord.normalizedTitle(topic.title)
            guard topic.isValid, topic.revision == 0,
                  try get(TopicRecord.self, kind: TopicRecord.recordKind, id: topic.id) == nil,
                  try get(Int64.self, kind: TopicRecord.deletedRecordKind, id: topic.id) == nil else { throw StoreError.invalidRecord }
            topic.revision = try reserveRevision(kind: TopicRecord.recordKind, id: topic.id)
            try put(topic, kind: TopicRecord.recordKind, id: topic.id, revision: topic.revision)
            return topic
        }
    }

    func renameTopic(id: String, title: String) throws -> TopicRecord {
        try transaction {
            guard var topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: id), topic.isValid else { throw StoreError.invalidRecord }
            let normalized = try TopicRecord.normalizedTitle(title)
            guard topic.title != normalized else { return topic }
            topic.title = normalized
            topic.revision = try reserveRevision(kind: TopicRecord.recordKind, id: id)
            try put(topic, kind: TopicRecord.recordKind, id: id, revision: topic.revision)
            return topic
        }
    }

    func setTopicExpanded(id: String, expanded: Bool) throws -> TopicRecord {
        try transaction {
            guard var topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: id), topic.isValid else { throw StoreError.invalidRecord }
            guard topic.expanded != expanded else { return topic }
            topic.expanded = expanded
            topic.revision = try reserveRevision(kind: TopicRecord.recordKind, id: id)
            try put(topic, kind: TopicRecord.recordKind, id: id, revision: topic.revision)
            return topic
        }
    }

    /// Validate the whole drag selection before changing any membership. A
    /// cross-project drop never changes a chat's working directory or tools.
    func moveChatsToTopic(ids: Set<String>, workspaceID: String, topicID: String?) throws -> [ChatRecord] {
        try transaction {
            guard !ids.isEmpty, TopicRecord.isValidIdentifier(workspaceID), workspaceID != WorkspaceRecord.scratchID else { throw StoreError.invalidRecord }
            if let topicID {
                guard let topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: topicID),
                      topic.isValid, topic.workspaceID == workspaceID else { throw StoreError.invalidRecord }
            }
            var selected: [String: ChatRecord] = [:]
            for id in ids.sorted() {
                guard let chat = try get(ChatRecord.self, kind: "chat", id: id), chat.workspaceID == workspaceID,
                      !chat.isUtilityChat, !chat.isSubagent else { throw StoreError.invalidRecord }
                selected[id] = chat
            }
            // A kept side can commit just before its UI row is published.
            // Discover the durable family inside the same transaction, rather
            // than relying on a sidebar snapshot of the caller's descendants.
            var children: [String: [String]] = [:]
            for row in try organizationRows() where row.workspaceID == workspaceID && row.groupable {
                guard let parentID = row.parentSessionID else { continue }
                children[parentID, default: []].append(row.id)
            }
            var pending = ids.sorted()
            while let parentID = pending.popLast() {
                for childID in children[parentID] ?? [] where selected[childID] == nil {
                    // Only the descendants actually being moved are read in full.
                    guard let child = try get(ChatRecord.self, kind: "chat", id: childID) else { continue }
                    selected[childID] = child
                    pending.append(childID)
                }
            }
            var chats = selected.values.sorted { $0.id < $1.id }
            for index in chats.indices where chats[index].topicID != topicID {
                chats[index].topicID = topicID
                chats[index].organizationRevision = try nextOrganizationRevision(chats[index])
            }
            for chat in chats { try put(chat, kind: "chat", id: chat.id) }
            return chats
        }
    }

    /// A chat's last activity, moved forward only (`ChatRecord.lastActivityAt`).
    func noteChatActivity(id: String, at stamp: Int64) throws {
        try transaction {
            guard var chat = try get(ChatRecord.self, kind: "chat", id: id), stamp > (chat.lastActivityAt ?? .min) else { return }
            chat.lastActivityAt = stamp
            try put(chat, kind: "chat", id: id)
        }
    }

    /// Removing a group returns its sessions to the project. Journals, drafts,
    /// archives, pin order, parent links and running work are never deleted.
    func removeTopic(id: String) throws -> [ChatRecord] {
        try transaction {
            guard let topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: id), topic.isValid else { throw StoreError.invalidRecord }
            var members = try organizationRows().filter { $0.topicID == id }.compactMap { try get(ChatRecord.self, kind: "chat", id: $0.id) }
            for index in members.indices {
                members[index].topicID = nil
                members[index].organizationRevision = try nextOrganizationRevision(members[index])
            }
            let revision = try reserveRevision(kind: TopicRecord.recordKind, id: id)
            for chat in members { try put(chat, kind: "chat", id: chat.id) }
            try put(revision, kind: TopicRecord.deletedRecordKind, id: id, revision: revision)
            try remove(kind: TopicRecord.recordKind, id: id)
            return members
        }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        // Draft writes are told once they are committed, and not at all if rolled back.
        transactionDrafts = []
        do {
            let result = try operation()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            for (version, draft, revision) in transactionDraftVersions { version.committed(draft, revision: revision) }
            transactionDraftVersions.removeAll()
            flushTransactionDrafts()
            return result
        } catch {
            transactionDraftVersions.removeAll(); transactionDrafts = nil
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            let conflicts = transactionConflicts; transactionConflicts.removeAll()
            // The rejected operation must roll back, but its losing input
            // must commit before the error can release its caller/display.
            // A failed preservation keeps the version pinned for a retry.
            for version in conflicts { try preserveDraftConflicts(version) }
            throw error
        }
    }

    /// Just enough of every chat to decide membership: id, project, group and
    /// parent link. Grouping used to materialise every full ChatRecord in the
    /// database on every drop, which is most of what a drag costs.
    private struct OrganizationRow: Decodable {
        var id: String; var workspaceID: String; var topicID: String?; var parentSessionID: String?
        var delegation: SubagentLink?
        var backgroundTask: String?; var connectionTest: Bool?
        var pinnedAt: Date?; var archivedAt: Date?
        var isBackgroundTask: Bool { backgroundTask != nil }
        var groupable: Bool { !isBackgroundTask && connectionTest != true }
    }
    /// Organization must inspect every member, even when history exceeds the
    /// sidebar's list limit. Rows this build cannot read are skipped, exactly
    /// as `loadChats` skips them, so one of them cannot disable grouping.
    private func organizationRows() throws -> [OrganizationRow] {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM records WHERE kind='chat' ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        var values: [OrganizationRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            // A row this build cannot decode is not listed in the sidebar
            // either, so it has no group membership to preserve. Failing here
            // instead broke every drag into a topic and every topic deletion,
            // for every project, with no way to reach the offending chat.
            if size <= 524_288, let bytes = sqlite3_column_blob(statement, 0),
               let row = try? JSONDecoder().decode(OrganizationRow.self, from: Data(bytes: bytes, count: size)) {
                values.append(row)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.unavailable }
        return values
    }
    func list<T: Decodable & Sendable>(_ type: T.Type, kind: String) throws -> [T] {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM records WHERE kind=? ORDER BY revision DESC LIMIT 10000", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var values: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= Self.recordByteLimit(kind), let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
            if let value = try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: size)) { values.append(value) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.unavailable }
        return values
    }
    func get<T: Decodable & Sendable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw StoreError.unavailable }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard size <= Self.recordByteLimit(kind), let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
        if type == ChatRecord.self { decodedChats += 1 }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: size))
    }
    /// Everything opening a chat needs from this database, answered in one
    /// actor hop. Three sequential round-trips used to sit between a click and
    /// the chat's own journal read, each one a separate suspension of the main
    /// actor; the answers do not depend on each other.
    struct SelectionMetadata: Sendable {
        var draft: DraftRecord?
        var draftVersion: DraftVersion?
        var anchor: TranscriptAnchor?
        var anchorVersion: AnchorVersion?
        var conflicts: [SavedDraftConflict] = []
        var recovered: [CommandIntent] = []
    }
    func selectionMetadata(id: String, draft wantsDraft: Bool, anchor wantsAnchor: Bool) throws -> SelectionMetadata {
        var value = SelectionMetadata()
        if wantsDraft {
            let version = try draftVersion(id: id)
            value.draft = version.snapshot.draft; value.draftVersion = version
        }
        if wantsAnchor {
            let version = try anchorVersion(id: id)
            value.anchor = version.snapshot.anchor; value.anchorVersion = version
        }
        value.conflicts = try draftConflicts(id: id)
        value.recovered = try list(CommandIntent.self, kind: "pending:" + id)
        return value
    }
    func remove(kind: String, id: String) throws {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        if kind == "draft" { noteDraftWrite(id, false) }
    }
    func close() { attempted = true; connection?.close(); connection = nil }
    /// All rows, with no listing cap or forgiving decode: an unlisted draft
    /// or chat is still a reference. Raw bytes also cover displaced drafts
    /// and pending records from newer versions whose fields we do not know.
    func pastedImageReferences(root: URL) throws -> PastedImageReferences {
        let database = try ready(), token = try pastedImageReferenceToken()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT kind,value FROM records", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        var referenced: Set<String> = [], journals: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let kind = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { throw StoreError.invalidRecord }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            referenced.formUnion(PastedImageStorage.names(in: data))
            let name = String(cString: kind)
            let chat: ChatRecord?
            if name == "chat" { chat = try JSONDecoder().decode(ChatRecord.self, from: data) }
            else if name == "side-keep" || name == SideKeepIntent.retainedKind { chat = try JSONDecoder().decode(SideKeepIntent.self, from: data).chat }
            else { chat = nil }
            if let chat {
                let path = chat.path ?? root.appendingPathComponent("Workspaces/\(chat.workspaceID)/Sessions/\(chat.id).jsonl").path
                if chat.path != nil || FileManager.default.fileExists(atPath: path) { journals.insert(path) }
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.unavailable }
        guard try pastedImageReferenceToken() == token else { throw StoreError.staleRevision }
        return PastedImageReferences(token: token, names: referenced, journals: journals)
    }
    func pastedImageReferencesUnchanged(_ token: PastedImageReferenceToken) throws -> Bool { try pastedImageReferenceToken() == token }
    private func pastedImageReferenceToken() throws -> PastedImageReferenceToken {
        let database = try ready()
        guard let connection else { throw StoreError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.unavailable }
        // total_changes covers this writer, data_version covers another
        // connection, and identity makes a closed connection invalidate work.
        return .init(connection: connection.identity, changes: sqlite3_total_changes64(database), version: sqlite3_column_int64(statement, 0))
    }
    func removeAll(kind: String) throws { try prune(kind: kind, keeping: 0) }
    func prune(kind: String, keeping: Int) throws {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM records WHERE kind=? AND id NOT IN (SELECT id FROM records WHERE kind=? ORDER BY revision DESC LIMIT ?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, kind, -1, transient); sqlite3_bind_int(statement, 3, Int32(max(0, keeping)))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
    }
    /// A submission and the composer it left, in one commit (one sync of the
    /// journal): the record that lets a crash flag or recover the message,
    /// and the draft that no longer holds its text. Either both are on disk
    /// or neither is, so the text is never in neither place.
    func recordSubmission(_ intent: CommandIntent, draft: DraftRecord?, draftVersion: DraftVersion? = nil) throws {
        try transaction {
            do { if let draft { try put(draft, kind: "draft", id: draft.id, draftVersion: draftVersion) } }
            catch StoreError.draftConflict {
                // Its intent will roll back too. Keep the input that already
                // left the composer, as well as the remaining draft.
                draftVersion?.conflicted(DraftRecord(id: intent.sessionID, text: intent.text, attachments: intent.attachments, skills: intent.skills))
                throw StoreError.draftConflict
            }
            try put(intent, kind: "pending:\(intent.sessionID)", id: intent.id)
        }
    }
    /// A submission the helper never acted on went back into the composer:
    /// the draft that holds its text again and the end of its record, in one
    /// commit.
    func withdrawSubmission(sessionID: String, commandID: String, draft: DraftRecord?, draftVersion: DraftVersion? = nil) throws {
        try transaction {
            if let draft { try put(draft, kind: "draft", id: draft.id, draftVersion: draftVersion) }
            try remove(kind: "pending:\(sessionID)", id: commandID)
        }
    }
    func acknowledgeCommand(sessionID: String, commandID: String) throws {
        let kind = "pending:\(sessionID)"
        guard var intent = try get(CommandIntent.self, kind: kind, id: commandID) else { return }
        intent.state = "acknowledged"; try put(intent, kind: kind, id: commandID)
    }
    func preserveSubmissionReviews(sessionID: String, commands: Set<String>, draftVersion: DraftVersion? = nil) throws {
        // Read inside the actor: a review marker must never overwrite newer
        // typing with the draft a journal read started from.
        guard var draft = try get(DraftRecord.self, kind: "draft", id: sessionID) else { return }
        draft.requireSubmissionReview(commands)
        try put(draft, kind: "draft", id: sessionID, draftVersion: draftVersion)
    }
    @discardableResult func commitKeptSide(_ proposed: ChatRecord, draft: DraftRecord, expected: ChatRecord, draftVersion: DraftVersion? = nil) throws -> ChatRecord {
        try transaction {
            guard proposed.id == expected.id else { throw StoreError.staleRevision }
            let pending = try get(SideKeepIntent.self, kind: "side-keep", id: expected.id)
            if pending == nil {
                // Another registration may have won while this caller read the
                // header. A receipt proves which copy won; an ID alone cannot.
                // Return its current organization without touching newer typing.
                guard let completed = try sideKeepRegistration(id: expected.id),
                      completed.expected == expected else { throw StoreError.staleRevision }
                return completed.chat
            }
            // Identity reads suspend outside this transaction. Dismissal, a
            // replacement or another receipt may have consumed their intent.
            // Compare the captured intent before path/organization migration;
            // no chat or draft write is allowed without that exact pending copy.
            guard pending?.chat == expected else { throw StoreError.staleRevision }
            var chat = proposed
            if let existing = try get(ChatRecord.self, kind: "chat", id: chat.id) {
                // Replaying a keep receipt must preserve an independent rename
                // or topic move made after this child was first retained.
                chat.applyOrganization(from: existing)
            } else if let parentID = chat.parentSessionID {
                // Whichever commits first, moving a parent and publishing a new
                // side agree on the parent's current durable group. A fork has
                // no parentSessionID and keeps its captured topic instead.
                let parent = try get(ChatRecord.self, kind: "chat", id: parentID)
                chat.topicID = parent?.workspaceID == chat.workspaceID ? parent?.topicID : nil
            }
            try put(chat, kind: "chat", id: chat.id); try put(draft, kind: "draft", id: chat.id, draftVersion: draftVersion); try remove(kind: "side-keep", id: chat.id)
            try put(SideKeepRegistration(expected: expected, path: chat.path), kind: SideKeepRegistration.kind, id: chat.id)
            // The registered chat now owns this reference. Other dismissed
            // paths with the same ID remain independently protected.
            try remove(kind: SideKeepIntent.retainedKind, id: sideKeepRetentionID(expected))
            guard let saved = try get(ChatRecord.self, kind: "chat", id: chat.id) else { throw StoreError.invalidRecord }
            return saved
        }
    }
    /// A commit may precede its caller's sidebar publication. Read its receipt
    /// and current chat atomically, without treating a replacement as settled.
    func sideKeepState(id: String) throws -> SideKeepState {
        try transaction {
            if let pending = try get(SideKeepIntent.self, kind: "side-keep", id: id) { return .pending(pending) }
            if let completed = try sideKeepRegistration(id: id) { return .registered(chat: completed.chat, expected: completed.expected) }
            return .missing
        }
    }
    private func sideKeepRegistration(id: String) throws -> (chat: ChatRecord, expected: ChatRecord)? {
        guard let receipt = try get(SideKeepRegistration.self, kind: SideKeepRegistration.kind, id: id),
              let saved = try get(ChatRecord.self, kind: "chat", id: id),
              receipt.expected.id == id, saved.id == id,
              saved.workspaceID == receipt.expected.workspaceID, saved.path == receipt.path else { return nil }
        return (saved, receipt.expected)
    }
    private func sideKeepRetentionID(_ chat: ChatRecord) throws -> String {
        // Preserve each file, including replacements that reuse a chat ID.
        let identity = try JSONEncoder().encode([chat.workspaceID, chat.id, chat.path] as [String?])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    /// Only the exact pending copy reviewed by the confirmation can be
    /// dismissed. Keep its journal discoverable for attachment retention,
    /// without leaving an automatic-registration intent or changing its bytes.
    func dismissSideKeep(_ expected: ChatRecord) throws {
        try transaction {
            guard let current = try get(SideKeepIntent.self, kind: "side-keep", id: expected.id) else { return }
            guard current.chat == expected else { throw StoreError.staleRevision }
            try put(current, kind: SideKeepIntent.retainedKind, id: sideKeepRetentionID(current.chat))
            try remove(kind: "side-keep", id: expected.id)
        }
    }
    /// A handoff must never reappear as an empty chat after a partial write.
    func commitPortableHandoff(_ chat: ChatRecord, draft: DraftRecord, provenance: WireValue?) throws {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        transactionDrafts = []  // told once committed (`transaction`)
        do {
            try put(chat, kind: "chat", id: chat.id)
            try put(draft, kind: "draft", id: chat.id)
            if let provenance { try put(provenance, kind: "handoff", id: chat.id) }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            flushTransactionDrafts()
        } catch { transactionDrafts = nil; sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }
    /// Current and future chat choices commit together. A storage failure must
    /// not leave the picker and next-chat defaults disagreeing after restart.
    func saveChatModelChoice(_ chat: ChatRecord) throws {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            try put(chat, kind: "chat", id: chat.id)
            try put(ChatModelDefaults(chat: chat), kind: ChatModelDefaults.recordKind, id: chat.profileID)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Several chat records in one transaction, each written as `put` writes
    /// it: launch settling every background request a quit left, at once.
    /// Rebase discovery on the owner's latest durable organization in one
    /// actor turn. A delayed scan cannot restore a deleted or moved family.
    func beginFamilyDeletion(_ members: [SessionDeletionRecord], repairCompleted: Bool = false) throws {
        try transaction {
            guard let owner = members.first?.ownerID, members.contains(where: { $0.id == owner }),
                  Set(members.map(\.id)).count == members.count, Set(members.map(\.workspaceID)).count == 1,
                  members.allSatisfy({ $0.ownerID == owner && ($0.id == owner || ($0.sideDepth == nil ? UUID(uuidString: $0.id) != nil : $0.isSavedSide)) }) else { throw StoreError.invalidRecord }
            for var member in members {
                if member.id == owner { member.repairCompleted = repairCompleted ? true : nil }
                try put(owner, kind: "session-deleted", id: member.id)
                try put(member, kind: SessionDeletionRecord.kind, id: member.id)
            }
        }
    }

    func completeFamilyDeletionRepair(_ owner: String) throws {
        guard var record = try get(SessionDeletionRecord.self,kind:SessionDeletionRecord.kind,id:owner),
              record.id == owner, record.ownerID == owner,
              try get(String.self,kind:"session-deleted",id:owner) == owner else { throw StoreError.invalidRecord }
        record.repairCompleted = true
        try put(record,kind:SessionDeletionRecord.kind,id:owner)
    }

    /// Recovery must see the complete durable manifest, including families
    /// larger than the generic metadata listing's desktop window. A damaged
    /// intent fails closed instead of silently leaving a member behind.
    func pendingFamilyDeletions() throws -> [SessionDeletionRecord] {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM records WHERE kind=? ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, SessionDeletionRecord.kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var values: [SessionDeletionRecord] = [], result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= Self.recordByteLimit(SessionDeletionRecord.kind), let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
            values.append(try JSONDecoder().decode(SessionDeletionRecord.self, from: Data(bytes: bytes, count: size)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.unavailable }
        return values
    }

    func registerSubagent(_ found: DiscoveredSubagent, workspaceID: String) throws -> ChatRecord? {
        let header = found.header, link = header.link
        guard link.valid, try get(String.self, kind: "session-deleted", id: link.childSessionID) == nil,
              try get(String.self, kind: "session-deleted", id: link.budgetOwnerSessionID) == nil else { return nil }
        let parent = try get(ChatRecord.self, kind: "chat", id: link.budgetOwnerSessionID)
        let validParent = parent.flatMap { $0.workspaceID == workspaceID && !$0.isSubagent && !$0.imported ? $0 : nil }
        let issue = found.issue ?? (validParent == nil ? "The parent chat is unavailable. This saved sub-agent is view-only." : nil)
        let old = try get(ChatRecord.self, kind: "chat", id: link.childSessionID)
        // Directory discovery and live opening can spell the same validated
        // journal differently (/var and /private/var on macOS). Compare file
        // identity canonically without accepting a different journal or origin.
        let path = URL(fileURLWithPath: found.path).resolvingSymlinksInPath().path
        if let old { guard old.workspaceID == workspaceID, old.delegation == nil || old.delegation == link,
            old.path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == path else { throw StoreError.invalidRecord } }
        var child = old ?? ChatRecord(id: link.childSessionID, workspaceID: workspaceID, title: header.description, path: found.path,
            profileID: validParent?.profileID ?? "", toolMode: header.readOnly ? ChatRecord.readOnlyTools : ChatRecord.editingTools,
            model: header.model.model, thinkingLevel: header.model.thinkingLevel, contextWindow: header.model.contextWindow,
            maxOutputTokens: header.model.maxOutputTokens, modelOutputLimit: header.model.modelOutputLimit,
            parentSessionID: issue == nil ? link.budgetOwnerSessionID : nil, delegation: link)
        // Older desktop encoders drop unknown fields. The validated child
        // header and reciprocal parent plan rebuild an absent identity; a
        // conflicting identity or a different file still fails above.
        child.delegation = link
        if let number = found.number, number > 0 { child.subagentNumber = number }
        child.path = path
        // Small metadata preview; the complete task remains in the owner's
        // journal and the ordinary child's user message once it starts.
        if !found.task.isEmpty { child.delegationTask = String(found.task.prefix(4096)) }
        child.delegationIssue = issue ?? old?.delegationIssue
        if child.delegationIssue != nil { child.parentSessionID = nil }
        if let parent = validParent, child.delegationIssue == nil {
            child.archivedAt = parent.archivedAt; child.topicID = parent.topicID; child.pinnedAt = nil
            child.parentSessionID = parent.id
        }
        if child != old { try put(child, kind: "chat", id: child.id) }
        return child
    }

    func putChats(_ records: [ChatRecord]) throws {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            for record in records { try put(record, kind: "chat", id: record.id) }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Claim one title job atomically so rapid submissions/restarts cannot
    /// duplicate an auxiliary request. Creating a record never resends work.
    func createTitleTask(_ task: ChatRecord, sourceID: String) throws -> ChatRecord? {
        let database = try ready()
        guard task.id != sourceID, !task.id.isEmpty, task.id.utf8.count <= 128,
              task.backgroundTask == BackgroundRequestKind.title.raw, task.sourceSessionID == sourceID,
              task.workspaceID == WorkspaceRecord.scratchID, task.title == TitleGenerationPlan.fixedTitle,
              task.connectionTest == true, task.toolMode == ChatRecord.readOnlyTools, task.parentSessionID == nil,
              task.path == nil, !task.imported else { throw StoreError.invalidRecord }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            guard var source = try get(ChatRecord.self, kind: "chat", id: sourceID),
                  source.titleTaskSessionID == nil, source.titleWasEdited != true,
                  !source.isUtilityChat, !source.imported,
                  source.workspaceID != WorkspaceRecord.scratchID,
                  source.profileID == task.profileID,
                  try get(ChatRecord.self, kind: "chat", id: task.id) == nil else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil); return nil
            }
            source.titleTaskSessionID = task.id
            try put(source, kind: "chat", id: source.id); try put(task, kind: "chat", id: task.id)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            return source
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Releases a title claim whose task failed or no longer exists, so the
    /// source can be titled again. A task without a recorded failure keeps it.
    func releaseTitleTask(sourceID: String, taskID: String) throws -> Bool {
        guard var source = try get(ChatRecord.self, kind: "chat", id: sourceID), source.titleTaskSessionID == taskID, source.titleWasGenerated != true else { return false }
        if let task = try get(ChatRecord.self, kind: "chat", id: taskID), task.backgroundTaskNotice == nil { return false }
        source.titleTaskSessionID = nil
        try put(source, kind: "chat", id: sourceID, releasingTitleClaim: true)
        return true
    }
    func applyGeneratedTitle(_ title: String, sourceID: String, taskID: String) throws -> ChatRecord? {
        guard var source = try get(ChatRecord.self, kind: "chat", id: sourceID),
              source.titleTaskSessionID == taskID, source.titleWasEdited != true,
              !source.isBackgroundTask, title.count <= 80,
              let task = try get(ChatRecord.self, kind: "chat", id: taskID),
              task.backgroundTask == BackgroundRequestKind.title.raw, task.sourceSessionID == sourceID else { return nil }
        source.title = try ChatRecord.normalizedTitle(title); source.titleWasGenerated = true
        source.organizationRevision = try nextOrganizationRevision(source)
        try put(source, kind: "chat", id: source.id)
        return source
    }
}

struct WorkspaceRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String
    /// Primary root: the host's working directory and the workspace display name.
    var path: String
    var trusted: Bool
    /// Additional trusted folders. Absent in records written before multi-folder workspaces.
    var paths: [String] = []
    /// Every root, primary first, as sent to `workspace.open`.
    var roots: [String] { [path] + paths }
    /// Reserved id of the app-owned scratch workspace that hosts chats outside
    /// any project, such as connection tests. It never enters the vault.
    static let scratchID = "scratch"
    var isScratch: Bool { id == Self.scratchID }
    init(id: String, path: String, trusted: Bool, paths: [String] = []) { self.id = id; self.path = path; self.trusted = trusted; self.paths = paths }
    private enum CodingKeys: String, CodingKey { case id, path, trusted, paths }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        trusted = try container.decode(Bool.self, forKey: .trusted)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
    }
}
struct ChatRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String; var workspaceID: String; var title: String; var path: String?; var profileID: String; var toolMode: String = ChatRecord.editingTools; var imported = false; var connectionTest: Bool?
    /// Per-chat overrides of the profile route; nil keeps the profile defaults (contract H3/H6).
    var model: String?
    var thinkingLevel: String?
    /// Catalog-selected context capacity and independently requested output budget.
    var contextWindow: Int?
    var maxOutputTokens: Int?
    /// Supported model ceiling, never automatically used as a requested budget.
    var modelOutputLimit: Int?
    /// Older records stored catalog ceilings in maxOutputTokens. New records separate them.
    var outputBudgetVersion: Int? = 1
    /// Optional for records created before session organization was introduced.
    /// When the chat was made (µs since 1970); for records older than that,
    /// fixed once from the store's revision (`loadChats`).
    var sidebarOrder: Int64? = Int64(Date().timeIntervalSince1970 * 1_000_000)
    /// When the chat last had a message, a reply or a run change (µs since
    /// 1970), nil until it has. Only ever moves forward
    /// (`ChatRecordMerge.swift`, `MetadataStore.noteChatActivity`).
    var lastActivityAt: Int64?
    var pinnedAt: Date?
    var archivedAt: Date?
    var titleWasEdited: Bool?
    var titleWasGenerated: Bool?
    var titleTaskSessionID: String?
    /// A retained utility job has its own journal, capture and billing scope.
    var backgroundTask: String?
    var sourceSessionID: String?
    var backgroundTaskNotice: String?
    var isBackgroundTask: Bool { backgroundTask != nil }
    /// A chat the app runs for itself rather than the reader's: a background
    /// request or a connection test.
    var isUtilityChat: Bool { isBackgroundTask || connectionTest == true }
    /// A background request's own account (`BackgroundRequests.swift`): when
    /// it was sent and ended, how it ended ("completed", "failed" or
    /// "interrupted"; nil while it runs), and what it produced (the title, the
    /// suggestions one per line, or the notification's parameters). Records
    /// written before these existed have none; launch reads their outcome
    /// from what they left.
    var backgroundTaskStartedAt: Date?
    var backgroundTaskEndedAt: Date?
    var backgroundTaskOutcome: String?
    var backgroundTaskResult: String?
    var organizationRevision: Int64?
    /// Optional for existing sessions; topics never change project ownership.
    var topicID: String?
    /// Saved side conversations keep their parent relationship across restarts.
    /// Independent forks and ordinary chats have no parent.
    var parentSessionID: String?
    /// Managed task identity. Unlike a side, this chat has no independent input.
    var delegation: SubagentLink?
    /// A cache of the unique accepted start's position in the parent journal.
    /// Never an execution identity; old records rebuild it during discovery.
    var subagentNumber: Int?
    var delegationTask: String?
    var delegationIssue: String?
    var isSubagent: Bool { delegation != nil }
    /// This chat's own cost limit; nil runs it under the Settings default.
    var costLimit: CostLimit?
    var costLimitRevision: Int64?
    /// True when this chat sends no webhook when it finishes; nil follows Settings.
    var webhookOff: Bool?
    /// When the chat's connection last changed (`WorkspaceConnectionSwitch.swift`):
    /// a copy read before then does not take the change back (`ChatRecordMerge.swift`).
    var connectionRevision: Int64?
    /// True while the chat's journal may still be bound to another connection
    /// than the one this record names, after a switch that did not finish:
    /// the chat's next open binds it here first.
    var journalRebind: Bool?
    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }
    /// What a new chat is called until its first message names it.
    static let defaultTitle = "New chat"
    /// `toolMode`: tools that may change the project, as every chat has
    /// until the reader chooses otherwise, or only ones that read it (a side
    /// until it is kept, a connection test, a background request).
    static let editingTools = "editing", readOnlyTools = "read-only"
    mutating func migrateOutputBudget(profile: ProfileRecord) {
        guard outputBudgetVersion == nil else { return }
        if !isBackgroundTask, let legacyCeiling = maxOutputTokens {
            modelOutputLimit = legacyCeiling
            maxOutputTokens = min(profile.maxOutputTokens, legacyCeiling, max(1, (contextWindow ?? profile.contextWindow) - 1))
        }
        outputBudgetVersion = 1
    }
    /// When anything last happened in this chat, for the sidebar's order:
    /// its last message, reply or run change, or else when it was made.
    var activityStamp: Int64 { max(lastActivityAt ?? 0, sidebarOrder ?? 0) }
    /// The sidebar's order, the same in every group: pinned chats first, then
    /// newest activity first (`activityStamp`). There is no order of the
    /// reader's own any more: records written while there was keep a
    /// `manualSidebarOrder` key, which nothing reads.
    static func sidebarPrecedes(_ lhs: ChatRecord, _ rhs: ChatRecord) -> Bool {
        sidebarPrecedes(lhs, rhs, activity: lhs.activityStamp, rhs.activityStamp)
    }
    /// The same order, with the activity each side is sorted by given: the
    /// sidebar holds a chat's place while the reader is pointing at it.
    static func sidebarPrecedes(_ lhs: ChatRecord, _ rhs: ChatRecord, activity a: Int64, _ b: Int64) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if a != b { return a > b }
        return lhs.id < rhs.id
    }
    static func normalizedTitle(_ title: String) throws -> String {
        let trimmed = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !trimmed.isEmpty else { throw HostError.failure("Enter a title for this chat.") }
        return String(trimmed.prefix(120))
    }
    /// The connection `other` names, with the model choices made against it.
    mutating func applyConnection(from other: ChatRecord) {
        profileID = other.profileID; model = other.model; thinkingLevel = other.thinkingLevel
        contextWindow = other.contextWindow; maxOutputTokens = other.maxOutputTokens
        modelOutputLimit = other.modelOutputLimit; outputBudgetVersion = other.outputBudgetVersion
        connectionRevision = other.connectionRevision; journalRebind = other.journalRebind
    }
    mutating func applyOrganization(from other: ChatRecord) {
        pinnedAt = other.pinnedAt; archivedAt = other.archivedAt; topicID = other.topicID
        titleWasEdited = other.titleWasEdited; titleWasGenerated = other.titleWasGenerated; organizationRevision = other.organizationRevision
        if other.titleWasEdited == true || other.titleWasGenerated == true { title = other.title }
    }
}
/// Keys with a default (`toolMode`, `imported`) may be missing from a row
/// another version wrote; the synthesized decoder required them, so such a
/// chat was skipped and left out of the sidebar. Every other key reads as
/// the synthesized decoder reads it: an absent optional is nil (the upgrades
/// in `loadChats` fill `sidebarOrder` and `outputBudgetVersion` in), and a
/// key with no default stays required. Encoding is the synthesized one.
extension ChatRecord {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); workspaceID = try c.decode(String.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title); path = try c.decodeIfPresent(String.self, forKey: .path)
        profileID = try c.decode(String.self, forKey: .profileID)
        toolMode = try c.decodeIfPresent(String.self, forKey: .toolMode) ?? ChatRecord.editingTools
        imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        connectionTest = try c.decodeIfPresent(Bool.self, forKey: .connectionTest)
        model = try c.decodeIfPresent(String.self, forKey: .model); thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow); maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        modelOutputLimit = try c.decodeIfPresent(Int.self, forKey: .modelOutputLimit)
        outputBudgetVersion = try c.decodeIfPresent(Int.self, forKey: .outputBudgetVersion)
        sidebarOrder = try c.decodeIfPresent(Int64.self, forKey: .sidebarOrder); lastActivityAt = try c.decodeIfPresent(Int64.self, forKey: .lastActivityAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt); archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        titleWasEdited = try c.decodeIfPresent(Bool.self, forKey: .titleWasEdited); titleWasGenerated = try c.decodeIfPresent(Bool.self, forKey: .titleWasGenerated)
        titleTaskSessionID = try c.decodeIfPresent(String.self, forKey: .titleTaskSessionID)
        backgroundTask = try c.decodeIfPresent(String.self, forKey: .backgroundTask); sourceSessionID = try c.decodeIfPresent(String.self, forKey: .sourceSessionID)
        backgroundTaskNotice = try c.decodeIfPresent(String.self, forKey: .backgroundTaskNotice)
        backgroundTaskStartedAt = try c.decodeIfPresent(Date.self, forKey: .backgroundTaskStartedAt); backgroundTaskEndedAt = try c.decodeIfPresent(Date.self, forKey: .backgroundTaskEndedAt)
        backgroundTaskOutcome = try c.decodeIfPresent(String.self, forKey: .backgroundTaskOutcome); backgroundTaskResult = try c.decodeIfPresent(String.self, forKey: .backgroundTaskResult)
        organizationRevision = try c.decodeIfPresent(Int64.self, forKey: .organizationRevision); topicID = try c.decodeIfPresent(String.self, forKey: .topicID)
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID); costLimit = try c.decodeIfPresent(CostLimit.self, forKey: .costLimit)
        delegation = try c.decodeIfPresent(SubagentLink.self, forKey: .delegation)
        subagentNumber = try c.decodeIfPresent(Int.self, forKey: .subagentNumber).flatMap { $0 > 0 ? $0 : nil }
        delegationTask = try c.decodeIfPresent(String.self, forKey: .delegationTask)
        delegationIssue = try c.decodeIfPresent(String.self, forKey: .delegationIssue)
        costLimitRevision = try c.decodeIfPresent(Int64.self, forKey: .costLimitRevision)
        webhookOff = try c.decodeIfPresent(Bool.self, forKey: .webhookOff); connectionRevision = try c.decodeIfPresent(Int64.self, forKey: .connectionRevision)
        journalRebind = try c.decodeIfPresent(Bool.self, forKey: .journalRebind)
    }
}
enum ChatOrganizationChange: Sendable { case title(String), pinned(Bool), archived(Bool) }
struct ChatOrganizationBatch: Sendable {
    var records: [ChatRecord] = []
    var changed: Set<String> = []
    var missing: Set<String> = []
    var unchanged: Set<String> = []
    var rejected: Set<String> = []
    var transactionMilliseconds: Double = 0
}
struct DraftRecord: Codable, Sendable, Equatable {
    var id: String; var text: String; var attachments: [AttachmentRecord]?; var skills: [SkillChip]?
    /// An edit remains an edit after a restart, and its displaced draft remains recoverable.
    var edit: MessageEditDraft?
    /// A queued message being rewritten when this was saved: the rewrite
    /// typed so far, which a reopen reconciles with the helper's hold. The
    /// record's own text, images and skills are the draft set aside for it.
    var queuedEdit: QueuedEditDraft?
    /// Returned input may already have run. This gate belongs to the draft,
    /// not the transient run state or the helper's bounded receipt list.
    var submissionReviews: Set<String>?
    func hasSameContents(as other: DraftRecord) -> Bool {
        func normalized(_ draft: DraftRecord) -> DraftRecord {
            var value = draft
            value.attachments = value.attachments ?? []; value.skills = value.skills ?? []
            value.submissionReviews = value.submissionReviews ?? []
            if var edit = value.edit {
                edit.originalAttachments = edit.originalAttachments ?? []; edit.originalSkills = edit.originalSkills ?? []
                edit.originalSubmissionReviews = edit.originalSubmissionReviews ?? []
                edit.inputReviewRequired = edit.inputReviewRequired ?? false; value.edit = edit
            }
            return value
        }
        return normalized(self) == normalized(other)
    }
    /// Unsent work the sidebar marks (a draft marker): text, an image or a
    /// skill in the composer, the draft an edit of an earlier message set
    /// aside, or a queued message being rewritten (not merely opened).
    var holdsUnsentDraft: Bool {
        if !isBlank { return true }
        if edit != nil, !displaced.isBlank { return true }
        if let queued = queuedEdit, queued.beginOnly != true, !queued.isOriginal(queued.rewrite) { return true }
        return false
    }
    /// Nothing typed: no text but spaces, no image, no skill.
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (attachments ?? []).isEmpty && (skills ?? []).isEmpty }
    /// `other` added to this draft: its text after this one's, a blank line
    /// between, its images and skills after these, one already here not
    /// added twice. Nothing is dropped at the submission limits: a composer
    /// past them is the reader's to trim, which Send says.
    /// The draft as the reader left it outside an edit: the one an earlier
    /// message's edit displaced, while it is edited, else this one.
    var displaced: DraftRecord {
        guard let edit else { return self }
        return DraftRecord(id: id, text: edit.originalText, attachments: edit.originalAttachments, skills: edit.originalSkills, submissionReviews: edit.originalSubmissionReviews)
    }
    /// `other` added to the draft the reader left: into the one an edit
    /// displaced while there is an edit, which ending it brings back.
    func receiving(_ other: DraftRecord) -> DraftRecord {
        guard var edit else { return merging(other) }
        let merged = displaced.merging(other)
        edit.originalText = merged.text; edit.originalAttachments = merged.attachments; edit.originalSkills = merged.skills
        edit.originalSubmissionReviews = merged.submissionReviews
        var record = self; record.edit = edit; return record
    }
    /// Whether this holds all of `other`: its text from the start, and every
    /// image and skill it has.
    func holds(_ other: DraftRecord) -> Bool {
        text.hasPrefix(other.text) && (other.attachments ?? []).allSatisfy { image in (attachments ?? []).contains { $0.id == image.id } }
            && (other.skills ?? []).allSatisfy { chip in (skills ?? []).contains { $0.id == chip.id } }
            && (other.submissionReviews ?? []).isSubset(of: submissionReviews ?? [])
    }
    func merging(_ other: DraftRecord) -> DraftRecord {
        var merged = self
        let added = other.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !added.isEmpty { merged.text += (text.isEmpty ? "" : "\n\n") + added }
        var images = attachments ?? []
        for image in other.attachments ?? [] where !images.contains(where: { $0.id == image.id }) { images.append(image) }
        var chips = skills ?? []
        for chip in other.skills ?? [] where !chips.contains(where: { $0.id == chip.id }) { chips.append(chip) }
        merged.attachments = images.isEmpty && attachments == nil ? nil : images
        merged.skills = chips.isEmpty && skills == nil ? nil : chips
        let reviews = (submissionReviews ?? []).union(other.submissionReviews ?? [])
        merged.submissionReviews = reviews.isEmpty ? nil : reviews
        return merged
    }
    mutating func requireSubmissionReview(_ commands: Set<String>) {
        if !isBlank { submissionReviews = (submissionReviews ?? []).union(commands) }
        if var edit, !displaced.isBlank { edit.originalSubmissionReviews = (edit.originalSubmissionReviews ?? []).union(commands); self.edit = edit }
    }
}
struct QueuedEditDraft: Codable, Sendable, Equatable {
    var editID: String
    var turnID: String
    /// The rewrite as last saved, and the digest of the message as it was
    /// when the edit began (the helper holds the message itself).
    var rewrite: String
    var originalDigest: String
    /// A Begin that got no answer: there is no rewrite yet, only the edit to ask after.
    var beginOnly: Bool? = nil
    /// A Save, Cancel or Remove sent and not yet answered, and the digest of
    /// the text a Save sent: a reopen asks after it, and only it may be retried.
    var pending: String? = nil
    var sentDigest: String? = nil
    init(editID: String, turnID: String, rewrite: String, original: String, beginOnly: Bool? = nil, pending: String? = nil, sent: String? = nil) {
        self.editID = editID; self.turnID = turnID; self.rewrite = rewrite
        originalDigest = QueuedEditDraft.digest(original.trimmingCharacters(in: .whitespacesAndNewlines))
        self.beginOnly = beginOnly; self.pending = pending; sentDigest = sent.map(QueuedEditDraft.digest)
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// Whether `text` is the message as it was when the edit began.
    func isOriginal(_ text: String) -> Bool { Self.digest(text.trimmingCharacters(in: .whitespacesAndNewlines)) == originalDigest }
}
struct MessageEditDraft: Codable, Sendable, Equatable {
    var messageID: String
    var originalText: String
    var originalAttachments: [AttachmentRecord]?
    var originalSkills: [SkillChip]?
    var sourceTimeline: String? = nil
    var sourceTextDigest: String? = nil
    var inputReviewRequired: Bool? = nil
    var originalSubmissionReviews: Set<String>? = nil
}
struct CommandIntent: Codable, Sendable, Equatable {
    var id: String; var sessionID: String; var turnID: String; var text: String; var state: String; var epoch: String?; var attachments: [AttachmentRecord]?; var skills: [SkillChip]?
    /// New sends persist their own draft review gate before returning input.
    /// Older records cannot distinguish returned input from newer typing.
    var draftReviewTracked: Bool? = nil
}
struct ProfileRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String = UUID().uuidString; var revision: String = UUID().uuidString
    var name: String = "LiteLLM connection"; var providerId: String = "litellm"
    var modelId: String = "" { didSet { if modelId != oldValue { modelOutputLimit = nil } } }
    var api: String = "openai-responses"; var baseUrl: String = ""
    var contextWindow: Int = 128_000; var maxOutputTokens: Int = 4096
    /// Catalog capability; maxOutputTokens is the configured request budget.
    var modelOutputLimit: Int?
    var advancedJSON: String?
    /// Optional custom model catalog; nil/blank uses the bundled Bello catalog.
    var catalogUrl: String?
    /// Separate utility-model choice. Nil uses an active catalog mini default,
    /// if supplied; it never silently substitutes the conversation model.
    var miniModelId: String?
    var isImported: Bool { configuration["source"]?.object != nil }
    var configuration: [String: WireValue] { guard let data = advancedJSON?.data(using: .utf8) else { return [:] }; return (try? JSONDecoder().decode(WireValue.self, from: data).object) ?? [:] }
    var wire: WireValue {
        var value = configuration
        value.merge(["id": .string(id), "revision": .string(revision), "providerId": .string(providerId), "modelId": .string(modelId), "api": .string(api), "baseUrl": .string(baseUrl), "contextWindow": .number(Double(contextWindow)), "maxOutputTokens": .number(Double(maxOutputTokens))]) { _, new in new }
        if let modelOutputLimit { value["modelOutputLimit"] = .number(Double(modelOutputLimit)) }
        else { value.removeValue(forKey: "modelOutputLimit") }
        return .object(value)
    }
}

struct CapturePreference: Codable, Sendable { var mode: String; var since: String }
