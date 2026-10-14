import Foundation

extension SessionDisplay {
    func parentAuthoredTask(_ source: TranscriptMessage) -> TranscriptMessage {
        var row = source; row.kind = "agent_message"
        row.nativeAgentDelivery = .object(["version":.number(1), "author":.string("parent"), "childId":.string(id),
            "turn":.number(1), "eventIds":.array([.string(row.id)]), "task":.string("Delegated task")])
        row.skills = nil
        return row
    }
    /// The source receipt stays immutable. Only its display receives the
    /// latest child state; later send cards retain their actual target turn.
    func presentAgentState(_ source: TranscriptMessage) -> TranscriptMessage {
        guard let tools = source.tools, tools.contains(where: { SubagentToolView.isControl($0.name) }) else { return source }
        var row = source
        row.tools = tools.map { original in
            guard let target = SubagentToolView(original).target, var summary = childSummaries[target.sessionID],
                  target.matchesOrigin(summary.link),
                  original.name == "subagent_start" || target.turn == nil || target.turn == summary.turn else { return original }
            if let live = original.subagent, live.link == summary.link, live.turn == summary.turn, live.status == summary.status, let progress = live.progress { summary.progress = progress }
            summary.parentWaiting = familyWaiting
            if !busy, (summary.pendingMessages ?? 0) > 0 || summary.deliveryState == "pending" { summary.deliveryState = "held" }
            var tool = original; tool.subagent = summary; return tool
        }
        return row
    }
}
