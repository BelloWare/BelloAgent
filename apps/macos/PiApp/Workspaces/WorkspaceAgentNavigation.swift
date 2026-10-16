import Foundation

struct AgentMessageReference: Sendable, Equatable {
    var childID: String, turn: Int
    var eventID: String? = nil
    var recipient = false
}

extension WorkspaceModel {
    func openAgentSource(_ reference: AgentMessageReference, from sessionID: String) async {
        guard let child = record(reference.childID), let link = child.delegation, link.valid,
              [link.budgetOwnerSessionID, child.id].contains(sessionID), let parent = record(link.budgetOwnerSessionID),
              parent.workspaceID == child.workspaceID, let path = parent.path else { return }
        let navigation = transcriptNavigation(sessionID, advancing: true)
        func current() -> Bool { !Task.isCancelled && navigation.isCurrent(in: self) }
        do {
            let state: AgentCoordination
            if let agentCoordinationLoader { state = try await agentCoordinationLoader(URL(fileURLWithPath: path), parent.id) }
            else { state = try await history.agentCoordination(path: URL(fileURLWithPath: path), ownerID: parent.id) }
            guard current() else { return }
            if let entry = state.entries.first(where: { $0.id == reference.eventID && $0.childID == child.id && $0.turn == reference.turn }) {
                if reference.recipient {
                    if let row = entry.recipientMessageID, entry.disposition == "delivered" { _ = await revealMessage(sessionID: entry.recipientID, messageID: row, origin: navigation.reader) }
                    else { await openSubagentParent(link, origin: navigation.reader) }
                } else { await showAgentSource(entry, origin: navigation.reader) }
            } else if sessionID == child.id { await openSubagentParent(link, origin: navigation.reader) }
            else { var target = SubagentTarget(link); target.turn = reference.turn; _ = await openSubagent(target) }
        } catch is CancellationError { }
        catch { if current() { displays[sessionID]?.notice = "The source message could not be read. " + error.localizedDescription } }
    }
    func showAgentSource(_ entry: AgentCoordinationEntry, origin: HostedReaderToken? = nil) async {
        guard !Task.isCancelled, origin?.isCurrent != false else { return }
        guard let child = record(entry.childID), let link = child.delegation, link.valid,
              let parent = record(link.budgetOwnerSessionID), parent.workspaceID == child.workspaceID else { return }
        if entry.sourceSessionID == parent.id {
            let origin = origin ?? subagentTab(child.id)?.renewNavigation()
            var target = SubagentTarget(link); target.receiptSource = true; target.turn = entry.turn
            target.assistantID = entry.sourceMessageID ?? target.assistantID; target.toolCallID = entry.sourceToolCallID ?? target.toolCallID
            await openSubagentParent(link, returningTo: target, origin: origin)
        } else if entry.sourceSessionID == child.id {
            var target = SubagentTarget(link); target.turn = entry.turn
            _ = await openSubagent(target, sourceMessage: entry.sourceMessageID, sourceToolCall: entry.sourceToolCallID)
        }
    }
}
