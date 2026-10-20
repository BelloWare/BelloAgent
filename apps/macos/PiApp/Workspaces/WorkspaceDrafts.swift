import Foundation

// Unsent text and reading position, written behind the typing rather than
// during it. Draft writes are debounced per chat, with loaded revisions;
// `flushDrafts()` is what quit and update wait for.

/// The model's debounced draft writes.
struct DraftWrites {
    /// The write of each chat's draft that is waiting or under way.
    var tasks: [String: Task<Void, Never>] = [:]
    /// Which write owns each entry above: a newer write replaces the token
    /// first, so a cancelled write's own cleanup never drops the newer entry.
    var tokens: [String: UUID] = [:]
    /// A draft write has already failed, so the next failure does not repeat
    /// the same banner.
    var failed = false
    /// Recovery owns the draft until its transaction finishes; typing waits
    /// behind it so it cannot save over the recovered message mid-commit.
    var recoveries: [String: Task<Void, Never>] = [:]
}

extension WorkspaceModel {
    /// Selection may abandon its read, but an explicit submission still needs
    /// this reconciliation without taking the reader back to its chat.
    func reconcileSubmissionDraft(_ item: ChatRecord, view: SessionDisplay, current: () -> Bool) async throws -> Bool {
        guard let store else { throw StoreError.unavailable }
        let wantsMetadata = !view.selectionMetadataLoaded, draftAtStart = view.savedDraft
        let metadata = try await store.selectionMetadata(id: view.id, draft: wantsMetadata && !item.isSubagent, anchor: wantsMetadata)
        guard current() else { return false }
        adoptDraftBaseline(metadata, into: view, draftAtStart: draftAtStart)
        if item.isSubagent { view.draftReady = false; return true }
        view.draftConflicts = metadata.conflicts
        let recovered = try await recoverableIntents(metadata.recovered, for: item, view: view)
        guard current() else { return false }
        view.recovered = recovered
        view.uncertain = recovered.contains { intent in !view.draftVersion.unsavedSubmissions.contains { $0.id == intent.id } }
        // Text alone cannot authorize a resend while acceptance is unread.
        view.draftReady = true
        return true
    }
    /// A flush, receipt or side transfer can need the baseline before the
    /// navigation read reaches it. Only the first completed read installs it;
    /// a later completion must not replace a version already used for writing.
    func loadDraftBaseline(_ view: SessionDisplay) async throws {
        guard !view.selectionMetadataLoaded else { return }
        guard let store else { throw StoreError.unavailable }
        let draftAtStart = view.savedDraft
        let metadata = try await store.selectionMetadata(id: view.id, draft: record(view.id)?.isSubagent != true, anchor: true)
        adoptDraftBaseline(metadata, into: view, draftAtStart: draftAtStart)
    }
    func adoptDraftBaseline(_ metadata: MetadataStore.SelectionMetadata, into view: SessionDisplay, draftAtStart: DraftRecord) {
        guard !view.selectionMetadataLoaded else { return }
        if let version = metadata.draftVersion { view.draftVersion = version; view.draftConflicts = metadata.conflicts }
        if let draft = metadata.draft, !view.draftWritePending,
           view.draft == draftAtStart.text && view.attachments == (draftAtStart.attachments ?? []) && view.skills == (draftAtStart.skills ?? []),
           view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil && view.queueEditingID == nil {
            view.restoreDraft(draft); if let queued = draft.queuedEdit { Task { await self.reconcileQueuedEdit(view, queued) } }
        }
        if let version = metadata.anchorVersion { view.anchorVersion = version }
        if !view.anchorWritePending, view.scrollAnchor == nil { view.scrollAnchor = metadata.anchor }
        view.selectionMetadataLoaded = true
        if view.draftWritePending { draftChanged(view) }
        if view.anchorWritePending { anchorChanged(view) }
    }
    /// An acknowledgement may be missing locally after a full disk or crash.
    /// Consult durable helper evidence before exposing any recovery action.
    func recoverableIntents(_ intents: [CommandIntent], for item: ChatRecord, view: SessionDisplay) async throws -> [CommandIntent] {
        let intents = retainingCapturedInput(intents, in: view)
        let unchecked = intents.filter { $0.state == "intent" && !view.acceptedCommands.contains($0.id) }
        // Queue saves have no new turn receipt. After a lost reply, the
        // helper's durable outcome must match this captured text before it
        // can retire the input; a different rewrite leaves it recoverable.
        for intent in unchecked {
            guard let editID = intent.queueEditID,
                  let status = try? await queueEditRequest("queue.edit.status", sessionID: item.id, params: ["editId": .string(editID)]),
                  status["state"]?.string == "saved", status["textDigest"]?.string == QueuedEditDraft.digest(intent.text) else { continue }
            view.acceptedCommands.insert(intent.id)
            try await store?.remove(kind: "pending:" + item.id, id: intent.id)
            pendingIntentsChanged(item.id)
        }
        let path = item.path ?? root.appendingPathComponent("Workspaces/\(item.workspaceID)/Sessions/\(item.id).jsonl").path
        let accepted: Set<String>
        let turns = unchecked.filter { $0.queueEditID == nil }
        if let commandAcceptanceRead { accepted = try await commandAcceptanceRead(path, turns, item.path == nil) }
        else { accepted = try await history.acceptedCommands(in: path, intents: turns, missingIsEmpty: item.path == nil) }
        view.acceptedCommands.formUnion(accepted)
        try await protectReturnedDrafts(intents, view: view)
        let unaccepted = unchecked.filter { !view.acceptedCommands.contains($0.id) }
        // A Resume the helper never took ran nothing and holds no text: its
        // record goes, and the chat still offers Resume.
        let resumes = unaccepted.filter { $0.turnID.hasPrefix(Self.resumeIntentPrefix) }
        if !resumes.isEmpty, let store {
            for intent in resumes { try await store.remove(kind: "pending:\(item.id)", id: intent.id) }
            pendingIntentsChanged(item.id)
        }
        return unaccepted.filter { !$0.turnID.hasPrefix(Self.resumeIntentPrefix) }
    }
    func protectReturnedDrafts(_ intents: [CommandIntent], view: SessionDisplay) async throws {
        let commands = Set(intents.filter { $0.draftReviewTracked != true && !$0.turnID.hasPrefix("compaction:") && !$0.turnID.hasPrefix(Self.resumeIntentPrefix) &&
            (view.acceptedCommands.contains($0.id) || $0.state == "acknowledged") && !view.reconciledSubmissionReviews.contains($0.id) }.map(\.id))
        guard !commands.isEmpty else { return }
        if !isEphemeral(view.id) { try await loadDraftBaseline(view) }
        // Legacy records do not identify which characters came back after a
        // lost reply. Preserve all typing, but require review before resending.
        if view.hasSubmittableInput { view.submissionReviews.formUnion(commands) }
        view.draftBeforeEdit?.requireSubmissionReview(commands)
        view.draftBeforeQueueEdit?.requireSubmissionReview(commands)
        // The marker-only operation reads durable text. Reissue the latest
        // live typing afterward so both the text and its review gate persist.
        defer { if view.selectionMetadataLoaded, !isShutDown, displays[view.id] === view { draftChanged(view) } }
        let previous = draftWrites.tasks[view.id]; previous?.cancel(); await previous?.value
        if !isEphemeral(view.id) {
            guard let store else { throw StoreError.unavailable }
            try await store.preserveSubmissionReviews(sessionID: view.id, commands: commands, draftVersion: view.draftVersion, write: store.draftWriter.capture(view.id))
        }
        // Only a successful marker write allows a terminal receipt to remove
        // the last evidence that the returned draft may already have run.
        view.reconciledSubmissionReviews.formUnion(commands)
    }
    func reviewReturnedSubmission(_ view: SessionDisplay, retry: @escaping @MainActor () -> Void) -> Bool {
        guard !view.submissionReviews.isEmpty else { return false }
        let saved = view.savedDraft
        let question = ChatQuestion(title: "This draft may include a message already sent",
                                    detail: "A previous submission was returned to the composer. Review this draft and the transcript before sending: a new command may repeat file or tool effects.",
                                    action: "I Reviewed It — Send New Command")
        if !questions.ask(question, about: view.id, answered: { [weak self, weak view] reviewed in
            guard let self, let view, self.displays[view.id] === view, reviewed else { return }
            guard view.savedDraft == saved else { view.notice = "The draft changed while review was open. Review it again before sending."; return }
            view.submissionReviews.removeAll(); view.uncertain = false
            self.draftChanged(view); retry()
        }) { view.notice = PiQuestion.busyNotice }
        return true
    }
    func draftChanged(_ view: SessionDisplay) {
        guard record(view.id)?.isSubagent != true else { return }
        guard draftWrites.recoveries[view.id] == nil else { return }
        // Writing a message is the moment to have its helper ready.
        prewarm(view.id)
        scheduleAutomaticContext(view.id, delay: WorkspaceModel.typingPreviewDelay)
        // Unkept side drafts stay in memory by design; on host loss their text
        // is moved into the parent composer instead (discardLostSides).
        guard !isEphemeral(view.id), !pendingChatIDs.contains(view.id) else { return }
        guard view.selectionMetadataLoaded else { view.draftWritePending = true; return }
        view.draftWritePending = false
        let previous = draftWrites.tasks[view.id]; previous?.cancel()
        guard let store else {
            if !draftWrites.failed { draftWrites.failed = true; error = "Draft could not be saved. \(StoreError.unavailable.localizedDescription)" }
            return
        }
        let write = store.draftWriter.capture(view.id)
        // The entry is cleared when this write finishes, and only by the write
        // that owns it: a newer one replaces the token first, so a cancelled
        // task's own cleanup can never drop it.
        let draft = view.savedDraft, id = view.id, token = UUID()
        let outputUse = beginToolOutputUse(.draftWrite)
        draftWrites.tokens[id] = token
        draftWrites.tasks[id] = Task {
            defer { finishToolOutputUse(outputUse) }
            defer { store.draftWriter.finish(write); if draftWrites.tokens[id] == token { draftWrites.tokens.removeValue(forKey: id); draftWrites.tasks.removeValue(forKey: id) } }
            do {
                // Cancellation cannot withdraw a write already in the store.
                // Compare against its committed version, including an undo
                // back to the draft that was originally loaded.
                await previous?.value
                try Task.checkCancellation()
                try await prepareToolOutputUse(outputUse)
                try await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
                try await store.put(draft, kind: "draft", id: draft.id, draftVersion: view.draftVersion, write: write); draftWrites.failed = false
            }
            catch is CancellationError { }
            catch StoreError.staleRevision { /* A newer send, flush or edit already saved this draft. */ }
            catch {
                if error as? StoreError == .draftConflict, let copies = try? await store.draftConflicts(id: view.id) {
                    view.draftConflicts = copies
                }
                // A full disk fails every debounce tick; report it once, not per keystroke.
                guard !draftWrites.failed else { return }
                draftWrites.failed = true; self.error = "Draft could not be saved. \(error.localizedDescription)"
            }
        }
        if let task = draftWrites.tasks[id] { store.draftWriter.cancelOnSupersession(write, task: task) }
    }
    /// Writes every pending draft and anchor now. Quit calls this so the
    /// 150 ms debounce cannot lose the last thing typed; the update path does
    /// the same inside prepareForInstall.
    func flushDrafts() async throws {
        let outputUse = beginToolOutputUse(.draftFlush)
        defer { finishToolOutputUse(outputUse) }
        try await prepareToolOutputUse(outputUse)
        for task in draftWrites.recoveries.values { await task.value }
        let pending = draftWrites.tasks, tokens = draftWrites.tokens
        for task in pending.values { task.cancel() }
        for task in pending.values { await task.value }
        for id in pending.keys where draftWrites.tokens[id] == tokens[id] {
            draftWrites.tasks.removeValue(forKey: id); draftWrites.tokens.removeValue(forKey: id)
        }
        let retained = displays.values.filter { !isEphemeral($0.id) }
        guard !retained.isEmpty else { return }
        guard let store else { throw StoreError.unavailable }
        for view in retained {
            await view.anchorWrite?.value
            // A chat that never sent has no record yet. Writing its draft under
            // that id alone left text nothing would ever list again; skipping it
            // silently threw away what the user had typed. Give the text a chat.
            if pendingChatIDs.contains(view.id) {
                guard !isPendingEmpty(view.id) else { continue }
                try await materializeChat(view.id)
            } else if !view.selectionMetadataLoaded {
                // Untouched displays may still stand for an unread saved
                // draft. Actual typing or scrolling owns a write, even if
                // navigation retired the read that would have hydrated it.
                guard view.hasUnsavedDraft || view.anchorWritePending else { continue }
                try await loadDraftBaseline(view)
            }
            try await store.preserveDraftConflicts(view.draftVersion)
            if record(view.id)?.isSubagent != true { try await store.put(view.savedDraft, kind: "draft", id: view.id, draftVersion: view.draftVersion, write: store.draftWriter.capture(view.id)) }
            try await store.putAnchor(view.scrollAnchor, id: view.id, version: view.anchorVersion, write: store.draftWriter.capture(view.id, payload: .anchor))
        }
    }
    /// Quit and update end every side that was never saved, and a side's
    /// draft is never written under its own id (the side-draft policy). Its
    /// whole unsent draft goes to its parent (`moveSideDraft`): the parent's
    /// composer, which the flush after this saves, or its saved draft. A
    /// failure is thrown with the side's draft left as it was, so quit and
    /// update stop and say so instead of losing it.
    func moveUnsavedSideDraftsToParents() async throws {
        for info in sides.values where info.pending || !info.kept { try await moveSideDraft(info) }
    }
    func anchorChanged(_ view: SessionDisplay) {
        // A reader back at the newest row, or reading within the window's
        // budget again, no longer holds a window their reading stretched.
        // Let go of on the next turn: the page says where the reader is from
        // inside its handling of their scroll, which a new page must not
        // re-enter (`TranscriptPage.reportPendingAnchor`).
        DispatchQueue.main.async { [weak self, weak view] in if let self, let view { self.releaseHeldWindow(view) } }
        guard !isEphemeral(view.id) else { return }
        guard view.selectionMetadataLoaded else { view.anchorWritePending = true; return }
        view.anchorWritePending = false
        guard let store else { return }
        let anchor = view.scrollAnchor, previous = view.anchorWrite
        let write = store.draftWriter.capture(view.id, payload: .anchor)
        view.anchorWrite = Task {
            defer { store.draftWriter.finish(write) }
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await store.putAnchor(anchor, id: view.id, version: view.anchorVersion, write: write)
        }
        if let task = view.anchorWrite { store.draftWriter.cancelOnSupersession(write, task: task) }
    }
    func canRestoreConflictedDraft(_ id: String) -> Bool {
        guard !isShutDown, !installPreparing, let item = record(id), !item.isSubagent, !item.imported,
              let view = displays[id] else { return false }
        return !view.loading && !view.busy && !view.resuming && view.editingMessageID == nil && !view.editPreparing && !view.editSubmitting &&
            view.queueEditingID == nil && view.queueEditBeginning == nil && view.queueEditCancelling == nil && view.unreconciledQueuedEdit == nil && draftWrites.recoveries[id] == nil
    }
    func restoreConflictedDraft(_ conflict: SavedDraftConflict) {
        guard canRestoreConflictedDraft(conflict.draft.id), let view = displays[conflict.draft.id] else { return }
        view.loading = true
        let outputUse = beginToolOutputUse(.draftRecovery)
        draftWrites.recoveries[view.id] = Task {
            defer { finishToolOutputUse(outputUse) }
            defer { view.loading = false; view.recoveringDraft = false; draftWrites.recoveries.removeValue(forKey: view.id); draftChanged(view) }
            let previous = draftWrites.tasks[view.id]; previous?.cancel(); await previous?.value
            do {
                try await prepareToolOutputUse(outputUse)
                guard let store else { throw StoreError.unavailable }
                view.recoveringDraft = true
                let live = view.savedDraft
                try await store.restoreConflict(conflict, replacing: live, version: view.draftVersion, write: store.draftWriter.capture(view.id))
                // Typing is disabled while this explicit recovery commits.
                view.restoreDraft(conflict.draft)
                view.unreconciledQueuedEdit = conflict.draft.queuedEdit
                if let queued = conflict.draft.queuedEdit { await reconcileQueuedEdit(view, queued) }
                view.draftConflicts = try await store.draftConflicts(id: view.id)
                focusComposer(view.id)
            } catch { self.error = "The conflicting draft could not be restored. Its saved copy was kept. \(error.localizedDescription)" }
        }
    }
    /// Until the independent input record commits, the version owns its pin.
    /// Recovery visibility is separate from whether the helper may have acted.
    func offerSubmissionRecovery(_ intent: CommandIntent, in view: SessionDisplay) {
        guard !view.acceptedCommands.contains(intent.id), !view.receipts.contains(where: { $0["commandId"]?.string == intent.id }) else { return }
        if view.submittingCommands.contains(intent.id) { view.settlingSubmissions[intent.id] = intent; return }
        guard !view.recovered.contains(where: { $0.id == intent.id }) else { return }
        view.recovered.append(intent)
    }
    func finishSubmission(_ id: String, in view: SessionDisplay) {
        view.submittingCommands.remove(id)
        if let intent = view.settlingSubmissions.removeValue(forKey: id) { offerSubmissionRecovery(intent, in: view) }
    }
    func retainingCapturedInput(_ intents: [CommandIntent], in view: SessionDisplay) -> [CommandIntent] {
        (intents + view.draftVersion.unsavedSubmissions.filter { pinned in !intents.contains { $0.id == pinned.id } })
            .filter { !view.submittingCommands.contains($0.id) }
    }
    func recoverDraft(_ intent: CommandIntent, insert: Bool) {
        // The banner sits in the pane of the chat the submission belongs to,
        // a side's included: it acts on that chat, not on the selected one.
        guard let view = displays[intent.sessionID], view.recoverableSubmissions.contains(where: { $0.id == intent.id }), draftWrites.recoveries[view.id] == nil else { return }
        guard intent.state == "intent", !view.acceptedCommands.contains(intent.id), !view.receipts.contains(where: { $0["commandId"]?.string == intent.id }) else {
            view.recovered.removeAll { $0.id == intent.id }; if view.recovered.isEmpty { view.uncertain = false }; return
        }
        guard !view.loading, view.editingMessageID == nil, view.queueEditingID == nil, !view.editPreparing, view.queueEditBeginning == nil, view.unreconciledQueuedEdit == nil else {
            view.notice = "Finish sending, or save or cancel the message you are editing before recovering this submission."; return
        }
        // Insert is not permission to repeat effects. Acceptance can arrive
        // during or after this transaction, after its intent is already gone.
        let recovered = DraftRecord(id: view.id, text: intent.text, attachments: intent.attachments, skills: intent.skills, submissionReviews: [intent.id])
        func mergedDraft() -> DraftRecord {
            var merged = view.savedDraft.merging(recovered)
            // Side-transfer merging trims separators; recovered prompts must
            // retain indentation and trailing newlines exactly as submitted.
            merged.text = view.draft + (view.draft.isEmpty || intent.text.isEmpty ? "" : "\n\n") + intent.text
            return merged
        }
        if insert, let reason = Self.recoveryLimit(mergedDraft()) { view.notice = reason; return }
        let previous = draftWrites.tasks[view.id]; previous?.cancel()
        let outputUse = beginToolOutputUse(.draftRecovery)
        draftWrites.recoveries[view.id] = Task {
            defer { finishToolOutputUse(outputUse) }
            defer { view.recoveringDraft = false; draftWrites.recoveries.removeValue(forKey: view.id); draftChanged(view) }
            do { try await prepareToolOutputUse(outputUse) } catch { return }
            // A cancelled debounce may already be in the store. Let it finish
            // before the transaction reserves the draft's newer revision.
            await previous?.value
            // A snapshot may have proved acceptance or retired this intent
            // while the old write finished. Its old button no longer applies.
            guard view.recoverableSubmissions.contains(where: { $0.id == intent.id }), !view.acceptedCommands.contains(intent.id),
                  !view.receipts.contains(where: { $0["commandId"]?.string == intent.id }) else { return }
            do {
                guard let store else { throw StoreError.unavailable }
                if insert {
                    try await materializeChat(view.id)
                    try await loadDraftBaseline(view)
                }
                guard view.recoverableSubmissions.contains(where: { $0.id == intent.id }), !view.acceptedCommands.contains(intent.id),
                      !view.receipts.contains(where: { $0["commandId"]?.string == intent.id }) else { return }
                guard !view.loading, view.editingMessageID == nil, view.queueEditingID == nil, !view.editPreparing,
                      view.queueEditBeginning == nil, view.unreconciledQueuedEdit == nil else {
                    view.notice = "Finish sending, or save or cancel the message you are editing before recovering this submission."; return
                }
                let merged = insert ? mergedDraft() : nil
                if let merged, let reason = Self.recoveryLimit(merged) { view.notice = reason; return }
                // Freeze the validated candidate only for this commit. Late
                // image conversions wait behind it; typing before it began
                // was included above. Quit awaits this task as well.
                view.recoveringDraft = true
                try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: merged, draftVersion: view.draftVersion, write: merged.map { _ in store.draftWriter.capture(view.id) })
                if let merged {
                    view.draft = merged.text; view.attachments = merged.attachments ?? []; view.skills = merged.skills ?? []; view.directCommand = false
                    view.submissionReviews = merged.submissionReviews ?? []
                }
                pendingIntentsChanged(view.id)
                view.recovered.removeAll { $0.id == intent.id }; if view.recovered.isEmpty { view.uncertain = false }
            } catch { self.error = "The retained submission could not be recovered. Its input was kept. \(error.localizedDescription)" }
        }
    }
    /// These are helper submission limits, not a reason to truncate a saved
    /// message. Refuse the entire merge and keep its recoverable intent.
    private static func recoveryLimit(_ draft: DraftRecord) -> String? {
        let images = draft.attachments ?? [], skills = draft.skills ?? []
        var limits: [String] = []
        if draft.text.utf8.count > SubmissionLimits.messageBytes { limits.append("more than 256 KiB of text") }
        if images.count > 4 { limits.append("\(images.count) images (maximum 4)") }
        if images.contains(where: { $0.bytes <= 0 || $0.bytes > 8 * 1024 * 1024 }) { limits.append("an image outside the 1 byte–8 MiB limit") }
        if images.reduce(0.0, { $0 + Double($1.bytes) }) > 16 * 1024 * 1024 { limits.append("more than 16 MiB of images") }
        if skills.count > 8 { limits.append("\(skills.count) skills (maximum 8)") }
        if skills.contains(where: { $0.arguments.utf8.count > 16_384 }) { limits.append("skill arguments over 16 KiB") }
        return limits.isEmpty ? nil : "Nothing was inserted: the combined draft would contain " + limits.joined(separator: ", ") + ". Make room in the composer, then insert again. The interrupted submission is still saved."
    }
}
