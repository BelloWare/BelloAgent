import Foundation

// The run loop: one task per session that answers a turn, executes the
// tool calls it asks for, and retries transient gateway failures.

extension AgentSession {
    func launch(compactOnly: Bool = false) {
        presentationUtility = compactOnly || titleTask
        if retrying, let root = taskRootID {
            beginPresentedTask(root)
            activeTaskPresentation?.activeInputID = currentTurnID.isEmpty ? root : currentTurnID
            activeTaskPresentation?.anchorSourceID = visible.last?.id ?? root
        }
        state="running"; runStatus=state; errorMessage=nil; errorCode=nil; begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0
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
    static func isRetryable(_ error: AgentError) -> Bool {
        !isContextOverflow(error) && PiProviderRules.isRetryableText(error.piMessage)
    }
    /// Case 1 of pi's isContextOverflow: the provider's text names an overflow.
    /// Ours: the gateway's structured overflow codes count too.
    static func isContextOverflow(_ error: AgentError) -> Bool {
        error.failure?.contextRejection == true || PiProviderRules.isOverflowText(error.piMessage)
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
        let attempts = retrySettings.enabled ? 1 + max(0, retrySettings.maxRetries) : 1
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
            try enforceCostLimit()
            let generation=beginObservationGeneration(profile:profile)
            // Each attempt's own duration; the back-off below is not model time.
            let started=nowMS(); var measured=false
            defer { if !measured { modelRequestsMs += nowMS()-started } }
            do {
                let reply = try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:id,cacheSessionID:promptCacheSessionID,turnID:turnID,purpose:purpose,onObservation:{ [weak self] observation in await self?.observeOperation(observation,generation:generation,operation:operation) },onDelta:onDelta)
                modelReplyMs = nowMS()-started; modelRequestsMs += modelReplyMs; measured = true
                return reply
            } catch let error as AgentError {
                modelRequestsMs += nowMS()-started; measured = true
                guard attempt < attempts, Self.isRetryable(error), !Task.isCancelled else {
                    throw attempt > 1 ? AgentError(error.code, "Failed after \(attempt) attempts. " + error.message,failure:error.failure,attemptID:error.attemptID,providerMessage:error.providerMessage) : error
                }
                try reset()
                retryInfo = ["attempt": JSON(attempt + 1), "of": JSON(attempts), "reason": JSON(error.message)]
                runStatus = "retrying"; event("retry", retryInfo)
                try await Task.sleep(nanoseconds: UInt64(retrySettings.delayMs(attempt: attempt) * 1_000_000))
                runStatus = "running"; event("state")
                if let next = try await refresh() { (profile, messages, instructions, tools) = next }
            }
        }
    }
    func observeOperation(_ observation: RequestObservation, generation: UInt64, operation: JSON) async {
        countAttempt(observation)
        startResponseLedger(observation)
        monitor(observation)
        observe(observation,generation:generation)
        if observation.phase == "awaiting", !operation.isNull { await traces.operation(observation.attemptID,operation) }
    }
    func run(compactOnly: Bool) async {
        do {
            try Task.checkCancellation(); state="running"; runStatus="running"; try persistState(active:true); event("state")
            if compactOnly { try await compactContext();if let activeSubmission { commandState(activeSubmission,"completed") } }
            else {
                // Deliver the next eligible input before sizing the pending request.
                if steering.isEmpty, !retrying {
                    // A follow-up that cannot be answered stays queued, paused.
                    if !queue.isEmpty { try enforceCostLimit() }
                    _ = try await startFollowUp()
                }
                let retryFirstRequest=retrying
                retrying=false
                // Pi's _overflowRecoveryAttempted: one compact-and-retry until a
                // user message arrives or a reply completes.
                var overflowRecoveryAttempted=retryFirstRequest && contextRecovery["consumed"].flag == true
                var rounds=0
                while true {
                    // Pi's agent loop has no limit on model requests per run.
                    try Task.checkCancellation(); rounds += 1
                    // Retry repeats the failed model request before pending steering
                    // reaches its next complete model/tool boundary.
                    let resumingFailedRequest=retryFirstRequest && rounds == 1
                    // Each round makes a model request. At the chat's cost
                    // limit it stops here, before pending steering is delivered.
                    try enforceCostLimit()
                    let drained=resumingFailedRequest ? false : try await drainSteering()
                    if drained { overflowRecoveryAttempted=false }
                    var resourceSnapshot: ResourceSnapshot
                    if let appliedSnapshot { resourceSnapshot=appliedSnapshot }
                    else { resourceSnapshot=try await resources.resolve(); appliedSnapshot=resourceSnapshot }
                    appliedRevision=resourceSnapshot.revision
                    var definitions=await sessionDefinitions()
                    var instructions=Self.requestInstructions(resourceSnapshot.prompt)
                    var request=try ProviderClient.requestBody(profile:turnProfile,messages:requestContext,instructions:instructions,tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
                    var count=try countContext(requestContext,request:request)
                    currentContextCount=count
                    // Include delivered input and complete tool results. Leave
                    // room for an intact-history summary before this request.
                    let threshold = autoCompaction && !titleTask && !resumingFailedRequest
                        ? try compactionThreshold(requestContext,instructions:instructions,profile:turnProfile) : Int.max
                    if count.requestTokens >= threshold, canCompact {
                        do { try await compactContext(reason:"threshold") }
                        catch let error as AgentError where error.code == "compact_unavailable" && count.fits { /* Nothing useful to replace; keep the intact request. */ }
                        if !drained && !resumingFailedRequest, try await drainSteering() { overflowRecoveryAttempted=false }
                        resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                        definitions=await sessionDefinitions()
                        instructions=Self.requestInstructions(resourceSnapshot.prompt)
                        request=try ProviderClient.requestBody(profile:turnProfile,messages:requestContext,instructions:instructions,tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
                        count=try countContext(requestContext,request:request); currentContextCount=count
                    }
                    var modelMs=0.0
                    let operationID=UUID().uuidString
                    var recovered=false, completed: ModelReply?
                    while completed == nil {
                        try Task.checkCancellation()
                        let dispatchProfile=try turnProfile.dispatching(count)
                        partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000; activeTaskPresentation?.operationID=operationID
                        partialText=""; partialThinking=""; resetPartialRow(); invalidateDisplay(); runStatus="running"; modelActive=true; event("message_start")
                        do {
                            completed=try await completeWithRetries(profile:dispatchProfile,messages:requestContext,instructions:instructions,tools:definitions,turnID:currentTurnID,purpose:titleTask ? "title" : "turn",operation:["logicalRequestId":JSON(operationID),"recovered":JSON(recovered),"recovery":recovered ? contextRecovery : .null],onDelta:{ [weak self] delta in await self?.delta(delta) },reset:{
                                if let partialID, !partialText.isEmpty || !partialThinking.isEmpty || !partialTimeline.segments.isEmpty {
                                    var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]])
                                    partial.responseTimeline=partialTimeline; partial.responseTimeline?.finish("interrupted")
                                    partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"
                                    partial.requestAttemptIDs=requestObservation.map { [$0.attemptID] }
                                    try append(partial)
                                }
                                partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000
                                partialText=""; partialThinking=""; resetPartialRow()
                                if let partialID { recordDisplayChange(partialID, at: displayClock()) }
                            },refresh:{
                                // Pi retries by continuing its loop, which first delivers queued steering.
                                guard try await drainSteering() else { return nil }
                                overflowRecoveryAttempted=false
                                resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                                definitions=await sessionDefinitions()
                                instructions=Self.requestInstructions(resourceSnapshot.prompt)
                                request=try ProviderClient.requestBody(profile:turnProfile,messages:requestContext,instructions:instructions,tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
                                count=try countContext(requestContext,request:request); currentContextCount=count
                                return (try turnProfile.dispatching(count),requestContext,instructions,definitions)
                            })
                            modelMs += modelRequestsMs
                        } catch let error as AgentError {
                            modelMs += modelRequestsMs
                            // Case 1 of pi's _checkCompaction: compact and retry once.
                            guard Self.isContextOverflow(error), autoCompaction, !titleTask, !overflowRecoveryAttempted, canCompact(recovering:true), !Task.isCancelled else { throw error }
                            overflowRecoveryAttempted=true
                            // Recovery surrounds only this failed model operation.
                            // The completed tool batch is never entered a second time.
                            if let partialID, !partialText.isEmpty || !partialThinking.isEmpty || !partialTimeline.segments.isEmpty {
                                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]])
                                partial.responseTimeline=partialTimeline; partial.responseTimeline?.finish("interrupted")
                                    partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"; partial.requestAttemptIDs=error.attemptID.map { [$0] }
                                try append(partial)
                            }
                            partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); modelActive=false
                            let failure=error.failure.flatMap { $0.contextRejection ? $0.rawValue : nil } ?? "contextOverflow"
                            let recovery: JSON=["logicalRequestId":JSON(operationID),"consumed":true,"failedAttemptId":error.attemptID.map { JSON($0) } ?? .null,"failedFingerprint":count.requestFingerprint.map { JSON($0) } ?? .null,"failure":JSON(failure)]
                            try journal?.append(["type":"custom","customType":"pi-app.context-recovery.v1","data":recovery],flush:true)
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
                            resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                            definitions=await sessionDefinitions()
                            instructions=Self.requestInstructions(resourceSnapshot.prompt)
                            request=try ProviderClient.requestBody(profile:turnProfile,messages:requestContext,instructions:instructions,tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
                            count=try countContext(requestContext,request:request); currentContextCount=count
                        }
                    }
                    guard let reply=completed else { throw AgentError("provider_failed","No model response") }
                    // Pi's mapStopReason: incomplete for any reason but max_output_tokens is an error.
                    if reply.truncated, let reason=reply.terminal?.incompleteReason, reason != "max_output_tokens" {
                        let text=PiErrorText.incomplete(reason); throw AgentError("provider_incomplete",text,providerMessage:text)
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
                    assistant.contextUsageBinding = try reply.message.contextUsageBinding ?? RequestContextCounter.usageBinding(request,profile:turnProfile)
                    try append(assistant); cumulativeUsage.observe(reply.usage)
                    if !outputLimited { overflowRecoveryAttempted=false }
                    event("message_end")
                    await flushRequestLinks()
                    guard !titleTask || reply.calls.isEmpty else { throw AgentError("title_tool_call", "Title generation returned a tool call. No tool ran and no extra model request was made.") }
                    if let stoppedEarly {
                        for call in reply.calls {
                            let reason = outputLimited ? "Tool call \"\(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments." : "Not executed: the provider ended the reply early (\(stoppedEarly)), so its arguments may be incomplete. Re-issue a complete tool call if it is still needed."
                            try recordTool(call,result:resultText(reason,error:true),started:nil,state:"failed")
                        }
                    } else if !reply.calls.isEmpty {
                        if Task.isCancelled {
                            for pending in reply.calls { try recordTool(pending,result:resultText("Not executed: cancelled before invocation",error:true),started:nil,state:"cancelled") }
                            throw CancellationError()
                        }
                        try await runToolBatch(reply.calls)
                    }
                    await flushRequestLinks()
                    boundary=context; runStatus="running"; try persistState(active:true); event("turn_end")
                    // Pi 0.85.1: steering is consumed after a COMPLETE tool batch.
                    // Follow-ups are consulted only when the agent would stop.
                    if !steering.isEmpty { continue }
                    // Pi continues after any tool batch, also one it failed because the
                    // reply stopped at its output limit, so the model can re-issue the calls.
                    if !reply.calls.isEmpty { continue }
                    // A reply that stopped at the output budget ends the turn like any
                    // other: the row says so, and queued follow-ups go on.
                    if outputLimited { event("output_limit") }
                    // A completed or output-limited answer stays in context.
                    // Compaction runs only before another pending model request.
                    try finishPresentedTask(outputLimited ? "output-limited" : "completed")
                    if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                    if !queue.isEmpty { try enforceCostLimit() }
                    if try await startFollowUp() { overflowRecoveryAttempted=false; continue }
                    break
                }
            }
            state="idle"; runStatus="idle"; errorMessage=nil; errorCode=nil
        } catch {
            queuePaused=true; runStatus=Task.isCancelled || error is CancellationError ? "cancelled" : "failed"; state=runStatus == "cancelled" ? "paused" : "error"
            errorMessage=(error as? AgentError)?.message ?? (runStatus == "cancelled" ? "Run cancelled. Pending messages are paused; inspect tool effects before retrying." : "Run failed.")
            errorCode=runStatus == "failed" ? (error as? AgentError)?.code : nil
            if let activeSubmission { commandState(activeSubmission,runStatus) }
            if let partialID, !partialText.isEmpty || !partialThinking.isEmpty || !partialTimeline.segments.isEmpty {
                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]]); partial.responseTimeline=partialTimeline; partial.responseTimeline?.finish("interrupted")
                                    partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"
                partial.requestAttemptIDs = partialTimeline.segments.first.map { [$0.part.attemptID] } ?? requestObservation.map { [$0.attemptID] }
                // Publishing links can suspend below. Once the durable row
                // exists, its former streaming placeholder must not duplicate
                // the same row ID in snapshots taken during that suspension.
                do { try append(partial); self.partialID=nil } catch { }
            }
            do { try finishPresentedTask(runStatus == "cancelled" ? "cancelled" : "failed", detail:errorMessage, code:errorCode) }
            catch { activeTaskPresentation=nil; errorMessage="Task outcome could not be saved. Inspect the retained conversation and tool effects before retrying." }
            event("error",["message":JSON(errorMessage ?? "Interrupted")])
        }
        await flushRequestLinks()
        if partialID != nil { invalidateDisplay() }
        modelActive=false; partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); end=nowMS(); runTask=nil
        retrySubmission = runStatus == "idle" ? nil : activeSubmission; activeSubmission=nil
        if let pending=pendingConfiguration { apply(profile:pending.profile, apiKey:pending.apiKey) }
        do { try persistState(active:false) } catch { errorMessage="Could not durably save session state. Do not replay tool actions without inspecting their effects."; errorCode=nil; state="error"; runStatus="failed"; queuePaused=true }
        event("agent_settled")
        // submit() may accept another message while the last request links
        // are being flushed above. It sees a runTask and queues instead of
        // launching. Manual compaction also bypasses the follow-up loop.
        // Recheck after the final await and hand off atomically, or those
        // accepted messages can sit idle forever. Failed/stopped work stays
        // paused and still requires an explicit Resume.
        if !closed, !queuePaused, state == "idle", !queue.isEmpty || !steering.isEmpty { launch() }
        if keepRequested && ephemeral && isIdle { do { _ = try keepNow() } catch { errorMessage="Could not keep side; in-memory content is intact"; event("side.keep-failed") } }
    }
}
