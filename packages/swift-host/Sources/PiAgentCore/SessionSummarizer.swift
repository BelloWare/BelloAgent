import Foundation

extension AgentSession {
    /// One frozen normal context plus one request-local instruction. No tool
    /// dispatch continuation exists on this path, even if the gateway ignores
    /// tool_choice. Preflight and dispatch use the same builder and controls.
    func summarize(_ messages: [ChatMessage], instructions: String, tools: [ToolDefinition], profile: Profile,
                   originalProfile: Profile, revision: UInt64) async throws -> String {
        let sessionID=id, cacheSessionID=promptCacheSessionID
        let worker=Task.detached(priority:.userInitiated) {
            let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,
                sessionID:sessionID,cacheSessionID:cacheSessionID,compaction:true)
            try CompactionPlanner.validateRequest(body)
            return try RequestContextCounter().count(messages:messages,profile:profile,request:body)
        }
        let count=try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
        try validateCompaction(revision,profile:originalProfile)
        guard count.fits else {
            throw AgentError("compaction_too_large", "The intact history (about \(count.requestTokens) tokens), checkpoint instruction and \(profile.maxOutput)-token summary allowance do not fit this model's \(profile.contextWindow)-token window. Nothing was sent, and the context is unchanged. Use a larger context window or start a new chat.")
        }
        compactionState["summaryInput"] = count.json
        compactionState["wireCap"] = profile.wireOutputLimit.map { JSON($0) } ?? .null
        var used = 0
        do {
            let reply = try await summaryReply(messages,instructions:instructions,tools:tools,profile:profile,originalProfile:originalProfile,revision:revision,
                limit:min(max(1,compactionPolicy.maximumAttempts),1+max(0,retrySettings.enabled ? retrySettings.maxRetries : 0)),used:&used)
            return try adopt(reply,cap:profile.maxOutput)
        } catch let error as AgentError where Self.isContextOverflow(error) {
            throw AgentError("compaction_too_large", "The gateway rejected the intact summary request as longer than the model's window. The context is unchanged; no alternate summary was sent.", attemptID:error.attemptID)
        }
    }

    /// One summary request, retried as pi's retryAssistantCall retries it:
    /// a failure pi reads as transient gets settings.retry's retries, within
    /// `limit` physical attempts counted in `used`.
    func summaryReply(_ messages: [ChatMessage], instructions: String, tools: [ToolDefinition], profile: Profile, originalProfile: Profile, revision: UInt64, limit: Int, used: inout Int) async throws -> ModelReply {
        compactionState["phase"]="summarizing"
        compactionState["outputAllowance"]=JSON(profile.maxOutput)
        event("compaction_progress")
        var retries=0
        while true {
            try validateCompaction(revision,profile:originalProfile)
            // A summary request is a model request of this chat: at its
            // cost limit none is sent, first attempt or retry.
            try enforceCostLimit()
            guard used<limit else { throw AgentError("compact_budget", "A summary request reached its \(limit)-attempt limit, including retries. Original context is retained.") }
            compactionPhysicalAttempts += 1; used += 1
            compactionState["httpAttempts"]=JSON(compactionPhysicalAttempts); modelActive=true
            // The request's own duration is model time; the back-off
            // before a retry, below, is not.
            let start=nowMS(); var requestMs: Double?
            defer { let ms=requestMs ?? (nowMS()-start); turnModelMs += ms; cumulativeModelMs=ObservedDuration.adding(cumulativeModelMs,ms) }
            do {
                let reply=try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:instructions,tools:tools,
                    sessionID:id,cacheSessionID:promptCacheSessionID,turnID:currentTurnID,purpose:"compaction",
                    onObservation:{ [weak self] in await self?.compactionObservation($0) },onDelta:{ [weak self] in await self?.compactionDelta($0) })
                requestMs=nowMS()-start
                return try await received(reply,cap:profile.maxOutput,revision:revision,originalProfile:originalProfile)
            } catch let error as AgentError {
                requestMs=nowMS()-start
                operationStatus("Summary request failed: " + error.message)
                if let attempt=error.attemptID, !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
                guard !Self.isContextOverflow(error), !["compaction_incompatible", "compact_stale", "provider_incomplete", "provider_refused"].contains(error.code), retrySettings.enabled, retries<retrySettings.maxRetries, used<limit,
                      PiProviderRules.isRetryableText(error.piMessage), !Task.isCancelled else { throw error }
                retries += 1
                compactionState["phase"]="retrying"; event("compaction_progress")
                try await Task.sleep(nanoseconds:UInt64(retrySettings.delayMs(attempt:retries)*1_000_000))
                compactionState["phase"]="summarizing"
            }
        }
    }

    /// Records a completed summary response.
    func received(_ reply: ModelReply, cap: Int, revision: UInt64, originalProfile: Profile) async throws -> ModelReply {
        operationStatus("Summary HTTP response completed")
        if reply.message.responseTimeline == nil, !reply.message.text.isEmpty {
            presentationOrdinal += 1
            compactionDelta(.part(ResponsePartEvent(attemptID:reply.message.requestAttemptIDs?.first ?? compactionPresentationID ?? id,ordinal:presentationOrdinal,itemID:"summary",kind:"text",update:"replace",text:reply.message.text,observedAt:nowMS(),evidence:"canonical")))
        }
        cumulativeUsage.observe(reply.usage)
        for attempt in reply.message.requestAttemptIDs ?? [] where !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
        let outcome=summaryOutcome(reply,cap:cap)
        compactionState["lastAttempt"]=outcome
        compactionState["attemptOutcomes"] = .array(compactionState["attemptOutcomes"].list + [outcome])
        for attempt in reply.message.requestAttemptIDs ?? [] { await traces.operation(attempt,compactionState) }
        try validateCompaction(revision,profile:originalProfile)
        return reply
    }

    /// Pi's getSummarizationFailure and tool-call check, then the text.
    func adopt(_ reply: ModelReply, cap: Int) throws -> String {
        let outcome=summaryOutcome(reply,cap:cap)
        let text=reply.message.text.trimmingCharacters(in:.whitespacesAndNewlines)
        // Ours: a refusal or an empty summary never becomes a checkpoint.
        if reply.terminal?.refusal == true { throw summaryFailure("compaction_refused","The gateway refused the summary; inspect this attempt before trying another handoff.",outcome:outcome) }
        guard reply.calls.isEmpty, !reply.message.content.contains(where: { $0["type"].text == "toolCall" }) else {
            throw summaryFailure("compaction_unexpected_tool_call","The summary returned a tool call. It was not executed; inspect the gateway's tool-free behavior.",outcome:outcome)
        }
        // Hosted/future tool items are retained verbatim by the provider reader
        // even when they are not client-dispatched calls. None is summary text.
        for item in reply.message.providerItems ?? [] {
            let type=item["type"].text ?? ""
            if type.hasSuffix("_call") || type == "tool_use" {
                throw summaryFailure("compaction_unexpected_tool_call","The summary returned a provider tool call despite tool_choice none. No local tool ran and no checkpoint was adopted.",outcome:outcome)
            }
            guard ["message","reasoning"].contains(type) else {
                throw summaryFailure("compaction_unexpected_output","The summary returned unsupported non-text output. Inspect the captured response.",outcome:outcome)
            }
            guard item["status"].isNull || item["status"].text == "completed" else {
                throw summaryFailure("compaction_incomplete","A summary output item did not complete. Inspect the captured response.",outcome:outcome)
            }
        }
        // Pi: a length stop is a partial summary and never a checkpoint.
        if reply.terminal?.outputExhausted == true {
            throw summaryFailure("compaction_output_exhausted","Summary generation hit the model's output limit, so the summary is incomplete and was not adopted.",outcome:outcome)
        }
        guard !reply.truncated, reply.message.stopReason != "length", reply.terminal?.status != "incomplete" else {
            throw summaryFailure("compaction_incomplete","Summary generation ended incompletely for a non-token or unknown reason. Inspect the captured response.",outcome:outcome)
        }
        guard reply.terminal?.status == "completed", reply.terminal?.incompleteReason == nil else {
            throw summaryFailure("compaction_incomplete", "The summary has no unambiguous successful completion evidence.", outcome:outcome)
        }
        guard !text.isEmpty else { throw summaryFailure("compaction_empty_summary","The completed response contained no usable summary text. Inspect this attempt before retrying.",outcome:outcome) }
        return text
    }

    /// Diagnostic fields are typed/allowlisted; neither arbitrary provider text
    /// nor summary/prompt content is promoted into ordinary error diagnostics.
    func summaryOutcome(_ reply: ModelReply, cap: Int) -> JSON {
        let status=reply.terminal?.status,reason=reply.terminal?.incompleteReason
        return ["cap":JSON(cap),"status":JSON(["completed","incomplete"].contains(status ?? "") ? status!:"unknown"),
            "reason":JSON(["max_output_tokens","content_filter"].contains(reason ?? "") ? reason!:"unknown"),
            "refusal":reply.terminal.map { JSON($0.refusal) } ?? .null,
            "attemptIds":.array((reply.message.requestAttemptIDs ?? []).map { JSON($0) }),
            "inputTokens":UsageObservation.count(reply.usage["input"]).map { JSON($0) } ?? .null,
            "outputTokens":UsageObservation.count(reply.usage["output"]).map { JSON($0) } ?? .null,
            "reasoningTokens":UsageObservation.count(reply.usage["reasoning"]).map { JSON($0) } ?? .null]
    }
    func summaryFailure(_ code: String, _ remedy: String, outcome: JSON) -> AgentError {
        let attempts=outcome["attemptIds"].list.compactMap(\.text).joined(separator:", ")
        func observed(_ key: String) -> String { outcome[key].int.map(String.init) ?? "unavailable" }
        let detail="Attempt \(attempts.isEmpty ? "unavailable":attempts); cap \(observed("cap")); reported input \(observed("inputTokens")), output \(observed("outputTokens")) (including reasoning \(observed("reasoningTokens"))); status \(outcome["status"].text ?? "unknown"), reason \(outcome["reason"].text ?? "unknown")."
        return AgentError(code,remedy+" "+detail+" Original context is unchanged.",attemptID:outcome["attemptIds"].list.last?.text)
    }
}
