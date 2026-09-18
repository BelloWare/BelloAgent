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
        if side(chatID) != nil || item.parentSessionID != nil { return "Side conversations keep their parent's connection." }
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
        guard connectionSwitchBlocker(for: chatID) == nil, var updated = record(chatID), updated.profileID != profileID else { return }
        do {
            if opened.contains(chatID) {
                guard let host = hosts[updated.workspaceID], host.isReady else { throw HostError.failure("Wait for this project's host to recover before changing the connection.") }
                _ = try await host.request("session.close", sessionID: chatID); opened.remove(chatID)
            }
            updated.profileID = profileID
            let listed = updated.model.flatMap { alias in catalogEntry(for: target).descriptor(for: alias) != nil ? alias : nil }
            applyModelChoice(listed, to: &updated, profile: target)
            try await store.put(updated, kind: "chat", id: chatID)
            if let index = chats.firstIndex(where: { $0.id == chatID }) {
                chats[index].profileID = updated.profileID
                chats[index].model = updated.model; chats[index].thinkingLevel = updated.thinkingLevel
                chats[index].contextWindow = updated.contextWindow; chats[index].maxOutputTokens = updated.maxOutputTokens
                chats[index].modelOutputLimit = updated.modelOutputLimit; chats[index].outputBudgetVersion = updated.outputBudgetVersion
            }
            if selectedID == chatID { profileChoice = profileID }
            if let view = displays[chatID] {
                // The footer's context and metrics described the old endpoint.
                view.footer.preparedContext = nil; view.context = [:]; view.metrics = [:]
                view.notice = "Next turn uses \(target.name)" + (item.model != nil && updated.model == nil ? " with its default model." : ".")
            }
            if selectedID == chatID { scheduleAutomaticContext(chatID) }
        } catch { self.error = error.localizedDescription }
    }
}
