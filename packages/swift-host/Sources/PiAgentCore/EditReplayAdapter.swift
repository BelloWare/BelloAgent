import Foundation

extension ChatMessage {
    var replayNode: ReplayNode {
        ReplayNode(id: id, role: role, eligible: replayEligible, summary: kind == "compaction",
                   dependencies: compaction?["dependencyIDs"].isNull == false ? compaction?["dependencyIDs"].list.compactMap(\.text) : nil,
                   summarized: compaction?["summarySourceIDs"].isNull == false ? compaction?["summarySourceIDs"].list.compactMap(\.text) : nil,
                   calls: content.filter { $0["type"].text == "toolCall" }.map { $0["id"].text ?? "" }, result: toolCallId)
    }
}
extension AgentSession {
    static func planEdit(_ target: String, history: [ChatMessage], visible: [ChatMessage], context: [ChatMessage]) throws -> HistoricalEditPlan {
        do {
            guard Set(history.map(\.id)).count == history.count else { throw ReplayPlanError(reason: "Duplicate historical identities.") }
            return try EditReplayPlan.prepare(target: target, nodes: Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.replayNode) }), visible: visible.map(\.id), context: context.map(\.id))
        } catch { throw AgentError("edit_target", error.localizedDescription) }
    }
    static func restoreBranch(_ record: JSON, history: [ChatMessage], visible: [ChatMessage], context: [ChatMessage]) throws -> HistoricalEditPlan {
        do {
            let branch = try JSONDecoder().decode(HistoricalBranch.self, from: record.data())
            return try EditReplayPlan.restore(branch, nodes: Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.replayNode) }), visible: visible.map(\.id), context: context.map(\.id))
        } catch { throw AgentError("session_damaged", error.localizedDescription) }
    }
    static func adoptBranch(_ plan: HistoricalEditPlan, history: inout [ChatMessage], visible: inout [ChatMessage], context: inout [ChatMessage], markerID: String) {
        let nodes = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        context = plan.replay.compactMap { nodes[$0] }
        visible = plan.displayPrefix.compactMap { nodes[$0] }
        let displayed = Set(visible.map(\.id)); visible += context.filter { !displayed.contains($0.id) }
        var marker = ChatMessage(role: "system", content: []); marker.id = markerID; marker.kind = "branch"; marker.replayEligible = false; marker.displayText = branchMarkerText
        history.append(marker); visible.append(marker)
    }
}
