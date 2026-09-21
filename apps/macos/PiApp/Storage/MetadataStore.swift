import Foundation
import SQLite3

enum StoreError: Error, Equatable, LocalizedError {
    case unavailable, invalidRecord, staleRevision
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
        case .unreadableRecord: "This conversation file could not be read. Its bytes were left untouched."
        case .missingJournal(let path): "The conversation file is no longer at \(path). Nothing was written in its place."
        }
    }
}

/// Owned only by MetadataStore. SQLite calls remain actor-isolated; the wrapper
/// also releases the handle when initialization throws or the actor is dropped.
private final class MetadataDatabase {
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
actor MetadataStore {
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
    func put<T: Encodable & Sendable>(_ value: T, kind: String, id: String, revision: Int64? = nil, releasingTitleClaim: Bool = false) throws {
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
            if let previous = try get(ChatRecord.self, kind: kind, id: id) {
                // Path/model/turn updates can finish after a rename, pin,
                // archive or topic move. They must not restore stale grouping.
                if (previous.organizationRevision ?? 0) > (chat.organizationRevision ?? 0) { chat.applyOrganization(from: previous) }
                if chat.sidebarOrder == nil { chat.sidebarOrder = previous.sidebarOrder }
                if chat.parentSessionID == nil { chat.parentSessionID = previous.parentSessionID }
                // Only the explicit release path may drop a title claim; other
                // writes that omit it keep the running task's claim intact.
                if chat.titleTaskSessionID == nil, !releasingTitleClaim { chat.titleTaskSessionID = previous.titleTaskSessionID }
                if previous.isBackgroundTask {
                    chat.title = previous.title; chat.backgroundTask = previous.backgroundTask; chat.sourceSessionID = previous.sourceSessionID
                    if chat.backgroundTaskNotice == nil { chat.backgroundTaskNotice = previous.backgroundTaskNotice }
                }
            }
            if let topicID = chat.topicID {
                let topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: topicID)
                if topic?.workspaceID != chat.workspaceID || topic?.isValid != true
                    || chat.workspaceID == WorkspaceRecord.scratchID || chat.isBackgroundTask || chat.connectionTest == true {
                    // A send/fork can finish after its group is removed. Keep
                    // the durable path/model write and leave that chat ungrouped.
                    chat.topicID = nil
                }
            }
            data = try JSONEncoder().encode(chat)
        } else { data = try JSONEncoder().encode(value) }
        guard data.count <= 524_288 else { throw StoreError.invalidRecord }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO records VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET value=excluded.value,revision=excluded.revision WHERE excluded.revision>=records.revision", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_int64(statement, 4, savedRevision)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        guard sqlite3_changes(database) == 1 else { throw StoreError.staleRevision }
        if kind.hasPrefix("receipt:") { try prune(kind: kind, keeping: 128) }
    }
    /// Freeze the previous sidebar order once when upgrading older records.
    /// Later metadata writes (renaming, opening or changing a model) cannot move
    /// a chat unexpectedly. This only migrates desktop metadata, never journals.
    func loadChats(profiles: [ProfileRecord] = []) throws -> [ChatRecord] {
        let database = try ready()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value,revision FROM records WHERE kind='chat' ORDER BY revision DESC,id ASC LIMIT 10000", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
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
        unlistedChats = max(0, try count(kind: "chat") - values.count)
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
            var patches: [ChatRecord] = []
            for id in ids where seen.insert(id).inserted {
                do {
                    guard let original = try get(ChatRecord.self, kind: "chat", id: id) else { result.missing.insert(id); continue }
                    guard original.id == id else { result.rejected.insert(id); continue }
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
            if chat.isPinned != pinned { chat.manualSidebarOrder = nil }
            chat.pinnedAt = pinned ? (chat.pinnedAt ?? now) : nil
        case .archived(let archived):
            if chat.isArchived != archived { chat.manualSidebarOrder = nil }
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
                      !chat.isBackgroundTask, chat.connectionTest != true else { throw StoreError.invalidRecord }
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
                chats[index].topicID = topicID; chats[index].manualSidebarOrder = nil
                chats[index].organizationRevision = try nextOrganizationRevision(chats[index])
            }
            for chat in chats { try put(chat, kind: "chat", id: chat.id) }
            return chats
        }
    }

    /// A single atomic organization update; later stale title/path writes keep
    /// these ranks through applyOrganization, just as they preserve pin/archive.
    func reorderChats(_ ids: [String], relativeTo targetID: String, after: Bool, workspaceID: String) throws -> [ChatRecord] {
        try transaction {
            guard !ids.isEmpty, !ids.contains(targetID), Set(ids).count == ids.count,
                  let target = try get(ChatRecord.self, kind: "chat", id: targetID), target.workspaceID == workspaceID,
                  !target.isBackgroundTask, target.connectionTest != true else { throw StoreError.invalidRecord }
            let selected = Set(ids)
            var group = try organizationRows().filter {
                $0.workspaceID == workspaceID && $0.groupable && $0.topicID == target.topicID &&
                ($0.pinnedAt != nil || $0.parentSessionID == target.parentSessionID) &&
                ($0.pinnedAt != nil) == target.isPinned && ($0.archivedAt != nil) == target.isArchived
            }.compactMap { try? get(ChatRecord.self, kind: "chat", id: $0.id) }.sorted(by: ChatRecord.sidebarPrecedes)
            guard selected.isSubset(of: Set(group.map(\.id))) else { throw HostError.failure("Reorder chats within the same topic, parent and pinned group. Drop on a topic header to move between topics.") }
            let moving = group.filter { selected.contains($0.id) }; group.removeAll { selected.contains($0.id) }
            guard let index = group.firstIndex(where: { $0.id == targetID }) else { throw StoreError.invalidRecord }
            group.insert(contentsOf: moving, at: index + (after ? 1 : 0))
            for index in group.indices {
                group[index].manualSidebarOrder = index
                group[index].organizationRevision = try nextOrganizationRevision(group[index])
                try put(group[index], kind: "chat", id: group[index].id)
            }
            return group
        }
    }

    /// Removing a group returns its sessions to the project. Journals, drafts,
    /// archives, pin order, parent links and running work are never deleted.
    func removeTopic(id: String) throws -> [ChatRecord] {
        try transaction {
            guard let topic = try get(TopicRecord.self, kind: TopicRecord.recordKind, id: id), topic.isValid else { throw StoreError.invalidRecord }
            var members = try organizationRows().filter { $0.topicID == id }.compactMap { try get(ChatRecord.self, kind: "chat", id: $0.id) }
            for index in members.indices {
                members[index].topicID = nil; members[index].manualSidebarOrder = nil
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
        do {
            let result = try operation()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            return result
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Just enough of every chat to decide membership: id, project, group and
    /// parent link. Grouping used to materialise every full ChatRecord in the
    /// database on every drop, which is most of what a drag costs.
    private struct OrganizationRow: Decodable {
        var id: String; var workspaceID: String; var topicID: String?; var parentSessionID: String?
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
            guard size <= 524_288, let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
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
        guard size <= 524_288, let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.invalidRecord }
        if type == ChatRecord.self { decodedChats += 1 }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: size))
    }
    /// Everything opening a chat needs from this database, answered in one
    /// actor hop. Three sequential round-trips used to sit between a click and
    /// the chat's own journal read, each one a separate suspension of the main
    /// actor; the answers do not depend on each other.
    struct SelectionMetadata: Sendable {
        var draft: DraftRecord?
        var anchor: TranscriptAnchor?
        var recovered: [CommandIntent] = []
    }
    func selectionMetadata(id: String, draft wantsDraft: Bool, anchor wantsAnchor: Bool) throws -> SelectionMetadata {
        var value = SelectionMetadata()
        if wantsDraft { value.draft = try get(DraftRecord.self, kind: "draft", id: id) }
        if wantsAnchor { value.anchor = try get(TranscriptAnchor.self, kind: "anchor", id: id) }
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
    }
    func close() { attempted = true; connection?.close(); connection = nil }
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
    func acknowledgeCommand(sessionID: String, commandID: String) throws {
        let kind = "pending:\(sessionID)"
        guard var intent = try get(CommandIntent.self, kind: kind, id: commandID) else { return }
        intent.state = "acknowledged"; try put(intent, kind: kind, id: commandID)
    }
    @discardableResult func commitKeptSide(_ proposed: ChatRecord, draft: DraftRecord) throws -> ChatRecord {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
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
            try put(chat, kind: "chat", id: chat.id); try put(draft, kind: "draft", id: chat.id); try remove(kind: "side-keep", id: chat.id)
            guard let saved = try get(ChatRecord.self, kind: "chat", id: chat.id) else { throw StoreError.invalidRecord }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
            return saved
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }
    /// A handoff must never reappear as an empty chat after a partial write.
    func commitPortableHandoff(_ chat: ChatRecord, draft: DraftRecord, provenance: WireValue?) throws {
        let database = try ready()
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            try put(chat, kind: "chat", id: chat.id)
            try put(draft, kind: "draft", id: chat.id)
            if let provenance { try put(provenance, kind: "handoff", id: chat.id) }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
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

    /// Claim one title job atomically so rapid submissions/restarts cannot
    /// duplicate an auxiliary request. Creating a record never resends work.
    func createTitleTask(_ task: ChatRecord, sourceID: String) throws -> ChatRecord? {
        let database = try ready()
        guard task.id != sourceID, !task.id.isEmpty, task.id.utf8.count <= 128,
              task.backgroundTask == "session-title", task.sourceSessionID == sourceID,
              task.workspaceID == WorkspaceRecord.scratchID, task.title == TitleGenerationPlan.fixedTitle,
              task.connectionTest == true, task.toolMode == "read-only", task.parentSessionID == nil,
              task.path == nil, !task.imported else { throw StoreError.invalidRecord }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            guard var source = try get(ChatRecord.self, kind: "chat", id: sourceID),
                  source.titleTaskSessionID == nil, source.titleWasEdited != true,
                  !source.isBackgroundTask, source.connectionTest != true, !source.imported,
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
              task.backgroundTask == "session-title", task.sourceSessionID == sourceID else { return nil }
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
    var id: String; var workspaceID: String; var title: String; var path: String?; var profileID: String; var toolMode: String = "editing"; var imported = false; var connectionTest: Bool?
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
    var sidebarOrder: Int64? = Int64(Date().timeIntervalSince1970 * 1_000_000)
    var manualSidebarOrder: Int?
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
    var organizationRevision: Int64?
    /// Optional for existing sessions; topics never change project ownership.
    var topicID: String?
    /// Saved side conversations keep their parent relationship across restarts.
    /// Independent forks and ordinary chats have no parent.
    var parentSessionID: String?
    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }
    mutating func migrateOutputBudget(profile: ProfileRecord) {
        guard outputBudgetVersion == nil else { return }
        if !isBackgroundTask, let legacyCeiling = maxOutputTokens {
            modelOutputLimit = legacyCeiling
            maxOutputTokens = min(profile.maxOutputTokens, legacyCeiling, max(1, (contextWindow ?? profile.contextWindow) - 1))
        }
        outputBudgetVersion = 1
    }
    static func sidebarPrecedes(_ lhs: ChatRecord, _ rhs: ChatRecord) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.manualSidebarOrder != nil || rhs.manualSidebarOrder != nil {
            // Newly created chats remain above an explicitly ordered group.
            if lhs.manualSidebarOrder == nil { return true }
            if rhs.manualSidebarOrder == nil { return false }
            if lhs.manualSidebarOrder != rhs.manualSidebarOrder { return lhs.manualSidebarOrder! < rhs.manualSidebarOrder! }
        }
        if let a = lhs.pinnedAt, let b = rhs.pinnedAt, a != b { return a < b }
        let a = lhs.sidebarOrder ?? 0, b = rhs.sidebarOrder ?? 0
        if a != b { return a > b }
        return lhs.id < rhs.id
    }
    static func normalizedTitle(_ title: String) throws -> String {
        let trimmed = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !trimmed.isEmpty else { throw HostError.failure("Enter a title for this chat.") }
        return String(trimmed.prefix(120))
    }
    mutating func applyOrganization(from other: ChatRecord) {
        pinnedAt = other.pinnedAt; archivedAt = other.archivedAt; topicID = other.topicID; manualSidebarOrder = other.manualSidebarOrder
        titleWasEdited = other.titleWasEdited; titleWasGenerated = other.titleWasGenerated; organizationRevision = other.organizationRevision
        if other.titleWasEdited == true || other.titleWasGenerated == true { title = other.title }
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
struct DraftRecord: Codable, Sendable {
    var id: String; var text: String; var attachments: [AttachmentRecord]?; var skills: [SkillChip]?
    /// An edit remains an edit after a restart, and its displaced draft remains recoverable.
    var edit: MessageEditDraft?
}
struct MessageEditDraft: Codable, Sendable {
    var messageID: String
    var originalText: String
    var originalAttachments: [AttachmentRecord]?
    var originalSkills: [SkillChip]?
    var sourceTimeline: String? = nil
    var sourceTextDigest: String? = nil
    var inputReviewRequired: Bool? = nil
}
struct CommandIntent: Codable, Sendable, Equatable { var id: String; var sessionID: String; var turnID: String; var text: String; var state: String; var epoch: String?; var attachments: [AttachmentRecord]?; var skills: [SkillChip]? }
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
