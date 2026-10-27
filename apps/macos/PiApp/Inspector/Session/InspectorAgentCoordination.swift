import AppKit

extension SessionInspectorModel {
    func coordination(for row: InspectorRequestRow) -> [AgentCoordinationEntry] {
        coordination.filter {
            $0.sourceAttemptID == row.id || $0.consumingAttemptID == row.id || row.agentDeliveryIDs?.contains($0.id) == true ||
                ($0.childID == row.sessionID && $0.turn == row.childTurn && ["task", "follow_up", "NEW_TASK"].contains($0.kind))
        }
    }
    func readAgentCoordination() async {
        guard let workspace else { return }
        let owner = workspace.record(scope.sessionID)?.delegation?.budgetOwnerSessionID ?? scope.sessionID
        guard let parent = workspace.record(owner), parent.workspaceID == scope.workspaceID, let path = parent.path else { return }
        do {
            let state = try await workspace.history.agentCoordination(path: URL(fileURLWithPath: path), ownerID: owner)
            let linked = try await archive.coordinationRequests(state.entries, ownerID: owner, workspaceID: scope.workspaceID)
            guard !Task.isCancelled else { return }
            numberSubagentGroups(state.subagentNumbers)
            coordination = linked.map { value in
                var entry = value
                if workspace.displays[owner]?.busy != true && entry.disposition == "pending" { entry.disposition = "held" }
                return entry
            }
        } catch is CancellationError { }
        catch { coordination = [] }
    }
    func coordinationMenu(_ entries: [AgentCoordinationEntry]) -> NSView {
        PiKit.MenuButton(title: "Agent messages (\(entries.count))", icon: "arrow.left.arrow.right") { [weak self] in
            for entry in entries {
                PiMenuEntry.note(entry.title + " · " + entry.deliveryLabel)
                PiMenuEntry.button("Source request", enabled: entry.sourceAttemptID != nil) { self?.focusCoordination(entry, consuming: false) }
                PiMenuEntry.button("Consuming request", enabled: entry.consumingAttemptID != nil) { self?.focusCoordination(entry, consuming: true) }
                PiMenuEntry.button("Show source message", enabled: entry.sourceMessageID != nil) { self?.showCoordinationSource(entry) }
                PiMenuEntry.button("Show delivery", enabled: entry.recipientMessageID != nil && entry.disposition == "delivered") { self?.showCoordinationDelivery(entry) }
                if entry.sourceAttemptID == nil || entry.consumingAttemptID == nil { PiMenuEntry.note("No retained request link yet. Capture may be off, expired or not dispatched.") }
                PiMenuEntry.divider
            }
        }
    }
    func focusCoordination(_ entry: AgentCoordinationEntry, consuming: Bool) {
        guard let attempt = consuming ? entry.consumingAttemptID : entry.sourceAttemptID else { return }
        let session = consuming ? entry.recipientID : entry.sourceSessionID
        if session == scope.sessionID || groups.contains(where: { $0.summary.link.childSessionID == session }) {
            setFamilyFilter(.family); focus(.request(attempt))
        } else { workspace?.openInspector(session: session, focus: .request(attempt), originalForkID: originalForkID) }
    }
    func showCoordinationSource(_ entry: AgentCoordinationEntry) {
        guard let workspace else { return }
        if originalForkID != nil { reveal(workspace, entry.sourceSessionID, entry.sourceMessageID); return }
        bringMainWindowForward()
        Task { await workspace.showAgentSource(entry) }
    }
    func showCoordinationDelivery(_ entry: AgentCoordinationEntry) {
        guard let workspace, let message = entry.recipientMessageID else { return }
        if originalForkID != nil { reveal(workspace, entry.recipientID, message); return }
        bringMainWindowForward()
        Task { _ = await workspace.revealMessage(sessionID: entry.recipientID, messageID: message) }
    }
}
