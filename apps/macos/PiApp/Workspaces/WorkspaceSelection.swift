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
        releasedHelperSessions.remove(id)
        if item.isSubagent { await openSubagentTab(id); return }
        let focusesComposer = focusesComposer && !item.isSubagent
        if revealInSidebar || preserveArchiveSwitch { quietSidebarReveal = [] }
        // A background request is listed on its own page, not the sidebar:
        // the menu bar's running requests and the report open it there.
        if item.isBackgroundTask { openBackgroundRequests(selecting: id); return }
        if reselectOpenChat(id, item: item, revealInSidebar: revealInSidebar) {
            do { try await attachManagedSubagent(item) }
            catch is CancellationError { }
            catch { displays[id]?.notice = error.localizedDescription }
            return
        }
        let (view, selection, heldRows) = prepareSelection(id, item: item, revealInSidebar: revealInSidebar, preserveArchiveSwitch: preserveArchiveSwitch,
                                                           focusesComposer: focusesComposer)
        restoreShownSide(of: id, selection: selection, reopensSide: reopensSide)
        releaseUnreadDisplays(keeping: id)
        let generation = view.presentation.readGeneration, navigation = transcriptNavigation(id)
        PerformanceProbe.shared.observe("selectionLoadingFeedbackMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            await self.loadSelectedChat(id, item: item, into: view, selection: selection, generation: generation, heldRows: heldRows,
                                        focusesComposer: focusesComposer, navigation: navigation)
        }
        navigationTask = task; view.presentation.navigation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func readerPaneVisibilityChanged() {
        if let id = selectedID, let side = sides[id], !transcriptShows(side.id) {
            displays[side.id]?.retireInitialPresentation()
        }
        resumeVisibleReaders()
    }
    /// Retirement only rejects publication. Still-wanted initial content must
    /// be hydrated under a fresh intent once its reader is visible again.
    /// Defer to the next actor turn so selection/pane mutations have settled.
    func resumeVisibleReaders() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            for view in self.displays.values where self.transcriptShows(view.id) && view.needsVisibleHistoryLoad {
                // Runtime retirement keeps a reload's explicit destination;
                // ordinary selection still resumes from its held position.
                guard let reload = view.presentation.reload else { continue }
                guard reload.navigation.isCurrent(in: self) else {
                    view.presentation.reload = nil
                    continue
                }
                switch reload.target {
                case .latest: self.reloadHistory(view.id, navigation: reload.navigation)
                case .message(let id): self.reloadHistory(view.id, around: id, navigation: reload.navigation)
                }
            }
            for tab in self.tabs.allTabs.compactMap({ $0 as? SubagentTab }) where self.subagentTabIsShown(tab.key) {
                tab.ensureLoaded()
                self.displays[tab.key]?.findHost?.resumeFindNavigation()
            }
            guard self.page == .chats, let id = self.selectedID else { return }
            self.displays[id]?.findHost?.resumeFindNavigation()
            if let side = self.sides[id], self.transcriptShows(side.id) { self.displays[side.id]?.findHost?.resumeFindNavigation() }
            if let view = self.displays[id], view.needsVisibleHistoryLoad,
               let item = self.record(id), !item.isSubagent {
                let held = view.beginHistoryPresentation(), generation = view.presentation.readGeneration, selection = self.selectionRevision
                let navigation = self.transcriptNavigation(id)
                let task = Task { [weak self, weak view] in
                    guard let self, let view else { return }
                    await self.loadSelectedChat(id, item: item, into: view, selection: selection,
                        generation: generation, heldRows: held, focusesComposer: false, navigation: navigation)
                }
                view.presentation.navigation = task
            }
            if let side = self.sides[id], !side.pending, self.transcriptShows(side.id),
               let child = self.record(side.id), let view = self.displays[side.id],
               view.needsVisibleHistoryLoad {
                view.beginHistoryPresentation()
                let generation = view.presentation.readGeneration, navigation = self.transcriptNavigation(child.id)
                Task { [weak self, weak view] in
                    guard let self, let view else { return }
                    guard navigation.isCurrent(in: self), self.transcriptShows(child.id), view.presentation.readGeneration == generation else {
                        view.finishHistoryPresentation(generation); self.resumeVisibleReaders(); return
                    }
                    await self.loadSideDisplay(child, view: view)
                }
            }
        }
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
            if !item.isSubagent, selected.presentation.readyAt != nil { scheduleAutomaticContext(id) }
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
        let held = view.beginHistoryPresentation()
        view.contextSelectionReady = false; view.browsingHistory = true
        view.draftReady = false
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
        return (view, selection, held)
    }
    /// The side shown beside this chat comes back with it: the one open in
    /// this launch, or else the saved side it showed when the app last
    /// closed (`WorkspaceLaunchSelection.swift`).
    private func restoreShownSide(of id: String, selection: Int, reopensSide: Bool) {
        var shownSide: (child: ChatRecord, view: SessionDisplay)?
        if let info = sides[id], let sideView = displays[info.id], let child = record(info.id) {
            sideView.beginHistoryPresentation(); sideView.browsingHistory = true
            sideView.draftReady = info.pending
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
            let sideGeneration = sideView.presentation.readGeneration
            Task { [weak self, weak sideView] in
                guard let self, let sideView, self.selectedID == id, self.sides[id]?.id == child.id,
                      self.selectionRevision == selection, sideView.presentation.readGeneration == sideGeneration else { return }
                await self.loadSideDisplay(child, view: sideView)
            }
        }
    }
    /// The displays of chats nobody is reading are let go of, least recently
    /// used first, until no more than eight are kept.
    func releaseUnreadDisplays(keeping id: String) {
        // A new chat that was never sent has nothing written anywhere (see
        // `materializeChat`): its display is the only place its draft lives,
        // so it is not let go of while it holds one.
        // Uncommitted typing and failed conflict copies still own this display.
        // Imports belong to this exact composer; keep it until its images
        // have arrived, even off screen.
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading && other.submittingCommands.isEmpty
            && !other.hasUnsavedDraft && !other.anchorWritePending && other.anchorWrite == nil && draftWrites.tasks[other.id] == nil && subagentTab(other.id) == nil && other.imageImports == 0 && other.id != record(id)?.delegation?.budgetOwnerSessionID
            && !(pendingChatIDs.contains(other.id) && !isPendingEmpty(other.id)) && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            other.presentation.cancel(); displays.removeValue(forKey: other.id)
            releaseHelperSession(other.id)
        }
    }
    /// Reads the opened chat's saved draft and place, then its page, and shows
    /// it: the rows it held when they are still its newest, else the page read.
    /// It stops wherever the reader has moved on.
    func loadSelectedChat(_ id: String, item: ChatRecord, into view: SessionDisplay, selection: Int,
                                  generation: UUID, heldRows: HeldRows, focusesComposer: Bool, reader: HostedReaderToken? = nil,
                                  navigation: TranscriptNavigationToken? = nil) async {
        let navigation = navigation ?? transcriptNavigation(id)
        // However this ends, nothing is reading the chat any more.
        defer { view.finishHistoryPresentation(generation); resumeVisibleReaders() }
        @MainActor func current() -> Bool {
            !Task.isCancelled && navigation.isCurrent(in: self) && (reader.map { $0.isCurrent && self.subagentTab(id) === $0.reader } ?? (self.selectionRevision == selection && self.selectedID == id)) &&
                self.displays[id] === view && view.presentation.readGeneration == generation
        }
        do {
            await readInheritedSubagents(item, current: current)
            guard current() else { return }
            try await attachManagedSubagent(item, current: current)
            guard current() else { return }
            guard try await reconcileSubmissionDraft(item, view: view, current: current) else { return }
            let owner = item.delegation.flatMap { record($0.budgetOwnerSessionID) } ?? item
            view.childSummaries = subagentSummaries.filter { $0.value.link.budgetOwnerSessionID == item.id }
            if item.isSubagent || !view.childSummaries.isEmpty, let path = owner.path,
               let state = try? await history.agentCoordination(path: URL(fileURLWithPath: path), ownerID: owner.id) {
                guard current() else { return }; applyAgentCoordination(state, parentID: owner.id)
            }
            if let link = item.delegation {
                view.isManagedSubagent = true; view.subagentStatus = subagentSummaries[id]?.status
                view.subagentTurn = subagentSummaries[id]?.turn
                if let issue = item.delegationIssue { view.notice = issue }
                if let parent = record(link.budgetOwnerSessionID), parent.workspaceID == item.workspaceID, let path = parent.path,
                   let plan = try? await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: parent.id, childID: item.id).first,
                   plan.header.link == link {
                    guard current() else { return }; view.delegatedTask = plan.task
                }
            }
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
        } catch is CancellationError {
            if current() { view.historyState = .failed("History reading was interrupted. Try loading it again.") }
        }
        catch {
            guard current() else { return }
            view.historyState = .failed(error.localizedDescription); view.refreshingCachedRows = false
            view.notice = error.localizedDescription
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
        guard let target = id ?? focusedSessionID ?? selectedID, record(target)?.isSubagent != true else { return }
        displays[target]?.composerFocusRequest += 1
    }
    func selectSide(_ id: String, revealInSidebar: Bool = true) async {
        guard let info = side(id), displays[id] != nil else {
            // A saved child chat that is not the shown side opens in the pane.
            if chats.contains(where: { $0.id == id && !$0.isSubagent && $0.parentSessionID != nil }) { await showSide(id, revealInSidebar: revealInSidebar) }
            return
        }
        if revealInSidebar { quietSidebarReveal = [] }
        tabs.showSide()
        let paneIntent = tabs.navigationRevision, selection = selectionRevision, changesParent = selectedID != info.parentID
        let revision = messageNavigationRevision + (changesParent ? 1 + (page == .chats ? 0 : 1) : 0)
        if selectedID != info.parentID { await passingThrough(info.parentID) { await select(info.parentID, revealInSidebar: revealInSidebar, focusesComposer: false) } }
        guard !Task.isCancelled, messageNavigationRevision == revision, tabs.navigationRevision == paneIntent, selectionRevision == selection + (changesParent ? 1 : 0), selectedID == info.parentID, side(id) != nil else { return }
        page = .chats; focusedSessionID = id
        if revealInSidebar, let child = record(id) { revealProjectChat(child) }
        focusComposer(id)
        scheduleAutomaticContext(id)
        if let view = displays[id], let child = record(id), !info.pending,
           view.historyState == .dormant || (view.historyState == .loading && view.presentation.navigation == nil) {
            view.beginHistoryPresentation(); view.browsingHistory = true
            await loadSideDisplay(child, view: view)
        }
    }

    /// A row the reader clicked in the sidebar. The chat opens as it would
    /// from anywhere else, a side beside its chat, but nothing in the sidebar
    /// unfolds or expands for it: the row was on screen to be clicked. The
    /// side list the reader folded, a collapsed topic of the chat a side
    /// belongs to and the archive switch all stay as they were.
    func openFromSidebar(_ id: String) async {
        // A chat the filter listed for its messages opens at its match.
        let hit = sidebarSearchHit(id), opening = beginSidebarOpen()
        if record(id)?.isSubagent == true {
            let reader = beginSubagentOpening(id)
            defer { finishSubagentOpening(reader) }
            guard await openSubagentTab(id, opening: reader) != nil, reader.isCurrent else { return }
            await revealSidebarSearchHit(id, hit: hit, opening: opening, reader: reader)
            return
        }
        await openSidebarRow(id)
        await revealSidebarSearchHit(id, hit: hit, opening: opening)
    }
    private func openSidebarRow(_ id: String) async {
        quietSidebarReveal = sidebarLineage(of: id)
        if side(id) != nil { await selectSide(id, revealInSidebar: false); return }
        guard let chat = record(id) else { return }
        if !chat.isSubagent, chat.parentSessionID != nil, record(chat.parentSessionID ?? "") != nil, !chat.imported { await showSide(id, revealInSidebar: false) }
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
struct HeldRows {
    /// The display had rows on screen.
    let cached: Bool
    let identity: (incarnation: String, lineage: String)?
    let partialTurnInput: String?
}
