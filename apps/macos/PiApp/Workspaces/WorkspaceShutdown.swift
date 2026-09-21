import Foundation

// Closing down: the barrier an update takes before it replaces the app, and
// the shutdown that stops every task, helper and watcher this model owns.

extension WorkspaceModel {
    func acquireUpdateBarrier() -> Bool {
        if installPreparing { return true }
        guard !hasActiveWork else { return false }
        installPreparing = true; return true
    }
    func prepareForInstall() async throws {
        guard installPreparing else { throw HostError.failure("The update idle barrier was not acquired") }
        do {
            // The host also checks authoritative lane state after all accepted
            // preflight commands finish. Native status can lag an acknowledgement.
            for host in hosts.values where host.isReady { _ = try await host.request("workspace.quiesce") }
            try await flushDrafts()
            for host in hosts.values { try await host.shutdownAndWait() }
            guard await flushProjectSidebarState() else { throw HostError.failure("Project preferences could not be saved in time. Retry the update after storage becomes available.") }
            guard await flushTopicChanges() else { throw HostError.failure("Topic changes could not be saved in time. Retry the update after storage becomes available.") }
            guard await flushReadStates() else { throw HostError.failure("Unread state could not be saved in time. Retry the update after storage becomes available.") }
        } catch {
            for host in hosts.values where host.isReady { _ = try? await host.request("workspace.resume") }
            throw error
        }
    }
    func releaseUpdateBarrier() { installPreparing = false }
    func shutdown() {
        navigationTask?.cancel(); navigationTask = nil
        for view in displays.values { view.presentation.cancel() }
        liveActivity.shutdown()
        cancelAutomaticContext()
        for pending in hostStarts.values { pending.task.cancel() }
        for pending in sessionOpenings.values { pending.task.cancel() }
        SessionUsageWindows.shared.closeAll(owner: self)
        for task in titleGenerationTasks.values { task.cancel() }
        titleGenerationTasks.removeAll()
        accountingStopped = true
        for task in accountingTasks.values { task.cancel() }
        accountingTasks.removeAll(); dirtyAccounting.removeAll()
        for host in hosts.values { host.shutdown() }
        TerminalRegistry.shared.shutdown()
    }
}
