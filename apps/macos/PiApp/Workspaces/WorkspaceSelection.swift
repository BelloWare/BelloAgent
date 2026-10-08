import Foundation

// Which chat is open, and everything that has to be true by the time it is
// on screen: its display loaded or built, its page fetched, its composer
// focused, and the displays of chats nobody is reading let go of.

extension WorkspaceModel {
    /// `focusesComposer` false: the chat opens for a side beside it, which
    /// takes the cursor (`showSide`, `selectSide`).
    func select(_ id: String, revealInSidebar: Bool = true, preserveArchiveSwitch: Bool = false, reopensSide: Bool = true,
                focusesComposer: Bool = true) async {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        if revealInSidebar || preserveArchiveSwitch { quietSidebarReveal = [] }
        // A background request is listed on its own page, not the sidebar:
        // the menu bar's running requests and the report open it there.
        if item.isBackgroundTask { openBackgroundRequests(selecting: id); return }
        if reselectOpenChat(id, item: item, revealInSidebar: revealInSidebar) { return }
        let (view, selection, heldRows) = prepareSelection(id, item: item, revealInSidebar: revealInSidebar, preserveArchiveSwitch: preserveArchiveSwitch,
                                                           focusesComposer: focusesComposer)
        restoreShownSide(of: id, selection: selection, reopensSide: reopensSide)
        releaseUnreadDisplays(keeping: id)
        let generation = view.presentationGeneration
        PerformanceProbe.shared.observe("selectionLoadingFeedbackMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            await self.loadSelectedChat(id, item: item, into: view, selection: selection, generation: generation, heldRows: heldRows,
                                        focusesComposer: focusesComposer)
        }
        navigationTask = task; view.presentation.navigation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    /// Opening the chat that is already open, with its page or reading it:
    /// the chat is focused and looked at, and nothing is read again.
    /// Returns whether it was that chat.
    private func reselectOpenChat(_ id: String, item: ChatRecord, revealInSidebar: Bool) -> Bool {
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
            return true
        }
        return false
    }
    /// The switch itself, before anything is read: the chat being left stops
    /// its reads, the sidebar shows the new one, and its display, kept or new,
    /// becomes the selection and starts loading. Returns that display, the
    /// selection's revision, and the rows it held.
    private func prepareSelection(_ id: String, item: ChatRecord, revealInSidebar: Bool, preserveArchiveSwitch: Bool,
                                  focusesComposer: Bool) -> (view: SessionDisplay, selection: Int, heldRows: HeldRows) {
        navigationTask?.cancel()
        if let outgoing = selected {
            outgoing.presentation.cancel()
            if let child = sides[outgoing.id] { displays[child.id]?.presentation.cancel() }
        }
        selectionRevision += 1
        let selection = selectionRevision
        let previous = selectedID
        if preserveArchiveSwitch {
            setProjectExpanded(item.workspaceID, expanded: true)
            if let topicID = effectiveTopicID(for: item) { setTopicExpanded(topicID, expanded: true) }
        } else if revealInSidebar { revealProjectChat(item) }
        PerformanceProbe.shared.count("sessionSelectionCalls")
        PerformanceProbe.shared.beginSelection(id, hasHistory: item.path != nil)
        let view = displays[id] ?? SessionDisplay(id: id)
        // Rows from a run that finished while the chat was in the background
        // are not kept on the page: they are the run as the reader left it,
        // and they would change under the reader when the finished page came.
        // The chat opens as a chat opened for the first time does.
        if view.hasPresentedRows, view.heldRowsOutlived { view.messages = []; view.presentation.identity = nil }
        let cached = view.hasPresentedRows
        // What the rows shown were read under, should they still be the chat's rows.
        let heldIdentity = view.presentation.identity, heldTurnInput = view.presentation.partialTurnInput
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        // Reads under way end with the page they were for; the boundaries
        // themselves stay until a page read in replaces them, since the rows
        // shown may turn out to be the chat's rows still.
        view.historyState = .loading; view.refreshingCachedRows = cached
        view.olderPage = .init(cursor: view.olderPage.cursor); view.newerPage = .init(cursor: view.newerPage.cursor)
        view.historyProgress = nil
        view.contextSelectionReady = false; view.browsingHistory = true
        view.draftReady = view.selectionMetadataLoaded
        view.used = Date(); displays[id] = view
        adoptContextReading(view, item: item)
        // Opened for a side beside it, which takes the cursor, the chat's
        // composer does not: no request is made for it below, and the
        // composer made anew for the switch does not act on the last one an
        // earlier visit made. Either, acted on once the side had the cursor,
        // put it back in the chat, and the side never took it.
        view.composerFocusSettled = focusesComposer ? 0 : view.composerFocusRequest
        selectedID = id; selected = view; profileChoice = item.profileID
        focusedSessionID = id; page = .chats
        // An empty New chat is dropped once the next chat is in its place, so
        // the selection changes once: through nil first, it read as a second
        // navigation to anything waiting on this one (`revealMessage`).
        if let previous, previous != id, isPendingEmpty(previous) { discardPendingChat(previous) }
        view.publishTranscript()
        clearFailureMark(sessionID: id)
        if item.workspaceID != WorkspaceRecord.scratchID { selectedWorkspaceID = item.workspaceID }
        return (view, selection, HeldRows(cached: cached, identity: heldIdentity, partialTurnInput: heldTurnInput))
    }
    /// The side shown beside this chat comes back with it: the one open in
    /// this launch, or else the saved side it showed when the app last
    /// closed (`WorkspaceLaunchSelection.swift`).
    private func restoreShownSide(of id: String, selection: Int, reopensSide: Bool) {
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
            // Nor does the side's composer, made anew beside it, act on an
            // earlier visit's request: the chat takes the cursor, or whoever
            // opened the chat for this side gives it to the side.
            sideView.composerFocusSettled = sideView.composerFocusRequest
            let sideGeneration = sideView.presentationGeneration
            Task { [weak self, weak sideView] in
                guard let self, let sideView, self.selectedID == id, self.sides[id]?.id == child.id,
                      self.selectionRevision == selection, sideView.presentationGeneration == sideGeneration else { return }
                await self.loadSideDisplay(child, view: sideView)
            }
        }
    }
    /// The displays of chats nobody is reading are let go of, least recently
    /// used first, until no more than eight are kept.
    private func releaseUnreadDisplays(keeping id: String) {
        // A new chat that was never sent has nothing written anywhere (see
        // `materializeChat`): its display is the only place its draft lives,
        // so it is not let go of while it holds one.
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading
            && !(pendingChatIDs.contains(other.id) && !isPendingEmpty(other.id)) && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            other.presentation.cancel(); displays.removeValue(forKey: other.id)
            releaseHelperSession(other.id)
        }
    }
    /// Reads the opened chat's saved draft and place, then its page, and shows
    /// it: the rows it held when they are still its newest, else the page read.
    /// It stops wherever the reader has moved on.
    private func loadSelectedChat(_ id: String, item: ChatRecord, into view: SessionDisplay, selection: Int,
                                  generation: UUID, heldRows: HeldRows, focusesComposer: Bool) async {
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
                   view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil && view.queueEditingID == nil { view.restoreDraft(draft); if let queued = draft.queuedEdit { Task { await self.reconcileQueuedEdit(view, queued) } } }
                if view.scrollAnchor == nil { view.scrollAnchor = metadata?.anchor }
                view.selectionMetadataLoaded = true
            }
            view.draftReady = true
            view.recovered = metadata?.recovered ?? []; view.uncertain = !view.recovered.isEmpty
            if focusesComposer { view.composerFocusRequest += 1 }
            // The chat's file can be named while its page is read: its
            // first message writes the journal, and the helper can report
            // a moved one. A page read under the old name is read again
            // under the new one instead of being dropped with nothing in
            // its place.
            let held = view.scrollAnchor
            // Shown earlier this launch, its journal unchanged, and its rows
            // still the newest page as read in, with the reader at the
            // bottom or on one of them: a fresh read returns those same
            // rows, and drew them again. Anything else is read as before:
            // rows paged in since come back as one page from where the
            // reader was, and a place no longer in the chat opens the newest.
            if heldRows.cached, let revision = view.historyRevision, revision.path == item.path, !view.messages.isEmpty,
               view.adoptedPage == view.pageRows, view.newerPage.cursor == nil,
               view.scrollAnchor.map({ anchor in anchor.followsBottom || view.messages.contains { $0.id == anchor.id } }) ?? true,
               await self.history.unchanged(revision) {
                guard current() else { return }
                self.presentHeldHistory(view, identity: heldRows.identity, partialTurnInput: heldRows.partialTurnInput)
                if self.opened.contains(id) { self.refresh(id) }
                return
            }
            // The name can also change while the page's request figures
            // are read, which takes up to `accountingBeforeShowing`: that
            // page was dropped with nothing reading the chat any more, and
            // it stayed on "Preparing…" until it was opened again.
            var source = item, page = try await self.readInitialWindow(source, holding: held)
            for reads in 1...4 {
                guard current(), let now = self.record(id) else { return }
                if now.path == source.path {
                    page.messages = await self.withAccounting(page.messages, view: view, workspaceID: source.workspaceID)
                    guard current() else { return }
                    if self.record(id)?.path == source.path { break }
                }
                guard reads < 4, let renamed = self.record(id) else { return }
                source = renamed; page = try await self.readInitialWindow(source, holding: held)
            }
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
    func selectSide(_ id: String, revealInSidebar: Bool = true) async {
        guard let info = side(id), displays[id] != nil else {
            // A saved child chat that is not the shown side opens in the pane.
            if chats.contains(where: { $0.id == id && $0.parentSessionID != nil }) { await showSide(id, revealInSidebar: revealInSidebar) }
            return
        }
        if revealInSidebar { quietSidebarReveal = [] }
        if selectedID != info.parentID { await select(info.parentID, revealInSidebar: revealInSidebar, focusesComposer: false) }
        guard selectedID == info.parentID, side(id) != nil else { return }
        page = .chats; focusedSessionID = id
        if revealInSidebar, let child = record(id) { revealProjectChat(child) }
        focusComposer(id)
        scheduleAutomaticContext(id)
    }

    /// A row the reader clicked in the sidebar. The chat opens as it would
    /// from anywhere else, a side beside its chat, but nothing in the sidebar
    /// unfolds or expands for it: the row was on screen to be clicked. The
    /// side list the reader folded, a collapsed topic of the chat a side
    /// belongs to and the archive switch all stay as they were.
    func openFromSidebar(_ id: String) async {
        // A chat the filter listed for its messages opens at its match.
        let hit = sidebarSearchHit(id), opening = beginSidebarOpen()
        await openSidebarRow(id)
        await revealSidebarSearchHit(id, hit: hit, opening: opening)
    }
    private func openSidebarRow(_ id: String) async {
        quietSidebarReveal = sidebarLineage(of: id)
        if side(id) != nil { await selectSide(id, revealInSidebar: false); return }
        guard let chat = record(id) else { return }
        if chat.parentSessionID != nil, record(chat.parentSessionID ?? "") != nil, !chat.imported { await showSide(id, revealInSidebar: false) }
        else { await select(id, revealInSidebar: false) }
    }

    /// The reader put the cursor in a pane already on screen: that chat is
    /// focused, and the sidebar unfolds nothing for it.
    func focusPane(_ id: String) {
        quietSidebarReveal.formUnion(sidebarLineage(of: id))
        if let selectedID { quietSidebarReveal.formUnion(sidebarLineage(of: selectedID)) }
        if focusedSessionID != id { focusedSessionID = id }
    }

    /// A chat and every chat above it: its parent, a side's chat, and theirs.
    func sidebarLineage(of id: String) -> Set<String> {
        var lineage: Set<String> = [id]
        var parent = record(id)?.parentSessionID ?? side(id)?.parentID
        while let next = parent, lineage.insert(next).inserted { parent = record(next)?.parentSessionID }
        return lineage
    }
}

/// What a chat's display showed as it was opened again: rows kept on screen
/// while its page is read, and what they were read under, should they turn
/// out to be the chat's rows still.
private struct HeldRows {
    /// The display had rows on screen.
    let cached: Bool
    let identity: (incarnation: String, lineage: String)?
    let partialTurnInput: String?
}
