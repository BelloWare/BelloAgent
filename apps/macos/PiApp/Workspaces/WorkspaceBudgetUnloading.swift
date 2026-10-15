import Foundation

extension WorkspaceModel {
    /// Accounting ownership, never pane placement (a mounted fork is independent).
    func budgetDescends(_ item: ChatRecord, from owner: String) -> Bool {
        var current = item, seen: Set<String> = []
        while seen.insert(current.id).inserted {
            if current.id == owner { return true }
            guard let id = current.delegation?.budgetOwnerSessionID ?? sideBudgetParent(current),
                  let parent = record(id), parent.workspaceID == item.workspaceID else { return false }
            current = parent
        }
        return false
    }

    func budgetMemberBusy(_ id: String) -> String {
        "Wait for “\(record(id)?.title ?? id)” to finish its work and queued messages before changing this chat."
    }

    func runningBudgetDependent(of owner: String) -> String? {
        displays.keys.sorted().first { id in
            guard id != owner, let view = displays[id], view.hasWork || view.loading,
                  let item = record(id) else { return false }
            return budgetDescends(item,from:owner)
        }
    }

    /// Held through the metadata/configuration commit, not just session.close.
    /// Invalidate already-leased opens as well as rejecting new family work.
    func beginBudgetOwnerChange(_ id: String) throws {
        guard !budgetOwnerChanges.contains(id) else { throw HostError.failure("Wait for this chat’s changes to finish.") }
        if let busy = runningBudgetDependent(of:id) { throw HostError.failure(budgetMemberBusy(busy)) }
        budgetOwnerChanges.insert(id)
        for item in chats where budgetDescends(item,from:id) { connectionGenerations[item.id,default:0] &+= 1 }
    }

    func budgetOwnerIsChanging(_ item: ChatRecord) -> Bool {
        budgetOwnerChanges.contains { budgetDescends(item,from:$0) }
    }

    /// The helper preflights its authoritative runtime family, including sides
    /// outside the chat window and readers without displays, then releases idle
    /// dependents deepest first. A busy reply names the member and closes none.
    /// No side is kept or discarded here; unpublished drafts remain in memory.
    func releaseIdleBudgetDependents(of owner: String, host: HostSupervisor) async throws {
        if let busy = runningBudgetDependent(of:owner) { throw HostError.failure(budgetMemberBusy(busy)) }
        let opening = sessionOpenings.filter { record($0.key).map { budgetDescends($0,from:owner) } == true }
        for value in opening.values { _ = await value.task.result }
        let closing = sessionClosings.filter { record($0.key).map { budgetDescends($0,from:owner) } == true }
        for value in closing.values { await value.task.value }
        let names = Dictionary(uniqueKeysWithValues:opened.union(displays.keys).union([owner]).compactMap { id -> (String,WireValue)? in
            record(id).map { (id,.string($0.title)) }
        })
        let result = try await host.request("session.releaseDependents",sessionID:owner,params:["names":.object(names)])
        for id in result.object?["released"]?.array?.compactMap(\.string) ?? [] { helperSessionDidUnload(id) }
    }

    /// Folder changes hold the project barrier before this preflight and save
    /// the new roots only after every old runtime has actually unloaded.
    func releaseIdleWorkspaceSessions(_ workspaceID: String) async throws {
        guard let host = hosts[workspaceID], host.isReady else { return }
        let ids = opened.filter { record($0)?.workspaceID == workspaceID }.sorted()
        for id in ids where opened.contains(id) {
            try await releaseIdleBudgetDependents(of:id,host:host)
            if opened.contains(id) {
                _ = try await host.request("session.close",sessionID:id)
                helperSessionDidUnload(id)
            }
        }
    }
}
