import Foundation

struct SubagentEnvironment: Sendable {
    let parent: AgentSession
    let ownerID: String, turnID: String, executionID: String
    let parentAttemptID: String?
    let generation: Int
    let profile: Profile, apiKey: String
    let models: [SubagentModelGrant]
    let definitions: [ToolDefinition], capabilities: [String]
    let mcpPolicy: JSON?
    let tools: any ToolExecuting, client: any ModelClient
    let resources: ResourceSnapshot
    let cwd: URL, directory: URL
    let readOnly: Bool, traces: TraceStore
    let retry: PiProviderRules.RetrySettings
    let changed: @Sendable (String, Int) -> Void
}

extension AgentSession {
    func enableSubagents(_ coordinator: SubagentCoordinator) {
        subagentCoordinator = coordinator
        if canDelegate {
            enableFamilyBudget()
            let ownerID = id
            familyCancelled = { generation in Task { await coordinator.cancel(owner: ownerID, through: generation) } }
        }
    }
    var canDelegate: Bool { subagentCoordinator != nil && journal != nil && !ephemeral && !titleTask && !isSubagent && !isConnectionTest }

    func delegationEnvironment() async throws -> SubagentEnvironment {
        guard canDelegate, !closed, !queuePaused, let execution = activeTaskPresentation?.executionID else { throw AgentError("tool_unavailable", "Delegation is unavailable in this session") }
        let generation = stopCount, profile = turnProfile
        let definitions = await tools.definitions(readOnly: readOnly), capabilities = await tools.capabilityIDs(readOnly: readOnly)
        let mcpPolicy = await tools.delegationMCPPolicy()
        let snapshot: ResourceSnapshot
        if let appliedSnapshot { snapshot = appliedSnapshot } else { snapshot = try await resources.resolve() }
        try Task.checkCancellation()
        guard generation == stopCount else { throw CancellationError() }
        return SubagentEnvironment(parent: self, ownerID: id, turnID: currentTurnID, executionID: execution, parentAttemptID: currentAttemptIDs.last, generation: generation,
                                   profile: profile, apiKey: apiKey, models: turnSubagentModels, definitions: definitions, capabilities: capabilities,
                                   mcpPolicy: mcpPolicy, tools: tools, client: client, resources: snapshot, cwd: cwd, directory: directory, readOnly: readOnly,
                                   traces: traces, retry: retrySettings, changed: changed)
    }
    func registerDelegation(_ plan: SubagentPlan, generation: Int) throws {
        try Task.checkCancellation()
        guard canDelegate, !closed, !queuePaused, stopCount == generation, plan.origin.link.valid,
              plan.origin.link.call.parentSessionID == id, activeTaskPresentation?.executionID == plan.origin.link.parentExecutionID,
              toolHistory.owners[plan.origin.link.call.toolCallID] == plan.origin.link.call.assistantMessageID else { throw AgentError("subagent_identity", "Delegation no longer belongs to this parent execution") }
        let record: JSON = ["type":"custom", "customType":JSON(JournalRecordKind.subagentCall), "data":try subagentJSON(plan)]
        var next = subagents; try next.consume(record, sessionID: id)
        try journal?.append(record, flush: true); subagents = next
    }
    func subagentChanged(_ summary: SubagentSummary) {
        if toolStateOwners[summary.link.call.toolCallID] == summary.link.call.assistantMessageID,
           var card = toolStates[summary.link.call.toolCallID] {
            card["subagent"] = (try? subagentJSON(summary)) ?? .null
            setToolState(summary.link.call.toolCallID, card)
            recordDisplayChange(summary.link.call.assistantMessageID, at: displayClock())
        }
        event("subagents.changed", (try? subagentJSON(summary)) ?? [:])
    }
    func setSubagentState(_ status: SubagentStatus) throws {
        guard let origin = subagents.origin else { throw AgentError("subagent_identity", "Not a managed child") }
        guard let journal else { throw AgentError("subagent_persistence", "The managed child journal is closed") }
        let record: JSON = ["type":"custom", "customType":JSON(JournalRecordKind.subagentState),
                            "data":["delegationID":JSON(origin.link.delegationID),"status":JSON(status.rawValue)]]
        var next = subagents; try next.consume(record, sessionID: id)
        try journal.append(record, flush: true); subagents = next
    }
    func saveSubagentTerminal(_ result: SubagentToolResult) throws {
        guard let origin = subagents.origin else { throw AgentError("subagent_identity", "Not a managed child") }
        guard let journal else { throw AgentError("subagent_persistence", "The managed child journal is closed") }
        let record: JSON = ["type":"custom", "customType":JSON(JournalRecordKind.subagentTerminal),
                            "data":["delegationID":JSON(origin.link.delegationID),"status":JSON(result.status.rawValue),"result":try subagentJSON(result)]]
        var next = subagents; try next.consume(record, sessionID: id)
        try journal.append(record, flush: true); subagents = next
    }
    func waitForSubagent() async { await runTask?.value }
    func subagentResult(_ plan: SubagentPlan, cancelled: Bool) -> SubagentToolResult {
        let final = visible.last { $0.role == "assistant" && !$0.content.contains(where: { $0["type"].text == "toolCall" }) }
        let interrupted = cancelled || state == .paused || state == .stopping
        let status: SubagentStatus = interrupted ? .interrupted : state == .error ? .failed : final?.stopReason == "length" ? .outputLimited : .completed
        let error = interrupted ? AgentError("subagent_stopped", "The delegated run was stopped. Effects may already have occurred. It was not restarted.")
            : state == .error ? AgentError(errorCode ?? "subagent_failed", errorMessage ?? "The delegated run failed") : nil
        return SubagentToolResult(plan: plan, status: status, text: final?.text ?? "", error: error, messageIDs: final.map { [$0.id] } ?? [], accountingRevision: accounting.revision, began: true)
    }
}
