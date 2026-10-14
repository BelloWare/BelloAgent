import Foundation

extension WorkspaceModel {
    /// Cards keep original ownership even when copied into a fork. Navigation
    /// validates the reciprocal child header inside this project's directory.
    @discardableResult func openSubagent(_ target: SubagentTarget) async -> Bool {
        let navigation = selectionRevision
        do {
            guard let parent = record(target.ownerID), store != nil else { throw HostError.failure("The parent chat is unavailable. The saved child can still be opened from search.") }
            let directory = try subagentDirectory(parent.workspaceID)
            let path = directory.appendingPathComponent(target.sessionID + ".jsonl")
            let header = try await history.subagentHeader(path: path, directory: directory, expected: target)
            guard !isShutDown, !Task.isCancelled, selectionRevision == navigation, record(parent.id)?.workspaceID == parent.workspaceID else { return false }
            if record(target.sessionID) == nil { await reconcileSubagents(parentID: parent.id) }
            guard let child = record(target.sessionID), child.workspaceID == parent.workspaceID, child.delegation == header.link else { throw StoreError.invalidRecord }
            guard !Task.isCancelled, selectionRevision == navigation else { return false }
            await select(target.sessionID, revealInSidebar: false, reopensSide: false, focusesComposer: false)
            guard selectedID == target.sessionID, !Task.isCancelled else { return false }
            subagentReturnTargets[target.sessionID] = target
            let message = try await history.subagentTurnMessage(path: path, childID: target.sessionID, turn: target.turn, messageID: target.messageID)
            if let message, selectedID == target.sessionID { _ = await revealInTranscript(sessionID: target.sessionID, messageID: message) }
            return !Task.isCancelled && selectedID == target.sessionID && page == .chats
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        return false
    }

    /// Every selection route (including restoration, notifications and a
    /// reveal of the already selected chat) attaches here before reading its
    /// history. Cold saved children remain view-only without starting a host.
    func attachManagedSubagent(_ item: ChatRecord) async throws {
        guard let link = item.delegation, item.delegationIssue == nil,
              let parent = record(link.budgetOwnerSessionID), parent.workspaceID == item.workspaceID,
              let host = hosts[item.workspaceID], host.isReady, opened.contains(parent.id) else { return }
        let navigation = selectionRevision, connection = host.connectionID
        let directory = try subagentDirectory(item.workspaceID)
        guard let path = item.path else { throw StoreError.invalidRecord }
        _ = try await history.subagentHeader(path: URL(fileURLWithPath: path), directory: directory, expected: SubagentTarget(link))
        guard !Task.isCancelled, selectedID == item.id, selectionRevision == navigation,
              record(item.id)?.delegation == link, record(item.id)?.path == path,
              hosts[item.workspaceID] === host, host.connectionID == connection, opened.contains(parent.id) else { throw CancellationError() }
        _ = try await open(item)
        refresh(item.id)
    }

    func stopSubagent(_ target: SubagentTarget, from source: String) {
        // A copied card is provenance, never a transfer of Stop authority.
        guard source == target.ownerID, let parent = record(target.ownerID),
              let host = hosts[parent.workspaceID], host.isReady, opened.contains(parent.id) else { return }
        Task {
            do {
                let turn = target.turn ?? subagentSummaries[target.sessionID]?.turn
                let params: [String: WireValue] = turn.map { ["childId":.string(target.sessionID), "turn":.number(Double($0))] } ?? ["delegationId":.string(target.delegationID)]
                _ = try await host.request("subagent.stop", sessionID: parent.id, params: params)
                refresh(parent.id); if opened.contains(target.sessionID) { refresh(target.sessionID) }
            } catch { displays[target.sessionID]?.notice = error.localizedDescription }
        }
    }

    func backToSubagentParent(_ childID: String) async {
        guard let link = record(childID)?.delegation else { return }
        await openSubagentParent(link, returningTo: subagentReturnTargets[childID])
    }

    func openSubagentParent(_ link: SubagentLink, returningTo target: SubagentTarget? = nil) async {
        let childID = link.childSessionID, navigation = selectionRevision
        guard link.valid, let parent = record(link.budgetOwnerSessionID),
              record(childID).map({ $0.workspaceID == parent.workspaceID && $0.delegation == link }) ?? true else {
            displays[childID]?.notice = "The parent chat is unavailable. This saved sub-agent remains viewable."; return
        }
        guard !Task.isCancelled, selectionRevision == navigation else { return }
        if side(parent.id) != nil { await selectSide(parent.id, revealInSidebar: false) }
        else if let ancestor = parent.parentSessionID, record(ancestor) != nil, !parent.imported { await showSide(parent.id, revealInSidebar: false) }
        else { await select(parent.id, revealInSidebar: false, reopensSide: false, focusesComposer: false) }
        var destination = link
        if let target, target.matchesOrigin(link) {
            destination.call.assistantMessageID = target.assistantID; destination.call.toolCallID = target.toolCallID
        }
        await revealSubagentCall(destination)
    }

    func revealSubagentCall(_ link: SubagentLink) async {
        guard let parent = record(link.budgetOwnerSessionID), subagentParentIsShown(parent.id), let view = displays[parent.id] else { return }
        messageNavigationRevision += 1
        let navigation = messageNavigationRevision
        let messageID = link.call.assistantMessageID
        if !view.presentedMessages.contains(where: { $0.id == messageID }) {
            do {
                let host = try await open(parent)
                let group = try await host.request("session.versions", sessionID: parent.id, params: ["containing":.string(messageID)]).object ?? [:]
                guard !Task.isCancelled, navigation == messageNavigationRevision, subagentParentIsShown(parent.id) else { return }
                let ids = group["versions"]?.array?.compactMap { $0.object?["messageId"]?.string } ?? []
                if let index = group["selected"]?.nonnegativeInteger, index > 0, index <= ids.count, let anchor = group["anchor"]?.string {
                    latestVersion(sessionID: parent.id)
                    guard await revealInTranscript(sessionID: parent.id, messageID: anchor),
                          !Task.isCancelled, navigation == messageNavigationRevision, subagentParentIsShown(parent.id) else { return }
                    showVersion(sessionID: parent.id, latestID: anchor, index: index, count: ids.count, ids: ids, live: group["current"]?.nonnegativeInteger ?? 0, around: messageID)
                    await view.versionLoad?.value
                } else { latestVersion(sessionID: parent.id) }
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
                try await registerListedSubagent(summary, parent: parent, task: tasks[summary.link.childSessionID] ?? "", connection: connection)
            }
            guard let next = page["cursor"]?.nonnegativeInteger else { break }
            guard next > cursor else { throw StoreError.invalidRecord }; cursor = next
        } while true
        reconcileRunHold(parent.id)
    }
    func registerListedSubagent(_ summary: SubagentSummary, parent: ChatRecord, task: String, connection: UUID? = nil) async throws {
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
        try await registerDiscoveredSubagent(found, workspaceID: parent.workspaceID, live: summary, connection: connection)
    }

}
