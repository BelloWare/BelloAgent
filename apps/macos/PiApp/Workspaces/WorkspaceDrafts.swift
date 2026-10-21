import Foundation

// Unsent text and reading position, written behind the typing rather than
// during it. A draft write is debounced per chat and the last write wins;
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
        if item.isSubagent {
            let metadata = try await store.selectionMetadata(id: view.id, draft: false, anchor: view.scrollAnchor == nil)
            guard current() else { return false }
            if view.scrollAnchor == nil { view.scrollAnchor = metadata.anchor }
            view.selectionMetadataLoaded = true; view.draftReady = false
            return true
        }
        let wantsMetadata = !view.selectionMetadataLoaded, draftAtStart = view.savedDraft
        let metadata = try await store.selectionMetadata(id: view.id, draft: wantsMetadata, anchor: wantsMetadata && view.scrollAnchor == nil)
        guard current() else { return false }
        if wantsMetadata {
            if let draft = metadata.draft, view.draft == draftAtStart.text && view.attachments == (draftAtStart.attachments ?? []) && view.skills == (draftAtStart.skills ?? []),
               view.draft.isEmpty && view.skills.isEmpty && view.attachments.isEmpty && view.editingMessageID == nil && view.queueEditingID == nil {
                view.restoreDraft(draft); if let queued = draft.queuedEdit { Task { await self.reconcileQueuedEdit(view, queued) } }
            }
            if view.scrollAnchor == nil { view.scrollAnchor = metadata.anchor }
            view.selectionMetadataLoaded = true
        }
        let recovered = try await recoverableIntents(metadata.recovered, for: item, view: view)
        guard current() else { return false }
        view.recovered = recovered; view.uncertain = !recovered.isEmpty
        // Text alone cannot authorize a resend while acceptance is unread.
        view.draftReady = true
        return true
    }
    /// An acknowledgement may be missing locally after a full disk or crash.
    /// Consult durable helper evidence before exposing any recovery action.
    func recoverableIntents(_ intents: [CommandIntent], for item: ChatRecord, view: SessionDisplay) async throws -> [CommandIntent] {
        let unchecked = intents.filter { $0.state == "intent" && !view.acceptedCommands.contains($0.id) }
        let path = item.path ?? root.appendingPathComponent("Workspaces/\(item.workspaceID)/Sessions/\(item.id).jsonl").path
        let accepted: Set<String>
        if let commandAcceptanceRead { accepted = try await commandAcceptanceRead(path, unchecked, item.path == nil) }
        else { accepted = try await history.acceptedCommands(in: path, intents: unchecked, missingIsEmpty: item.path == nil) }
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
        // Legacy records do not identify which characters came back after a
        // lost reply. Preserve all typing, but require review before resending.
        if view.hasSubmittableInput { view.submissionReviews.formUnion(commands) }
        view.draftBeforeEdit?.requireSubmissionReview(commands)
        view.draftBeforeQueueEdit?.requireSubmissionReview(commands)
        // The marker-only write can overtake a typing revision reserved while
        // we await the old debounce. Reissue the latest live draft afterward.
        defer { if view.selectionMetadataLoaded, !isShutDown, displays[view.id] === view { draftChanged(view) } }
        let previous = draftWrites.tasks[view.id]; previous?.cancel(); await previous?.value
        if !isEphemeral(view.id) {
            guard let store else { throw StoreError.unavailable }
            try await store.preserveSubmissionReviews(sessionID: view.id, commands: commands)
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
        draftWrites.tasks[view.id]?.cancel()
        // The entry is cleared when this write finishes, and only by the write
        // that owns it: a newer one replaces the token first, so a cancelled
        // task's own cleanup can never drop it.
        let draft = view.savedDraft, id = view.id, token = UUID()
        let outputUse = beginToolOutputUse(.draftWrite)
        draftWrites.tokens[id] = token
        draftWrites.tasks[id] = Task {
            defer { finishToolOutputUse(outputUse) }
            defer { if draftWrites.tokens[id] == token { draftWrites.tokens.removeValue(forKey: id); draftWrites.tasks.removeValue(forKey: id) } }
            do {
                try await prepareToolOutputUse(outputUse)
                guard let store else { throw StoreError.unavailable }
                let revision = try await store.reserveRevision(kind: "draft", id: draft.id)
                try await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
                try await store.put(draft, kind: "draft", id: draft.id, revision: revision); draftWrites.failed = false
            }
            catch is CancellationError { }
            catch StoreError.staleRevision { /* A newer send, flush or edit already saved this draft. */ }
            catch {
                // A full disk fails every debounce tick; report it once, not per keystroke.
                guard !draftWrites.failed else { return }
                draftWrites.failed = true; self.error = "Draft could not be saved. \(error.localizedDescription)"
            }
        }
    }
    /// Writes every pending draft and anchor now. Quit calls this so the
    /// 150 ms debounce cannot lose the last thing typed; the update path does
    /// the same inside prepareForInstall.
    func flushDrafts() async throws {
        let outputUse = beginToolOutputUse(.draftFlush)
        defer { finishToolOutputUse(outputUse) }
        try await prepareToolOutputUse(outputUse)
        for task in draftWrites.recoveries.values { await task.value }
        for task in draftWrites.tasks.values { task.cancel() }; draftWrites.tasks.removeAll(); draftWrites.tokens.removeAll()
        let retained = displays.values.filter { !isEphemeral($0.id) }
        guard !retained.isEmpty else { return }
        guard let store else { throw StoreError.unavailable }
        for view in retained {
            // A chat that never sent has no record yet. Writing its draft under
            // that id alone left text nothing would ever list again; skipping it
            // silently threw away what the user had typed. Give the text a chat.
            if pendingChatIDs.contains(view.id) {
                guard !isPendingEmpty(view.id) else { continue }
                try await materializeChat(view.id)
            } else if !view.selectionMetadataLoaded {
                // A display whose saved draft never loaded (a selection that
                // was overtaken, or one a helper event built for a chat nobody
                // is showing) holds an empty composer that is not the user's:
                // writing it erased the draft that is on disk.
                continue
            }
            if record(view.id)?.isSubagent != true { try await store.put(view.savedDraft, kind: "draft", id: view.id) }
            if let anchor = view.scrollAnchor { try await store.put(anchor, kind: "anchor", id: view.id) }
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
        let anchor = view.scrollAnchor
        Task { if let anchor { try? await store?.put(anchor, kind: "anchor", id: view.id) }
            else { try? await store?.remove(kind: "anchor", id: view.id) } }
    }
    func recoverDraft(_ intent: CommandIntent, insert: Bool) {
        // The banner sits in the pane of the chat the submission belongs to,
        // a side's included: it acts on that chat, not on the selected one.
        guard let view = displays[intent.sessionID], view.recovered.contains(where: { $0.id == intent.id }), draftWrites.recoveries[view.id] == nil else { return }
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
            guard view.recovered.contains(where: { $0.id == intent.id }), !view.acceptedCommands.contains(intent.id),
                  !view.receipts.contains(where: { $0["commandId"]?.string == intent.id }) else { return }
            do {
                guard let store else { throw StoreError.unavailable }
                let merged = insert ? mergedDraft() : nil
                if let merged, let reason = Self.recoveryLimit(merged) { view.notice = reason; return }
                // Freeze the validated candidate only for this commit. Late
                // image conversions wait behind it; typing before it began
                // was included above. Quit awaits this task as well.
                view.recoveringDraft = true
                try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: merged)
                if let merged {
                    view.draft = merged.text; view.attachments = merged.attachments ?? []; view.skills = merged.skills ?? []; view.directCommand = false
                    view.submissionReviews = merged.submissionReviews ?? []
                }
                pendingIntentsChanged(view.id)
                view.recovered.removeAll { $0.id == intent.id }; if view.recovered.isEmpty { view.uncertain = false }
            } catch { self.error = "The interrupted submission could not be recovered. Its saved copy was kept. \(error.localizedDescription)" }
        }
    }
    /// These are helper submission limits, not a reason to truncate a saved
    /// message. Refuse the entire merge and keep its recoverable intent.
    private static func recoveryLimit(_ draft: DraftRecord) -> String? {
        let images = draft.attachments ?? [], skills = draft.skills ?? []
        var limits: [String] = []
        if draft.text.utf8.count > SubmissionLimits.messageBytes { limits.append("more than 256 KiB of text") }
        if images.count > SubmissionLimits.images { limits.append("\(images.count) images (maximum \(SubmissionLimits.images))") }
        if images.contains(where: { $0.bytes <= 0 || $0.bytes > SubmissionLimits.imageBytes }) { limits.append("an image outside the 1 byte–8 MiB limit") }
        if images.reduce(0.0, { $0 + Double($1.bytes) }) > Double(SubmissionLimits.imageTotalBytes) {
            limits.append("more than \(SubmissionLimits.imageTotalBytes / 1_048_576) MiB of images")
        }
        if skills.count > 8 { limits.append("\(skills.count) skills (maximum 8)") }
        if skills.contains(where: { $0.arguments.utf8.count > 16_384 }) { limits.append("skill arguments over 16 KiB") }
        return limits.isEmpty ? nil : "Nothing was inserted: the combined draft would contain " + limits.joined(separator: ", ") + ". Make room in the composer, then insert again. The interrupted submission is still saved."
    }
}
