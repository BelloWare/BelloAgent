import Foundation

/// Read-only replay for portable export and parity tests. Unlike AgentSession,
/// this reducer performs no recovery writes and never opens tools or a queue.
struct ConversationReplay {
    var history: [ChatMessage] = [], visible: [ChatMessage] = [], context: [ChatMessage] = []
    init(_ records: [JSON] = []) throws {
        for record in records { try consume(record) }
    }
    mutating func consume(_ record: JSON) throws {
        if record["type"].text == "message" {
            let message = try ChatMessage(id: identity(record["id"]), pi: record["message"])
            history.append(message); visible.append(message); if message.replayEligible { context.append(message) }
        } else if record["type"].text == "compaction" {
            let restored = try CompactionCheckpoint.restore(record, context: context)
            context = [restored.summary] + restored.kept; history.append(restored.summary); visible.append(restored.summary)
        } else if record["type"].text == "branch" {
            if !record["nativeBranchVersion"].isNull {
                let plan = try AgentSession.restoreBranch(record, history: history, visible: visible, context: context)
                AgentSession.adoptBranch(plan, history: &history, visible: &visible, context: &context, markerID: try identity(record["id"]))
            } else {
                let ids = try CompactionCheckpoint.identities(record["keptIds"]), kept = Set(ids)
                guard context.filter({ kept.contains($0.id) }).map(\.id) == ids else { throw CompactionCheckpoint.damaged("Invalid legacy branch") }
                AgentSession.branch(history: &history, context: &context, visible: &visible, from: record["fromMessageId"].text ?? "", keptIDs: kept, markerID: try identity(record["id"]))
            }
        } else if record["customType"].text == "pi-app.native.context.v1" {
            let nodes = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ids = try CompactionCheckpoint.identities(record["data"]["ids"])
            context = try ids.map { guard let node = nodes[$0] else { throw CompactionCheckpoint.damaged("Missing context source") }; return node }
            let selected = EditReplayPlan.forkTimeline(visible: visible.map(\.id), boundary: ids)
            if !record["data"]["visibleIDs"].isNull, try CompactionCheckpoint.identities(record["data"]["visibleIDs"]) != selected { throw CompactionCheckpoint.damaged("Invalid fork timeline") }
            visible = selected.compactMap { nodes[$0] }
        }
    }
}
extension AgentSession {
    public func prepareEdit(_ messageID: String, offset: Int = 0, expectedTimeline: String? = nil, expectedTextDigest: String? = nil) throws -> JSON {
        guard !closed, !ephemeral else { throw AgentError("edit_unavailable", "Keep and reopen this conversation before editing.") }
        let plan = try Self.planEdit(messageID, history: history, visible: visible, context: context)
        guard let message = history.first(where: { $0.id == messageID }) else { throw AgentError("edit_target", "The message is not retained.") }
        let text = message.displayText ?? message.text
        guard text.utf8.count <= 262_144 else { throw AgentError("message_limit", "The original input exceeds the editor limit.") }
        let digest = sha256(Data(text.utf8))
        guard expectedTimeline == nil || expectedTimeline == plan.sourceTimeline, expectedTextDigest == nil || expectedTextDigest == digest else { throw AgentError("edit_changed", "The source changed during edit preparation. Select the message again.") }
        var page = try textPage(text, offset: offset)
        page["messageId"] = JSON(messageID); page["sourceTimeline"] = JSON(plan.sourceTimeline); page["sourceTextDigest"] = JSON(digest)
        if offset == 0 {
            page["input"] = message.userInput ?? .null
            page["legacyInputs"] = JSON(message.userInput == nil && (message.displayText != nil && message.displayText != message.text || message.content.contains { $0["type"].text == "image" }))
        }
        return page
    }
}
