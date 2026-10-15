import Foundation

extension WorkspaceModel {
    /// Every cold-open caller (including Resume) awaits this before receiving
    /// the host. Pages bound wire frames, never the total retained evidence.
    func reconcileCapturedBudget(_ item: ChatRecord, host: HostSupervisor) async throws {
        var after: String?
        repeat {
            try Task.checkCancellation()
            let page = try await host.request("budget.attempts", sessionID: item.id, params: after.map { ["after":.string($0)] } ?? [:])
            let ids = page.object?["attemptIds"]?.array?.compactMap(\.string) ?? []
            let evidence = try await traces.budgetEvidence(attempts: ids, owner: item.id, workspace: item.workspaceID)
            if !evidence.isEmpty {
                let cost = try await host.request("budget.reconcile", sessionID: item.id, params: ["evidence":.array(evidence)])
                observeCost(["cost":cost],sessionID:item.id)
            }
            after = page.object?["next"]?.string
        } while after != nil
    }
}
