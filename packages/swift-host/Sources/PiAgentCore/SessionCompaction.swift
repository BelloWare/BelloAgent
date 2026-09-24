import Foundation

func compactionDetail(tokens: Int?, kept: Int) -> String {
    "Compacted \(tokens.map(String.init) ?? "unknown") estimated input tokens · \(kept) messages kept"
}

extension AgentSession {
    func compactionPresentation(_ operation: JSON) -> JSON {
        operation.removing(["sourceIDs","protectedIDs","keptIDs","summarySourceIDs","dependencyIDs","readFiles","modifiedFiles"])
    }
    /// Pi's compact(customInstructions): the running turn is stopped first,
    /// queued messages stay queued, and a focus joins the summary prompt as
    /// "Additional focus".
    public func compact(commandID: String = UUID().uuidString, overrides: JSON = [:], focus: String? = nil) async throws {
        let focus=focus?.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (focus?.utf8.count ?? 0) <= 4096 else { throw AgentError("invalid_params", "A compaction focus is limited to 4 KB") }
        if runTask != nil { stop(); await runTask?.value }
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
        activeSubmission=intent; currentTurnID=intent.turnID; commandState(intent,"queued"); try persistState(); launch(compactOnly:true)
    }
    /// Pi's prepareCompaction finds something to summarize.
    var canCompact: Bool { canCompact(recovering:false) }
    func canCompact(recovering: Bool) -> Bool {
        (try? compactionPlan(context,profile:turnProfile,recovering:recovering))?.plan.summarized.isEmpty == false
    }
    /// Pi's cut, moved later while the kept messages cannot fit beside the
    /// summary caps by pi's estimate. The request itself is counted later.
    func compactionPlan(_ context: [ChatMessage], profile: Profile, recovering: Bool) throws -> (source: CompactionPlanner.Source, cut: Int, plan: CompactionPlan, keep: Int) {
        let source=try CompactionPlanner.source(context:context,taskRoot:taskRootID), keep=compactionKeep(context,window:profile.contextWindow,recovering:recovering)
        let cap=compactionPolicy.summaryTokens(for:profile), prefixCap=compactionPolicy.summaryTokens(for:profile,turnPrefix:true)
        let budget=profile.contextWindow-profile.maxOutput-RequestContextCount.safetyMargin(contextWindow:profile.contextWindow)
        // Pi compacts nothing when nothing followed the last checkpoint.
        let unchanged=source.previous != nil && (source.newSince ?? 0) >= source.body.count
        var cut=unchanged ? 0 : CompactionPlanner.cut(source.body,keepRecentTokens:keep,previous:CompactionPlanner.previousPosition(source)), plan=CompactionPlanner.plan(source,cut:cut)
        var kept=PiContext.messageTokens(plan.keptMessages)
        // Ours: a kept tail that would not leave the output budget free beside
        // the summary moves the cut later, where pi's compaction could not free
        // the room its next request needs.
        while !unchanged, cut<source.body.count, PiContext.sum([kept,cap,plan.turnPrefix.isEmpty ? 0:prefixCap])>budget {
            kept -= PiContext.messageTokens(source.body[cut].messages.filter { !source.protectedIDs.contains($0.id) })
            cut += 1; plan=CompactionPlanner.plan(source,cut:cut)
        }
        return (source,cut,plan,keep)
    }
    /// Pi's recent tail. Unlike pi, whose overflow recovery cannot compact a
    /// history within its tail, a context the gateway rejected keeps at most
    /// half of itself.
    func compactionKeep(_ context: [ChatMessage], window: Int, recovering: Bool) -> Int {
        let keep=compactionPolicy.keepRecentTokens(contextWindow:window)
        return recovering ? min(keep,PiContext.messageTokens(context)/2) : keep
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
            // Pi's figure is what the checkpoint records. A candidate is sized as
            // pi sizes a request no reply has measured: characters over four with
            // the prefix. Like pi, a summary is not required to be smaller than
            // the rows it replaces; it only has to leave a request that fits.
            func count(_ messages: [ChatMessage], reported: Bool = false, request: JSON? = nil) throws -> RequestContextCount {
                try contextCounter.count(messages:messages,profile:originalProfile,request:request ?? body(messages),reportedUsage:reported)
            }
            let frozenBody=try body(frozen)
            let before=try count(frozen,reported:true,request:frozenBody)
            // Pi's summary caps: 0.8 × reserve for history, 0.5 × for a turn prefix,
            // within the model's own ceiling when it is known.
            let cap=compactionPolicy.summaryTokens(for:originalProfile), prefixCap=compactionPolicy.summaryTokens(for:originalProfile,turnPrefix:true)
            compactionState["outputAllowance"]=JSON(cap)
            compactionState["outputAllowanceSource"]=JSON(originalProfile.modelOutputLimit.map { $0 < cap + 1 } == true ? "model-output-limit" : "pi-reserve-share")
            let summaryProfile=try compactionPolicy.summaryProfile(originalProfile,cap:compactionPolicy.summaryRoom(for:originalProfile))
            compactionState["allowedOutputTokens"]=JSON(cap)
            compactionState["reasoningEffort"]=JSON(summaryProfile.raw["thinkingLevel"].text ?? "default")
            let planned=try compactionPlan(frozen,profile:originalProfile,recovering:reason == "context-rejection"), source=planned.source, keep=planned.keep
            var cut=planned.cut, plan=planned.plan
            let unchanged=source.previous != nil && (source.newSince ?? 0) >= source.body.count
            // Ours: reserve room for the summary before summarizing, where pi's
            // kept tail would not leave the output budget free: a kept group
            // that cannot fit beside it is summarized too, never discarded.
            while !unchanged, cut<source.body.count {
                let room=ChatMessage(role:"system",content:[textBlock(String(repeating:"s",count:(cap+(plan.turnPrefix.isEmpty ? 0:prefixCap))*4))])
                if try count([room]+plan.keptMessages).fits { break }
                cut += 1; plan=CompactionPlanner.plan(source,cut:cut)
            }
            guard !plan.summarized.isEmpty else {
                throw AgentError("compact_unavailable", unchanged ? "Already compacted: nothing has been added since the last compaction." : "Nothing to compact (session too small): the most recent \(keep) tokens stay as they are.")
            }
            let summarizedIDs=(plan.previous.map { [$0.id] } ?? [])+plan.summarized.map(\.id), replayed=Set(plan.protected.map(\.id))
            func generate(_ messages: [ChatMessage], previous: String?, turnPrefix: Bool) async throws -> String {
                try await summarize(CompactionSourceBuilder.serialize(messages),previous:previous,turnPrefix:turnPrefix,
                                    profile:turnPrefix ? compactionPolicy.summaryProfile(originalProfile,cap:compactionPolicy.summaryRoom(for:originalProfile,turnPrefix:true)) : summaryProfile,
                                    originalProfile:originalProfile,revision:revision,sourceIDs:summarizedIDs,focus:turnPrefix ? nil : focus)
            }
            // Pi's compact(): the history since the last checkpoint updates its
            // summary; a split turn's prefix is summarized on its own. Unlike
            // pi, a split turn with nothing new before it keeps the previous summary.
            var text: String
            if plan.turnPrefix.isEmpty || plan.history.contains(where: { !replayed.contains($0.id) }) {
                text=try await generate(plan.history,previous:plan.previousSummary,turnPrefix:false)
            } else { text=plan.previousSummary ?? CompactionSourceBuilder.noPriorHistory }
            // A prefix of verbatim inputs alone needs no summary of its own.
            if plan.turnPrefix.contains(where: { !replayed.contains($0.id) }) {
                text += CompactionSourceBuilder.splitTurnSeparator+(try await generate(plan.turnPrefix,previous:nil,turnPrefix:true))
            }
            let files=CompactionSourceBuilder.fileLists(plan.history+plan.turnPrefix,previous:plan.previous?.compaction)
            text += CompactionSourceBuilder.fileOperations(read:files.read,modified:files.modified)
            try validateCompaction(revision,profile:originalProfile)
            var summary=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+text)])
            // Pi adopts the checkpoint without measuring what follows it.
            let retained=plan.keptMessages, candidate=[summary]+retained
            let request=try body(candidate), after=try count(candidate,request:request)
            try CompactionPlanner.validateRequest(request)
            operationStatus("Candidate summary validated")
            var metadata=compactionState
            metadata["version"]=2; metadata["phase"]="completed"; metadata["sourceContextRevision"]=before.requestFingerprint.map { JSON($0) } ?? .null
            metadata["taskRootId"]=taskRootID.map { JSON($0) } ?? .null
            metadata["sourceIDs"] = .array(frozen.map { JSON($0.id) })
            let dependencies=Set(summarizedIDs)
            metadata["summarySourceIDs"] = .array(summarizedIDs.map { JSON($0) })
            metadata["dependencyIDs"] = .array(frozen.filter { dependencies.contains($0.id) }.map { JSON($0.id) })
            metadata["protectedIDs"] = .array(plan.protected.map { JSON($0.id) })
            metadata["readFiles"] = .array(files.read.map { JSON($0) }); metadata["modifiedFiles"] = .array(files.modified.map { JSON($0) })
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
            // Commit all preceding tool results and this checkpoint together.
            // Nothing below can suspend or fail until the new projection is adopted.
            try journal?.append(record,id:summary.id,flush:true)
            context=[summary]+retained; history.append(summary); visible.append(summary); boundary=context; requestExclusions=[]
            // Pi's context is unknown now until the next reply reports usage.
            replayInputsChanged(reason:"compaction-committed"); clearRequestObservation()
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
        countAttempt(observation)
        guard observation.purpose == "compaction" else { return }
        monitor(observation)
        if !compactionAttemptIDs.contains(observation.attemptID) {
            compactionAttemptIDs.append(observation.attemptID)
            operationStatus("Summary request · chunk \(compactionState["chunk"].int ?? 1) · attempt \(compactionPhysicalAttempts)")
            if let id=compactionPresentationID, var row=history.first(where: { $0.id == id }) {
                row.requestAttemptIDs=compactionAttemptIDs; try? updatePresentation(row,persist:true)
            }
        }
        if observation.phase == "awaiting" { await traces.operation(observation.attemptID,compactionState) }
    }
}
