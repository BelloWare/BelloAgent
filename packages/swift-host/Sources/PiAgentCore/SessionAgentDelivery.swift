import Foundation

extension AgentSession {
    var hasAgentUserSteering: Bool { !steering.isEmpty && queueEdit == nil }
    var agentDeliveryHeld: Bool { queueEdit != nil || closed || queuePaused }
    func setFamilyWaiting(_ waiting: Bool) { if familyWaiting != waiting { familyWaiting = waiting; event("subagents.changed") } }
    func closeAgentFamilyFence() throws -> Bool {
        guard steering.isEmpty, queueEdit == nil else { return false }
        let state = agentState()
        // Durable fence, not the coordinator's transient active counter.
        guard !state.turns.values.contains(where: { !$0.status.terminal }),
              state.pending(author:"subagent").isEmpty,
              state.pending(author:"parent").isEmpty else { return false }
        if var run = state.run, !run.closed { run.closed = true; try appendAgentRecord(JournalRecordKind.familyRun,run) }
        setFamilyWaiting(false); return true
    }
    func appendAgentDelivery(_ delivery: AgentDelivery, selected: [AgentFamilyMessage]) async throws {
        if let digest = subagents.family?.contextRows[delivery.rowID] {
            guard digest == sha256(Data(JSON.array([textBlock(delivery.payload.encoded())]).encoded().utf8)) else { throw SubagentRecovery.damaged() }
            return
        }
        guard !agentDeliveryHeld, let first = selected.first else { throw AgentError("subagent_delivery_held", "Agent delivery is held") }
        var row = ChatMessage(role:"user",content:[textBlock(delivery.payload.encoded())]); row.id = delivery.rowID
        row.nativeAgentDelivery = ["version":1,"author":JSON(first.author),"childId":JSON(first.childID),"turn":JSON(first.turn),"eventIds":.array(delivery.eventIDs.map { JSON($0) }),"task":JSON(first.task),"events":.array(selected.map(\.event))]
        row.inputLane = "agent"; row.kind = "agent_message"
        // Agent authorship cannot carry attachments, skill selections or user consent.
        row.userInput = nil
        try append(row); try journal?.synchronize(); boundary = context
        // The preparation already durably charged this continuation before
        // the recipient row. A crash cannot erase the coordination charge.
        event("agent.message-delivered")
    }
    /// Use the same real input budget and counter as request admission. This
    /// check never appends a partial accepted message to make it fit.
    func agentPayloadFits(_ payload: JSON, parentLane: Bool) async throws -> Bool {
        var row = ChatMessage(role:"user",content:[textBlock(payload.encoded())]); row.inputLane = "agent"
        let own = try contextCounter.count(messages:[row],profile:turnProfile,reserveTokens:compactionSettings.reserveTokens)
        if parentLane, own.requestTokens > own.inputBudget / 5 { return false }
        let snapshot: ResourceSnapshot
        if let appliedSnapshot { snapshot = appliedSnapshot } else { snapshot = try await resources.resolve() }
        let definitions = await sessionDefinitions(), messages = requestContext + [row]
        let body = try ProviderClient.requestBody(profile:turnProfile,messages:messages,instructions:Self.requestInstructions(snapshot.prompt, tools: definitions),tools:definitions,sessionID:id,cacheSessionID:promptCacheSessionID)
        return try countContext(messages,request:body).fits
    }
}
