import Foundation
import AppKit

// A chat from first press to deletion: the pending chat that exists only on
// screen, the record written when its first message is sent, and the
// commands that rename, import, copy, hand off or delete one.

extension WorkspaceModel {
    func newChat() {
        let previous = (focusedSessionID ?? selectedID).flatMap(record)
        let topicID = previous.flatMap { $0.workspaceID == selectedWorkspaceID ? effectiveTopicID(for: $0) : nil }
        createNewChat(topicID: topicID)
    }
    /// Explicit project/topic actions capture their destination before any
    /// asynchronous model-default reads or selection changes can occur.
    func createNewChat(topicID: String?) {
        guard !installPreparing else { return }
        page = .chats
        guard let workspaceID = selectedWorkspaceID, profiles.contains(where: { $0.id == profileChoice }) else {
            if workspaces.isEmpty { showWorkspaceManager = true } else { showProfiles = true }; return
        }
        guard workspaces.contains(where: { $0.id == workspaceID && $0.trusted }), !workspaceChangesInFlight.contains(workspaceID) else { error = "Wait for project changes to finish and choose a trusted project."; return }
        guard requestProfiles.contains(where: { $0.id == profileChoice }) else { error = LiteLLMConfiguration.unsupportedAPIMessage; showProfiles = true; return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before creating a chat."; return }
        if let topicID, !topics.contains(where: { $0.id == topicID && $0.workspaceID == workspaceID }) {
            error = "This topic is no longer available. Choose another topic or the project."; return
        }
        if let current = selectedID, isPendingEmpty(current), let item = record(current), item.workspaceID == workspaceID, item.profileID == profileChoice, effectiveTopicID(for: item) == topicID {
            displays[current]?.composerFocusRequest += 1; return
        }
        workspaceChangesInFlight.insert(workspaceID)
        let profileID = profileChoice, pendingChoice = overrideWrites[profileChoice]?.task
        let previousChatID = focusedSessionID ?? selectedID
        Task { defer { workspaceChangesInFlight.remove(workspaceID); if let id = selectedID { scheduleAutomaticContext(id) } }
            do {
                await pendingChoice?.value
                var item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "New chat", path: nil, profileID: profileID)
                let remembered = try await store.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: profileID)
                // On upgrade there may be a chosen model in the current chat
                // but no defaults record yet. Never inherit another gateway.
                let previous = previousChatID.flatMap(record).flatMap { $0.profileID == profileID && !$0.isBackgroundTask ? ChatModelDefaults(chat: $0) : nil }
                (remembered ?? previous)?.apply(to: &item, profile: profiles.first { $0.id == profileID })
                if remembered?.outputBudgetVersion == nil, item.outputBudgetVersion == 1, remembered != nil {
                    try await store.put(ChatModelDefaults(chat: item), kind: ChatModelDefaults.recordKind, id: profileID)
                }
                // Removing a topic during the reads above must not leave a
                // newly created chat assigned to a deleted group.
                item.topicID = topicID.flatMap { id in topics.contains(where: { $0.id == id && $0.workspaceID == workspaceID }) ? id : nil }
                // Created on screen only; the first send writes it (materializeChat).
                pendingChatIDs.insert(item.id); chats.insert(item, at: 0); await select(item.id)
            }
            catch { self.error = error.localizedDescription } }
    }
    /// Writes a pending chat's record before its first message, rename,
    /// archive, connection change or helper session needs it.
    func materializeChat(_ id: String) async throws {
        guard pendingChatIDs.contains(id), let item = chats.first(where: { $0.id == id }) else { return }
        guard let store else { throw StoreError.unavailable }
        try await store.put(item, kind: "chat", id: id)
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats[index].topicID = effectiveTopicID(for: chats[index])
        }
        pendingChatIDs.remove(id)
        if let draft = displays[id]?.savedDraft, !draft.text.isEmpty || !(draft.attachments ?? []).isEmpty { try await store.put(draft, kind: "draft", id: id) }
    }
    /// Drops a pending chat that never received a message. Nothing was written.
    func discardPendingChat(_ id: String) {
        guard pendingChatIDs.remove(id) != nil else { return }
        chats.removeAll { $0.id == id }; displays.removeValue(forKey: id); opened.remove(id)
        if selectedID == id { selectedID = nil; selected = nil }
        if focusedSessionID == id { focusedSessionID = nil }
    }
    func isPendingEmpty(_ id: String) -> Bool {
        guard pendingChatIDs.contains(id) else { return false }
        guard let view = displays[id] else { return true }
        return view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && view.attachments.isEmpty && view.skills.isEmpty
    }
    func createOnboardingChat() async throws {
        guard !installPreparing, !creatingOnboardingChat else {
            throw HostError.failure("A chat or app update is already being prepared.")
        }
        creatingOnboardingChat = true
        defer { creatingOnboardingChat = false }
        try await ensureConfiguration()
        guard let workspaceID = selectedWorkspaceID,
              workspaces.contains(where: { $0.id == workspaceID && $0.trusted }),
              !workspaceChangesInFlight.contains(workspaceID),
              requestProfiles.contains(where: { $0.id == profileChoice }) else {
            throw HostError.failure("Choose a saved Responses connection and a trusted project first.")
        }
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID); if let id = selectedID { scheduleAutomaticContext(id) } }
        guard let store else { throw HostError.failure("Desktop storage is unavailable. Your setup is saved; try again after resolving the storage error.") }
        let item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: "New chat", path: nil, profileID: profileChoice)
        try await store.put(item, kind: "chat", id: item.id)
        chats.insert(item, at: 0)
        await select(item.id)
    }
    func rename() {
        if let id = focusedSessionID ?? selectedID { renameSession(id) }
    }
    func importChat() {
        guard let workspaceID = selectedWorkspaceID else { pickWorkspace(); return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before importing."; return }
        if !questions.chooseOne(message: "Open a Pi JSONL session read-only. The original file will remain unchanged.", directories: false, { [weak self] url in
            self?.importChat(from: url, workspaceID: workspaceID, store: store)
        }) { error = PiQuestion.busyNotice }
    }
    private func importChat(from url: URL, workspaceID: String, store: MetadataStore) {
        Task { do {
            let page = try await history.read(path: url.path)
            let item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: url.deletingPathExtension().lastPathComponent, path: url.path, profileID: profileChoice, imported: true)
            try await store.put(item, kind: "chat", id: item.id); chats.insert(item, at: 0); await select(item.id); selected?.notice = page.notice ?? "Imported original · Read-only. No historical HTTP capture is available."
        } catch { self.error = "Import could not be read. The original was preserved." } }
    }
    func continueCopy(recoverTail: Bool = false) {
        guard let item = chat, let source = item.path, let workspace = workspaces.first(where: { $0.id == item.workspaceID }), requestProfiles.contains(where: { $0.id == profileChoice }) else { error = "Choose a Responses connection for the continued copy"; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        let profileID = profileChoice
        Task { do {
            // Asked before anything is created or a helper is started, and as
            // a sheet, so the chats behind it keep running.
            if recoverTail {
                switch await questions.confirm(Self.recoveredCopy, about: item.id) {
                case .yes: break
                case .no: return
                case .busy: self.error = PiQuestion.busyNotice; return
                }
            }
            let host = try await host(for: workspace), id = UUID().uuidString
            let result = try await host.request(recoverTail ? "session.import.recover" : "session.import.continue", params: ["path": .string(source), "newSessionId": .string(id)]).object ?? [:]
            guard let path = result["sessionFile"]?.string else { throw StoreError.invalidRecord }
            var copy = ChatRecord(id: id, workspaceID: item.workspaceID, title: item.title + " — continued", path: path, profileID: profileID, toolMode: item.toolMode)
            copy.topicID = effectiveTopicID(for: item)
            try await store.put(copy, kind: "chat", id: copy.id); chats.insert(copy, at: 0); await select(copy.id)
        } catch { self.error = "The source could not be continued safely. Check for an incomplete tail, changed source, or incompatible saved profile. Original preserved." } }
    }
    func portableHandoff() {
        guard let item = chat, let path = item.path, let workspace = workspaces.first(where: { $0.id == item.workspaceID }), requestProfiles.contains(where: { $0.id == profileChoice }) else { error = "Choose a source history and a Responses connection"; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        let profileID = profileChoice
        Task { do {
            let host = try await host(for: workspace)
            let value = try await host.request("session.portable.preview", params: ["path": .string(path)]).object ?? [:]
            guard let text = value["draft"]?.string else { throw StoreError.invalidRecord }
            // The preview is ready; the question about it is a sheet, and this
            // task waits on the answer rather than the whole app.
            switch await questions.confirm(Self.portableDraft, about: item.id) {
            case .yes: break
            case .no: return
            case .busy: self.error = PiQuestion.busyNotice; return
            }
            var copy = ChatRecord(id: UUID().uuidString, workspaceID: item.workspaceID, title: item.title + " — portable handoff", path: nil, profileID: profileID, toolMode: item.toolMode)
            copy.topicID = effectiveTopicID(for: item)
            try await store.commitPortableHandoff(copy, draft: DraftRecord(id: copy.id, text: text), provenance: value["provenance"])
            chats.insert(copy, at: 0); await select(copy.id)
        } catch { self.error = error.localizedDescription } }
    }
    func deleteChat() { deleteChat(selectedID) }
    /// Deletes any chat by id, so archived chats can go straight from the sidebar.
    func deleteChat(_ id: String?) {
        guard let id, let item = record(id) else { return }
        if pendingChatIDs.contains(id) { discardPendingChat(id); return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        if sides[id] != nil { error = "Close the side panel before deleting its parent."; return }
        if side(id) != nil { error = "Close this side panel before deleting its chat."; return }
        guard displays[id]?.hasWork != true, displays[id]?.loading != true else { error = "Stop work and remove queued submissions before deleting this chat"; return }
        let question = ChatQuestion(title: item.isArchived ? "Delete the archived chat “\(item.title)”?" : "Delete this chat?",
                                    detail: item.imported ? "Remove its app index and draft. The imported original stays in place." : "Move its managed conversation file to Trash and remove its draft and current memory traces, and locally retained traces.",
                                    action: "Delete Chat")
        if !questions.ask(question, about: item.id, destructive: true, answered: { [weak self] confirmed in
            guard let self, confirmed, self.record(item.id) != nil else { return }
            self.performDelete(item, store: store)
        }) { error = PiQuestion.busyNotice }
    }
    private func performDelete(_ item: ChatRecord, store: MetadataStore) {
        Task { do {
            if let host = hosts[item.workspaceID], host.isReady { _ = try await host.request("session.forget", sessionID: item.id) }
            opened.remove(item.id)
            try await traces.clear(sessionID: item.id)
            if !item.imported, let path = item.path, FileManager.default.fileExists(atPath: path) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                }
            }
            forgetReadState(item.id)
            for kind in ["chat", "draft", "anchor", "capture-preference", "handoff", "side-keep", "session-read"] { try await store.remove(kind: kind, id: item.id) }
            try await store.removeAll(kind: "receipt:\(item.id)")
            for intent in try await store.list(CommandIntent.self, kind: "pending:\(item.id)") { try await store.remove(kind: "pending:\(item.id)", id: intent.id) }
            chats.removeAll { $0.id == item.id }; displays.removeValue(forKey: item.id)
            if selectedID == item.id { selectedID = nil; selected = nil }
            if focusedSessionID == item.id { focusedSessionID = nil }
            do { try await removeDeletedCapturePreference(sessionID: item.id) }
            catch { self.error = "The chat was deleted, but its old capture preference could not be removed. \(error.localizedDescription)" }
        } catch { self.error = "Chat deletion did not complete. \(error.localizedDescription)" } }
    }
}
