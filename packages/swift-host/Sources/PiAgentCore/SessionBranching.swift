import Foundation

// Editing an earlier user message: the journal keeps every record, while
// the live context and the displayed timeline drop the abandoned tail.

let branchMarkerText = "Edited from here · earlier replies stay in the journal"

extension AgentSession {
    /// Branch the conversation at one of its user messages and resubmit new text.
    /// The journal keeps every record; only the live context and the displayed
    /// timeline drop the abandoned tail. Nothing is written unless the new
    /// submission is itself acceptable.
    ///
    /// `expectedPrefix`, when the reader's preparation gave it, is what the
    /// edit is checked against: the conversation through the edited message
    /// (`sourcePrefix`). Rows added after that message since, as a run adds
    /// them, leave the edit valid. Without it (an older reader) the whole
    /// timeline must be as it was (`expectedTimeline`).
    public func edit(fromMessageID messageID: String, input: Submission, expectedTimeline: String? = nil, expectedTextDigest: String? = nil, expectedPrefix: String? = nil, admittedAt: Int? = nil) async throws -> JSON {
        try requireIndependentSession()
        let admittedAt = admittedAt ?? stopCount
        try checkSubmissionStop(admittedAt)
        // Work a cost-limit pause holds (parked sub-agent turns, held tool
        // calls, a cut compaction) is the run's, still under way: an edit is
        // refused as it is while those turns run, so Resume never restarts
        // an abandoned branch's work under the edited conversation.
        guard isIdle, !holdsCostPausedWork else { throw AgentError("session_busy", "Edit requires an idle session with empty queues") }
        guard !ephemeral else { throw AgentError("side_ephemeral", "Keep this side chat before editing its messages; a branch must be durable") }
        let capturedHead = journal?.head
        // A family's historic tool owners also serve its receipt/recovery
        // checks. Keep their existing full-history adoption; ordinary chats
        // need only the validated replay inputs and latest display rows.
        if partialHistory, subagents.family != nil || subagents.origin != nil || !subagents.plans.isEmpty { try await loadFullHistory() }
        let prepared = try await editSource(messageID)
        let adoption = try await editAdoption(prepared.plan)
        try checkSubmissionStop(admittedAt)
        guard !closed, isIdle, !holdsCostPausedWork, journal?.head == capturedHead else { throw AgentError("edit_changed", "The conversation changed while preparing the edit. Select the message again.") }
        guard try input.savedValue.data().count < 8 * 1024 * 1024 else { throw AgentError("queue_limit", "Queued content exceeds 8 MiB") }
        try validate(input,steer:false)
        try await resources.validate(input.skills, tools: await tools.capabilityIDs(readOnly: readOnly))
        try checkSubmissionStop(admittedAt)
        guard isIdle, !holdsCostPausedWork, journal?.head == capturedHead else { throw AgentError("edit_changed", "The conversation changed while preparing the edit. Select the message again.") }
        try validate(input,steer:false)
        guard let journal else { throw AgentError("session_closed", "Session runtime is unloaded") }
        let plan = prepared.plan
        let images = try loadImages(input.attachments)
        let effective = try profile.overriding(input)
        guard images.isEmpty || effective.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
        if let expectedPrefix {
            guard expectedPrefix == plan.sourcePrefix else { throw AgentError("edit_changed", "The conversation before the edited message changed. Select the message again.") }
        } else {
            guard expectedTimeline == nil || expectedTimeline == plan.sourceTimeline else { throw AgentError("edit_changed", "The selected branch changed. Select the message again.") }
        }
        let target = prepared.message
        let textDigest = sha256(Data((target.displayText ?? target.text).utf8))
        guard expectedTextDigest == nil || expectedTextDigest == textDigest else { throw AgentError("edit_changed", "The original message changed. Select it again.") }
        let targetDigest = sha256(try target.pi.data())
        let branch = HistoricalBranch(fromMessageId: messageID, keptIds: plan.replay, selectedTimelinePrefix: plan.displayPrefix,
                                      sourceTimelineDigest: plan.sourceTimeline, sourceJournalHead: journal.head, targetDigest: targetDigest)
        var record = try JSON.parse(JSONEncoder().encode(branch)); record["type"] = "branch"
        let oldCommands=commands
        queue.append(input); commandState(input,"queued")
        let markerID: String
        do {
            // Publish the branch and accepted replacement atomically. No
            // separate queue append may fail after hiding the previous tail.
            record["nativeState"] = try savedState(active:false)
            markerID=try journal.append(record)
            journaledWholeCommands(record["nativeState"])
        } catch {
            queue.removeLast(); commands=oldCommands
            wholeCommandsDue=true; journaledCommandsUncertain=true
            if journal.writeOutcomeUncertain { throw AgentError(AgentErrorCode.journalUncertain, "The edit may have been saved, but journal synchronization failed. Reopen or recover the preserved journal before sending again.") }
            throw error
        }
        if let adoption, partialHistory { adoptEdit(adoption, from: messageID, markerID: markerID) }
        else {
            versions.hide(from: messageID, visible: visible, history: history)
            Self.adoptBranch(plan, history: &history, visible: &visible, context: &context, markerID: markerID)
            prunePresentedTasksAfterBranch()
        }
        invalidateDisplay(allRows: true); replayInputsChanged(); contextRecovery = .null; compactionState = .null; requestExclusions = []
        boundary = context; currentContextCount = nil; clearRequestObservation()
        retrySubmission = nil; activeSubmission = nil; partialID = nil; partialText = ""; partialThinking = ""; resetPartialRow(); currentTurnID = ""; taskRootID = nil
        recordDisplayChange(markerID, at: displayClock())
        refreshCheckpoint()
        event("context.branched",["fromMessageId":JSON(messageID),"kept":JSON(plan.replay.count)])
        event("queue.changed"); queuePaused=false; launch()
        return ["accepted":true,"turnId":JSON(input.turnID),"queued":false,"queueCount":JSON(queue.count),"delivery":"start"]
    }
    func applyBranch(from messageID: String, keptIDs: Set<String>, markerID: String) {
        Self.branch(history:&history,context:&context,visible:&visible,from:messageID,keptIDs:keptIDs,markerID:markerID)
        prunePresentedTasksAfterBranch()
        invalidateDisplay(allRows: true)
        replayInputsChanged(); contextRecovery = .null; compactionState = .null; requestExclusions = []
        boundary=context; currentContextCount=nil; clearRequestObservation()
    }
    /// Shared by live edits and journal replay (the synchronous initializer
    /// cannot call isolated methods). The marker is display-only: it joins
    /// history and the visible timeline, never the model context.
    static func branch(history: inout [ChatMessage], context: inout [ChatMessage], visible: inout [ChatMessage], from messageID: String, keptIDs: Set<String>, markerID: String) {
        context=context.filter { keptIDs.contains($0.id) }
        if let index=visible.firstIndex(where:{$0.id == messageID}) { visible=Array(visible[..<index]) } else { visible=visible.filter { keptIDs.contains($0.id) } }
        // A summary is written after the user turns it keeps. Editing one of
        // those turns must not hide the summary that remains in model context.
        let visibleIDs=Set(visible.map(\.id))
        visible += context.filter { !visibleIDs.contains($0.id) }
        let marker=branchMarker(markerID)
        history.append(marker); visible.append(marker)
    }
    /// The display-only row an edit leaves where it branched.
    static func branchMarker(_ id: String) -> ChatMessage {
        var marker=ChatMessage(role:"system",content:[]); marker.id=id; marker.kind="branch"; marker.replayEligible=false; marker.displayText=branchMarkerText
        return marker
    }
}
