import Foundation

extension AgentSession {
    /// Pi's generateSummary (generateTurnPrefixSummary for a split turn with
    /// nothing new before it): one request carrying the whole source, retried
    /// as pi's retryAssistantCall retries it. Ours: a compaction is this one
    /// request (the owner's rule), never chunks, and a split turn's prefix is
    /// summarized in it (CompactionSourceBuilder.prompt). A request that would
    /// not leave `room` free for its summary is not sent, where pi's
    /// clampMaxTokensToContext would clip the summary, and a request the
    /// gateway rejects as too long is not sent again: either way the
    /// compaction fails and the context stays as it was. Nothing is published
    /// into active context until the checkpoint is adopted.
    func summarize(_ prompt: String, room: Int, profile: Profile, originalProfile: Profile, revision: UInt64, sourceIDs: [String]) async throws -> String {
        // The summary profile's output budget is `room`: the request fits as
        // any request does, its input beside that budget and the margin.
        let messages=summaryMessages(prompt,sourceIDs:sourceIDs), count=try summaryCount(messages,profile:profile)
        guard count.fits else {
            func tokens(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier:"en_US"))) }
            throw AgentError("compaction_too_large","The history to summarize (about \(tokens(count.requestTokens)) tokens) and the summary's \(tokens(room))-token room do not fit this model's \(tokens(profile.contextWindow))-token window in one request. Nothing was sent, and the context is unchanged. Switch to a model with a larger window, or start a new chat.")
        }
        var used=0
        do {
            let reply=try await summaryReply(messages,profile:profile,originalProfile:originalProfile,revision:revision,
                                             limit:min(max(1,compactionPolicy.maximumAttempts),1+max(0,retrySettings.enabled ? retrySettings.maxRetries : 0)),used:&used)
            return try adopt(reply,cap:room)
        } catch let error as AgentError where Self.isContextOverflow(error) {
            throw AgentError("compaction_too_large","The gateway rejected the summary request as longer than the model's window. The context is unchanged. Switch to a model with a larger window, or start a new chat.",attemptID:error.attemptID)
        }
    }

    /// The summary request's one user message.
    func summaryMessages(_ prompt: String, sourceIDs: [String]) -> [ChatMessage] {
        var source=ChatMessage(role:"user",content:[textBlock(prompt)])
        source.sourceMessageIDs=sourceIDs
        return [source]
    }
    /// A summary request sized as pi sizes one: its system prompt and message.
    func summaryCount(_ messages: [ChatMessage], profile: Profile) throws -> RequestContextCount {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id,promptCaching:false)
        return try contextCounter.count(messages:messages,profile:profile,request:body,reportedUsage:false)
    }

    /// One summary request, retried as pi's retryAssistantCall retries it:
    /// a failure pi reads as transient gets settings.retry's retries, within
    /// `limit` physical attempts counted in `used`.
    func summaryReply(_ messages: [ChatMessage], profile: Profile, originalProfile: Profile, revision: UInt64, limit: Int, used: inout Int) async throws -> ModelReply {
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
                // The model's output limit, clipped as pi clips any request to
                // the room left, and never below the summary's room.
                let count=try summaryCount(messages,profile:profile)
                let room=max(profile.maxOutput,PiContext.outputRoom(contextWindow:profile.contextWindow,requestTokens:count.requestTokens))
                let dispatched=try profile.wireOutputLimit.map { $0 > room ? try profile.capped(room) : profile } ?? profile
                let reply=try await client.complete(profile:dispatched,apiKey:apiKey,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id,turnID:currentTurnID,purpose:"compaction",onObservation:{ [weak self] in await self?.compactionObservation($0) },onDelta:{ [weak self] in await self?.compactionDelta($0) })
                requestMs=nowMS()-start
                return try await received(reply,cap:profile.maxOutput,revision:revision,originalProfile:originalProfile)
            } catch let error as AgentError {
                requestMs=nowMS()-start
                operationStatus("Summary request failed: " + error.message)
                if let attempt=error.attemptID, !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
                guard !Self.isContextOverflow(error), retrySettings.enabled, retries<retrySettings.maxRetries, used<limit,
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
        // Pi: a length stop is a partial summary and never a checkpoint.
        if reply.terminal?.outputExhausted == true {
            throw summaryFailure("compaction_output_exhausted","Summary generation hit the model's output limit, so the summary is incomplete and was not adopted.",outcome:outcome)
        }
        guard !reply.truncated, reply.message.stopReason != "length", reply.terminal?.status != "incomplete" else {
            throw summaryFailure("compaction_incomplete","Summary generation ended incompletely for a non-token or unknown reason. Inspect the captured response.",outcome:outcome)
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
