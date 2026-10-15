import Foundation

struct AgentMessageReference: Sendable, Equatable {
    var childID: String, turn: Int
    var eventID: String? = nil
    var recipient = false
}

extension WorkspaceModel {
    func openAgentSource(_ reference: AgentMessageReference, from sessionID: String) async {
        let navigation = selectionRevision
        guard let child = record(reference.childID), let link = child.delegation, link.valid,
              [link.budgetOwnerSessionID, child.id].contains(sessionID), let parent = record(link.budgetOwnerSessionID),
              parent.workspaceID == child.workspaceID, let path = parent.path else { return }
        let reader = subagentTab(sessionID)?.renewNavigation()
        func current() -> Bool { !Task.isCancelled && (reader?.isCurrent ?? (selectionRevision == navigation)) }
        do {
            let state: AgentCoordination
            if let agentCoordinationLoader { state = try await agentCoordinationLoader(URL(fileURLWithPath: path), parent.id) }
            else { state = try await history.agentCoordination(path: URL(fileURLWithPath: path), ownerID: parent.id) }
            guard current() else { return }
            if let entry = state.entries.first(where: { $0.id == reference.eventID && $0.childID == child.id && $0.turn == reference.turn }) {
                if reference.recipient {
                    if let row = entry.recipientMessageID, entry.disposition == "delivered" { _ = await revealMessage(sessionID: entry.recipientID, messageID: row) }
                    else { await openSubagentParent(link) }
                } else { await showAgentSource(entry) }
            } else if sessionID == child.id { await openSubagentParent(link) }
            else { var target = SubagentTarget(link); target.turn = reference.turn; _ = await openSubagent(target) }
        } catch is CancellationError { }
        catch { if current() { displays[sessionID]?.notice = "The source message could not be read. " + error.localizedDescription } }
    }
    func showAgentSource(_ entry: AgentCoordinationEntry) async {
        guard let child = record(entry.childID), let link = child.delegation, link.valid,
              let parent = record(link.budgetOwnerSessionID), parent.workspaceID == child.workspaceID else { return }
        if entry.sourceSessionID == parent.id {
            var target = SubagentTarget(link); target.receiptSource = true; target.turn = entry.turn
            target.assistantID = entry.sourceMessageID ?? target.assistantID; target.toolCallID = entry.sourceToolCallID ?? target.toolCallID
            await openSubagentParent(link, returningTo: target)
        } else if entry.sourceSessionID == child.id {
            var target = SubagentTarget(link); target.turn = entry.turn
            guard await openSubagent(target), let message = entry.sourceMessageID else { return }
            _ = await revealInTranscript(sessionID: child.id, messageID: message, toolCallID: entry.sourceToolCallID)
        }
    }
}
