import AppKit

// Side panels are durable child chats. A recovery intent precedes journal
// publication so an interrupted acknowledgement cannot orphan saved history.
struct SideRecord: Identifiable, Equatable {
    var id: String; var parentID: String; var workspaceID: String; var profileID: String; var title: String
    var kept = false; var keeping = false; var keepRequested = false
    /// Open on screen only; the helper session and journal appear with its first message.
    var pending = false
    var boundary: [String: WireValue] = [:]
    /// Model and reasoning overrides inherited from the parent when the side opens.
    var model: String? = nil
    var thinkingLevel: String? = nil
    var contextWindow: Int? = nil
    var maxOutputTokens: Int? = nil
    var modelOutputLimit: Int? = nil
    var outputBudgetVersion: Int? = 1
    var topicID: String?
    /// Legacy value retained for decoding only; sides follow the main budget.
    var costLimit: CostLimit? = nil
    /// What follows its chat's title in a new side's, until its first
    /// message names it.
    static let titleSuffix = " — side"
    var chat: ChatRecord { .init(id: id, workspaceID: workspaceID, title: title, path: nil, profileID: profileID, toolMode: ChatRecord.readOnlyTools, model: model, thinkingLevel: thinkingLevel, contextWindow: contextWindow, maxOutputTokens: maxOutputTokens, modelOutputLimit: modelOutputLimit, outputBudgetVersion: outputBudgetVersion, topicID: topicID, parentSessionID: parentID, costLimit: costLimit) }
}
struct SideKeepIntent: Codable, Sendable {
    /// Attachment discovery only: never listed for automatic registration.
    static let retainedKind = "side-keep-retained"
    var chat: ChatRecord
}

/// The exact pending copy consumed by a successful registration. A delayed
/// caller can acknowledge it without replaying chat/draft writes.
struct SideKeepRegistration: Codable, Sendable {
    static let kind = "side-keep-registration"
    var expected: ChatRecord
    var path: String?
}

enum SideKeepState: Sendable {
    case pending(SideKeepIntent)
    case registered(chat: ChatRecord, expected: ChatRecord)
    case missing
}

