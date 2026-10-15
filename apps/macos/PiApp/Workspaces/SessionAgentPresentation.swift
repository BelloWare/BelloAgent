import Foundation

extension SessionDisplay {
    func parentAuthoredTask(_ source: TranscriptMessage) -> TranscriptMessage {
        var row = source; row.kind = "agent_message"
        row.nativeAgentDelivery = .object(["version":.number(1), "author":.string("parent"), "childId":.string(id),
            "turn":.number(1), "eventIds":.array([.string(row.id)]), "task":.string("Delegated task")])
        row.skills = nil
        if let number = subagentNumbers[id] { row.agentNumbers = [id: number] }
        return row
    }
    /// The source receipt stays immutable. Only its display receives the
    /// latest child state; later send cards retain their actual target turn.
    func presentAgentState(_ source: TranscriptMessage) -> TranscriptMessage {
        var row = source
        if source.nativeAgentDelivery != nil || source.kind == "agent_message" {
            let ids = Set(AgentMessagePresentation(source).events.map(\.childID))
            row.agentNumbers = Dictionary(ids.compactMap { id in subagentNumbers[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        guard let tools = source.tools, tools.contains(where: { SubagentToolView.isControl($0.name) }) else { return row }
        row.tools = tools.map { source in
            guard SubagentToolView.isControl(source.name) else { return source }
            var original = source
            let value = SubagentToolView(source)
            original.originalSubagentAvailability = value.childID.flatMap { originalSubagentAvailability[$0] }
            let childID = value.childID ?? (source.name == "subagent_report" && isManagedSubagent ? id : nil)
            original.subagentNumber = childID.flatMap { subagentNumbers[$0] }
            let effort = childID.flatMap { subagentEfforts[$0] } ?? SubagentEffort()
            original.subagentEffort = effort.label(value.receiptEffort ?? value.summary?.effort)
            if let id = value.receiptMessageID, let event = agentCoordination[id] {
                original.agentDeliveryState = event.disposition == "pending" && !busy ? "held" : event.disposition
            }
            guard let target = value.target, var summary = childSummaries[target.sessionID],
                  target.matchesOrigin(summary.link),
                  original.name == "subagent_start" || target.turn == nil || target.turn == summary.turn else { return original }
            if let live = original.subagent, live.link == summary.link, live.turn == summary.turn, live.status == summary.status,
               live.progressEpoch == summary.progressEpoch, let progress = live.progress { summary.progress = progress }
            summary.parentWaiting = familyWaiting
            if !busy, (summary.pendingMessages ?? 0) > 0 || summary.deliveryState == "pending" { summary.deliveryState = "held" }
            var tool = original; tool.subagent = summary; tool.subagentEffort = effort.label(summary.effort ?? value.receiptEffort)
            tool.agentHeldByUser = heldAgentChildren.contains(target.sessionID); return tool
        }
        return row
    }
}
