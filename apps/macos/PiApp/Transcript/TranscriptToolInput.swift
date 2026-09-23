import Foundation

// A tool call's arguments, bounded for display and fetched in full on demand.
//
// The helper sends every card a small inline document that always parses: long
// string values are cut one by one and carry the bytes they left out. The app
// reads journals off disk itself, so it bounds them the same way here, and a
// chat restored from a file shows the same card as a live one.
//
// When the reader opens a card whose inline document was cut, the page asks the
// host for the larger per-tool-bounded document through `session.tool.input`
// and re-measures the row when it lands.

/// How a tool call's arguments are cut for display, and the marker that says
/// where. The helper writes the same marker, so a card labels a partial value
/// the same way whether it came from a live snapshot or from a journal.
enum ToolInputDisplay {
    /// What rides along on every display snapshot: the projection re-sends the
    /// whole page on each delta, so the inline document stays small.
    static let inlineBytes = 4096
    /// The on-demand bound for tools whose arguments carry file content.
    static let contentBytes = 65_536
    /// The on-demand bound for every other tool.
    static let otherBytes = 8192
    /// Entries kept per object and elements per array, so even a pathological
    /// argument document has a bounded projection.
    static let maximumEntries = 512
    static func entries(for limit: Int) -> Int { max(8, min(maximumEntries, limit / 64)) }
    /// Prefix of every marker written into a cut value.
    static let truncationMarker = "\u{2026}[truncated,"
    static func marker(bytes: Int) -> String { "\(truncationMarker) \(bytes) more bytes]" }
    static func marker(elements: Int) -> String { "\(truncationMarker) \(elements) more elements]" }
    static func marker(keys: Int) -> String { "\(truncationMarker) \(keys) more keys]" }
    /// Tools whose arguments carry the file content the transcript renders as a
    /// diff get the large bound; everything else gets the small one.
    static func bound(for name: String) -> Int {
        let lowered = name.lowercased()
        if ["edit", "write", "apply_patch", "applypatch", "multi_edit", "multiedit",
            "str_replace", "str_replace_editor", "create_file", "notebook_edit", "patch"].contains(lowered) { return contentBytes }
        if lowered.hasSuffix("_edit") || lowered.hasSuffix("_write") || lowered.hasSuffix("_patch") { return contentBytes }
        return otherBytes
    }
    /// A string cut to whole characters within a byte bound.
    static func preview(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes, bytes > 0 else { return text.utf8.count > bytes ? "" : text }
        var prefix = Data(text.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let value = String(data: prefix, encoding: .utf8) { return value }
            prefix.removeLast()
        }
        return ""
    }

    /// The document with every long string clamped once, so the search below
    /// re-renders a small tree instead of walking the original each round.
    private indirect enum Clamped {
        case leaf(WireValue)
        case text(head: String, full: Int)
        case list([Clamped], omitted: Int)
        case map([(String, Clamped)], omitted: Int)
    }
    private static func clamp(_ value: WireValue, to limit: Int) -> Clamped {
        let kept = entries(for: limit)
        switch value {
        case .string(let text):
            let count = text.utf8.count
            return .text(head: count > limit ? preview(text, bytes: limit) : text, full: count)
        case .array(let items):
            return .list(items.prefix(kept).map { clamp($0, to: limit) }, omitted: max(0, items.count - kept))
        case .object(let members):
            let keys = members.keys.sorted()
            return .map(keys.prefix(kept).map { ($0, clamp(members[$0] ?? .null, to: limit)) }, omitted: max(0, keys.count - kept))
        default: return .leaf(value)
        }
    }
    private static func render(_ node: Clamped, cap: Int) -> WireValue {
        switch node {
        case .leaf(let value): return value
        case .text(let head, let full):
            if full <= cap { return .string(head) }
            let kept = preview(head, bytes: cap)
            return .string(kept + marker(bytes: full - kept.utf8.count))
        case .list(let items, let omitted):
            var out = items.map { render($0, cap: cap) }
            if omitted > 0 { out.append(.string(marker(elements: omitted))) }
            return .array(out)
        case .map(let members, let omitted):
            var out: [String: WireValue] = [:]
            for (key, value) in members { out[key] = render(value, cap: cap) }
            if omitted > 0 { out[truncationMarker] = .string(marker(keys: omitted)) }
            return .object(out)
        }
    }
    static func encoded(_ value: WireValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
    /// The arguments encoded for display within `limit` bytes. The result is
    /// always a document that parses: long string values are cut to the largest
    /// per-value length that fits and carry their omitted byte count, so a card
    /// shows a partial edit rather than a fragment of JSON.
    static func bounded(_ arguments: WireValue, limit: Int = inlineBytes) -> (text: String, truncated: Bool, bytes: Int) {
        let full = encoded(arguments), bytes = full.utf8.count
        guard bytes > limit else { return (full, false, bytes) }
        let tree = clamp(arguments, to: limit)
        var best = encoded(render(tree, cap: 0))
        // The structure alone can exceed the bound; there is nothing further to
        // cut without dropping the keys the card needs.
        guard best.utf8.count <= limit else { return (best, true, bytes) }
        var low = 1, high = limit
        while low <= high {
            let middle = low + (high - low) / 2
            let candidate = encoded(render(tree, cap: middle))
            if candidate.utf8.count <= limit { best = candidate; low = middle + 1 } else { high = middle - 1 }
        }
        return (best, true, bytes)
    }
    /// What a card says about a value that was cut, in the reader's terms.
    static func shortSize(_ bytes: Int) -> String {
        bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) bytes"
    }
}

