import Foundation

// What the reader had open, kept so the next launch puts them back there.
// Launch used to open whichever chat sorted first, because the chat on screen
// was never written anywhere. It is written as it changes — debounced, and on
// the store's own actor rather than the main one — not only at quit, so a
// crash or a force-quit still reopens it; quitting and updating flush a change
// that is still waiting. The same record keeps the saved side each chat last
// showed beside it, which comes back whenever that chat is opened again.

/// The chat in the main pane, its project, and the saved sides shown beside
/// chats. One record for the one window, in the desktop metadata store.
struct RememberedSelection: Codable, Sendable, Equatable {
    static let recordKind = "selection"
    static let recordID = "main"
    /// A reader keeps a handful of sides open; a record read back is never
    /// trusted to be that small.
    static let maximumShownSides = 256
    /// The chat in the main pane; nil when none was open.
    var chatID: String?
    /// The project that was chosen. A relaunch chooses the reopened chat's
    /// own; this stands only for a chat outside every project, or when no
    /// chat reopens.
    var projectID: String?
    /// The saved side each chat last showed beside it, by chat id. A side
    /// that has not been kept is never one: it exists only on screen.
    var shownSides: [String: String]?
    /// True when the open chat's side, rather than the chat, had the keyboard.
    var sideFocused: Bool?
    var revision: Int64 = 0

    /// The same chat, project, sides and focus, whenever each was written.
    func names(_ other: RememberedSelection) -> Bool {
        var lhs = self, rhs = other
        lhs.revision = 0; rhs.revision = 0
        return lhs == rhs
    }

    /// Nothing read back from the store is trusted to be the shape it was
    /// written in. A record that cannot be ordered against the next write is
    /// no record at all.
    var sanitized: RememberedSelection? {
        guard revision >= 0, revision < Int64.max else { return nil }
        func usable(_ id: String?) -> String? { id.flatMap { !$0.isEmpty && $0.utf8.count <= 512 ? $0 : nil } }
        var value = self
        value.chatID = usable(chatID); value.projectID = usable(projectID)
        value.shownSides = shownSides.map { sides in
            Dictionary(uniqueKeysWithValues: sides.filter { usable($0.key) != nil && usable($0.value) != nil }
                .sorted { $0.key < $1.key }.prefix(Self.maximumShownSides).map { ($0.key, $0.value) })
        }
        return value
    }
}

/// Sidebar groups opened for this launch only, so the row of the chat a
/// relaunch put back on screen can be seen. Never written: the collapse and
/// archive choices the reader saved stay what they chose, and the first time
/// they touch one of these groups themselves, their choice is what shows.
struct SidebarLaunchReveal: Equatable {
    /// Collapsed projects shown open.
    var projects: Set<String> = []
    /// Collapsed topics shown open.
    var topics: Set<String> = []
    /// Projects showing the other of their two lists: true for the archive.
    var archive: [String: Bool] = [:]
}

extension WorkspaceModel {
    /// How long a changed selection waits before it is written. Every change
    /// made during the wait rides along with it, so stepping through the
    /// sidebar with the keyboard writes a few times a second at most, and the
    /// last write is always where the reader stopped.
    static let selectionWriteDelay: Duration = .milliseconds(250)

    /// What the next launch should reopen. A New chat that was never sent is
    /// written nowhere, so it would not exist after a relaunch: while one is
    /// open, the chat open before it stays the one to come back to.
    var selectionToRemember: RememberedSelection {
        var value: RememberedSelection
        if let id = selectedID, pendingChatIDs.contains(id) {
            value = rememberedSelection ?? RememberedSelection()
        } else {
            value = RememberedSelection(chatID: selectedID, projectID: selectedWorkspaceID)
            if let id = selectedID, let side = sides[id], side.kept, focusedSessionID == side.id { value.sideFocused = true }
        }
        value.shownSides = rememberedSides.isEmpty ? nil : rememberedSides
        return value
    }

