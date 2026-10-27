import Foundation

extension WorkspaceModel {
    /// Cards keep original ownership even when copied into a fork. Navigation
    /// validates the reciprocal child header inside this project's directory.
    @discardableResult func openSubagent(_ target: SubagentTarget, sourceMessage: String? = nil, sourceToolCall: String? = nil) async -> Bool {
        let opening = beginSubagentOpening(target.sessionID)
        defer { finishSubagentOpening(opening) }
        func currentOpening() -> Bool {
            !isShutDown && !Task.isCancelled && opening.isCurrent
        }
        do {
            guard let parent = record(target.ownerID), store != nil else { throw HostError.failure("The parent chat is unavailable. The saved child can still be opened from search.") }
            let directory = try subagentDirectory(parent.workspaceID)
            let path = directory.appendingPathComponent(target.sessionID + ".jsonl")
            let header = try await history.subagentHeader(path: path, directory: directory, expected: target)
            guard currentOpening(), record(parent.id)?.workspaceID == parent.workspaceID else { return false }
            if record(target.sessionID) == nil { await reconcileSubagents(parentID: parent.id) }
            guard currentOpening() else { return false }
            guard let child = record(target.sessionID), child.workspaceID == parent.workspaceID, child.delegation == header.link else { throw StoreError.invalidRecord }
            guard let tab = await openSubagentTab(target.sessionID, opening: opening),
                  currentOpening(), subagentTabIsShown(target.sessionID) else { return false }
            subagentReturnTargets[target.sessionID] = target
            let message = try await subagentTurnMessage(target, path: path)
            guard currentOpening(),
                  subagentTab(target.sessionID) === tab, subagentTabIsShown(target.sessionID) else { return false }
            if let message = sourceMessage ?? message { _ = await revealInTranscript(sessionID: target.sessionID, messageID: message, toolCallID: sourceToolCall, navigation: opening) }
            return currentOpening() && subagentTabIsShown(target.sessionID)
        } catch is CancellationError { }
        catch { if currentOpening() { self.error = error.localizedDescription } }
        return false
    }

    /// Owned and original-reference readers resolve the same persisted turn
    /// and steering identities. This read never attaches a writable helper.
    func subagentTurnMessage(_ target: SubagentTarget, path: URL) async throws -> String? {
        if let subagentTurnMessageLoader { return try await subagentTurnMessageLoader(path, target.sessionID, target.turn, target.messageID) }
        return try await history.subagentTurnMessage(path: path, childID: target.sessionID, turn: target.turn, messageID: target.messageID)
    }

    /// Every selection route (including restoration, notifications and a
    /// reveal of the already selected chat) attaches here before reading its
    /// history. Cold saved children remain view-only without starting a host.
    func attachManagedSubagent(_ item: ChatRecord, current: (() -> Bool)? = nil) async throws {
        guard !isOriginalSubagentReader(item.id), let link = item.delegation, item.delegationIssue == nil,
              let parent = record(link.budgetOwnerSessionID), parent.workspaceID == item.workspaceID,
              let host = hosts[item.workspaceID], host.isReady, opened.contains(parent.id) else { return }
        let navigation = selectionRevision, connection = host.connectionID
        let reader = subagentTab(item.id)?.navigation
        func ownsPresentation() -> Bool {
            if let current { return current() }
            if let reader { return reader.isCurrent && subagentTab(item.id) === reader.reader }
            return selectedID == item.id && selectionRevision == navigation
        }
        let directory = try subagentDirectory(item.workspaceID)
        guard let path = item.path else { throw StoreError.invalidRecord }
        _ = try await history.subagentHeader(path: URL(fileURLWithPath: path), directory: directory, expected: SubagentTarget(link))
        guard !Task.isCancelled, ownsPresentation(),
              record(item.id)?.delegation == link, record(item.id)?.path == path,
              hosts[item.workspaceID] === host, host.connectionID == connection, opened.contains(parent.id) else { throw CancellationError() }
        _ = try await open(item)
        guard !Task.isCancelled, ownsPresentation(), record(item.id)?.delegation == link,
              hosts[item.workspaceID] === host, host.connectionID == connection else { throw CancellationError() }
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
        if pendingSubagentOpening?.reader.key == childID { retirePendingSubagentOpening() }
        else { subagentTab(childID)?.renewNavigation() }
        let origin = subagentTab(childID)?.navigation
        if let fork = subagentTab(childID)?.originalForkID {
            guard record(fork) != nil else { return }
            if selectedID != fork { await select(fork, focusesComposer: false) }
            else { page = .chats }
            guard !Task.isCancelled, origin?.isCurrent != false, selectedID == fork, transcriptShows(fork) else { return }
            focusSubagentParent(fork)
            return
        }
        if subagentTab(childID)?.container?.isPane == true {
            if selectedID == link.budgetOwnerSessionID { focusSubagentParent(link.budgetOwnerSessionID); return }
            if let owner = record(link.budgetOwnerSessionID), sideFamilyOwner(owner) == selectedID {
                await openFamilySide(owner.id)
                return
            }
        }
        if await openSubagentParent(link, returningTo: subagentReturnTargets[childID], origin: origin) { focusSubagentParent(link.budgetOwnerSessionID) }
    }

