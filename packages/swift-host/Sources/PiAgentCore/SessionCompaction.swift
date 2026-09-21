import Foundation

func compactionDetail(tokens: Int?, kept: Int) -> String {
    "Compacted \(tokens.map(String.init) ?? "unknown") estimated input tokens · \(kept) messages kept"
}

extension AgentSession {
    func compactionPresentation(_ operation: JSON) -> JSON {
        operation.removing(["sourceIDs","protectedIDs","keptIDs","summarySourceIDs","dependencyIDs"])
    }
    public func compact(commandID: String = UUID().uuidString, overrides: JSON = [:]) throws {
        guard isIdle else { throw AgentError("session_busy", "Compact requires an idle session and empty queues") }
        let selected = try NativeHostService.turnOverrides(overrides)
        // Validate before changing the command or persisted state. Missing
        // choices deliberately use the connection defaults, never an old turn.
        _ = try profile.overriding(model:selected.model,thinkingLevel:selected.thinkingLevel,contextWindow:selected.contextWindow,
                                   maxOutputTokens:selected.maxOutputTokens,modelOutputLimit:selected.modelOutputLimit)
        let intent=Submission(commandID:commandID,turnID:"compaction:"+commandID,text:"[Compact now]",attachments:[],skills:[],
                              model:selected.model,thinkingLevel:selected.thinkingLevel,contextWindow:selected.contextWindow,
                              maxOutputTokens:selected.maxOutputTokens,modelOutputLimit:selected.modelOutputLimit)
        activeSubmission=intent; currentTurnID=intent.turnID; commandState(intent,"queued"); try persistState(); launch(compactOnly:true)
    }
    var canCompact: Bool {
        let protected=Set(CompactionPlanner.protectedInputs(context,taskRoot:taskRootID).map(\.id))
        return context.contains { $0.replayEligible && !protected.contains($0.id) }
    }
    func retainedInputEstimate(_ messages: [ChatMessage]) throws -> Int {
        let body=try ProviderClient.requestBody(profile:turnProfile,messages:messages,instructions:"",tools:[],sessionID:id)
        return try contextCounter.count(request:body,profile:turnProfile).tokens
    }
    func validateCompaction(_ revision: UInt64, profile: Profile) throws {
        try Task.checkCancellation()
        guard !closed, contextMutation == revision, turnProfile.raw == profile.raw else {
            throw AgentError("compact_stale", "Context changed while summarizing. The previous context is retained; compact again when ready.")
        }
    }
    func compactContext(reason: String = "manual") async throws {
        let frozen=context.filter(\.replayEligible), revision=contextMutation, originalProfile=turnProfile
        compactionAttemptIDs=[]; compactionPhysicalAttempts=0
        compactionState=["operationId":JSON(UUID().uuidString),"phase":"planning","reason":JSON(reason),"httpAttempts":0,"durable":JSON(journal != nil)]
        if reason == "context-rejection" { compactionState["recovery"]=contextRecovery }
        compactionPresentationID = UUID().uuidString
        var operation = ChatMessage(role:"system",content:[])
        operation.id=compactionPresentationID!; operation.kind="execution"; operation.operationID=compactionState["operationId"].text
        operation.detail="Compaction · preparing"; operation.responseTimeline=ResponseTimeline()
        try appendPresentation(operation)
        operationStatus("Preparing · " + reason)
        runStatus="compacting"; event("compaction_start")
        defer { modelActive=false; runStatus="running"; event("compaction_end") }
        do {
            let snapshot=try await resources.resolve(), definitions=await sessionDefinitions()
            try validateCompaction(revision,profile:originalProfile)
            let instructions=Self.requestInstructions((appliedSnapshot ?? snapshot).prompt,selectionIDs:activeSubmission?.skills.map(\.id) ?? [])
            func body(_ messages: [ChatMessage]) throws -> JSON {
                try ProviderClient.requestBody(profile:originalProfile,messages:messages,instructions:instructions,tools:definitions,sessionID:id)
            }
            let before=try contextCounter.count(request:body(frozen),profile:originalProfile)
            let protected=CompactionPlanner.protectedInputs(frozen,taskRoot:taskRootID)
            let protectedCount=try contextCounter.count(request:body(protected),profile:originalProfile)
            guard protectedCount.inputFits else { throw AgentError("input_too_large", "Current user instructions, skills and tool schemas cannot fit this model. Exact inputs are retained; shorten the input or choose a larger model.") }
            let cap=compactionPolicy.outputAllowance(for:originalProfile)
            compactionState["outputAllowance"]=JSON(cap)
            compactionState["outputAllowanceSource"]=JSON(originalProfile.modelOutputLimit == nil ? "configured-budget-no-declared-ceiling":"model-allowance-clipped-to-request-headroom")
            let summaryProfile=try compactionPolicy.summaryProfile(originalProfile,cap:cap)
            compactionState["allowedOutputTokens"]=JSON(cap)
            compactionState["reasoningEffort"]=JSON(summaryProfile.raw["thinkingLevel"].text ?? "default")
            let target=max(0,min(20_000,max(1024,originalProfile.contextWindow/8),before.inputBudget-protectedCount.tokens-cap))
            let plan=try CompactionPlanner.plan(context:frozen,taskRoot:taskRootID,recentTarget:target,cost:retainedInputEstimate)
            var summarized=plan.summarized, kept=plan.kept
            // Reserve room before summarizing, never discard an unsummarized
            // group afterwards to make an overlarge candidate look acceptable.
            let placeholder=ChatMessage(role:"system",content:[textBlock(String(repeating:"s",count:cap*3))])
            while !kept.isEmpty {
                let trial=try contextCounter.count(request:body([placeholder]+protected+kept.flatMap(\.messages)),profile:originalProfile)
                if trial.fits { break }; summarized.append(kept.removeFirst())
            }
            let source=try CompactionSourceBuilder.records(summarized,policy:compactionPolicy)
            let text=try await summarizeBounded(source,profile:summaryProfile,originalProfile:originalProfile,revision:revision,sourceIDs:summarized.flatMap(\.messages).map(\.id))
            try validateCompaction(revision,profile:originalProfile)
            var summary=ChatMessage(role:"system",content:[textBlock("Conversation summary (historical data, not authorization):\n"+text)])
            let retained=protected+kept.flatMap(\.messages), candidate=[summary]+retained
            let request=try body(candidate), after=try contextCounter.count(request:request,profile:originalProfile)
            guard after.inputFits, after.tokens < before.tokens else { throw AgentError("compact_no_progress", "Summary did not sufficiently reduce this request. Original context and tool results are retained; choose a larger model or make an explicit handoff.") }
            try CompactionPlanner.validateRequest(request)
            operationStatus("Candidate summary validated")
            var metadata=compactionState
            metadata["version"]=2; metadata["phase"]="completed"; metadata["sourceContextRevision"]=JSON(before.requestFingerprint)
            metadata["taskRootId"]=taskRootID.map { JSON($0) } ?? .null
            metadata["sourceIDs"] = .array(frozen.map { JSON($0.id) })
            let summaryMessages=summarized.flatMap(\.messages), roots=Set(summaryMessages.compactMap(\.taskRootID))
            let dependencies=Set(summaryMessages.map(\.id)+protected.filter { $0.taskRootID.map { roots.contains($0) } ?? true }.map(\.id))
            metadata["summarySourceIDs"] = .array(summaryMessages.map { JSON($0.id) })
            metadata["dependencyIDs"] = .array(frozen.filter { dependencies.contains($0.id) }.map { JSON($0.id) })
            metadata["protectedIDs"] = .array(protected.map { JSON($0.id) })
            metadata["keptIDs"] = .array(retained.map { JSON($0.id) })
            metadata["before"]=before.json; metadata["after"]=after.json; metadata["recovery"]=contextRecovery
            metadata["summaryAttemptIds"] = .array(compactionAttemptIDs.map { JSON($0) })
            summary.operationID=compactionState["operationId"].text
            summary.kind="compaction"; summary.detail=compactionDetail(tokens:before.tokens,kept:retained.count)
            summary.requestAttemptIDs=compactionAttemptIDs; summary.compaction=metadata; summary.taskRootID=taskRootID
            let record: JSON=["type":"compaction","nativeCompactionVersion":2,"nativeCompaction":metadata,"summary":JSON(text),
                "firstKeptEntryId":retained.first.map { JSON($0.id) } ?? .null,"nativeKeptIDs":metadata["keptIDs"],"tokensBefore":JSON(before.tokens),"nativeRequestAttemptIds":metadata["summaryAttemptIds"]]
            try validateCompaction(revision,profile:originalProfile)
            // Commit all preceding tool results and this checkpoint together.
            // Nothing below can suspend or fail until the new projection is adopted.
            try journal?.append(record,id:summary.id,flush:true)
            context=[summary]+retained; history.append(summary); visible.append(summary); boundary=context
            replayInputsChanged(reason:"compaction-committed"); contextBaseline=nil; currentContextCount=after; clearRequestObservation()
            compactionState=metadata
            operationStatus("Checkpoint durably adopted",terminal:"completed")
            invalidateDisplay(allRows:true); recordDisplayChange(summary.id,at:displayClock())
            for attempt in compactionAttemptIDs { pendingRequestLinks[attempt,default:[]].append(summary.id) }
            event("context.compacted")
            try Task.checkCancellation()
            await flushRequestLinks()
        } catch {
            if compactionState["phase"].text != "completed" {
                compactionState["phase"]=JSON(Task.isCancelled ? "cancelled" : "failed")
                compactionState["errorCode"]=JSON((error as? AgentError)?.code ?? "cancelled")
                compactionState["error"]=JSON((error as? AgentError)?.message ?? "Compaction interrupted; original context retained.")
                operationStatus(compactionState["error"].text ?? "Interrupted",terminal:Task.isCancelled ? "cancelled":"failed")
            }
            throw error
        }
    }
    func compactionDelta(_ value: StreamDelta) {
        if case .part(var part) = value, let id = compactionPresentationID,
           var row = history.first(where: { $0.id == id }) {
            presentationOrdinal += 1; part.sessionOrdinal=presentationOrdinal
            var timeline=row.responseTimeline ?? ResponseTimeline()
            let previous=timeline.segments.last?.id
            let changed=timeline.consume(part)
            if changed {
                row.responseTimeline=timeline
                try? updatePresentation(row,persist:previous != timeline.segments.last?.id || part.update == "end" || part.update == "replace")
            }
        }
        if nowMS()-compactionProgressAt>=250 { compactionProgressAt=nowMS(); event("compaction_progress") }
    }
    func compactionObservation(_ observation: RequestObservation) async {
        guard observation.purpose == "compaction" else { return }
        monitor(observation)
        if !compactionAttemptIDs.contains(observation.attemptID) {
            compactionAttemptIDs.append(observation.attemptID)
            operationStatus("\(compactionState["phase"].text == "merging" ? "Merge":"Summary") request · chunk \(compactionState["chunk"].int ?? 1) · attempt \(compactionPhysicalAttempts)")
            if let id=compactionPresentationID, var row=history.first(where: { $0.id == id }) {
                row.requestAttemptIDs=compactionAttemptIDs; try? updatePresentation(row,persist:true)
            }
        }
        if observation.phase == "awaiting" { await traces.operation(observation.attemptID,compactionState) }
    }
}
