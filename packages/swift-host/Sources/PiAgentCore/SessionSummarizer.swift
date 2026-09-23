import Foundation

extension AgentSession {
    /// Every chunk, merge and transient retry consumes the same physical HTTP
    /// allowance. Intermediate summaries are never published into active context.
    func summarizeBounded(_ source: [String], profile: Profile, originalProfile: Profile, revision: UInt64, sourceIDs: [String]) async throws -> String {
        let budget=max(1,min(8,compactionPolicy.maximumAttempts))
        var pending=source, level=0, capacity=Int.max
        let allowedCap=profile.outputCap ?? profile.maxOutput
        var budgetRetried=false
        func questions(_ records: [String]) -> [ChatMessage] {
            var source=ChatMessage(role:"user",content:[textBlock(records.joined(separator:"\n"))])
            source.sourceMessageIDs=sourceIDs
            // Stable source first, compaction-specific instructions last. Do not
            // place task directives ahead of evidence and invalidate its prefix.
            return [source,ChatMessage(role:"user",content:[textBlock(CompactionSourceBuilder.instructions)])]
        }
        func prepare(_ records: [String]) throws -> (Profile,RequestContextCount) {
            let messages=questions(records)
            let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:"",tools:[],sessionID:id)
            let packed=try contextCounter.count(messages:messages,profile:profile,request:body,reportedUsage:false)
            guard packed.fits else { return (profile,packed) }
            let cap=min(allowedCap,packed.replyRoom)
            var raw=profile.raw;raw["maxOutputTokens"]=JSON(cap);raw["outputCap"]=JSON(cap)
            let dispatch=try Profile(raw)
            let actual=try ProviderClient.requestBody(profile:dispatch,messages:messages,instructions:"",tools:[],sessionID:id)
            return (dispatch,try contextCounter.count(messages:messages,profile:dispatch,request:actual,reportedUsage:false))
        }
        while true {
            try validateCompaction(revision,profile:originalProfile)
            let inputBytes=pending.reduce(0) { $0+$1.utf8.count }
            var outputs: [String]=[], offset=0
            while offset<pending.count {
                guard compactionPhysicalAttempts<budget else { throw AgentError("compact_budget", "Compaction reached its \(budget)-request limit. Original context is retained.") }
                var low=0, high=pending.count-offset
                while low<high {
                    let mid=(low+high+1)/2, measured=try prepare(Array(pending[offset..<(offset+mid)])).1
                    if measured.fits && measured.requestTokens<=capacity { low=mid } else { high=mid-1 }
                }
                if low==0 {
                    // A single record can exceed a small window. Split its data,
                    // never its active assistant/tool replay group.
                    let bytes=Array(pending[offset].utf8)
                    guard bytes.count>512, pending.count<4096 else { throw AgentError("compaction_source_limit", "Summary instructions and one bounded evidence fragment cannot fit with the configured output reserve. Original context is retained; choose a larger context model or a smaller explicit handoff.") }
                    var split=bytes.count/2
                    while split>0, bytes[split]&0xc0 == 0x80 { split -= 1 }
                    let ref=sha256(Data(bytes)), parts=[bytes[..<split],bytes[split...]].enumerated().map { n, part in
                        JSON.object(["sourceFragment":JSON(ref),"part":JSON(n+1),"of":2,"data":JSON(String(decoding:part,as:UTF8.self))]).encoded()
                    }
                    pending.replaceSubrange(offset...offset,with:parts); continue
                }
                let records=Array(pending[offset..<(offset+low)]), (effectiveProfile,measured)=try prepare(records)
                compactionState["phase"]=JSON(level==0 ? "summarizing" : "merging")
                compactionState["level"]=JSON(level); compactionState["chunk"]=JSON(outputs.count+1)
                compactionState["outputAllowance"]=JSON(effectiveProfile.maxOutput);compactionState["budgetRetry"]=JSON(budgetRetried)
                event("compaction_progress")
                var reply: ModelReply?, transient=0, repack=false
                while reply==nil && !repack {
                    try validateCompaction(revision,profile:originalProfile)
                    guard compactionPhysicalAttempts<budget else { throw AgentError("compact_budget", "Compaction reached its \(budget)-request limit, including retries. Original context is retained.") }
                    compactionPhysicalAttempts += 1; transient += 1
                    compactionState["httpAttempts"]=JSON(compactionPhysicalAttempts); modelActive=true
                    // The request's own duration is model time; the back-off
                    // before a retry, below, is not.
                    let start=nowMS(); var requestMs: Double?
                    defer { let ms=requestMs ?? (nowMS()-start); turnModelMs += ms; cumulativeModelMs=ObservedDuration.adding(cumulativeModelMs,ms) }
                    do {
                        reply=try await client.complete(profile:effectiveProfile,apiKey:apiKey,messages:questions(records),instructions:"",tools:[],sessionID:id,turnID:currentTurnID,purpose:"compaction",onObservation:{ [weak self] in await self?.compactionObservation($0) },onDelta:{ [weak self] in await self?.compactionDelta($0) })
                        requestMs=nowMS()-start
                    } catch let error as AgentError {
                        requestMs=nowMS()-start
                        operationStatus("Summary request failed: " + error.message)
                        if let attempt=error.attemptID, !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
                        if error.failure?.contextRejection == true {
                            capacity=min(capacity,max(1,measured.requestTokens*2/3)); repack=true
                        } else if transient<Self.modelAttempts, Self.isRetryable(error), !Task.isCancelled, compactionPhysicalAttempts<budget {
                            compactionState["phase"]="retrying"; event("compaction_progress")
                            try await Task.sleep(nanoseconds:UInt64(Self.retryDelays[min(transient-1,Self.retryDelays.count-1)]*1_000_000_000))
                        } else { throw error }
                    }
                }
                if repack { try validateCompaction(revision,profile:originalProfile); continue }
                guard let reply else { throw AgentError("compact_failed","Summary response is missing") }
                operationStatus("Summary HTTP response completed")
                if reply.message.responseTimeline == nil, !reply.message.text.isEmpty {
                    presentationOrdinal += 1
                    compactionDelta(.part(ResponsePartEvent(attemptID:reply.message.requestAttemptIDs?.first ?? compactionPresentationID ?? id,ordinal:presentationOrdinal,itemID:"summary",kind:"text",update:"replace",text:reply.message.text,observedAt:nowMS(),evidence:"canonical")))
                }
                cumulativeUsage.observe(reply.usage)
                for attempt in reply.message.requestAttemptIDs ?? [] where !compactionAttemptIDs.contains(attempt) { compactionAttemptIDs.append(attempt) }
                let outcome=summaryOutcome(reply,cap:effectiveProfile.maxOutput)
                compactionState["lastAttempt"]=outcome
                compactionState["attemptOutcomes"] = .array(compactionState["attemptOutcomes"].list + [outcome])
                for attempt in reply.message.requestAttemptIDs ?? [] { await traces.operation(attempt,compactionState) }
                try validateCompaction(revision,profile:originalProfile)
                let text=reply.message.text.trimmingCharacters(in:.whitespacesAndNewlines)
                if reply.terminal?.refusal == true { throw summaryFailure("compaction_refused","The gateway refused the summary; inspect this attempt before trying another handoff.",outcome:outcome) }
                guard reply.calls.isEmpty, !reply.message.content.contains(where: { $0["type"].text == "toolCall" }) else {
                    throw summaryFailure("compaction_unexpected_tool_call","The summary returned a tool call. It was not executed; inspect the gateway's tool-free behavior.",outcome:outcome)
                }
                if reply.terminal?.outputExhausted == true {
                    guard !budgetRetried, allowedCap>effectiveProfile.maxOutput, compactionPhysicalAttempts<budget else {
                        throw summaryFailure("compaction_output_exhausted","Summary generation exhausted its output allowance. No further permitted budget retry remains; choose a larger declared capacity or a smaller handoff.",outcome:outcome)
                    }
                    capacity=min(capacity,max(1,measured.requestTokens*2/3));budgetRetried=true
                    // Source reduction can make more of the model's allowance
                    // feasible; a full-cap exhaustion has no larger legal retry.
                    compactionState["phase"]="retrying-output-budget";event("compaction_progress")
                    continue
                }
                guard !reply.truncated, reply.message.stopReason != "length", reply.terminal?.status != "incomplete" else {
                    throw summaryFailure("compaction_incomplete","Summary generation ended incompletely for a non-token or unknown reason. Inspect the captured response; no budget retry was attempted.",outcome:outcome)
                }
                guard !text.isEmpty else { throw summaryFailure("compaction_empty_summary","The completed response contained no usable summary text. Inspect this attempt before retrying.",outcome:outcome) }
                guard text.utf8.count<=compactionPolicy.maximumSourceBytes else {
                    throw summaryFailure("compaction_source_limit","The generated summary exceeds the retained-source limit; use a smaller handoff.",outcome:outcome)
                }
                outputs.append(text); offset += low
                budgetRetried=false
            }
            if outputs.count==1 { return outputs[0] }
            let outputBytes=outputs.reduce(0) { $0+$1.utf8.count }
            guard !outputs.isEmpty, outputBytes<inputBytes, outputBytes<=compactionPolicy.maximumSourceBytes else { throw AgentError("compact_no_progress","Summary chunks did not reduce the source. Original context is retained.") }
            pending=outputs.map { JSON.object(["intermediateSummary":JSON($0),"historicalData":true]).encoded() }; level += 1
        }
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
