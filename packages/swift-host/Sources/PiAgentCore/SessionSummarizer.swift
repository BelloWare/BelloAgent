import Foundation

extension AgentSession {
    /// Pi's generateSummary, or generateTurnPrefixSummary when `turnPrefix`,
    /// in one request when its prompt fits beside the whole cap. A longer
    /// source is summarized in consecutive chunks, each chunk's summary being
    /// the next chunk's previous summary: pi's own iterative update. Nothing
    /// is published into active context until the checkpoint is adopted.
    func summarize(_ parts: [String], previous: String?, turnPrefix: Bool, profile: Profile, originalProfile: Profile, revision: UInt64, sourceIDs: [String]) async throws -> String {
        let budget=max(1,compactionPolicy.maximumAttempts)
        var pending=parts.isEmpty ? [""] : parts, offset=0, summary=previous, capacity=Int.max, attempts=0
        func request(_ slice: ArraySlice<String>) -> [ChatMessage] {
            var source=ChatMessage(role:"user",content:[textBlock(CompactionSourceBuilder.prompt(slice,previous:summary,turnPrefix:turnPrefix))])
            source.sourceMessageIDs=sourceIDs
            return [source]
        }
        func measure(_ slice: ArraySlice<String>) throws -> RequestContextCount {
            let messages=request(slice)
            let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id)
            return try contextCounter.count(messages:messages,profile:profile,request:body,reportedUsage:false)
        }
        func fits(_ count: RequestContextCount) -> Bool { count.fits && count.requestTokens<=capacity }
        while offset<pending.count {
            try validateCompaction(revision,profile:originalProfile)
            // Pack whole parts by their escaped size, then count the request itself.
            let empty=try measure(pending[offset..<offset]), room=min(empty.inputBudget,capacity)-empty.requestTokens
            var count=0, used=0
            while offset+count<pending.count {
                let part=pending[offset+count], cost=(JSON(part).encoded().utf8.count+4)/3
                if used+cost<=room { used += cost; count += 1; continue }
                // A long part fills the rest of this request and continues in the next.
                guard room-used>=256, let pieces=CompactionSourceBuilder.split(part,fraction:Double(room-used)/Double(cost)) else { break }
                pending.replaceSubrange((offset+count)...(offset+count),with:pieces)
            }
            while count>0, try !fits(measure(pending[offset..<(offset+count)])) { count=count*3/4 }
            if count==0 {
                guard pending[offset].utf8.count>512, let halves=CompactionSourceBuilder.split(pending[offset],fraction:0.5) else {
                    throw AgentError("compaction_window_too_small","The summary prompt\(summary == nil ? "" : " and the summary so far") leave no room for history beside the \(profile.maxOutput)-token summary cap in this model's window. Original context is retained; choose a model with a larger window.")
                }
                pending.replaceSubrange(offset...offset,with:halves); continue
            }
            let slice=pending[offset..<(offset+count)], messages=request(slice), measured=try measure(slice)
            compactionState["phase"]="summarizing"; compactionState["chunk"]=JSON((compactionState["chunk"].int ?? 0)+1)
            compactionState["outputAllowance"]=JSON(profile.maxOutput)
            event("compaction_progress")
            var reply: ModelReply?, transient=0, repack=false
            while reply==nil && !repack {
                try validateCompaction(revision,profile:originalProfile)
                guard attempts<budget else { throw AgentError("compact_budget", "A summary request reached its \(budget)-attempt limit, including retries. Original context is retained.") }
                compactionPhysicalAttempts += 1; attempts += 1; transient += 1
                compactionState["httpAttempts"]=JSON(compactionPhysicalAttempts); modelActive=true
                // The request's own duration is model time; the back-off
                // before a retry, below, is not.
                let start=nowMS(); var requestMs: Double?
                defer { let ms=requestMs ?? (nowMS()-start); turnModelMs += ms; cumulativeModelMs=ObservedDuration.adding(cumulativeModelMs,ms) }
                do {
                    reply=try await client.complete(profile:profile,apiKey:apiKey,messages:messages,instructions:CompactionSourceBuilder.systemPrompt,tools:[],sessionID:id,turnID:currentTurnID,purpose:"compaction",onObservation:{ [weak self] in await self?.compactionObservation($0) },onDelta:{ [weak self] in await self?.compactionDelta($0) })
                    requestMs=nowMS()-start
                } catch let error as AgentError {
                    requestMs=nowMS()-start
                    operationStatus("Summary request failed: " + error.message)
                    if let attempt=error.attemptID, !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
                    if error.failure?.contextRejection == true {
                        // The gateway counts differently: pack smaller, same budget.
                        capacity=min(capacity,max(1,measured.requestTokens*2/3)); repack=true
                    } else if transient<Self.modelAttempts, Self.isRetryable(error), !Task.isCancelled, attempts<budget {
                        compactionState["phase"]="retrying"; event("compaction_progress")
                        try await Task.sleep(nanoseconds:UInt64(Self.retryDelays[min(transient-1,Self.retryDelays.count-1)]*1_000_000_000))
                    } else { throw error }
                }
            }
            if repack { continue }
            guard let reply else { throw AgentError("compact_failed","Summary response is missing") }
            operationStatus("Summary HTTP response completed")
            if reply.message.responseTimeline == nil, !reply.message.text.isEmpty {
                presentationOrdinal += 1
                compactionDelta(.part(ResponsePartEvent(attemptID:reply.message.requestAttemptIDs?.first ?? compactionPresentationID ?? id,ordinal:presentationOrdinal,itemID:"summary",kind:"text",update:"replace",text:reply.message.text,observedAt:nowMS(),evidence:"canonical")))
            }
            cumulativeUsage.observe(reply.usage)
            for attempt in reply.message.requestAttemptIDs ?? [] where !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
            let outcome=summaryOutcome(reply,cap:profile.maxOutput)
            compactionState["lastAttempt"]=outcome
            compactionState["attemptOutcomes"] = .array(compactionState["attemptOutcomes"].list + [outcome])
            for attempt in reply.message.requestAttemptIDs ?? [] { await traces.operation(attempt,compactionState) }
            try validateCompaction(revision,profile:originalProfile)
            let text=reply.message.text.trimmingCharacters(in:.whitespacesAndNewlines)
            if reply.terminal?.refusal == true { throw summaryFailure("compaction_refused","The gateway refused the summary; inspect this attempt before trying another handoff.",outcome:outcome) }
            guard reply.calls.isEmpty, !reply.message.content.contains(where: { $0["type"].text == "toolCall" }) else {
                throw summaryFailure("compaction_unexpected_tool_call","The summary returned a tool call. It was not executed; inspect the gateway's tool-free behavior.",outcome:outcome)
            }
            // Pi: a length stop is a partial summary and never a checkpoint.
            if reply.terminal?.outputExhausted == true {
                throw summaryFailure("compaction_output_exhausted","Summary generation hit its \(profile.maxOutput)-token cap, so the summary is incomplete and was not adopted.",outcome:outcome)
            }
            guard !reply.truncated, reply.message.stopReason != "length", reply.terminal?.status != "incomplete" else {
                throw summaryFailure("compaction_incomplete","Summary generation ended incompletely for a non-token or unknown reason. Inspect the captured response.",outcome:outcome)
            }
            guard !text.isEmpty else { throw summaryFailure("compaction_empty_summary","The completed response contained no usable summary text. Inspect this attempt before retrying.",outcome:outcome) }
            summary=text; offset += count; attempts=0
        }
        return summary ?? ""
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
