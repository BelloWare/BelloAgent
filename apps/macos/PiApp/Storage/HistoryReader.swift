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
    /// Work the journal's last state record left unfinished.
    var retainedRun: RetainedRun? = nil
    /// The notice is only that the last record was cut off mid-write: every
    /// record before it is complete and on this page.
    var incompleteTail = false
}

/// What a journal's last state record says was unfinished when its helper
/// last stopped: a run still going (cut off by a quit or a crash), or
/// follow-ups and steering waiting, paused, behind a stopped one. The helper
/// restores exactly this, paused and with nothing replayed, the next time the
/// chat is used; the app shows it before then.
struct RetainedRun: Equatable, Sendable {
    var active: Bool
    var runStatus: String?
    var queuePaused: Bool
    /// The waiting submissions, in the shape the helper's queue rows have
    /// (`turnId`, a bounded `text` preview, `kind` for steering).
    var queue: [[String: WireValue]]
    /// Tool calls in the conversation's context with no result: their outcome
    /// is unknown when the run that issued them never finished.
    var unansweredCalls: Set<String>
}

/// The journal identity used for a retained display, including replacements
/// with the same path, length and modification time. It never retains bodies.
struct HistoryRevision: Codable, Equatable, Sendable {
    let path: String
    let stamp: String
}

