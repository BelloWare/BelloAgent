import Foundation
import Darwin

struct HistoryPage: Sendable {
    var messages: [TranscriptMessage]; var before: String?; var total: Int; var notice: String?
    var assistantMessageCount: Int? = nil
    var latestAssistantMessageID: String? = nil
    var failureMessage: String? = nil
}

// Read-only archive browsing does not launch Node or construct a Pi runtime.
// First index record offsets and parent links; decode only the requested page.
actor HistoryReader {
    private struct Ref {
        var id: String; var parent: String?; var offset: UInt64; var length: Int; var type: String?
        var fromMessageID: String?; var keptIDs: [String]?
    }
    private struct IndexRecord: Decodable {
        var type: String?; var id: String?; var parentId: String?
        var fromMessageId: String?; var keptIds: [String]?; var nativeKeptIDs: [String]?; var contextIDs: [String]?
        var version: Int?; var customType: String?; var pendingWork: PendingWork?
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
            var role: String?; var toolCallId: String?; var calls: [String]; var contentIndexed: Bool
            private enum CodingKeys: String, CodingKey { case role, toolCallId, content }
            init(from decoder: Decoder) throws {
                let value = try decoder.container(keyedBy: CodingKeys.self)
                role = try value.decodeIfPresent(String.self, forKey: .role)
                toolCallId = try value.decodeIfPresent(String.self, forKey: .toolCallId)
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
        private enum CodingKeys: String, CodingKey { case type, id, parentId, fromMessageId, keptIds, nativeKeptIDs, version, customType, nativeState, data, message }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            type = try value.decodeIfPresent(String.self, forKey: .type); id = try value.decodeIfPresent(String.self, forKey: .id)
            parentId = try value.decodeIfPresent(String.self, forKey: .parentId)
            fromMessageId = try value.decodeIfPresent(String.self, forKey: .fromMessageId); keptIds = try value.decodeIfPresent([String].self, forKey: .keptIds)
            nativeKeptIDs = try value.decodeIfPresent([String].self, forKey: .nativeKeptIDs)
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
    private struct Index { var stamp: Stamp; var branch: [Ref]; var assistantCount: Int; var latestAssistantID: String?; var sessionID: String?; var automaticContextSafe: Bool; var failureMessage: String? }
    private var indexes: [String: Index] = [:]
    private var recency: [String] = [] // At most three bounded offset indexes; no full history bodies.
    private func revision(_ stamp: Stamp) -> String { "\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.modified):\(stamp.modifiedNS):\(stamp.changed):\(stamp.changedNS)" }
    private func content(_ ref: Ref, file: FileHandle) throws -> String {
        if ref.type == "branch" { return "## Edit\n\n" + Self.branchText + "\n\n" }
        try file.seek(toOffset: ref.offset)
        guard let bytes = try file.read(upToCount: ref.length), bytes.count == ref.length else { throw StoreError.invalidRecord }
        return ConversationContent.text(try JSONDecoder().decode(WireValue.self, from: bytes).object ?? [:])
    }
    func searchContent(path: String, query: String, start: Int) throws -> ContentSearch {
        guard query.count <= 256, start >= 0 else { throw StoreError.invalidRecord }
        let page = try read(path: path)
        guard page.notice == nil, let index = indexes[path] else { throw HostError.failure("Validate or recover damaged history before searching it") }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        guard try stamp(file) == index.stamp else { throw StoreError.invalidRecord }
        var hits: [ContentHit] = [], cursor = min(start, index.branch.count)
        while cursor < index.branch.count && hits.count < 100 {
            let ref = index.branch[cursor], text = try content(ref, file: file)
            if query.isEmpty { hits.append(.init(id: ref.id, position: cursor + 1, preview: String(text.prefix(240)))) }
            else if let range = text.range(of: query, options: [.caseInsensitive]) {
                let from = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                hits.append(.init(id: ref.id, position: cursor + 1, preview: String(text[from...].prefix(240))))
            }
            cursor += 1
        }
        guard try stamp(file) == index.stamp else { throw StoreError.invalidRecord }
        return .init(hits: hits, total: index.branch.count, next: cursor < index.branch.count ? cursor : nil, revision: revision(index.stamp))
    }
    func copyContentPage(path: String, first: Int, last: Int, cursor: ContentCursor, revision expected: String) throws -> ContentPage {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        guard let index = indexes[path], try stamp(file) == index.stamp, revision(index.stamp) == expected else { throw HostError.failure("History changed. Refresh the range before copying") }
        guard first >= 1, last >= first, last <= index.branch.count, cursor.index >= first, cursor.index <= last else { throw StoreError.invalidRecord }
        let full = try content(index.branch[cursor.index - 1], file: file) as NSString
        let text = try UnicodePage.slice(full, offset: cursor.offset), end = cursor.offset + (text as NSString).length
        guard try stamp(file) == index.stamp else { throw StoreError.invalidRecord }
        return .init(text: text, next: end < full.length ? .init(index: cursor.index, offset: end) : cursor.index < last ? .init(index: cursor.index + 1, offset: 0) : nil)
    }
    private func stamp(_ file: FileHandle) throws -> Stamp {
        var value = stat(); guard fstat(file.fileDescriptor, &value) == 0 else { throw StoreError.invalidRecord }
        return Stamp(device: value.st_dev, inode: value.st_ino, size: value.st_size, modified: value.st_mtimespec.tv_sec, modifiedNS: value.st_mtimespec.tv_nsec, changed: value.st_ctimespec.tv_sec, changedNS: value.st_ctimespec.tv_nsec)
    }
    func validateIdentity(path: String, id: String) throws {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        guard let bytes = try file.read(upToCount: 65_536), let newline = bytes.firstIndex(of: 10) else { throw StoreError.invalidRecord }
        let header = try JSONDecoder().decode(WireValue.self, from: bytes[..<newline]).object ?? [:]
        guard header["type"]?.string == "session", header["id"]?.string == id, header["version"]?.number == 3, try read(path: path).notice == nil else { throw StoreError.invalidRecord }
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
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        guard try file.seekToEnd() <= 134_217_728 else { throw StoreError.invalidRecord }; try file.seek(toOffset: 0)
        var pending = Data()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.invalidRecord }
                let value = try JSONDecoder().decode(WireValue.self, from: pending).object ?? [:]
                if value["id"]?.string == id {
                    let content = value["message"]?.object?["content"], blocks = content?.array ?? []
                    let text: String
                    if field != "thinking", value["type"]?.string == "branch" { text = Self.branchText }
                    else if field != "thinking", value["type"]?.string == "compaction" { text = "Conversation summary:\n" + (value["summary"]?.string ?? "") }
                    else { text = field == "thinking" ? blocks.compactMap { $0.object?["type"]?.string == "thinking" ? $0.object?["thinking"]?.string : nil }.joined() :
                        content?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined() }
                    let utf16 = text as NSString
                    return (try UnicodePage.slice(utf16, offset: offset), utf16.length)
                }
                pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.invalidRecord }
        }
        throw HostError.failure("The retained message is unavailable")
    }
    func read(path: String, before: String? = nil, around: String? = nil) throws -> HistoryPage {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        let identity = try stamp(file)
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard size <= 134_217_728 else { throw StoreError.invalidRecord }
        var branch: [Ref] = [], notice: String?, assistantCount = 0, latestAssistantID: String?, failureMessage: String?
        if let cached = indexes[path], cached.stamp == identity {
            branch = cached.branch; assistantCount = cached.assistantCount; latestAssistantID = cached.latestAssistantID
            failureMessage = cached.failureMessage
        }
        else {
        indexes.removeValue(forKey: path)
        var pending = Data(), offset: UInt64 = 0, refs: [String: Ref] = [:], leaf: String?
        var sessionID: String?, native = false, linear = true, pendingWork = false
        var contextIDs: Set<String> = [], contextMessages: [String: (calls: [String], result: String?)] = [:]
        var contextSafe = true, callCount = 0
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                pending.append(chunk[start..<index]); guard pending.count <= 33_554_432 else { throw StoreError.invalidRecord }
                do {
                    let value = try JSONDecoder().decode(IndexRecord.self, from: pending)
                    if value.type == "session", offset == 0, value.version == 3 { sessionID = value.id }
                    if value.customType == "pi-app.native.v1" { native = true }
                    if let work = value.pendingWork { pendingWork = work.exists; failureMessage = work.failure }
                    if value.type != "session" {
                        let id = value.id ?? "record-\(offset)"
                        guard refs.count < 100_000, refs[id] == nil else { throw StoreError.invalidRecord }
                        let parent = value.id == nil ? leaf : value.parentId
                        if value.id == nil || parent != leaf { linear = false }
                        if let parent, refs[parent] == nil { throw StoreError.invalidRecord }
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
                            contextIDs.insert(id)
                        } else if value.type == "compaction" {
                            contextIDs = Set(value.nativeKeptIDs ?? []).intersection(contextMessages.keys)
                            contextMessages[id] = ([], nil); contextIDs.insert(id)
                        } else if value.type == "branch" {
                            let kept = Set(value.keptIds ?? [])
                            if !kept.isSubset(of: Set(contextMessages.keys)) { contextSafe = false }
                            contextIDs.formIntersection(kept)
                            contextMessages[id] = ([], nil)
                        } else if let replacement = value.contextIDs {
                            let ids = Set(replacement)
                            if !ids.isSubset(of: Set(contextMessages.keys)) { contextSafe = false }
                            contextIDs = ids
                        }
                        // Count durable appends, including abandoned branches,
                        // exactly as the helper does. This is not the visible-page count.
                        if value.type == "message", value.message?.role == "assistant" { assistantCount += 1; latestAssistantID = id }
                    }
                } catch { notice = "Damaged history record preserved. Continue requires validation or an explicit recovered copy."; break }
                offset += UInt64(pending.count + 1); pending.removeAll(keepingCapacity: true); start = chunk.index(after: index)
            }
            if notice != nil { break }
            pending.append(chunk[start...]); guard pending.count <= 33_554_432 else { throw StoreError.invalidRecord }
        }
        if !pending.isEmpty && notice == nil { notice = "Incomplete tail preserved. No repair was performed." }
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
        guard try stamp(file) == identity else { throw StoreError.invalidRecord }
        let activeCalls = Set(contextIDs.flatMap { contextMessages[$0]?.calls ?? [] })
        let activeResults = Set(contextIDs.compactMap { contextMessages[$0]?.result })
        if notice == nil { indexes[path] = Index(stamp: identity, branch: branch, assistantCount: assistantCount, latestAssistantID: latestAssistantID,
                                               sessionID: sessionID, automaticContextSafe: native && linear && !pendingWork && contextSafe && activeCalls.isSubset(of: activeResults), failureMessage: failureMessage) }
        }
        recency.removeAll { $0 == path }; recency.append(path)
        while recency.count > 3 { indexes.removeValue(forKey: recency.removeFirst()) }
        let anchorIndex = around.flatMap { target in branch.firstIndex { $0.id == target } }
        let end = before.flatMap { target in branch.firstIndex { $0.id == target } } ?? branch.count
        var messages: [TranscriptMessage] = [], index = anchorIndex ?? end, bytes = 0
        // Restoring an older viewport starts at its visible message, then fills
        // forward. A byte-limited reverse page could otherwise omit the anchor.
        while (anchorIndex != nil ? index < branch.count : index > 0) && messages.count < 60 {
            let ref = branch[anchorIndex != nil ? index : index - 1]; try file.seek(toOffset: ref.offset)
            guard let data = try file.read(upToCount: ref.length) else { throw StoreError.invalidRecord }
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
        guard try stamp(file) == identity else { indexes.removeValue(forKey: path); throw StoreError.invalidRecord }
        let start = anchorIndex ?? index
        return HistoryPage(messages: messages, before: start > 0 && start < branch.count ? branch[start].id : nil, total: branch.count, notice: notice,
                           assistantMessageCount: notice == nil ? assistantCount : nil, latestAssistantMessageID: notice == nil ? latestAssistantID : nil, failureMessage: notice == nil ? failureMessage : nil)
    }
}