    /// Called whenever the open chat, its project, a side pane or the focus
    /// between a chat and its side may have changed. Cheap when nothing did.
    func noteSelectionChanged() {
        guard remembersSelection, store != nil else { return }
        var next = selectionToRemember
        if let current = rememberedSelection, current.names(next) { return }
        let previous = min(rememberedSelection?.revision ?? 0, Int64.max - 1)
        next.revision = max(previous + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        rememberedSelection = next
        scheduleSelectionWrite(after: Self.selectionWriteDelay)
    }

    /// A side pane opened, closed, or its side was kept. A kept side becomes
    /// the one to reopen beside its chat; a closed pane forgets it. A side
    /// that has not been kept changes nothing: it would not exist after a
    /// relaunch, and the kept side it covers would.
    func sidesChanged(from old: [String: SideRecord]) {
        guard remembersSelection else { return }
        var next = rememberedSides
        for parent in Set(old.keys).union(sides.keys) {
            let before = old[parent], after = sides[parent]
            guard before?.id != after?.id || before?.kept != after?.kept else { continue }
            if let after { if after.kept { next[parent] = after.id } } else { next.removeValue(forKey: parent) }
        }
        if next != rememberedSides { rememberedSides = next }
        noteSelectionChanged()
    }

    /// The saved side a chat last showed beside it, while it is still that
    /// chat's side. `select` reopens it.
    func rememberedSide(of parentID: String) -> ChatRecord? {
        guard let id = rememberedSides[parentID], let child = chatRecord(id),
              child.parentSessionID == parentID, !child.imported else { return nil }
        return child
    }

    /// One write in flight at a time, carrying whatever is newest when it
    /// runs. Only the task itself clears `selectionWrite`, so a newer task can
    /// never be forgotten by an older one finishing.
    private func scheduleSelectionWrite(after delay: Duration?) {
        guard selectionWrite == nil else { return }
        selectionWrite = Task { [weak self] in
            // A flush cancels the wait to write at once.
            if let delay { try? await Task.sleep(for: delay) }
            guard let self else { return }
            defer { self.selectionWrite = nil }
            // Shut down: nothing more is written for this model.
            guard self.remembersSelection else { return }
            while let value = self.rememberedSelection, value.revision > self.savedSelectionRevision {
                guard await self.persistSelection(value) else { return }
            }
        }
    }

    /// A failure is not reported. It is a place to come back to, not
    /// something the reader made: the next change and the quit flush retry
    /// it, and a store that cannot write is already reported by the drafts,
    /// read states and sidebar preferences written beside it.
    private func persistSelection(_ value: RememberedSelection) async -> Bool {
        guard let store else { return false }
        do { try await store.put(value, kind: RememberedSelection.recordKind, id: RememberedSelection.recordID, revision: value.revision) }
        catch StoreError.staleRevision { /* A newer selection is already on disk. */ }
        catch { return false }
        savedSelectionRevision = max(savedSelectionRevision, value.revision)
        return true
    }

    /// Writes a selection still waiting on its debounce. Quit and update call
    /// this after the drafts are flushed, because flushing a New chat's draft
    /// gives it a chat record, and that chat is then the one to reopen.
    /// Bounded, and never a reason to refuse quitting.
    @discardableResult func flushSelection(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var retried = false
        while selectionWrite != nil || (rememberedSelection?.revision ?? 0) > savedSelectionRevision {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if let write = selectionWrite { write.cancel() }
            else if remembersSelection, !retried { retried = true; scheduleSelectionWrite(after: nil) }
            else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }

    /// Stops writing for good: this model is going away.
    func stopRememberingSelection() {
        remembersSelection = false
        selectionWrite?.cancel()
    }

    /// What the last session left, as soon as the chats are listed, so a
    /// chat the reader opens from the first painted row brings its side back.
    func adoptRememberedSelection(_ remembered: RememberedSelection?) {
        rememberedSelection = remembered
        savedSelectionRevision = remembered?.revision ?? 0
        rememberedSides = (remembered?.shownSides ?? [:]).filter { parent, side in
            chatRecord(parent) != nil && chatRecord(side).map { $0.parentSessionID == parent && !$0.imported } == true
        }
    }

    /// The chat launch reopens: the remembered one while it exists and is
    /// not a background task, else the first chat, as every launch opened.
    func launchTarget(_ remembered: RememberedSelection?) -> (chat: ChatRecord, remembered: Bool)? {
        if let chat = remembered?.chatID.flatMap(chatRecord), !chat.isBackgroundTask { return (chat, true) }
        return chats.first(where: { !$0.isArchived && !$0.isBackgroundTask }).map { ($0, false) }
    }

    /// The project shown as chosen from the moment the chats are listed: the
    /// one the reopened chat belongs to, which is where selecting it lands
    /// anyway. The remembered choice only stands for a chat outside every
    /// project, or when no chat reopens.
    func launchProjectID(_ remembered: RememberedSelection?) -> String? {
        if let chat = launchTarget(remembered)?.chat, chat.workspaceID != WorkspaceRecord.scratchID,
           workspaces.contains(where: { $0.id == chat.workspaceID }) { return chat.workspaceID }
        if let id = remembered?.projectID, workspaces.contains(where: { $0.id == id }) { return id }
        return workspaces.first?.id
    }

    /// Puts the reader back on what they had open: the chat, its project and
    /// the side beside it (which `select` brings back), with the keyboard
    /// where it was. When there is no record, or its chat is gone, is a
    /// background task, or was a New chat never sent (the chat open before
    /// it is remembered instead), the first chat opens, as every launch did
    /// before. A chat the reader opened while launch was still reading is
    /// theirs and stays. Selects one chat at most, and opens no runtime.
    /// Returns whether launch opened a chat itself.
    @discardableResult
    func reopenRememberedSelection(_ remembered: RememberedSelection?, unlessSelectedSince revision: Int) async -> Bool {
        // From here on every change is written. Whatever the reader opened
        // while this was loading is the selection now, and is written first.
        defer { remembersSelection = true; noteSelectionChanged() }
        guard selectedID == nil, selectionRevision == revision, case let (target, isRemembered)? = launchTarget(remembered) else { return false }
        let saved = isRemembered ? target : nil
        let side = saved.flatMap { rememberedSide(of: $0.id) }
        if let saved {
            // The highlighted row is the side's when it had the keyboard.
            let highlighted = remembered?.sideFocused == true ? side ?? saved : saved
            revealForLaunch(highlighted)
        }
        await select(target.id, revealInSidebar: false)
        // The reader may have opened something else while the page loaded.
        guard let saved, selectedID == saved.id else { return true }
        if remembered?.sideFocused == true, let side, sides[saved.id]?.id == side.id, focusedSessionID == saved.id {
            focusedSessionID = side.id; focusComposer(side.id)
        }
        return true
    }

    /// Opens, for this launch only, whatever hides the reopened chat's row:
    /// its collapsed project or topic, or the other of the project's two
    /// lists. Nothing is written.
    func revealForLaunch(_ item: ChatRecord) {
        guard sidebarProjects.contains(where: { $0.id == item.workspaceID }) else { return }
        var reveal = SidebarLaunchReveal()
        let saved = projectSidebarStates[item.workspaceID]
        if saved?.expanded == false { reveal.projects.insert(item.workspaceID) }
        if (saved?.archived ?? false) != item.isArchived { reveal.archive[item.workspaceID] = item.isArchived }
        if let topicID = effectiveTopicID(for: item), topics.first(where: { $0.id == topicID })?.expanded == false {
            reveal.topics.insert(topicID)
        }
        if reveal != launchReveal { launchReveal = reveal }
    }

    /// The reader chose this project's disclosure or list themselves.
    func forgetLaunchReveal(project id: String) {
        guard launchReveal.projects.contains(id) || launchReveal.archive[id] != nil else { return }
        var next = launchReveal
        next.projects.remove(id); next.archive[id] = nil
        launchReveal = next
    }

    /// The reader opened or closed this topic themselves.
    func forgetLaunchReveal(topic id: String) {
        guard launchReveal.topics.contains(id) else { return }
        var next = launchReveal
        next.topics.remove(id)
        launchReveal = next
    }

    /// Whether a topic lists its chats: as saved, or opened for this launch.
    func topicIsExpanded(_ topic: TopicRecord) -> Bool { topic.expanded || launchReveal.topics.contains(topic.id) }
}
