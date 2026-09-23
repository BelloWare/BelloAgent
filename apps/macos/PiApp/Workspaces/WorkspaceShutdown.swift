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
            await moveUnsavedSideDraftsToParents()
            try await flushDrafts()
            for host in hosts.values { try await host.shutdownAndWait() }
            guard await flushProjectSidebarState() else { throw HostError.failure("Project preferences could not be saved in time. Retry the update after storage becomes available.") }
            guard await flushTopicChanges() else { throw HostError.failure("Topic changes could not be saved in time. Retry the update after storage becomes available.") }
            guard await flushReadStates() else { throw HostError.failure("Unread state could not be saved in time. Retry the update after storage becomes available.") }
            // After the drafts: flushing one can give a New chat its record.
            // Which chat to reopen is not worth refusing the update over.
            await flushSelection()
        } catch {
            for host in hosts.values where host.isReady { _ = try? await host.request("workspace.resume") }
            throw error
        }
    }
    func releaseUpdateBarrier() { installPreparing = false }
    /// Stops every helper and waits for each to exit, all at once and bounded
    /// by `shutdownAndWait`. A run stopped this way writes its partial reply
    /// and its final state before its helper exits; an app that answered
    /// AppKit first took that with it, and the chat came back as a crash.
    func stopHostsAndWait() async {
        let stops = hosts.values.map { host in Task { try? await host.shutdownAndWait() } }
        for stop in stops { await stop.value }
    }
    func shutdown() {
        // Quit and update have flushed it; whatever changes from here on is
        // the app coming down, not the reader choosing a chat.
        stopRememberingSelection()
        stopConfigurationRetry()
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
