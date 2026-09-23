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
        state="running"; runStatus=state; errorMessage=nil; begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0
        runTask=Task { await run(compactOnly:compactOnly) }; event("state")
    }
    func flushRequestLinks() async {
        let pending = pendingRequestLinks; pendingRequestLinks = [:]
        for (attempt, ids) in pending { await traces.outputs(attempt, messageIDs: ids) }
    }
    /// A model request gets five retries after its initial failure before it is
    /// reported. Only transient gateway conditions are retried: transport
    /// failures, a stream that ended before its terminal event, HTTP
    /// 408/425/429/5xx and provider errors that describe
    /// overload, rate limits or temporary unavailability. Anything about the
    /// request itself (a bad model, an oversized body, an auth failure) fails
    /// at once, and a cancellation is never retried.
    public static let modelAttempts = 6
    static let retryDelays: [Double] = [1.0, 3.0, 5.0, 8.0, 10.0]
    static func isRetryable(_ error: AgentError) -> Bool {
        if let failure=error.failure, [.inputContextExceeded,.inputPlusOutputContextExceeded,.outputLimitInvalid,.requestBodyTooLarge,.authentication].contains(failure) { return false }
        switch error.code {
        // A stream cut before its terminal event ran no tool; its partial
        // reply is kept as an interrupted row before the request is resent.
        case "provider_transport", "stream_backpressure", "incomplete_stream": return true
        case "provider_http":
            guard let status = httpStatus(in: error.message) else { return true }
            return status == 408 || status == 425 || status == 429 || status >= 500
        case "provider_failed":
            let text = error.message.lowercased()
            if ["not_found", "not found", "invalid", "unsupported", "authentication", "unauthorized", "permission", "quota", "context_length", "context length", "too large", "billing"].contains(where: { text.contains($0) }) { return false }
            return ["overloaded", "rate limit", "rate_limit", "server_error", "server error", "internal error", "timeout", "timed out", "temporar", "unavailable", "capacity", "try again", "(529", "(503", "(502"].contains { text.contains($0) }
        default: return false
        }
    }
    static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(5))
    }
    func completeWithRetries(profile: Profile, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], turnID: String, purpose: String, operation: JSON = .null, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void, reset: () throws -> Void) async throws -> ModelReply {
        var attempt = 0
        modelRequestsMs = 0; modelReplyMs = 0
        // The retry notice describes this request only. It goes whichever way
        // the request ends: a reply, a failure, or a Stop that cancels the
        // retried request itself (thrown as a CancellationError, not an
        // AgentError, so no catch below would see it).
        defer { retryInfo = .null }
        while true {
            attempt += 1
            let generation=beginObservationGeneration(profile:profile)
            // Each attempt's own duration; the back-off below is not model time.
            let started=nowMS(); var measured=false
            defer { if !measured { modelRequestsMs += nowMS()-started } }
            do {
                let reply = try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:id,turnID:turnID,purpose:purpose,onObservation:{ [weak self] observation in await self?.observeOperation(observation,generation:generation,operation:operation) },onDelta:onDelta)
                modelReplyMs = nowMS()-started; modelRequestsMs += modelReplyMs; measured = true
                return reply
            } catch let error as AgentError {
                modelRequestsMs += nowMS()-started; measured = true
                guard attempt < Self.modelAttempts, Self.isRetryable(error), !Task.isCancelled else {
                    throw attempt > 1 ? AgentError(error.code, "Failed after \(attempt) attempts. " + error.message,failure:error.failure,attemptID:error.attemptID) : error
                }
                try reset()
                retryInfo = ["attempt": JSON(attempt + 1), "of": JSON(Self.modelAttempts), "reason": JSON(error.message)]
                runStatus = "retrying"; event("retry", retryInfo)
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                runStatus = "running"; event("state")
            }
        }
    }
    func observeOperation(_ observation: RequestObservation, generation: UInt64, operation: JSON) async {
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
                let priorContext=context
                if steering.isEmpty, !retrying { _ = try await startFollowUp() }
                let retryFirstRequest=retrying
                retrying=false
                var rounds=0
                while true {
                    try Task.checkCancellation(); rounds += 1
                    guard rounds <= 256 else { throw AgentError("turn_limit", "Run stopped after 256 model requests; continue explicitly") }
                    // Retry repeats the failed model request before pending steering
                    // reaches its next complete model/tool boundary.
                    let resumingFailedRequest=retryFirstRequest && rounds == 1
                    let drained=resumingFailedRequest ? false : try await drainSteering()
                    var resourceSnapshot: ResourceSnapshot
                    if let appliedSnapshot { resourceSnapshot=appliedSnapshot }
                    else { resourceSnapshot=try await resources.resolve(); appliedSnapshot=resourceSnapshot }
                    appliedRevision=resourceSnapshot.revision
                    var definitions=await sessionDefinitions()
                    var instructions=Self.requestInstructions(resourceSnapshot.prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
                    var request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                    var count=try countContext(context,request:request)
                    currentContextCount=count
                    // Pi 0.85.1 checks the threshold before a new prompt joins the context
                    // (Case 3 of _checkCompaction, on the reply before it) and before each
                    // later request of the run (_compactBeforeNextAssistantResponse), where
                    // the context is unknown after a compaction until a reply reports usage.
                    // A retried request is not checked again. A request whose input fits the
                    // window is always sent, with its cap clipped to the room that is left.
                    // Pi never refuses a request on its estimate: a request the gateway
                    // rejects as too long is compacted and retried once below.
                    let thresholdTokens=resumingFailedRequest ? nil : rounds == 1 ? PiContext.promptThresholdTokens(priorContext) : count.tokens
                    if let thresholdTokens, PiContext.shouldCompact(thresholdTokens,contextWindow:turnProfile.contextWindow,settings:compactionSettings), canCompact {
                        try await compactContext(reason:"threshold")
                        if !drained && !resumingFailedRequest { _ = try await drainSteering() }
                        resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                        definitions=await sessionDefinitions()
                        instructions=Self.requestInstructions(resourceSnapshot.prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
                        request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                        count=try countContext(context,request:request); currentContextCount=count
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
                            completed=try await completeWithRetries(profile:dispatchProfile,messages:context,instructions:instructions,tools:definitions,turnID:currentTurnID,purpose:titleTask ? "title" : "turn",operation:["logicalRequestId":JSON(operationID),"recovered":JSON(recovered),"recovery":recovered ? contextRecovery : .null],onDelta:{ [weak self] delta in await self?.delta(delta) },reset:{
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
                            })
                            modelMs += modelRequestsMs
                        } catch let error as AgentError {
                            modelMs += modelRequestsMs
                            guard error.failure?.contextRejection == true, autoCompaction, !titleTask, !recovered, canCompact(recovering:true), !Task.isCancelled else { throw error }
                            // Recovery surrounds only this failed model operation.
                            // The completed tool batch is never entered a second time.
                            if let partialID, !partialText.isEmpty || !partialThinking.isEmpty || !partialTimeline.segments.isEmpty {
                                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]])
                                partial.responseTimeline=partialTimeline; partial.responseTimeline?.finish("interrupted")
                                    partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"; partial.requestAttemptIDs=error.attemptID.map { [$0] }
                                try append(partial)
                            }
                            partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); modelActive=false
                            let recovery: JSON=["logicalRequestId":JSON(operationID),"consumed":true,"failedAttemptId":error.attemptID.map { JSON($0) } ?? .null,"failedFingerprint":count.requestFingerprint.map { JSON($0) } ?? .null,"failure":JSON(error.failure!.rawValue)]
                            try journal?.append(["type":"custom","customType":"pi-app.context-recovery.v1","data":recovery],flush:true)
                            contextRecovery=recovery; recovered=true
                            try await compactContext(reason:"context-rejection")
                            try Task.checkCancellation()
                            // Pending steering keeps its normal next-boundary admission.
                            request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                            count=try countContext(context,request:request); currentContextCount=count
                        }
                    }
                    guard let reply=completed else { throw AgentError("provider_failed","No model response") }
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
                    let replyID=assistant.id
                    event("message_end")
                    await flushRequestLinks()
                    guard !titleTask || reply.calls.isEmpty else { throw AgentError("title_tool_call", "Title generation returned a tool call. No tool ran and no extra model request was made.") }
                    for (i,call) in reply.calls.enumerated() {
                        if Task.isCancelled {
                            for pending in reply.calls.dropFirst(i) { try recordTool(pending,result:resultText("Not executed: cancelled before invocation",error:true),started:nil,state:"cancelled") }
                            throw CancellationError()
                        }
                        if let stoppedEarly {
                            let reason = outputLimited ? "Not executed: model hit its output limit and arguments may be truncated. Re-issue a complete tool call." : "Not executed: the provider ended the reply early (\(stoppedEarly)), so its arguments may be incomplete. Re-issue a complete tool call if it is still needed."
                            try recordTool(call,result:resultText(reason,error:true),started:nil,state:"failed"); continue
                        }
                        let start=nowMS(); runStatus="waitingTool"; toolInvocationBegan=nil
                        setToolStateOwner(call.id)
                        let fields=toolInputFields(call.arguments)
                        setToolState(call.id,merging(["id":JSON(call.id),"name":JSON(call.name),"state":"running","output":"","durationMs":.null,"truncated":JSON(fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false)],fields))
                        recordDisplayChange(toolStateOwners[call.id], at: displayClock())
                        event("tool_execution_queued")
                        do { let result=try await invokeTool(call); try recordTool(call,result:result,started:start,state:result["isError"].flag == true ? "failed" : "completed") }
                        catch {
                            let cancelled=Task.isCancelled || error is CancellationError
                            // A call stopped before its tool was entered (still
                            // waiting for the workspace editing gate) never ran.
                            let began=toolInvocationBegan == call.id
                            let text=cancelled ? (began ? "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay." : "Not executed: cancelled before invocation") : (error as? AgentError)?.message ?? "Tool failed; inspect its effects before retrying."
                            // Only an editing tool that had begun, and failed other
                            // than by rejecting the call outright, may have left
                            // effects: its outcome is unknown, never just failed.
                            try recordTool(call,result:resultText(text,error:true),started:began ? start : nil,state:cancelled ? "cancelled" : "failed",uncertain:began && Self.isEditing(call) && !Self.isRejection(error))
                            if cancelled { for pending in reply.calls.dropFirst(i+1) { try recordTool(pending,result:resultText("Not executed: cancelled",error:true),started:nil,state:"cancelled") }; throw CancellationError() }
                        }
                    }
                    await flushRequestLinks()
                    boundary=context; runStatus="running"; try persistState(active:true); event("turn_end")
                    // Pi 0.85.1: steering is consumed after a COMPLETE tool batch.
                    // Follow-ups are consulted only when the agent would stop.
                    if !steering.isEmpty { continue }
                    if !reply.truncated && !reply.calls.isEmpty { continue }
                    // A reply that stopped at the output budget ends the turn like any
                    // other: the row says so, and queued follow-ups go on.
                    if outputLimited { event("output_limit") }
                    // Pi 0.85.1 ends a run with the same check on its last reply (Case 3 of
                    // _checkCompaction) and compacts without a retry. A queued follow-up
                    // continues the run instead and is checked before its request. The reply
                    // is complete either way: a failed compaction keeps the context and says so.
                    if queue.isEmpty, let position=context.lastIndex(where: { $0.id == replyID }),
                       let tokens=PiContext.thresholdTokens(after:position,in:context),
                       PiContext.shouldCompact(tokens,contextWindow:turnProfile.contextWindow,settings:compactionSettings), canCompact {
                        do { try await compactContext(reason:"threshold") }
                        catch where !(error is CancellationError) && !Task.isCancelled {}
                    }
                    try finishPresentedTask(outputLimited ? "output-limited" : "completed")
                    if let activeSubmission { commandState(activeSubmission,"completed") }; self.activeSubmission=nil
                    if try await startFollowUp() { continue }
                    break
                }
            }
            state="idle"; runStatus="idle"; errorMessage=nil
        } catch {
            queuePaused=true; runStatus=Task.isCancelled || error is CancellationError ? "cancelled" : "failed"; state=runStatus == "cancelled" ? "paused" : "error"
            errorMessage=(error as? AgentError)?.message ?? (runStatus == "cancelled" ? "Run cancelled. Pending messages are paused; inspect tool effects before retrying." : "Run failed.")
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
            do { try finishPresentedTask(runStatus == "cancelled" ? "cancelled" : "failed", detail:errorMessage) }
            catch { activeTaskPresentation=nil; errorMessage="Task outcome could not be saved. Inspect the retained conversation and tool effects before retrying." }
            event("error",["message":JSON(errorMessage ?? "Interrupted")])
        }
        await flushRequestLinks()
        if partialID != nil { invalidateDisplay() }
        modelActive=false; partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); end=nowMS(); runTask=nil
        retrySubmission = runStatus == "idle" ? nil : activeSubmission; activeSubmission=nil
        if let pending=pendingConfiguration { apply(profile:pending.profile, apiKey:pending.apiKey) }
        do { try persistState(active:false) } catch { errorMessage="Could not durably save session state. Do not replay tool actions without inspecting their effects."; state="error"; runStatus="failed"; queuePaused=true }
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
