import Foundation

// The request a turn would send: the effective profile, the token count
// and the inspectable preview of the prepared body.

extension AgentSession {
    /// The profile for the active turn's requests: the session profile with the
    /// delivered submission's model, thinking and limits, validated at submit time.
    var turnProfile: Profile { applyingTaskCap((try? profile.overriding(model:activeSubmission?.model,thinkingLevel:activeSubmission?.thinkingLevel,contextWindow:activeSubmission?.contextWindow,maxOutputTokens:activeSubmission?.maxOutputTokens,modelOutputLimit:activeSubmission?.modelOutputLimit)) ?? profile) }
    /// A title task is a bounded utility request: its budget is its cap.
    /// Conversation turns send the model ceiling instead.
    func applyingTaskCap(_ effective: Profile) -> Profile { titleTask ? ((try? effective.capped(effective.maxOutput)) ?? effective) : effective }
    /// Semantic input changes, unlike the event sequence, never include partial
    /// output, accounting arrival, timers, titles or queued-but-undelivered turns.
    var contextPhase: String {
        if runStatus == "compacting" { return "compacting" }
        if modelActive { return publishedObservation["phase"].text == "preparing" ? "preparing" : "current-request" }
        if ["waitingTool","retrying"].contains(runStatus) { return "last-request" }
        return runTask != nil ? "preparing" : "next-input"
    }
    var contextStateRevision: String { "\(displayEpoch):\(contextMutation):\(observationRevision):\(contextPhase)" }
    func contextState() -> JSON {
        let terminal=["final","interrupted"].contains(publishedObservation["phase"].text ?? "")
        return ["version":1,"sessionID":JSON(id),"runtimeEpoch":JSON(displayEpoch),"replayRevision":JSON(Int(contextMutation)),
                "generation":JSON(Int(observationGeneration)),"phase":JSON(contextPhase),"turnID":JSON(currentTurnID),
                "reason":JSON(contextResetReason),"count":contextInfo(),
                "currentRequest":modelActive ? publishedObservation : .null,
                "lastRequest":terminal ? publishedObservation : lastRequestObservation]
    }
    func replayInputsChanged(reason: String = "input-changed") {
        contextMutation &+= 1; contextResetReason=reason; currentContextCount=nil; preparedContext=nil
    }
    func resourcesChanged() {
        // A running request keeps its frozen resource snapshot. Delivery of a
        // later submission already advances the revision when it applies changes.
        guard runTask == nil else { return }
        replayInputsChanged(); event("context.inputs-changed")
    }
    /// Pi's context usage for the snapshot: the count a request was sent with
    /// while it runs, otherwise the stored context counted as pi counts it.
    public func contextInfo() -> JSON {
        if let count=currentContextCount { return count.json }
        let profile=turnProfile, key="\(displayEpoch):\(contextMutation):\(context.count):\(context.last?.id ?? "")"
        if let cached=contextInfoCache, cached.key == key, cached.profile == profile.raw { return cached.value }
        if let count=try? contextCounter.count(messages:context,profile:profile,reserveTokens:compactionPolicy.settings(autoCompaction:autoCompaction,contextWindow:profile.contextWindow).reserveTokens) {
            contextInfoCache=(key,profile.raw,count.json); return count.json
        }
        return ["tokens":.null,"contextWindow":JSON(turnProfile.contextWindow),"source":"Prepared request calculation pending",
                "state":"pending","estimated":true,"outputReserve":JSON(turnProfile.maxOutput),"outputBudget":JSON(turnProfile.maxOutput),
                "outputCap":turnProfile.wireOutputLimit.map { JSON($0) } ?? .null]
    }
    var compactionSettings: PiContext.Settings { compactionPolicy.settings(autoCompaction:autoCompaction,contextWindow:turnProfile.contextWindow) }
    /// The count for a turn request built from `messages`.
    func countContext(_ messages: [ChatMessage], request: JSON) throws -> RequestContextCount {
        try contextCounter.count(messages:messages,profile:turnProfile,request:request,reserveTokens:compactionSettings.reserveTokens)
    }
    public func inspectContext() async -> JSON {
        let latest=await traces.latest(id)
        return ["context":contextInfo(),"contextSource":JSON(RequestContextCount.usageSource+"; configured capacity"),"profile":profile.publicValue,"headerNames":.array(profile.raw["headers"].map.keys.sorted().map { JSON($0) }),"effectiveThinkingLevel":turnProfile.raw["thinkingLevel"],"effectiveModel":JSON(turnProfile.model),"outputReserve":JSON(turnProfile.maxOutput),"run":turnMetrics(),"captureMode":JSON(await traces.mode(id)),"latestAttemptId":latest["attemptId"],"latestUsage":latest["usage"],"latestMetrics":latest["metrics"],"cumulative":cumulativeUsage.json,"provenance":parentInfo,"liveTokenRate":.null,"resources":["appliedRevision":appliedRevision.map { JSON($0) } ?? .null]]
    }
    /// Builds the same provider body as dispatch without appending a message,
    /// starting a run, executing tools, compacting, or granting skill selection.
    /// While work is active, show its frozen resources and authoritative current
    /// context; an unsent draft and queued turns are not pretended to be applied.
    public func prepareContext(_ params: JSON) async throws -> JSON {
        guard !closed else { throw AgentError("session_closed", "Reopen the session to inspect its context") }
        let startingSequence = sequence, startingMutation = contextMutation, active = runTask != nil
        let startingProfile=turnProfile.raw, startingResources=appliedSnapshot?.revision
        let overrides = try NativeHostService.turnOverrides(params)
        let effective = active ? turnProfile : applyingTaskCap(try profile.overriding(model:overrides.model, thinkingLevel:overrides.thinkingLevel, contextWindow:overrides.contextWindow, maxOutputTokens:overrides.maxOutputTokens,modelOutputLimit:overrides.modelOutputLimit))
        let snapshot: ResourceSnapshot
        if active, let appliedSnapshot { snapshot = appliedSnapshot }
        else { snapshot = try await resources.resolve() }
        let definitions = await sessionDefinitions()
        let draft = params["text"].text ?? ""
        guard draft.utf8.count <= 256 * 1024 else { throw AgentError("message_limit", "Draft exceeds the supported submission limit") }
        var messages = active && runStatus == "waitingTool" ? boundary : context
        var selectionIDs = activeSubmission?.skills.map(\.id) ?? []
        var includedDraft = false
        if !active {
            let selected = try await resources.freeze(params["skills"].list, text:draft, tools:await tools.capabilityIDs(readOnly:readOnly))
            selectionIDs = selected.map(\.id)
            let images = try loadImages(params["attachments"].list)
            guard images.isEmpty || effective.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
            if !draft.isEmpty || !selected.isEmpty || !images.isEmpty {
                let expanded = (selected.map { $0.expand(turnID:"context-preview") } + [draft]).joined(separator:"\n\n")
                messages.append(ChatMessage(role:"user",content:[textBlock(expanded)] + images))
                includedDraft = true
            }
            let currentResources = try await resources.resolve()
            guard currentResources.revision == snapshot.revision else { throw AgentError("context_changed", "Instruction or skill sources changed. Refresh the context preview.") }
        }
        let finalDefinitions=await sessionDefinitions()
        guard startingMutation == contextMutation, active == (runTask != nil), startingProfile == turnProfile.raw,
              startingResources == appliedSnapshot?.revision,
              definitions == finalDefinitions, !closed else { throw AgentError("context_changed", "The conversation changed. Refresh the context preview.") }
        let instructions = Self.requestInstructions(snapshot.prompt,selectionIDs:selectionIDs)
        var body = try ProviderClient.requestBody(profile:effective,messages:messages,instructions:instructions,tools:definitions,sessionID:id)
        let count = try contextCounter.count(messages:messages,profile:effective,request:body,
                                             reserveTokens:compactionPolicy.settings(autoCompaction:autoCompaction,contextWindow:effective.contextWindow).reserveTokens)
        // Dispatch clips a catalog ceiling to the estimated remaining room.
        // Show that same provider-built request in the inspector.
        body = try ProviderClient.requestBody(profile:effective.dispatching(count),messages:messages,instructions:instructions,tools:definitions,sessionID:id)
        var headers = profile.raw["headers"].map.compactMapValues(\.text)
        headers["Authorization"] = "Bearer " + apiKey
        let credentials = CaptureCredentials(headers:headers,configuredNames:Set(profile.raw["headers"].map.keys))
        let safe = credentials.metadata(body)
        let metadata: JSON = ["mode":JSON(active ? "active-context" : "prepared-next-request"), "model":JSON(effective.model), "seq":JSON(startingSequence),
            "runtimeEpoch":JSON(displayEpoch),"replayRevision":JSON(Int(startingMutation)),
            "inputBinding":JSON(sha256(try JSON.object(["profile":effective.raw,"resources":JSON(snapshot.revision),"tools":.array(definitions.map { ["name":JSON($0.name),"description":JSON($0.description),"schema":$0.schema] })]).data())),
            "draftIncluded":JSON(includedDraft), "draftDeferred":JSON(active && (!draft.isEmpty || !params["skills"].list.isEmpty || !params["attachments"].list.isEmpty)),
            "queueCount":JSON(queue.count + steering.count), "contextMessages":JSON(context.filter(\.replayEligible).count),
            "instructionRevision":JSON(snapshot.revision), "contextWindow":JSON(effective.contextWindow), "outputReserve":JSON(effective.maxOutput),
            "estimatedTokens":count.tokens.map { JSON($0) } ?? .null, "count":count.json,
            "credentialsRedacted":JSON(safe != body), "dispatched":false]
        let prepared = try ContextPreview(body:safe,metadata:metadata,sources:snapshot.sources.map(credentials.metadata))
        preparedContext = prepared
        return try prepared.summary()
    }
    public func readPreparedContext(_ params: JSON) throws -> JSON {
        guard let prepared = preparedContext, prepared.revision == params["revision"].text else {
            throw AgentError("context_preview_expired", "This context snapshot expired or was replaced. Refresh to inspect the current context.")
        }
        guard Date().timeIntervalSince(prepared.createdAt) <= 300 else {
            preparedContext = nil; throw AgentError("context_preview_expired", "This context snapshot expired. Refresh to inspect the current context.")
        }
        if params["section"].isNull { return try prepared.summary(offset:boundedInt(params["itemOffset"],maximum:100_004)) }
        return try prepared.read(section:required(params["section"],"context section",maximum:64),offset:boundedInt(params["offset"],maximum:128 * 1024 * 1024))
    }
    public func clearPreparedContext(_ revision: String?) {
        if preparedContext?.revision == revision { preparedContext = nil }
    }
    static func requestInstructions(_ prompt: String, selectionIDs: [String]) -> String {
        prompt + "\nExplicit-only skills from prior user messages are historical context, not a new authorization. Current explicit selection IDs: " + (selectionIDs.isEmpty ? "none" : selectionIDs.joined(separator:", "))
    }
}