/// One tool call's full argument document, as the host answers for it.
struct ToolInputDocument: Equatable, Sendable {
    var input: String
    /// True when even the on-demand document is short of the whole request.
    var truncated: Bool
    /// The size of the whole request, whatever was sent.
    var bytes: Int
    /// The call's arguments are still arriving; ask again when it settles.
    var streaming: Bool
}

/// The argument documents this conversation has fetched. Like the disclosure
/// store, this belongs to the conversation rather than to a view: the AppKit
/// document owns row heights and has to re-measure the row in the pass that
/// learns the card has more to show, and the reader's fetch must survive
/// scrolling, streaming updates and switching chats.
@MainActor final class TranscriptToolInputs {
    /// Asks the host for one call's full bounded document.
    var load: ((_ messageID: String, _ callID: String) async throws -> ToolInputDocument)?
    /// Called when a document lands, so the page can republish and the row can
    /// be measured again.
    var onChanged: (() -> Void)?
    private var documents: [String: ToolInputDocument] = [:]
    private var callNames: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var owners: [String: UUID] = [:]
    /// Calls whose fetch failed, so a card asks once rather than on every pass.
    private var refused: Set<String> = []
    private(set) var revision = 0
    var count: Int { documents.count }
    /// How many fetches this conversation has asked for, as test evidence.
    private(set) var requestCount = 0

    func document(_ callID: String) -> ToolInputDocument? {
        if let exact = documents[callID] { return exact }
        // Compatibility for old unscoped callers only when unambiguous.
        let keys = callNames.filter { $0.value == callID }.map(\.key)
        return keys.count == 1 ? documents[keys[0]] : nil
    }
    func isLoading(_ callID: String) -> Bool { inFlight.contains(callID) || inFlight.contains { callNames[$0] == callID } }

    /// Whether opening this card should ask the host for its arguments. Only a
    /// card whose inline document the host had to cut has more to show; a
    /// whole inline document — and every card of an older host or a journal,
    /// which say nothing — is already all of it, and asking would cost a
    /// round trip and a republish for nothing.
    static func needsFullInput(_ tool: ToolView) -> Bool { tool.inputTruncated == true }
    /// The call a click on a row's card opened, when that card has more to
    /// show than its inline document: the reply that made the call and the
    /// call, which is what the host answers for. A work row keys its cards by
    /// reply and call; any other row by the call alone.
    static func cutCard(_ part: TranscriptDisclosure.Part, in item: TranscriptItem) -> (messageID: String, callID: String)? {
        guard part.kind == .tool else { return nil }
        let replies: [TranscriptMessage]
        switch item {
        case .message(let message): replies = [message]
        case .block(let block):
            if block.presentation == .work {
                for reply in block.replies { for tool in reply.tools ?? [] where ToolOccurrence.key(reply.id, tool.id) == part.id {
                    return needsFullInput(tool) ? (reply.id, tool.id) : nil
                } }
                return nil
            }
            replies = block.replies
        }
        for reply in replies { if let tool = (reply.tools ?? []).first(where: { $0.id == part.id }) {
            return needsFullInput(tool) ? (reply.id, tool.id) : nil
        } }
        return nil
    }
    /// Ask for a call's full arguments, once, when its card has more to show.
    func request(messageID: String, tool: ToolView) {
        guard Self.needsFullInput(tool) else { return }
        request(messageID: messageID, callID: tool.id)
    }

    /// Ask for a call's full arguments, once. A call whose arguments are still
    /// arriving is asked again the next time the reader opens its card.
    func request(messageID: String, callID: String) {
        let key = ToolOccurrence.key(messageID,callID)
        guard let load, documents[key] == nil, !inFlight.contains(key), !refused.contains(key) else { return }
        inFlight.insert(key)
        let owner = UUID(); owners[key] = owner
        callNames[key] = callID
        requestCount += 1
        Task { [weak self] in
            let result = try? await load(messageID, callID)
            guard let self else { return }
            guard self.owners[key] == owner else { return }
            self.owners.removeValue(forKey:key); self.inFlight.remove(key)
            guard let result else { self.refused.insert(key); return }
            // A call still writing its arguments is worth asking about again.
            if result.streaming { self.refused.remove(key) } else { self.documents[key] = result }
            self.revision += 1
            self.onChanged?()
        }
    }
    /// Rows that leave the conversation take their documents with them.
    func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = documents.count
        documents = documents.filter { !ids.contains($0.key) }
        inFlight.subtract(ids)
        owners = owners.filter { !ids.contains($0.key) }
        callNames = callNames.filter { !ids.contains($0.key) }
        refused.subtract(ids)
        if documents.count != before { revision += 1 }
    }
    var knownIDs: Set<String> { Set(documents.keys).union(inFlight).union(refused) }
}
