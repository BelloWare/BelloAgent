import Foundation

extension WorkspaceModel {
    /// Cards keep original ownership even when copied into a fork. Navigation
    /// validates the reciprocal child header inside this project's directory.
    func openSubagent(_ target: SubagentTarget) async {
        let navigation = selectionRevision
        do {
            guard let parent = record(target.ownerID), let store else { throw HostError.failure("The parent chat is unavailable. The saved child can still be opened from search.") }
            let directory = root.appendingPathComponent("Workspaces/\(parent.workspaceID)/Sessions", isDirectory: true)
            let path = directory.appendingPathComponent(target.sessionID + ".jsonl")
            let header = try await history.subagentHeader(path: path, directory: directory, expected: target)
            guard !isShutDown, !Task.isCancelled, selectionRevision == navigation, record(parent.id)?.workspaceID == parent.workspaceID else { return }
            if let existing = record(target.sessionID) {
                guard existing.workspaceID == parent.workspaceID, existing.delegation == header.link else { throw StoreError.invalidRecord }
            } else {
                let grant = header.model
                let child = ChatRecord(id: target.sessionID, workspaceID: parent.workspaceID, title: header.description, path: path.path,
                                       profileID: parent.profileID, toolMode: header.readOnly ? ChatRecord.readOnlyTools : ChatRecord.editingTools,
                                       model: grant.model, thinkingLevel: grant.thinkingLevel, contextWindow: grant.contextWindow,
                                       maxOutputTokens: grant.maxOutputTokens, modelOutputLimit: grant.modelOutputLimit,
                                       archivedAt: parent.archivedAt, topicID: parent.topicID, parentSessionID: parent.id, delegation: header.link)
                try await store.put(child, kind: "chat", id: child.id)
                guard !isShutDown, record(parent.id) != nil else { return }
                chats.append(child)
            }
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