    @discardableResult func openSubagentParent(_ link: SubagentLink, returningTo target: SubagentTarget? = nil, origin: HostedReaderToken? = nil) async -> Bool {
        guard !Task.isCancelled, origin?.isCurrent != false else { return false }
        let childID = link.childSessionID
        if let fork = subagentTab(childID)?.originalForkID {
            return await revealMessage(sessionID: fork, messageID: target?.assistantID ?? link.call.assistantMessageID, origin: origin)
        }
        guard link.valid, let parent = record(link.budgetOwnerSessionID),
              record(childID).map({ $0.workspaceID == parent.workspaceID && $0.delegation == link }) ?? true else {
            displays[childID]?.notice = "The parent chat is unavailable. This saved sub-agent remains viewable."; return false
        }
        // From the sub-agent's tab, outside the sidebar: Flat lists its chat.
        listSidebarProject(of: parent)
        let sideOwner = selectedID == parent.id ? nil : (side(parent.id)?.parentID ?? sideFamilyOwner(parent))
        let mainID = sideOwner ?? parent.id
        // Showing the owning ordinary side intentionally replaces an embedded
        // child. At that synchronous navigation boundary ownership transfers to
        // the main pane; an external child keeps its independent origin token.
        let origin = sideOwner != nil && origin?.reader.container?.isPane == true ? nil : origin
        // Retire the destination's previous reveal before any selection or
        // version lookup can suspend. Internal steps below share this intent.
        var intent = transcriptNavigation(parent.id, advancing: true)
        let selection = selectionRevision, revision = messageNavigationRevision + (page == .chats ? 0 : 1)
        let changesMain = selectedID != mainID
        intent.workspaceRevision = revision + (changesMain ? 1 : 0)
        intent.origin = origin
        let paneIntent = tabs.navigationRevision + (sideOwner == nil || tabs.pane.sideShown ? 0 : 1)
        if sideOwner != nil, side(parent.id) != nil { await selectSide(parent.id, revealInSidebar: false) }
        else if sideOwner != nil { await showSide(parent.id, revealInSidebar: false) }
        else { await select(parent.id, revealInSidebar: false, reopensSide: false, focusesComposer: false) }
        func current() -> Bool {
            !Task.isCancelled && intent.isCurrent(in: self) && (changesMain ? selectionRevision == selection + 1 : (selection...selection + 1).contains(selectionRevision)) && tabs.navigationRevision == paneIntent && subagentParentIsShown(parent.id)
        }
        guard current() else { return false }
        var destination = link
        if let target, target.matchesOrigin(link) {
            destination.call.assistantMessageID = target.assistantID; destination.call.toolCallID = target.toolCallID
        }
        await revealSubagentCall(destination, intent: intent)
        return current()
    }

    func revealSubagentCall(_ link: SubagentLink, intent: TranscriptNavigationToken? = nil) async {
        guard let parent = record(link.budgetOwnerSessionID), subagentParentIsShown(parent.id), let view = displays[parent.id] else { return }
        let intent = intent ?? transcriptNavigation(parent.id, advancing: true)
        func current() -> Bool { !Task.isCancelled && intent.isCurrent(in: self) && displays[parent.id] === view && subagentParentIsShown(parent.id) }
        guard current() else { return }
        let messageID = link.call.assistantMessageID
        if !view.presentedMessages.contains(where: { $0.id == messageID }) {
            do {
                let group: [String: WireValue]
                if let subagentVersionsLoader { group = try await subagentVersionsLoader(parent.id, messageID) }
                else {
                    let host = try await open(parent)
                    guard current() else { return }
                    group = try await host.request("session.versions", sessionID: parent.id, params: ["containing":.string(messageID)]).object ?? [:]
                }
                guard current() else { return }
                let ids = group["versions"]?.array?.compactMap { $0.object?["messageId"]?.string } ?? []
                if let index = group["selected"]?.nonnegativeInteger, index > 0, index <= ids.count, let anchor = group["anchor"]?.string {
                    latestVersion(sessionID: parent.id, intent: intent)
                    guard await revealInTranscript(sessionID: parent.id, messageID: anchor, intent: intent),
                          current() else { return }
                    showVersion(sessionID: parent.id, latestID: anchor, index: index, count: ids.count, ids: ids, live: group["current"]?.nonnegativeInteger ?? 0, around: messageID, intent: intent)
                    await view.versionLoad?.value
                } else { latestVersion(sessionID: parent.id, intent: intent) }
            } catch { if current() { view.notice = "The issuing version could not be read: " + error.localizedDescription } }
        }
        guard current() else { return }
        _ = await revealInTranscript(sessionID: parent.id, messageID: messageID, toolCallID: link.call.toolCallID, intent: intent)
    }

