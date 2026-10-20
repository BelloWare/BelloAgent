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
        if view.editPreparing { return "Loading the complete original input…" }
        if view.editSubmitting || view.loading || installPreparing { return "Waiting for the current operation to finish." }
        if view.busy || !view.queue.isEmpty || view.queueCount > 0 { return "Wait for the current run and queue to finish before resending an edited message." }
        if view.editInputReviewRequired { return "Original skill or image selections were not recorded. Review and reselect them, or choose Use text only." }
        if view.attachments.contains(where: { view.editMissingAttachments.contains($0.id) }) { return "An original attachment is missing or changed. Replace or remove its chip." }
        return nil
    }
    /// Always resolve the retained occurrence, not the three-turn display or a
    /// truncated row. Entering edit mode has no conversation mutations.
    func editMessage(_ messageID: String, sessionID: String) {
        guard let view = displays[sessionID], let item = record(sessionID), !item.isSubagent else { return }
        if let shown = view.messages.first(where: { $0.id == messageID }), shown.role != "user" || shown.kind != nil || shown.isStreaming { return }
        if let reason = editEntryBlocker(view) { view.notice = reason; view.editNotice = reason; return }
        let generation = UUID(), draft = view.savedDraft
        let focusOrigin = focusedSessionID ?? selectedID
        let focus = QueueEditFocus(self, view)
        view.editGeneration = generation; view.editPreparing = true; view.editNotice = "Loading the complete original input…"
        let outputUse = beginToolOutputUse(.messageEdit)
        Task {
            defer { finishToolOutputUse(outputUse) }
            defer { if view.editGeneration == generation { view.editPreparing = false } }
            do {
                try await prepareToolOutputUse(outputUse)
                let result: [String: WireValue]
                if let editTargetRead { result = try await editTargetRead(sessionID, messageID) }
                else if let host = hosts[item.workspaceID], opened.contains(sessionID) {
                    var prepared = try await host.request("session.edit.prepare", sessionID: sessionID, params: ["messageId": .string(messageID)]).object ?? [:]
                    var full = prepared["text"]?.string ?? "", next = prepared["next"]?.nonnegativeInteger
                    let total = prepared["totalCharacters"]?.nonnegativeInteger ?? (full as NSString).length
                    guard total <= SubmissionLimits.messageBytes else { throw HostError.failure("The original input exceeds the editor limit.") }
                    while let offset = next {
                        guard view.editGeneration == generation, view.draft == draft.text else { return }
                        guard offset == (full as NSString).length, offset < total else { throw HostError.failure("Edit preparation did not advance.") }
                        let page = try await host.request("session.edit.prepare", sessionID: sessionID,
                            params: ["messageId": .string(messageID), "offset": .number(Double(offset)), "sourceTimeline": prepared["sourceTimeline"] ?? .null, "sourceTextDigest": prepared["sourceTextDigest"] ?? .null]).object ?? [:]
                        guard let part = page["text"]?.string, !part.isEmpty, page["totalCharacters"]?.nonnegativeInteger == total,
                              page["sourceTimeline"] == prepared["sourceTimeline"], page["sourceTextDigest"] == prepared["sourceTextDigest"] else { throw HostError.failure("The original input changed during preparation.") }
                        full += part; guard full.utf8.count <= SubmissionLimits.messageBytes else { throw HostError.failure("The original input exceeds the editor limit.") }
                        next = page["next"]?.nonnegativeInteger
                    }
                    guard (full as NSString).length == total else { throw HostError.failure("The original input is incomplete.") }
                    prepared["text"] = .string(full); result = prepared
                } else {
                    guard let path = item.path else { throw HostError.failure("The original message has no retained journal.") }
                    result = try await history.editTarget(path: path, id: messageID)
                }
                guard view.editGeneration == generation, view.savedDraft == draft else { return }
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
                guard view.editGeneration == generation, view.savedDraft == draft else { return }
                if view.editingMessageID == nil { view.draftBeforeEdit = draft; view.submissionReviews = [] }
                view.editingMessageID = messageID; view.editSourceTimeline = result["sourceTimeline"]?.string; view.editSourceTextDigest = result["sourceTextDigest"]?.string
                view.draft = text; view.attachments = attachments; view.skills = skills; view.editMissingAttachments = missing
                view.editInputReviewRequired = result["legacyInputs"]?.bool ?? false
                view.directCommand = false; view.completionVisible = false; view.editNotice = "Context inspection shows the current unedited branch until Send."
                if (focusedSessionID ?? selectedID) == focusOrigin, focusOrigin == sessionID, focus.holds(self) { focusedSessionID = sessionID; view.composerFocusRequest += 1 }
                draftChanged(view)
            } catch {
                guard view.editGeneration == generation, view.savedDraft == draft else { return }
                view.editNotice = error.localizedDescription; view.notice = "The complete message could not be loaded for editing: " + error.localizedDescription
            }
        }
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
        let attachments = view.attachments, skills = view.skills
        let text = view.draft, commandID = UUID().uuidString, turnID = UUID().uuidString
        let intent = CommandIntent(id: commandID, sessionID: item.id, turnID: turnID, text: text, state: "intent",
                                   epoch: hosts[item.workspaceID].flatMap { $0.isReady ? $0.epoch : nil }, attachments: attachments, skills: skills, draftReviewTracked: true)
        view.draftVersion.preservingSubmission(intent)
        // An edit stays in the composer while the helper replies. Its saved
        // copy needs the same review gate as a normal send returned on failure.
        view.submissionReviews.insert(commandID)
        let savedDraft = view.savedDraft, write = store.draftWriter.capture(view.id)
        var params = turnOverrides(for: item, base: Self.editTurnParams(messageID: messageID, text: text, turnID: turnID, attachments: attachments, skills: skills))
        if let timeline = view.editSourceTimeline { params["editSourceTimeline"] = .string(timeline) }
        if let digest = view.editSourceTextDigest { params["editSourceTextDigest"] = .string(digest) }
        let generation = view.editGeneration
        let archiveRevision = archiveRevisions[id, default: 0]
        latestVersion(sessionID: id)
        view.loading = true; view.editSubmitting = true
        view.submittingCommands.insert(commandID)
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
                        view.editSourceTimeline = nil; view.editSourceTextDigest = nil
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
                if !isEphemeral(item.id) { try await store.acknowledgeCommand(sessionID: item.id, commandID: commandID); pendingIntentsChanged(item.id) }
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

/// An edit on its way to the helper: the branch the page held when it was
/// sent, the question it replaces and the turn that replaces it.
struct PendingBranch: Equatable, Sendable {
    var from: String?
    var messageID: String
    var turnID: String
}
