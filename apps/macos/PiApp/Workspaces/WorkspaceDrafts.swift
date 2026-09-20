import Foundation

// Unsent text and reading position, written behind the typing rather than
// during it. A draft write is debounced per chat and the last write wins;
// `flushDrafts()` is what quit and update wait for.

extension WorkspaceModel {
    func draftChanged(_ view: SessionDisplay) {
        scheduleAutomaticContext(view.id, delay: WorkspaceModel.typingPreviewDelay)
        // Unkept side drafts stay in memory by design; on host loss their text
        // is moved into the parent composer instead (discardLostSides).
        guard !isEphemeral(view.id), !pendingChatIDs.contains(view.id) else { return }
        draftTasks[view.id]?.cancel()
        // The entry is cleared when this write finishes, and only by the write
        // that owns it: a newer one replaces the token first, so a cancelled
        // task's own cleanup can never drop it.
        let draft = view.savedDraft, id = view.id, token = UUID()
        draftTaskTokens[id] = token
        draftTasks[id] = Task {
            defer { if draftTaskTokens[id] == token { draftTaskTokens.removeValue(forKey: id); draftTasks.removeValue(forKey: id) } }
            do {
                guard let store else { throw StoreError.unavailable }
                let revision = try await store.reserveRevision(kind: "draft", id: draft.id)
                try await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
                try await store.put(draft, kind: "draft", id: draft.id, revision: revision); draftSaveFailed = false
            }
            catch is CancellationError { }
            catch StoreError.staleRevision { /* A newer send, flush or edit already saved this draft. */ }
            catch {
                // A full disk fails every debounce tick; report it once, not per keystroke.
                guard !draftSaveFailed else { return }
                draftSaveFailed = true; self.error = "Draft could not be saved. \(error.localizedDescription)"
            }
        }
    }
    /// Writes every pending draft and anchor now. Quit calls this so the
    /// 150 ms debounce cannot lose the last thing typed; the update path does
    /// the same inside prepareForInstall.
    func flushDrafts() async throws {
        for task in draftTasks.values { task.cancel() }; draftTasks.removeAll(); draftTaskTokens.removeAll()
        let retained = displays.values.filter { !isEphemeral($0.id) }
        guard !retained.isEmpty else { return }
        guard let store else { throw StoreError.unavailable }
        for view in retained {
            // A chat that never sent has no record yet. Writing its draft under
            // that id alone left text nothing would ever list again; skipping it
            // silently threw away what the user had typed. Give the text a chat.
            if pendingChatIDs.contains(view.id) {
                guard !isPendingEmpty(view.id) else { continue }
                try await materializeChat(view.id)
            }
            try await store.put(view.savedDraft, kind: "draft", id: view.id)
            if let anchor = view.scrollAnchor { try await store.put(anchor, kind: "anchor", id: view.id) }
        }
    }
    func anchorChanged(_ view: SessionDisplay) {
        guard !isEphemeral(view.id) else { return }
        let anchor = view.scrollAnchor
        Task { if let anchor { try? await store?.put(anchor, kind: "anchor", id: view.id) }
            else { try? await store?.remove(kind: "anchor", id: view.id) } }
    }
    func recoverDraft(_ intent: CommandIntent, insert: Bool) {
        guard let view = selected else { return }
        if insert { view.attachments = Array((view.attachments + (intent.attachments ?? [])).prefix(4)); for chip in intent.skills ?? [] where !view.skills.contains(where: { $0.id == chip.id }) && view.skills.count < 8 { view.skills.append(chip) }; view.draft += (view.draft.isEmpty ? "" : "\n\n") + intent.text; view.directCommand = false; draftChanged(view) }
        Task { do { try await store?.remove(kind: "pending:\(view.id)", id: intent.id); view.recovered.removeAll { $0.id == intent.id }; if view.recovered.isEmpty { view.uncertain = false } }
            catch { self.error = error.localizedDescription } }
    }
}
