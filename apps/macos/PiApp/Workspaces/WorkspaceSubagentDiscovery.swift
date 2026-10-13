import Foundation

extension WorkspaceModel {
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

    func registerDiscoveredSubagent(_ found: DiscoveredSubagent, workspaceID: String, live: SubagentSummary? = nil) async throws {
        guard let store, !deletingFamilies.contains(found.header.link.budgetOwnerSessionID),
              let child = try await store.registerSubagent(found, workspaceID: workspaceID) else { return }
        guard !isShutDown, !deletingFamilies.contains(found.header.link.budgetOwnerSessionID) else { return }
        if let at = chats.firstIndex(where: { $0.id == child.id }) { if chats[at] != child { chats[at] = child } }
        else { chats.append(child) }
        let summary = live ?? SubagentSummary(link: found.header.link, description: found.header.description, model: found.header.model.model, status: found.status, revision: 0)
        if subagentSummaries[child.id] != summary { subagentSummaries[child.id] = summary }
        displays[child.id]?.isManagedSubagent = true
        displays[child.id]?.subagentStatus = summary.status
        if let issue = child.delegationIssue { displays[child.id]?.notice = issue }
        // Terminal or newly created content is indexed by the normal search
        // scheduler. Streamed progress never reaches this registration path.
    }
}
