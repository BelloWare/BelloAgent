import Foundation

// The run loop: one task per session that answers a turn, executes the
// tool calls it asks for, and retries transient gateway failures.

extension AgentSession {
    func launch(compactOnly: Bool = false) {
        state="running"; runStatus=state; errorMessage=nil; begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0
        runTask=Task { await run(compactOnly:compactOnly) }; event("state")
    }
    func flushRequestLinks() async {
        let pending = pendingRequestLinks; pendingRequestLinks = [:]
        for (attempt, ids) in pending { await traces.outputs(attempt, messageIDs: ids) }
    }
    /// A model request is tried up to three times before its failure is
    /// reported. Only transient gateway conditions are retried: transport
    /// failures, HTTP 408/425/429/5xx and provider errors that describe
    /// overload, rate limits or temporary unavailability. Anything about the
    /// request itself (a bad model, an oversized body, an auth failure) fails
    /// at once, and a cancellation is never retried.
    public static let modelAttempts = 3
    static let retryDelays: [Double] = [1.0, 3.0]
    static func isRetryable(_ error: AgentError) -> Bool {
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
    func completeWithRetries(profile: Profile, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void, reset: () -> Void) async throws -> ModelReply {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let reply = try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,sessionID:id,turnID:turnID,purpose:purpose,onDelta:onDelta)
                retryInfo = .null
                return reply
            } catch let error as AgentError {
                guard attempt < Self.modelAttempts, Self.isRetryable(error), !Task.isCancelled else {
                    retryInfo = .null
                    throw attempt > 1 ? AgentError(error.code, "Failed after \(attempt) attempts. " + error.message) : error
                }
                reset()
                retryInfo = ["attempt": JSON(attempt + 1), "of": JSON(Self.modelAttempts), "reason": JSON(error.message)]
                runStatus = "retrying"; event("retry", retryInfo)
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { retryInfo = .null; throw error }
                runStatus = "running"; event("state")
            }
        }
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
                    var definitions=await tools.definitions(readOnly:readOnly)
                    var instructions=Self.requestInstructions(resourceSnapshot.prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
                    var request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                    var count=try contextCounter.count(request:request,profile:turnProfile,baseline:contextBaseline)
                    currentContextCount=count
                    // The output budget is a reserve, not a rule: when the estimate says the
                    // reply may not fit beside the input, older turns are folded first, but a
                    // request whose input fits the window is always sent, with its cap clipped
                    // to the room that is left. Only input that cannot fit at all stops a turn.
                    if !count.fits, autoCompaction, canCompact {
                        try await compactContext()
                        if !drained && !resumingFailedRequest { _ = try await drainSteering() }
                        resourceSnapshot=appliedSnapshot ?? resourceSnapshot
                        definitions=await tools.definitions(readOnly:readOnly)
                        instructions=Self.requestInstructions(resourceSnapshot.prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
                        request=try ProviderClient.requestBody(profile:turnProfile,messages:context,instructions:instructions,tools:definitions,sessionID:id)
                        count=try contextCounter.count(request:request,profile:turnProfile,baseline:contextBaseline); currentContextCount=count
                        guard count.inputFits else { throw AgentError("context_limit", "Current turn remains too large after compaction; use a new chat or smaller input") }
                    }
                    guard count.inputFits else { throw AgentError("context_limit", "Estimated request input plus the safety margin exceeds configured capacity; use a new chat or smaller input") }
                    let dispatchProfile=try turnProfile.dispatching(count)
                    partialID=UUID().uuidString; partialText=""; partialThinking=""; resetPartialRow(); invalidateDisplay(); runStatus="running"; modelActive=true; event("message_start")
                    let modelStart=nowMS()
                    let reply=try await completeWithRetries(profile:dispatchProfile,messages:context,instructions:instructions,tools:definitions,turnID:currentTurnID,purpose:titleTask ? "title" : "turn",onDelta:{ [weak self] delta in await self?.delta(delta) },reset:{
                        // A retried request starts its reply over; the partial from the failed attempt is dropped.
                        partialText=""; partialThinking=""; resetPartialRow()
                        if let partialID { recordDisplayChange(partialID, at: displayClock()) }
                    })
                    let modelMs=nowMS()-modelStart; turnModelMs += modelMs; cumulativeModelMs = ObservedDuration.adding(cumulativeModelMs, modelMs)
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
                            try recordTool(call,result:resultText(text,error:true),started:start,state:cancelled ? "cancelled" : "failed")
                            if cancelled { for pending in reply.calls.dropFirst(i+1) { try recordTool(pending,result:resultText("Not executed: cancelled",error:true),started:nil,state:"cancelled") }; throw CancellationError() }
                        }
                    }
                    await flushRequestLinks()
                    boundary=context; runStatus="running"; try persistState(active:true); event("turn_end")
                    // Pi 0.85.1: steering is consumed after a COMPLETE tool batch.
                    // Follow-ups are consulted only when the agent would stop.
                    if !steering.isEmpty { continue }
                    if !reply.calls.isEmpty { continue }
                    // A reply that stopped at the output budget ends the turn like any
                    // other: the row says so, and queued follow-ups go on.
                    if reply.truncated { event("output_limit") }
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
                var partial=ChatMessage(role:"assistant",content:[textBlock(partialText),["type":"thinking","thinking":JSON(partialThinking)]]); partial.id=partialID; partial.replayEligible=false
                let latest = await traces.latest(id)
                if latest["turnId"].text == currentTurnID, let attempt = latest["attemptId"].text { partial.requestAttemptIDs=[attempt] }
                // Publishing links can suspend below. Once the durable row
                // exists, its former streaming placeholder must not duplicate
                // the same row ID in snapshots taken during that suspension.
                do { try append(partial); self.partialID=nil } catch { }
            }
            event("error",["message":JSON(errorMessage ?? "Interrupted")])
        }
        await flushRequestLinks()
        if partialID != nil { invalidateDisplay() }
        modelActive=false; partialID=nil; partialText=""; partialThinking=""; resetPartialRow(); end=nowMS(); runTask=nil
        retrySubmission = runStatus == "idle" ? nil : activeSubmission; activeSubmission=nil
        if let pending=pendingConfiguration { apply(profile:pending.profile, apiKey:pending.apiKey) }
        do { try persistState(active:false) } catch { errorMessage="Could not durably save session state. Do not replay tool actions without inspecting their effects."; state="error"; runStatus="failed" }
        event("agent_settled")
        if keepRequested && ephemeral && isIdle { do { _ = try keepNow() } catch { errorMessage="Could not keep side; in-memory content is intact"; event("side.keep-failed") } }
    }
}