    private func subagentParentIsShown(_ id: String) -> Bool {
        transcriptShows(id)
    }

    /// A changed family revision pages journal-backed summaries, including
    /// queued tasks with no capture. No extra read on ordinary token updates.
    func refreshSubagentGroups(parent: ChatRecord, host: HostSupervisor, connection: UUID) async throws {
        let plans: [DiscoveredSubagent]
        if let path = record(parent.id)?.path { plans = try await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: parent.id) }
        else { plans = [] }
        let byChild = Dictionary(plans.map { ($0.header.link.childSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var cursor = 0
        repeat {
            let page = try await host.request("subagent.list", sessionID: parent.id, params: ["cursor":.number(Double(cursor)),"includeCosts":.bool(true)]).object ?? [:]
            guard !isShutDown, !Task.isCancelled, hosts[parent.workspaceID] === host, liveSubagentAuthority(parent.workspaceID, connection: connection),
                  record(parent.id)?.workspaceID == parent.workspaceID else { throw CancellationError() }
            for value in page["children"]?.array ?? [] {
                let summary = try JSONDecoder().decode(SubagentSummary.self, from: JSONEncoder().encode(value))
                let plan = byChild[summary.link.childSessionID]
                try await registerListedSubagent(summary, parent: parent, task: plan?.task ?? "", connection: connection, number: plan?.number)
                guard !Task.isCancelled, hosts[parent.workspaceID] === host, liveSubagentAuthority(parent.workspaceID, connection: connection) else { throw CancellationError() }
                if let cost = page["costs"]?.object?[summary.link.childSessionID] {
                    observeCost(["cost":cost],sessionID:summary.link.childSessionID)
                }
            }
            guard let next = page["cursor"]?.nonnegativeInteger else { break }
            guard next > cursor else { throw StoreError.invalidRecord }; cursor = next
        } while true
        if let path = record(parent.id)?.path, let projection = try? await history.agentCoordination(path: URL(fileURLWithPath: path), ownerID: parent.id) {
            guard !Task.isCancelled, hosts[parent.workspaceID] === host, host.connectionID == connection else { throw CancellationError() }
            applyAgentCoordination(projection, parentID: parent.id)
        }
        reconcileRunHold(parent.id)
    }
    func applyAgentCoordination(_ projection: AgentCoordination, parentID: String) {
        let entries = Dictionary(projection.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        displays[parentID]?.agentCoordination = entries
        displays[parentID]?.heldAgentChildren = projection.heldChildren
        // Include accepted starts without a child file, and retain numbers of
        // copied provenance from other families already known to the display.
        displays[parentID]?.subagentNumbers.merge(projection.subagentNumbers, uniquingKeysWith: { _, current in current })
        for child in subagentChildren(of: parentID) where displays[child.id] != nil {
            displays[child.id]?.agentCoordination = entries.filter { $0.value.childID == child.id || $0.value.sourceSessionID == child.id || $0.value.recipientID == child.id }
            displays[child.id]?.heldAgentChildren = projection.heldChildren
            if displays[child.id]?.supportsCodexAgents == true { displays[child.id]?.childSummaries = displays[parentID]?.childSummaries ?? [:] }
            displays[child.id]?.subagentNumbers.merge(projection.subagentNumbers, uniquingKeysWith: { _, current in current })
        }
    }
    func registerListedSubagent(_ summary: SubagentSummary, parent: ChatRecord, task: String, connection: UUID? = nil, number: Int? = nil) async throws {
        guard summary.link.budgetOwnerSessionID == parent.id else { throw StoreError.invalidRecord }
        try await traces.recordSubagent(summary, workspaceID: parent.workspaceID)
        let directory = try subagentDirectory(parent.workspaceID)
        let path = directory.appendingPathComponent(summary.link.childSessionID + ".jsonl")
        var header: SubagentHeader
        do { header = try await history.subagentHeader(path: path, directory: directory, expected: SubagentTarget(summary.link)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // The accepted plan can precede child creation, or creation may
            // fail. Keep its Inspector group without blocking healthy siblings
            // or registering an unvalidated transcript path.
            return
        }
        var ordinal = number
        if ordinal == nil, let path = parent.path {
            ordinal = try await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: parent.id, childID: summary.link.childSessionID).first?.number
        }
        header.taskName = summary.taskName ?? header.taskName; header.forkTurns = summary.forkTurns ?? header.forkTurns
        let found = DiscoveredSubagent(header: header, path: path.path, task: task, status: summary.status, number: ordinal)
        try await registerDiscoveredSubagent(found, workspaceID: parent.workspaceID, live: summary, connection: connection)
    }

}
