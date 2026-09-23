import Foundation
import Darwin
import CryptoKit

struct HistoryPage: Sendable {
    var messages: [TranscriptMessage]; var before: String?; var total: Int
    /// The journal is damaged or truncated: Continue and search need an
    /// explicit validation or recovery first.
    var notice: String?
    /// The journal is intact but longer than one index can hold. Browsing,
    /// search and copying all work on the part that was indexed; this says so.
    var limitNotice: String? = nil
    var assistantMessageCount: Int? = nil
    var latestAssistantMessageID: String? = nil
    var failureMessage: String? = nil
    var revision: HistoryRevision? = nil
    var incarnation: String? = nil
    var lineage: String? = nil
    var older: ConversationCursor? = nil
    var newer: ConversationCursor? = nil
    var partialTurnInput: String? = nil
    var taskRecords: [TaskPresentationRecord] = []
}

/// The journal identity used for a retained display, including replacements
/// with the same path, length and modification time. It never retains bodies.
struct HistoryRevision: Equatable, Sendable {
    let path: String
    let stamp: String
}

// Read-only archive browsing does not launch an agent runtime.
// First index record offsets and parent links; decode only the requested page.
actor HistoryReader {
    /// A journal that is no longer where its chat says it is must say so. The
    /// caller's "original files were preserved" is a false claim about a file
    /// that is not there.
    private func open(_ path: String) throws -> FileHandle {
        do { return try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw StoreError.missingJournal(path)
        }
    }
    private typealias Ref = HistoryOffset
    private struct IndexRecord: Decodable {
        var type: String?; var id: String?; var parentId: String?
        var fromMessageId: String?; var keptIds: [String]?; var nativeKeptIDs: [String]?; var contextIDs: [String]?
        var version: Int?; var customType: String?; var pendingWork: PendingWork?
        var nativeCompactionVersion: Int?; var nativeCompaction: Checkpoint?
        var historicalBranch: HistoricalBranch?; var selectedTimeline: [String]?
        var presentationTarget: String?
        var taskTerminal: TaskPresentationRecord?
        struct Checkpoint: Decodable { var operationId: String?; var version: Int; var sourceIDs: [String]; var protectedIDs: [String]; var keptIDs: [String]; var dependencyIDs: [String]?; var summarySourceIDs: [String]? }
        struct PendingItem: Decodable {}
        struct PendingWork: Decodable {
            var active: Bool?; var queue: [PendingItem]?; var steering: [PendingItem]?
            var runStatus: String?; var errorMessage: String?
            var exists: Bool { active == true || !(queue ?? []).isEmpty || !(steering ?? []).isEmpty }
            var failure: String? {
                guard active != true, runStatus == "failed" else { return nil }
                let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return detail.isEmpty ? "Run failed." : detail
            }
        }
        struct MessageRole: Decodable {
            struct Block: Decodable { var type: String?; var id: String? }
            var role: String?; var toolCallId: String?; var calls: [String]; var contentIndexed: Bool; var nativeReplayEligible: Bool?
            var nativeKind: String?; var nativeOperationID: String?; var nativeCompaction: Checkpoint?
            private enum CodingKeys: String, CodingKey { case role, toolCallId, content, nativeReplayEligible, nativeKind, nativeCompaction, nativeOperationID }
            init(from decoder: Decoder) throws {
                let value = try decoder.container(keyedBy: CodingKeys.self)
                role = try value.decodeIfPresent(String.self, forKey: .role)
                toolCallId = try value.decodeIfPresent(String.self, forKey: .toolCallId)
                nativeReplayEligible = try value.decodeIfPresent(Bool.self, forKey: .nativeReplayEligible)
                nativeKind = try value.decodeIfPresent(String.self, forKey: .nativeKind)
                nativeOperationID = try value.decodeIfPresent(String.self, forKey: .nativeOperationID)
                nativeCompaction = try value.decodeIfPresent(Checkpoint.self, forKey: .nativeCompaction)
                // String-form user content is valid. Only normalized call IDs
                // are indexed; text/provider content is never retained here.
                let blocks = try? value.decode([Block].self, forKey: .content)
                calls = (blocks ?? []).filter { $0.type == "toolCall" }.map { $0.id ?? "" }
                // A malformed mixed array can still contain a helper-visible
                // call. Preserve browsing, but do not auto-open unknown content.
                contentIndexed = blocks != nil || (try? value.decode(String.self, forKey: .content)) != nil
            }
        }
        var message: MessageRole?
        private struct ContextSelection: Decodable { var ids: [String]?; var visibleIDs: [String]? }
        private enum CodingKeys: String, CodingKey { case type, id, parentId, fromMessageId, keptIds, nativeKeptIDs, version, customType, nativeState, data, message, nativeCompactionVersion, nativeCompaction, nativeBranchVersion }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            type = try value.decodeIfPresent(String.self, forKey: .type); id = try value.decodeIfPresent(String.self, forKey: .id)
            parentId = try value.decodeIfPresent(String.self, forKey: .parentId)
            fromMessageId = try value.decodeIfPresent(String.self, forKey: .fromMessageId); keptIds = try value.decodeIfPresent([String].self, forKey: .keptIds)
            nativeKeptIDs = try value.decodeIfPresent([String].self, forKey: .nativeKeptIDs)
            nativeCompactionVersion = try value.decodeIfPresent(Int.self, forKey: .nativeCompactionVersion)
            nativeCompaction = try value.decodeIfPresent(Checkpoint.self, forKey: .nativeCompaction)
            version = try value.decodeIfPresent(Int.self, forKey: .version); customType = try value.decodeIfPresent(String.self, forKey: .customType)
            message = try value.decodeIfPresent(MessageRole.self, forKey: .message)
            if type == "branch" {
                pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .nativeState)
                if value.contains(.nativeBranchVersion) { historicalBranch = try HistoricalBranch(from: decoder) }
            }
            else if customType == "pi-app.native.state.v1" { pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .data) }
            else if customType == "pi-app.presentation.update.v1" {
                struct Target: Decodable { var id: String }
                presentationTarget = try value.decode(Target.self, forKey: .data).id
            }
            else if customType == "pi-app.task-terminal.v1" {
                let task = try value.decode(TaskPresentationRecord.self, forKey:.data)
                guard task.valid, task.terminal else { throw StoreError.unreadableRecord }
                taskTerminal = task
            }
            if customType == "pi-app.native.context.v1" {
                let selection = try value.decodeIfPresent(ContextSelection.self, forKey: .data)
                contextIDs = selection?.ids ?? []; selectedTimeline = selection?.visibleIDs
            }
        }
    }
    private static let branchText = "Edited from here · earlier replies stay in the journal"
    private struct Stamp: Equatable {
        var device: Int32; var inode: UInt64; var size: Int64; var modified: Int; var modifiedNS: Int; var changed: Int; var changedNS: Int
    }
    private struct Index { var stamp: Stamp; var branch: HistoryOffsetIndex; var assistantCount: Int; var latestAssistantID: String?; var sessionID: String?; var automaticContextSafe: Bool; var failureMessage: String?; var taskRecords: [TaskPresentationRecord] }
    private var indexes: [String: Index] = [:]
    // As many bounded offset indexes as the workspace keeps transcript pages, so
    // cycling between open chats does not re-index a large journal each time.
    // Offsets and parent links only; no history bodies.
    private static let retainedIndexes = 8
    private var recency: [String] = []
    private var digests: [String: (stamp: Stamp, bytes: UInt64, digest: String)] = [:]
    private func fingerprint(_ file: FileHandle, bytes: UInt64) throws -> String {
        try file.seek(toOffset: 0)
        var hash = SHA256(), read: UInt64 = 0
        while read < bytes {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: Int(min(65_536, bytes - read))), !data.isEmpty else { throw StoreError.unreadableRecord }
            hash.update(data: data); read += UInt64(data.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Paging a large record used to decode it again for every 16 KiB page, and
    /// `message()` rescanned the whole journal on top of that. One slot is
    /// enough: every caller pages one record to its end before moving on.
    private struct RecordKey: Equatable { var path: String; var stamp: Stamp; var id: String; var field: String }
    private var decoded: (key: RecordKey, text: NSString)?
    // MARK: Test seams
    //
    // What a read cost, in decodes and retained indexes, and the one knob that
    // lowers a bound so a test can reach it. Each is an addition or a stored
    // integer; none of them does anything when nothing reads it.

    /// Journal records fully decoded for paging. Tests pin paging cost with it:
    /// one page used to cost a full decode of its record, and `message()` a
    /// full decode of every record in the file before it.
    private(set) var decodedRecords = 0
    private(set) var indexedRecordCount = 0
    private(set) var indexedBytes: UInt64 = 0
    /// Journals whose offset index is currently retained.
    var retainedIndexCount: Int { recency.count }
    /// Progress/cancellation segment size, never a source EOF or record limit.
    /// Lowered in tests to exercise traversal across segment boundaries.
    private var indexRecordLimit = 100_000
    func setIndexRecordLimit(_ value: Int) { indexRecordLimit = max(1, value); indexes.removeAll(); recency.removeAll() }
    /// The projection each caller asks for, from one decoded journal record.
    private static func projection(_ value: [String: WireValue], field: String) -> String {
        let message = value["message"]?.object ?? [:]
        let content = message["content"], blocks = content?.array ?? []
        if field != "thinking", ["execution", "requestLedger"].contains(message["nativeKind"]?.string ?? "") {
            return ConversationContent.text(value)
        }
        if field != "thinking", value["type"]?.string == "branch" { return branchText }
        if field != "thinking", value["type"]?.string == "compaction" { return "Conversation summary:\n" + (value["summary"]?.string ?? "") }
        if field == "thinking" { return blocks.compactMap { $0.object?["type"]?.string == "thinking" ? $0.object?["thinking"]?.string : nil }.joined() }
        return value["message"]?.object?["nativeDisplayText"]?.string ?? content?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
    }
    private func revision(_ stamp: Stamp) -> String { "\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.modified):\(stamp.modifiedNS):\(stamp.changed):\(stamp.changedNS)" }
    private func content(_ ref: Ref, file: FileHandle) throws -> String {
        if ref.type == "branch" { return "## Edit\n\n" + Self.branchText + "\n\n" }
        decodedRecords += 1
        try file.seek(toOffset: ref.offset)
        guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length else { throw StoreError.unreadableRecord }
        return ConversationContent.text(try JSONDecoder().decode(WireValue.self, from: bytes).object ?? [:])
    }
    func editTarget(path: String, id: String) throws -> [String: WireValue] {
        let page = try read(path: path, around: id, targetTurns: 1)
        guard page.notice == nil, let index = indexes[path], try index.branch.index(of: id) != nil,
              let ref = try index.branch.ref(id), ref.type == "message", ref.role == "user" else {
            throw HostError.failure("The editable user message is unavailable, abandoned, or its history needs recovery.")
        }
        let file = try open(path); defer { try? file.close() }
        guard try stamp(file) == index.stamp else { throw StoreError.unreadableRecord }
        try file.seek(toOffset: ref.offset)
        guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length else { throw StoreError.unreadableRecord }
        let record = try JSONDecoder().decode(WireValue.self, from: bytes).object ?? [:], message = record["message"]?.object ?? [:]
        let text = Self.projection(record, field: "text")
        guard text.utf8.count <= 262_144, try stamp(file) == index.stamp else { throw HostError.failure("The original input is too large or changed during loading.") }
        let blocks = message["content"]?.array ?? []
        let expanded = message["content"]?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
        return ["messageId": .string(id), "text": .string(text), "sourceTimeline": .string(EditReplayPlan.digest(try index.branch.timelineIDs())),
                "sourceTextDigest": .string(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()),
                "input": message["nativeUserInput"] ?? .null,
                "legacyInputs": .bool(message["nativeUserInput"] == nil && (expanded != text || blocks.contains { $0.object?["type"]?.string == "image" }))]
    }
    func searchContent(path: String, query: String, start: Int) throws -> ContentSearch {
        guard query.count <= 256, start >= 0 else { throw StoreError.unreadableRecord }
        let page = try read(path: path)
        guard page.notice == nil, let index = indexes[path] else { throw HostError.failure("Validate or recover damaged history before searching it") }
        let file = try open(path); defer { try? file.close() }
        guard try stamp(file) == index.stamp else { throw StoreError.unreadableRecord }
        // A query that matches nothing used to decode every record in the
        // conversation before answering. Stop after a bounded window and let the
        // caller continue from `next`, exactly as a full page of hits does.
        let limit = min(index.branch.count, min(start, index.branch.count) + 5_000)
        var hits: [ContentHit] = [], cursor = min(start, index.branch.count)
        while cursor < limit && hits.count < 100 {
            let ref = try index.branch.at(cursor), text = try content(ref, file: file)
            if query.isEmpty { hits.append(.init(id: ref.id, position: cursor + 1, preview: String(text.prefix(240)))) }
            else if let range = text.range(of: query, options: [.caseInsensitive]) {
                let from = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                hits.append(.init(id: ref.id, position: cursor + 1, preview: String(text[from...].prefix(240))))
            }
            cursor += 1
        }
        guard try stamp(file) == index.stamp else { throw StoreError.unreadableRecord }
        return .init(hits: hits, total: index.branch.count, next: cursor < index.branch.count ? cursor : nil, revision: revision(index.stamp))
    }
    func copyContentPage(path: String, first: Int, last: Int, cursor: ContentCursor, revision expected: String) throws -> ContentPage {
        let file = try open(path); defer { try? file.close() }
        guard let index = indexes[path], try stamp(file) == index.stamp, revision(index.stamp) == expected else { throw HostError.failure("History changed. Refresh the range before copying") }
        guard first >= 1, last >= first, last <= index.branch.count, cursor.index >= first, cursor.index <= last else { throw StoreError.unreadableRecord }
        let ref = try index.branch.at(cursor.index - 1)
        let key = RecordKey(path: path, stamp: index.stamp, id: ref.id, field: "conversation")
        let full: NSString
        if let decoded, decoded.key == key { full = decoded.text }
        else { full = try content(ref, file: file) as NSString; decoded = (key, full) }
        let text = try UnicodePage.slice(full, offset: cursor.offset), end = cursor.offset + (text as NSString).length
        guard try stamp(file) == index.stamp else { throw StoreError.unreadableRecord }
        return .init(text: text, next: end < full.length ? .init(index: cursor.index, offset: end) : cursor.index < last ? .init(index: cursor.index + 1, offset: 0) : nil)
    }
    private func stamp(_ file: FileHandle) throws -> Stamp {
        var value = stat(); guard fstat(file.fileDescriptor, &value) == 0 else { throw StoreError.unreadableRecord }
        return Stamp(device: value.st_dev, inode: value.st_ino, size: value.st_size, modified: value.st_mtimespec.tv_sec, modifiedNS: value.st_mtimespec.tv_nsec, changed: value.st_ctimespec.tv_sec, changedNS: value.st_ctimespec.tv_nsec)
    }
    func validateIdentity(path: String, id: String) throws {
        let file = try open(path); defer { try? file.close() }
        guard let bytes = try file.read(upToCount: 65_536), let newline = bytes.firstIndex(of: 10) else { throw StoreError.unreadableRecord }
        let header = try JSONDecoder().decode(WireValue.self, from: bytes[..<newline]).object ?? [:]
        guard header["type"]?.string == "session", header["id"]?.string == id, header["version"]?.number == 3, try read(path: path).notice == nil else { throw StoreError.unreadableRecord }
    }
    /// Auto context must not open a runtime that would repair an interrupted
    /// tool call or restore pending work. Explicit inspection/recovery remains
    /// separate. The same bounded, stamped index used for browsing supplies this.
    func allowsAutomaticContext(path: String, id: String) throws -> Bool {
        let page = try read(path: path)
        guard page.notice == nil, let index = indexes[path], index.sessionID == id else { return false }
        return index.automaticContextSafe
    }
    func message(path: String, id: String, field: String, offset: Int) throws -> (String, Int) {
        let file = try open(path); defer { try? file.close() }
        let identity = try stamp(file)
        let key = RecordKey(path: path, stamp: identity, id: id, field: field)
        if let decoded, decoded.key == key { return (try UnicodePage.slice(decoded.text, offset: offset), decoded.text.length) }
        guard try file.seekToEnd() <= 134_217_728 else { throw StoreError.unreadableRecord }
        // The stamped index already knows where this record starts and how long
        // it is. Rescanning and decoding the whole journal per page made editing
        // one large message cost one full decode of the file for every page.
        if let index = indexes[path], index.stamp == identity, let position = try index.branch.index(of: id) {
            let ref = try index.branch.at(position)
            try file.seek(toOffset: ref.offset)
            guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length,
                  let value = try? JSONDecoder().decode(WireValue.self, from: bytes).object else { throw StoreError.unreadableRecord }
            guard try stamp(file) == identity else { throw StoreError.unreadableRecord }
            decodedRecords += 1
            let text = Self.projection(value, field: field) as NSString
            decoded = (key, text)
            return (try UnicodePage.slice(text, offset: offset), text.length)
        }
        try file.seek(toOffset: 0)
        var pending = Data(), position: UInt64 = 0
        var presentation: [String: WireValue]?
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                try Task.checkCancellation()
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                // A damaged neighbour must not hide a readable message, and a
                // record written without an id is addressed by its offset — the
                // same identity the page that displayed it was given.
                if let value = try? JSONDecoder().decode(WireValue.self, from: pending).object,
                   value["type"]?.string != "session", (value["id"]?.string ?? "record-\(position)") == id ||
                    (value["customType"]?.string == "pi-app.presentation.update.v1" && value["data"]?.object?["id"]?.string == id && presentation != nil) {
                    if ["execution", "requestLedger"].contains(value["message"]?.object?["nativeKind"]?.string ?? "") {
                        presentation = value
                    } else {
                    decodedRecords += 1
                    let text = Self.projection(value, field: field) as NSString
                    decoded = (key, text)
                    return (try UnicodePage.slice(text, offset: offset), text.length)
                    }
                }
                position += UInt64(pending.count + 1); pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        if let presentation {
            guard try stamp(file) == identity else { throw StoreError.unreadableRecord }
            decodedRecords += 1
            let text = Self.projection(presentation, field: field) as NSString
            decoded = (key, text)
            return (try UnicodePage.slice(text, offset: offset), text.length)
        }
        throw HostError.failure("The retained message is unavailable")
    }
    /// Returning to an already loaded chat should keep its page and reading
    /// position. A cheap descriptor stamp works even after its offset index was
    /// evicted; an appended/replaced/edited journal still takes the full reader.
    func readIfChanged(path: String, since previous: HistoryRevision?) throws -> HistoryPage? {
        if let previous, previous.path == path {
            let file = try open(path); defer { try? file.close() }
            if revision(try stamp(file)) == previous.stamp { return nil }
        }
        return try read(path: path)
    }
    typealias Progress = @Sendable (_ records: Int, _ bytes: UInt64, _ total: UInt64) -> Void
    func window(path: String, cursor: ConversationCursor? = nil, newer: Bool = false, around: String? = nil, progress: Progress? = nil) throws -> HistoryPage {
        try read(path: path, before: newer ? nil : cursor?.entry, around: around,
                 after: newer ? cursor?.entry : nil, targetTurns: HistoryWindowPolicy.turns, expected: cursor, progress: progress)
    }
    func read(path: String, before: String? = nil, around: String? = nil, after: String? = nil,
              targetTurns: Int? = nil, expected: ConversationCursor? = nil, progress: Progress? = nil) throws -> HistoryPage {
        try Task.checkCancellation()
        let file = try open(path); defer { try? file.close() }
        let identity = try stamp(file)
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard size <= 134_217_728 else { throw StoreError.unreadableRecord }
        let branch: HistoryOffsetIndex
        if let cached = indexes[path], cached.stamp == identity { branch = cached.branch }
        else { branch = try HistoryOffsetIndex() }
        var notice: String?, assistantCount = 0, latestAssistantID: String?, failureMessage: String?
        var taskRecords: [TaskPresentationRecord] = []
        if let cached = indexes[path], cached.stamp == identity {
            assistantCount = cached.assistantCount; latestAssistantID = cached.latestAssistantID
            failureMessage = cached.failureMessage
            taskRecords = cached.taskRecords
            if targetTurns != nil && cached.sessionID == nil { notice = "History has no valid session header. Its source was left untouched." }
        }
        else {
        indexes.removeValue(forKey: path)
        var pending = Data(), offset: UInt64 = 0, leaf: String?
        var sessionID: String?, native = false, linear = true, pendingWork = false
        var contextIDs: Set<String> = [], contextMessages: [String: (calls: [String], result: String?)] = [:]
        var orderedContext: [String] = [], roles: [String: String] = [:]
        var replayNodes: [String: ReplayNode] = [:], selectedTimeline: [String] = []
        var contextSafe = true, callCount = 0
        var progressAt = ProcessInfo.processInfo.systemUptime
        var presentationOperations: [String:String] = [:]
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                try Task.checkCancellation()
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                do {
                    let value = try JSONDecoder().decode(IndexRecord.self, from: pending)
                    if value.type == "session", offset == 0, value.version == 3 { sessionID = value.id }
                    if value.customType == "pi-app.native.v1" { native = true }
                    if let work = value.pendingWork { pendingWork = work.exists; failureMessage = work.failure }
                    if let task = value.taskTerminal {
                        taskRecords.removeAll { $0.key == task.key }; taskRecords.append(task)
                        if taskRecords.count > 64 { taskRecords.removeFirst() }
                    }
                    if value.type != "session" {
                        let id = value.id ?? "record-\(offset)"
                        guard try branch.ref(id) == nil else { throw StoreError.unreadableRecord }
                        // A work segment is a cancellation boundary, not EOF.
                        if branch.recordCount % indexRecordLimit == 0 { try Task.checkCancellation() }
                        indexedRecordCount = branch.recordCount; indexedBytes = offset
                        let parent = value.id == nil ? leaf : value.parentId
                        if value.id == nil || parent != leaf { linear = false }
                        if let parent, try branch.ref(parent) == nil { throw StoreError.unreadableRecord }
                        try branch.insert(Ref(id: id, parent: parent, offset: offset, length: pending.count, type: value.type,
                                       fromMessageID: value.fromMessageId, keptIDs: value.keptIds, role: value.message?.role, presentation:["execution","requestLedger"].contains(value.message?.nativeKind ?? ""), selectedPrefix: value.historicalBranch?.selectedTimelinePrefix, contextSelection: value.contextIDs.map { EditReplayPlan.forkTimeline(visible: selectedTimeline, boundary: $0) }))
                        if let target = value.presentationTarget {
                            guard var original = try branch.ref(target), original.presentation else { throw StoreError.unreadableRecord }
                            original.offset = offset; original.length = pending.count
                            try branch.replaceMetadata(original)
                        }
                        if let operation = value.message?.nativeOperationID, value.type == "message" { presentationOperations[operation] = id }
                        if value.type == "compaction", let operation = value.nativeCompaction?.operationId, let target = presentationOperations[operation], var original = try branch.ref(target) {
                            original.adopted = true; try branch.replaceMetadata(original)
                        }
                        // Replay only the active context's compact tool metadata.
                        // A result in an abandoned branch cannot prove that an
                        // active call is paired and safe to resume without repair.
                        if value.type == "message" {
                            let calls = value.message?.calls ?? []
                            if value.message?.contentIndexed != true { contextSafe = false }
                            callCount += calls.count
                            if callCount > 100_000 { contextSafe = false }
                            contextMessages[id] = (callCount <= 100_000 ? calls : [], value.message?.role == "toolResult" ? value.message?.toolCallId : nil)
                            roles[id]=value.message?.role
                            replayNodes[id] = ReplayNode(id: id, role: value.message?.role ?? "", eligible: value.message?.nativeReplayEligible != false,
                                summary: value.message?.nativeKind == "compaction", dependencies: value.message?.nativeCompaction?.dependencyIDs, summarized: value.message?.nativeCompaction?.summarySourceIDs,
                                calls: calls, result: value.message?.toolCallId)
                            selectedTimeline.append(id)
                            if value.message?.nativeReplayEligible != false { contextIDs.insert(id); orderedContext.append(id) }
                        } else if value.type == "compaction" {
                            let kept=value.nativeKeptIDs ?? [], keptSet=Set(kept)
                            guard keptSet.count==kept.count, keptSet.isSubset(of:contextIDs) else { throw StoreError.unreadableRecord }
                            if value.nativeCompactionVersion != nil || value.nativeCompaction != nil {
                                guard value.nativeCompactionVersion==2, let checkpoint=value.nativeCompaction, checkpoint.version==2,
                                      checkpoint.sourceIDs==orderedContext, checkpoint.keptIDs==kept else { throw StoreError.unreadableRecord }
                                let protected=Set(checkpoint.protectedIDs)
                                guard protected.count==checkpoint.protectedIDs.count,
                                      Array(kept.prefix(protected.count))==checkpoint.protectedIDs,
                                      orderedContext.filter({ protected.contains($0) })==checkpoint.protectedIDs,
                                      checkpoint.protectedIDs.allSatisfy({ roles[$0]=="user" }),
                                      orderedContext.filter({ keptSet.subtracting(protected).contains($0) })==Array(kept.dropFirst(protected.count)) else { throw StoreError.unreadableRecord }
                            } else if orderedContext.filter({ keptSet.contains($0) }) != kept { throw StoreError.unreadableRecord }
                            replayNodes[id] = ReplayNode(id: id, role: "system", summary: true, dependencies: value.nativeCompaction?.dependencyIDs, summarized: value.nativeCompaction?.summarySourceIDs)
                            selectedTimeline.append(id)
                            orderedContext=[id]+kept; contextIDs=Set(orderedContext)
                            contextMessages[id] = ([], nil); contextIDs.insert(id)
                        } else if value.type == "branch" {
                            let kept = value.keptIds ?? [], keptSet = Set(kept)
                            if let branch = value.historicalBranch {
                                let plan = try EditReplayPlan.restore(branch, nodes: replayNodes, visible: selectedTimeline, context: orderedContext)
                                orderedContext = plan.replay; selectedTimeline = plan.displayPrefix
                            } else {
                                guard keptSet.count == kept.count, orderedContext.filter({ keptSet.contains($0) }) == kept else { throw StoreError.unreadableRecord }
                                orderedContext = kept
                                if let target = value.fromMessageId, let position = selectedTimeline.firstIndex(of: target) { selectedTimeline = Array(selectedTimeline.prefix(position)) }
                                else { selectedTimeline.removeAll { !keptSet.contains($0) } }
                            }
                            let shown = Set(selectedTimeline); selectedTimeline += kept.filter { !shown.contains($0) }; selectedTimeline.append(id)
                            replayNodes[id] = ReplayNode(id: id, role: "system", eligible: false)
                            contextIDs = Set(orderedContext); contextMessages[id] = ([], nil)
                        } else if let replacement = value.contextIDs {
                            let ids = Set(replacement)
                            guard ids.count == replacement.count, ids.isSubset(of: Set(contextMessages.keys)) else { throw StoreError.unreadableRecord }
                            let selected = EditReplayPlan.forkTimeline(visible: selectedTimeline, boundary: replacement)
                            guard value.selectedTimeline == nil || value.selectedTimeline == selected else { throw StoreError.unreadableRecord }
                            selectedTimeline = selected
                            contextIDs = ids; orderedContext=replacement
                        }
                        leaf = id
                        // Count durable appends, including abandoned branches,
                        // exactly as the helper does. This is not the visible-page count.
                        if value.type == "message", value.message?.role == "assistant" { assistantCount += 1; latestAssistantID = id }
                    }
                } catch is CancellationError { throw CancellationError() } catch { notice = "Damaged history record preserved. " + (error is ReplayPlanError ? error.localizedDescription : "Continue requires validation or an explicit recovered copy."); break }
                offset += UInt64(pending.count + 1); pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            if notice != nil { break }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
            if ProcessInfo.processInfo.systemUptime - progressAt >= 0.15 {
                progress?(branch.recordCount, offset, size); progressAt = ProcessInfo.processInfo.systemUptime
            }
        }
        if !pending.isEmpty && notice == nil { notice = "Incomplete tail preserved. No repair was performed." }
        if targetTurns != nil && sessionID == nil && notice == nil { notice = "History has no valid session header. Its source was left untouched." }
        try branch.constructChain(leaf: leaf)
        // Native edits keep the append-only source, while the disk-backed
        // visible position table follows their explicit branch records.
        try branch.replayChain { ref in
            if ref.type == "branch" {
                let kept = ref.keptIDs ?? []
                for id in kept { guard try branch.hasSeen(id) else { throw StoreError.unreadableRecord } }
                if let prefix = ref.selectedPrefix {
                    let shown = Set(prefix); try branch.selectTimeline(prefix + kept.filter { !shown.contains($0) })
                } else { try branch.branch(from: ref.fromMessageID, kept: kept) }
                try branch.append(ref)
            } else if let selected = ref.contextSelection { try branch.selectTimeline(selected)
            } else if ref.type == "message" || ref.type == "compaction" { try branch.append(ref) }
        }
        try branch.finish()
        taskRecords = try taskRecords.filter { task in
            guard let last = task.lastSourceID else { return false }
            return try branch.index(of:last) != nil
        }
        indexedRecordCount = branch.recordCount; indexedBytes = size
        guard try stamp(file) == identity else { throw StoreError.unreadableRecord }
        let activeCalls = Set(contextIDs.flatMap { contextMessages[$0]?.calls ?? [] })
        let activeResults = Set(contextIDs.compactMap { contextMessages[$0]?.result })
        if notice == nil { indexes[path] = Index(stamp: identity, branch: branch, assistantCount: assistantCount, latestAssistantID: latestAssistantID,
                                               sessionID: sessionID, automaticContextSafe: native && linear && !pendingWork && contextSafe && activeCalls.isSubset(of: activeResults), failureMessage: failureMessage, taskRecords:taskRecords) }
        }
        recency.removeAll { $0 == path }; recency.append(path)
        while recency.count > Self.retainedIndexes { indexes.removeValue(forKey: recency.removeFirst()) }
        let incarnation = "file:\(identity.device):\(identity.inode)"
        let lineage = branch.lineage
        if let expected {
            if let bytes = expected.committedBytes, let hash = expected.fingerprint {
                let cached = digests[path]
                let actual = cached?.stamp == identity && cached?.bytes == bytes ? cached!.digest : try fingerprint(file, bytes: bytes)
                guard bytes <= size, hash == actual else { throw HostError.failure("History was replaced or edited. Reload it to reanchor safely.") }
            }
            guard expected.incarnation == incarnation, expected.lineage == lineage else {
                throw HostError.failure("History changed. Reload this conversation to reanchor it.")
            }
        }
        let digest: String?
        if targetTurns != nil {
            if let cached = digests[path], cached.stamp == identity, cached.bytes == size { digest = cached.digest }
            else {
                digest = try fingerprint(file, bytes: size)
                digests[path] = (identity, size, digest!)
                if digests.count > Self.retainedIndexes { digests = digests.filter { recency.contains($0.key) } }
            }
        } else { digest = nil }
        func pageCursor(_ entry: String) -> ConversationCursor {
            var cursor = ConversationCursor(incarnation: incarnation, lineage: lineage, entry: entry)
            if let digest { cursor.committedBytes = size; cursor.fingerprint = digest }
            return cursor
        }
        let anchorIndex = try around.flatMap { try branch.index(of: $0) }
        let beforeIndex = try before.flatMap { try branch.index(of: $0) }
        let afterIndex = try after.flatMap { try branch.index(of: $0) }
        guard (around == nil || anchorIndex != nil), (before == nil || beforeIndex != nil), (after == nil || afterIndex != nil) else {
            throw HostError.failure("That history boundary is no longer in this branch. Reload history or inspect its retained source.")
        }
        let forward = anchorIndex != nil || afterIndex != nil
        let range: Range<Int>
        if let targetTurns {
            let pivot = anchorIndex ?? afterIndex ?? beforeIndex ?? branch.count
            let users = try branch.userPositions(in: max(0, pivot - HistoryWindowPolicy.rows)..<min(branch.count, pivot + HistoryWindowPolicy.rows + 1))
            range = HistoryWindowPolicy.range(count: branch.count, before: beforeIndex, after: afterIndex,
                                              around: anchorIndex, target: targetTurns, isUser: { users.contains($0) })
        } else if let start = anchorIndex ?? afterIndex.map({ $0 + 1 }) { range = start..<min(branch.count, start + 60) }
        else { let end = beforeIndex ?? branch.count; range = max(0, end - 60)..<end }
        var messages: [TranscriptMessage] = [], bytes = HistoryWindowPolicy.metadataAllowance
        var start = forward ? range.lowerBound : range.upperBound, end = start
        // What each call's result recorded, so the reply that made the call
        // can show it in that call's own card, exactly as a live snapshot
        // does. Collected while the window is decoded, keyed by the result's
        // own row: a call id alone is not unique, since providers reuse them.
        // The page is filled in once below, in page order, so the direction
        // it was read in does not matter.
        var toolResults: [String: ToolResultRecord] = [:]
        for index in (forward ? Array(range) : Array(range.reversed())) {
            try Task.checkCancellation()
            let ref = try branch.at(index); try file.seek(toOffset: ref.offset)
            guard let data = try file.read(upToCount: ref.length), data.count == ref.length else { throw StoreError.unreadableRecord }
            decodedRecords += 1
            let value = try JSONDecoder().decode(WireValue.self, from: data).object ?? [:]
            var message: TranscriptMessage
            if value["type"]?.string == "branch" { message = .init(id: ref.id, role: "system", text: Self.branchText, kind: "branch") }
            else if value["type"]?.string == "compaction" {
                message = TranscriptMessage.project(id: ref.id, message: ["role": .string("system"), "content": .string("Conversation summary:\n" + (value["summary"]?.string ?? ""))])
                let kept = Set(value["nativeKeptIDs"]?.array?.compactMap(\.string) ?? []).count
                let tokens = value["tokensBefore"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
                message.operationID = value["nativeCompaction"]?.object?["operationId"]?.string
                message.kind = "compaction"; message.detail = "Compacted \(tokens) tokens · \(kept) message\(kept == 1 ? "" : "s") kept"
            }
            else {
                let row = value["message"]?.object ?? [:]
                if let result = ToolResultRecord.of(row) { toolResults[ref.id] = result.record }
                message = TranscriptMessage.project(id: ref.id, message: row)
            }
            if ref.adopted { message.responseTimeline?.finish("completed"); message.detail="Compaction · Checkpoint durably adopted" }
            if ref.presentation, message.responseTimeline?.terminal == nil { message.detail=(message.detail ?? "Operation") + " · no terminal receipt" }
            let count = try JSONEncoder().encode(message).count
            // A page may hold one large complete row. Never shorten a source
            // just to fit the preferred window size; native layout is virtual.
            guard messages.isEmpty || bytes + count + 1 <= HistoryWindowPolicy.envelopeBytes else { break }
            bytes += count + 1
            if forward { messages.append(message); end = index + 1 }
            else { messages.insert(message, at: 0); start = index }
        }
        guard try stamp(file) == identity else { indexes.removeValue(forKey: path); throw StoreError.unreadableRecord }
        guard range.isEmpty || !messages.isEmpty else { throw HostError.failure("This history record exceeds the display envelope. Its retained source is unchanged.") }
        messages = TranscriptMessage.resolvingToolResults(messages, results: toolResults)
        return HistoryPage(messages: messages, before: start > 0 && start < branch.count ? try branch.at(start).id : nil, total: branch.count, notice: notice,
                           assistantMessageCount: notice == nil ? assistantCount : nil, latestAssistantMessageID: notice == nil ? latestAssistantID : nil,
                           failureMessage: notice == nil ? failureMessage : nil,
                           revision: notice == nil ? HistoryRevision(path: path, stamp: revision(identity)) : nil,
                           incarnation: incarnation, lineage: lineage,
                           older: start > 0 && !messages.isEmpty ? pageCursor(try branch.at(start).id) : nil,
                           newer: end < branch.count && !messages.isEmpty ? pageCursor(try branch.at(end - 1).id) : nil,
                           partialTurnInput: start < branch.count && messages.first?.role != "user" ? try branch.latestUser(before: start) : nil, taskRecords:taskRecords)
    }
}
