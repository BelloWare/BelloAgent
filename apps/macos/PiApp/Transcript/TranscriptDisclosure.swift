import Foundation

/// What the reader has opened or closed in a conversation: a turn's work, one
/// tool call's card, exposed reasoning, a compaction note.
///
/// This belongs to the conversation rather than to a SwiftUI view, for two
/// reasons. A row's height is owned by the AppKit document, which cannot see
/// view-local state and would otherwise learn about a click only when the
/// hosting view happens to invalidate its intrinsic size, one or two run-loop
/// turns later; in between, the row draws at its old height and paints over its
/// neighbours. And a choice made by the reader must survive streaming updates,
/// scrolling a row out of the viewport and switching chats, none of which
/// preserve view-local state reliably.
@MainActor final class TranscriptDisclosure {
    struct Part: Hashable {
        enum Kind: Hashable { case work, tool, reasoning, compaction }
        let kind: Kind
        let id: String
        static func work(_ id: String) -> Part { Part(kind: .work, id: id) }
        static func tool(_ id: String) -> Part { Part(kind: .tool, id: id) }
        static func reasoning(_ id: String) -> Part { Part(kind: .reasoning, id: id) }
        static func compaction(_ id: String) -> Part { Part(kind: .compaction, id: id) }
        /// Work, tool details, reasoning and compaction notes open only on request.
        var openByDefault: Bool { false }
    }
    /// Only what the reader actually changed, so a long conversation keeps no
    /// entry for the rows it never touched.
    private var changed: [Part: Bool] = [:]
    private(set) var revision = 0

    func isOpen(_ part: Part) -> Bool { changed[part] ?? part.openByDefault }
    func setOpen(_ open: Bool, _ part: Part) {
        guard isOpen(part) != open else { return }
        if open == part.openByDefault { changed.removeValue(forKey: part) } else { changed[part] = open }
        revision += 1
    }
    func toggle(_ part: Part) { setOpen(!isOpen(part), part) }
    /// Rows that leave the conversation take their entries with them.
    func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = changed.count
        changed = changed.filter { !ids.contains($0.key.id) }
        if changed.count != before { revision += 1 }
    }
    var changedCount: Int { changed.count }
    var changedIDs: Set<String> { Set(changed.keys.map(\.id)) }
}

/// The disclosure values one row needs, as plain data. A row host compares this
/// like any other content: when it differs the row is re-measured and re-laid
/// out in the same pass as the click that changed it.
struct TranscriptRowDisclosure: Equatable {
    var work = false
    var openTools: Set<String> = []
    var openReasoning: Set<String> = []
    var compaction = false
    /// Full argument documents fetched for this row's open cards. They belong
    /// here for the same reason the open set does: the row is re-measured in
    /// the pass that learns a card now has more to show.
    var toolInputs: [String: ToolInputDocument] = [:]

    static let `default` = TranscriptRowDisclosure()

    /// Reads exactly the parts this item can show, so unrelated changes
    /// elsewhere in the conversation never re-measure this row.
    @MainActor static func of(_ item: TranscriptItem, in store: TranscriptDisclosure,
                              inputs: TranscriptToolInputs? = nil) -> TranscriptRowDisclosure {
        // Until the reader has changed something, every row is at the default,
        // and a streaming delta need not walk each row's tools to find that out.
        guard store.changedCount > 0 || (inputs?.count ?? 0) > 0 else { return .default }
        var value = TranscriptRowDisclosure()
        switch item {
        case .message(let message):
            value.compaction = store.isOpen(.compaction(message.id))
            for tool in message.tools ?? [] where store.isOpen(.tool(tool.id)) { value.openTools.insert(tool.id) }
            if store.isOpen(.reasoning(message.id)) { value.openReasoning.insert(message.id) }
        case .block(let block):
            // `key` stays with the block for its whole life; `id` follows its
            // latest row, so keying on it would reopen a turn as it grows.
            value.work = store.isOpen(.work(block.key))
            for tool in block.tools where store.isOpen(.tool(tool.id)) { value.openTools.insert(tool.id) }
            for reply in block.replies where store.isOpen(.reasoning(reply.id)) { value.openReasoning.insert(reply.id) }
            if let message = block.message {
                value.compaction = store.isOpen(.compaction(message.id))
                for tool in message.tools ?? [] where store.isOpen(.tool(tool.id)) { value.openTools.insert(tool.id) }
            }
        }
        // Only the cards that are open can show a fetched document, so a
        // document landing for a closed card never re-measures this row.
        if let inputs {
            for id in value.openTools {
                if let document = inputs.document(id) { value.toolInputs[id] = document }
            }
        }
        return value
    }
}
