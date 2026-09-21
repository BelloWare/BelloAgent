import Foundation

// Sending, steering, stopping, and reading earlier pages: everything that
// asks the helper to do something to the conversation the reader is in.

extension WorkspaceModel {
    /// Snapshot the originating pane's intent synchronously, before any helper await.
    func submitComposer(intent: ComposerSubmissionIntent, sessionID: String) {
        guard page == .chats, let view = displays[sessionID], view.draftReady, !view.loading, !installPreparing else { return }
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
                followSubmittedTurn(item.id)
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
}
