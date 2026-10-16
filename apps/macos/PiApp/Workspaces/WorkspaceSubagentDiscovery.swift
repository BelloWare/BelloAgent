import Foundation

extension WorkspaceModel {
    /// Side panes and copied transcript views also need the cached child names.
    /// Only seed newly inserted displays; progress updates keep their identity.
    func seedSubagentNumbers(replacing previous: [String: SessionDisplay]) {
        let added = displays.filter { previous[$0.key] !== $0.value }
        guard !added.isEmpty else { return }
        let numbers = Dictionary(chats.compactMap { chat in chat.subagentNumber.map { (chat.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for display in added.values {
            display.subagentNumbers.merge(numbers, uniquingKeysWith: { _, saved in saved })
            display.subagentEfforts = subagentEfforts
            display.subagentCosts = budgetStates.reduce(into: [:]) { result, entry in
                if record(entry.key)?.delegation?.budgetOwnerSessionID == display.id, entry.value.reading.spentUSD != nil {
                    result[entry.key] = SubagentCostPresentation(costReading(for:entry.key))
                }
            }
        }
    }

    /// Recover child metadata without starting a helper or resuming any run.
    /// The scan is actor-isolated; only validated small identities reach UI.
    func reconcileSubagents(parentID: String? = nil) async {
        guard store != nil else { return }
        let projects = parentID.flatMap { record($0)?.workspaceID }.map { Set([$0]) } ?? Set(workspaces.map(\.id) + chats.map(\.workspaceID))
        for project in projects where project != WorkspaceRecord.scratchID {
            do {
                let directory = try subagentDirectory(project)
                let found = try await history.discoverSubagents(directory: directory, parents: chats.filter { $0.workspaceID == project })
                guard !Task.isCancelled, !isShutDown else { return }
                for child in found where parentID == nil || child.header.link.budgetOwnerSessionID == parentID {
                    try await registerDiscoveredSubagent(child, workspaceID: project)
                }
            } catch is CancellationError { return }
            catch { self.error = "Sub-agent history could not be reconciled. " + error.localizedDescription }
        }
    }

    func registerDiscoveredSubagent(_ found: DiscoveredSubagent, workspaceID: String, live: SubagentSummary? = nil, connection: UUID? = nil) async throws {
        guard let store, !deletingFamilies.contains(found.header.link.budgetOwnerSessionID),
              let child = try await store.registerSubagent(found, workspaceID: workspaceID) else { return }
        guard !isShutDown, !deletingFamilies.contains(found.header.link.budgetOwnerSessionID) else { return }
        try Task.checkCancellation()
        if let connection, hosts[workspaceID]?.connectionID != connection { throw CancellationError() }
        publishSubagentMetadata(child)
        publishSubagentEffort(found.header.model, child: child)
        // No terminal row means only "interrupted if restored", not evidence
        // that an attached child has stopped. Do not discard live progress on
        // a topic move, archive/restore or repeated discovery.
        let previous = subagentSummaries[child.id]
        let retained = previous.flatMap { value in
            value.link == found.header.link && value.revision > 0 &&
                ((value.turn ?? 1) > (found.turn ?? 1) || ((value.turn ?? 1) == (found.turn ?? 1) && (!found.hasTerminalRecord || value.status == found.status))) ? value : nil
        }
        let summary = live ?? retained ?? SubagentSummary(link: found.header.link, description: found.header.description, model: found.header.model.model, status: found.status, revision: 0, turn: found.turn, executionID: found.executionID, effort: found.effort ?? found.header.model.thinkingLevel, costPaused: found.costPaused ? true : nil)
        if let live, let previous, !live.supersedes(previous) { return }
        if subagentSummaries[child.id] != summary { subagentSummaries[child.id] = summary }
        if live != nil { observeSubagentCost(summary) }
        if let owner = displays[summary.link.budgetOwnerSessionID], owner.childSummaries[child.id] != summary { owner.childSummaries[child.id] = summary }
        displays[child.id]?.isManagedSubagent = true
        displays[child.id]?.subagentStatus = summary.status
        displays[child.id]?.subagentTurn = summary.turn
        if let issue = child.delegationIssue { displays[child.id]?.notice = issue }
        // Terminal or newly created content is indexed by the normal search
        // scheduler. Streamed progress never reaches this registration path.
    }

    func publishSubagentMetadata(_ child: ChatRecord) {
        if let at = chats.firstIndex(where: { $0.id == child.id }) {
            let current = child.merged(over: chats[at])
            if chats[at] != current { chats[at] = current }
        }
        else { chats.append(child) }
        if let number = child.subagentNumber {
            for display in displays.values where display.subagentNumbers[child.id] != number {
                display.subagentNumbers[child.id] = number
            }
        }
    }

    func interruptSubagents(workspaceID: String) {
        for child in chats where child.workspaceID == workspaceID && child.isSubagent {
            // A turn held at its family's cost limit is not running: the
            // helper's loss leaves it waiting for Resume, not interrupted.
            guard var summary = subagentSummaries[child.id], !summary.status.terminal, summary.costPaused != true else { continue }
            summary.status = .interrupted; summary.revision = 0; summary.progress = nil; summary.progressEpoch = nil
            subagentSummaries[child.id] = summary; displays[child.id]?.subagentStatus = .interrupted
            displays[summary.link.budgetOwnerSessionID]?.childSummaries[child.id] = summary
        }
    }
}
