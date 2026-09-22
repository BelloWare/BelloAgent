import Foundation

enum ToolOccurrence {
    static func key(_ message: String, _ call: String) -> String { "\(message.utf8.count):" + message + call }
}

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
        /// `response` folds everything inside one reply — every reasoning
        /// segment, every tool card — and `responseLine` folds the reply
        /// itself down to its summary. Neither clears what the reader had
        /// opened inside: those entries stay, so unfolding restores exactly
        /// the response that was collapsed.
        /// `turnFold` is the end-of-turn fold: closed, which is its default,
        /// means the turn's work is behind its one line, and opening it shows
        /// the turn exactly as it read while it ran.
        enum Kind: Hashable { case work, tool, reasoning, compaction, response, responseLine, turnFold }
        let kind: Kind
        let id: String
        static func work(_ id: String) -> Part { Part(kind: .work, id: id) }
        static func tool(_ id: String) -> Part { Part(kind: .tool, id: id) }
        static func reasoning(_ id: String) -> Part { Part(kind: .reasoning, id: id) }
        static func compaction(_ id: String) -> Part { Part(kind: .compaction, id: id) }
        static func response(_ id: String) -> Part { Part(kind: .response, id: id) }
        static func responseLine(_ id: String) -> Part { Part(kind: .responseLine, id: id) }
        static func turnFold(_ id: String) -> Part { Part(kind: .turnFold, id: id) }
        /// Work, tool details, reasoning and compaction notes open only on
        /// request; a response's own fold is closed, which means nothing is
        /// hidden, and opening it is what collapses the response.
        var openByDefault: Bool { false }
        /// A fold that spans more rows than the one it was clicked in. The
        /// conversation republishes for these, so every row of the response
        /// reaches its new height in the same layout pass.
        var spansRows: Bool { kind == .response || kind == .responseLine || kind == .turnFold }
    }
    /// Only what the reader actually changed, so a long conversation keeps no
    /// entry for the rows it never touched.
    private var changed: [Part: Bool] = [:]
    private(set) var revision = 0
    /// Called when a fold that spans several rows changes, so the conversation
    /// publishes its page again and every row of the response follows.
    var spanningChange: (() -> Void)?

    func isOpen(_ part: Part) -> Bool { changed[part] ?? part.openByDefault }
    func setOpen(_ open: Bool, _ part: Part) {
        guard isOpen(part) != open else { return }
        if open == part.openByDefault { changed.removeValue(forKey: part) } else { changed[part] = open }
        revision += 1
        if part.spansRows { spanningChange?() }
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
    /// The reader folded everything inside this row's response: whatever is
    /// open inside it stays recorded and draws closed until the response is
    /// opened again.
    var responseFolded = false
    /// The reader folded the whole response down to its one line: its header
    /// says what it did, and its other rows draw nothing at all.
    var responseLine = false
    /// This row's turn has ended and its work is behind the turn's one line.
    /// The row keeps its place and everything opened inside it; it draws
    /// nothing until the fold is opened.
    var foldedAway = false
    /// Only a turn's fold control reads this: whether its turn is open.
    var turnFoldOpen = false
    /// Full argument documents fetched for this row's open cards. They belong
    /// here for the same reason the open set does: the row is re-measured in
    /// the pass that learns a card now has more to show.
    var toolInputs: [String: ToolInputDocument] = [:]

    static let `default` = TranscriptRowDisclosure()

    /// Reads exactly the parts this item can show, so unrelated changes
    /// elsewhere in the conversation never re-measure this row.
    @MainActor static func of(_ item: TranscriptItem, in store: TranscriptDisclosure,
                              inputs: TranscriptToolInputs? = nil) -> TranscriptRowDisclosure {
        var value = TranscriptRowDisclosure()
        // A finished turn is folded by default, so this is read before the
        // fast path below: a page nobody has touched still has to draw its
        // folds. It is one optional field per row, not a walk of its tools.
        switch item {
        case .message(let message): value.foldedAway = message.foldGroup.map { !store.isOpen(.turnFold($0)) } ?? false
        case .block(let block):
            value.foldedAway = block.foldGroup.map { !store.isOpen(.turnFold($0)) } ?? false
            value.turnFoldOpen = block.foldControl.map { store.isOpen(.turnFold($0)) } ?? false
        }
        // Until the reader has changed something, every row is at the default,
        // and a streaming delta need not walk each row's tools to find that out.
        guard store.changedCount > 0 || (inputs?.count ?? 0) > 0 else { return value }
        switch item {
        case .message(let message):
            // A response's accounting line is part of the response and folds
            // with it; the row's own id is the response's id.
            if message.kind == "requestInfo" {
                value.responseLine = store.isOpen(.responseLine(message.id))
                value.responseFolded = value.responseLine || store.isOpen(.response(message.id))
            }
            value.compaction = store.isOpen(.compaction(message.id))
            for tool in message.tools ?? [] where store.isOpen(.tool(tool.id)) { value.openTools.insert(tool.id) }
            if store.isOpen(.reasoning(message.id)) { value.openReasoning.insert(message.id) }
        case .block(let block):
            // `key` stays with the block for its whole life; `id` follows its
            // latest row, so keying on it would reopen a turn as it grows.
            value.work = store.isOpen(.work(block.key))
            if let response = block.responseID {
                value.responseLine = store.isOpen(.responseLine(response))
                value.responseFolded = value.responseLine || store.isOpen(.response(response))
            }
            for reply in block.replies { for tool in reply.tools ?? [] {
                let id = block.presentation == .work ? ToolOccurrence.key(reply.id,tool.id) : tool.id
                if store.isOpen(.tool(id)) { value.openTools.insert(id) }
            } }
            for reply in block.replies where store.isOpen(.reasoning(reply.id)) { value.openReasoning.insert(reply.id) }
            // `replies` already holds `message`, so its cards were read above,
            // under the same key the row draws them with.
            if let message = block.message { value.compaction = store.isOpen(.compaction(message.id)) }
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
