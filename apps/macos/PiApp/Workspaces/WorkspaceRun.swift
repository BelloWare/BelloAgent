import Foundation

// Sending, steering, stopping, and reading earlier pages: everything that
// asks the helper to do something to the conversation the reader is in.

extension WorkspaceModel {
    /// Snapshot the originating pane's intent synchronously, before any helper await.
    func submitComposer(intent: ComposerSubmissionIntent, sessionID: String) {
        guard page == .chats, let view = displays[sessionID], view.draftReady, !view.loading, !installPreparing else { return }
        if view.queueEditingID != nil { saveQueuedEdit(sessionID: sessionID); return }
        if view.editingMessageID != nil { sendEdit(sessionID: sessionID); return }
        // Bypassing the completion list with Command-Return is not a skill grant.
        if intent == .steer, view.completionVisible {
            view.notice = "Select or dismiss the skill suggestions before steering."; return
        }
        if let command = LeadingCommand.parse(view.draft, directInput: view.directCommand),
           !LeadingCommand.reserved.contains(command.name), intent == .steer || (command.arguments.isEmpty && view.completionVisible) {
            view.completionVisible = true
            view.notice = "Select the skill with Tab or Return before submitting."
            Task { await loadSkillCatalog(sessionID: sessionID) }
            return
        }
        send(steer: intent == .steer && view.busy, sessionID: sessionID)
    }

