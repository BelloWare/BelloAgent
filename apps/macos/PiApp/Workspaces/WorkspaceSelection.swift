import Foundation

// Which chat is open, and everything that has to be true by the time it is
// on screen: its display loaded or built, its page fetched, its composer
// focused, and the displays of chats nobody is reading let go of.

extension WorkspaceModel {
    func select(_ id: String, revealInSidebar: Bool = true) async {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        PerformanceProbe.shared.observe("sessionSelectionCalls", milliseconds: 1)
        selectionRevision += 1
        let selection = selectionRevision
        if let previous = selectedID, previous != id, isPendingEmpty(previous) { discardPendingChat(previous) }
        if revealInSidebar { revealProjectChat(item) } else { showArchivedSessions = item.isArchived }
        PerformanceProbe.shared.beginSelection(id, hasHistory: item.path != nil)
        selectedID = id; profileChoice = item.profileID
        clearFailureMark(sessionID: id)
        // A chat outside any project never becomes the target for new chats.
        if item.workspaceID != WorkspaceRecord.scratchID { selectedWorkspaceID = item.workspaceID }
        focusedSessionID = id; page = .chats
        let view = displays[id] ?? SessionDisplay(id: id); view.used = Date(); displays[id] = view; selected = view
        func current() -> Bool {
            !Task.isCancelled && selectionRevision == selection && selectedID == id && displays[id] === view && record(id)?.path == item.path
        }
        view.contextSelectionReady = false
        var contextReady = false
        defer {
            if current() {
                view.contextSelectionReady = contextReady
                if contextReady { scheduleAutomaticContext(id) }
            }
        }
        if let sideID = sides[id]?.id { refresh(sideID) }
        // Drop hidden, idle display pages. Persistent history and drafts are loaded on demand.
        for other in displays.values.sorted(by: { $0.used < $1.used }) where displays.count > 8 && other.id != id && !other.hasWork && !other.loading && !sides.values.contains(where: { $0.id == other.id || $0.parentID == other.id }) {
            displays.removeValue(forKey: other.id)
        }
        do {
            if !opened.contains(id) {
                let mode = try await capturePreference(sessionID: id).mode
                guard current() else { return }
                view.captureMode = mode; view.captureAvailable = false
            }
            // One read for the draft, the reading position and any command
            // whose outcome is unknown: they are independent, and asking for
            // them one at a time put three suspensions between the click and
            // the chat's own history.
            let wantsMetadata = !view.selectionMetadataLoaded
            let metadata = try await store?.selectionMetadata(id: id, draft: wantsMetadata,
                                                              anchor: wantsMetadata && view.scrollAnchor == nil)
            guard current() else { return }
            if wantsMetadata {
                if let draft = metadata?.draft, view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil { view.restoreDraft(draft) }
                if view.scrollAnchor == nil { view.scrollAnchor = metadata?.anchor }
                view.selectionMetadataLoaded = true
            }
            view.recovered = metadata?.recovered ?? []
            view.uncertain = !view.recovered.isEmpty
            // The draft is in the composer, so the caret belongs there now.
            // Waiting for the journal meant a long chat could not be typed
            // into until its transcript had finished loading.
            view.composerFocusRequest += 1
            // An unloaded chat shows its newest page; earlier pages load as the
            // reader scrolls up. A saved reading position is honoured when it is
            // inside that page, otherwise the chat opens at its latest message.
            if let path = item.path, !opened.contains(id) {
                let historySequence = view.lastSequence
                let page = try await history.readIfChanged(path: path, since: view.historyRevision)
                guard current() else { return }
                if let page, !opened.contains(id), view.lastSequence == historySequence {
                    if page.notice == nil, let count = page.assistantMessageCount {
                        observeAssistantOutputs(sessionID: id, snapshot: ["assistantMessageCount": .number(Double(count)), "latestAssistantMessageId": page.latestAssistantMessageID.map(WireValue.string) ?? .null])
                    }
                    view.browsingHistory = false
                    if let anchor = view.scrollAnchor, !anchor.followsBottom, !page.messages.contains(where: { $0.id == anchor.id }) { view.scrollAnchor = nil }
                    view.pageStartEnsured = false
                    view.messages = page.messages; view.before = page.before; view.historyRevision = page.revision
                    view.notice = page.notice ?? page.limitNotice ?? (item.imported ? "Imported original · Read-only. Continue creates a separate managed copy." : "Saved history · Host unloaded")
                    if page.notice == nil { view.observeRetainedFailure(page.failureMessage) }
                    await ensurePageStartsAtTurn(sessionID: id, refreshAfterRepair: false)
                    guard current() else { return }
                }
            }
            if let profile = profiles.first(where: { $0.id == item.profileID }), profile.api != LiteLLMConfiguration.supportedAPI {
                view.notice = LiteLLMConfiguration.unsupportedAPIMessage
            }
            contextReady = true
            view.contextSelectionReady = true
            scheduleAutomaticContext(id)
            if opened.contains(id) { refresh(id) }
            else if !view.recovered.isEmpty {
                view.uncertain = true; view.notice = "Outcome uncertain for a previous command. Review the saved history before sending again."; if view.state != "error" { view.state = "interrupted" }
            }
            // Keep the awaited completion contract, but navigation and typing
            // need not wait for a potentially large retained-accounting read.
            await refreshAccounting(view, workspaceID: item.workspaceID)
        } catch {
            guard current() else { return }
            // Claiming that the original files were preserved is false when the
            // journal is the thing that is missing.
            if case StoreError.missingJournal = error { view.notice = error.localizedDescription }
            else { view.notice = "History could not be read. Original files were preserved. \(error.localizedDescription)" }
        }
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
