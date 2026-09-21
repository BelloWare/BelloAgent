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
    /// failures, HTTP 408/425/429/5xx and provider errors that describe
    /// overload, rate limits or temporary unavailability. Anything about the
    /// request itself (a bad model, an oversized body, an auth failure) fails
    /// at once, and a cancellation is never retried.
    public static let modelAttempts = 6
    static let retryDelays: [Double] = [1.0, 3.0, 5.0, 8.0, 10.0]
    static func isRetryable(_ error: AgentError) -> Bool {
        if let failure=error.failure, [.inputContextExceeded,.inputPlusOutputContextExceeded,.outputLimitInvalid,.requestBodyTooLarge,.authentication].contains(failure) { return false }
        switch error.code {
        case "provider_transport", "stream_backpressure": return true
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
        while true {
            attempt += 1
            let generation=beginObservationGeneration(profile:profile)
            do {
                let reply = try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:id,turnID:turnID,purpose:purpose,onObservation:{ [weak self] observation in await self?.observeOperation(observation,generation:generation,operation:operation) },onDelta:onDelta)
                retryInfo = .null
                return reply
            } catch let error as AgentError {
                guard attempt < Self.modelAttempts, Self.isRetryable(error), !Task.isCancelled else {
                    retryInfo = .null
                    throw attempt > 1 ? AgentError(error.code, "Failed after \(attempt) attempts. " + error.message,failure:error.failure,attemptID:error.attemptID) : error
                }
                try reset()
                retryInfo = ["attempt": JSON(attempt + 1), "of": JSON(Self.modelAttempts), "reason": JSON(error.message)]
                runStatus = "retrying"; event("retry", retryInfo)
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { retryInfo = .null; throw error }
                runStatus = "running"; event("state")
            }
        }
    }
    func observeOperation(_ observation: RequestObservation, generation: UInt64, operation: JSON) async {
        monitor(observation)
        observe(observation,generation:generation)
        if observation.phase == "awaiting", !operation.isNull { await traces.operation(observation.attemptID,operation) }
    }
    func run(compactOnly: Bool) async {
        do {
            try Task.checkCancellation(); state="running"; runStatus="running"; try persistState(active:true); event("state")
            if compactOnly { try await compactContext();if let activeSubmission { commandState(activeSubmission,"completed") } }
            else {
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
                    var count=try contextCounter.count(request:request,profile:turnProfile,baseline:contextBaseline)
                    currentContextCount=count
                    // The output budget is a reserve, not a rule: when the estimate says the
                    // reply may not fit beside the input, older turns are folded first, but a
                    // request whose input fits the window is always sent, with its cap clipped
                    // to the room that is left. Only input that cannot fit at all stops a turn.
                    if !count.fits, autoCompaction, canCompact {
                        try await compactContext(reason:"threshold")
                        if !drained && !resumingFailedRequest { _ = try await drainSteering() }
                        resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                        definitions=await sessionDefinitions()
                        instructions=Self.requestInstructions(resourceSnapshot.prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
                        request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                        count=try contextCounter.count(request:request,profile:turnProfile,baseline:contextBaseline); currentContextCount=count
                        guard count.inputFits else { throw AgentError("context_limit", "Current turn remains too large after compaction; use a new chat or smaller input") }
                    }
                    guard count.inputFits else { throw AgentError("context_limit", "Estimated request input plus the safety margin exceeds configured capacity; use a new chat or smaller input") }
                    var modelMs=0.0
                    let operationID=UUID().uuidString
                    var recovered=false, completed: ModelReply?
                    while completed == nil {
                        try Task.checkCancellation()
                        let dispatchProfile=try turnProfile.dispatching(count)
                        partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000; activeTaskPresentation?.operationID=operationID
                        partialText=""; partialThinking=""; resetPartialRow(); invalidateDisplay(); runStatus="running"; modelActive=true; event("message_start")
                        let requestStart=nowMS()
                        do {
                            completed=try await completeWithRetries(profile:dispatchProfile,messages:context,instructions:instructions,tools:definitions,turnID:currentTurnID,purpose:titleTask ? "title" : "turn",operation:["logicalRequestId":JSON(operationID),"recovered":JSON(recovered),"recovery":recovered ? contextRecovery : .null],onDelta:{ [weak self] delta in await self?.delta(delta) },reset:{
                                if let partialID, !partialText.isEmpty || !partialThinking.isEmpty {
                                    var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]])
                                    partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"
                                    partial.requestAttemptIDs=requestObservation.map { [$0.attemptID] }
                                    try append(partial)
                                }
                                partialID=UUID().uuidString; partialStartedAt=Date().timeIntervalSince1970 * 1000
                                partialText=""; partialThinking=""; resetPartialRow()
                                if let partialID { recordDisplayChange(partialID, at: displayClock()) }
                            })
                            modelMs += nowMS()-requestStart
                        } catch let error as AgentError {
                            modelMs += nowMS()-requestStart
                            guard error.failure?.contextRejection == true, autoCompaction, !titleTask, !recovered, canCompact, !Task.isCancelled else { throw error }
                            // Recovery surrounds only this failed model operation.
                            // The completed tool batch is never entered a second time.
                            if let partialID, !partialText.isEmpty || !partialThinking.isEmpty {
                                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]])
                                partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"; partial.requestAttemptIDs=error.attemptID.map { [$0] }
                                try append(partial)
                            }
                            partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); modelActive=false
                            let recovery: JSON=["logicalRequestId":JSON(operationID),"consumed":true,"failedAttemptId":error.attemptID.map { JSON($0) } ?? .null,"failedFingerprint":JSON(count.requestFingerprint),"failure":JSON(error.failure!.rawValue)]
                            try journal?.append(["type":"custom","customType":"pi-app.context-recovery.v1","data":recovery],flush:true)
                            contextRecovery=recovery; recovered=true
                            try await compactContext(reason:"context-rejection")
                            try Task.checkCancellation()
                            // Pending steering keeps its normal next-boundary admission.
                            request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                            count=try contextCounter.count(request:request,profile:turnProfile); currentContextCount=count
                            guard count.inputFits else { throw AgentError("context_limit","Context recovery could not fit this request. Your conversation and tool results are retained.") }
                        }
                    }
                    guard let reply=completed else { throw AgentError("provider_failed","No model response") }
                    turnModelMs += modelMs; cumulativeModelMs = ObservedDuration.adding(cumulativeModelMs, modelMs)
                    modelActive=false
                    var assistant=reply.message; assistant.id=partialID ?? assistant.id; assistant.modelMs=modelMs; partialID=nil; currentAttemptIDs=assistant.requestAttemptIDs ?? []
                    // A reply cut at the output budget is a complete row with a reason, not a failed run.
                    if reply.truncated { assistant.stopReason="length" }
                    try append(assistant); cumulativeUsage.observe(reply.usage)
                    contextBaseline=try RequestUsageBaseline(request:request,profile:turnProfile,reply:reply)
                    event("message_end")
                    await flushRequestLinks()
                    guard !titleTask || reply.calls.isEmpty else { throw AgentError("title_tool_call", "Title generation returned a tool call. No tool ran and no extra model request was made.") }
                    for (i,call) in reply.calls.enumerated() {
                        if Task.isCancelled {
                            for pending in reply.calls.dropFirst(i) { try recordTool(pending,result:resultText("Not executed: cancelled before invocation",error:true),started:nil,state:"cancelled") }
                            throw CancellationError()
                        }
                        if reply.truncated { try recordTool(call,result:resultText("Not executed: model hit its output limit and arguments may be truncated. Re-issue a complete tool call.",error:true),started:nil,state:"failed"); continue }
                        let start=nowMS(); runStatus="waitingTool"
                        setToolStateOwner(call.id)
                        let fields=toolInputFields(call.arguments)
                        setToolState(call.id,merging(["id":JSON(call.id),"name":JSON(call.name),"state":"running","output":"","durationMs":.null,"truncated":JSON(fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false)],fields))
                        recordDisplayChange(toolStateOwners[call.id], at: displayClock())
                        event("tool_execution_start")
                        do { let result=try await invokeTool(call); try recordTool(call,result:result,started:start,state:result["isError"].flag == true ? "failed" : "completed") }
                        catch {
                            let cancelled=Task.isCancelled || error is CancellationError
                            let text=cancelled ? "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay." : (error as? AgentError)?.message ?? "Tool failed; inspect its effects before retrying."
                            try recordTool(call,result:resultText(text,error:true),started:start,state:cancelled ? "cancelled" : "failed",uncertain:Self.isEditing(call))
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
                    if reply.truncated { event("output_limit") }
                    try finishPresentedTask(reply.truncated ? "output-limited" : "completed")
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
            if let partialID, !partialText.isEmpty || !partialThinking.isEmpty {
                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]]); partial.id=partialID; partial.replayEligible=false; partial.stopReason="interrupted"
                let latest = await traces.latest(id)
                if latest["turnId"].text == currentTurnID, let attempt = latest["attemptId"].text { partial.requestAttemptIDs=[attempt] }
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
