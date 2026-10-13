import Foundation

extension WorkspaceModel {
    /// A changed family revision pages journal-backed summaries, including
    /// queued tasks with no capture. No extra read on ordinary token updates.
    func refreshSubagentGroups(parent: ChatRecord, host: HostSupervisor, connection: UUID) async throws {
        var cursor = 0
        repeat {
            let page = try await host.request("subagent.list", sessionID: parent.id, params: ["cursor":.number(Double(cursor))]).object ?? [:]
            guard !isShutDown, !Task.isCancelled, hosts[parent.workspaceID] === host, host.connectionID == connection,
                  record(parent.id)?.workspaceID == parent.workspaceID else { throw CancellationError() }
            for value in page["children"]?.array ?? [] {
                let summary = try JSONDecoder().decode(SubagentSummary.self, from: JSONEncoder().encode(value))
                guard summary.link.budgetOwnerSessionID == parent.id else { throw StoreError.invalidRecord }
                try await traces.recordSubagent(summary, workspaceID: parent.workspaceID)
            }
            guard let next = page["cursor"]?.nonnegativeInteger else { break }
            guard next > cursor else { throw StoreError.invalidRecord }; cursor = next
        } while true
    }
}