    /// The Conversation menu's ⌘↩: what ⌘↩ does in the focused chat's composer.
    func submitFocusedComposer(intent: ComposerSubmissionIntent) {
        guard let id = focusedSessionID ?? selectedID else { return }
        submitComposer(intent: intent, sessionID: id)
    }
    func send(steer: Bool = false, sessionID: String? = nil) {
        // Global commands target the visible conversation. Explicit session
        // submissions already accepted by an asynchronous side flow continue.
        guard sessionID != nil || page == .chats else { return }
        if redirectsToEdit(steer: steer, sessionID: sessionID) { return }
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), !item.isBackgroundTask, let view = displays[id], (!view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.skills.isEmpty), !view.loading, !installPreparing, side(id)?.keeping != true else { return }
        // A message goes to the latest version, and the transcript returns to it.
        latestVersion(sessionID: id)
        guard !item.isArchived else { view.notice = Self.archivedNotice; return }
        guard let store else { error = "Desktop storage is unavailable. Resolve the storage error before sending."; return }
        if resolveLeadingCommand(view, steer: steer) { return }
        guard view.draft.utf8.count <= SubmissionLimits.messageBytes else { error = "The draft exceeds the 256 KiB submission limit"; return }
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
        let submission = acceptSubmission(item, view: view, store: store, steer: steer)
        sendSteps?("accepted")
        Task {
            // A send that failed before any snapshot leaves the helper's busy
            // mark to be worked out again here (a failed first message of a
            // draft side had marked it busy for good).
            defer { view.loading = false; updateHostActivity(workspaceID: item.workspaceID) }
            var progress = SendProgress()
            do { try await deliverSubmission(submission, progress: &progress) }
            catch { await recoverFailedSubmission(submission, from: error, progress: progress) }
        }
        if submission.accepted {
            draftChanged(view)
            // The new turn is what the reader wants to see, wherever they had scrolled.
            if submission.drawsRow { followSubmittedTurn(item.id, refreshing: false) }
        }
    }
    /// Return in a composer that is rewriting a queued or an earlier message
    /// saves that edit instead, and a steer waits until the edit is done.
    /// Returns whether the press was taken that way.
    private func redirectsToEdit(steer: Bool, sessionID: String?) -> Bool {
        if let id = sessionID ?? focusedSessionID ?? selectedID, let view = displays[id], view.queueEditingID != nil {
            if steer { view.notice = "Save or cancel the queued message you are rewriting before steering the current run." }
            else { saveQueuedEdit(sessionID: id) }
            return true
        }
        if let id = sessionID ?? focusedSessionID ?? selectedID, let view = displays[id], view.editingMessageID != nil {
            if steer { view.notice = "Finish or cancel this edit before steering the current run." }
            else { sendEdit(sessionID: id) }
            return true
        }
        return false
    }
    /// Takes the message out of the composer on Return, before anything
    /// suspends: what it says, whether its chat can still send it, and the
    /// row drawn for it at once.
    private func acceptSubmission(_ item: ChatRecord, view: SessionDisplay, store: MetadataStore, steer: Bool) -> Submission {
        let attachments = view.attachments, skills = view.skills, directCommand = view.directCommand
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString
        // Authorization is read before anything suspends. A chat whose
        // connection is already gone refuses the message where it was typed:
        // nothing shows as sent, and the draft stays in the composer.
        let connection = Result { try connectionLease(for: item) }
        let accepted = (try? connection.get()) != nil
        // A new message is drawn on Return, in the place the helper's row for
        // it will take. A steer, or a follow-up to a run that is going, shows
        // in the queue panel once the helper has it, as it always has.
        let drawsRow = accepted && !steer && !view.busy
        view.beginContextSubmission(turnID)
        view.loading = true
        view.sendFailure = nil
        // The composer empties on Return, not when the helper answers. If the
        // send fails, the text comes back with its images and skills.
        if accepted {
            view.draft = ""; view.attachments = []; view.skills = []; view.directCommand = false
            if drawsRow {
                var row = TranscriptMessage(id: turnID, role: "user", text: text, state: TranscriptMessage.sendingState,
                                            at: Date().timeIntervalSince1970 * 1000, turn: turnID, taskRootID: turnID)
                // The helper's row names the skills the message used; the row drawn
                // before it does too, or the pills would appear, and the row grow,
                // only at the handover.
                if !skills.isEmpty { row.skills = skills.map(TranscriptSkillUse.init(chip:)) }
                view.showSending(row)
            }
        }
        let named = drawsRow ? nameAfterFirstMessage(item.id, text: text, skills: skills) : nil
        return Submission(item: item, view: view, store: store, steer: steer, text: text, attachments: attachments, skills: skills,
                          directCommand: directCommand, commandID: commandID, turnID: turnID, connection: connection,
                          accepted: accepted, drawsRow: drawsRow, named: named)
    }
    /// Sends the accepted message: the chat's record and the command's durable
    /// record are written, the helper is given the command, and the chat's
    /// title is settled. A message its connection refused stays as the draft.
    private func deliverSubmission(_ submission: Submission, progress: inout SendProgress) async throws {
        let item = submission.item, view = submission.view, store = submission.store, steer = submission.steer
        let text = submission.text, attachments = submission.attachments, skills = submission.skills
        let commandID = submission.commandID, turnID = submission.turnID, connection = submission.connection
        let accepted = submission.accepted, drawsRow = submission.drawsRow
        // A new chat's record is written before anything names it.
        try await materializeChat(item.id)
        sendSteps?("materialized")
        guard accepted else {
            // Preserve the user's draft even when the connection is already missing.
            if !isEphemeral(item.id) { try await store.put(DraftRecord(id: item.id, text: text, attachments: attachments, skills: skills), kind: "draft", id: item.id) }
            _ = try connection.get()
            return
        }
        let lease = try connection.get()
        try requireConnection(lease)
        if let info = side(item.id), info.pending {
            // The message is the draft of the side it creates until its record below replaces it.
            try await publishPendingSide(info, view: view, draft: DraftRecord(id: item.id, text: text, attachments: attachments, skills: skills))
        }
        if !isEphemeral(item.id) {
            // The record that lets a crash flag or recover this
            // message, in one commit with the draft that no longer
            // holds it. It is written while the helper is reached, and
            // the command goes out only once it is on disk.
            let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent",
                                       epoch: hosts[item.workspaceID].flatMap { $0.isReady ? $0.epoch : nil }, attachments: attachments, skills: skills)
            let draft = view.savedDraft
            progress.recording = Task { try await store.recordSubmission(intent, draft: draft) }
        }
        let host = try await open(item)
        sendSteps?("opened")
        if let recording = progress.recording { try await recording.value; pendingIntentsChanged(item.id) }
        sendSteps?("durable")
        try requireConnection(lease)
        progress.dispatched = true
        // A new message shows the run starting at once. A steer joins
        // a run that is already showing, and may reach the helper
        // after it ended: it never puts "running" up itself.
        if !steer, !view.busy { progress.shown = (.running, view.runState); view.runState = .running }
        sendSteps?("dispatched")
        let reply = try await host.request(steer ? "turn.steer" : "turn.submit", sessionID: item.id,
                                           params: turnOverrides(for: item, base: ["text": .string(text), "clientTurnId": .string(turnID), "attachments": .array(attachments.map(\.wire)), "skills": .array(skills.map(\.wire))]), commandID: commandID)
        sendSteps?("submitted")
        // A run this chat had not shown yet was going: the helper
        // queued the message behind it, and the queue panel shows it.
        if reply.object?["queued"]?.bool == true { view.dropSending(turnID) }
        view.acknowledgeContextSubmission(turnID)
        // The helper's own row for the message comes with its next snapshot.
        if drawsRow { refresh(item.id) }
        if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID); pendingIntentsChanged(item.id) }
        sendSteps?("acknowledged")
        try await titleAfterSending(submission)
        sendSteps?("titled")
        // A follow-up or a steer: the turn is what the reader wants to
        // see, wherever they had scrolled. A new message did this on Return.
        if !drawsRow { followSubmittedTurn(item.id) }
    }
    /// Once the helper has the message, the chat's title is settled: a name
    /// given on Return is kept, a chat still on its placeholder title asks
    /// for a generated one, and a title an earlier quit cut off is asked for again.
    private func titleAfterSending(_ submission: Submission) async throws {
        let item = submission.item, store = submission.store, text = submission.text, skills = submission.skills, named = submission.named
        var titled = false
        if let index = chats.firstIndex(where: { $0.id == item.id }), chats[index].titleWasEdited != true, chats[index].titleWasGenerated != true {
            if let named {
                // Named on Return; the name is kept now that the helper has the message.
                if chats[index].title == named {
                    try await store.put(chats[index], kind: "chat", id: item.id)
                    scheduleTitleGeneration(sourceID: item.id, input: text); titled = true
                }
            } else if chats[index].title == ChatRecord.defaultTitle || (chats[index].parentSessionID != nil && chats[index].title.hasSuffix(SideRecord.titleSuffix)) {
                if chats[index].title == ChatRecord.defaultTitle {
                    chats[index].title = Self.firstMessageTitle(text, skills: skills); try await store.put(chats[index], kind: "chat", id: item.id)
                }
                scheduleTitleGeneration(sourceID: item.id, input: text); titled = true
            }
        }
        // A title an earlier quit interrupted is asked for again on the next
        // send that does not ask for one itself.
        if !titled { resumeInterruptedTitle(item.id) }
    }
    /// A send that failed: the message goes back where it was typed, its
    /// record goes unless the helper may have acted on it, and the chat's
    /// state is set from what is known of the outcome.
    private func recoverFailedSubmission(_ submission: Submission, from error: Error, progress: SendProgress) async {
        let item = submission.item, view = submission.view, store = submission.store, steer = submission.steer
        let text = submission.text, attachments = submission.attachments, skills = submission.skills, directCommand = submission.directCommand
        let commandID = submission.commandID, turnID = submission.turnID, accepted = submission.accepted, named = submission.named
        let dispatched = progress.dispatched, recording = progress.recording, shown = progress.shown
        @MainActor func undoShownState() { if let shown, view.runState == shown.state { view.runState = shown.replaced } }
        sendSteps?("failed")
        view.rejectContextSubmission(turnID)
        // The message leaves the transcript and goes back where it was typed.
        view.dropSending(turnID)
        if let named, let index = chats.firstIndex(where: { $0.id == item.id }), chats[index].title == named {
            chats[index].title = ChatRecord.defaultTitle
            let reverted = chats[index]
            if !pendingChatIDs.contains(item.id) { try? await store.put(reverted, kind: "chat", id: item.id) }
        }
        let rejection: String? = { if case HostError.rejected(let code, _) = error { return code }; return nil }()
        // The failure sits in the conversation, under the messages, not in a fixed strip.
        // A chat at its cost limit refuses a message where it was typed:
        // the notice says so and offers to raise the limit. Its code
        // goes first, so the row is drawn once, as that notice.
        if rejection == SessionDisplay.costLimitCode { view.sendFailureCode = rejection }
        if rejection == "not_running", steer {
            view.sendFailure = "The run finished. Press Return to send this as a new message."
        } else { view.sendFailure = error.localizedDescription }
        if accepted { restoreUnsent(view, text: text, attachments: attachments, skills: skills, directCommand: directCommand) }
        let draft = accepted && !isEphemeral(item.id) ? view.savedDraft : nil
        if rejection != nil || !dispatched {
            // The helper never acted on it: its record goes, in the
            // same commit as the draft that holds the text again.
            _ = try? await recording?.value
            try? await store.withdrawSubmission(sessionID: item.id, commandID: commandID, draft: draft); pendingIntentsChanged(item.id)
        } else if let draft {
            // Its outcome is unknown: the record stays to say so, and
            // the text is back in the draft as well.
            try? await store.put(draft, kind: "draft", id: item.id)
        }
        if let rejection {
            // The helper refused it, so nothing new is running. The
            // state it had when this was pressed may be long gone (a
            // steer that lost the race with the end of the run found
            // "running"); the helper's own snapshot says what it is.
            if rejection == "connection_unavailable" { view.runState = .interrupted } else { undoShownState(); refresh(item.id) }
        } else if dispatched { view.uncertain = true; view.runState = .interrupted }
        else { undoShownState() }
    }
    /// A chat still called "New chat" is named after its first message as
    /// that message is sent, so its sidebar row says what it is at once.
    private func nameAfterFirstMessage(_ id: String, text: String, skills: [SkillChip]) -> String? {
        guard let index = chats.firstIndex(where: { $0.id == id }), chats[index].titleWasEdited != true,
              chats[index].titleWasGenerated != true, chats[index].title == ChatRecord.defaultTitle else { return nil }
        let title = Self.firstMessageTitle(text, skills: skills)
        chats[index].title = title
        return title
    }
    static func firstMessageTitle(_ text: String, skills: [SkillChip]) -> String {
        String((text.isEmpty ? skills.map { "/" + $0.name }.joined(separator: " ") : text).prefix(60)).replacingOccurrences(of: "\n", with: " ")
    }
    /// A message that could not be sent goes back into its composer: its
    /// text, images and skills, ahead of anything typed since.
    func restoreUnsent(_ view: SessionDisplay, text: String, attachments: [AttachmentRecord], skills: [SkillChip], directCommand: Bool) {
        if view.draft.isEmpty && view.attachments.isEmpty && view.skills.isEmpty {
            view.draft = text; view.attachments = attachments; view.skills = skills; view.directCommand = directCommand
        } else {
            view.draft = text + (text.isEmpty || view.draft.isEmpty ? "" : "\n\n") + view.draft
            view.attachments = attachments + view.attachments.filter { !attachments.contains($0) }
            view.skills = skills + view.skills.filter { chip in !skills.contains { $0.id == chip.id } }
            view.directCommand = false
        }
        draftChanged(view)
    }
    func action(_ method: String, params: [String: WireValue] = [:], sessionID: String? = nil) {
        guard !installPreparing, let id = sessionID ?? selectedID, let item = record(id) else { return }
        // Nothing runs in an archived chat; stopping is the one command it still takes.
        guard !item.isArchived || method == "turn.stop" else { displays[id]?.notice = Self.archivedNotice; return }
        // Compact uses the same selected model/effort/limits as Send. Freeze
        // the originating pane's choice before opening or awaiting its helper.
        let requestParams = method == "context.compact" ? turnOverrides(for: item, base: params) : params
        let commandID = UUID().uuidString
        Task { do {
            let lease = try connectionLease(for: item)
            let host = try await open(item)
            if method == "context.compact" && !isEphemeral(item.id) {
                guard let store else { throw StoreError.unavailable }
                try await store.put(CommandIntent(id: commandID, sessionID: item.id, turnID: "compaction:\(commandID)", text: "[Compact now]", state: "intent", epoch: host.epoch), kind: "pending:\(item.id)", id: commandID)
                pendingIntentsChanged(item.id)
            }
            try requireConnection(lease)
            _ = try await host.request(method, sessionID: item.id, params: requestParams, commandID: commandID)
            if method == "queue.remove", let turnID = params["turnId"]?.string {
                for intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { try await store?.remove(kind: "pending:\(item.id)", id: intent.id) }
                pendingIntentsChanged(item.id)
            }
            if method == "queue.update", let turnID = params["turnId"]?.string, let text = params["text"]?.string, !isEphemeral(item.id) {
                // A recovered intent shows the text the host will actually deliver.
                for var intent in try await store?.list(CommandIntent.self, kind: "pending:\(item.id)") ?? [] where intent.turnID == turnID { intent.text = text; try await store?.put(intent, kind: "pending:\(item.id)", id: intent.id) }
                pendingIntentsChanged(item.id)
            }
            refresh(item.id)
        }
            catch {
                // A rejected compaction never ran; a leftover intent would mark
                // the chat "outcome uncertain" on its next visit.
                if method == "context.compact", case HostError.rejected = error { try? await store?.remove(kind: "pending:\(item.id)", id: commandID); pendingIntentsChanged(item.id) }
                self.error = error.localizedDescription
            } }
    }
    /// `userInitiated` is the Stop button, the live bar and ⌘. — a press that
    /// has to resolve what is on screen even when there is no helper left to
    /// ask. Callers that merely forward a stop (archiving a chat, say) pass
    /// false: they must not invent an interruption for a run they cannot see.
    func stop(sessionID: String? = nil, userInitiated: Bool = true) {
        guard let id = sessionID ?? selectedID, let item = record(id), let view = displays[id] else { return }
        // Nothing is running and nothing is queued: there is nothing to stop.
        // Asking anyway showed "Stopping" and left the chat "Paused".
        guard view.hasWork else { return }
        guard let host = hosts[item.workspaceID], opened.contains(item.id) else {
            // The helper that was running this chat is gone (it crashed, was
            // unloaded, or its project was closed). Doing nothing would leave
            // the live bar and its Stop button up with nothing behind them.
            guard userInitiated, view.busy else { return }
            view.runState = .interrupted; view.runStatus = "interrupted"; view.settleInterruptedRows()
            view.notice = "The helper is no longer running this chat, so there was nothing left to stop. Send again to start a new command."
            return
        }
        view.runState = .stopping
        Task { do { _ = try await host.request("turn.stop", sessionID: item.id); refresh(item.id) }
            catch { view.runState = .interrupted; view.uncertain = true; view.notice = error.localizedDescription } }
    }
}

/// A message as it was when Return was pressed: what the helper is sent,
/// and what goes back to the composer if the send fails.
private struct Submission {
    let item: ChatRecord
    let view: SessionDisplay
    let store: MetadataStore
    let steer: Bool
    let text: String
    let attachments: [AttachmentRecord]
    let skills: [SkillChip]
    let directCommand: Bool
    let commandID: String
    let turnID: String
    /// The chat's connection as it was on Return, or why it was gone.
    let connection: Result<WorkspaceModel.ConnectionLease, Error>
    /// The connection was there: the composer emptied, and the message went ahead.
    let accepted: Bool
    /// The message was drawn in the transcript on Return.
    let drawsRow: Bool
    /// The title this message gave its chat on Return.
    let named: String?
}

/// How far a send got, so that a failure undoes no more than it did.
private struct SendProgress {
    /// The command is going to the helper: a failure from here, unless the
    /// helper refused it, leaves its outcome unknown.
    var dispatched = false
    /// The durable record of this submission, while it is written.
    var recording: Task<Void, Error>?
    /// The state this send put up before the helper answered, and the
    /// one it replaced. Only that write is ever undone, and only while
    /// it is still showing: a snapshot may have moved the chat on since.
    var shown: (state: RunState, replaced: RunState)?
}
