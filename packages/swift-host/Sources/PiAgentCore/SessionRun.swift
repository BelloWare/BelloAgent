import Foundation

// The run loop: one task per session that answers a turn, executes the
// tool calls it asks for, and retries transient gateway failures.

extension AgentSession {
    func launch(compactOnly: Bool = false) {
        turnSubagentModels = activeSubmission?.subagentModels ?? subagentModelGrants
        if !costLimitReached, accountingFailure == nil { familyStopReason = nil; budgetStopIssued = false }
        presentationUtility = compactOnly || titleTask
        if retrying || continuing, let root = taskRootID {
            beginPresentedTask(root)
            activeTaskPresentation?.activeInputID = currentTurnID.isEmpty ? root : currentTurnID
            activeTaskPresentation?.anchorSourceID = visible.last?.id ?? root
        }
        state = .running; runStatus = .running; errorMessage=nil; errorCode=nil; begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0
        runTask=Task { await run(compactOnly:compactOnly) }; event("state")
    }
    func flushRequestLinks() async {
        let pending = pendingRequestLinks; pendingRequestLinks = [:]
        for (attempt, ids) in pending { await traces.outputs(attempt, messageIDs: ids) }
    }
    /// Pi 0.85.1's retry (agent-session.ts _isRetryableError and _prepareRetry):
    /// a failure whose text pi's isRetryableAssistantError reads as transient
    /// (overload, rate limits, 5xx, transport and cut streams), never a
    /// context overflow, is retried up to settings.retry.maxRetries times (3),
    /// after 2, 4 and 8 seconds. Anything else, and a cancellation, fails at once.
    /// Ours (owner 2026-10-15): an incomplete with no reason also retries;
    /// an explicit incomplete reason never becomes transient through its text.
    static func isRetryable(_ error: AgentError) -> Bool {
        guard error.code != "provider_incomplete", !isContextOverflow(error) else { return false }
        return error.code == "provider_incomplete_unexplained" || PiProviderRules.isRetryableText(error.piMessage)
    }
    /// Case 1 of pi's isContextOverflow: the provider's text names an overflow.
    /// Ours: the gateway's structured overflow codes count too.
    static func isContextOverflow(_ error: AgentError) -> Bool {
        guard error.code != "provider_incomplete" else { return false }
        return error.failure?.contextRejection == true || PiProviderRules.isOverflowText(error.piMessage)
    }
    static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(5))
    }
    /// `refresh` runs after a retry's back-off. Pi retries by continuing its
    /// agent loop, which first delivers queued steering; when it does, the
    /// retried request is the one it returns.
    func completeWithRetries(profile: Profile, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], turnID: String, purpose: String, operation: JSON = .null, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void, reset: () throws -> Void,
                             refresh: () async throws -> (profile: Profile, messages: [ChatMessage], instructions: String, tools: [ToolDefinition])? = { nil }) async throws -> ModelReply {
        var profile = profile, messages = messages, instructions = instructions, tools = tools
        // One policy for the whole request: a setting changed meanwhile applies from the next one.
        let retry = retrySettings
        let attempts = retry.enabled ? 1 + max(0, retry.maxRetries) : 1
        var attempt = 0
        modelRequestsMs = 0; modelReplyMs = 0
        // The retry notice describes this request only. It goes whichever way
        // the request ends: a reply, a failure, or a Stop that cancels the
        // retried request itself (thrown as a CancellationError, not an
        // AgentError, so no catch below would see it).
        defer { retryInfo = .null }
        while true {
            attempt += 1
            // Every attempt, the first and each retry, is a model request:
            // none goes once the chat's reported spend reaches its limit.
            if costPaused { throw Self.costHoldError }
            try enforceCostLimit()
            let generation=beginObservationGeneration(profile:profile)
            // Each attempt's own duration; the back-off below is not model time.
            let started=nowMS(); var measured=false
            defer { if !measured { modelRequestsMs += nowMS()-started } }
            do {
                modelActive = true
                let lifecycle = try await requestLifecycle(turnID:turnID,purpose:purpose,requestMessages:messages)
                let client = self.client, apiKey = self.apiKey, sessionID = id, cacheSessionID = promptCacheSessionID
                // A cost-limit pause cuts this request (`abortModelRequests`).
                let reply = try await abortable { [weak self] in
                    try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,cacheSessionID:cacheSessionID,turnID:turnID,purpose:purpose,lifecycle:lifecycle,onObservation:{ [weak self] observation in await self?.observeOperation(observation,generation:generation,operation:operation) },onDelta:onDelta)
                }
                modelReplyMs = nowMS()-started; modelRequestsMs += modelReplyMs; measured = true
                return reply
            } catch is UnexplainedIncompleteCancellation {
                modelActive = false
                try discardIncompleteReply()
                throw CancellationError()
            } catch let error as AgentError {
                modelActive = false
                modelRequestsMs += nowMS()-started; measured = true
                if error.code == "provider_incomplete_unexplained" || error.discardIncompleteReply {
                    // Discard this attempt even when retrying is disabled or
                    // exhausted. Its ledger/capture and accounting remain;
                    // neither a retry nor crash recovery may adopt its reply.
                    try discardIncompleteReply()
                }
                guard attempt < attempts, Self.isRetryable(error), !Task.isCancelled else {
                    throw attempt > 1 ? AgentError(error.code, "Failed after \(attempt) attempts. " + error.message,failure:error.failure,attemptID:error.attemptID,providerMessage:error.providerMessage) : error
                }
                try reset()
                retryInfo = ["attempt": JSON(attempt + 1), "of": JSON(attempts), "reason": JSON(error.message)]
                runStatus = .retrying; event("retry", retryInfo)
                let delay = UInt64(retry.delayMs(attempt: attempt) * 1_000_000)
                try await abortable { try await Task.sleep(nanoseconds: delay) }
                runStatus = .running; event("state")
                if let next = try await refresh() { (profile, messages, instructions, tools) = next }
            }
        }
    }
    /// Runs a model request (or its retry back-off) so a cost-limit pause can
    /// cut it alone, leaving the run and its tools in place. Stop still
    /// cancels it through the run task.
    func abortable<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        modelRequestAbort = { task.cancel() }
        defer { modelRequestAbort = nil }
        if costPaused { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// The held calls of the newest reply, in its order, still without results.
    func heldToolCalls() -> ([ToolCall], [String]) {
        let held = Set(costPendingCalls)
        guard let index = context.lastIndex(where: { $0.role == "assistant" }) else { return ([], []) }
        // Providers may reuse call IDs across replies: only this reply's results count.
        let reply = context[index], answered = Set(context[context.index(after:index)...].compactMap { $0.role == "toolResult" ? $0.toolCallId : nil })
        let calls = reply.content.compactMap { block -> ToolCall? in
            guard block["type"].text == "toolCall", let id = block["id"].text, let name = block["name"].text, held.contains(id), !answered.contains(id) else { return nil }
            return ToolCall(id:id,name:name,arguments:block["arguments"])
        }
        return (calls, reply.requestAttemptIDs ?? [])
    }
    func observeOperation(_ observation: RequestObservation, generation: UInt64, operation: JSON) async {
        countAttempt(observation)
        startResponseLedger(observation)
        monitor(observation)
        observe(observation,generation:generation)
        if observation.phase == "awaiting", !operation.isNull { await traces.operation(observation.attemptID,operation) }
    }
    /// A model request as the context stands: the tools it offers, its
    /// instructions, its body, and its count, which the chat's figures show.
    struct PreparedRequest {
        var snapshot: ResourceSnapshot
        var definitions: [ToolDefinition]
        var instructions: String
        var body: JSON
        var count: RequestContextCount
    }
    /// The next request, built from `snapshot`, the chat's resources as
    /// applied, and the context as it now stands: before the first request,
    /// and again whenever a compaction or delivered steering changed it.
    func prepareRequest(_ snapshot: ResourceSnapshot) async throws -> PreparedRequest {
        let definitions=await sessionDefinitions()
        let instructions=Self.requestInstructions(snapshot.prompt, tools: definitions)
        let body=try ProviderClient.requestBody(profile:turnProfile,messages:requestContext,instructions:instructions,tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
        let count=try countContext(requestContext,request:body); currentContextCount=count
        return PreparedRequest(snapshot:snapshot,definitions:definitions,instructions:instructions,body:body,count:count)
    }
    /// The reply streamed so far, as the row a cut-off request leaves: kept
    /// and shown, never sent to the model again. Nil when nothing arrived.
    func interruptedPartial(attemptIDs: [String]?) -> ChatMessage? {
        guard let partialID, !partialText.isEmpty || !partialThinking.isEmpty || !partialTimeline.segments.isEmpty else { return nil }
        return Self.interruptedReply(id:partialID,text:partialText,thinking:partialThinking,timeline:partialTimeline,attemptIDs:attemptIDs)
    }
    func run(compactOnly: Bool) async {
        do {
            try Task.checkCancellation(); state = .running; runStatus = .running; try persistState(active:true); event("state")
            if compactOnly { try await compactContext(); costPendingCompaction=false; if let activeSubmission { commandState(activeSubmission,"completed") } }
            else {
                // Deliver the next eligible input before sizing the pending request.
                var startedFollowUp=false
                if steering.isEmpty, !retrying, !continuing {
                    // A follow-up that cannot be answered stays queued, paused.
                    if !queue.isEmpty, queueEdit == nil { try enforceCostLimit() }
                    startedFollowUp=try await startFollowUp()
                }
                let retryFirstRequest=retrying
                retrying=false
                // A Resume asks the model from the context as it stands. Unlike
                // a retry, the request is a new one: steering waiting at its
                // start is delivered first (pi's loop polls it before the first
                // request), and the context may be compacted before it.
                let continued=continuing
                continuing=false
                if continued { try startAgentEpoch() }
                // Resume after a cost-limit pause: parked sub-agent turns go on
                // under this run's execution, before anything is asked again.
                if resumingCostPause, !isSubagent {
                    resumingCostPause=false
                    do { try await agentCoordinator?.resumeParked(owner:self,generation:costPauseCount) }
                    catch {
                        // Stopped (or closed) while the pause's children were
                        // still settling: the family stays paused for the next
                        // Resume, and their runs are halted, not waited for.
                        costPaused = true; costPauseCount &+= 1; try? persistState(active:true)
                        if let coordinator = agentCoordinator { let count = costPauseCount; Task { await coordinator.pause(owner:self,generation:count,halt:true) } }
                        throw error
                    }
                }
                // Tool calls the pause held before they started run first,
                // from the reply that issued them: it is never asked again.
                if continued, !costPendingCalls.isEmpty {
                    let (calls, attempts) = heldToolCalls()
                    // Durable before any effect: after a crash these calls may
                    // have begun, so recovery gives them unknown outcomes and
                    // nothing replays them.
                    costPendingCalls = []; try persistState(active:true)
                    if !calls.isEmpty {
                        currentAttemptIDs = attempts
                        try await runToolBatch(calls)
                        await flushRequestLinks()
                        boundary=context; try persistState(active:true); event("turn_end")
                    } else { try persistState(active:true) }
                }
                if compactOnResume {
                    // The manual compaction the pause cut, done again once parked
                    // work is released and held calls have run (a failure here
                    // cannot strand the family).
                    compactOnResume=false
                    // Nothing left to summarize is not a reason to strand the rest.
                    do { try await compactContext() } catch let error as AgentError where error.code == "compact_unavailable" {}
                    costPendingCompaction=false; try persistState(active:true)
                }
                // Nothing of the parent's own was cut off: wait for the resumed
                // family as the turn's end would, and ask the model only once
                // something arrives for it.
                var familyOnly=false
                if familyWaitResume {
                    familyWaitResume=false
                    if let coordinator=agentCoordinator, try await coordinator.boundary(self,final:true) {} else { familyOnly=true }
                }
                // Pi's _overflowRecoveryAttempted: one compact-and-retry until a
                // user message arrives or a reply completes.
                var overflowRecoveryAttempted=retryFirstRequest && contextRecovery["consumed"].flag == true
                var rounds=0
                if familyOnly {
                    try finishPresentedTask("completed")
                    if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                }
                while !familyOnly {
                    // Pi's agent loop has no limit on model requests per run.
                    try Task.checkCancellation(); rounds += 1
                    // Retry repeats the failed model request before pending steering
                    // reaches its next complete model/tool boundary.
                    let resumingFailedRequest=retryFirstRequest && rounds == 1
                    // Each round makes a model request. At the chat's cost
                    // limit it stops here, before pending steering is delivered.
                    try await enforceCostHold(); try enforceCostLimit()
                    let humanDrained=resumingFailedRequest ? false : try await drainSteering()
                    let agentDrained=resumingFailedRequest || agentCoordinator == nil ? false : try await agentCoordinator!.boundary(self,final:false)
                    let drained = humanDrained || agentDrained
                    if drained { overflowRecoveryAttempted=false }
                    // A run started for pending input that delivered none (a
                    // queued edit took the hold first, or the message left)
                    // settles without asking the model about the old context.
                    if rounds == 1, !retryFirstRequest, !continued, !startedFollowUp, !drained { break }
                    // A resumed sub-agent turn that had already answered when
                    // its family paused has nothing to ask the model again. It
                    // still takes its final boundary: steering accepted
                    // meanwhile is delivered (and answered) before it seals.
                    if rounds == 1, continued, isSubagent, !drained, let tail=continuationTail, !Self.continues(from:tail) {
                        if let coordinator=agentCoordinator, try await coordinator.boundary(self,final:true) { continue }
                        try finishPresentedTask("completed")
                        if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                        break
                    }
                    let resourceSnapshot: ResourceSnapshot
                    if let appliedSnapshot { resourceSnapshot=appliedSnapshot }
                    else { resourceSnapshot=try await resources.resolve(); appliedSnapshot=resourceSnapshot }
                    appliedRevision=resourceSnapshot.revision
                    var prepared=try await prepareRequest(resourceSnapshot)
                    // Include delivered input and complete tool results. Leave
                    // room for an intact-history summary before this request.
                    let threshold = autoCompaction && !titleTask && !resumingFailedRequest
                        ? try compactionThreshold(requestContext,instructions:prepared.instructions,profile:turnProfile) : Int.max
                    if prepared.count.requestTokens >= threshold, canCompact {
                        do { try await compactContext(reason:"threshold") }
                        catch let error as AgentError where error.code == "compact_unavailable" && prepared.count.fits { /* Nothing useful to replace; keep the intact request. */ }
                        if !drained && !resumingFailedRequest, try await drainSteering() { overflowRecoveryAttempted=false }
                        prepared=try await prepareRequest(appliedSnapshot ?? prepared.snapshot)
                    }
                    var modelMs=0.0
                    let operationID=UUID().uuidString
                    var recovered=false, completed: ModelReply?
                    while completed == nil {
                        try Task.checkCancellation()
                        let dispatchProfile=try turnProfile.dispatching(prepared.count)
                        partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000; activeTaskPresentation?.operationID=operationID
                        partialText=""; partialThinking=""; resetPartialRow(); invalidateDisplay(); runStatus = .running; modelActive=true; event("message_start")
                        do {
                            completed=try await completeWithRetries(profile:dispatchProfile,messages:requestContext,instructions:prepared.instructions,tools:prepared.definitions,turnID:currentTurnID,purpose:titleTask ? utilityPurpose : "turn",operation:["logicalRequestId":JSON(operationID),"recovered":JSON(recovered),"recovery":recovered ? contextRecovery : .null],onDelta:{ [weak self] delta in await self?.delta(delta) },reset:{
                                if let partial=interruptedPartial(attemptIDs:requestObservation.map { [$0.attemptID] }) { try append(partial) }
                                partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000
                                partialText=""; partialThinking=""; resetPartialRow()
                                if let partialID { recordDisplayChange(partialID, at: displayClock()) }
                            },refresh:{
                                // Pi retries by continuing its loop, which first delivers queued steering.
                                let userDelivered = try await drainSteering()
                                let agentDelivered = try await agentCoordinator?.boundary(self,final:false) ?? false
                                guard userDelivered || agentDelivered else { return nil }
                                overflowRecoveryAttempted=false
                                prepared=try await prepareRequest(appliedSnapshot ?? prepared.snapshot)
                                return (try turnProfile.dispatching(prepared.count),requestContext,prepared.instructions,prepared.definitions)
                            })
                            modelMs += modelRequestsMs
                        } catch let error as AgentError {
                            modelMs += modelRequestsMs
                            // Case 1 of pi's _checkCompaction: compact and retry once.
                            guard Self.isContextOverflow(error), autoCompaction, !titleTask, !overflowRecoveryAttempted, canCompact(recovering:true), !Task.isCancelled else { throw error }
                            overflowRecoveryAttempted=true
                            // Recovery surrounds only this failed model operation.
                            // The completed tool batch is never entered a second time.
                            if let partial=interruptedPartial(attemptIDs:error.attemptID.map { [$0] }) { try append(partial) }
                            partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); modelActive=false
                            let failure=error.failure.flatMap { $0.contextRejection ? $0.rawValue : nil } ?? "contextOverflow"
                            let recovery: JSON=["logicalRequestId":JSON(operationID),"consumed":true,"failedAttemptId":error.attemptID.map { JSON($0) } ?? .null,"failedFingerprint":prepared.count.requestFingerprint.map { JSON($0) } ?? .null,"failure":JSON(failure)]
                            try journal?.append(["type":"custom","customType":JSON(JournalRecordKind.contextRecovery),"data":recovery],flush:true)
                            contextRecovery=recovery; recovered=true
                            // A recovery that cannot compact leaves the overflow as the run's failure, as in pi.
                            let overflow=error
                            do { try await compactContext(reason:"context-rejection") }
                            // A stop at the chat's cost limit is the run's failure, not the overflow.
                            catch let stopped as AgentError where stopped.code == Self.costLimitCode { throw stopped }
                            catch let failed where !(failed is CancellationError) && !Task.isCancelled { throw overflow }
                            try Task.checkCancellation()
                            // Pi continues its loop after the compaction, delivering queued steering first.
                            if try await drainSteering() { overflowRecoveryAttempted=false }
                            prepared=try await prepareRequest(appliedSnapshot ?? prepared.snapshot)
                        }
                    }
                    guard let reply=completed else { throw AgentError("provider_failed","No model response") }
                    // Pi's mapStopReason: incomplete for any reason but max_output_tokens is an error.
                    if reply.truncated, let reason=reply.terminal?.incompleteReason, reason != "max_output_tokens" {
                        throw PiErrorText.incompleteFailure(JSON(reason))
                    }
                    turnModelMs += modelMs; cumulativeModelMs = ObservedDuration.adding(cumulativeModelMs, modelMs)
                    modelActive=false
                    if partialTimeline.segments.isEmpty, let timeline=reply.message.responseTimeline { partialTimeline=timeline }
                    partialTimeline.finish(reply.truncated ? "incomplete":"completed")
                    saveResponseLedger(persist:true,terminal:reply.truncated ? "incomplete":"completed"); partialLedgerID=nil
                    var assistant=reply.message
                    if !partialTimeline.segments.isEmpty { assistant.responseTimeline=partialTimeline }
                    // The reply's model time is its own request's; the turn's counts every attempt.
                    assistant.id=partialID ?? assistant.id; assistant.modelMs=modelReplyMs; partialID=nil; currentAttemptIDs=assistant.requestAttemptIDs ?? []
                    // An incomplete reply is a complete row with a reason, not a
                    // failed run, and its calls never run. Only a reply cut at
                    // the output budget is output-limited; the provider can end
                    // one early for another reason (its content filter), which
                    // the row names instead of claiming the limit.
                    let stoppedEarly = reply.truncated ? (reply.terminal?.incompleteReason ?? "max_output_tokens") : nil
                    let outputLimited = stoppedEarly == "max_output_tokens"
                    if let stoppedEarly { assistant.stopReason = outputLimited ? "length" : stoppedEarly }
                    // The reply keeps its usage in pi's shape: the next count rests on it.
                    assistant.usage=PiContext.usage(reply.usage,api:turnProfile.api)
                    assistant.contextUsageBinding = try reply.message.contextUsageBinding ?? RequestContextCounter.usageBinding(prepared.body,profile:turnProfile)
                    // A reply the journal refuses keeps its log, set aside when the run settles.
                    do { try append(assistant) } catch { partialReplyUnsaved=true; flushStreamed(as:assistant.id); throw error }
                    cumulativeUsage.observe(reply.usage)
                    if !outputLimited { overflowRecoveryAttempted=false }
                    event("message_end")
                    await flushRequestLinks()
                    guard !titleTask || reply.calls.isEmpty else { throw AgentError("title_tool_call", (utilityPurpose == "webhook" ? "The webhook's mini model request" : "Title generation") + " returned a tool call. No tool ran and no extra model request was made.") }
                    if let stoppedEarly {
                        for call in reply.calls {
                            let reason = outputLimited ? "Tool call \"\(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments." : "Not executed: the provider ended the reply early (\(stoppedEarly)), so its arguments may be incomplete. Re-issue a complete tool call if it is still needed."
                            try recordTool(call,result:resultText(reason,error:true),started:nil,state:.failed)
                        }
                    } else if !reply.calls.isEmpty {
                        if Task.isCancelled {
                            for pending in reply.calls { try recordTool(pending,result:resultText("Not executed: cancelled before invocation",error:true),started:nil,state:.cancelled) }
                            throw CancellationError()
                        }
                        try await runToolBatch(reply.calls)
                    }
                    await flushRequestLinks()
                    boundary=context; runStatus = .running; try persistState(active:true); event("turn_end")
                    // Pi 0.85.1: steering is consumed after a COMPLETE tool batch.
                    // Follow-ups are consulted only when the agent would stop.
                    if !steering.isEmpty, queueEdit == nil { continue }
                    // Pi continues after any tool batch, also one it failed because the
                    // reply stopped at its output limit, so the model can re-issue the calls.
                    if !reply.calls.isEmpty { continue }
                    // A reply that stopped at the output budget ends the turn like any
                    // other: the row says so, and queued follow-ups go on.
                    if outputLimited { event("output_limit") }
                    // A completed or output-limited answer stays in context.
                    // Compaction runs only before another pending model request.
                    if let coordinator = agentCoordinator, try await coordinator.boundary(self,final:true) { continue }
                    if !steering.isEmpty, queueEdit == nil { continue }
                    try finishPresentedTask(outputLimited ? "output-limited" : "completed")
                    if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                    if !queue.isEmpty, queueEdit == nil { try enforceCostLimit() }
                    if try await startFollowUp() { overflowRecoveryAttempted=false; continue }
                    break
                }
            }
            state = .idle; runStatus = .idle; errorMessage=nil; errorCode=nil
        } catch {
            // Settling a failed family cancels this task too. Preserve the
            // original outcome before that internal Stop, and leave ordinary
            // chats on their existing failure path until a family is accepted.
            let cancelled = Task.isCancelled || error is CancellationError
            modelActive = false
            let budgetError = familyStopReason?.code == Self.costLimitCode ? familyStopReason : (error as? AgentError).flatMap { $0.code == Self.costLimitCode ? $0 : nil }
            // At the limit every chat pauses (`pauseAtCostLimit`); a family's
            // sub-agent turns are parked, not cancelled or waited for.
            if let budgetError {
                stopFamilyAtLimit(budgetError)
            } else if budgetError == nil, !costPaused, !isSubagent, subagents.family != nil, let coordinator = agentCoordinator {
                let owner = id, runtime = displayEpoch, generation = stopCount
                stop()
                await Task { await coordinator.cancel(owner:owner,runtimeID:runtime,through:generation); await coordinator.drain(owner:owner) }.value
            }
            let error: Error = familyStopReason ?? error
            setFamilyWaiting(false)
            // Paused, not failed: Resume goes on from here once the limit is
            // raised. A managed child's turn is parked by its coordinator.
            let pausedAtLimit = costPaused || isSubagent && budgetError != nil
            // A manual compaction the pause cut is done again on Resume.
            if compactOnly, costPaused { costPendingCompaction = true }
            queuePaused=true; runStatus=pausedAtLimit || familyStopReason == nil && cancelled ? .cancelled : .failed; state=runStatus == .cancelled ? .paused : .error
            errorMessage=pausedAtLimit ? (isSubagent ? "Paused at the shared cost limit." : costPausedMessage) : (error as? AgentError)?.message ?? (runStatus == .cancelled ? "Run cancelled. Pending messages are paused; inspect tool effects before retrying." : "Run failed.")
            errorCode=pausedAtLimit ? Self.costLimitCode : runStatus == .failed ? (error as? AgentError)?.code : nil
            if let activeSubmission { commandState(activeSubmission,runStatus.rawValue) }
            if let partial=interruptedPartial(attemptIDs:partialTimeline.segments.first.map { [$0.part.attemptID] } ?? requestObservation.map { [$0.attemptID] }) {
                // Publishing links can suspend below. Once the durable row
                // exists, its former streaming placeholder must not duplicate
                // the same row ID in snapshots taken during that suspension.
                do { try append(partial); partialID=nil } catch { partialReplyUnsaved=true; flushStreamed() }
            }
            do { try finishPresentedTask(runStatus == .cancelled ? "cancelled" : "failed", detail:errorMessage, code:errorCode) }
            catch { activeTaskPresentation=nil; errorMessage="Task outcome could not be saved. Inspect the retained conversation and tool effects before retrying." }
            event("error",["message":JSON(errorMessage ?? "Interrupted")])
        }
        await beforeFinalRequestLinks?()
        await flushRequestLinks()
        if partialID != nil { invalidateDisplay() }
        modelActive=false; partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); end=nowMS(); runTask=nil
        // A run stopped before it began never read these: the next run is a
        // plain one, not a retry or a Resume of this one.
        retrying=false; continuing=false
        // A Retry after a failed Resume answers the turn it continued, never
        // the continuation's own receipt.
        retrySubmission = runStatus == .idle || activeSubmission?.turnID.hasPrefix(Self.continuePrefix) == true ? nil : activeSubmission; activeSubmission=nil
        if let pending=pendingConfiguration { apply(profile:pending.profile, apiKey:pending.apiKey) }
        // The pause landed as the run was settling: the run's own outcome
        // stays, but the chat waits for the family's Resume.
        if costPaused, !isSubagent, !hasWorkAfterCostPause {
            // The reply that crossed the limit was the run's last word:
            // nothing waits for Resume. The chat is simply at its limit, and
            // a new message is refused there as before.
            clearCostPauseWithoutWork()
            if state != .error { state = .idle; runStatus = .idle }
        }
        if costPaused, state != .error {
            queuePaused=true; state = .paused; runStatus = .cancelled
            errorCode=Self.costLimitCode; errorMessage=errorMessage ?? costPausedMessage
        }
        // A reply the journal refused has its log set aside before the run
        // is saved as settled: a reopen of a settled run removes the log.
        if partialReplyUnsaved { removeStreamedLog() }
        do { try persistState(active:false); removeStreamedLog() } catch { errorMessage="Could not durably save session state. Do not replay tool actions without inspecting their effects."; errorCode=nil; state = .error; runStatus = .failed; queuePaused=true }
        event("agent_settled")
        // submit() may accept another message while the last request links
        // are being flushed above. It sees a runTask and queues instead of
        // launching. Manual compaction also bypasses the follow-up loop.
        // Recheck after the final await and hand off atomically, or those
        // accepted messages can sit idle forever. Failed/stopped work stays
        // paused and still requires an explicit Resume.
        if !closed, !queuePaused, queueEdit == nil, state == .idle, !queue.isEmpty || !steering.isEmpty { launch() }
        // A background load of older rows waits for the chat to be idle.
        adoptHistoryFillIfIdle()
        if keepRequested && ephemeral && isIdle { do { _ = try keepNow() } catch { errorMessage="Could not keep side; in-memory content is intact"; event("side.keep-failed") } }
    }
}
