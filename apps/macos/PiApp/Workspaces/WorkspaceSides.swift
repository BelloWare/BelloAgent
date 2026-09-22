import SwiftUI
import AppKit

// Side panels are durable child chats. A recovery intent precedes journal
// publication so an interrupted acknowledgement cannot orphan saved history.
struct SideRecord: Identifiable {
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
    var chat: ChatRecord { .init(id: id, workspaceID: workspaceID, title: title, path: nil, profileID: profileID, toolMode: "read-only", model: model, thinkingLevel: thinkingLevel, contextWindow: contextWindow, maxOutputTokens: maxOutputTokens, modelOutputLimit: modelOutputLimit, outputBudgetVersion: outputBudgetVersion, topicID: topicID, parentSessionID: parentID) }
}
struct SideKeepIntent: Codable, Sendable { var chat: ChatRecord }

extension WorkspaceModel {
    /// Both are asked for once per sidebar row, and the sidebar redraws on every
    /// workspace change: a linear scan here is a scan of every chat per row.
    func side(_ id: String) -> SideRecord? { sidebarIndex.side(id, in: sides) }
    func record(_ id: String) -> ChatRecord? { chatRecord(id) ?? side(id)?.chat }
    func isEphemeral(_ id: String) -> Bool { side(id).map { !$0.kept } ?? false }
    var resourceTarget: SessionDisplay? { displays[resourceTargetSessionID ?? selectedID ?? ""] }
    func inspect(_ id: String, messageID: String? = nil) { inspectorSessionID = id; inspectorMessageID = messageID; showInspector = true }
    /// Shows or hides the integrated terminal under the selected chat.
    func toggleTerminal() {
        guard selectedID != nil else { return }
        terminalVisible.toggle()
        if !terminalVisible, let id = focusedSessionID ?? selectedID { displays[id]?.composerFocusRequest += 1 }
    }
    /// Opens the Changes sheet for a project's folders.
    func showChanges(in workspaceID: String? = nil) {
        guard let workspaceID = workspaceID ?? chat?.workspaceID ?? selectedWorkspaceID, workspaces.contains(where: { $0.id == workspaceID }) else { error = "Choose a project to see its changes."; return }
        gitWorkspaceID = workspaceID; showGit = true
    }
    func inspectResources(_ id: String?) { resourceTargetSessionID = id; showResources = true }
    func viewMessages(_ id: String) { messageViewerSessionID = id; showMessageViewer = true }
    func updateHostActivity(workspaceID: String) {
        hosts[workspaceID]?.isBusy = sides.values.contains { $0.workspaceID == workspaceID && !$0.kept && !$0.pending } || displays.values.contains { ($0.hasWork || $0.loading) && record($0.id)?.workspaceID == workspaceID }
    }
    func canOpenSide(_ id: String) -> Bool {
        guard let parent = record(id) else { return false }
        return !parent.imported && parent.connectionTest != true && parent.workspaceID != WorkspaceRecord.scratchID
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
        guard draft.utf8.count <= 262_144 else { error = "The quoted draft exceeds 256 KiB. Select a shorter passage."; return }
        openSide(parentID: parentID)
        guard let info = sides[parentID], info.pending, let view = displays[info.id] else { return }
        view.draft = draft; view.directCommand = false; view.completionVisible = false; view.completionToken = nil
        draftChanged(view)
        focusedSessionID = info.id; view.composerFocusRequest += 1
    }
    func openSide(parentID: String? = nil, question: String = "") {
        guard !installPreparing, let parentID = parentID ?? selectedID, let parent = record(parentID), !parent.imported else { error = "Continue an imported original as a separate chat before opening a side."; return }
        guard canOpenSide(parentID) else { error = "Connection-test chats keep tools disabled and cannot open side chats."; return }
        guard side(parentID) == nil else { error = "Close this side panel before opening a side from its saved chat."; return }
        // Another side can open while one is shown: the shown side stays a
        // saved child chat in the sidebar and comes back on click. Only a side
        // that is still being published must finish first.
        if let existing = sides[parentID], existing.pending {
            // The empty side is already waiting for its first message.
            focusedSessionID = existing.id; displays[existing.id]?.composerFocusRequest += 1
            if !question.isEmpty { displays[existing.id]?.draft = question; send(sessionID: existing.id) }
            return
        }
        if let existing = sides[parentID], !existing.kept || existing.keeping {
            focusedSessionID = existing.id
            error = "Wait for the current side to finish opening before starting another."; return
        }
        let id = UUID().uuidString, view = SessionDisplay(id: id)
        view.historyState = .empty; view.selectionMetadataLoaded = true
        var info = SideRecord(id: id, parentID: parentID, workspaceID: parent.workspaceID, profileID: parent.profileID, title: parent.title + " — side", model: parent.model, thinkingLevel: parent.thinkingLevel, contextWindow: parent.contextWindow, maxOutputTokens: parent.maxOutputTokens, modelOutputLimit: parent.modelOutputLimit, outputBudgetVersion: parent.outputBudgetVersion)
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
                view.draft = question; send(sessionID: id)
            } catch {
                view.loading = false; view.notice = error.localizedDescription
                // Unwind the in-memory side for every failure, not only an
                // explicit rejection. A side left half-open can be neither
                // closed nor kept, and while it exists the app refuses to quit
                // and blocks every update. The saved side-keep intent still
                // lets a side the host did publish be recovered on restart.
                sides.removeValue(forKey: parentID); displays.removeValue(forKey: id)
                if let original = displays[parentID] { original.draft += (original.draft.isEmpty ? "" : "\n\n") + question; original.directCommand = false; draftChanged(original) }
                self.error = error.localizedDescription; updateHostActivity(workspaceID: parent.workspaceID)
            }
        }
    }
    /// Creates the side on the helper: the recovery intent and draft, the
    /// parent's context snapshot as a durable child session, and its capture
    /// preference. Called when a side with a question opens, and when a
    /// pending side sends its first message.
    func publishPendingSide(_ info: SideRecord, view: SessionDisplay) async throws {
        guard let store else { throw StoreError.unavailable }
        guard let parent = record(info.parentID) else { throw HostError.failure("The parent chat is no longer available.") }
        let id = info.id, parentID = info.parentID
        view.loading = true; defer { view.loading = false }
        var saved = info.chat
        saved.topicID = effectiveTopicID(for: parent)
        saved.path = root.appendingPathComponent("Workspaces/\(info.workspaceID)/Sessions/side_\(id).jsonl").path
        try await store.put(SideKeepIntent(chat: saved), kind: "side-keep", id: id)
        try await store.put(DraftRecord(id: id, text: view.draft), kind: "draft", id: id)
        let host = try await open(parent); host.isBusy = true
        sides[parentID]?.pending = false
        let result = try await host.request("side.open", sessionID: parentID, params: ["sideSessionId": .string(id)]).object ?? [:]
        guard result["sessionId"]?.string == id, sides[parentID]?.id == id else { throw HostError.failure("Side identity changed; reopen this project before creating another side.") }
        try await registerKeptSide(id: id, path: result["path"]?.string)
        let preference = try await capturePreference(sessionID: id)
        _ = try await host.request("debug.mode", sessionID: id, params: ["mode": .string(preference.mode)])
        view.captureMode = preference.mode
        let initial = try await host.request("session.status", sessionID: id)
        observeAssistantOutputs(sessionID: id, snapshot: initial.object ?? [:])
        observeSessionCompletion(sessionID: id, snapshot: initial.object ?? [:], baseline: true)
        sides[parentID]?.boundary = result["side"]?.object ?? [:]; opened.insert(id); view.captureAvailable = true
        if selectedID == parentID { focusedSessionID = id }
        updateHostActivity(workspaceID: info.workspaceID); refresh(id)
    }
    /// Drops a side that never sent a message, moving its unsent text into the parent composer.
    func discardPendingSide(_ info: SideRecord) {
        guard info.pending else { return }
        let draft = displays[info.id]?.draft.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sides.removeValue(forKey: info.parentID); displays.removeValue(forKey: info.id)
        if focusedSessionID == info.id { focusedSessionID = info.parentID }
        if !draft.isEmpty, let parent = displays[info.parentID] { parent.draft += (parent.draft.isEmpty ? "" : "\n\n") + draft; parent.directCommand = false; draftChanged(parent) }
        focusComposer(info.parentID)
    }
    /// Shows a saved child chat in the side pane of its parent, replacing the
    /// side shown there. The replaced side keeps its display and any running
    /// work; only the pane changes.
    func showSide(_ id: String) async {
        guard !installPreparing, let child = chats.first(where: { $0.id == id }), let parentID = child.parentSessionID, record(parentID) != nil, !child.imported else { return }
        if let shown = sides[parentID], shown.id == id { await selectSide(id); return }
        if let shown = sides[parentID], shown.pending { discardPendingSide(shown) }
        if let shown = sides[parentID], !shown.kept || shown.keeping { error = "Wait for the current side to finish opening before switching."; return }
        if selectedID != parentID { await select(parentID) }
        guard selectedID == parentID else { return }
        if let previous = sides[parentID] { displays[previous.id]?.presentation.cancel() }
        let view = displays[id] ?? SessionDisplay(id: id); view.used = Date(); displays[id] = view
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        view.historyState = .loading; view.draftReady = view.selectionMetadataLoaded
        view.browsingHistory = true; view.publishTranscript()
        var info = SideRecord(id: id, parentID: parentID, workspaceID: child.workspaceID, profileID: child.profileID, title: child.title, kept: true, model: child.model, thinkingLevel: child.thinkingLevel, contextWindow: child.contextWindow, maxOutputTokens: child.maxOutputTokens, modelOutputLimit: child.modelOutputLimit, outputBudgetVersion: child.outputBudgetVersion)
        info.topicID = effectiveTopicID(for: child)
        info.boundary = ["parentSessionId": .string(parentID)]
        sides[parentID] = info
        page = .chats; focusedSessionID = id
        revealProjectChat(child)
        await loadSideDisplay(child, view: view)
    }
    /// Restores a saved child's draft, anchor, pending intents and history into
    /// its display, mirroring what selecting a chat does for the main pane.
    func loadSideDisplay(_ child: ChatRecord, view: SessionDisplay) async {
        let id = child.id, generation = view.presentationGeneration
        let task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && self.selectedID == child.parentSessionID && self.sides[child.parentSessionID ?? ""]?.id == id && self.displays[id] === view && view.presentationGeneration == generation }
            do {
                let oldDraft = view.savedDraft
                let metadata = try await self.store?.selectionMetadata(id: id, draft: !view.selectionMetadataLoaded, anchor: !view.selectionMetadataLoaded && view.scrollAnchor == nil)
                guard current() else { return }
                if !view.selectionMetadataLoaded {
                    if let draft = metadata?.draft, view.draft == oldDraft.text && view.attachments == (oldDraft.attachments ?? []) && view.skills == (oldDraft.skills ?? []),
                       view.draft.isEmpty && view.attachments.isEmpty && view.skills.isEmpty && view.editingMessageID == nil { view.restoreDraft(draft) }
                    if view.scrollAnchor == nil { view.scrollAnchor = metadata?.anchor }
                    view.selectionMetadataLoaded = true
                }
                view.recovered = metadata?.recovered ?? []; view.uncertain = !view.recovered.isEmpty
                view.draftReady = true
                if self.focusedSessionID == id { view.composerFocusRequest += 1 }
                let page = try await self.readConversationWindow(child, cursor: nil)
                guard current() else { return }
                self.adoptInitialHistory(page, into: view)
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError { }
            catch { if current() { view.historyState = .failed(error.localizedDescription); view.notice = error.localizedDescription } }
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
                self.error = "The side's saved history could not be registered. Its recovery intent was preserved. \(error.localizedDescription)"
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
        guard let store, let intent = try await store.get(SideKeepIntent.self, kind: "side-keep", id: id), let expected = intent.chat.path,
              Self.sameFile(path, expected) else {
            if chats.contains(where: { $0.id == id }) { return }
            throw HostError.failure("Keep needs its saved recovery intent and expected conversation file.")
        }
        try await history.validateIdentity(path: expected, id: id)
        let view = displays[id]
        let draft: DraftRecord
        if let view { draft = view.savedDraft }
        else { draft = try await store.get(DraftRecord.self, kind: "draft", id: id) ?? DraftRecord(id: id, text: "") }
        var retained = intent.chat
        if let existing = chats.first(where: { $0.id == id }) { retained.applyOrganization(from: existing) }
        else if let parentID = retained.parentSessionID, let parent = record(parentID) {
            // A parent may move while the helper publishes this saved side.
            retained.topicID = effectiveTopicID(for: parent)
        } else { retained.topicID = effectiveTopicID(for: retained) }
        if let profile = profiles.first(where: { $0.id == retained.profileID }) { retained.migrateOutputBudget(profile: profile) }
        // The transaction resolves a concurrent parent move and returns its
        // durable organization instead of the stale recovery intent's group.
        retained = try await store.commitKeptSide(retained, draft: draft)
        retained.topicID = effectiveTopicID(for: retained)
        if let index = chats.firstIndex(where: { $0.id == id }) {
            if (retained.organizationRevision ?? 0) >= (chats[index].organizationRevision ?? 0) {
                chats[index].applyOrganization(from: retained)
            }
        } else { chats.insert(retained, at: 0) }
        if let info = side(id) { sides[info.parentID]?.kept = true; sides[info.parentID]?.keeping = false; sides[info.parentID]?.keepRequested = false; sides[info.parentID]?.topicID = chats.first(where: { $0.id == id })?.topicID }
        await retainSideReadState(id)
    }
    func reconcileSideKeeps() async {
        do {
            for intent in try await store?.list(SideKeepIntent.self, kind: "side-keep") ?? [] {
                do {
                    guard let path = intent.chat.path else { continue }
                    if FileManager.default.fileExists(atPath: path) { try await registerKeptSide(id: intent.chat.id, path: path) }
                    else { try await store?.remove(kind: "side-keep", id: intent.chat.id) }
                } catch { self.error = "A previous conversation copy needs review. Its file and recovery intent were preserved. \(error.localizedDescription)" }
            }
        } catch { self.error = "A previous conversation copy needs review. Its file and recovery intent were preserved. \(error.localizedDescription)" }
    }
    func closeSide(_ id: String) {
        guard let info = side(id), let view = displays[id], !view.loading, !info.keeping else { return }
        if info.pending { discardPendingSide(info); return }
        view.loading = true
        Task { defer {
            view.loading = false
            updateHostActivity(workspaceID: info.workspaceID)
            if let host = hosts[info.workspaceID] { scheduleIdle(workspaceID: info.workspaceID, host: host) }
        }; do {
            guard let store else { throw StoreError.unavailable }
            if !info.kept {
                guard let host = hosts[info.workspaceID], host.isReady else { throw HostError.failure("The side could not be saved. Reopen its project to recover its journal; the panel remains open.") }
                var saved = info.chat
                saved.path = root.appendingPathComponent("Workspaces/\(info.workspaceID)/Sessions/side_\(id).jsonl").path
                try await store.put(SideKeepIntent(chat: saved), kind: "side-keep", id: id)
                let result = try await host.request("side.close", sessionID: id).object ?? [:]
                try await registerKeptSide(id: id, path: result["path"]?.string)
            }
            try await store.put(view.savedDraft, kind: "draft", id: id)
            if let anchor = view.scrollAnchor { try await store.put(anchor, kind: "anchor", id: id) }
            view.presentation.cancel()
            sides.removeValue(forKey: info.parentID)
            if focusedSessionID == id { focusedSessionID = info.parentID }
            // The cursor goes back to the chat the side came from.
            focusComposer(info.parentID)
        } catch { view.notice = error.localizedDescription; self.error = error.localizedDescription } }
    }
    func forkSession(_ parentID: String) {
        guard !installPreparing, let view = displays[parentID], !view.loading else { return }
        view.loading = true
        Task { defer {
            view.loading = false
            if let workspace = record(parentID)?.workspaceID {
                updateHostActivity(workspaceID: workspace)
                if let host = hosts[workspace] { scheduleIdle(workspaceID: workspace, host: host) }
            }
        }; do {
            let fork = try await createFork(parentID: parentID)
            if selectedID == parentID || focusedSessionID == parentID { await select(fork.id) }
        } catch { self.error = error.localizedDescription } }
    }
    @discardableResult func createFork(parentID: String) async throws -> ChatRecord {
        guard !installPreparing, let parent = record(parentID), !parent.imported, !isEphemeral(parentID), let store else {
            throw HostError.failure("Choose a saved native session before forking its context.")
        }
        let id = UUID().uuidString
        var fork = ChatRecord(id: id, workspaceID: parent.workspaceID, title: String((parent.title + " — fork").prefix(120)), path: nil, profileID: parent.profileID, toolMode: parent.toolMode, connectionTest: parent.connectionTest, model: parent.model, thinkingLevel: parent.thinkingLevel, contextWindow: parent.contextWindow, maxOutputTokens: parent.maxOutputTokens, modelOutputLimit: parent.modelOutputLimit, outputBudgetVersion: parent.outputBudgetVersion)
        fork.topicID = effectiveTopicID(for: parent)
        fork.path = root.appendingPathComponent("Workspaces/\(parent.workspaceID)/Sessions/fork_\(id).jsonl").path
        try await store.put(SideKeepIntent(chat: fork), kind: "side-keep", id: id)
        let host = try await open(parent)
        let result = try await host.request("session.fork", sessionID: parentID, params: ["forkSessionId": .string(id)]).object ?? [:]
        guard result["sessionId"]?.string == id else { throw HostError.failure("The fork identity changed. Its recovery intent was preserved.") }
        try await registerKeptSide(id: id, path: result["path"]?.string)
        let view = SessionDisplay(id: id); displays[id] = view; opened.insert(id)
        let preference = try await capturePreference(sessionID: id)
        _ = try await host.request("debug.mode", sessionID: id, params: ["mode": .string(preference.mode)])
        view.captureMode = preference.mode; view.captureAvailable = true
        let initial = try await host.request("session.status", sessionID: id)
        observeAssistantOutputs(sessionID: id, snapshot: initial.object ?? [:])
        observeSessionCompletion(sessionID: id, snapshot: initial.object ?? [:], baseline: true)
        refresh(id)
        return fork
    }
    func discardLostSides(workspaceID: String) {
        for info in sides.values.filter({ $0.workspaceID == workspaceID && !$0.kept }) {
            let draft = displays[info.id]?.draft.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sides.removeValue(forKey: info.parentID); displays.removeValue(forKey: info.id); opened.remove(info.id)
            forgetReadState(info.id)
            guard let parent = displays[info.parentID] else { continue }
            // The side is gone, but nothing the user typed into it is.
            if !draft.isEmpty { parent.draft += (parent.draft.isEmpty ? "" : "\n\n") + draft; parent.directCommand = false; draftChanged(parent) }
            parent.notice = draft.isEmpty ? "The host stopped. Its unkept side was discarded; no request was replayed."
                : "The host stopped. Its unkept side was discarded and its unsent draft was moved into this composer."
        }
        Task { await reconcileSideKeeps() }
    }
    func bringBack(_ text: String, from id: String, replace: Bool) throws {
        guard !text.isEmpty, let info = side(id), let parent = displays[info.parentID] else { throw HostError.failure("The parent draft is unavailable") }
        let draft = replace || parent.draft.isEmpty ? text : parent.draft + "\n\n" + text
        guard draft.utf8.count <= 262_144 else { throw HostError.failure("The combined draft exceeds 256 KiB. Shorten the summary first.") }
        parent.draft = draft; parent.directCommand = false; parent.completionVisible = false; draftChanged(parent)
    }
    func enableEditing(_ id: String) {
        guard let item = chats.first(where: { $0.id == id && !$0.imported && $0.connectionTest != true && $0.workspaceID != WorkspaceRecord.scratchID }), item.toolMode == "read-only", displays[id]?.hasWork != true, displays[id]?.loading != true, side(id) == nil else { error = "Close the saved side panel and wait for idle before changing tools."; return }
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
        guard var item = chats.first(where: { $0.id == id && !$0.imported && $0.connectionTest != true && $0.workspaceID != WorkspaceRecord.scratchID }), item.toolMode == "read-only", displays[id]?.hasWork != true, displays[id]?.loading != true, side(id) == nil else {
            throw HostError.failure("Close the saved side panel and wait for idle before changing tools.")
        }
        let view = displays[id]
        view?.loading = true
        defer { view?.loading = false }
        if opened.contains(id) {
            guard let host = hosts[item.workspaceID], host.isReady else { throw HostError.failure("Wait for this project's host to recover before changing tools.") }
            _ = try await host.request("session.close", sessionID: id); opened.remove(id)
        }
        item.toolMode = "editing"
        try await store.put(item, kind: "chat", id: id)
        if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].toolMode = "editing" }
        displays[id]?.notice = "Editing tools apply to the next turn."
    }
}

