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
                // Pi checks a new prompt against the context before the prompt joins it.
                let priorContext=requestContext
                if steering.isEmpty, !retrying {
                    // A follow-up that cannot be answered stays queued, paused.
                    if !queue.isEmpty { try enforceCostLimit() }
                    _ = try await startFollowUp()
                }
                let retryFirstRequest=retrying
                retrying=false
                // Pi's _overflowRecoveryAttempted: one compact-and-retry until a
                // user message arrives or a reply completes.
                var overflowRecoveryAttempted=false
                // Ours: a mid-run compaction the next measurement still finds over the
                // threshold freed no room; compacting again would loop.
                var compactedWithoutRelief=false
                // The context before this round's steering or follow-up joined it:
                // pi checks the threshold before pending messages are injected.
                var undelivered: [ChatMessage]?
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
                    let beforeDelivery=undelivered ?? requestContext; undelivered=nil
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
                    // Pi 0.85.1 checks the threshold before a new prompt joins the context
                    // (Case 3 of _checkCompaction, on the reply before it) and before each
                    // later request of the run (_compactBeforeNextAssistantResponse), where
                    // the context is unknown after a compaction until a reply reports usage.
                    // A retried request is not checked again. A request whose input fits the
                    // window is always sent, with its cap clipped to the room that is left.
                    // Pi never refuses a request on its estimate: a request the gateway
                    // rejects as too long is compacted and retried once below.
                    let thresholdTokens=resumingFailedRequest ? nil : rounds == 1 ? PiContext.promptThresholdTokens(priorContext) : PiContext.contextUsage(beforeDelivery)?.tokens
                    let overThreshold=thresholdTokens.map { PiContext.shouldCompact($0,contextWindow:turnProfile.contextWindow,settings:compactionSettings) }
                    if overThreshold == false { compactedWithoutRelief=false }
                    if overThreshold == true, rounds > 1, compactedWithoutRelief {
                        throw AgentError("compact_no_progress", "Compacting did not bring this chat back under its context limit: the latest work alone is too large to keep. Continue in a new chat, or compact with a focus (/compact …).")
                    }
                    if overThreshold == true, canCompact {
                        if rounds == 1 {
                            // Pi reports a failed threshold compaction and sends the request anyway.
                            do { try await compactContext(reason:"threshold") }
                            catch where !(error is CancellationError) && !Task.isCancelled {}
                        } else {
                            // Ours: mid-run, pi's next round would try the same failing
                            // summary again, billing a summary and a full request every
                            // round. The run stops with the compaction's error instead.
                            try await compactContext(reason:"threshold")
                            compactedWithoutRelief=true
                        }
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
                    try append(assistant); cumulativeUsage.observe(reply.usage)
                    if !outputLimited { overflowRecoveryAttempted=false }
                    let replyID=assistant.id
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
                    // Pi 0.85.1 ends a run with _checkCompaction on its last reply. A
                    // queued follow-up continues the run instead and is checked before its
                    // request. A failed compaction keeps the context and says so.
                    if queue.isEmpty, let position=context.lastIndex(where: { $0.id == replyID }) {
                        let stop=outputLimited ? "length" : "stop", usage=context[position].usage, window=turnProfile.contextWindow
                        let overflowed=PiProviderRules.isUsageOverflow(stopReason:stop,usage:usage,contextWindow:window)
                        let recoverable=PiProviderRules.isRecoverableLength(stopReason:stop,usage:usage,desiredMaxOutput:turnProfile.modelOutputLimit ?? 0)
                        if autoCompaction, overflowed || recoverable {
                            if stop == "stop" {
                                // Case 2: a completed reply that overflowed the window compacts without a retry.
                                if canCompact {
                                    do { try await compactContext(reason:"overflow") }
                                    catch where !(error is CancellationError) && !Task.isCancelled {}
                                }
                            } else if !overflowRecoveryAttempted, !titleTask, canCompact(recovering:true) {
                                // Case 1: a reply cut below the model's own output limit (or by a
                                // full window) leaves the context, which is compacted, and the
                                // request is made again once.
                                overflowRecoveryAttempted=true
                                let recovery: JSON=["logicalRequestId":JSON(operationID),"consumed":true,"failedAttemptId":currentAttemptIDs.last.map { JSON($0) } ?? .null,
                                                    "failedFingerprint":count.requestFingerprint.map { JSON($0) } ?? .null,"failure":"length"]
                                try journal?.append(["type":"custom","customType":"pi-app.context-recovery.v1","data":recovery],flush:true)
                                contextRecovery=recovery; excludeFromRequests(replyID)
                                var compacted=false
                                do { try await compactContext(reason:"context-rejection"); compacted=true }
                                catch where !(error is CancellationError) && !Task.isCancelled {}
                                // Pi takes the reply out of the rebuilt context again and continues.
                                excludeFromRequests(replyID)
                                if compacted { continue }
                            }
                        } else if let tokens=PiContext.thresholdTokens(after:position,in:context),
                                  PiContext.shouldCompact(tokens,contextWindow:window,settings:compactionSettings), canCompact {
                            // Case 3: the threshold, without a retry.
                            do { try await compactContext(reason:"threshold") }
                            catch where !(error is CancellationError) && !Task.isCancelled {}
                        }
                    }
                    try finishPresentedTask(outputLimited ? "output-limited" : "completed")
                    if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                    undelivered=requestContext
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
