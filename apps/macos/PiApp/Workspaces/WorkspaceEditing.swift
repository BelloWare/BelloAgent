import AppKit

// Edit-and-resend (contract H4) and the per-message details entry point.
// The composer switches into edit mode for one user message; Send then issues
// `turn.edit` with the same draft/intent/receipt bookkeeping as `send()`.
extension WorkspaceModel {
    nonisolated static let editTurnMethod = "turn.edit"

    /// Parameters for `turn.edit` exactly as the host contract defines them.
    nonisolated static func editTurnParams(messageID: String, text: String, turnID: String, attachments: [AttachmentRecord], skills: [SkillChip], model: String? = nil, thinkingLevel: String? = nil) -> [String: WireValue] {
        var params: [String: WireValue] = ["messageId": .string(messageID), "text": .string(text), "clientTurnId": .string(turnID),
                                           "attachments": .array(attachments.map(\.wire)), "skills": .array(skills.map(\.wire))]
        if let model = TurnOverrides.normalizedModel(model) { params["model"] = .string(model) }
        if let thinkingLevel, ["default", "off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(thinkingLevel) { params["thinkingLevel"] = .string(thinkingLevel) }
        return params
    }
    /// Per-chat model/thinking overrides (contract H6, `ChatRecord.model` /
    /// `ChatRecord.thinkingLevel`) read through Codable so this compiles both
    /// before and after another change adds those stored properties.
    nonisolated static func turnOverrides<Record: Encodable>(_ item: Record) -> (model: String?, thinkingLevel: String?) {
        guard let data = try? JSONEncoder().encode(item), let object = try? JSONDecoder().decode([String: WireValue].self, from: data) else { return (nil, nil) }
        return (object["model"]?.string, object["thinkingLevel"]?.string)
    }

    /// A message's Details: the Session Inspector at the request it came from,
    /// or at its turn.
    func showMessageDetail(_ sessionID: String, messageID: String) {
        openInspector(session: sessionID, focus: .message(messageID))
    }

    /// Entering an edit is read-only; active work can finish while the user
    /// prepares a replacement. Sending additionally requires an empty queue.
    func editEntryBlocker(_ view: SessionDisplay) -> String? {
        if draftWrites.recoveries[view.id] != nil { return "Wait for the interrupted submission to finish saving." }
        guard let item = record(view.id) else { return "This conversation is unavailable." }
        if item.imported { return "Imported originals are read-only. Continue as a separate chat before editing." }
        if item.isArchived { return WorkspaceModel.archivedNotice }
        if isEphemeral(view.id) { return "Keep this side chat before editing its messages." }
        if view.editSubmitting { return "Waiting for the edit acknowledgement." }
        if view.queueEditingID != nil { return "Save or cancel the queued message you are rewriting first." }
        return nil
    }
    /// Eligibility is shared by the composer button, keyboard and send path.
    func editBlocker(_ view: SessionDisplay) -> String? {
        if let reason = editEntryBlocker(view) { return reason }
        if view.editPreparing { return Self.editLoadingNotice }
        if view.editInputPending { return "The complete original input could not be loaded. Cancel, or choose Edit on the message again." }
        if view.editSubmitting || view.loading || installPreparing { return "Waiting for the current operation to finish." }
        if view.busy || !view.queue.isEmpty || view.queueCount > 0 { return "Wait for the current run and queue to finish before resending an edited message." }
        if view.editInputReviewRequired { return "Original skill or image selections were not recorded. Review and reselect them, or choose Use text only." }
        if view.attachments.contains(where: { view.editMissingAttachments.contains($0.id) }) { return "An original attachment is missing or changed. Replace or remove its chip." }
        return nil
    }
    static let editLoadingNotice = "Loading the complete original input…"
    /// Always resolve the retained occurrence, not the three-turn display or a
    /// truncated row. Entering edit mode has no conversation mutations.
    ///
    /// A question on screen goes into the composer at once (`editOpening`):
    /// its row is its whole text. Its complete original — the images and
    /// skills it was sent with, and the timeline and text Send is checked
    /// against — is read behind it, and Send waits for that read
    /// (`editPreparing`, then `editInputPending` if it failed). The first
    /// read of a long chat's original replays its whole journal, in the
    /// helper or here: seconds, with the question already on screen (EDIT-1).
    func editMessage(_ messageID: String, sessionID: String) {
        guard let view = displays[sessionID], let item = record(sessionID), !item.isSubagent else { return }
        let shown = view.messages.first(where: { $0.id == messageID })
        if let shown, shown.role != "user" || shown.kind != nil || shown.isStreaming { return }
        if let reason = editEntryBlocker(view) { view.notice = reason; view.editNotice = reason; return }
        // Edit again on the message whose original is still unread (its read
        // failed, or is still going): it is read again behind the composer,
        // which keeps what was typed and added since.
        if view.editingMessageID == messageID, view.editInputPending {
            if (focusedSessionID ?? selectedID) == sessionID { focusedSessionID = sessionID; view.composerFocusRequest += 1 }
            resumeEditPreparation(view, shown: shown.flatMap(Self.editOpening))
            return
        }
        let generation = UUID(), attempt = UUID(), draft = view.savedDraft
        let focusOrigin = focusedSessionID ?? selectedID
        let focus = QueueEditFocus(self, view)
        view.editGeneration = generation; view.editPreparation = attempt; view.editPreparing = true; view.editNotice = Self.editLoadingNotice
        let outputUse = beginToolOutputUse(.messageEdit)
        // The draft an edit sets aside must be the chat's own: until its
        // saved draft is read, the question waits for its original as before.
        let opening = view.selectionMetadataLoaded ? shown.flatMap(Self.editOpening) : nil
        if let opening {
            beginEdit(messageID, in: view, settingAside: draft)
            view.draft = opening; view.attachments = []; view.skills = []; view.editInputPending = true
            if focusOrigin == sessionID { focusedSessionID = sessionID; view.composerFocusRequest += 1 }
            draftChanged(view)
        }
        messageEditStep?(opening == nil ? "begin" : "shown")
        Task {
            defer { finishToolOutputUse(outputUse) }
            defer { if view.editGeneration == generation, view.editPreparation == attempt { view.editPreparing = false } }
            // A composer that took the question keeps what is typed in it;
            // one still waiting takes the original only over the draft it had.
            let current = { view.editGeneration == generation && view.editPreparation == attempt && (opening != nil || view.savedDraft == draft) }
            do {
                try await prepareToolOutputUse(outputUse)
                messageEditStep?("outputs")
                guard let original = try await readEditOriginal(item, messageID: messageID, current: current), current() else { messageEditStep?("dropped"); return }
                if opening != nil { adoptEditOriginal(original, shown: opening, into: view) }
                else {
                    beginEdit(messageID, in: view, settingAside: draft)
                    view.draft = original.text; view.attachments = original.attachments; view.skills = original.skills
                    adoptEditChecks(original, into: view)
                    if (focusedSessionID ?? selectedID) == focusOrigin, focusOrigin == sessionID, focus.holds(self) { focusedSessionID = sessionID; view.composerFocusRequest += 1 }
                    draftChanged(view)
                }
                messageEditStep?("applied")
            } catch {
                messageEditStep?("failed: " + error.localizedDescription)
                guard current() else { return }
                view.editNotice = error.localizedDescription; view.notice = "The complete message could not be loaded for editing: " + error.localizedDescription
            }
        }
    }
    /// An edit whose original is unread — one a restart brought back while
    /// it was still loading (`MessageEditDraft.inputPending`), or one whose
    /// read failed and Edit was chosen again: its text is the reader's, and
    /// its images, skills and checks are read again before Send takes it.
    /// `shown`: the question's row as it reads now, when it is on screen.
    func resumeEditPreparation(_ view: SessionDisplay, shown: String? = nil) {
        guard view.editInputPending, let messageID = view.editingMessageID, let item = record(view.id), !item.isSubagent else { return }
        // The same edit, read again: its generation stays (an image import
        // into it keeps its place), and only this read is current.
        let generation = view.editGeneration, attempt = UUID()
        view.editPreparation = attempt; view.editPreparing = true
        let outputUse = beginToolOutputUse(.messageEdit)
        Task {
            defer { finishToolOutputUse(outputUse) }
            defer { if view.editGeneration == generation, view.editPreparation == attempt { view.editPreparing = false } }
            let current = { view.editGeneration == generation && view.editPreparation == attempt && view.editingMessageID == messageID }
            do {
                try await prepareToolOutputUse(outputUse)
                guard let original = try await readEditOriginal(item, messageID: messageID, current: current), current() else { return }
                adoptEditOriginal(original, shown: shown, into: view)
            } catch {
                guard current() else { return }
                view.notice = "The complete message could not be loaded for editing: " + error.localizedDescription
            }
        }
    }
    /// The text a user row on screen stands for, when it is the whole
    /// question as it was sent: a row of the timeline shown, not cut, and
    /// not the label an image-only message wears ("Image", "3 images").
    nonisolated static func editOpening(_ row: TranscriptMessage) -> String? {
        guard row.role == "user", row.kind == nil, !row.isStreaming, row.truncated != true, row.earlierVersion != true,
              !row.text.isEmpty, row.text.utf8.count <= SubmissionLimits.messageBytes else { return nil }
        let images = row.text == TranscriptMessage.imageOnlyText(1) ? 1 : row.text.hasSuffix(" images") ? Int(row.text.dropLast(7)) : nil
        return images.map(TranscriptMessage.imageOnlyText) == row.text ? nil : row.text
    }
    /// The composer turns to `messageID`: the draft it held is set aside for
    /// Cancel (once, however many edits follow it), and none of a draft's
    /// own state stays.
    private func beginEdit(_ messageID: String, in view: SessionDisplay, settingAside draft: DraftRecord) {
        if view.editingMessageID == nil { view.draftBeforeEdit = draft; view.submissionReviews = [] }
        view.editingMessageID = messageID; view.editSourceTimeline = nil; view.editSourceTextDigest = nil; view.editSourcePrefix = nil
        view.editMissingAttachments = []; view.editInputReviewRequired = false; view.editInputPending = false
        view.directCommand = false; view.completionVisible = false
    }
    /// The complete original arriving under the question the composer took
    /// at once (`shown`; nil for an edit a restart brought back). What was
    /// typed since stays, and so does an image or a skill added since, after
    /// the original's own. Untouched, the composer takes the original's text.
    /// A chip the composer holds wins over the original's of the same id: a
    /// skill chosen again meanwhile keeps the arguments it was given.
    private func adoptEditOriginal(_ original: EditOriginal, shown: String?, into view: SessionDisplay) {
        let typed = view.draft != (shown ?? original.text)
        if !typed { view.draft = original.text }
        let attachments = view.attachments, skills = view.skills
        let originalAttachments = Set(original.attachments.map(\.id)), originalSkills = Set(original.skills.map(\.id))
        view.attachments = original.attachments.map { item in attachments.first { $0.id == item.id } ?? item } + attachments.filter { !originalAttachments.contains($0.id) }
        view.skills = original.skills.map { chip in skills.first { $0.id == chip.id } ?? chip } + skills.filter { !originalSkills.contains($0.id) }
        adoptEditChecks(original, into: view)
        if typed, let shown, shown != original.text { view.editNotice = "The original message differs from its row as shown. Review the text before sending." }
        draftChanged(view)
    }
    /// What Send checks an edit against, and what it needs reviewed first.
    private func adoptEditChecks(_ original: EditOriginal, into view: SessionDisplay) {
        view.editSourceTimeline = original.sourceTimeline; view.editSourceTextDigest = original.sourceTextDigest
        view.editSourcePrefix = original.sourcePrefix
        view.editMissingAttachments = original.missing; view.editInputReviewRequired = original.legacyInputs
        view.editInputPending = false
        view.editNotice = "Context inspection shows the current unedited branch until Send."
        // A Send pressed while the original loaded said so; that is over.
        if view.notice == Self.editLoadingNotice { view.notice = "" }
    }
    /// The complete original of a message being edited: its text, the images
    /// and skills it was sent with, which of those images are no longer as
    /// they were, and the timeline and text Send is checked against. The
    /// helper reads it when the chat is open there, the journal otherwise. A
    /// read that met rows written meanwhile — a run going on while the helper
    /// loaded the whole history — is made again, and finds them loaded. Nil
    /// once `current` stops holding.
    private func readEditOriginal(_ item: ChatRecord, messageID: String, current: () -> Bool) async throws -> EditOriginal? {
        var read: [String: WireValue]?, attempt = 0
        while read == nil {
            attempt += 1
            do {
                guard let result = try await readEditTarget(item, messageID: messageID, current: current) else { return nil }
                read = result
            } catch HostError.rejected(let code, _) where attempt < 3 && ["edit_changed", "history_changed"].contains(code) {
                guard current() else { return nil }
            }
        }
        messageEditStep?("read")
        guard let result = read, current() else { return nil }
        guard result["messageId"]?.string == messageID, let text = result["text"]?.string, text.utf8.count <= SubmissionLimits.messageBytes else { throw HostError.failure("The complete original input is unavailable.") }
        let input = result["input"]?.object
        guard input == nil || input?["version"]?.number == 1 else { throw HostError.failure("Update Bello Agent to edit this input format.") }
        let attachments = try input?["attachments"].map { try JSONDecoder().decode([AttachmentRecord].self, from: JSONEncoder().encode($0)) } ?? []
        let skills = try input?["skills"].map { try JSONDecoder().decode([SkillChip].self, from: JSONEncoder().encode($0)) } ?? []
        let missing = await Task.detached(priority: .userInitiated) {
            Set(attachments.filter { original in
                guard let actual = try? AttachmentRecord.inspect(URL(fileURLWithPath: original.path)) else { return true }
                return actual.sha256 != original.sha256 || actual.bytes != original.bytes
            }.map(\.id))
        }.value
        messageEditStep?("inspected")
        return EditOriginal(text: text, attachments: attachments, skills: skills, missing: missing, sourceTimeline: result["sourceTimeline"]?.string,
                            sourceTextDigest: result["sourceTextDigest"]?.string, sourcePrefix: result["sourcePrefix"]?.string,
                            legacyInputs: result["legacyInputs"]?.bool ?? false)
    }
    /// One read of the original: page by page from the helper, or from the
    /// journal. Nil when `current` stops holding between pages.
    private func readEditTarget(_ item: ChatRecord, messageID: String, current: () -> Bool) async throws -> [String: WireValue]? {
        let sessionID = item.id
        if let editTargetRead { return try await editTargetRead(sessionID, messageID) }
        if let host = hosts[item.workspaceID], opened.contains(sessionID) {
            messageEditStep?("read:helper")
            var prepared = try await host.request("session.edit.prepare", sessionID: sessionID, params: ["messageId": .string(messageID)]).object ?? [:]
            var full = prepared["text"]?.string ?? "", next = prepared["next"]?.nonnegativeInteger
            let total = prepared["totalCharacters"]?.nonnegativeInteger ?? (full as NSString).length
            guard total <= SubmissionLimits.messageBytes else { throw HostError.failure("The original input exceeds the editor limit.") }
            while let offset = next {
                guard current() else { return nil }
                guard offset == (full as NSString).length, offset < total else { throw HostError.failure("Edit preparation did not advance.") }
                let page = try await host.request("session.edit.prepare", sessionID: sessionID,
                    params: ["messageId": .string(messageID), "offset": .number(Double(offset)), "sourceTimeline": prepared["sourceTimeline"] ?? .null, "sourceTextDigest": prepared["sourceTextDigest"] ?? .null]).object ?? [:]
                guard let part = page["text"]?.string, !part.isEmpty, page["totalCharacters"]?.nonnegativeInteger == total,
                      page["sourceTimeline"] == prepared["sourceTimeline"], page["sourceTextDigest"] == prepared["sourceTextDigest"] else { throw HostError.failure("The original input changed during preparation.") }
                full += part; guard full.utf8.count <= SubmissionLimits.messageBytes else { throw HostError.failure("The original input exceeds the editor limit.") }
                next = page["next"]?.nonnegativeInteger
            }
            guard (full as NSString).length == total else { throw HostError.failure("The original input is incomplete.") }
            prepared["text"] = .string(full)
            return prepared
        }
        guard let path = item.path else { throw HostError.failure("The original message has no retained journal.") }
        messageEditStep?("read:history")
        return try await history.editTarget(path: path, id: messageID)
    }
    func cancelEdit(sessionID: String) {
        guard let view = displays[sessionID], !view.editSubmitting else { return }
        view.editGeneration = UUID(); view.editPreparing = false
        guard view.editingMessageID != nil else { return }
        finishEdit(view)
    }
    private func finishEdit(_ view: SessionDisplay) {
        let original = view.draftBeforeEdit ?? DraftRecord(id: view.id, text: "")
        view.restoreDraft(original)
        draftChanged(view)
    }
    /// Resends the edited message with `turn.edit`. Preconditions mirror the
    /// host: idle session, empty queue, retained user on the selected timeline.
    func sendEdit(sessionID: String? = nil) {
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), let view = displays[id], view.draftReady, view.imageImports == 0, let messageID = view.editingMessageID, let store else { return }
        if let reason = editBlocker(view) { view.notice = reason; view.editNotice = reason; return }
        guard view.hasSubmittableInput else { view.editNotice = "Enter a replacement message, add an image or select a skill."; return }
        guard !item.imported, !isEphemeral(id) else { view.notice = "Continue or keep this chat before editing its messages."; return }
        guard !item.isArchived else { view.notice = WorkspaceModel.archivedNotice; return }
        guard !view.busy, view.queue.isEmpty, view.queueCount == 0 else { view.notice = "Wait for the current run and queue to finish before resending an edited message."; return }
        guard view.draft.utf8.count <= SubmissionLimits.messageBytes else { error = "The draft exceeds the 256 KiB submission limit"; return }
        if reviewReturnedSubmission(view, retry: { [weak self] in self?.sendEdit(sessionID: id) }) { return }
        if view.uncertain {
            // A sheet on the chat's window, not a modal run loop: the other
            // chats keep streaming while this question waits for an answer.
            if !questions.ask(WorkspaceModel.uncertainOutcome, about: id, answered: { [weak self] reviewed in
                guard let self, reviewed, let view = self.displays[id], view.uncertain else { return }
                view.uncertain = false
                self.sendEdit(sessionID: id)
            }) { view.notice = PiQuestion.busyNotice }
            return
        }
        let owner: String
        do { owner = try inputPublicationOwner() }
        catch { view.editNotice = "The replacement could not be saved locally. " + error.localizedDescription; return }
        let attachments = view.attachments, skills = view.skills
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString
        let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent",
                                   epoch: hosts[item.workspaceID].flatMap { $0.isReady ? $0.epoch : nil }, attachments: attachments, skills: skills, draftReviewTracked: true, submissionOwner: owner)
        view.draftVersion.preservingSubmission(intent)
        // An edit stays in the composer while the helper replies. Its saved
        // copy needs the same review gate as a normal send returned on failure.
        view.submissionReviews.insert(commandID)
        let savedDraft = view.savedDraft, write = store.draftWriter.capture(view.id)
        var params = turnOverrides(for: item, base: Self.editTurnParams(messageID: messageID, text: text, turnID: turnID, attachments: attachments, skills: skills))
        if let timeline = view.editSourceTimeline { params["editSourceTimeline"] = .string(timeline) }
        if let digest = view.editSourceTextDigest { params["editSourceTextDigest"] = .string(digest) }
        // Checked at Send: the conversation through the edited message, so the
        // rows a run added after it since the original was read do not refuse
        // the edit; the message itself and what it branches from still must be
        // as they were. A helper without it checks the whole timeline instead.
        if let prefix = view.editSourcePrefix { params["editSourcePrefix"] = .string(prefix) }
        let generation = view.editGeneration
        let archiveRevision = archiveRevisions[id, default: 0]
        latestVersion(sessionID: id)
        view.loading = true; view.editSubmitting = true
        beginSubmission(commandID, in: view)
        let outputUse = beginToolOutputUse(.messageEdit)
        Task {
            defer { finishSubmission(commandID, in: view) }
            defer { finishToolOutputUse(outputUse) }
            defer { view.loading = false; view.editSubmitting = false }
            var dispatched = false, helperAccepted = false
            // As in `send`: only this resend's own "queued" is ever undone, and
            // only while it is still what the chat shows.
            var shown: (state: RunState, replaced: RunState)?
            @MainActor func undoShownState() { if let shown, view.runState == shown.state { view.runState = shown.replaced } }
            @MainActor func settleRefusedInput() async {
                defer { pendingIntentsChanged(item.id) }
                // A rejection settles execution, not the captured input.
                // Retire it only with a durable draft still holding that input.
                if !view.draftVersion.unsavedSubmissions.contains(where: { $0.id == commandID }),
                   view.draft == text, view.attachments == attachments, view.skills == skills {
                    do {
                        try await store.withdrawSubmission(sessionID: item.id, commandID: commandID, draft: view.savedDraft,
                                                           draftVersion: view.draftVersion, write: store.draftWriter.capture(view.id))
                        view.recovered.removeAll { $0.id == commandID }; if view.recovered.isEmpty { view.uncertain = false }
                        return
                    } catch { view.draftVersion.preservingSubmission(intent) }
                }
                offerSubmissionRecovery(intent, in: view)
            }
            do {
                try await prepareToolOutputUse(outputUse)
                let connection = Result { try connectionLease(for: item) }
                // Newer typing may replace the editor snapshot, never the
                // replacement captured by Resend or its independent intent.
                try await store.recordSubmission(intent, draft: savedDraft, draftVersion: view.draftVersion, write: write)
                pendingIntentsChanged(item.id)
                let lease = try connection.get()
                try requireConnection(lease)
                let host = try await open(item)
                try requireConnection(lease)
                try requireUnarchived(item.id, revision: archiveRevision)
                dispatched = true
                noteChatActivity(item.id)
                if !view.busy { shown = (.queued, view.runState); view.runState = .queued }
                // The branch this makes is the reader's own: the snapshot that
                // first carries it is adopted where they are (`adoptOwnBranch`).
                view.pendingBranch = .init(from: view.presentation.identity?.lineage, messageID: messageID, turnID: turnID)
                _ = try await host.request(Self.editTurnMethod, sessionID: item.id, params: params, commandID: commandID)
                helperAccepted = true
                view.acceptedCommands.insert(commandID)
                view.submissionReviews.remove(commandID)
                view.recovered.removeAll { $0.id == commandID }; if view.recovered.isEmpty { view.uncertain = false }
                view.skillRepins = [:]
                if view.editGeneration == generation, view.editingMessageID == messageID {
                    if view.draft == text, view.attachments == attachments, view.skills == skills { finishEdit(view) }
                    else {
                        // The original occurrence is now abandoned. Keep the
                        // newer edits attached to the accepted replacement so
                        // their next Send can amend it after the run finishes.
                        view.editingMessageID = turnID
                        view.editSourceTimeline = nil; view.editSourceTextDigest = nil; view.editSourcePrefix = nil
                        view.editNotice = "Edit accepted. Your newer changes now edit the replacement. Cancel restores the original unsent draft."
                        draftChanged(view)
                    }
                }
                // A branch still on its way is followed by the snapshot that
                // adopts it, so the rows it abandons never scroll past first.
                // One already adopted, or a page away from the live rows, is
                // followed the way a sent message is.
                if view.pendingBranch?.turnID == turnID, !view.browsingHistory, !view.historyState.loading { refresh(item.id) }
                else { followSubmittedTurn(item.id) }
                if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID, draftVersion: view.draftVersion); pendingIntentsChanged(item.id) }
            } catch {
                if helperAccepted {
                    // The helper made the branch. Local bookkeeping cannot
                    // turn that known acceptance into a retry of the old edit.
                    self.error = "Edit accepted, but its local record could not be saved. \(error.localizedDescription)"
                    refresh(item.id)
                    return
                }
                let rejection: String? = { if case HostError.rejected(let code, _) = error { return code }; return nil }()
                // A skill that changed since it was chosen: the edit is still
                // in the composer, so its chips are put right as a send's are
                // (`refreshRefusedSkills`), and Send confirms the update.
                if let rejection, Self.skillRefusalCodes.contains(rejection), !skills.isEmpty,
                   view.editGeneration == generation, view.editingMessageID == messageID {
                    view.submissionReviews.remove(commandID)
                    if view.pendingBranch?.turnID == turnID { view.pendingBranch = nil }
                    await settleRefusedInput()
                    undoShownState()
                    let refresh = await refreshRefusedSkills(view, sent: skills)
                    if view.editGeneration == generation { view.editNotice = refresh.notice }
                    draftChanged(view)
                    return
                }
                view.notice = error.localizedDescription
                if view.editGeneration == generation { view.editNotice = error.localizedDescription }
                if case HostError.rejected(let code, _) = error, code == "journal_uncertain" { view.uncertain = true; view.runState = .interrupted; offerSubmissionRecovery(intent, in: view) }
                else if case HostError.rejected(let code, _) = error {
                    view.submissionReviews.remove(commandID); draftChanged(view)
                    // Refused: no branch was made.
                    if view.pendingBranch?.turnID == turnID { view.pendingBranch = nil }
                    // At the chat's cost limit the conversation says so, with a way to raise it.
                    if code == SessionDisplay.costLimitCode { view.sendFailureCode = code; view.sendFailure = error.localizedDescription }
                    await settleRefusedInput()
                    if code == "connection_unavailable" { view.runState = .interrupted } else { undoShownState() }
                }
                else if dispatched { view.uncertain = true; view.runState = .interrupted; offerSubmissionRecovery(intent, in: view) }
                else { view.submissionReviews.remove(commandID); draftChanged(view); await settleRefusedInput(); undoShownState() }
            }
        }
    }
}

/// A message's complete original, read for its edit (`readEditOriginal`).
struct EditOriginal {
    var text: String
    var attachments: [AttachmentRecord]
    var skills: [SkillChip]
    /// The original's images that are no longer as they were sent.
    var missing: Set<String>
    var sourceTimeline: String?
    var sourceTextDigest: String?
    /// The timeline through the message (`HistoricalEditPlan.sourcePrefix`).
    var sourcePrefix: String?
    /// Its images or skills were not recorded, so Send needs them reviewed.
    var legacyInputs: Bool
}

/// An edit on its way to the helper: the branch the page held when it was
/// sent, the question it replaces and the turn that replaces it.
struct PendingBranch: Equatable, Sendable {
    var from: String?
    var messageID: String
    var turnID: String
}
