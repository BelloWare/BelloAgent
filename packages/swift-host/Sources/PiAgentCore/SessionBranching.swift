import Foundation

// Editing an earlier user message: the journal keeps every record, while
// the live context and the displayed timeline drop the abandoned tail.

let branchMarkerText = "Edited from here · earlier replies stay in the journal"

extension AgentSession {
    /// Branch the conversation at one of its user messages and resubmit new text.
    /// The journal keeps every record; only the live context and the displayed
    /// timeline drop the abandoned tail. Nothing is written unless the new
    /// submission is itself acceptable.
    public func edit(fromMessageID messageID: String, input: Submission, expectedTimeline: String? = nil, expectedTextDigest: String? = nil) async throws -> JSON {
        guard isIdle else { throw AgentError("session_busy", "Edit requires an idle session with empty queues") }
        guard !ephemeral else { throw AgentError("side_ephemeral", "Keep this side chat before editing its messages; a branch must be durable") }
        try validate(input,steer:false)
        guard try input.savedValue.data().count < 8 * 1024 * 1024 else { throw AgentError("queue_limit", "Queued content exceeds 8 MiB") }
        let capturedHead = journal?.head
        try await resources.validate(input.skills, tools: await tools.capabilityIDs(readOnly: readOnly))
        guard isIdle, journal?.head == capturedHead else { throw AgentError("edit_changed", "The conversation changed while preparing the edit. Select the message again.") }
        try validate(input,steer:false)
        guard let journal else { throw AgentError("session_closed", "Session runtime is unloaded") }
        let plan = try Self.planEdit(messageID, history: history, visible: visible, context: context)
        let images = try loadImages(input.attachments)
        let effective = try profile.overriding(model: input.model, thinkingLevel: input.thinkingLevel, contextWindow: input.contextWindow, maxOutputTokens: input.maxOutputTokens, modelOutputLimit: input.modelOutputLimit)
        guard images.isEmpty || effective.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
        guard expectedTimeline == nil || expectedTimeline == plan.sourceTimeline else { throw AgentError("edit_changed", "The selected branch changed. Select the message again.") }
        let target = history.first { $0.id == messageID }
        let textDigest = sha256(Data((target?.displayText ?? target?.text ?? "").utf8))
        guard expectedTextDigest == nil || expectedTextDigest == textDigest else { throw AgentError("edit_changed", "The original message changed. Select it again.") }
        let byID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let targetDigest = try byID[messageID].map { sha256(try $0.pi.data()) }
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
        } catch {
            queue.removeLast(); commands=oldCommands
            if journal.writeOutcomeUncertain { throw AgentError("journal_uncertain", "The edit may have been saved, but journal synchronization failed. Reopen or recover the preserved journal before sending again.") }
            throw error
        }
        Self.adoptBranch(plan, history: &history, visible: &visible, context: &context, markerID: markerID)
        prunePresentedTasksAfterBranch()
        invalidateDisplay(allRows: true); replayInputsChanged(); contextRecovery = .null; compactionState = .null; requestExclusions = []
        boundary = context; currentContextCount = nil; clearRequestObservation()
        retrySubmission = nil; activeSubmission = nil; partialID = nil; partialText = ""; partialThinking = ""; resetPartialRow(); currentTurnID = ""; taskRootID = nil
        recordDisplayChange(markerID, at: displayClock())
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
        var marker=ChatMessage(role:"system",content:[]); marker.id=markerID; marker.kind="branch"; marker.replayEligible=false; marker.displayText=branchMarkerText
        history.append(marker); visible.append(marker)
    }
}
