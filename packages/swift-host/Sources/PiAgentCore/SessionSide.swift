import Foundation

// A side chat's requests extend its parent's. Its first request repeats the
// parent's last one (tools, instructions, the conversation so far) and adds
// only what the side asks, so it joins the parent's prompt cache: same tools,
// same cache key, and a hidden note that it is a read-only side instead of a
// shorter tool list. Ours: pi has no side chats; this follows Codex CLI's
// /side, which keeps the parent's tools and cache key and adds a hidden
// boundary message, and Claude Code, which keeps its tools and refuses a call
// when it runs.

extension AgentSession {
    /// A chat opened from another's context that is not a fork of it: open
    /// and kept sides alike, since the origin is journaled with a kept side.
    var isSideChat: Bool { parentInfo["parentSessionId"].text != nil && parentInfo["relationship"].text != "fork" }

    /// The prompt cache this session's requests join: a side joins the cache
    /// its parent's requests went to, any other chat its own (pi's session id).
    var promptCacheSessionID: String {
        guard isSideChat else { return id }
        return parentInfo["cacheSessionId"].text ?? parentInfo["parentSessionId"].text ?? id
    }

    /// Whether requests offer the read-only tool list. A read-only side offers
    /// its parent's list, which has the editing tools when the parent can
    /// edit, and refuses those calls when they run (`sideRefusal`). A chat
    /// that is read-only itself offers the read-only list, as pi removes tools.
    var offersReadOnlyTools: Bool { readOnly && !(isSideChat && parentInfo["parentToolMode"].text == "editing") }

    /// What a read-only side answers to a call of an editing tool, before
    /// anything runs. The app keeps a side read-only; a chat forked from it
    /// can have its editing tools turned on.
    func sideRefusal(_ call: ToolCall) -> AgentError? {
        guard readOnly, isSideChat, Self.editingTools.contains(call.name) else { return nil }
        return AgentError("read_only", "Side chats are read-only: \(call.name) is not available here. To make this change, ask in the main chat, or fork this side with /fork and choose Enable Editing Tools… in the new chat's menu.")
    }

    static let sideNote = ContextNote(kind: "side-read-only", text: "This is a side conversation, branched from the conversation above. It is read-only: write, edit and bash are unavailable here, so answer from the conversation and the read-only tools.")
    static let editingNote = ContextNote(kind: "editing-on", text: "Editing tools are now on in this conversation: write, edit and bash are available.")

    /// The hidden note the next user message carries, if any. A read-only
    /// side needs its note once, after the history it inherited: its first
    /// message carries it, and it stays in the context, so every later
    /// request repeats the same prefix. It is sent again only when the
    /// context lost it (an edit before it, a compaction that summarized it).
    /// A chat that holds a side's note and has its editing tools on says so.
    func pendingContextNote() -> ContextNote? {
        var scope = context[...]
        // A side's own note follows what it inherited: a side opened from a
        // saved side inherits that side's note, which is not its own.
        if isSideChat, let cutoff = parentInfo["cutoffEntryId"].text, let index = context.firstIndex(where: { $0.id == cutoff }) {
            scope = context[context.index(after: index)...]
        }
        let latest = scope.last(where: { $0.contextNote != nil })?.contextNote?.kind
        if readOnly { return isSideChat && latest != Self.sideNote.kind ? Self.sideNote : nil }
        return latest == Self.sideNote.kind ? Self.editingNote : nil
    }
}