extension WorkspaceModel {
    /// Both are asked for once per sidebar row, and the sidebar redraws on every
    /// workspace change: a linear scan here is a scan of every chat per row.
    func side(_ id: String) -> SideRecord? { sidebarIndex.side(id, in: sides) }
    func record(_ id: String) -> ChatRecord? { chatRecord(id) ?? side(id)?.chat }
    func isEphemeral(_ id: String) -> Bool { side(id).map { !$0.kept } ?? false }
    var resourceTarget: SessionDisplay? { displays[resourceTargetSessionID ?? selectedID ?? ""] }
    /// The Session Inspector at the session's latest request: 🐞, ⌥⌘I and the chat's ⋯ menu.
    func inspect(_ id: String) { openInspector(session: id, focus: .latestRequest) }
    /// Shows or hides the integrated terminal under the selected chat.
    func toggleTerminal() {
        guard selectedID != nil else { return }
        terminalVisible.toggle()
        if !terminalVisible, let id = focusedSessionID ?? selectedID { displays[id]?.composerFocusRequest += 1 }
    }
    func inspectResources(_ id: String?) { resourceTargetSessionID = id; showResources = true }
    func updateHostActivity(workspaceID: String) {
        hosts[workspaceID]?.isBusy = sides.values.contains { $0.workspaceID == workspaceID && !$0.kept && !$0.pending } || displays.values.contains { ($0.hasWork || $0.loading) && record($0.id)?.workspaceID == workspaceID }
    }
    func canOpenSide(_ id: String) -> Bool {
        guard let parent = record(id), !parent.isSubagent, orphanedSideRefusal(id) == nil else { return false }
        return !parent.imported && parent.connectionTest != true && parent.workspaceID != WorkspaceRecord.scratchID
    }
    /// A saved side whose chat was deleted stays in the sidebar as a chat of
    /// its own, and opens no side of its own (the owner's choice, 0.1.116).
    /// A saved side is known by its journal, `side_‹id›.jsonl`: a chat forked
    /// from a reply also names the chat it came from, and keeps its sides.
    func orphanedSideRefusal(_ id: String) -> String? {
        guard let chat = record(id), let parentID = chat.parentSessionID, record(parentID) == nil,
              let path = chat.path, URL(fileURLWithPath: path).lastPathComponent.hasPrefix("side_") else { return nil }
        return "The chat this side was opened from was deleted, so it can't open sides of its own."
    }
    func canQuoteReply(_ id: String) -> Bool {
        guard !installPreparing, canOpenSide(id), side(id) == nil, let parent = record(id),
              !parent.isArchived, !parent.isBackgroundTask, workspace(for: parent.workspaceID) != nil else { return false }
        return true
    }
    /// Selection is quoted as unsent prose, never interpreted as a slash/skill
    /// command. Reuse an unfinished side draft without overwriting it; a saved
    /// side keeps its history while a new child opens beside the parent.
    func openQuotedSide(parentID: String, quote: TranscriptQuote) {
        guard selectedID == parentID, canQuoteReply(parentID), !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existing = sides[parentID]
        if let existing, existing.keeping || (!existing.pending && !existing.kept) || displays[existing.id]?.loading == true {
            error = "Wait for the current side to finish opening before quoting another response."; return
        }
        let existingDraft = existing.flatMap { $0.pending ? displays[$0.id]?.draft : nil } ?? ""
        let quoted = quote.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let draft = existingDraft + (existingDraft.isEmpty ? "" : "\n\n") + quoted + "\n\n"
        guard draft.utf8.count <= SubmissionLimits.messageBytes else { error = "The quoted draft exceeds 256 KiB. Select a shorter passage."; return }
        openSide(parentID: parentID)
        guard let info = sides[parentID], info.pending, let view = displays[info.id] else { return }
        view.draft = draft; view.directCommand = false; view.completionVisible = false; view.completionToken = nil
        draftChanged(view)
        focusedSessionID = info.id; view.composerFocusRequest += 1
    }
    func openSide(parentID: String? = nil, question: String = "") {
        guard !installPreparing, let parentID = parentID ?? selectedID, let parent = record(parentID), !parent.imported else { error = "Continue an imported original as a separate chat before opening a side."; return }
        // A new side opens beside its chat, which is on screen: the sidebar
        // unfolds nothing for it. A side list the reader folded stays folded,
        // the new side listed under the fold (owner, 2026-10-12).
        quietSidebarReveal = sidebarLineage(of: parentID)
        if let refusal = orphanedSideRefusal(parentID) { error = refusal; return }
        guard canOpenSide(parentID) else { error = "Connection-test chats keep tools disabled and cannot open side chats."; return }
        guard side(parentID) == nil else { error = "Close this side panel before opening a side from its saved chat."; return }
        // Another side can open while one is shown: the shown side stays a
        // saved child chat in the sidebar and comes back on click. Only a side
        // that is still being published must finish first.
        if let existing = sides[parentID], existing.pending {
            // The empty side is already waiting for its first message.
            quietSidebarReveal.insert(existing.id)
            focusedSessionID = existing.id; displays[existing.id]?.composerFocusRequest += 1
            if !question.isEmpty { displays[existing.id]?.draft = question; send(sessionID: existing.id) }
            return
        }
        if let existing = sides[parentID], !existing.kept || existing.keeping {
            quietSidebarReveal.insert(existing.id)
            focusedSessionID = existing.id
            error = "Wait for the current side to finish opening before starting another."; return
        }
        let id = UUID().uuidString, view = SessionDisplay(id: id)
        quietSidebarReveal.insert(id)
        view.historyState = .empty; view.selectionMetadataLoaded = true
        var info = SideRecord(id: id, parentID: parentID, workspaceID: parent.workspaceID, profileID: parent.profileID, title: parent.title + SideRecord.titleSuffix, model: parent.model, thinkingLevel: parent.thinkingLevel, contextWindow: parent.contextWindow, maxOutputTokens: parent.maxOutputTokens, modelOutputLimit: parent.modelOutputLimit, outputBudgetVersion: parent.outputBudgetVersion)
        info.topicID = effectiveTopicID(for: parent)
        if question.isEmpty {
            // Nothing is created until the first message: no intent, journal or helper session.
            info.pending = true; sides[parentID] = info
            displays[id] = view
            if selectedID == parentID { focusedSessionID = id }
            view.composerFocusRequest += 1
            return
        }
        sides[parentID] = info
        displays[id] = view; view.loading = true; view.draft = question
        Task {
            do {
                try await publishPendingSide(info, view: view)
                // This flag was set here, for the side's creation; the send
                // below sets its own.
                view.loading = false
                view.draft = question; send(sessionID: id)
            } catch {
                view.loading = false; view.notice = error.localizedDescription
                // Unwind the in-memory side for every failure, not only an
                // explicit rejection. A side left half-open can be neither
                // closed nor kept, and while it exists the app refuses to quit
                // and blocks every update. The saved side-keep intent still
                // lets a side the host did publish be recovered on restart.
                // Only this side: a lost host may already have put another
                // in its place holding what was typed here.
                let replaced = sides[parentID].map { $0.id != id } ?? false
                if !replaced { sides.removeValue(forKey: parentID) }
                displays.removeValue(forKey: id)
                if !replaced, let original = displays[parentID] {
                    if let recovery = draftWrites.recoveries[parentID] { await recovery.value }
                    original.draft += (original.draft.isEmpty ? "" : "\n\n") + question; original.directCommand = false; draftChanged(original)
                }
                self.error = error.localizedDescription; updateHostActivity(workspaceID: parent.workspaceID)
            }
        }
    }
    /// Creates the side on the helper: the recovery intent and draft, the
    /// parent's context snapshot as a durable child session, and its capture
    /// preference. Called when a side with a question opens, and when a
    /// pending side sends its first message.
    /// `draft` is what the kept side starts with on disk: the message being
    /// sent, whose composer has already emptied (`send`), else what the
    /// composer holds.
    func publishPendingSide(_ info: SideRecord, view: SessionDisplay, draft: DraftRecord? = nil) async throws {
        guard let store else { throw StoreError.unavailable }
        guard let parent = record(info.parentID) else { throw HostError.failure("The parent chat is no longer available.") }
        let id = info.id, parentID = info.parentID
        // A send that publishes the side holds this flag for the whole
        // submission. Clearing it here, with the first message still on its
        // way, let Send submit that message a second time.
        let wasLoading = view.loading
        view.loading = true; defer { if !wasLoading { view.loading = false } }
        var saved = info.chat
        saved.topicID = effectiveTopicID(for: parent)
        saved.path = root.appendingPathComponent("Workspaces/\(info.workspaceID)/Sessions/side_\(id).jsonl").path
        try await store.put(SideKeepIntent(chat: saved), kind: "side-keep", id: id)
        try await store.put(draft ?? DraftRecord(id: id, text: view.draft), kind: "draft", id: id)
        let host = try await open(parent); host.isBusy = true
        let result: [String: WireValue]
        var written = false
        do {
            guard sides[parentID]?.id == id, displays[id] === view else { throw HostError.failure("Side identity changed; reopen this project before creating another side.") }
            sides[parentID]?.pending = false
            sessionProfileRevisions[id] = sessionProfileRevisions[parentID] ?? profiles.first(where: { $0.id == info.profileID }).map { (host.connectionID, $0.revision) }
            // Sides share the main chat’s budget.
            result = try await host.request("side.open", sessionID: parentID, params: ["sideSessionId": .string(id)]).object ?? [:]
            written = true
            guard result["sessionId"]?.string == id, sides[parentID]?.id == id else { throw HostError.failure("Side identity changed; reopen this project before creating another side.") }
            try await registerKeptSide(id: id, path: result["path"]?.string)
        } catch {
            // Nothing was kept, so the side is still the draft it was: it can
            // be sent again or closed, and its text is where it was. Left
            // half-open, nothing could close, keep or replace it, and while it
            // existed the app refused to quit and blocked every update. A side
            // the helper did write is still recovered from its intent; one it
            // refused leaves nothing behind, since a draft side's text is
            // never stored.
            if sides[parentID]?.id == id, sides[parentID]?.kept != true { sides[parentID]?.pending = true }
            if !written {
                try? await store.remove(kind: "side-keep", id: id)
                try? await store.remove(kind: "draft", id: id)
            }
            throw error
        }
        let preference = try await capturePreference(sessionID: id)
        _ = try await host.request("debug.mode", sessionID: id, params: ["mode": .string(preference.mode)])
        view.captureMode = preference.mode
        let initial = try await host.request("session.status", sessionID: id)
        observeAssistantOutputs(sessionID: id, snapshot: initial.object ?? [:])
        observeSessionCompletion(sessionID: id, snapshot: initial.object ?? [:], baseline: true)
        if sides[parentID]?.id == id { sides[parentID]?.boundary = result["side"]?.object ?? [:] }
        opened.insert(id); view.captureAvailable = true
        try await reconcileSessionProfile(saved, host: host)
        if selectedID == parentID, sides[parentID]?.id == id { focusedSessionID = id }
        updateHostActivity(workspaceID: info.workspaceID); refresh(id)
    }
    /// Drops a side that never sent a message, moving its whole unsent draft
    /// (text, images and skills) into the parent (`moveSideDraft`). The side
    /// goes only once the parent holds the draft; if the parent's saved draft
    /// cannot be read or written, the side stays as it was. True when gone.
    @discardableResult
    func discardPendingSide(_ info: SideRecord) async -> Bool {
        guard info.pending, sides[info.parentID]?.id == info.id else { return sides[info.parentID]?.id != info.id }
        guard displays[info.id]?.loading != true, (displays[info.id]?.imageImports ?? 0) == 0 else {
            error = "Wait for the current side to finish opening or adding images before switching."; return false
        }
        if discardPendingSideNow(info) { return true }
        let view = displays[info.id]
        view?.loading = true
        do { try await moveSideDraft(info) }
        catch {
            view?.loading = false
            self.error = "The side's draft could not be moved to its chat, so the side stays open. \(error.localizedDescription)"
            return false
        }
        view?.loading = false
        // An image can start arriving while the parent's stored draft is read.
        guard (view?.imageImports ?? 0) == 0 else { return false }
        if sides[info.parentID]?.id == info.id { removePendingSide(info) }
        return true
    }
    /// The same, at once, when nothing has to be read first: true when done.
    func discardPendingSideNow(_ info: SideRecord) -> Bool {
        guard info.pending, sides[info.parentID]?.id == info.id else { return sides[info.parentID]?.id != info.id }
        // A draft on its way to the parent's saved draft is not done yet.
        guard displays[info.id]?.loading != true, (displays[info.id]?.imageImports ?? 0) == 0, sideDraftTransfers[info.id] == nil, moveSideDraftHere(info) else { return false }
        removePendingSide(info); return true
    }
    private func removePendingSide(_ info: SideRecord) {
        sides.removeValue(forKey: info.parentID); displays.removeValue(forKey: info.id)
        forgetOpened(info.id)
        if focusedSessionID == info.id { focusedSessionID = info.parentID }
        focusComposer(info.parentID)
    }
    /// The one way an unsaved side's draft reaches its parent (closing or
    /// replacing it, quit, update, a lost host): its text after the parent's,
    /// its images and skills after the parent's (`DraftRecord.merging`). Into
    /// the parent's draft as loaded here (`absorb`); else into its saved
    /// draft, read first: one that cannot be read is never taken for empty.
    /// The side's composer is emptied as the draft leaves and given back if
    /// it cannot arrive; what is typed meanwhile follows on the next pass,
    /// until nothing is left.
    func moveSideDraft(_ info: SideRecord, from shown: SessionDisplay? = nil) async throws {
        guard let side = shown ?? displays[info.id] else { return }
        while true {
            if let recovery = draftWrites.recoveries[info.parentID] { await recovery.value }
            // One move of a side's draft at a time: another waits, then sees
            // what that one left in the side (all of it, if it failed).
            while let running = sideDraftTransfers[info.id] { await running.task.value }
            if moveSideDraftHere(info, from: side) { return }
            guard let store else { throw StoreError.unavailable }
            let moving = Self.unsentDraft(of: side, to: info.parentID)
            // Each part goes back to its own place if the move fails.
            let composerBefore = DraftRecord(id: side.id, text: side.draft, attachments: side.attachments, skills: side.skills, submissionReviews: side.submissionReviews.isEmpty ? nil : side.submissionReviews)
            let parkedBefore = side.queueEditingID != nil ? side.draftBeforeQueueEdit : nil
            Self.consumeUnsentDraft(of: side)
            let (done, finish) = AsyncStream<Never>.makeStream(), token = UUID()
            sideDraftTransfers[info.id] = (token, Task { for await _ in done {} })
            defer { finish.finish(); if sideDraftTransfers[info.id]?.token == token { sideDraftTransfers.removeValue(forKey: info.id) } }
            do {
                let saved = try await store.get(DraftRecord.self, kind: "draft", id: info.parentID) ?? DraftRecord(id: info.parentID, text: "")
                if let recovery = draftWrites.recoveries[info.parentID] { await recovery.value }
                // The parent's draft may have loaded meanwhile: it takes the
                // draft itself, and the saved one follows from it.
                if let parent = displays[info.parentID], parent.selectionMetadataLoaded || pendingChatIDs.contains(parent.id) { absorb(moving, into: parent); continue }
                let merged = saved.receiving(moving)
                try await store.put(merged, kind: "draft", id: info.parentID)
                if let recovery = draftWrites.recoveries[info.parentID] { await recovery.value }
                // Or loaded the copy from before this write: given the draft
                // too, unless what it loaded already holds all of it.
                if let parent = displays[info.parentID], parent.selectionMetadataLoaded, !Self.parked(in: parent).holds(merged.displaced) { absorb(moving, into: parent) }
            } catch {
                // Back where each part was, with what was added meanwhile after it.
                let composer = composerBefore.merging(DraftRecord(id: side.id, text: side.draft, attachments: side.attachments, skills: side.skills, submissionReviews: side.submissionReviews.isEmpty ? nil : side.submissionReviews))
                side.draft = composer.text; side.attachments = composer.attachments ?? []; side.skills = composer.skills ?? []; side.submissionReviews = composer.submissionReviews ?? []
                if let parkedBefore, side.queueEditingID != nil {
                    side.draftBeforeQueueEdit = parkedBefore.merging(side.draftBeforeQueueEdit ?? DraftRecord(id: side.id, text: ""))
                }
                throw error
            }
        }
    }
    /// The draft `parent` keeps outside any edit under way.
    private static func parked(in parent: SessionDisplay) -> DraftRecord {
        if parent.queueEditingID != nil, let before = parent.draftBeforeQueueEdit { return before }
        if parent.editingMessageID != nil, let before = parent.draftBeforeEdit { return before }
        return DraftRecord(id: parent.id, text: parent.draft, attachments: parent.attachments, skills: parent.skills, submissionReviews: parent.submissionReviews.isEmpty ? nil : parent.submissionReviews)
    }
    /// `moveSideDraft` without suspending: true when there is nothing (left)
    /// to move or the parent's loaded draft took it; false when only its
    /// saved draft can.
    func moveSideDraftHere(_ info: SideRecord, from shown: SessionDisplay? = nil) -> Bool {
        guard draftWrites.recoveries[info.parentID] == nil else { return false }
        guard let side = shown ?? displays[info.id] else { return true }
        let moving = Self.unsentDraft(of: side, to: info.parentID)
        guard !moving.isBlank else { return true }
        guard let parent = displays[info.parentID], parent.selectionMetadataLoaded || pendingChatIDs.contains(parent.id) else { return false }
        absorb(moving, into: parent)
        Self.consumeUnsentDraft(of: side)
        return true
    }
    /// Empties what `unsentDraft` took: the composer and, while a queued
    /// message was being rewritten, the draft set aside for it.
    static func consumeUnsentDraft(of side: SessionDisplay) {
        side.draft = ""; side.attachments = []; side.skills = []; side.submissionReviews = []
        if side.queueEditingID != nil, let before = side.draftBeforeQueueEdit { side.draftBeforeQueueEdit = DraftRecord(id: before.id, text: "") }
    }
    /// `moving` added to the draft `parent` saves: the one a queued or an
    /// earlier message's edit displaced, while it is being edited, so ending
    /// the edit brings it back with the side's; else the composer's.
    private func absorb(_ moving: DraftRecord, into parent: SessionDisplay) {
        if parent.queueEditingID != nil, let before = parent.draftBeforeQueueEdit { parent.draftBeforeQueueEdit = before.merging(moving) }
        else if parent.editingMessageID != nil, let before = parent.draftBeforeEdit { parent.draftBeforeEdit = before.merging(moving) }
        else {
            let merged = Self.parked(in: parent).merging(moving)
            parent.draft = merged.text; parent.attachments = merged.attachments ?? []; parent.skills = merged.skills ?? []; parent.submissionReviews = merged.submissionReviews ?? []
            parent.directCommand = false
        }
        draftChanged(parent)
    }
    static func unsentDraft(of side: SessionDisplay, to parentID: String) -> DraftRecord {
        let composer = DraftRecord(id: parentID, text: side.draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: side.attachments, skills: side.skills, submissionReviews: side.submissionReviews.isEmpty ? nil : side.submissionReviews)
        // Rewriting a queued message, the composer holds the rewrite and the
        // side's own draft is set aside: both go, the rewrite after the
        // draft unless it is the message unchanged.
        guard side.queueEditingID != nil, let before = side.draftBeforeQueueEdit else { return composer }
        var parked = DraftRecord(id: parentID, text: before.text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: before.attachments, skills: before.skills, submissionReviews: before.submissionReviews)
        let rewrite = composer.text
        if !rewrite.isEmpty, rewrite != side.queueEditOriginal.trimmingCharacters(in: .whitespacesAndNewlines) {
            parked = parked.merging(DraftRecord(id: parentID, text: rewrite))
        }
        return parked
    }
    /// Shows a saved child chat in the side pane of its parent, replacing the
    /// side shown there. The replaced side keeps its display and any running
    /// work; only the pane changes.
    func showSide(_ id: String, revealInSidebar: Bool = true) async {
        guard !installPreparing, let child = chats.first(where: { $0.id == id }), !child.isSubagent, let parentID = child.parentSessionID, record(parentID) != nil, !child.imported else { return }
        if let shown = sides[parentID], shown.id == id { await selectSide(id, revealInSidebar: revealInSidebar); return }
        tabs.showSide()
        let paneIntent = tabs.navigationRevision, selection = selectionRevision, changesParent = selectedID != parentID
        let revision = messageNavigationRevision, pageChange = page == .chats ? 0 : 1
        if let shown = sides[parentID], shown.pending, !(await discardPendingSide(shown)) { return }
        guard !Task.isCancelled, messageNavigationRevision == revision, tabs.navigationRevision == paneIntent, selectionRevision == selection else { return }
        if let shown = sides[parentID], !shown.kept || shown.keeping { error = "Wait for the current side to finish opening before switching."; return }
        if revealInSidebar { quietSidebarReveal = [] }
        // This side is the one asked for, not the one the parent last showed.
        if selectedID != parentID { await passingThrough(parentID) { await select(parentID, revealInSidebar: revealInSidebar, reopensSide: false, focusesComposer: false) } }
        guard !Task.isCancelled, messageNavigationRevision == revision + (changesParent ? 1 + pageChange : 0), tabs.navigationRevision == paneIntent, selectionRevision == selection + (changesParent ? 1 : 0), selectedID == parentID else { return }
        let view = mountSide(child, beside: parentID)
        page = .chats; focusedSessionID = id
        if revealInSidebar { revealProjectChat(child) }
        await loadSideDisplay(child, view: view)
    }
    /// Puts a saved child chat in its parent's side pane, waiting to be read.
    /// The side shown there before keeps its display and any running work.
    func mountSide(_ child: ChatRecord, beside parentID: String) -> SessionDisplay {
        releasedHelperSessions.remove(child.id)
        if let previous = sides[parentID] { displays[previous.id]?.presentation.cancel() }
        let view = displays[child.id] ?? SessionDisplay(id: child.id); view.used = Date(); displays[child.id] = view
        adoptContextReading(view, item: child)
        view.beginHistoryPresentation(); view.draftReady = false
        view.browsingHistory = true; view.publishTranscript()
        var info = SideRecord(id: child.id, parentID: parentID, workspaceID: child.workspaceID, profileID: child.profileID, title: child.title, kept: true, model: child.model, thinkingLevel: child.thinkingLevel, contextWindow: child.contextWindow, maxOutputTokens: child.maxOutputTokens, modelOutputLimit: child.modelOutputLimit, outputBudgetVersion: child.outputBudgetVersion)
        info.topicID = effectiveTopicID(for: child)
        info.boundary = ["parentSessionId": .string(parentID)]
        sides[parentID] = info
        return view
    }
    /// Restores a saved child's draft, anchor, pending intents and history into
    /// its display, mirroring what selecting a chat does for the main pane.
    func loadSideDisplay(_ child: ChatRecord, view: SessionDisplay) async {
        let id = child.id, generation = view.presentationGeneration, navigation = transcriptNavigation(child.id)
        let paneIntent = tabs.navigationRevision
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            defer { view.finishHistoryPresentation(generation); self.resumeVisibleReaders() }
            @MainActor func current() -> Bool { !Task.isCancelled && navigation.isCurrent(in: self) && self.tabs.navigationRevision == paneIntent && self.selectedID == child.parentSessionID && self.sides[child.parentSessionID ?? ""]?.id == id && self.displays[id] === view && view.presentationGeneration == generation }
            do {
                await self.readInheritedSubagents(child, current: current)
                guard current() else { return }
                let oldDraft = view.savedDraft
                let metadata = try await self.store?.selectionMetadata(id: id, draft: !view.selectionMetadataLoaded, anchor: !view.selectionMetadataLoaded && view.scrollAnchor == nil)
                guard current() else { return }
                if !view.selectionMetadataLoaded {
                    if let draft = metadata?.draft, view.draft == oldDraft.text && view.attachments == (oldDraft.attachments ?? []) && view.skills == (oldDraft.skills ?? []),
                       view.draft.isEmpty && view.attachments.isEmpty && view.skills.isEmpty && view.editingMessageID == nil && view.queueEditingID == nil { view.restoreDraft(draft); if let queued = draft.queuedEdit { Task { await self.reconcileQueuedEdit(view, queued) } } }
                    if view.scrollAnchor == nil { view.scrollAnchor = metadata?.anchor }
                    view.selectionMetadataLoaded = true
                }
                let recovered = try await self.recoverableIntents(metadata?.recovered ?? [], for: child, view: view)
                guard current() else { return }
                view.recovered = recovered; view.uncertain = !recovered.isEmpty
                view.draftReady = true
                if self.focusedSessionID == id { view.composerFocusRequest += 1 }
                var page = try await self.readInitialWindow(child, holding: view.scrollAnchor)
                guard current() else { return }
                page.messages = await self.withAccounting(page.messages, view: view, workspaceID: child.workspaceID)
                guard current() else { return }
                self.adoptInitialHistory(page, into: view)
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError {
                if current() { view.historyState = .failed("History reading was interrupted. Try loading it again.") }
            }
            catch { if current() { view.historyState = .failed(error.localizedDescription); view.refreshingCachedRows = false; view.notice = error.localizedDescription } }
        }
        view.presentation.navigation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func keepSide(_ id: String) {
        guard let info = side(id), !info.kept, !info.keeping, !info.pending, let view = displays[id], !view.loading, hosts[info.workspaceID] != nil else { return }
        guard view.hasWork else { performKeepSide(id, whenFinished: false); return }
        // Asked on the window showing this side, so the run it is about keeps
        // streaming behind the question instead of freezing with it.
        let question = ChatQuestion(title: "Keep this side when it finishes?",
                                    detail: "Save it as a separate read-only chat when its current work and queue reach idle. Your parent chat stays unchanged.",
                                    action: "Keep When Finished")
        if !questions.ask(question, about: id, answered: { [weak self] keep in
            guard let self, keep else { return }
            self.performKeepSide(id, whenFinished: true)
        }) { view.notice = PiQuestion.busyNotice }
    }
    private func performKeepSide(_ id: String, whenFinished: Bool) {
        guard let info = side(id), !info.kept, !info.keeping, !info.pending, let view = displays[id], !view.loading, let host = hosts[info.workspaceID] else { return }
        view.loading = true
        Task { defer {
            view.loading = false
            updateHostActivity(workspaceID: info.workspaceID)
            if let host = hosts[info.workspaceID] { scheduleIdle(workspaceID: info.workspaceID, host: host) }
        }; do {
            guard let store else { throw StoreError.unavailable }
            var chat = info.chat
            chat.path = root.appendingPathComponent("Workspaces/\(info.workspaceID)/Sessions/side_\(id).jsonl").path
            try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: id)
            let result = try await host.request("side.keep", sessionID: id, params: ["whenFinished": .bool(whenFinished)]).object ?? [:]
            if result["ephemeral"]?.bool == false { try await registerKeptSide(id: id, path: result["path"]?.string) }
            else { sides[info.parentID]?.keepRequested = true }
            refresh(id)
        } catch { view.notice = error.localizedDescription; self.error = error.localizedDescription } }
    }
    func applySideStatus(id: String, result: [String: WireValue]) async {
        guard let info = side(id) else { return }
        if let boundary = result["side"]?.object, boundary != info.boundary { sides[info.parentID]?.boundary = boundary }
        let keeping = result["keeping"]?.bool ?? false, requested = result["keepRequested"]?.bool ?? false
        if info.keeping != keeping { sides[info.parentID]?.keeping = keeping }
        if info.keepRequested != requested { sides[info.parentID]?.keepRequested = requested }
        if result["ephemeral"]?.bool == false && !info.kept {
            do { try await registerKeptSide(id: id, path: result["path"]?.string) }
            catch {
                // Registration can be retried from the preserved recovery
                // intent. It must not prevent this snapshot from updating the
                // transcript, run state, Stop control and queue afterwards.
                await reportSideKeepFailure(id: id, title: info.title, error: error)
            }
        }
    }
    /// Two spellings of one file are the same file. The app writes the path it
    /// intends into the recovery intent; the helper answers with the path it
    /// actually wrote, resolved. Under a symlinked root — `/tmp`, a home on a
    /// mounted volume — those two strings differ although nothing about them
    /// disagrees, and comparing them as text refused to register a side that
    /// had in fact been written exactly where it was asked for.
    private static func sameFile(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        func settled(_ value: String) -> String {
            URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return settled(lhs) == settled(rhs)
    }
    func registerKeptSide(id: String, path: String?) async throws {
        guard let store, let path else { throw HostError.failure("Keep could not match this chat to its saved file.") }
        let intent: SideKeepIntent
        switch try await store.sideKeepState(id: id) {
        case .pending(let pending): intent = pending
        case .registered(let chat, let expected):
            guard Self.sameFile(path, chat.path) else {
                throw HostError.failure("Keep could not match this chat to its saved file.")
            }
            try await history.validateIdentity(path: path, id: id)
            await finishSideKeepRegistration(chat, expected: expected)
            return
        case .missing:
            throw HostError.failure("Keep could not match this chat to its saved file.")
        }
        guard Self.sameFile(path, intent.chat.path) else {
            throw HostError.failure("Keep could not match this chat to its saved file.")
        }
        try await history.validateIdentity(path: path, id: id)
        let view = displays[id]
        let draft: DraftRecord
        if let view { draft = view.savedDraft }
        else { draft = try await store.get(DraftRecord.self, kind: "draft", id: id) ?? DraftRecord(id: id, text: "") }
        var retained = intent.chat
        // The file as the helper names it, which is how every snapshot will
        // name it. The app's own spelling of the same file (/private/tmp for
        // /tmp, a path through a symlink) had the first snapshot rename the
        // chat's file while it was being opened.
        retained.path = path
        if let existing = chats.first(where: { $0.id == id }) { retained.applyOrganization(from: existing) }
        else if let parentID = retained.parentSessionID, let parent = record(parentID) {
            // A parent may move while the helper publishes this saved side.
            retained.topicID = effectiveTopicID(for: parent)
        } else { retained.topicID = effectiveTopicID(for: retained) }
        if let profile = profiles.first(where: { $0.id == retained.profileID }) { retained.migrateOutputBudget(profile: profile) }
        // The transaction resolves a concurrent parent move and returns its
        // durable organization instead of the stale recovery intent's group.
        retained = try await store.commitKeptSide(retained, draft: draft, expected: intent.chat)
        await finishSideKeepRegistration(retained, expected: intent.chat)
    }
    private func finishSideKeepRegistration(_ saved: ChatRecord, expected: ChatRecord) async {
        var retained = saved
        let id = retained.id
        retained.topicID = effectiveTopicID(for: retained)
        if let index = chats.firstIndex(where: { $0.id == id }) {
            if (retained.organizationRevision ?? 0) >= (chats[index].organizationRevision ?? 0) {
                chats[index].applyOrganization(from: retained)
            }
        } else { chats.insert(retained, at: 0) }
        if let info = side(id) { sides[info.parentID]?.kept = true; sides[info.parentID]?.keeping = false; sides[info.parentID]?.keepRequested = false; sides[info.parentID]?.topicID = chats.first(where: { $0.id == id })?.topicID }
        await retainSideReadState(id)
        sideKeepResolutionRevision &+= 1
        sideKeepIssues.removeAll { $0.chat == expected }
        do { try await restoreSideBudgets() }
        catch { self.error = "The chat was saved, but its family cost totals could not be refreshed: " + error.localizedDescription }
    }
    func reconcileSideKeeps() async {
        guard !reconcilingSideKeeps else { return }
        reconcilingSideKeeps = true; defer { reconcilingSideKeeps = false }
        do {
            while true {
                let revision = sideKeepResolutionRevision
                var issues: [SideKeepIssue] = []
                for intent in try await store?.list(SideKeepIntent.self, kind: "side-keep") ?? [] {
                    do {
                        guard let path = intent.chat.path else { throw HostError.failure("No file location was saved for this chat.") }
                        try await registerKeptSide(id: intent.chat.id, path: path)
                    } catch {
                        // A missing file may still be awaiting publication. Keep
                        // the registration until it succeeds or is dismissed.
                        if let current = try await store?.get(SideKeepIntent.self, kind: "side-keep", id: intent.chat.id), current.chat == intent.chat {
                            issues.append(sideKeepIssue(intent, error: error))
                        }
                    }
                }
                // An answer or live keep may settle an earlier item while a later
                // file is checked. Re-read rather than resurrecting its old notice.
                guard revision == sideKeepResolutionRevision else { continue }
                sideKeepIssues = issues.sorted { $0.id < $1.id }
                break
            }
        } catch { self.error = "Saved conversation copies could not be checked. \(error.localizedDescription)" }
    }
    func closeSide(_ id: String) {
        guard let info = side(id), let view = displays[id], !view.loading, !info.keeping else { return }
        if info.pending { if !discardPendingSideNow(info) { Task { await discardPendingSide(info) } }; return }
        view.loading = true
        Task { defer {
            view.loading = false
            updateHostActivity(workspaceID: info.workspaceID)
            if let host = hosts[info.workspaceID] { scheduleIdle(workspaceID: info.workspaceID, host: host) }
        }; do {
            // Recovery removes its intent only with the merged draft saved.
            // Wait before any capture so closing cannot overwrite that draft.
            if let recovery = draftWrites.recoveries[id] { await recovery.value }
            guard let store else { throw StoreError.unavailable }
            if !info.kept {
                guard let host = hosts[info.workspaceID], host.isReady else { throw HostError.failure("The side could not be saved. Reopen its project to recover its journal; the panel remains open.") }
                var saved = info.chat
                saved.path = root.appendingPathComponent("Workspaces/\(info.workspaceID)/Sessions/side_\(id).jsonl").path
                try await store.put(SideKeepIntent(chat: saved), kind: "side-keep", id: id)
                let result = try await host.request("side.close", sessionID: id).object ?? [:]
                try await registerKeptSide(id: id, path: result["path"]?.string)
            }
            // A side whose saved draft never loaded holds nothing of the user's
            // yet: writing its empty composer would erase the one on disk.
            if view.selectionMetadataLoaded {
                try await store.put(view.savedDraft, kind: "draft", id: id)
                if let anchor = view.scrollAnchor { try await store.put(anchor, kind: "anchor", id: id) }
            }
            view.presentation.cancel()
            // Another side may have opened on this chat during the awaits
            // above: only this one is closed, and only its cursor moves.
            guard sides[info.parentID]?.id == id else { return }
            sides.removeValue(forKey: info.parentID)
            if focusedSessionID == id { focusedSessionID = info.parentID }
            // The cursor goes back to the chat the side came from.
            focusComposer(info.parentID)
        } catch { view.notice = error.localizedDescription; self.error = error.localizedDescription } }
    }
    func forkSession(_ parentID: String) {
        guard !installPreparing, let view = displays[parentID], !view.loading else { return }
        let navigation = organizationNavigationRevision
        view.loading = true
        Task { defer {
            view.loading = false
            if let workspace = record(parentID)?.workspaceID {
                updateHostActivity(workspaceID: workspace)
                if let host = hosts[workspace] { scheduleIdle(workspaceID: workspace, host: host) }
            }
        }; do {
            let fork = try await createFork(parentID: parentID)
            if organizationNavigationRevision == navigation, selectedID == parentID || focusedSessionID == parentID { await select(fork.id) }
        } catch { self.error = error.localizedDescription } }
    }
    /// `/fork` copies the whole conversation into a chat of its own. With
    /// `atMessageID` ("Fork from here" on a reply) the copy ends at that reply
    /// and its tools, and the new chat, "‹title› · fork", nests under this one.
    @discardableResult func createFork(parentID: String, atMessageID: String? = nil) async throws -> ChatRecord {
        guard !installPreparing, let parent = record(parentID), !parent.imported, !isEphemeral(parentID), let store else {
            throw HostError.failure("Choose a saved native session before forking its context.")
        }
        let id = UUID().uuidString
        let title = atMessageID == nil ? parent.title + " — fork" : parent.title + " · fork"
        var fork = ChatRecord(id: id, workspaceID: parent.workspaceID, title: String(title.prefix(120)), path: nil, profileID: parent.profileID, toolMode: parent.toolMode, connectionTest: parent.connectionTest, model: parent.model, thinkingLevel: parent.thinkingLevel, contextWindow: parent.contextWindow, maxOutputTokens: parent.maxOutputTokens, modelOutputLimit: parent.modelOutputLimit, outputBudgetVersion: parent.outputBudgetVersion)
        fork.topicID = effectiveTopicID(for: parent)
        if atMessageID != nil { fork.parentSessionID = parent.id }
        fork.path = root.appendingPathComponent("Workspaces/\(parent.workspaceID)/Sessions/fork_\(id).jsonl").path
        try await store.put(SideKeepIntent(chat: fork), kind: "side-keep", id: id)
        let host = try await open(parent)
        var params: [String: WireValue] = ["forkSessionId": .string(id), "costLimit": costLimit(for: fork).wire]
        if let atMessageID { params["atMessageId"] = .string(atMessageID) }
        let result: [String: WireValue]
        sessionProfileRevisions[id] = sessionProfileRevisions[parentID] ?? profiles.first(where: { $0.id == parent.profileID }).map { (host.connectionID, $0.revision) }
        do { result = try await host.request("session.fork", sessionID: parentID, params: params).object ?? [:] }
        catch {
            // Refused before a file was written (a reply whose tools still
            // run): no copy to recover, so no recovery intent is left behind.
            if let path = fork.path, !FileManager.default.fileExists(atPath: path) { try? await store.remove(kind: "side-keep", id: id) }
            throw error
        }
        guard result["sessionId"]?.string == id else { throw HostError.failure("The fork identity changed. Its recovery intent was preserved.") }
        try await registerKeptSide(id: id, path: result["path"]?.string)
        let view = SessionDisplay(id: id); displays[id] = view; opened.insert(id)
        let preference = try await capturePreference(sessionID: id)
        _ = try await host.request("debug.mode", sessionID: id, params: ["mode": .string(preference.mode)])
        view.captureMode = preference.mode; view.captureAvailable = true
        let initial = try await host.request("session.status", sessionID: id)
        observeAssistantOutputs(sessionID: id, snapshot: initial.object ?? [:])
        observeSessionCompletion(sessionID: id, snapshot: initial.object ?? [:], baseline: true)
        try await reconcileSessionProfile(fork, host: host)
        refresh(id)
        return fork
    }
    func discardLostSides(workspaceID: String) {
        // A draft side has nothing on the helper to lose: it stays, with its text.
        for info in sides.values.filter({ $0.workspaceID == workspaceID && !$0.kept && !$0.pending }) {
            let view = displays[info.id]
            let typed = view.map { !Self.unsentDraft(of: $0, to: info.parentID).isBlank } ?? false
            sides.removeValue(forKey: info.parentID); displays.removeValue(forKey: info.id); helperSessionDidUnload(info.id)
            forgetReadState(info.id)
            // The side is gone, but nothing the user typed into it is: the
            // draft moves as a closed side's does, from the display kept here.
            // A parent whose draft is not loaded here cannot take it now: the
            // draft stays on screen as a new draft side of that parent, which
            // closing, quitting or updating moves as any draft side's.
            var parked = false
            if let view, typed, !moveSideDraftHere(info, from: view) {
                parked = true
                var draftSide = info
                draftSide.id = UUID().uuidString; draftSide.pending = true; draftSide.kept = false; draftSide.keeping = false
                draftSide.keepRequested = false; draftSide.boundary = [:]
                let shown = SessionDisplay(id: draftSide.id)
                shown.historyState = .empty; shown.selectionMetadataLoaded = true
                let unsent = Self.unsentDraft(of: view, to: info.parentID)
                shown.draft = unsent.text; shown.attachments = unsent.attachments ?? []; shown.skills = unsent.skills ?? []; shown.submissionReviews = unsent.submissionReviews ?? []
                sides[info.parentID] = draftSide; displays[draftSide.id] = shown
            }
            guard let parent = displays[info.parentID] else { continue }
            parent.notice = !typed ? "The host stopped. Its unkept side was discarded; no request was replayed."
                : parked ? "The host stopped. Its unkept side was discarded; its unsent draft waits in a new side."
                : "The host stopped. Its unkept side was discarded and its unsent draft was moved into this composer."
        }
        Task { await reconcileSideKeeps() }
    }
    func bringBack(_ text: String, from id: String, replace: Bool) throws {
        guard !text.isEmpty, let info = side(id), let parent = displays[info.parentID] else { throw HostError.failure("The parent draft is unavailable") }
        guard draftWrites.recoveries[parent.id] == nil else { throw HostError.failure("Wait for the interrupted submission to finish saving before bringing back the summary.") }
        let draft = replace || parent.draft.isEmpty ? text : parent.draft + "\n\n" + text
        guard draft.utf8.count <= SubmissionLimits.messageBytes else { throw HostError.failure("The combined draft exceeds 256 KiB. Shorten the summary first.") }
        parent.draft = draft; parent.directCommand = false; parent.completionVisible = false; draftChanged(parent)
    }
    func enableEditing(_ id: String) {
        guard let item = chats.first(where: { $0.id == id && !$0.imported && $0.connectionTest != true && $0.workspaceID != WorkspaceRecord.scratchID }), item.toolMode == ChatRecord.readOnlyTools, displays[id]?.hasWork != true, displays[id]?.loading != true else { error = "Wait for this chat to finish its work before changing tools."; return }
        guard store != nil else { error = StoreError.unavailable.localizedDescription; return }
        let question = ChatQuestion(title: "Enable editing tools for this saved chat?",
                                    detail: "Future turns may run shell commands and change files in this project with your account's permissions.",
                                    action: "Enable Editing")
        if !questions.ask(question, about: id, destructive: true, answered: { [weak self] enable in
            guard let self, enable else { return }
            Task { do { try await self.enableEditingAfterConfirmation(id) } catch { self.error = error.localizedDescription } }
        }) { displays[id]?.notice = PiQuestion.busyNotice }
    }
    func enableEditingAfterConfirmation(_ id: String) async throws {
        guard let store else { throw StoreError.unavailable }
        guard var item = chats.first(where: { $0.id == id && !$0.imported && $0.connectionTest != true && $0.workspaceID != WorkspaceRecord.scratchID }), item.toolMode == ChatRecord.readOnlyTools, displays[id]?.hasWork != true, displays[id]?.loading != true else {
            throw HostError.failure("Wait for this chat to finish its work before changing tools.")
        }
        let view = displays[id]
        try beginBudgetOwnerChange(id)
        defer { budgetOwnerChanges.remove(id) }
        view?.loading = true
        defer { view?.loading = false }
        if let host = hosts[item.workspaceID], host.isReady { try await releaseIdleBudgetDependents(of:id,host:host) }
        if opened.contains(id) {
            guard let host = hosts[item.workspaceID], host.isReady else { throw HostError.failure("Wait for this project's host to recover before changing tools.") }
            _ = try await host.request("session.close", sessionID: id); helperSessionDidUnload(id)
        }
        item.toolMode = ChatRecord.editingTools
        try await store.put(item, kind: "chat", id: id)
        if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].toolMode = ChatRecord.editingTools }
        displays[id]?.notice = "Editing tools apply to the next turn."
    }
}
