import Foundation

/// Per-chat connection switching. A chat is bound to one saved LiteLLM
/// connection (endpoint, key, headers, catalog). Moving it to another
/// connection closes the open helper session so the next turn reopens with
/// the new endpoint and key and replays the portable history there.
extension WorkspaceModel {
    /// Why this chat cannot change connection right now, or nil when it can.
    func connectionSwitchBlocker(for chatID: String) -> String? {
        guard let item = record(chatID) else { return "This chat is unavailable." }
        if installPreparing { return "Wait for the app update to finish." }
        if item.imported { return "Imported history has no connection to change." }
        if item.connectionTest == true || item.workspaceID == WorkspaceRecord.scratchID { return "Connection tests keep the connection they tested." }
        if item.isBackgroundTask { return "Background tasks keep their connection." }
        if connectionSwitches[chatID] != nil { return "Wait for this chat's connection change to finish." }
        if side(chatID) != nil || item.parentSessionID != nil { return "Side conversations keep their parent's connection." }
        if isSessionOpening(chatID) { return "Wait for this chat's connection to finish opening." }
        if let view = displays[chatID], view.hasWork || view.loading { return "Wait for this chat to finish its current work first." }
        if workspaceChangesInFlight.contains(item.workspaceID) { return "Wait for this project's folder changes to finish." }
        return nil
    }

