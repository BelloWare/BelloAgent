import Foundation
import AppKit

// A chat from first press to deletion: the pending chat that exists only on
// screen, the record written when its first message is sent, and the
// commands that rename, import, copy, hand off or delete one.

extension WorkspaceModel {
    func newChat() {
        if sidebarListsFlat {
            guard let project = flatNewChatProjectID else { showWorkspaceManager = true; return }
            newChat(in: project, topicID: nil)
            return
        }
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
        guard store != nil else { error = "Desktop storage is unavailable. Resolve the storage error before creating a chat."; return }
        if let topicID, !topics.contains(where: { $0.id == topicID && $0.workspaceID == workspaceID }) {
            error = "This topic is no longer available. Choose another topic or the project."; return
        }
        // New Chat supersedes the old draft's project choice even when it
        // reuses that draft or waits for defaults before changing selection.
        if let current = selectedID { pendingChatProjectChoices[current] = nil }
        if let current = selectedID, isPendingEmpty(current), let item = record(current), item.workspaceID == workspaceID, item.profileID == profileChoice, effectiveTopicID(for: item) == topicID {
            displays[current]?.composerFocusRequest += 1; return
        }
        workspaceChangesInFlight.insert(workspaceID)
        let profileID = profileChoice, pendingChoice = overrideWrites[profileChoice]?.task
        let previousChatID = focusedSessionID ?? selectedID
        Task { defer { workspaceChangesInFlight.remove(workspaceID); if let id = selectedID { scheduleAutomaticContext(id) } }
            do {
                await pendingChoice?.value
                let item = try await newChatRecord(workspaceID: workspaceID, profileID: profileID, previousChatID: previousChatID, topicID: topicID)
                // Created on screen only; the first send writes it (materializeChat).
                pendingChatIDs.insert(item.id); chats.insert(item, at: 0); await select(item.id)
            }
            catch { self.error = error.localizedDescription } }
    }
    /// Shared by New Chat and its unsaved project picker. Project resources
    /// remain owned by the destination helper; only model choices are inherited.
    func newChatRecord(workspaceID: String, profileID: String, previousChatID: String?, topicID: String?) async throws -> ChatRecord {
        guard let store else { throw StoreError.unavailable }
        var item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: ChatRecord.defaultTitle, path: nil, profileID: profileID)
        let remembered = try await store.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: profileID)
        let previous = previousChatID.flatMap(record).flatMap { $0.profileID == profileID && !$0.isBackgroundTask ? ChatModelDefaults(chat: $0) : nil }
        (remembered ?? previous)?.apply(to: &item, profile: profiles.first { $0.id == profileID })
        if remembered?.outputBudgetVersion == nil, item.outputBudgetVersion == 1, remembered != nil {
            try await store.put(ChatModelDefaults(chat: item), kind: ChatModelDefaults.recordKind, id: profileID)
        }
        item.topicID = topicID.flatMap { id in topics.contains(where: { $0.id == id && $0.workspaceID == workspaceID }) ? id : nil }
        guard workspaces.contains(where: { $0.id == workspaceID && $0.trusted && !$0.isScratch }) else {
            throw HostError.failure("Choose a trusted project before starting a chat.")
        }
        return item
    }
    /// Writes a pending chat's record before its first message, rename,
    /// archive, connection change or helper session needs it.
    func materializeChat(_ id: String) async throws {
        guard pendingChatIDs.contains(id), let item = chats.first(where: { $0.id == id }) else { return }
        // A first use owns the project even if its write fails and the chat
        // becomes eligible again. Never revive a choice made before that use.
        pendingChatProjectChoices[id] = nil
        guard let store else { throw StoreError.unavailable }
        pendingChatSaveCounts[id, default: 0] += 1
        defer {
            let remaining = pendingChatSaveCounts[id, default: 1] - 1
            pendingChatSaveCounts[id] = remaining > 0 ? remaining : nil
        }
        try await store.put(item, kind: "chat", id: id)
        PerformanceProbe.shared.count("pendingChatCreationWrites")
        if let view = displays[id] { try await loadDraftBaseline(view) }
        // Navigation can discard a still-empty placeholder while this actor
        // write is pending. Do not leave a resurrected desktop row on restart.
        guard record(id) != nil else {
            try await store.remove(kind: "chat", id: id)
            PerformanceProbe.shared.count("pendingChatDiscardCleanupWrites")
            pendingChatIDs.remove(id)
            throw HostError.failure("This chat is no longer available.")
        }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats[index].topicID = effectiveTopicID(for: chats[index])
        }
        pendingChatIDs.remove(id)
        if let draft = displays[id]?.savedDraft, !draft.text.isEmpty || !(draft.attachments ?? []).isEmpty {
            do {
                try await store.put(draft, kind: "draft", id: id, draftVersion: displays[id]?.draftVersion, write: store.draftWriter.capture(id))
                PerformanceProbe.shared.count("pendingChatDraftWrites")
            } catch StoreError.staleRevision {
                // The chat row is durable. Newer typing owns this snapshot;
                // it cannot cancel the separate first submission.
            }
        }
    }
    /// Drops a pending chat that never received a message. Nothing was written.
    func discardPendingChat(_ id: String) {
        guard displays[id]?.draftVersion.hasUnsavedConflict != true, pendingChatIDs.remove(id) != nil else { return }
        chats.removeAll { $0.id == id }; displays.removeValue(forKey: id); helperSessionDidUnload(id)
        forgetOpened(id)
        if selectedID == id { selectedID = nil; selected = nil }
        if focusedSessionID == id { focusedSessionID = nil }
    }
    func isPendingEmpty(_ id: String) -> Bool {
        guard pendingChatIDs.contains(id) else { return false }
        guard let view = displays[id] else { return true }
        // A first message on its way has left the composer empty; the chat
        // is anything but empty. An image being imported also owns this draft.
        return !view.draftVersion.hasUnsavedConflict && !view.loading && view.sendingRows.isEmpty && view.imageImports == 0
            && view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && view.attachments.isEmpty && view.skills.isEmpty
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
        let item = ChatRecord(id: UUID().uuidString, workspaceID: workspaceID, title: ChatRecord.defaultTitle, path: nil, profileID: profileChoice)
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
    /// Makes a new chat from every complete record of one whose last record
    /// was cut off while it was written (a power loss, a full disk). The
    /// helper checks the records and writes the copy under a new identity;
    /// the original file is left exactly as it is.
    func recoverCopy(_ id: String) {
        guard let item = record(id), let source = item.path, let workspace = workspaces.first(where: { $0.id == item.workspaceID }) else { error = "This chat has no saved file to recover."; return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        Task { do {
            // Asked before anything is created or a helper is started, and as
            // a sheet, so the chats behind it keep running.
            switch await questions.confirm(Self.recoveredCopy, about: item.id) {
            case .yes: break
            case .no: return
            case .busy: self.error = PiQuestion.busyNotice; return
            }
            let host = try await host(for: workspace), copyID = UUID().uuidString
            let result = try await host.request("session.recover", params: ["path": .string(source), "newSessionId": .string(copyID)]).object ?? [:]
            guard let path = result["sessionFile"]?.string else { throw StoreError.invalidRecord }
            var copy = ChatRecord(id: copyID, workspaceID: item.workspaceID, title: String((item.title + " — recovered").prefix(120)), path: path, profileID: item.profileID, toolMode: item.toolMode, model: item.model, thinkingLevel: item.thinkingLevel, contextWindow: item.contextWindow, maxOutputTokens: item.maxOutputTokens, modelOutputLimit: item.modelOutputLimit, outputBudgetVersion: item.outputBudgetVersion)
            copy.topicID = effectiveTopicID(for: item)
            try await store.put(copy, kind: "chat", id: copy.id); chats.insert(copy, at: 0); await select(copy.id)
        } catch { self.error = "The chat could not be recovered. Its file was left as it was. \(error.localizedDescription)" } }
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
    var canDeleteCommandChat: Bool {
        conversationCommandsEnabled && conversationCommandID().flatMap(record).map { !$0.isSubagent } == true
    }
    func deleteChat() {
        guard canDeleteCommandChat else { return }
        deleteChat(conversationCommandID())
    }
    /// Deletes any chat by id, so archived chats can go straight from the sidebar.
    func deleteChat(_ id: String?) {
        guard let id, let item = record(id), !item.isSubagent else { return }
        guard displays[id]?.draftVersion.hasUnsavedConflict != true else { error = "Save the conflicting draft before deleting this chat."; return }
        guard displays[id]?.hasWork != true, displays[id]?.loading != true else { error = "Stop work and remove queued submissions before deleting this chat"; return }
        if pendingChatIDs.contains(id) { discardPendingChat(id); return }
        guard let store else { error = StoreError.unavailable.localizedDescription; return }
        if let info = side(id), info.pending { Task { await discardPendingSide(info) }; return }
        if let busy = runningBudgetDependent(of:id) { error = budgetMemberBusy(busy); return }
        Task {
            do {
                // Discovery reads metadata and member journals off the main
                // actor; it never needs the project folder or its helper.
                let preview = try await familyDeletionPreview(item)
                guard record(item.id) != nil else { return }
                let count = preview.managedCount, family = preview.sides
                let isSide = deletionNeedsAncestorRepair(item)
                let title = item.isArchived ? "Delete the archived chat “\(item.title)”?"
                    : family.isEmpty ? (isSide ? "Delete this side?" : "Delete this chat?")
                    : (isSide ? "Delete this side and its sides?" : "Delete this chat and its sides?")
                var detail = item.imported ? "Remove its app index and draft. The imported original stays in place."
                    : "Move its managed conversation files to Trash and remove its draft and retained trace bodies."
                if !family.isEmpty { detail += family.count == 1 ? " Its saved side goes with it, with its sub-agents." : " All \(family.count) of its saved sides go with it, with their sub-agents." }
                if count > 0 { detail += " Includes \(count) managed sub-agent\(count == 1 ? "" : "s")." }
                if isSide { detail += " Its spend stays counted in “\(budgetOwner(for: item).title)”." }
                if ([item.id] + family.map(\.chat.id)).contains(where: { self.sides[$0]?.pending == true }) { detail += " Its unsent side draft is also removed." }
                var question = ChatQuestion(title: title, detail: detail, action: isSide ? "Delete Side" : "Delete Chat")
                question.list = .init(heading: family.isEmpty ? "" : "Saved sides deleted with it (\(family.count))",
                                      items: family.map { .init(title: $0.chat.title, depth: $0.depth) }, notes: preview.skipped)
                if !questions.ask(question, about: item.id, destructive: true, answered: { [weak self] confirmed in
                    guard let self, confirmed, self.record(item.id) != nil else { return }
                    self.performDelete(item, store: store, announced: preview.skipped)
                }) { error = PiQuestion.busyNotice }
            } catch { self.error = "Chat deletion could not be prepared. " + error.localizedDescription }
        }
    }

    private func performDelete(_ item: ChatRecord, store: MetadataStore, announced: [String] = []) {
        Task { do {
            // The confirmation's count is only a preview: a running reply
            // may accept its first delegation while the sheet is open.
            // Every owned journal takes the same unload-and-rescan barrier.
            if !item.imported {
                let skipped = try await deleteSubagentFamily(item)
                // Name anything the confirmation could not have announced.
                if !Set(skipped).isSubset(of: announced) { error = "“\(item.title)” was deleted. " + skipped.joined(separator: " ") }
                return
            }
            guard displays[item.id]?.draftVersion.hasUnsavedConflict != true else { throw StoreError.unavailable }
            if let host = hosts[item.workspaceID] {
                if host.isReady { _ = try await host.request("session.forget", sessionID: item.id) }
                else { try await host.settleCaptureIfStopping() }
            }
            helperSessionDidUnload(item.id)
            try removeRetiredCaptureSpools(sessionID: item.id)
            try await traces.clear(sessionID: item.id)
            forgetReadState(item.id); forgetRunHold(item.id)
            for kind in ["chat", "draft", "anchor", "anchor-deleted", "capture-preference", "handoff", "side-keep", SideKeepRegistration.kind, "session-read", RunHoldRecord.kind, ContextReading.recordKind, JournalSlimMark.kind] { try await store.remove(kind: kind, id: item.id) }
            contextReadings.removeValue(forKey: item.id)
            try await store.removeAll(kind: "draft-conflict:\(item.id)")
            try await store.removeAll(kind: "receipt:\(item.id)")
            for intent in try await store.list(CommandIntent.self, kind: "pending:\(item.id)") { try await store.remove(kind: "pending:\(item.id)", id: intent.id) }
            pendingIntentsChanged(item.id)
            chats.removeAll { $0.id == item.id }; displays.removeValue(forKey: item.id)
            forgetOpened(item.id)
            if selectedID == item.id { selectedID = nil; selected = nil }
            if focusedSessionID == item.id { focusedSessionID = nil }
            do { try await removeDeletedCapturePreference(sessionID: item.id) }
            catch { self.error = "The chat was deleted, but its old capture preference could not be removed. \(error.localizedDescription)" }
        } catch { self.error = "Chat deletion did not complete. \(error.localizedDescription)" } }
    }
}
