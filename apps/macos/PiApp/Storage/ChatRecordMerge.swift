import Foundation

// What the store keeps when a chat record is written over the one it holds.
// A chat's record is written from many places at once — a send naming the
// chat, a helper reporting its journal, a model choice, a title request, a
// rename, a pin, a topic move — and a write made from a copy read before
// another write landed must not take that other write back. These are the
// rules `MetadataStore.put` applies to every chat record it writes; a new
// field of `ChatRecord` decides here whether an older copy may clear it.

extension ChatRecord {
    /// This record as the store writes it over `previous`, the one it holds.
    ///
    /// - A copy older than the chat's organization (a rename, pin, archive or
    ///   topic move with a higher `organizationRevision`) takes that
    ///   organization back instead of undoing it: path, model and turn
    ///   updates can finish after a rename.
    /// - A copy older than the chat's last connection change (a higher
    ///   `connectionRevision`) takes that connection, its model choices and
    ///   whether the journal is still to move back instead of undoing them.
    /// - A copy with no sidebar order or parent keeps the ones held.
    /// - A copy with no title claim keeps the claim of the title request
    ///   still running, unless the write releases it on purpose
    ///   (`releasingTitleClaim`).
    /// - A background request keeps its title, kind and source chat, and how
    ///   it ended is written once: a copy read before then (a path update)
    ///   does not take its notice, times, outcome or result back.
    func merged(over previous: ChatRecord, releasingTitleClaim: Bool = false) -> ChatRecord {
        var chat = self
        if (previous.organizationRevision ?? 0) > (chat.organizationRevision ?? 0) { chat.applyOrganization(from: previous) }
        if (previous.connectionRevision ?? 0) > (chat.connectionRevision ?? 0) { chat.applyConnection(from: previous) }
        if chat.sidebarOrder == nil { chat.sidebarOrder = previous.sidebarOrder }
        if chat.parentSessionID == nil { chat.parentSessionID = previous.parentSessionID }
        if chat.titleTaskSessionID == nil, !releasingTitleClaim { chat.titleTaskSessionID = previous.titleTaskSessionID }
        if previous.isBackgroundTask {
            chat.title = previous.title; chat.backgroundTask = previous.backgroundTask; chat.sourceSessionID = previous.sourceSessionID
            if chat.backgroundTaskNotice == nil { chat.backgroundTaskNotice = previous.backgroundTaskNotice }
            if chat.backgroundTaskStartedAt == nil { chat.backgroundTaskStartedAt = previous.backgroundTaskStartedAt }
            if chat.backgroundTaskEndedAt == nil { chat.backgroundTaskEndedAt = previous.backgroundTaskEndedAt }
            if chat.backgroundTaskOutcome == nil { chat.backgroundTaskOutcome = previous.backgroundTaskOutcome }
            if chat.backgroundTaskResult == nil { chat.backgroundTaskResult = previous.backgroundTaskResult }
        }
        return chat
    }

    /// This record with its topic kept only while the topic still exists in
    /// the chat's project, and only for a chat that can be in a topic at all:
    /// never one outside every project, a background request or a connection
    /// test. A send or a fork can finish after its topic was removed; its
    /// path and model are still written, and the chat is left ungrouped.
    func fitting(topic: TopicRecord?) -> ChatRecord {
        guard topicID != nil else { return self }
        var chat = self
        if topic?.workspaceID != workspaceID || topic?.isValid != true
            || workspaceID == WorkspaceRecord.scratchID || isUtilityChat {
            chat.topicID = nil
        }
        return chat
    }
}