    /// Moves a saved chat to another Responses connection. A model override
    /// survives only when the new connection's catalog lists it; limits and
    /// effort re-derive against that connection. The choice is not remembered
    /// for new chats, unlike a model or effort choice.
    func setConnection(_ profileID: String, for chatID: String) async {
        guard let item = record(chatID) else { return }
        if let blocker = connectionSwitchBlocker(for: chatID) { error = blocker; return }
        guard profileID != item.profileID else { return }
        guard let target = profiles.first(where: { $0.id == profileID }) else { error = "That connection is no longer saved. Reload Settings and choose again."; return }
        guard target.api == LiteLLMConfiguration.supportedAPI else { error = LiteLLMConfiguration.unsupportedAPIMessage; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        // Let an in-flight model or effort write for either connection land first.
        await overrideWrites[item.profileID]?.task.value
        await overrideWrites[profileID]?.task.value
        // Decide the chat's model against the target's real catalog. A
        // connection nobody has listed this session has a blank entry, which
        // silently dropped the chat's model on the first switch to it.
        if item.model != nil { _ = await listModels(for: target) }
        // Every other rejection explains itself; a run that started while those
        // awaits drained used to make the pill do nothing at all.
        if let blocker = connectionSwitchBlocker(for: chatID) { error = blocker; return }
        guard var updated = record(chatID), updated.profileID != profileID else { return }
        // From here on the chat is the change's: an open, a send, a prewarm
        // or an automatic context waits for it, then opens wherever the chat
        // is, and one leased before it is stale (`requireConnection`). Without
        // this, an open that read the chat on the old connection while the
        // record was being written opened the old session after the switch.
        let (released, release) = AsyncStream<Never>.makeStream()
        let token = UUID()
        connectionSwitches[chatID] = (token, Task { for await _ in released {} })
        connectionGenerations[chatID, default: 0] &+= 1
        defer {
            release.finish()
            if connectionSwitches[chatID]?.token == token { connectionSwitches.removeValue(forKey: chatID) }
        }
        do {
            // A close sent when the chat's display was let go of lands first.
            if let closing = sessionClosings[chatID] { await closing.task.value }
            if opened.contains(chatID) {
                guard let host = hosts[updated.workspaceID], host.isReady else { throw HostError.failure("Wait for this project's host to recover before changing the connection.") }
                _ = try await host.request("session.close", sessionID: chatID); opened.remove(chatID)
            }
            try await connectionSwitchSteps?("closed")
            // A chat never sent has no record yet (`materializeChat`): writing
            // one here left an empty "New chat" in the sidebar at every launch
            // once the chat was abandoned. Its first send writes it, with this
            // connection, from memory.
            let persisted = !pendingChatIDs.contains(chatID)
            // A chat with a journal moves it first: bound to the old
            // connection, it would not open on the new one. The record says
            // the journal may move before it moves, so a crash or a lost
            // answer in between is put right by the next open
            // (`reconcileJournal`), and names the new connection only once
            // the journal is bound there.
            if let path = updated.path {
                guard let workspace = workspace(for: updated.workspaceID) else { throw HostError.failure("This chat's project is unavailable.") }
                var marked = updated
                marked.journalRebind = true; marked.connectionRevision = nextConnectionRevision(after: updated)
                if persisted { try await store.put(marked, kind: "chat", id: chatID) }
                adoptConnection(of: marked)
                do {
                    let host = try await host(for: workspace)
                    _ = try await host.request("session.rebind", sessionID: chatID, params: ["path": .string(path), "profile": target.wire])
                    try await connectionSwitchSteps?("rebound")
                } catch {
                    // Even a refusal may come after the move was written. The
                    // chat stays on its connection: its journal is bound back
                    // there, and the mark goes only once it is; otherwise the
                    // next open settles it.
                    if let current = profiles.first(where: { $0.id == updated.profileID }), let host = hosts[updated.workspaceID], host.isReady,
                       (try? await host.request("session.rebind", sessionID: chatID, params: ["path": .string(path), "profile": current.wire])) != nil {
                        var unmarked = marked
                        unmarked.journalRebind = nil; unmarked.connectionRevision = nextConnectionRevision(after: marked)
                        if persisted { try? await store.put(unmarked, kind: "chat", id: chatID) }
                        adoptConnection(of: unmarked)
                    }
                    throw error
                }
                updated = marked
            }
            updated.profileID = profileID; updated.journalRebind = nil; updated.connectionRevision = nextConnectionRevision(after: updated)
            // Only an actually-read catalog is evidence that a model is gone.
            // A blank or failed listing keeps the chat's choice.
            let catalog = catalogEntry(for: target)
            let known = catalog.error == nil && !catalog.descriptors.isEmpty
            let listed = updated.model.flatMap { alias in !known || catalog.descriptor(for: alias) != nil ? alias : nil }
            applyModelChoice(listed, to: &updated, profile: target)
            try await connectionSwitchSteps?("metadata")
            if persisted { try await store.put(updated, kind: "chat", id: chatID) }
            adoptConnection(of: updated)
            if selectedID == chatID { profileChoice = profileID }
            if let view = displays[chatID] {
                // The footer's context and metrics described the old endpoint.
                view.footer.preparedContext = nil; view.context = [:]; view.metrics = [:]
                view.notice = "Next turn uses \(target.name)" + (item.model != nil && updated.model == nil ? " with its default model." : ".")
            }
            if selectedID == chatID { scheduleAutomaticContext(chatID) }
        } catch { self.error = error.localizedDescription }
    }

    /// A connection revision after the chat's last (`ChatRecord.connectionRevision`).
    func nextConnectionRevision(after record: ChatRecord) -> Int64 {
        max((record.connectionRevision ?? 0) + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
    }
    /// The connection `record` names, taken by the chat in memory.
    func adoptConnection(of record: ChatRecord) {
        guard let index = chats.firstIndex(where: { $0.id == record.id }) else { return }
        chats[index].applyConnection(from: record)
    }
    /// Binds the journal of a chat whose last switch did not finish to the
    /// connection its record names, before the chat opens: the record wins,
    /// whichever side of the move the journal was left on. Called from the
    /// chat's one shared open, so no other caller has its session loaded.
    func reconcileJournal(_ chatID: String, host: HostSupervisor, profile: ProfileRecord) async throws {
        guard let current = record(chatID), current.journalRebind == true, current.profileID == profile.id else { return }
        if let path = current.path {
            _ = try await host.request("session.rebind", sessionID: chatID, params: ["path": .string(path), "profile": profile.wire])
        }
        var settled = current
        settled.journalRebind = nil; settled.connectionRevision = nextConnectionRevision(after: current)
        // Left marked when the write fails: the next open binds it again,
        // which changes nothing then.
        if !pendingChatIDs.contains(chatID) { try? await store?.put(settled, kind: "chat", id: chatID) }
        adoptConnection(of: settled)
    }
}