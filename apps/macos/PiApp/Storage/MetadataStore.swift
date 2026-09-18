import Foundation
import SQLite3

enum StoreError: Error, Equatable, LocalizedError {
    case unavailable, invalidRecord, staleRevision
    var errorDescription: String? {
        switch self {
        case .unavailable: "Desktop storage is unavailable."
        case .invalidRecord: "The desktop record could not be saved."
        case .staleRevision: "A newer version of this desktop record has already been saved."
        }
    }
}

// Native is SQLite's only writer. JSON documents are small desktop metadata;
// authoritative conversation messages and raw capture bodies never enter this database.
actor MetadataStore {
    private var database: OpaquePointer?
    private var lastReservedRevision: Int64 = 0
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw StoreError.unavailable }
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000; CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(kind,id));", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Reserve before an asynchronous debounce. Persisted revisions, rather
    /// than the wall clock alone, keep edits ordered across clock corrections.
    func reserveRevision(kind: String, id: String) throws -> Int64 {
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
        let revision = try revision ?? reserveRevision(kind: kind, id: id)
        let data: Data
        if kind == "chat", var chat = value as? ChatRecord, let previous = try get(ChatRecord.self, kind: kind, id: id) {
            // Path/model/turn updates can finish after a rename, pin or archive.
            // Those unrelated writes must not restore a stale organization state.
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
            data = try JSONEncoder().encode(chat)
        } else { data = try JSONEncoder().encode(value) }
        guard data.count <= 524_288 else { throw StoreError.invalidRecord }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO records VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET value=excluded.value,revision=excluded.revision WHERE excluded.revision>=records.revision", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_int64(statement, 4, revision)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        guard sqlite3_changes(database) == 1 else { throw StoreError.staleRevision }
        if kind.hasPrefix("receipt:") { try prune(kind: kind, keeping: 128) }
    }
    /// Freeze the previous sidebar order once when upgrading older records.
    /// Later metadata writes (renaming, opening or changing a model) cannot move
    /// a chat unexpectedly. This only migrates desktop metadata, never journals.
    func loadChats(profiles: [ProfileRecord] = []) throws -> [ChatRecord] {
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
                if size <= 524_288, let bytes = sqlite3_column_blob(statement, 0),
                   let chat = try? JSONDecoder().decode(ChatRecord.self, from: Data(bytes: bytes, count: size)) {
                    values.append((chat, sqlite3_column_int64(statement, 1)))
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw StoreError.unavailable }
        }
        for index in values.indices {
            let previous = values[index].0
            if values[index].0.sidebarOrder == nil { values[index].0.sidebarOrder = values[index].1 }
            if let profile = profiles.first(where: { $0.id == values[index].0.profileID }) {
                values[index].0.migrateOutputBudget(profile: profile)
            }
            if values[index].0 != previous { try put(values[index].0, kind: "chat", id: values[index].0.id, revision: values[index].1) }
        }
        return values.map(\.0).sorted(by: ChatRecord.sidebarPrecedes)
    }
    func updateChatOrganization(id: String, change: ChatOrganizationChange, now: Date = Date()) throws -> ChatRecord {
        guard var chat = try get(ChatRecord.self, kind: "chat", id: id) else { throw StoreError.invalidRecord }
        switch change {
        case .title(let title):
            guard !chat.isBackgroundTask else { throw StoreError.invalidRecord }
            chat.title = try ChatRecord.normalizedTitle(title); chat.titleWasEdited = true; chat.titleWasGenerated = nil
        case .pinned(let pinned): chat.pinnedAt = pinned ? (chat.pinnedAt ?? now) : nil
        case .archived(let archived): chat.archivedAt = archived ? (chat.archivedAt ?? now) : nil
        }
        chat.organizationRevision = (chat.organizationRevision ?? 0) + 1
        try put(chat, kind: "chat", id: id)
        return chat
    }
    func list<T: Decodable & Sendable>(_ type: T.Type, kind: String) throws -> [T] {
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
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: size))
    }
    func remove(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
    }
    func close() { sqlite3_close(database); database = nil }
    func removeAll(kind: String) throws { try prune(kind: kind, keeping: 0) }
    func prune(kind: String, keeping: Int) throws {
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
    func commitKeptSide(_ chat: ChatRecord, draft: DraftRecord) throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        do {
            try put(chat, kind: "chat", id: chat.id); try put(draft, kind: "draft", id: chat.id); try remove(kind: "side-keep", id: chat.id)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }
    /// A handoff must never reappear as an empty chat after a partial write.
    func commitPortableHandoff(_ chat: ChatRecord, draft: DraftRecord, provenance: WireValue?) throws {
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
        source.organizationRevision = (source.organizationRevision ?? 0) + 1
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
        pinnedAt = other.pinnedAt; archivedAt = other.archivedAt
        titleWasEdited = other.titleWasEdited; titleWasGenerated = other.titleWasGenerated; organizationRevision = other.organizationRevision
        if other.titleWasEdited == true || other.titleWasGenerated == true { title = other.title }
    }
}
enum ChatOrganizationChange: Sendable { case title(String), pinned(Bool), archived(Bool) }
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
