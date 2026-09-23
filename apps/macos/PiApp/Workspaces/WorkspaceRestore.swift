import Foundation

// What the workspace reads back at launch and which folder it works in.
// `restore()` runs once: it opens the store off the main actor, pulls the
// projects, topics, chats and read states back, leaves the sidebar paintable
// before the rest of the model has settled, and reopens the chat the reader
// had open (`WorkspaceLaunchSelection.swift`).

extension WorkspaceModel {
    func restore() async {
        guard !restoring else { return }
        guard store != nil else { launching = false; return }
        restoring = true; launching = true
        guard await prepareStore(), let store else { restoring = false; launching = false; return }
        // The rows are live from the moment the chats are listed. A chat the
        // reader opens from them, or from the menu bar, before this finishes
        // is the one they want: launch must not open another over it.
        let launchSelection = selectionRevision
        // The chat list and the vault are independent reads, and the sidebar's
        // first frame needs both: read serially, every chat was listed under a
        // "Retained chats" placeholder until the Keychain answered. What the
        // reader had open last time rides along with the chat list.
        async let savedConfiguration = vault.load()
        async let savedSelection = store.get(RememberedSelection.self, kind: RememberedSelection.recordKind, id: RememberedSelection.recordID)
        do {
            let restored = try await store.loadChats()
            var loaded: VaultConfiguration?
            do { let saved = try await savedConfiguration; applyConfiguration(saved); loaded = saved }
            catch { configurationLoaded = false; self.error = error.localizedDescription; retryConfigurationWhenActive() }
            // A record this build cannot read is no record: the launch opens
            // what it always did.
            let remembered = (try? await savedSelection)?.sanitized
            chats = restored
            await dropLeftoverTitleSuggestions()
            await nameUnnamedJournals()
            adoptRememberedSelection(remembered)
            try await restoreTopics()
            try await restoreReadStates()
            await reconcileSideKeeps()
            try await restoreProjectSidebarStates()
            if selectedID == nil, selectionRevision == launchSelection {
                // The reopened chat's project is the chosen one from here on.
                selectedWorkspaceID = launchProjectID(remembered); profileChoice = requestProfiles.first?.id ?? ""
            }
            // The request archive's retention sweep and retained billing for
            // every listed chat are the two longest reads of a launch, and the
            // sidebar is already on screen: they run after it, not before it.
            // The archive opens (with its sweep) before the chat does, since
            // the chat's accounting reads it and its helper writes into it;
            // the billing of every listed chat waits until the chat is open.
            var archiveOpen = false
            if let loaded { archiveOpen = await openConfiguredArchive(loaded) }
            // Restore history without opening every runtime: one chat, the one
            // the reader had open. Only the focused, safe native chat may
            // prepare its context in the background.
            let launchOpened = await reopenRememberedSelection(remembered, unlessSelectedSince: launchSelection)
            // The pane shows the chat now, or the welcome if there is none.
            launching = false
            // A chat launch opened reads its own accounting once its page is
            // on screen (`historyViewportReady`), as every opened chat does. A
            // chat the reader opened while launch was still reading may have
            // read it before the archive was open: read those again.
            if archiveOpen { if launchOpened { await refreshChatStats() } else { await refreshRetainedAccounting() } }
            // A chat this build cannot list is not a chat that is gone. Say so
            // once, instead of leaving a row silently missing from the sidebar.
            let unlisted = await store.unlistedChats
            if unlisted > 0, self.error == nil {
                self.error = "\(unlisted) saved chat\(unlisted == 1 ? "" : "s") could not be listed by this version. Their conversation files are untouched."
            }
        } catch { restoring = false; launching = false; self.error = "Chats could not be restored. \(error.localizedDescription)" }
    }
    /// A chat's journal is named in its record only once the helper has made
    /// it. A crash or a failed write in between left a record with no path
    /// over a journal that exists: the chat opened as an empty New chat, and
    /// every send failed with "Session path already exists". Named here, it
    /// opens with its history and sends. A record with no journal is left as
    /// it is.
    func nameUnnamedJournals() async {
        let unnamed = chats.filter { $0.path == nil && !$0.imported }.map(\.id)
        for id in unnamed {
            guard let chat = chats.first(where: { $0.id == id }), chat.path == nil else { continue }
            let journal = root.appendingPathComponent("Workspaces/\(chat.workspaceID)/Sessions/\(chat.id).jsonl")
            guard FileManager.default.fileExists(atPath: journal.path) else { continue }
            var named = chat; named.path = journal.path
            do { try await store?.put(named, kind: "chat", id: id) } catch { continue }
            if let index = chats.firstIndex(where: { $0.id == id }), chats[index].path == nil { chats[index].path = journal.path }
        }
    }
    func pickWorkspace() {
        // A sheet on the main window: choosing a folder must not stop the
        // chats that are streaming behind it.
        if !questions.chooseOne(message: "Choose the working directory for Bello Agent.", directories: true, { [weak self] url in
            self?.adoptWorkspace(at: url.resolvingSymlinksInPath())
        }) { error = PiQuestion.busyNotice }
    }
    private func adoptWorkspace(at url: URL) {
        let existing = workspaces.first(where: { $0.path == url.path })
        if let existing, existing.trusted { selectedWorkspaceID = existing.id; return }
        let workspace = WorkspaceRecord(id: existing?.id ?? UUID().uuidString, path: url.path, trusted: true, paths: existing?.paths ?? [])
        Task { do { try await updateConfiguration {
            if let index = $0.workspaces.firstIndex(where: { $0.id == workspace.id }) { $0.workspaces[index] = workspace }
            else { $0.workspaces.append(workspace) }
        }; selectedWorkspaceID = workspace.id }
            catch { self.error = error.localizedDescription } }
    }
}
