import Foundation

extension AgentSession {
    /// Pi's generateSummary, or generateTurnPrefixSummary when `turnPrefix`:
    /// one request carrying the whole source at pi's cap, retried as pi's
    /// retryAssistantCall retries it. Ours: where that request would not leave
    /// room for the whole cap (pi's clampMaxTokensToContext would clip it and
    /// risk a cut-off summary), or the gateway rejects its size, the source is
    /// summarized in consecutive chunks at the whole cap instead, each chunk's
    /// summary being the next chunk's previous summary: pi's own iterative
    /// update. Nothing is published into active context until the checkpoint
    /// is adopted.
    func summarize(_ parts: [String], previous: String?, turnPrefix: Bool, profile: Profile, originalProfile: Profile, revision: UInt64, sourceIDs: [String], focus: String? = nil) async throws -> String {
        let whole=parts.isEmpty ? [""] : parts, cap=profile.maxOutput
        let messages=summaryMessages(whole[...],previous:previous,turnPrefix:turnPrefix,sourceIDs:sourceIDs,focus:focus)
        let single=try summaryCount(messages,profile:profile)
        // The attempts pi's one request makes count toward the first chunk's.
        var used=0
        if PiContext.sum([single.requestTokens,cap,PiContext.contextSafetyTokens]) <= profile.contextWindow {
            do {
                let reply=try await summaryReply(messages,profile:profile,originalProfile:originalProfile,revision:revision,
                                                 limit:min(max(1,compactionPolicy.maximumAttempts),1+max(0,retrySettings.enabled ? retrySettings.maxRetries : 0)),used:&used)
                return try adopt(reply,cap:cap)
            } catch let error as AgentError where Self.isContextOverflow(error) {
                // Ours: the gateway counted the source past the window; pi would fail here.
            }
        }
        return try await chained(whole,previous:previous,turnPrefix:turnPrefix,profile:profile,originalProfile:originalProfile,revision:revision,sourceIDs:sourceIDs,used:used,focus:focus)
    }

    /// The summary request's one user message.
    func summaryMessages(_ slice: ArraySlice<String>, previous: String?, turnPrefix: Bool, sourceIDs: [String], focus: String? = nil) -> [ChatMessage] {
        var source=ChatMessage(role:"user",content:[textBlock(CompactionSourceBuilder.prompt(slice,previous:previous,turnPrefix:turnPrefix,focus:focus))])
        source.sourceMessageIDs=sourceIDs
        return [source]
    }
    /// A summary request sized as pi sizes one: its system prompt and message.
    func summaryCount(_ messages: [ChatMessage], profile: Profile) throws -> RequestContextCount {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id,promptCaching:false)
        return try contextCounter.count(messages:messages,profile:profile,request:body,reportedUsage:false)
    }

    /// Ours: consecutive chunks, each packed to fit beside the whole cap.
    func chained(_ parts: [String], previous: String?, turnPrefix: Bool, profile: Profile, originalProfile: Profile, revision: UInt64, sourceIDs: [String], used spent: Int = 0, focus: String? = nil) async throws -> String {
        let budget=max(1,compactionPolicy.maximumAttempts)
        var pending=parts, offset=0, summary=previous, capacity=Int.max
        func request(_ slice: ArraySlice<String>) -> [ChatMessage] { summaryMessages(slice,previous:summary,turnPrefix:turnPrefix,sourceIDs:sourceIDs,focus:focus) }
        func measure(_ slice: ArraySlice<String>) throws -> RequestContextCount { try summaryCount(request(slice),profile:profile) }
        func fits(_ count: RequestContextCount) -> Bool { count.fits && count.requestTokens<=capacity }
        var used=spent
        while offset<pending.count {
            try validateCompaction(revision,profile:originalProfile)
            // Pack whole parts by pi's characters over four, then count the request itself.
            let empty=try measure(pending[offset..<offset]), room=min(empty.inputBudget,capacity)-empty.requestTokens
            var count=0, packed=0
            while offset+count<pending.count {
                let part=pending[offset+count], cost=PiContext.tokens(chars:part.utf16.count+2)
                if packed+cost<=room { packed += cost; count += 1; continue }
                // A long part fills the rest of this request and continues in the next.
                guard room-packed>=256, let pieces=CompactionSourceBuilder.split(part,fraction:Double(room-packed)/Double(cost)) else { break }
                pending.replaceSubrange((offset+count)...(offset+count),with:pieces)
            }
            while count>0, try !fits(measure(pending[offset..<(offset+count)])) { count=count*3/4 }
            if count==0 {
                guard pending[offset].utf8.count>512, let halves=CompactionSourceBuilder.split(pending[offset],fraction:0.5) else {
                    throw AgentError("compaction_window_too_small","The summary prompt\(summary == nil ? "" : " and the summary so far") leave no room for history beside the \(profile.maxOutput)-token summary cap in this model's window. Original context is retained; choose a model with a larger window.")
                }
                pending.replaceSubrange(offset...offset,with:halves); continue
            }
            let slice=pending[offset..<(offset+count)], measured=try measure(slice)
            let reply: ModelReply
            do { reply=try await summaryReply(request(slice),profile:profile,originalProfile:originalProfile,revision:revision,limit:budget,used:&used) }
            catch let error as AgentError where Self.isContextOverflow(error) && used<budget {
                // The gateway counts differently: pack smaller, same budget.
                capacity=min(capacity,max(1,measured.requestTokens*2/3)); continue
            }
            summary=try adopt(reply,cap:profile.maxOutput); offset += count; used=0
        }
        return summary ?? ""
    }

    /// One summary request, retried as pi's retryAssistantCall retries it:
    /// a failure pi reads as transient gets settings.retry's retries, within
    /// `limit` physical attempts counted in `used`.
    func summaryReply(_ messages: [ChatMessage], profile: Profile, originalProfile: Profile, revision: UInt64, limit: Int, used: inout Int) async throws -> ModelReply {
        compactionState["phase"]="summarizing"; compactionState["chunk"]=JSON((compactionState["chunk"].int ?? 0)+1)
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
                let reply=try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id,turnID:currentTurnID,purpose:"compaction",onObservation:{ [weak self] in await self?.compactionObservation($0) },onDelta:{ [weak self] in await self?.compactionDelta($0) })
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
            throw summaryFailure("compaction_output_exhausted","Summary generation hit its \(cap)-token cap, so the summary is incomplete and was not adopted.",outcome:outcome)
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
