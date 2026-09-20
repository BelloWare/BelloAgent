import Foundation

// Sending, steering, stopping, and reading earlier pages: everything that
// asks the helper to do something to the conversation the reader is in.

extension WorkspaceModel {
    /// Snapshot the originating pane's intent synchronously, before any helper await.
    func submitComposer(intent: ComposerSubmissionIntent, sessionID: String) {
        guard page == .chats, let view = displays[sessionID], !view.loading, !installPreparing else { return }
        if view.editingMessageID != nil { sendEdit(sessionID: sessionID); return }
        // Bypassing the completion list with Command-Return is not a skill grant.
        if let command = LeadingCommand.parse(view.draft, directInput: view.directCommand),
           !LeadingCommand.reserved.contains(command.name) {
            view.completionVisible = true
            view.notice = "Select the skill with Tab or Return before submitting."
            Task { await loadSkillCatalog(sessionID: sessionID) }
            return
        }
        send(steer: intent == .steer && view.busy, sessionID: sessionID)
    }

    func send(steer: Bool = false, sessionID: String? = nil) {
        // Global commands target the visible conversation. Explicit session
        // submissions already accepted by an asynchronous side flow continue.
        guard sessionID != nil || page == .chats else { return }
        if let id = sessionID ?? focusedSessionID ?? selectedID, let view = displays[id], view.editingMessageID != nil {
            if steer { view.notice = "Finish or cancel this edit before steering the current run." }
            else { sendEdit(sessionID: id) }
            return
        }
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), !item.isBackgroundTask, let view = displays[id], (!view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.skills.isEmpty), !view.loading, !installPreparing, side(id)?.keeping != true else { return }
        guard !item.isArchived else { view.notice = Self.archivedNotice; return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before sending."; return }
        if resolveLeadingCommand(view, steer: steer) { return }
        guard view.draft.utf8.count <= 262_144 else { error = "The draft exceeds the 256 KiB submission limit"; return }
        if view.uncertain {
            // Asked on the chat's own window: a modal run loop here would stop
            // every other chat's stream while the reader thinks about it.
            if !questions.ask(Self.uncertainOutcome, about: id, answered: { [weak self] reviewed in
                guard let self, reviewed, let view = self.displays[id], view.uncertain else { return }
                view.uncertain = false
                self.send(steer: steer, sessionID: id)
            }) { view.notice = PiQuestion.busyNotice }
            return
        }
        let attachments = view.attachments, skills = view.skills
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString, previousState = view.state
        view.beginContextSubmission(turnID)
        view.loading = true; view.compactionNotice = nil
        view.sendFailure = nil
        Task {
            defer { view.loading = false }
            var dispatched = false
            do {
                // Snapshot authorization before suspending, but preserve the
                // user's draft even when the connection is already missing.
                let connection = Result { try connectionLease(for: item) }
                try await materializeChat(item.id)
                if !isEphemeral(item.id) { try await store.put(DraftRecord(id: item.id, text: text, attachments: attachments, skills: skills), kind: "draft", id: item.id) }
                let lease = try connection.get()
                try requireConnection(lease)
                if let info = side(item.id), info.pending {
                    try await publishPendingSide(info, view: view)
                    if !isEphemeral(item.id) { try await store.put(DraftRecord(id: item.id, text: text, attachments: attachments, skills: skills), kind: "draft", id: item.id) }
                }
                let host = try await open(item)
                let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent", epoch: host.epoch, attachments: attachments, skills: skills)
                if !isEphemeral(item.id) { try await store.put(intent, kind: "pending:\(item.id)", id: commandID) }
                try requireConnection(lease)
                dispatched = true
                if !view.busy { view.state = "running" }
                _ = try await host.request(steer ? "turn.steer" : "turn.submit", sessionID: item.id,
                                          params: TurnOverrides.params(for: item, base: ["text": .string(text), "clientTurnId": .string(turnID), "attachments": .array(attachments.map(\.wire)), "skills": .array(skills.map(\.wire))]), commandID: commandID)
                view.acknowledgeContextSubmission(turnID)
                if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID) }
                if view.draft == text { view.draft = ""; view.attachments.removeAll { attachments.contains($0) }; view.skills.removeAll { skills.contains($0) }; view.directCommand = false; draftChanged(view) }
                if let index = chats.firstIndex(where: { $0.id == item.id }), chats[index].titleWasEdited != true, chats[index].titleWasGenerated != true,
                   chats[index].title == "New chat" || (chats[index].parentSessionID != nil && chats[index].title.hasSuffix(" — side")) {
                    if chats[index].title == "New chat" {
                        chats[index].title = String((text.isEmpty ? skills.map { "/" + $0.name }.joined(separator: " ") : text).prefix(60)).replacingOccurrences(of: "\n", with: " "); try await store.put(chats[index], kind: "chat", id: item.id)
                    }
                    scheduleTitleGeneration(sourceID: item.id, input: text)
                }
                // The new turn is what the reader wants to see, wherever they had scrolled.
                view.scrollAnchor = .init(id: view.messages.last?.id ?? "", offset: 0, followsBottom: true); view.viewportRequest += 1; anchorChanged(view)
                refresh(item.id)
            } catch {
                view.rejectContextSubmission(turnID)
                // The failure sits in the conversation, under the messages, not in a fixed strip.
                if case HostError.rejected(let code, _) = error, code == "not_running", steer {
                    view.sendFailure = "The run finished. Press Return to send this as a new message."
                } else { view.sendFailure = error.localizedDescription }
                if case HostError.rejected(let code, _) = error { try? await store.remove(kind: "pending:\(item.id)", id: commandID); view.state = code == "connection_unavailable" ? "interrupted" : previousState }
                else { view.uncertain = dispatched; view.state = dispatched ? "interrupted" : previousState }
            }
        }
    }
    func action(_ method: String, params: [String: WireValue] = [:], sessionID: String? = nil) {
        guard !installPreparing, let id = sessionID ?? selectedID, let item = record(id) else { return }
        // Nothing runs in an archived chat; stopping is the one command it still takes.
        guard !item.isArchived || method == "turn.stop" else { displays[id]?.notice = Self.archivedNotice; return }
        if method == "context.compact" { displays[id]?.compactionNotice = nil }
        let commandID = UUID().uuidString
        Task { do {
            let lease = try connectionLease(for: item)
            let host = try await open(item)
            if method == "context.compact" && !isEphemeral(item.id) {
                guard let store else { throw StoreError.unavailable }
                try await store.put(CommandIntent(id: commandID, sessionID: item.id, turnID: "compaction:\(commandID)", text: "[Compact now]", state: "intent", epoch: host.epoch), kind: "pending:\(item.id)", id: commandID)
            }
            try requireConnection(lease)
            _ = try await host.request(method, sessionID: item.id, params: params, commandID: commandID)
            if method == "queue.remove", let turnID = params["turnId"]?.string {
                for intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { try await store?.remove(kind: "pending:\(item.id)", id: intent.id) }
            }
            if method == "queue.update", let turnID = params["turnId"]?.string, let text = params["text"]?.string, !isEphemeral(item.id) {
                // A recovered intent shows the text the host will actually deliver.
                for var intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { intent.text = text; try await store?.put(intent, kind: "pending:\(item.id)", id: intent.id) }
            }
            refresh(item.id)
        }
            catch {
                // A rejected compaction never ran; a leftover intent would mark
                // the chat "outcome uncertain" on its next visit.
                if method == "context.compact", case HostError.rejected = error { try? await store?.remove(kind: "pending:\(item.id)", id: commandID) }
                self.error = error.localizedDescription
            } }
    }
    /// `userInitiated` is the Stop button, the live bar and ⌘. — a press that
    /// has to resolve what is on screen even when there is no helper left to
    /// ask. Callers that merely forward a stop (archiving a chat, say) pass
    /// false: they must not invent an interruption for a run they cannot see.
    func stop(sessionID: String? = nil, userInitiated: Bool = true) {
        guard let id = sessionID ?? selectedID, let item = record(id), let view = displays[id] else { return }
        guard let host = hosts[item.workspaceID], opened.contains(item.id) else {
            // The helper that was running this chat is gone (it crashed, was
            // unloaded, or its project was closed). Doing nothing would leave
            // the live bar and its Stop button up with nothing behind them.
            guard userInitiated, view.busy else { return }
            view.state = "interrupted"; view.runStatus = "interrupted"; view.settleInterruptedRows()
            view.notice = "The helper is no longer running this chat, so there was nothing left to stop. Send again to start a new command."
            return
        }
        view.state = "stopping"
        Task { do { _ = try await host.request("turn.stop", sessionID: item.id); refresh(item.id) }
            catch { view.state = "interrupted"; view.uncertain = true; view.notice = error.localizedDescription } }
    }
    /// Prepends the page before the earliest row shown, keeping the reader's
    /// place. The page asks for this as the reader nears the top; the header
    /// button asks explicitly. Live updates keep arriving underneath.
    func loadEarlier(sessionID: String? = nil) {
        Task { _ = await loadEarlierPage(sessionID: sessionID) }
    }
    /// A page that begins in the middle of a turn hides the question that
    /// started it, which is exactly what a short chat with many tool calls
    /// looks like; earlier pages are pulled in until a user message leads.
    func ensurePageStartsAtTurn(sessionID id: String, refreshAfterRepair: Bool = true) async {
        guard let view = displays[id], !view.pageStartEnsured else { return }
        view.pageStartEnsured = true
        var pages = 0
        while pages < 4, let first = view.messages.first, first.role != "user", view.hostBefore != nil || view.before != nil, displays[id] === view {
            guard await loadEarlierPage(sessionID: id, startingTurnOnly: true) else { break }
            pages += 1
        }
        if pages > 0, refreshAfterRepair, displays[id] === view, let item = record(id) {
            await refreshAccounting(view, workspaceID: item.workspaceID)
        }
    }
    /// One earlier page; true when rows were prepended.
    func loadEarlierPage(sessionID: String? = nil, startingTurnOnly: Bool = false) async -> Bool {
        guard let id = sessionID ?? selectedID, let item = record(id), let view = displays[id], !view.loadingEarlier else { return false }
        view.loadingEarlier = true
        defer { view.loadingEarlier = false }
        do {
            var earlier: [TranscriptMessage] = [], hostPage = false
            if opened.contains(item.id), let host = hosts[item.workspaceID] {
                hostPage = true
                guard let before = view.hostBefore else { return false }
                let value = try await host.request("session.history", sessionID: item.id, params: ["before": .number(before)]).object ?? [:]
                earlier = try TranscriptMessage.page(value["messages"] ?? .array([]))
                guard displays[id] === view else { return false }
                view.hostBefore = value["before"]?.number
            } else if let path = item.path, let before = view.before {
                let page = try await history.read(path: path, before: before)
                guard displays[id] === view else { return false }
                earlier = page.messages; view.before = page.before
                if view.historyRevision != page.revision { view.historyRevision = nil }
            } else { return false }
            var prefix = TranscriptPaging.prefix(earlier: earlier, shown: view.messages)
            guard !prefix.isEmpty else { return false }
            if startingTurnOnly, let user = prefix.lastIndex(where: { $0.role == "user" }), user > prefix.startIndex {
                prefix = Array(prefix[user...])
                // Automatic repair needs only this turn, not every older row
                // returned in the page. Keep its omitted rows pageable later.
                if hostPage, let first = prefix.first,
                   let omitted = earlier.firstIndex(where: { $0.id == first.id }) {
                    view.hostBefore = (view.hostBefore ?? 0) + Double(omitted)
                } else { view.before = prefix.first?.id }
            }
            for index in prefix.indices { prefix[index].accounting = view.messageAccounting[prefix[index].id] }
            // A deliberate older-page request anchors its first visible row.
            // Automatic turn repair preserves the reader's existing intent;
            // inventing a detached first-row anchor would jump a newly opened
            // chat away from its newest turn before layout finishes.
            if !startingTurnOnly, let first = view.messages.first {
                let offset = view.scrollAnchor?.id == first.id ? (view.scrollAnchor?.offset ?? 0) : 0
                view.scrollAnchor = .init(id: first.id, offset: offset, followsBottom: false)
            }
            view.messages = prefix + view.messages
            view.viewportRequest += 1
            if !startingTurnOnly { anchorChanged(view) }
            if !startingTurnOnly { await refreshAccounting(view, workspaceID: item.workspaceID) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func latest(sessionID: String? = nil) { if let id = sessionID ?? selectedID {
        if let view = displays[id], let item = record(id) {
            view.browsingHistory = false; view.projectionRevision = nil
            // A nil anchor would be reloaded from SQLite by select() before an
            // asynchronous deletion finished. Persist the explicit bottom intent.
            view.scrollAnchor = .init(id: view.messages.last?.id ?? "", offset: 0, followsBottom: true); view.viewportRequest += 1; anchorChanged(view)
            // Drop the pages scrolled up to; the helper's window or the file tail is the display again.
            if opened.contains(id) { view.messages = Array(view.messages.suffix(60)); view.hostBefore = nil }
            else if let path = item.path {
                Task { if let page = try? await history.read(path: path), displays[id] === view { view.messages = page.messages; view.before = page.before; view.viewportRequest += 1 } }
            }
        }
        if opened.contains(id) { refresh(id) } else { Task { await select(id) } }
    } }
}
