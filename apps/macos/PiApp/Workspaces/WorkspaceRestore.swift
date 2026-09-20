import Foundation

// What the workspace reads back at launch and which folder it works in.
// `restore()` runs once: it opens the store off the main actor, pulls the
// projects, topics, chats and read states back, and leaves the sidebar
// paintable before the rest of the model has settled.

extension WorkspaceModel {
    func restore() async {
        guard !restoring, store != nil else { return }; restoring = true
        guard await prepareStore(), let store else { restoring = false; return }
        // The chat list and the vault are independent reads, and the sidebar's
        // first frame needs both: read serially, every chat was listed under a
        // "Retained chats" placeholder until the Keychain answered.
        async let savedConfiguration = vault.load()
        do {
            let restored = try await store.loadChats()
            var loaded: VaultConfiguration?
            do { let saved = try await savedConfiguration; applyConfiguration(saved); loaded = saved }
            catch { configurationLoaded = false; self.error = error.localizedDescription }
            chats = restored
            try await restoreTopics()
            try await restoreReadStates()
            await reconcileSideKeeps()
            try await restoreProjectSidebarStates()
            selectedWorkspaceID = workspaces.first?.id; profileChoice = requestProfiles.first?.id ?? ""
            // The request archive's retention sweep and retained billing for
            // every listed chat are the two longest reads of a launch, and the
            // sidebar is already on screen: they run after it, not before it.
            if let loaded { await finishConfiguration(loaded) }
            // Restore history without opening every runtime. Only the focused,
            // safe native chat may prepare its context in the background.
            if let first = chats.first(where: { !$0.isArchived && !$0.isBackgroundTask }) { await select(first.id, revealInSidebar: false) }
            // A chat this build cannot list is not a chat that is gone. Say so
            // once, instead of leaving a row silently missing from the sidebar.
            let unlisted = await store.unlistedChats
            if unlisted > 0, self.error == nil {
                self.error = "\(unlisted) saved chat\(unlisted == 1 ? "" : "s") could not be listed by this version. Their conversation files are untouched."
            }
        } catch { restoring = false; self.error = "Chats could not be restored. \(error.localizedDescription)" }
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
