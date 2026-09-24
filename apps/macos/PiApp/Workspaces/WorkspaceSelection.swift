import Foundation

// Which chat is open, and everything that has to be true by the time it is
// on screen: its display loaded or built, its page fetched, its composer
// focused, and the displays of chats nobody is reading let go of.

extension WorkspaceModel {
    func select(_ id: String, revealInSidebar: Bool = true, preserveArchiveFilter: Bool = false, reopensSide: Bool = true) async {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        // A chat whose load ended without a page (nothing is reading it any
        // more) is read again rather than left on "Preparing…" for good.
        if selectedID == id, let selected, selected.historyState != .dormant,
           !(selected.historyState == .loading && selected.presentation.navigation == nil) {
            page = .chats; focusedSessionID = id
            // A run that failed while another app was in front marked this
            // chat; clicking it is looking at it.
            clearFailureMark(sessionID: id)
            if revealInSidebar { revealProjectChat(item) }
            // Keep the transcript idempotent while allowing an expired or
            // missing optional preview to recover after helper eviction.
            if selected.presentation.readyAt != nil { scheduleAutomaticContext(id) }
            return
        }
        navigationTask?.cancel()
        if let outgoing = selected {
            outgoing.presentation.cancel()
            if let child = sides[outgoing.id] { displays[child.id]?.presentation.cancel() }
        }
        selectionRevision += 1
        let selection = selectionRevision
        let previous = selectedID
        if preserveArchiveFilter {
            setProjectExpanded(item.workspaceID, expanded: true)
            if let topicID = effectiveTopicID(for: item) { setTopicExpanded(topicID, expanded: true) }
        } else if revealInSidebar { revealProjectChat(item) } else { showArchivedSessions = item.isArchived }
        PerformanceProbe.shared.count("sessionSelectionCalls")
        PerformanceProbe.shared.beginSelection(id, hasHistory: item.path != nil)
        let view = displays[id] ?? SessionDisplay(id: id), cached = view.hasPresentedRows
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        view.historyState = .loading; view.refreshingCachedRows = cached; view.olderPage = .init(); view.newerPage = .init()
        view.historyProgress = nil
        view.contextSelectionReady = false; view.browsingHistory = true
        view.draftReady = view.selectionMetadataLoaded
        view.used = Date(); displays[id] = view
        selectedID = id; selected = view; profileChoice = item.profileID
        focusedSessionID = id; page = .chats
        // An empty New chat is dropped once the next chat is in its place, so
        // the selection changes once: through nil first, it read as a second
        // navigation to anything waiting on this one (`revealMessage`).
        if let previous, previous != id, isPendingEmpty(previous) { discardPendingChat(previous) }
        view.publishTranscript()
        clearFailureMark(sessionID: id)
        if item.workspaceID != WorkspaceRecord.scratchID { selectedWorkspaceID = item.workspaceID }
        // The side shown beside this chat comes back with it: the one open in
        // this launch, or else the saved side it showed when the app last
        // closed (`WorkspaceLaunchSelection.swift`).
        var shownSide: (child: ChatRecord, view: SessionDisplay)?
        if let info = sides[id], let sideView = displays[info.id], let child = record(info.id) {
            let sideCached = sideView.hasPresentedRows
            sideView.presentation.begin(); sideView.presentationGeneration = sideView.presentation.generation
            sideView.historyProgress = nil; sideView.historyState = .loading; sideView.refreshingCachedRows = sideCached; sideView.browsingHistory = true
            sideView.draftReady = sideView.selectionMetadataLoaded || info.pending
            sideView.publishTranscript()
            shownSide = (child, sideView)
        } else if reopensSide, sides[id] == nil, !installPreparing, let child = rememberedSide(of: id) {
            shownSide = (child, mountSide(child, beside: id))
        }
        if case let (child, sideView)? = shownSide {
            let sideGeneration = sideView.presentationGeneration
            Task { [weak self, weak sideView] in
                guard let self, let sideView, self.selectedID == id, self.sides[id]?.id == child.id,
                      self.selectionRevision == selection, sideView.presentationGeneration == sideGeneration else { return }
                await self.loadSideDisplay(child, view: sideView)
            }
        }
        // A new chat that was never sent has nothing written anywhere (see
        // `materializeChat`): its display is the only place its draft lives,
        // so it is not let go of while it holds one.
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading
            && !(pendingChatIDs.contains(other.id) && !isPendingEmpty(other.id)) && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            other.presentation.cancel(); displays.removeValue(forKey: other.id)
            releaseHelperSession(other.id)
        }
        let generation = view.presentationGeneration
        PerformanceProbe.shared.observe("selectionLoadingFeedbackMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            // However this ends, nothing is reading the chat any more.
            defer { if view.presentationGeneration == generation { view.presentation.navigation = nil } }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.selectionRevision == selection && self.selectedID == id &&
                    self.displays[id] === view && view.presentationGeneration == generation
            }
            do {
                let wantsMetadata = !view.selectionMetadataLoaded
                let draftAtStart = view.savedDraft
                let metadata = try await self.store?.selectionMetadata(id: id, draft: wantsMetadata,
                                                anchor: wantsMetadata && view.scrollAnchor == nil)
                guard current() else { return }
                if wantsMetadata {
                    if let draft = metadata?.draft, view.draft == draftAtStart.text && view.attachments == (draftAtStart.attachments ?? []) && view.skills == (draftAtStart.skills ?? []),
                       view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil { view.restoreDraft(draft) }
                    if view.scrollAnchor == nil { view.scrollAnchor = metadata?.anchor }
                    view.selectionMetadataLoaded = true
                }
                view.draftReady = true
                view.recovered = metadata?.recovered ?? []; view.uncertain = !view.recovered.isEmpty
                view.composerFocusRequest += 1
                // The chat's file can be named while its page is read: its
                // first message writes the journal, and the helper can report
                // a moved one. A page read under the old name is read again
                // under the new one instead of being dropped with nothing in
                // its place.
                let held = view.scrollAnchor
                var source = item, page = try await self.readInitialWindow(source, holding: held)
                for _ in 0..<3 {
                    guard current(), let now = self.record(id), now.path != source.path else { break }
                    source = now; page = try await self.readInitialWindow(source, holding: held)
                }
                guard current(), self.record(id)?.path == source.path else { return }
                self.adoptInitialHistory(page, into: view)
                if let profile = self.profiles.first(where: { $0.id == item.profileID }), profile.api != LiteLLMConfiguration.supportedAPI {
                    view.notice = LiteLLMConfiguration.unsupportedAPIMessage
                }
                if !view.recovered.isEmpty { view.notice = "Outcome uncertain for a previous command. Review the saved history before sending again." }
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError { }
            catch {
                guard current() else { return }
                view.historyState = .failed(error.localizedDescription); view.refreshingCachedRows = false
                view.notice = error.localizedDescription; view.draftReady = view.selectionMetadataLoaded
            }
        }
        navigationTask = task; view.presentation.navigation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    /// The page a chat opens on: its newest turns, or, when the reader left it
    /// further back than those, the turns from where they were, read the way
    /// a jump to a message is (`revealMessage`). Opening on the newest page
    /// alone dropped that position on every switch back and relaunch. A row
    /// no longer in the conversation (an edit, another branch) opens on the
    /// newest page, as before.
    func readInitialWindow(_ source: ChatRecord, holding anchor: TranscriptAnchor?) async throws -> ConversationHistoryPage {
        let latest = try await readConversationWindow(source, cursor: nil)
        guard let anchor, !anchor.followsBottom, !anchor.id.isEmpty, !latest.messages.contains(where: { $0.id == anchor.id }) else { return latest }
        do {
            let around = try await readConversationWindow(source, cursor: nil, around: anchor.id)
            return around.messages.contains(where: { $0.id == anchor.id }) ? around : latest
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return latest }
    }
    /// Puts the cursor in a chat's composer: the given chat, else the focused
    /// side, else the selected chat. Every deliberate move between chats calls
    /// this so typing can start at once; background events never do.
    func focusComposer(_ id: String? = nil) {
        guard let target = id ?? focusedSessionID ?? selectedID else { return }
        displays[target]?.composerFocusRequest += 1
    }
    func selectSide(_ id: String) async {
        guard let info = side(id), displays[id] != nil else {
            // A saved child chat that is not the shown side opens in the pane.
            if chats.contains(where: { $0.id == id && $0.parentSessionID != nil }) { await showSide(id) }
            return
        }
        if selectedID != info.parentID { await select(info.parentID) }
        guard selectedID == info.parentID, side(id) != nil else { return }
        page = .chats; focusedSessionID = id
        if let child = record(id) { revealProjectChat(child) }
        focusComposer(id)
        scheduleAutomaticContext(id)
    }
}
