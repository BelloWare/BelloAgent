import Foundation

extension WorkspaceModel {
    /// Cards keep original ownership even when copied into a fork. Navigation
    /// validates the reciprocal child header inside this project's directory.
    func openSubagent(_ target: SubagentTarget) async {
        let navigation = selectionRevision
        do {
            guard let parent = record(target.ownerID), store != nil else { throw HostError.failure("The parent chat is unavailable. The saved child can still be opened from search.") }
            let directory = try subagentDirectory(parent.workspaceID)
            let path = directory.appendingPathComponent(target.sessionID + ".jsonl")
            let header = try await history.subagentHeader(path: path, directory: directory, expected: target)
            guard !isShutDown, !Task.isCancelled, selectionRevision == navigation, record(parent.id)?.workspaceID == parent.workspaceID else { return }
            if record(target.sessionID) == nil { await reconcileSubagents(parentID: parent.id) }
            guard let child = record(target.sessionID), child.workspaceID == parent.workspaceID, child.delegation == header.link else { throw StoreError.invalidRecord }
            guard selectionRevision == navigation else { return }
            await select(target.sessionID, revealInSidebar: false, reopensSide: false, focusesComposer: false)
            if let child = record(target.sessionID), hosts[parent.workspaceID]?.isReady == true, opened.contains(parent.id) {
                _ = try await open(child); refresh(child.id)
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func stopSubagent(_ target: SubagentTarget, from source: String) {
        // A copied card is provenance, never a transfer of Stop authority.
        guard source == target.ownerID, let parent = record(target.ownerID),
              let host = hosts[parent.workspaceID], host.isReady, opened.contains(parent.id) else { return }
        Task {
            do {
                _ = try await host.request("subagent.stop", sessionID: parent.id, params: ["delegationId":.string(target.delegationID)])
                refresh(parent.id); if opened.contains(target.sessionID) { refresh(target.sessionID) }
            } catch { displays[target.sessionID]?.notice = error.localizedDescription }
        }
    }

    func backToSubagentParent(_ childID: String) async {
        guard let link = record(childID)?.delegation else { return }
        await openSubagentParent(link)
    }

    func openSubagentParent(_ link: SubagentLink) async {
        let childID = link.childSessionID, navigation = selectionRevision
        guard link.valid, let parent = record(link.budgetOwnerSessionID),
              record(childID).map({ $0.workspaceID == parent.workspaceID && $0.delegation == link }) ?? true else {
            displays[childID]?.notice = "The parent chat is unavailable. This saved sub-agent remains viewable."; return
        }
        do {
            // A restored reader has no coordinator job. Close it before the
            // parent's recovery opens child journals; the helper refuses to
            // unload any live queued or settling child.
            if !opened.contains(parent.id), opened.contains(childID), let host = hosts[parent.workspaceID], host.isReady {
                _ = try await host.request("session.close", sessionID: childID)
                opened.remove(childID)
            }
            guard !Task.isCancelled, selectionRevision == navigation else { return }
            if side(parent.id) != nil { await selectSide(parent.id, revealInSidebar: false) }
            else if let ancestor = parent.parentSessionID, record(ancestor) != nil, !parent.imported { await showSide(parent.id, revealInSidebar: false) }
            else { await select(parent.id, revealInSidebar: false, reopensSide: false, focusesComposer: false) }
            await revealSubagentCall(link)
        } catch { displays[childID]?.notice = error.localizedDescription }
    }

    func revealSubagentCall(_ link: SubagentLink) async {
        guard let parent = record(link.budgetOwnerSessionID), subagentParentIsShown(parent.id), let view = displays[parent.id] else { return }
        messageNavigationRevision += 1
        let navigation = messageNavigationRevision
        let messageID = link.call.assistantMessageID
        if !view.presentedMessages.contains(where: { $0.id == messageID }) {
            do {
                let host = try await open(parent)
                let group = try await host.request("session.versions", sessionID: parent.id, params: ["messageId":.string(link.parentTurnID)]).object ?? [:]
                guard !Task.isCancelled, navigation == messageNavigationRevision, subagentParentIsShown(parent.id) else { return }
                let ids = group["versions"]?.array?.compactMap { $0.object?["messageId"]?.string } ?? []
                if let index = ids.firstIndex(of: link.parentTurnID), let live = group["current"]?.nonnegativeInteger,
                   live > 0, live <= ids.count, index + 1 != live, subagentParentIsShown(parent.id) {
                    _ = await revealInTranscript(sessionID: parent.id, messageID: ids[live - 1])
                    showVersion(sessionID: parent.id, latestID: ids[live - 1], index: index + 1, count: ids.count, ids: ids, live: live, around: messageID)
                    await view.versionLoad?.value
                }
            } catch { view.notice = "The issuing version could not be read: " + error.localizedDescription }
        }
        guard !Task.isCancelled, navigation == messageNavigationRevision, subagentParentIsShown(parent.id) else { return }
        _ = await revealInTranscript(sessionID: parent.id, messageID: messageID, toolCallID: link.call.toolCallID)
    }

    private func subagentParentIsShown(_ id: String) -> Bool {
        page == .chats && (selectedID == id || sides[selectedID ?? ""]?.id == id)
    }

    /// A changed family revision pages journal-backed summaries, including
    /// queued tasks with no capture. No extra read on ordinary token updates.
    func refreshSubagentGroups(parent: ChatRecord, host: HostSupervisor, connection: UUID) async throws {
        let plans: [DiscoveredSubagent]
        if let path = record(parent.id)?.path { plans = try await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: parent.id) }
        else { plans = [] }
        let tasks = Dictionary(plans.map { ($0.header.link.childSessionID, $0.task) }, uniquingKeysWith: { first, _ in first })
        var cursor = 0
        repeat {
            let page = try await host.request("subagent.list", sessionID: parent.id, params: ["cursor":.number(Double(cursor))]).object ?? [:]
            guard !isShutDown, !Task.isCancelled, hosts[parent.workspaceID] === host, host.connectionID == connection,
                  record(parent.id)?.workspaceID == parent.workspaceID else { throw CancellationError() }
            for value in page["children"]?.array ?? [] {
                let summary = try JSONDecoder().decode(SubagentSummary.self, from: JSONEncoder().encode(value))
                try await registerListedSubagent(summary, parent: parent, task: tasks[summary.link.childSessionID] ?? "")
            }
            guard let next = page["cursor"]?.nonnegativeInteger else { break }
            guard next > cursor else { throw StoreError.invalidRecord }; cursor = next
        } while true
        reconcileRunHold(parent.id)
    }
    func registerListedSubagent(_ summary: SubagentSummary, parent: ChatRecord, task: String) async throws {
        guard summary.link.budgetOwnerSessionID == parent.id else { throw StoreError.invalidRecord }
        try await traces.recordSubagent(summary, workspaceID: parent.workspaceID)
        let directory = try subagentDirectory(parent.workspaceID)
        let path = directory.appendingPathComponent(summary.link.childSessionID + ".jsonl")
        let header: SubagentHeader
        do { header = try await history.subagentHeader(path: path, directory: directory, expected: SubagentTarget(summary.link)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // The accepted plan can precede child creation, or creation may
            // fail. Keep its Inspector group without blocking healthy siblings
            // or registering an unvalidated transcript path.
            return
        }
        let found = DiscoveredSubagent(header: header, path: path.path, task: task, status: summary.status)
        try await registerDiscoveredSubagent(found, workspaceID: parent.workspaceID, live: summary)
    }

}
