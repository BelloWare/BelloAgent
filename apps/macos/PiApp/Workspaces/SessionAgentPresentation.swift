import Foundation

extension SessionDisplay {
    var agentPresentation: AgentTranscriptPresentation {
        AgentTranscriptPresentation(id: id, isManagedSubagent: isManagedSubagent, busy: busy, familyWaiting: familyWaiting,
            subagentNumbers: subagentNumbers, subagentEfforts: subagentEfforts, subagentCosts: subagentCosts,
            originalSubagentAvailability: originalSubagentAvailability, agentCoordination: agentCoordination,
            childSummaries: childSummaries, heldAgentChildren: heldAgentChildren,
            supportsCodexAgents: supportsCodexAgents, supportsMailboxCutin: supportsMailboxCutin, subagentNames: subagentNames, agentSourceEvents: agentSourceEvents)
    }
    func parentAuthoredTask(_ source: TranscriptMessage) -> TranscriptMessage { agentPresentation.parentAuthoredTask(source) }
    func presentAgentState(_ source: TranscriptMessage) -> TranscriptMessage {
        presentedMessageVisits += 1
        return agentPresentation.presentAgentState(source)
    }
}

/// The display's agent inputs, captured with its messages for a history read.
/// Unloaded rows use exactly the presentation they receive on joining the page.
struct AgentTranscriptPresentation: Sendable {
    var id: String
    var isManagedSubagent: Bool
    var busy: Bool
    var familyWaiting: Bool
    var subagentNumbers: [String: Int]
    var subagentEfforts: [String: SubagentEffort]
    var subagentCosts: [String: SubagentCostPresentation]
    var originalSubagentAvailability: [String: OriginalSubagentAvailability]
    var agentCoordination: [String: AgentCoordinationEntry]
    var childSummaries: [String: SubagentSummary]
    var heldAgentChildren: Set<String>
    var supportsCodexAgents = false
    var supportsMailboxCutin = false
    var subagentNames: [String: String] = [:]
    var agentSourceEvents: [String: AgentCoordinationEntry] = [:]

    func present(_ source: TranscriptMessage, firstTask: String?) -> TranscriptMessage {
        let row = presentAgentState(source)
        if isManagedSubagent, row.id == firstTask, row.role == "user", row.nativeAgentDelivery == nil, row.nativeInherited == nil {
            return parentAuthoredTask(row)
        }
        return row
    }
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
        row.codexAgents = supportsCodexAgents
        row.mailboxCutin = supportsMailboxCutin
        row.tools = row.tools?.map { var tool = $0; tool.mailboxCutin = supportsMailboxCutin; return tool }
        if source.nativeInherited != nil { row.earlierVersion = true; row.skills = nil }
        if source.nativeAgentDelivery != nil || source.kind == "agent_message" {
            let ids = Set(AgentMessagePresentation(row).events.map(\.childID))
            row.agentNumbers = Dictionary(ids.compactMap { id in subagentNumbers[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
            row.agentNames = Dictionary(ids.compactMap { id in subagentNames[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        guard let tools = row.tools, tools.contains(where: { SubagentToolView.isControl($0.name) }) else { return row }
        row.tools = tools.map { source in
            guard SubagentToolView.isControl(source.name) else { return source }
            var original = source
            original.codexAgents = supportsCodexAgents
            if supportsCodexAgents, SubagentToolView.codexTools.contains(source.name),
               let event = agentSourceEvents[ToolOccurrence.key(row.id, source.id)] {
                original.agentEvent = event
                original.agentDeliveryState = event.disposition
                if ["send_message", "followup_task", "interrupt_agent"].contains(source.name),
                   let summary = childSummaries[event.recipientID] { original.subagent = summary }
            }
            let value = SubagentToolView(original)
            original.originalSubagentAvailability = value.childID.flatMap { originalSubagentAvailability[$0] }
            let childID = value.childID ?? (source.name == "subagent_report" && isManagedSubagent ? id : nil)
            if value.target?.ownerID == id { original.subagentCost = childID.flatMap { subagentCosts[$0] } }
            original.subagentNumber = childID.flatMap { subagentNumbers[$0] }
            original.subagentTaskName = childID.flatMap { subagentNames[$0] }
            let effort = childID.flatMap { subagentEfforts[$0] } ?? SubagentEffort()
            original.subagentEffort = effort.label(value.receiptEffort ?? value.summary?.effort)
            if let id = value.receiptMessageID, let event = agentCoordination[id] {
                original.agentDeliveryState = event.disposition == "pending" && !busy ? "held" : event.disposition
            }
            guard let target = value.target, var summary = childSummaries[target.sessionID],
                  target.matchesOrigin(summary.link),
                  ["subagent_start", "spawn_agent"].contains(original.name) || target.turn == nil || target.turn == summary.turn else { return original }
            if let live = original.subagent, live.link == summary.link, live.turn == summary.turn, live.status == summary.status,
               live.progressEpoch == summary.progressEpoch, let progress = live.progress { summary.progress = progress }
            summary.parentWaiting = familyWaiting
            if !busy, summary.deliveryState != "waiting_next_turn", (summary.pendingMessages ?? 0) > 0 || summary.deliveryState == "pending" { summary.deliveryState = "held" }
            var tool = original; tool.subagent = summary; tool.subagentEffort = effort.label(summary.effort ?? value.receiptEffort)
            tool.agentHeldByUser = heldAgentChildren.contains(target.sessionID); return tool
        }
        return row
    }
}
