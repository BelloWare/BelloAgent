import Foundation

// Which chat is open, and everything that has to be true by the time it is
// on screen: its display loaded or built, its page fetched, its composer
// focused, and the displays of chats nobody is reading let go of.

extension WorkspaceModel {
    func select(_ id: String, revealInSidebar: Bool = true, preserveArchiveFilter: Bool = false) async {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        if selectedID == id, let selected, selected.historyState != .dormant {
            page = .chats; focusedSessionID = id
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
        if let previous = selectedID, previous != id, isPendingEmpty(previous) { discardPendingChat(previous) }
        if preserveArchiveFilter {
            setProjectExpanded(item.workspaceID, expanded: true)
            if let topicID = effectiveTopicID(for: item) { setTopicExpanded(topicID, expanded: true) }
        } else if revealInSidebar { revealProjectChat(item) } else { showArchivedSessions = item.isArchived }
        PerformanceProbe.shared.count("sessionSelectionCalls")
        PerformanceProbe.shared.beginSelection(id, hasHistory: item.path != nil)
        let view = displays[id] ?? SessionDisplay(id: id)
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        view.historyState = .loading; view.olderPage = .init(); view.newerPage = .init()
        view.historyProgress = nil
        view.contextSelectionReady = false; view.browsingHistory = true
        view.draftReady = view.selectionMetadataLoaded
        view.used = Date(); displays[id] = view
        selectedID = id; selected = view; profileChoice = item.profileID
        focusedSessionID = id; page = .chats
        view.publishTranscript()
        clearFailureMark(sessionID: id)
        if item.workspaceID != WorkspaceRecord.scratchID { selectedWorkspaceID = item.workspaceID }
        if let info = sides[id], let sideView = displays[info.id], let child = record(info.id) {
            sideView.presentation.begin(); sideView.presentationGeneration = sideView.presentation.generation
            sideView.historyProgress = nil; sideView.historyState = .loading; sideView.browsingHistory = true
            sideView.draftReady = sideView.selectionMetadataLoaded || info.pending
            sideView.publishTranscript()
            let sideGeneration = sideView.presentationGeneration
            Task { [weak self, weak sideView] in
                guard let self, let sideView, self.selectedID == id, self.sides[id]?.id == child.id,
                      self.selectionRevision == selection, sideView.presentationGeneration == sideGeneration else { return }
                await self.loadSideDisplay(child, view: sideView)
            }
        }
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            other.presentation.cancel(); displays.removeValue(forKey: other.id)
        }
        let generation = view.presentationGeneration
        PerformanceProbe.shared.observe("selectionLoadingFeedbackMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.selectionRevision == selection && self.selectedID == id &&
                    self.displays[id] === view && view.presentationGeneration == generation && self.record(id)?.path == item.path
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
                let page = try await self.readConversationWindow(item, cursor: nil)
                guard current() else { return }
                self.adoptInitialHistory(page, into: view)
                if let profile = self.profiles.first(where: { $0.id == item.profileID }), profile.api != LiteLLMConfiguration.supportedAPI {
                    view.notice = LiteLLMConfiguration.unsupportedAPIMessage
                }
                if !view.recovered.isEmpty { view.notice = "Outcome uncertain for a previous command. Review the saved history before sending again." }
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError { }
            catch {
                guard current() else { return }
                view.historyState = .failed(error.localizedDescription); view.notice = error.localizedDescription; view.draftReady = view.selectionMetadataLoaded
            }
        }
        navigationTask = task; view.presentation.navigation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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
