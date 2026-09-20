import Foundation
import Darwin

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
}

/// The journal identity used for a retained display, including replacements
/// with the same path, length and modification time. It never retains bodies.
struct HistoryRevision: Equatable, Sendable {
    let path: String
    let stamp: String
}

// Read-only archive browsing does not launch Node or construct a Pi runtime.
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
    private struct Ref {
        var id: String; var parent: String?; var offset: UInt64; var length: Int; var type: String?
        var fromMessageID: String?; var keptIDs: [String]?
    }
    private struct IndexRecord: Decodable {
        var type: String?; var id: String?; var parentId: String?
        var fromMessageId: String?; var keptIds: [String]?; var nativeKeptIDs: [String]?; var contextIDs: [String]?
        var version: Int?; var customType: String?; var pendingWork: PendingWork?
        var nativeCompactionVersion: Int?; var nativeCompaction: Checkpoint?
        struct Checkpoint: Decodable { var version: Int; var sourceIDs: [String]; var protectedIDs: [String]; var keptIDs: [String] }
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
            private enum CodingKeys: String, CodingKey { case role, toolCallId, content, nativeReplayEligible }
            init(from decoder: Decoder) throws {
                let value = try decoder.container(keyedBy: CodingKeys.self)
                role = try value.decodeIfPresent(String.self, forKey: .role)
                toolCallId = try value.decodeIfPresent(String.self, forKey: .toolCallId)
                nativeReplayEligible = try value.decodeIfPresent(Bool.self, forKey: .nativeReplayEligible)
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
        private struct ContextSelection: Decodable { var ids: [String]? }
        private enum CodingKeys: String, CodingKey { case type, id, parentId, fromMessageId, keptIds, nativeKeptIDs, version, customType, nativeState, data, message, nativeCompactionVersion, nativeCompaction }
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
            if type == "branch" { pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .nativeState) }
            else if customType == "pi-app.native.state.v1" { pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .data) }
            if customType == "pi-app.native.context.v1" { contextIDs = try value.decodeIfPresent(ContextSelection.self, forKey: .data)?.ids ?? [] }
        }
    }
    private static let branchText = "Edited from here · earlier replies stay in the journal"
    private struct Stamp: Equatable {
        var device: Int32; var inode: UInt64; var size: Int64; var modified: Int; var modifiedNS: Int; var changed: Int; var changedNS: Int
    }
    private struct Index { var stamp: Stamp; var branch: [Ref]; var assistantCount: Int; var latestAssistantID: String?; var sessionID: String?; var automaticContextSafe: Bool; var failureMessage: String?; var truncated: Bool }
    private var indexes: [String: Index] = [:]
    // As many bounded offset indexes as the workspace keeps transcript pages, so
    // cycling between open chats does not re-index a large journal each time.
    // Offsets and parent links only; no history bodies.
    private static let retainedIndexes = 8
    private var recency: [String] = []
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
    /// Journals whose offset index is currently retained.
    var retainedIndexCount: Int { recency.count }
    /// Records one offset index holds. Lowered in tests to reach the bound
    /// without writing a hundred thousand records.
    private var indexRecordLimit = 100_000
    func setIndexRecordLimit(_ value: Int) { indexRecordLimit = max(1, value); indexes.removeAll(); recency.removeAll() }
    /// The projection each caller asks for, from one decoded journal record.
    private static func projection(_ value: [String: WireValue], field: String) -> String {
        let content = value["message"]?.object?["content"], blocks = content?.array ?? []
        if field != "thinking", value["type"]?.string == "branch" { return branchText }
        if field != "thinking", value["type"]?.string == "compaction" { return "Conversation summary:\n" + (value["summary"]?.string ?? "") }
        if field == "thinking" { return blocks.compactMap { $0.object?["type"]?.string == "thinking" ? $0.object?["thinking"]?.string : nil }.joined() }
        return content?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
    }
    private func revision(_ stamp: Stamp) -> String { "\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.modified):\(stamp.modifiedNS):\(stamp.changed):\(stamp.changedNS)" }
    private func content(_ ref: Ref, file: FileHandle) throws -> String {
        if ref.type == "branch" { return "## Edit\n\n" + Self.branchText + "\n\n" }
        decodedRecords += 1
        try file.seek(toOffset: ref.offset)
        guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length else { throw StoreError.unreadableRecord }
        return ConversationContent.text(try JSONDecoder().decode(WireValue.self, from: bytes).object ?? [:])
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
            let ref = index.branch[cursor], text = try content(ref, file: file)
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
        let ref = index.branch[cursor.index - 1]
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
        if let index = indexes[path], index.stamp == identity, let ref = index.branch.first(where: { $0.id == id }) {
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
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                // A damaged neighbour must not hide a readable message, and a
                // record written without an id is addressed by its offset — the
                // same identity the page that displayed it was given.
                if let value = try? JSONDecoder().decode(WireValue.self, from: pending).object,
                   value["type"]?.string != "session", (value["id"]?.string ?? "record-\(position)") == id {
                    decodedRecords += 1
                    let text = Self.projection(value, field: field) as NSString
                    decoded = (key, text)
                    return (try UnicodePage.slice(text, offset: offset), text.length)
                }
                position += UInt64(pending.count + 1); pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
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
    func read(path: String, before: String? = nil, around: String? = nil) throws -> HistoryPage {
        let file = try open(path); defer { try? file.close() }
        let identity = try stamp(file)
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard size <= 134_217_728 else { throw StoreError.unreadableRecord }
        var branch: [Ref] = [], notice: String?, assistantCount = 0, latestAssistantID: String?, failureMessage: String?
        var truncated = false
        if let cached = indexes[path], cached.stamp == identity {
            branch = cached.branch; assistantCount = cached.assistantCount; latestAssistantID = cached.latestAssistantID
            failureMessage = cached.failureMessage; truncated = cached.truncated
        }
        else {
        indexes.removeValue(forKey: path)
        var pending = Data(), offset: UInt64 = 0, refs: [String: Ref] = [:], leaf: String?
        var sessionID: String?, native = false, linear = true, pendingWork = false
        var contextIDs: Set<String> = [], contextMessages: [String: (calls: [String], result: String?)] = [:]
        var orderedContext: [String] = [], roles: [String: String] = [:]
        var contextSafe = true, callCount = 0
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
                do {
                    let value = try JSONDecoder().decode(IndexRecord.self, from: pending)
                    if value.type == "session", offset == 0, value.version == 3 { sessionID = value.id }
                    if value.customType == "pi-app.native.v1" { native = true }
                    if let work = value.pendingWork { pendingWork = work.exists; failureMessage = work.failure }
                    if value.type != "session" {
                        let id = value.id ?? "record-\(offset)"
                        guard refs[id] == nil else { throw StoreError.unreadableRecord }
                        // Being longer than one index can hold is not damage.
                        // Reporting it as damage blocked search, copying and
                        // Continue on a conversation whose bytes are all intact.
                        if refs.count >= indexRecordLimit { truncated = true; break }
                        let parent = value.id == nil ? leaf : value.parentId
                        if value.id == nil || parent != leaf { linear = false }
                        if let parent, refs[parent] == nil { throw StoreError.unreadableRecord }
                        refs[id] = Ref(id: id, parent: parent, offset: offset, length: pending.count, type: value.type,
                                       fromMessageID: value.fromMessageId, keptIDs: value.keptIds); leaf = id
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
                            orderedContext=[id]+kept; contextIDs=Set(orderedContext)
                            contextMessages[id] = ([], nil); contextIDs.insert(id)
                        } else if value.type == "branch" {
                            let kept = Set(value.keptIds ?? [])
                            if kept.count != value.keptIds?.count || orderedContext.filter({ kept.contains($0) }) != value.keptIds { contextSafe = false }
                            contextIDs.formIntersection(kept)
                            orderedContext=orderedContext.filter { kept.contains($0) }
                            contextMessages[id] = ([], nil)
                        } else if let replacement = value.contextIDs {
                            let ids = Set(replacement)
                            if ids.count != replacement.count || !ids.isSubset(of: Set(contextMessages.keys)) { contextSafe = false }
                            contextIDs = ids; orderedContext=replacement
                        }
                        // Count durable appends, including abandoned branches,
                        // exactly as the helper does. This is not the visible-page count.
                        if value.type == "message", value.message?.role == "assistant" { assistantCount += 1; latestAssistantID = id }
                    }
                } catch { notice = "Damaged history record preserved. Continue requires validation or an explicit recovered copy."; break }
                offset += UInt64(pending.count + 1); pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            if notice != nil || truncated { break }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.unreadableRecord }
        }
        if !pending.isEmpty && notice == nil && !truncated { notice = "Incomplete tail preserved. No repair was performed." }
        var cursor = leaf
        while let id = cursor, let ref = refs[id] { branch.append(ref); cursor = ref.parent }
        branch.reverse()
        // Native edits append a branch record to the same parent chain. Replay
        // those records before paging/searching so an unloaded session has the
        // same visible timeline as its helper, without decoding message bodies.
        var visible: [Ref] = [], history: [String: Ref] = [:]
        for ref in branch {
            if ref.type == "branch" {
                let kept = ref.keptIDs ?? []
                guard kept.allSatisfy({ history[$0] != nil }) else { notice = "Damaged history record preserved. Branch references unknown messages."; break }
                if let index = visible.firstIndex(where: { $0.id == ref.fromMessageID }) { visible.removeSubrange(index...) }
                else { let ids = Set(kept); visible.removeAll { !ids.contains($0.id) } }
                // A compaction summary can sit after the edited user in the
                // timeline while still belonging to the retained context.
                var shown = Set(visible.map(\.id))
                for id in kept where shown.insert(id).inserted { if let retained = history[id] { visible.append(retained) } }
                visible.append(ref); history[ref.id] = ref
            } else if ref.type == "message" || ref.type == "compaction" { visible.append(ref); history[ref.id] = ref }
        }
        branch = visible
        guard try stamp(file) == identity else { throw StoreError.unreadableRecord }
        let activeCalls = Set(contextIDs.flatMap { contextMessages[$0]?.calls ?? [] })
        let activeResults = Set(contextIDs.compactMap { contextMessages[$0]?.result })
        if notice == nil { indexes[path] = Index(stamp: identity, branch: branch, assistantCount: assistantCount, latestAssistantID: latestAssistantID,
                                               sessionID: sessionID, automaticContextSafe: !truncated && native && linear && !pendingWork && contextSafe && activeCalls.isSubset(of: activeResults), failureMessage: failureMessage, truncated: truncated) }
        }
        recency.removeAll { $0 == path }; recency.append(path)
        while recency.count > Self.retainedIndexes { indexes.removeValue(forKey: recency.removeFirst()) }
        let anchorIndex = around.flatMap { target in branch.firstIndex { $0.id == target } }
        let end = before.flatMap { target in branch.firstIndex { $0.id == target } } ?? branch.count
        var messages: [TranscriptMessage] = [], index = anchorIndex ?? end, bytes = 0
        // Restoring an older viewport starts at its visible message, then fills
        // forward. A byte-limited reverse page could otherwise omit the anchor.
        while (anchorIndex != nil ? index < branch.count : index > 0) && messages.count < 60 {
            let ref = branch[anchorIndex != nil ? index : index - 1]; try file.seek(toOffset: ref.offset)
            guard let data = try file.read(upToCount: ref.length) else { throw StoreError.unreadableRecord }
            let value = try JSONDecoder().decode(WireValue.self, from: data).object ?? [:]
            let message: TranscriptMessage
            if value["type"]?.string == "branch" { message = .init(id: ref.id, role: "system", text: Self.branchText, kind: "branch") }
            else if value["type"]?.string == "compaction" {
                var summary = TranscriptMessage.project(id: ref.id, message: ["role": .string("system"), "content": .string("Conversation summary:\n" + (value["summary"]?.string ?? ""))])
                let kept = Set(value["nativeKeptIDs"]?.array?.compactMap(\.string) ?? []).count
                let tokens = value["tokensBefore"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
                summary.kind = "compaction"; summary.detail = "Compacted \(tokens) tokens · \(kept) message\(kept == 1 ? "" : "s") kept"
                message = summary
            }
            else { message = TranscriptMessage.project(id: ref.id, message: value["message"]?.object ?? [:]) }
            let count = try JSONEncoder().encode(message).count
            if bytes + count > 300_000 { break }
            bytes += count
            if anchorIndex != nil { messages.append(message); index += 1 }
            else { messages.insert(message, at: 0); index -= 1 }
        }
        guard try stamp(file) == identity else { indexes.removeValue(forKey: path); throw StoreError.unreadableRecord }
        let start = anchorIndex ?? index
        return HistoryPage(messages: messages, before: start > 0 && start < branch.count ? branch[start].id : nil, total: branch.count, notice: notice,
                           limitNotice: truncated ? "This conversation is longer than Bello Agent indexes at once. Its first \(branch.count) messages are shown, searchable and copyable; the rest stay in the file untouched." : nil,
                           assistantMessageCount: notice == nil && !truncated ? assistantCount : nil, latestAssistantMessageID: notice == nil && !truncated ? latestAssistantID : nil,
                           failureMessage: notice == nil ? failureMessage : nil,
                           revision: notice == nil ? HistoryRevision(path: path, stamp: revision(identity)) : nil)
    }
}