// Read-only archive browsing does not launch an agent runtime.
// First index record offsets and parent links; decode only the requested page.
actor HistoryReader {
    /// Where offset indexes are built (`HistoryOffsetIndex`).
    private let indexDirectory: URL
    init(indexDirectory: URL = FileManager.default.temporaryDirectory) { self.indexDirectory = indexDirectory }
    /// The next newline at or after `start`, found with `memchr`. `Data`'s
    /// `range(of:)` set up a Boyer-Moore search for every line of a journal,
    /// the largest single cost of reading a long one.
    private static func newline(in data: Data, from start: Data.Index) -> Data.Index? {
        data.withUnsafeBytes { raw -> Data.Index? in
            let offset = start - data.startIndex
            guard let base = raw.baseAddress, offset < raw.count, let found = memchr(base + offset, 10, raw.count - offset) else { return nil }
            return data.startIndex + base.distance(to: UnsafeRawPointer(found))
        }
    }
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
    /// A run-state record's data, as `JournalRunHold` reads it.
    struct RunStateRecord: Decodable {
        fileprivate var work: IndexRecord.PendingWork
        init(from decoder: Decoder) throws { work = try IndexRecord.PendingWork(from: decoder) }
        /// "interrupted" for a run cut off, "paused" for one stopped or with
        /// work held behind it, nil for none or a failure.
        var hold: String? {
            if work.active == true { return "interrupted" }
            if work.runStatus == "failed" { return nil }
            return work.exists || work.pausedWithoutWork ? "paused" : nil
        }
    }
    fileprivate struct IndexRecord: Decodable {
        var type: String?; var id: String?; var parentId: String?
        var fromMessageId: String?; var keptIds: [String]?; var nativeKeptIDs: [String]?; var contextIDs: [String]?
        var version: Int?; var customType: String?; var pendingWork: PendingWork?
        var nativeCompactionVersion: Int?; var nativeCompaction: Checkpoint?
        var historicalBranch: HistoricalBranch?; var selectedTimeline: [String]?
        var presentationTarget: String?
        var taskTerminal: TaskPresentationRecord?
        struct Checkpoint: Decodable { var operationId: String?; var version: Int; var sourceIDs: [String]; var protectedIDs: [String]; var keptIDs: [String]; var dependencyIDs: [String]?; var summarySourceIDs: [String]? }
        struct PendingItem: Decodable { var turnID: String?; var text: String? }
        struct PendingWork: Decodable {
            var active: Bool?; var queue: [PendingItem]?; var steering: [PendingItem]?
            var runStatus: String?; var errorMessage: String?; var queuePaused: Bool?
            var exists: Bool { active == true || !(queue ?? []).isEmpty || !(steering ?? []).isEmpty }
            var failure: String? {
                guard active != true, runStatus == "failed" else { return nil }
                let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return detail.isEmpty ? "Run failed." : detail
            }
            /// Stopped by the reader (or a quit) with nothing queued: the run
            /// is over, but the chat waits for Resume, as the helper restores
            /// it. Not a failure, which is shown as one.
            var pausedWithoutWork: Bool { !exists && queuePaused == true && runStatus != "failed" }
            func retained(unanswered: Set<String>) -> RetainedRun? {
                guard exists || pausedWithoutWork else { return nil }
                func row(_ item: PendingItem, steering: Bool) -> [String: WireValue]? {
                    guard let id = item.turnID else { return nil }
                    let text = item.text ?? "", kept = String(text.prefix(1024))
                    var value: [String: WireValue] = ["turnId": .string(id), "text": .string(steering ? "[Steering] " + kept : kept), "textTruncated": .bool(kept.count < text.count)]
                    if steering { value["kind"] = .string("steering") }
                    return value
                }
                let rows = (steering ?? []).compactMap { row($0, steering: true) } + (queue ?? []).compactMap { row($0, steering: false) }
                return RetainedRun(active: active == true, runStatus: runStatus, queuePaused: queuePaused == true || !rows.isEmpty || active == true,
                                   queue: rows, unansweredCalls: active == true ? unanswered : [])
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
        /// A run-state record read from its tail (`StateRecordTail`): its id
        /// and parent. What it says about unfinished work is read from the
        /// newest one only.
        init(stateID: String, parentID: String?) { type = "custom"; id = stateID; parentId = parentID; customType = StateRecordTail.customType }
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
    private struct Index { var stamp: Stamp; var branch: HistoryOffsetIndex; var assistantCount: Int; var latestAssistantID: String?; var sessionID: String?; var automaticContextSafe: Bool; var failureMessage: String?; var taskRecords: [TaskPresentationRecord]; var retainedRun: RetainedRun?
        /// Shown rows before the ones held, for an index built from the
        /// journal's metadata file; a page that reaches them indexes it all.
        var olderRows = 0
        /// Built from the metadata file: rows before the checkpoint, shown or
        /// hidden by an edit, are not in it.
        var partial = false
        /// Edited messages' versions, numbered from the branch records as the helper numbers them.
        var versions = MessageVersionLedger() }
    /// What indexing a journal found besides where each row is: what a page
    /// says about the chat, from the index kept between reads or built now.
    private struct JournalFacts {
        var branch: HistoryOffsetIndex
        var notice: String? = nil, assistantCount = 0, latestAssistantID: String? = nil, failureMessage: String? = nil
        var taskRecords: [TaskPresentationRecord] = [], retainedRun: RetainedRun? = nil, incompleteTail = false
        var versions = MessageVersionLedger(), olderRows = 0
    }
    private var indexes: [String: Index] = [:]
    // As many bounded offset indexes as the workspace keeps transcript pages, so
    // cycling between open chats does not re-index a large journal each time.
    // Offsets and parent links only; no history bodies.
    private static let retainedIndexes = 8
    private var recency: [String] = []
    private var digests: [String: (stamp: Stamp, bytes: UInt64, digest: String)] = [:]
    /// What a page cursor records of the journal it was read from: its
    /// length, and its first and last 64 KiB up to there. A journal only ever
    /// grows; a replaced or rewritten one differs in these. Hashing the whole
    /// of a long journal was a large part of opening it.
    private func fingerprint(_ file: FileHandle, bytes: UInt64) throws -> String {
        var hash = SHA256(), length = bytes
        withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
        let window: UInt64 = 65_536
        for start in Set([0, bytes > window ? bytes - window : 0]).sorted() where bytes > start {
            try file.seek(toOffset: start)
            let count = Int(min(window, bytes - start))
            guard let data = try file.read(upToCount: count), data.count == count else { throw StoreError.unreadableRecord }
            hash.update(data: data)
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
    /// What the retained offset indexes take, together.
    var retainedIndexBytes: Int { indexes.values.reduce(0) { $0 + $1.branch.bytes } }
    /// Lets go of every retained offset index, and with it its file: the app
    /// is quitting.
    func releaseIndexes() { indexes.removeAll(); recency.removeAll(); digests.removeAll() }
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
    private func revision(_ stamp: Stamp) -> String { Self.revision(stamp) }
    private static func revision(_ stamp: Stamp) -> String { "\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.modified):\(stamp.modifiedNS):\(stamp.changed):\(stamp.changedNS)" }
    /// The revision a page read from `path` now would carry: the file's
    /// identity, size and change times, looked at without reading it or
    /// waiting on this reader.
    nonisolated static func currentRevision(path: String) -> HistoryRevision? {
        var value = stat()
        guard stat(path, &value) == 0 else { return nil }
        let stamp = Stamp(device: value.st_dev, inode: value.st_ino, size: value.st_size, modified: value.st_mtimespec.tv_sec, modifiedNS: value.st_mtimespec.tv_nsec,
                          changed: value.st_ctimespec.tv_sec, changedNS: value.st_ctimespec.tv_nsec)
        return HistoryRevision(path: path, stamp: revision(stamp))
    }
    private func content(_ ref: Ref, file: FileHandle) throws -> String {
        if ref.type == "branch" { return "## Edit\n\n" + Self.branchText + "\n\n" }
        decodedRecords += 1
        try file.seek(toOffset: ref.offset)
        guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length else { throw StoreError.unreadableRecord }
        return ConversationContent.text(try JSONDecoder().decode(WireValue.self, from: bytes).object ?? [:])
    }
    func editTarget(path: String, id: String) throws -> [String: WireValue] {
        let page = try read(path: path, around: id, targetTurns: 1, whole: true)
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
        guard text.utf8.count <= SubmissionLimits.messageBytes, try stamp(file) == index.stamp else { throw HostError.failure("The original input is too large or changed during loading.") }
        let blocks = message["content"]?.array ?? []
        let expanded = message["content"]?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
        return ["messageId": .string(id), "text": .string(text), "sourceTimeline": .string(EditReplayPlan.digest(try index.branch.timelineIDs())),
                "sourceTextDigest": .string(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()),
                "input": message["nativeUserInput"] ?? .null,
                "legacyInputs": .bool(message["nativeUserInput"] == nil && (expanded != text || blocks.contains { $0.object?["type"]?.string == "image" }))]
    }
    /// A retained message's role, from the offset index: any record of the
    /// journal, in the timeline shown now or in an earlier version.
    func messageRole(path: String, id: String) throws -> String? {
        let page = try read(path: path, whole: true)
        guard page.notice == nil, let index = indexes[path] else { return nil }
        return try index.branch.ref(id)?.role
    }
    func searchContent(path: String, query: String, start: Int) throws -> ContentSearch {
        guard query.count <= 256, start >= 0 else { throw StoreError.unreadableRecord }
        let page = try read(path: path, whole: true)
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
        // Positions count every shown row, as the search that gave them did.
        if indexes[path]?.partial == true { _ = try read(path: path, whole: true) }
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
    /// Whether a journal is still the file a page was read from: the same
    /// file, size and change times. Nothing is read from it.
    func unchanged(_ held: HistoryRevision) -> Bool {
        guard let file = try? open(held.path) else { return false }
        defer { try? file.close() }
        guard let current = try? stamp(file) else { return false }
        return revision(current) == held.stamp
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
            while let index = Self.newline(in: chunk, from: start) {
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
    /// `whole` indexes every record: what reads the whole chat (search, copy,
    /// an edit's timeline, a record's role in any version) needs it.
    func read(path: String, before: String? = nil, around: String? = nil, after: String? = nil,
              targetTurns: Int? = nil, expected: ConversationCursor? = nil, progress: Progress? = nil, whole: Bool = false) throws -> HistoryPage {
        try Task.checkCancellation()
        let file = try open(path); defer { try? file.close() }
        let identity = try stamp(file)
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        let journal = try journalIndex(path: path, file: file, identity: identity, size: size, before: before, around: around, after: after,
                                       targetTurns: targetTurns, progress: progress, whole: whole)
        let branch = journal.branch, notice = journal.notice, olderRows = journal.olderRows, versions = journal.versions
        let assistantCount = journal.assistantCount, latestAssistantID = journal.latestAssistantID, failureMessage = journal.failureMessage
        let taskRecords = journal.taskRecords, retainedRun = journal.retainedRun, incompleteTail = journal.incompleteTail
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
        let (range, forward) = try Self.pageRange(in: branch, before: before, around: around, after: after, targetTurns: targetTurns)
        let (messages, start, end) = try decodePage(range, forward: forward, from: file, path: path, identity: identity,
                                                    branch: branch, versions: versions, retainedRun: retainedRun)
        return HistoryPage(messages: messages, before: start > 0 && start < branch.count ? try branch.at(start).id : nil, total: olderRows + branch.count, notice: notice,
                           assistantMessageCount: notice == nil ? assistantCount : nil, latestAssistantMessageID: notice == nil ? latestAssistantID : nil,
                           failureMessage: notice == nil ? failureMessage : nil,
                           revision: notice == nil ? HistoryRevision(path: path, stamp: revision(identity)) : nil,
                           incarnation: incarnation, lineage: lineage,
                           older: (start > 0 || olderRows > 0) && !messages.isEmpty ? pageCursor(try branch.at(start).id) : nil,
                           newer: end < branch.count && !messages.isEmpty ? pageCursor(try branch.at(end - 1).id) : nil,
                           partialTurnInput: start < branch.count && messages.first?.role != "user" ? try branch.latestUser(before: start) : nil, taskRecords:taskRecords,
                           retainedRun: notice == nil ? retainedRun : nil, incompleteTail: incompleteTail)
    }
    /// The journal's offset index and what it says about the chat: the one
    /// kept from an earlier read while the file is unchanged, else one built
    /// now (`buildIndex`).
    private func journalIndex(path: String, file: FileHandle, identity: Stamp, size: UInt64, before: String?, around: String?, after: String?,
                              targetTurns: Int?, progress: Progress?, whole: Bool) throws -> JournalFacts {
        // A page reaching past the rows an index built from the metadata
        // file holds needs the whole journal indexed.
        var wholeJournal = whole
        if let cached = indexes[path], cached.stamp == identity, cached.partial,
           try whole || Self.reachesPast(cached.branch, before: before, around: around, after: after) { indexes.removeValue(forKey: path); wholeJournal = true }
        if let cached = indexes[path], cached.stamp == identity {
            return JournalFacts(branch: cached.branch,
                                notice: targetTurns != nil && cached.sessionID == nil ? "History has no valid session header. Its source was left untouched." : nil,
                                assistantCount: cached.assistantCount, latestAssistantID: cached.latestAssistantID, failureMessage: cached.failureMessage,
                                taskRecords: cached.taskRecords, retainedRun: cached.retainedRun, versions: cached.versions, olderRows: cached.olderRows)
        }
        return try buildIndex(path: path, file: file, identity: identity, size: size, before: before, around: around, after: after,
                              targetTurns: targetTurns, progress: progress, wholeJournal: wholeJournal)
    }
    /// Indexes the journal: from its metadata file's checkpoint when one
    /// still matches the file, else every record from the start. The index
    /// is kept for the next read unless a record was damaged.
    private func buildIndex(path: String, file: FileHandle, identity: Stamp, size: UInt64, before: String?, around: String?, after: String?,
                            targetTurns: Int?, progress: Progress?, wholeJournal: Bool) throws -> JournalFacts {
        var branch = try HistoryOffsetIndex(directory: indexDirectory)
        var notice: String?, assistantCount = 0, latestAssistantID: String?, failureMessage: String?
        var taskRecords: [TaskPresentationRecord] = [], retainedRun: RetainedRun?, incompleteTail = false
        var versions = MessageVersionLedger(), olderRows = 0
        indexes.removeValue(forKey: path)
        // A journal with a metadata file (`JournalCheckpoint`) is indexed from
        // the file's checkpoint: the rows it names, then only the records after
        // it. A file the journal no longer matches, an edit after it, or a
        // page reaching past its rows, and the whole journal is indexed.
        let resumable = wholeJournal ? nil : JournalCheckpoint.read(for: URL(fileURLWithPath: path))
        build: for resume in (resumable.map { [$0, nil] } ?? [nil]) as [JournalCheckpoint?] {
        if resume == nil, resumable != nil {
            branch = try HistoryOffsetIndex(directory: indexDirectory); notice = nil; assistantCount = 0; latestAssistantID = nil; failureMessage = nil
            taskRecords = []; retainedRun = nil; incompleteTail = false; versions = MessageVersionLedger(); olderRows = 0
        }
        var pending = Data(), offset: UInt64 = 0, leaf: String?
        // Where the newest run-state record is, when it was read from its
        // tail: what it says about unfinished work is decoded after the loop.
        var newestState: (offset: UInt64, length: Int)?
        var sessionID: String?, native = false, linear = true, pendingWork = false, lastWork: IndexRecord.PendingWork?
        var contextIDs: Set<String> = [], contextMessages: [String: (calls: [String], result: String?)] = [:]
        var orderedContext: [String] = [], roles: [String: String] = [:]
        var replayNodes: [String: ReplayNode] = [:], selectedTimeline: [String] = []
        var contextSafe = true, callCount = 0
        var progressAt = ProcessInfo.processInfo.systemUptime
        var presentationOperations: [String:String] = [:]
        // Rows named by the checkpoint: shown as they are, not replayed as edits.
        var seeded: Set<String> = [], seededTail: String?
        if let resume {
            guard let seed = Self.seed(resume, file: file) else { continue build }
            for ref in seed.rows { try branch.insert(ref) }
            if let tail = seed.tail { try branch.insert(tail); seededTail = tail.id }
            seeded = Set(seed.rows.map(\.id)); branch.startLineage(resume.lineage)
            sessionID = seed.sessionID; native = true
            leaf = resume.lastID; offset = resume.start; olderRows = resume.rowsBefore
            orderedContext = resume.context; contextIDs = Set(resume.context)
            contextMessages = seed.contextMessages; roles = seed.roles; replayNodes = seed.replayNodes
            selectedTimeline = seed.rows.map(\.id); presentationOperations = seed.presentationOperations
            contextSafe = seed.contextSafe; callCount = seed.callCount
            assistantCount = resume.assistantMessageCount; latestAssistantID = resume.latestAssistantMessageID
            versions = resume.versions; taskRecords = resume.tasks
            if let work = seed.work { pendingWork = work.exists; failureMessage = work.failure; lastWork = work }
            try file.seek(toOffset: resume.start)
        } else { try file.seek(toOffset: 0) }
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            while let index = Self.newline(in: chunk, from: start) {
                try Task.checkCancellation()
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                do {
                    // Superseded run state is never used, and a long chat holds
                    // thousands of copies: only a state record's id and parent
                    // join the index, and the newest is decoded after the loop.
                    let value: IndexRecord
                    if let tail = StateRecordTail.read(pending) { value = IndexRecord(stateID: tail.id, parentID: tail.parent); newestState = (offset, pending.count) }
                    else { value = try JSONDecoder().decode(IndexRecord.self, from: pending); if value.pendingWork != nil { newestState = nil } }
                    // An edit or a fork boundary after the checkpoint is replayed from the start.
                    if resume != nil, value.type == "branch" || value.customType == "pi-app.native.context.v1" { continue build }
                    if value.type == "session", offset == 0, value.version == 3 { sessionID = value.id }
                    if value.customType == "pi-app.native.v1" { native = true }
                    if let work = value.pendingWork { pendingWork = work.exists; failureMessage = work.failure; lastWork = work }
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
                            if value.message?.role == "user" { versions.recorded(userMessage: id) }
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
                            versions.branched(from: value.fromMessageId ?? "")
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
        if !pending.isEmpty && notice == nil { notice = "Incomplete tail preserved. No repair was performed."; incompleteTail = sessionID != nil }
        if let newest = newestState {
            try file.seek(toOffset: newest.offset)
            let line = try file.read(upToCount: newest.length) ?? Data()
            if line.count == newest.length, let value = try? JSONDecoder().decode(IndexRecord.self, from: line) {
                if let work = value.pendingWork { pendingWork = work.exists; failureMessage = work.failure; lastWork = work }
            } else if notice == nil { notice = "Damaged history record preserved. Continue requires validation or an explicit recovered copy." }
        }
        if targetTurns != nil && sessionID == nil && notice == nil { notice = "History has no valid session header. Its source was left untouched." }
        try branch.constructChain(leaf: leaf)
        // Native edits keep the append-only source, while the disk-backed
        // visible position table follows their explicit branch records.
        try branch.replayChain { ref in
            if seeded.contains(ref.id) { try branch.append(ref); return }
            if ref.id == seededTail { return }
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
        retainedRun = lastWork?.retained(unanswered: activeCalls.subtracting(activeResults))
        if resume != nil, try Self.reachesPast(branch, before: before, around: around, after: after) { continue build }
        if notice == nil { indexes[path] = Index(stamp: identity, branch: branch, assistantCount: assistantCount, latestAssistantID: latestAssistantID,
                                               sessionID: sessionID, automaticContextSafe: native && linear && !pendingWork && contextSafe && activeCalls.isSubset(of: activeResults), failureMessage: failureMessage, taskRecords:taskRecords, retainedRun: retainedRun, olderRows: olderRows, partial: resume != nil, versions: versions) }
        break build
        }
        return JournalFacts(branch: branch, notice: notice, assistantCount: assistantCount, latestAssistantID: latestAssistantID,
                            failureMessage: failureMessage, taskRecords: taskRecords, retainedRun: retainedRun, incompleteTail: incompleteTail,
                            versions: versions, olderRows: olderRows)
    }
    /// A page's rows decoded from the journal in the order they are read,
    /// until the display envelope is full, from a file that must not have
    /// changed meanwhile. Each call's result shows in its call's card, and a
    /// call the stopped run never answered reads "unknown". Returns the rows
    /// and where they start and end in the branch.
    private func decodePage(_ range: Range<Int>, forward: Bool, from file: FileHandle, path: String, identity: Stamp,
                            branch: HistoryOffsetIndex, versions: MessageVersionLedger,
                            retainedRun: RetainedRun?) throws -> (messages: [TranscriptMessage], start: Int, end: Int) {
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
                if message.role == "user", let ids = versions.versions(of: ref.id), let at = ids.firstIndex(of: ref.id) {
                    message.versions = MessageVersionMark(index: at + 1, count: ids.count, ids: ids.count <= 64 ? ids : nil)
                }
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
        if let unanswered = retainedRun?.unansweredCalls, !unanswered.isEmpty {
            // A call the stopped run issued and never answered did not
            // finish: it reads "unknown", as the helper will record it, not "Ran".
            for index in messages.indices where messages[index].tools?.contains(where: { unanswered.contains($0.id) && $0.state == "recorded" }) == true {
                messages[index].tools = messages[index].tools?.map { tool in
                    var card = tool; if unanswered.contains(tool.id) && tool.state == "recorded" { card.state = "unknown" }; return card
                }
            }
        }
        return (messages, start, end)
    }
    /// The rows a page holds, and whether it reads forward from its first:
    /// the turns around, after or before a row, or sixty rows when no count
    /// of turns is asked for. A boundary no longer in the branch throws.
    private static func pageRange(in branch: HistoryOffsetIndex, before: String?, around: String?, after: String?,
                                  targetTurns: Int?) throws -> (range: Range<Int>, forward: Bool) {
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
        return (range, forward)
    }
}

extension HistoryReader {
    /// What the checkpoint's rows contribute to an index, read from the
    /// journal and checked against the file; nil when anything differs.
    fileprivate struct Seed {
        var rows: [HistoryOffset] = [], tail: HistoryOffset?
        var sessionID: String?
        var roles: [String: String] = [:], contextMessages: [String: (calls: [String], result: String?)] = [:]
        var replayNodes: [String: ReplayNode] = [:], presentationOperations: [String: String] = [:]
        var contextSafe = true, callCount = 0
        var work: IndexRecord.PendingWork?
    }
    fileprivate static func seed(_ checkpoint: JournalCheckpoint, file: FileHandle) -> Seed? {
        guard let headerLine = JournalCheckpoint.verified(checkpoint.header, in: file),
              let header = try? JSONDecoder().decode(IndexRecord.self, from: headerLine), header.type == "session", header.version == 3,
              header.id == checkpoint.sessionID,
              let markerLine = JournalCheckpoint.verified(checkpoint.marker, in: file),
              let marker = try? JSONDecoder().decode(IndexRecord.self, from: markerLine), marker.customType == "pi-app.native.v1",
              let lastLine = JournalCheckpoint.verified(checkpoint.last, in: file),
              let last = try? JSONDecoder().decode(IndexRecord.self, from: lastLine), last.id == checkpoint.lastID else { return nil }
        var seed = Seed(); seed.sessionID = header.id
        var parent: String?, operations: [String: Int] = [:]
        for row in checkpoint.rows {
            guard let bytes = JournalCheckpoint.rowBytes(row, in: file), let value = try? JSONDecoder().decode(IndexRecord.self, from: bytes) else { return nil }
            var ref = HistoryOffset(id: row.id, parent: parent, offset: row.offset, length: row.length, type: nil)
            switch row.kind {
            case .message, .update:
                guard (row.kind == .message ? value.type == "message" && value.id == row.id : value.presentationTarget == row.id), let message = value.message else { return nil }
                ref.type = "message"; ref.role = message.role
                ref.presentation = ["execution", "requestLedger"].contains(message.nativeKind ?? "")
                if let operation = message.nativeOperationID { operations[operation] = seed.rows.count; seed.presentationOperations[operation] = row.id }
                seed.roles[row.id] = message.role
                if message.contentIndexed != true { seed.contextSafe = false }
                seed.callCount += message.calls.count
                if seed.callCount > 100_000 { seed.contextSafe = false }
                seed.contextMessages[row.id] = (seed.callCount <= 100_000 ? message.calls : [], message.role == "toolResult" ? message.toolCallId : nil)
                seed.replayNodes[row.id] = ReplayNode(id: row.id, role: message.role ?? "", eligible: message.nativeReplayEligible != false,
                                                      summary: message.nativeKind == "compaction", dependencies: message.nativeCompaction?.dependencyIDs,
                                                      summarized: message.nativeCompaction?.summarySourceIDs, calls: message.calls, result: message.toolCallId)
            case .compaction:
                guard value.type == "compaction", value.id == row.id else { return nil }
                ref.type = "compaction"
                if let operation = value.nativeCompaction?.operationId, let position = operations[operation] { seed.rows[position].adopted = true }
                seed.replayNodes[row.id] = ReplayNode(id: row.id, role: "system", summary: true, dependencies: value.nativeCompaction?.dependencyIDs,
                                                      summarized: value.nativeCompaction?.summarySourceIDs)
                seed.contextMessages[row.id] = ([], nil)
            case .branch:
                guard value.type == "branch", value.id == row.id else { return nil }
                ref.type = "branch"
                seed.replayNodes[row.id] = ReplayNode(id: row.id, role: "system", eligible: false)
                seed.contextMessages[row.id] = ([], nil)
            }
            seed.rows.append(ref); parent = row.id
        }
        guard checkpoint.context.allSatisfy({ seed.contextMessages[$0] != nil }) else { return nil }
        // The record the checkpoint follows, when it is not a row itself, joins
        // the chain so the records after it find their parent.
        if !checkpoint.rows.contains(where: { $0.id == checkpoint.lastID }) {
            seed.tail = HistoryOffset(id: checkpoint.lastID, parent: parent, offset: checkpoint.last.offset, length: checkpoint.last.length, type: last.type)
        }
        if let state = checkpoint.state {
            guard let line = JournalCheckpoint.verified(state, in: file), let value = try? JSONDecoder().decode(IndexRecord.self, from: line) else { return nil }
            seed.work = value.pendingWork
        }
        return seed
    }
    /// Whether a request names rows before the ones an index built from the
    /// journal's metadata file holds: its first row as the boundary to read
    /// before, or a row it does not have.
    fileprivate static func reachesPast(_ branch: HistoryOffsetIndex, before: String?, around: String?, after: String?) throws -> Bool {
        if let before, (try branch.index(of: before) ?? 0) == 0 { return true }
        for id in [around, after].compactMap({ $0 }) where try branch.index(of: id) == nil { return true }
        return false
    }
}

/// A run-state record's own id and parent, read from the end of its line.
/// The helper writes journal keys sorted, so such a record begins with its
/// `customType` and ends with its id, parent, timestamp and type, none of which
/// can hold a quote: the last `,"id":"` in the line is the record's own, and
/// the rest of the line must be exactly that ending. Anything else answers nil,
/// and the line is decoded as before. The helper reads its journal the same way
/// (`JournalLineScan.stateTail`).
/// Whether a journal's newest run-state record leaves the chat waiting for
/// Resume, read from the end of the file alone: what a chat paused before
/// this build looked like, for its sidebar row before it is first opened
/// (`WorkspaceRunHolds.swift`). The run state is written after the messages of
/// each run, so it sits near the end. What cannot be told from the end
/// (a state record further back than `window`, or a file that cannot be read)
/// is `.unknown`, never a guess.
enum JournalRunHold: Equatable {
    /// "paused" or "interrupted".
    case held(String)
    /// Nothing waits: the newest state is finished or failed, the journal has
    /// no state at all, or it is gone.
    case clear
    case unknown

    static func read(path: String, window: Int = 262_144) -> JournalRunHold {
        guard FileManager.default.fileExists(atPath: path) else { return .clear }
        guard let file = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return .unknown }
        guard size > 0 else { return .clear }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? file.seek(toOffset: start)) != nil, let data = try? file.readToEnd() else { return .unknown }
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // cut off at the window's start
        for line in lines.reversed() where line.starts(with: StateRecordTail.prefix) {
            struct Record: Decodable { var data: HistoryReader.RunStateRecord? }
            guard let work = (try? JSONDecoder().decode(Record.self, from: Data(line)))?.data else { return .unknown }
            return work.hold.map(JournalRunHold.held) ?? .clear
        }
        // The whole journal was read and holds no run state: nothing ever ran.
        return start == 0 ? .clear : .unknown
    }
}

enum StateRecordTail {
    static let customType = "pi-app.native.state.v1"
    static let prefix = Data(#"{"customType":"pi-app.native.state.v1","#.utf8)

    static func read(_ line: Data) -> (id: String, parent: String?)? {
        guard line.starts(with: prefix) else { return nil }
        return line.withUnsafeBytes { raw -> (id: String, parent: String?)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let marker: [UInt8] = Array(#","id":""#.utf8)
            var start = bytes.count - marker.count
            search: while start > prefix.count {
                for offset in 0..<marker.count where bytes[start + offset] != marker[offset] { start -= 1; continue search }
                break
            }
            // The data object ends right before the record's own id.
            guard start > prefix.count, bytes[start - 1] == UInt8(ascii: "}") else { return nil }
            var index = start
            func take(_ text: StaticString) -> Bool {
                let count = text.utf8CodeUnitCount
                guard index + count <= bytes.count else { return false }
                for offset in 0..<count where bytes[index + offset] != text.utf8Start[offset] { return false }
                index += count; return true
            }
            /// A quoted string without escapes or control characters.
            func plain() -> String? {
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
                let begin = index + 1
                index = begin
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\"") {
                        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[begin..<index]), as: UTF8.self)
                        index += 1; return text
                    }
                    if byte == UInt8(ascii: "\\") || byte < 0x20 { return nil }
                    index += 1
                }
                return nil
            }
            guard take(#","id":"#), let id = plain(), take(#","parentId":"#) else { return nil }
            let parent: String?
            if index < bytes.count, bytes[index] == UInt8(ascii: "\"") { guard let text = plain() else { return nil }; parent = text }
            else if take("null") { parent = nil }
            else { return nil }
            guard take(#","timestamp":"#), plain() != nil, take(#","type":"custom"}"#) else { return nil }
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
            return index == bytes.count ? (id, parent) : nil
        }
    }
}
