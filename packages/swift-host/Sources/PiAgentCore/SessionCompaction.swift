import Foundation

/// What an automatic compaction's plan depends on (`AgentSession.compactionInputs`).
struct CompactionInputs: Equatable, Sendable {
    let recovery: Bool
    let revision: UInt64
    let task: String?
    let profile: JSON
    let resources: String?
}

func compactionDetail(tokens: Int?, kept: Int) -> String {
    "Compacted \(tokens.map(String.init) ?? "unknown") estimated input tokens · \(kept) messages kept"
}

extension AgentSession {
    func compactionPresentation(_ operation: JSON) -> JSON {
        operation.removing(["sourceIDs","protectedIDs","keptIDs","summarySourceIDs","dependencyIDs","readFiles","modifiedFiles"])
    }
    /// The running turn is stopped first, queued messages stay queued, and
    /// an optional focus is escaped data in the appended summary instruction.
    public func compact(commandID: String = UUID().uuidString, overrides: JSON = [:], focus: String? = nil) async throws {
        try requireIndependentSession()
        let focus=focus?.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (focus?.utf8.count ?? 0) <= 4096 else { throw AgentError("invalid_params", "A compaction focus is limited to 4 KB") }
        // Stopping the turn pauses the queue; that pause is compaction's own,
        // so the queue it paused is released when compaction launches, and
        // what arrives during "Compacting…" is delivered after it, as in pi.
        // A Stop while the turn winds down cancels the compaction instead.
        var releaseQueue = false
        if runTask != nil {
            let wasPaused = queuePaused
            stop(userInitiated:false); let stops = stopCount
            await runTask?.value
            guard stopCount == stops else { throw AgentError("compaction_cancelled", "Compaction was cancelled because the chat was stopped") }
            releaseQueue = !wasPaused
        }
        guard runTask == nil else { throw AgentError("session_busy", "The running turn did not stop, so the chat was not compacted") }
        let selected = try NativeHostService.turnOverrides(overrides)
        // Validate before changing the command or persisted state. Missing
        // choices deliberately use the connection defaults, never an old turn.
        let intent=Submission(commandID:commandID,turnID:"compaction:"+commandID,text:"[Compact now]",attachments:[],skills:[],
                              model:selected.model,thinkingLevel:selected.thinkingLevel,contextWindow:selected.contextWindow,
                              maxOutputTokens:selected.maxOutputTokens,modelOutputLimit:selected.modelOutputLimit,input:selected.input)
        _ = try profile.overriding(intent)
        compactionFocus=focus?.isEmpty == false ? focus : nil
        if releaseQueue, state != .error { queuePaused=false }
        activeSubmission=intent; currentTurnID=intent.turnID; commandState(intent,"queued"); try persistState(); launch(compactOnly:true)
    }
    /// Whether a compaction would have something to summarize while keeping
    /// everything the next request must answer.
    var canCompact: Bool { canCompact(recovering:false) }
    func canCompact(recovering: Bool) -> Bool {
        guard let source=try? CompactionPlanner.source(context:context,taskRoot:taskRootID),
              source.previous == nil || (source.newSince ?? 0) < source.body.count else { return false }
        return !CompactionPlanner.plan(source,cut:min(max(source.required,source.whole),source.body.count)).summarized.isEmpty
    }
    /// Whether the task `taskRootID` names is still to be finished when the
    /// owner compacts an idle chat: its recorded outcome, or for a chat with
    /// none (a seed, an older journal) whether its context ends on something
    /// the model has not answered. A run in progress never asks: its task is open.
    /// The outcome is that of the newest execution that added a row to the
    /// task: a Resume that only redid a cut compaction, and was itself
    /// interrupted, says nothing about a task its reply had already ended.
    var idleTaskOpen: Bool {
        if let root=taskRootID {
            let worked=Set(history.lazy.filter { $0.replayEligible && $0.taskRootID == root }.compactMap(\.taskExecutionID))
            if let finished=recentTaskPresentations.last(where: { $0.rootID == root && worked.contains($0.executionID) }) {
                return !["completed","output-limited"].contains(finished.outcome ?? "")
            }
        }
        return continuationTail.map(Self.continues(from:)) ?? false
    }
    /// Before a task's first request the earlier threshold applies: no reply
    /// of the task is in the context yet. Steering, retries, Resume and
    /// sub-agent wake-ups of a task that has been answered are not a start.
    var atTaskStart: Bool {
        guard let root=taskRootID else { return false }
        for message in context.reversed() where message.replayEligible {
            guard message.taskRootID == root || message.id == root else { return false }
            if message.role == "assistant" { return false }
            if message.id == root { return true }
        }
        return false
    }
    /// Where an automatic compaction is due for `messages`. The appended
    /// instruction is small; measure its real boundary description at
    /// semantic request boundaries, never while receiving stream fragments.
    func compactionThreshold(_ messages: [ChatMessage], instructions: String, profile: Profile, taskStart: Bool = false) throws -> Int {
        let source = try CompactionPlanner.source(context:messages,taskRoot:taskRootID)
        let kept = CompactionPlanner.plan(source,cut:source.whole).keptMessages
        let projection = try ProviderClient.responsesProjection(messages.filter(\.replayEligible),instructions:instructions,profile:profile)
        let boundary = try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:Set(kept.map(\.id)))
        let instruction = CompactionSourceBuilder.instruction(boundary:boundary,focus:nil,visibleTarget:compactionPolicy.visibleTarget(for:profile))
        let items = ProviderClient.userContent(instruction,images:false)
        return try compactionPolicy.trigger(profile:profile,instructionTokens:RequestContextCounter.inputTokens([["role":"user","content":.array(items)]]),taskStart:taskStart)
    }
    /// What an automatic compaction may fail with while the turn goes on
    /// from its intact context: it could not be planned, its one summary
    /// request failed or was not usable, or its candidate was not worth
    /// adopting. Named one by one: a Stop, a cost or accounting hold, a
    /// damaged replay group and a journal that refused a write are none of
    /// these, and stop the run as before.
    static let recoverableCompactionFailures: Set<String> = [
        "compact_unavailable", "compact_budget", "compaction_too_large", "compact_no_progress", "compact_previous_failure", "compact_stale",
        "unsupported_image", "compaction_incompatible", "request_limit",
        "compaction_refused", "compaction_unexpected_tool_call", "compaction_unexpected_output", "compaction_incomplete",
        "compaction_output_exhausted", "compaction_empty_summary",
        "provider_http", "provider_transport", "provider_failed", "provider_incomplete", "provider_incomplete_unexplained", "provider_refused",
        "invalid_stream", "incomplete_stream", "response_limit", "invalid_tool_calls", "tool_argument_limit"]
    func recoverableCompactionFailure(_ error: Error) -> Bool {
        guard !Task.isCancelled, !costPaused, accountingFailure == nil, let error=error as? AgentError else { return false }
        // A summary request refused for the reasoning it replayed is the
        // owner's question (`holdRejectedReasoning`), not a summary that
        // was paid for and not adopted: it ends the run, not the task's
        // automatic compaction.
        guard !handlesRefusedReasoning(error) else { return false }
        return Self.recoverableCompactionFailures.contains(error.code)
    }
    /// One summary paid for and not adopted per task: every later round
    /// changes the context, so a fingerprint alone would ask again each time.
    /// A plan that could not be made is not such an attempt (`automaticCompaction`).
    var automaticCompactionSuppressed: Bool { taskRootID != nil && suppressedCompactionTask == taskRootID }
    /// What a plan depends on: the replayed context and its task, the
    /// request's configuration, and the mode, since recovery admits what a
    /// threshold does not. Presentation rows change none of it.
    func compactionInputs(reason: String) -> CompactionInputs {
        CompactionInputs(recovery:reason == "context-rejection",revision:contextMutation,task:taskRootID,profile:turnProfile.raw,resources:appliedSnapshot?.revision)
    }
    /// The record that ends a task's automatic attempts. A chat with no
    /// journal yet (a side not saved) holds it in memory, and its first
    /// journal carries it (`keepNow`).
    func suppressionRecord(_ root: String) -> JSON {
        var data: JSON=["taskRootId":JSON(root)]
        if let fingerprint=failedCompactionFingerprint { data["fingerprint"]=JSON(fingerprint) }
        return ["type":"custom","customType":JSON(JournalRecordKind.compactionFailure),"data":data]
    }
    /// A journal write like any other: when it cannot be appended and
    /// synchronized the error is the run's, before another request is paid
    /// for on a journal that refuses writes (an ordinary chat has no other
    /// check before a request). Memory says so only once the journal does.
    func suppressAutomaticCompaction() throws {
        guard let root=taskRootID, suppressedCompactionTask != root else { return }
        try journal?.append(suppressionRecord(root),flush:true)
        suppressedCompactionTask=root
    }
    /// The one policy for every automatic compaction (threshold, agent
    /// delivery, overflow recovery): whether a checkpoint was adopted. A
    /// recoverable failure leaves the context intact and shows on the
    /// operation's row. What follows depends on whether it cost a request:
    /// - before the summary request was sent, compaction is unavailable for
    ///   this context, nothing more: no failure is recorded, the task is not
    ///   written off, and a plan is tried again when its inputs change (a
    ///   task's required rows change every round; the same inputs are not
    ///   planned twice);
    /// - after it, the summary was paid for and not adopted: automatic
    ///   compaction ends for the task, durably.
    /// And one summary at most is paid for between two replies of the model.
    func automaticCompaction(reason: String) async throws -> Bool {
        guard !automaticCompactionSuppressed, !automaticSummarySpent else { return false }
        let inputs=compactionInputs(reason:reason)
        guard unavailableCompaction != inputs else { return false }
        do { try await compactContext(reason:reason); return true }
        catch where reasoningWidening(error) != nil {
            // The summary request sent again after the owner's Continue was
            // refused for the model's own reasoning: that goes too, and the
            // summary is asked for once more (`widenReasoningWithholding`
            // allows it once).
            try widenReasoningWithholding(reasoningWidening(error) ?? [])
            automaticSummarySpent=false
            return try await automaticCompaction(reason:reason)
        }
        catch where recoverableCompactionFailure(error) {
            if compactionDispatched { try suppressAutomaticCompaction() } else { unavailableCompaction=inputs }
            return false
        }
    }
    /// The compaction due before the request counted as `tokens`, if any.
    func compactAtThreshold(_ tokens: Int, instructions: String) async throws -> Bool {
        guard autoCompaction, !titleTask, !automaticCompactionSuppressed, !automaticSummarySpent else { return false }
        let threshold: Int
        // A budget that cannot hold a summary makes compaction unavailable;
        // it does not fail a request that can still be sent, and nothing
        // was spent on it.
        do { threshold=try compactionThreshold(requestContext,instructions:instructions,profile:turnProfile,taskStart:atTaskStart) }
        catch where recoverableCompactionFailure(error) { return false }
        guard tokens >= threshold, canCompact else { return false }
        return try await automaticCompaction(reason:"threshold")
    }
    func validateCompaction(_ revision: UInt64, profile: Profile) throws {
        try Task.checkCancellation()
        guard !closed, contextMutation == revision, turnProfile.raw == profile.raw else {
            throw AgentError("compact_stale", "Context changed while summarizing. The previous context is retained; compact again when ready.")
        }
    }
    func compactContext(reason: String = "manual") async throws {
        // Only the manual compaction it was given for carries the focus.
        let focus=reason == "manual" ? compactionFocus : nil; compactionFocus=nil
        let frozen=context.filter(\.replayEligible), revision=contextMutation, originalProfile=turnProfile
        let frozenTask=taskRootID, frozenKey=apiKey, frozenCache=promptCacheSessionID, frozenApplied=appliedSnapshot?.revision
        compactionAttemptIDs=[]; compactionPhysicalAttempts=0; compactionDispatched=false
        compactionState=["operationId":JSON(UUID().uuidString),"phase":"planning","reason":JSON(reason),"httpAttempts":0,"durable":JSON(journal != nil)]
        if reason == "context-rejection" { compactionState["recovery"]=contextRecovery }
        compactionPresentationID = UUID().uuidString
        var operation = ChatMessage(role:"system",content:[])
        operation.id=compactionPresentationID!; operation.kind="execution"; operation.operationID=compactionState["operationId"].text
        operation.detail="Compaction · preparing"; operation.responseTimeline=ResponseTimeline()
        try appendPresentation(operation)
        operationStatus("Preparing · " + reason)
        runStatus = .compacting; event("compaction_start")
        defer { modelActive=false; runStatus = .running; event("compaction_end") }
        do {
            let snapshot=try await resources.resolve(), definitions=await sessionDefinitions()
            try validateCompaction(revision,profile:originalProfile)
            let instructions=Self.requestInstructions((appliedSnapshot ?? snapshot).prompt, tools: definitions)
            let policy=compactionPolicy, sessionID=id, taskOpen=reason != "manual" || idleTaskOpen
            let worker=Task.detached(priority:.userInitiated) {
                try CompactionPlanner.prepare(frozen:frozen,profile:originalProfile,instructions:instructions,definitions:definitions,
                    sessionID:sessionID,cacheSessionID:frozenCache,taskRoot:frozenTask,taskOpen:taskOpen,policy:policy,reason:reason,focus:focus)
            }
            let prepared=try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
            try validateCompaction(revision,profile:originalProfile)
            let before=prepared.before, cap=prepared.profile.maxOutput, summaryProfile=prepared.profile, plan=prepared.plan
            let summarizedIDs=prepared.replacedIDs
            if reason != "manual", failedCompactionFingerprint == prepared.fingerprint {
                throw AgentError("compact_previous_failure", "Automatic compaction already failed for this unchanged context. Change its input/settings or explicitly retry compaction.")
            }
            compactionState["sourceFingerprint"]=JSON(prepared.fingerprint)
            compactionState["outputAllowance"]=JSON(cap); compactionState["allowedOutputTokens"]=JSON(cap)
            compactionState["outputAllowanceSource"]=JSON(summaryProfile.wireOutputLimit == nil ? "local-reserve-only" : "summary-generation-cap")
            compactionState["reasoningEffort"]=JSON(summaryProfile.raw["thinkingLevel"].text ?? "default")
            let text=try await summarize(prepared.messages,instructions:instructions,tools:definitions,profile:summaryProfile,originalProfile:originalProfile,revision:revision)
            var summary=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+text)])
            summary.kind="compaction"
            // The framing is part of the checkpoint from before it is counted.
            let continuation=prepared.continuationText
            if let continuation { summary.compaction=["continuationText":JSON(continuation)] }
            let retained=plan.keptMessages, candidate=[summary]+retained
            let validation=Task.detached(priority:.userInitiated) {
                let request=try ProviderClient.requestBody(profile:originalProfile,messages:candidate,instructions:instructions,tools:definitions,sessionID:sessionID,cacheSessionID:frozenCache)
                try CompactionPlanner.validateRequest(request)
                guard try request.data().count <= policy.maximumRequestBytes else {
                    throw AgentError("compact_budget", "The completed checkpoint and retained messages exceed the 32 MiB request limit. Original context is unchanged; no repair request was sent.")
                }
                return try RequestContextCounter().count(messages:candidate,profile:originalProfile,request:request,reportedUsage:false)
            }
            let after=try await withTaskCancellationHandler(operation:{ try await validation.value },onCancel:{ validation.cancel() })
            let finalResources=try await resources.resolve(), finalDefinitions=await sessionDefinitions()
            try validateCompaction(revision,profile:originalProfile)
            guard frozenTask == taskRootID, frozenKey == apiKey, frozenCache == promptCacheSessionID,
                  frozenApplied == appliedSnapshot?.revision, finalResources.revision == snapshot.revision, finalDefinitions == definitions else {
                throw AgentError("compact_stale", "Resources or task configuration changed while summarizing. Original context is retained.")
            }
            guard after.fits else { throw AgentError("compact_budget", "The completed checkpoint and retained messages need about \(after.requestTokens) tokens, exceeding the continuation input budget of \(after.inputBudget). Original context is unchanged; no repair request was sent.") }
            let reduction=before.requestTokens-after.requestTokens
            // An automatic checkpoint has to leave the planned gap before the
            // next trigger, not merely fall below it.
            // After a context rejection, where only what must stay was
            // planned, the half does not apply: fitting the normal reserve
            // (above) and saving the safety margin do.
            guard reduction > 0, reason == "manual" || (reduction >= after.safetyMargin && (prepared.recoveryOnly || after.requestTokens <= (prepared.replacementTarget ?? Int.max))) else {
                throw AgentError("compact_no_progress", "The completed checkpoint did not free sufficient context (before \(before.requestTokens), after \(after.requestTokens) estimated tokens). Original context is unchanged; no repair request was sent.")
            }
            operationStatus("Candidate summary validated")
            var metadata=compactionState
            metadata["version"]=2; metadata["phase"]="completed"; metadata["sourceContextRevision"]=before.requestFingerprint.map { JSON($0) } ?? .null
            metadata["taskRootId"]=taskRootID.map { JSON($0) } ?? .null
            if let continuation { metadata["continuationText"]=JSON(continuation) }
            metadata["sourceIDs"] = .array(frozen.map { JSON($0.id) })
            metadata["summarySourceIDs"] = .array(summarizedIDs.map { JSON($0) })
            metadata["dependencyIDs"] = .array(frozen.map { JSON($0.id) })
            metadata["protectedIDs"] = .array(plan.protected.map { JSON($0.id) })
            metadata["readFiles"] = []; metadata["modifiedFiles"] = []
            metadata["keptIDs"] = .array(retained.map { JSON($0.id) })
            metadata["before"]=before.json; metadata["after"]=after.json; metadata["recovery"]=contextRecovery
            metadata["summaryAttemptIds"] = .array(compactionAttemptIDs.map { JSON($0) })
            summary.operationID=compactionState["operationId"].text
            // Pi's tokensBefore: estimateContextTokens over the whole context,
            // the last valid reply's usage plus the rows after it.
            let tokensBefore=PiContext.estimateContextTokens(frozen).tokens
            summary.kind="compaction"; summary.detail=compactionDetail(tokens:tokensBefore,kept:retained.count)
            summary.requestAttemptIDs=compactionAttemptIDs; summary.compaction=metadata; summary.taskRootID=taskRootID
            let record: JSON=["type":"compaction","nativeCompactionVersion":2,"nativeCompaction":metadata,"summary":JSON(text),
                "firstKeptEntryId":retained.first.map { JSON($0.id) } ?? .null,"nativeKeptIDs":metadata["keptIDs"],"tokensBefore":JSON(tokensBefore),"nativeRequestAttemptIds":metadata["summaryAttemptIds"],
                "details":["readFiles":metadata["readFiles"],"modifiedFiles":metadata["modifiedFiles"]]]
            try validateCompaction(revision,profile:originalProfile)
            guard frozenTask == taskRootID, frozenKey == apiKey, frozenCache == promptCacheSessionID, frozenApplied == appliedSnapshot?.revision else {
                throw AgentError("compact_stale", "Task configuration changed during validation. Original context is retained.")
            }
            // Commit all preceding tool results and this checkpoint together.
            // Nothing below can suspend or fail until the new projection is adopted.
            try journal?.append(record,id:summary.id,flush:true)
            context=[summary]+retained; history.append(summary); visible.append(summary); boundary=context; requestExclusions=[]
            // Pi's context is unknown now until the next reply reports usage.
            replayInputsChanged(reason:"compaction-committed"); clearRequestObservation()
            failedCompactionFingerprint=nil
            compactionState=metadata
            operationStatus("Checkpoint durably adopted",terminal:"completed")
            refreshCheckpoint()
            invalidateDisplay(allRows:true); recordDisplayChange(summary.id,at:displayClock())
            for attempt in compactionAttemptIDs { pendingRequestLinks[attempt,default:[]].append(summary.id) }
            event("context.compacted")
            try Task.checkCancellation()
            await flushRequestLinks()
        } catch {
            if compactionState["phase"].text != "completed" {
                // A cost-limit pause cut (or refused) it: not a failure of
                // this context, so Resume compacts it again.
                let paused = costPaused || (error as? AgentError)?.code == Self.costLimitCode || error is CancellationError
                // A failed attempt is one whose summary request was sent; a
                // plan that could not be made leaves no record.
                if !Task.isCancelled, !paused, compactionDispatched, !handlesRefusedReasoning(error), let fingerprint=compactionState["sourceFingerprint"].text {
                    failedCompactionFingerprint=fingerprint
                    _ = try? journal?.append(["type":"custom","customType":JSON(JournalRecordKind.compactionFailure),"data":["fingerprint":JSON(fingerprint)]],flush:true)
                }
                compactionState["phase"]=JSON(Task.isCancelled ? "cancelled" : "failed")
                compactionState["errorCode"]=JSON((error as? AgentError)?.code ?? "cancelled")
                compactionState["error"]=JSON((error as? AgentError)?.message ?? "Compaction interrupted; original context retained.")
                operationStatus(compactionState["error"].text ?? "Interrupted",terminal:Task.isCancelled ? "cancelled":"failed")
            }
            throw error
        }
    }
    func compactionDelta(_ value: StreamDelta) {
        if case .part(var part) = value, let id = compactionPresentationID,
           var row = history.first(where: { $0.id == id }) {
            presentationOrdinal += 1; part.sessionOrdinal=presentationOrdinal
            var timeline=row.responseTimeline ?? ResponseTimeline()
            let changed=timeline.consume(part)
            if changed {
                row.responseTimeline=timeline
                // Keep unaccepted provider content live only. Settlement
                // persists accepted content or discards the rejected attempt
                // before writing the next local status receipt.
                try? updatePresentation(row,persist:false)
            }
        }
        if nowMS()-compactionProgressAt>=250 { compactionProgressAt=nowMS(); event("compaction_progress") }
    }
    func compactionObservation(_ observation: RequestObservation) async {
        countAttempt(observation)
        guard observation.purpose == "compaction" else { return }
        monitor(observation)
        if !compactionAttemptIDs.contains(observation.attemptID) {
            compactionAttemptIDs.append(observation.attemptID)
            operationStatus("Summary request · attempt \(compactionPhysicalAttempts)")
            if let id=compactionPresentationID, var row=history.first(where: { $0.id == id }) {
                row.requestAttemptIDs=compactionAttemptIDs; try? updatePresentation(row,persist:true)
            }
        }
        if observation.phase == "awaiting" { await traces.operation(observation.attemptID,compactionState) }
    }
}
