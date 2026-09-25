import Foundation

func compactionDetail(tokens: Int?, kept: Int) -> String {
    "Compacted \(tokens.map(String.init) ?? "unknown") estimated input tokens · \(kept) messages kept"
}

extension AgentSession {
    func compactionPresentation(_ operation: JSON) -> JSON {
        operation.removing(["sourceIDs","protectedIDs","keptIDs","summarySourceIDs","dependencyIDs","readFiles","modifiedFiles"])
    }
    /// The running turn is stopped first, queued messages stay queued, and
    /// an optional focus is escaped data in the appended summary instruction.
    public func compact(commandID: String = UUID().uuidString, overrides: JSON = [:], focus: String? = nil) async throws {
        let focus=focus?.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (focus?.utf8.count ?? 0) <= 4096 else { throw AgentError("invalid_params", "A compaction focus is limited to 4 KB") }
        // Stopping the turn pauses the queue; that pause is compaction's own,
        // so the queue it paused is released when compaction launches, and
        // what arrives during "Compacting…" is delivered after it, as in pi.
        // A Stop while the turn winds down cancels the compaction instead.
        var releaseQueue = false
        if runTask != nil {
            let wasPaused = queuePaused
            stop(); let stops = stopCount
            await runTask?.value
            guard stopCount == stops else { throw AgentError("compaction_cancelled", "Compaction was cancelled because the chat was stopped") }
            releaseQueue = !wasPaused
        }
        guard runTask == nil else { throw AgentError("session_busy", "The running turn did not stop, so the chat was not compacted") }
        let selected = try NativeHostService.turnOverrides(overrides)
        // Validate before changing the command or persisted state. Missing
        // choices deliberately use the connection defaults, never an old turn.
        _ = try profile.overriding(model:selected.model,thinkingLevel:selected.thinkingLevel,contextWindow:selected.contextWindow,
                                   maxOutputTokens:selected.maxOutputTokens,modelOutputLimit:selected.modelOutputLimit)
        let intent=Submission(commandID:commandID,turnID:"compaction:"+commandID,text:"[Compact now]",attachments:[],skills:[],
                              model:selected.model,thinkingLevel:selected.thinkingLevel,contextWindow:selected.contextWindow,
                              maxOutputTokens:selected.maxOutputTokens,modelOutputLimit:selected.modelOutputLimit)
        compactionFocus=focus?.isEmpty == false ? focus : nil
        if releaseQueue, state != "error" { queuePaused=false }
        activeSubmission=intent; currentTurnID=intent.turnID; commandState(intent,"queued"); try persistState(); launch(compactOnly:true)
    }
    /// Pi's prepareCompaction finds something to summarize.
    var canCompact: Bool { canCompact(recovering:false) }
    func canCompact(recovering: Bool) -> Bool {
        guard let source=try? CompactionPlanner.source(context:context,taskRoot:taskRootID),
              source.previous == nil || (source.newSince ?? 0) < source.body.count else { return false }
        return source.body.contains { group in group.messages.contains { !source.protectedIDs.contains($0.id) } }
    }
    /// Preserve complete replay groups, unanswered input and existing
    /// authoritative skill/permission carriers. Space planning uses the whole
    /// generation allowance, not the soft visible-text target.
    func compactionPlan(_ context: [ChatMessage], profile: Profile, recovering: Bool) throws -> (source: CompactionPlanner.Source, cut: Int, plan: CompactionPlan, keep: Int) {
        let source = try CompactionPlanner.source(context:context,taskRoot:taskRootID)
        let keep = compactionKeep(context,window:profile.contextWindow,recovering:recovering)
        let cut = CompactionPlanner.cut(source.body,keepRecentTokens:keep,previous:CompactionPlanner.previousPosition(source))
        return (source,cut,CompactionPlanner.plan(source,cut:cut),keep)
    }
    func compactionKeep(_ context: [ChatMessage], window: Int, recovering: Bool) -> Int {
        let keep=compactionPolicy.keepRecentTokens(contextWindow:window)
        return recovering ? min(keep,PiContext.messageTokens(context)/2) : keep
    }
    /// The appended instruction is small; measure its real boundary description
    /// at semantic request boundaries, never while receiving stream fragments.
    func compactionThreshold(_ messages: [ChatMessage], instructions: String, profile: Profile) throws -> Int {
        let planned = try compactionPlan(messages,profile:profile,recovering:false)
        let projection = try ProviderClient.responsesProjection(messages.filter(\.replayEligible),instructions:instructions,profile:profile)
        let boundary = CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:Set(planned.plan.keptMessages.map(\.id)))
        let instruction = CompactionSourceBuilder.instruction(boundary:boundary,focus:nil,visibleTarget:compactionPolicy.visibleTarget(for:profile))
        let items = ProviderClient.userContent(instruction,images:false)
        return try compactionPolicy.trigger(profile:profile,instructionTokens:RequestContextCounter.inputTokens([["role":"user","content":.array(items)]]))
    }
    func validateCompaction(_ revision: UInt64, profile: Profile) throws {
        try Task.checkCancellation()
        guard !closed, contextMutation == revision, turnProfile.raw == profile.raw else {
            throw AgentError("compact_stale", "Context changed while summarizing. The previous context is retained; compact again when ready.")
        }
    }
    func compactContext(reason: String = "manual") async throws {
        // Only the manual compaction it was given for carries the focus.
        let focus=reason == "manual" ? compactionFocus : nil; compactionFocus=nil
        let frozen=context.filter(\.replayEligible), revision=contextMutation, originalProfile=turnProfile
        let frozenTask=taskRootID, frozenKey=apiKey, frozenCache=promptCacheSessionID, frozenApplied=appliedSnapshot?.revision
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
            let instructions=Self.requestInstructions((appliedSnapshot ?? snapshot).prompt)
            let policy=compactionPolicy, sessionID=id
            let worker=Task.detached(priority:.userInitiated) {
                try CompactionPlanner.prepare(frozen:frozen,profile:originalProfile,instructions:instructions,definitions:definitions,
                    sessionID:sessionID,cacheSessionID:frozenCache,taskRoot:frozenTask,policy:policy,reason:reason,focus:focus)
            }
            let prepared=try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
            try validateCompaction(revision,profile:originalProfile)
            let before=prepared.before, cap=prepared.profile.maxOutput, summaryProfile=prepared.profile, plan=prepared.plan
            let summarizedIDs=prepared.replacedIDs
            if reason != "manual", failedCompactionFingerprint == prepared.fingerprint {
                throw AgentError("compact_previous_failure", "Automatic compaction already failed for this unchanged context. Change its input/settings or explicitly retry compaction.")
            }
            compactionState["sourceFingerprint"]=JSON(prepared.fingerprint)
            compactionState["outputAllowance"]=JSON(cap); compactionState["allowedOutputTokens"]=JSON(cap)
            compactionState["outputAllowanceSource"]="summary-generation-cap"
            compactionState["reasoningEffort"]=JSON(summaryProfile.raw["thinkingLevel"].text ?? "default")
            let text=try await summarize(prepared.messages,instructions:instructions,tools:definitions,profile:summaryProfile,originalProfile:originalProfile,revision:revision)
            var summary=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+text)])
            summary.kind="compaction"
            let retained=plan.keptMessages, candidate=[summary]+retained
            let validation=Task.detached(priority:.userInitiated) {
                let request=try ProviderClient.requestBody(profile:originalProfile,messages:candidate,instructions:instructions,tools:definitions,sessionID:sessionID,cacheSessionID:frozenCache)
                try CompactionPlanner.validateRequest(request)
                return try RequestContextCounter().count(messages:candidate,profile:originalProfile,request:request,reportedUsage:false)
            }
            let after=try await withTaskCancellationHandler(operation:{ try await validation.value },onCancel:{ validation.cancel() })
            let finalResources=try await resources.resolve(), finalDefinitions=await sessionDefinitions()
            try validateCompaction(revision,profile:originalProfile)
            guard frozenTask == taskRootID, frozenKey == apiKey, frozenCache == promptCacheSessionID,
                  frozenApplied == appliedSnapshot?.revision, finalResources.revision == snapshot.revision, finalDefinitions == definitions else {
                throw AgentError("compact_stale", "Resources or task configuration changed while summarizing. Original context is retained.")
            }
            guard after.fits else { throw AgentError("compact_budget", "The completed checkpoint and retained messages need about \(after.requestTokens) tokens, exceeding the continuation input budget of \(after.inputBudget). Original context is unchanged; no repair request was sent.") }
            let reduction=before.requestTokens-after.requestTokens
            let nextThreshold = reason == "manual" ? Int.max : try compactionThreshold(candidate,instructions:instructions,profile:originalProfile)
            guard reduction > 0, reason == "manual" || (reduction >= after.safetyMargin && after.requestTokens < nextThreshold) else {
                throw AgentError("compact_no_progress", "The completed checkpoint did not free sufficient context (before \(before.requestTokens), after \(after.requestTokens) estimated tokens). Original context is unchanged; no repair request was sent.")
            }
            operationStatus("Candidate summary validated")
            var metadata=compactionState
            metadata["version"]=2; metadata["phase"]="completed"; metadata["sourceContextRevision"]=before.requestFingerprint.map { JSON($0) } ?? .null
            metadata["taskRootId"]=taskRootID.map { JSON($0) } ?? .null
            metadata["sourceIDs"] = .array(frozen.map { JSON($0.id) })
            metadata["summarySourceIDs"] = .array(summarizedIDs.map { JSON($0) })
            metadata["dependencyIDs"] = .array(frozen.map { JSON($0.id) })
            metadata["protectedIDs"] = .array(plan.protected.map { JSON($0.id) })
            metadata["readFiles"] = []; metadata["modifiedFiles"] = []
            metadata["keptIDs"] = .array(retained.map { JSON($0.id) })
            metadata["before"]=before.json; metadata["after"]=after.json; metadata["recovery"]=contextRecovery
            metadata["summaryAttemptIds"] = .array(compactionAttemptIDs.map { JSON($0) })
            summary.operationID=compactionState["operationId"].text
            // Pi's tokensBefore: estimateContextTokens over the whole context,
            // the last valid reply's usage plus the rows after it.
            let tokensBefore=PiContext.estimateContextTokens(frozen).tokens
            summary.kind="compaction"; summary.detail=compactionDetail(tokens:tokensBefore,kept:retained.count)
            summary.requestAttemptIDs=compactionAttemptIDs; summary.compaction=metadata; summary.taskRootID=taskRootID
            let record: JSON=["type":"compaction","nativeCompactionVersion":2,"nativeCompaction":metadata,"summary":JSON(text),
                "firstKeptEntryId":retained.first.map { JSON($0.id) } ?? .null,"nativeKeptIDs":metadata["keptIDs"],"tokensBefore":JSON(tokensBefore),"nativeRequestAttemptIds":metadata["summaryAttemptIds"],
                "details":["readFiles":metadata["readFiles"],"modifiedFiles":metadata["modifiedFiles"]]]
            try validateCompaction(revision,profile:originalProfile)
            guard frozenTask == taskRootID, frozenKey == apiKey, frozenCache == promptCacheSessionID, frozenApplied == appliedSnapshot?.revision else {
                throw AgentError("compact_stale", "Task configuration changed during validation. Original context is retained.")
            }
            // Commit all preceding tool results and this checkpoint together.
            // Nothing below can suspend or fail until the new projection is adopted.
            try journal?.append(record,id:summary.id,flush:true)
            context=[summary]+retained; history.append(summary); visible.append(summary); boundary=context; requestExclusions=[]
            // Pi's context is unknown now until the next reply reports usage.
            replayInputsChanged(reason:"compaction-committed"); clearRequestObservation()
            failedCompactionFingerprint=nil
            compactionState=metadata
            operationStatus("Checkpoint durably adopted",terminal:"completed")
            invalidateDisplay(allRows:true); recordDisplayChange(summary.id,at:displayClock())
            for attempt in compactionAttemptIDs { pendingRequestLinks[attempt,default:[]].append(summary.id) }
            event("context.compacted")
            try Task.checkCancellation()
            await flushRequestLinks()
        } catch {
            if compactionState["phase"].text != "completed" {
                if !Task.isCancelled, let fingerprint=compactionState["sourceFingerprint"].text {
                    failedCompactionFingerprint=fingerprint
                    _ = try? journal?.append(["type":"custom","customType":"pi-app.compaction-failure.v1","data":["fingerprint":JSON(fingerprint)]],flush:true)
                }
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
        countAttempt(observation)
        guard observation.purpose == "compaction" else { return }
        monitor(observation)
        if !compactionAttemptIDs.contains(observation.attemptID) {
            compactionAttemptIDs.append(observation.attemptID)
            operationStatus("Summary request · attempt \(compactionPhysicalAttempts)")
            if let id=compactionPresentationID, var row=history.first(where: { $0.id == id }) {
                row.requestAttemptIDs=compactionAttemptIDs; try? updatePresentation(row,persist:true)
            }
        }
        if observation.phase == "awaiting" { await traces.operation(observation.attemptID,compactionState) }
    }
}