struct SidePane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let info: SideRecord
    /// The share of the content column this side has, for the composer bar.
    let paneWidth: CGFloat
    @State private var handoff = false
    var body: some View {
        // The hairline that used to start this pane is the split's draggable
        // divider now, drawn once by the workspace between the two panes.
        ConversationPane(model: model, session: session, chat: model.record(info.id) ?? info.chat, paneWidth: paneWidth, side: info,
                         sideActions: SideActions(bringBack: { handoff = true }, keep: { model.keepSide(info.id) }, close: { model.closeSide(info.id) }))
        .sheet(isPresented: $handoff) { SideHandoff(model: model, session: session) }
    }
}
struct SideHandoff: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @State private var text = ""
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PiSheet("Bring back to parent draft", subtitle: "Edit this summary or selection. Bringing it back only changes the parent draft; review it before sending.", symbol: "arrow.uturn.backward", width: 720, height: 480) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                NativeCodeEditor(text: $text, accessibilityLabel: "Editable side summary").piInset().frame(maxHeight: .infinity)
                PiStatusLine(text: error, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }
        } footer: {
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
                Button("Replace Parent Draft") { insert(replace: true) }
                Button("Insert in Parent Draft") { insert(replace: false) }.buttonStyle(.piPrimary)
            }.disabled(text.isEmpty)
        }
        .onAppear { text = session.messages.last(where: { $0.role == "assistant" && !$0.isStreaming })?.text ?? "" }
    }
    private func insert(replace: Bool) { do { try model.bringBack(text, from: session.id, replace: replace); dismiss() } catch { self.error = error.localizedDescription } }
}
