import Foundation

extension AgentSession {
    // Internal fixture entry as well as the sole production switch's target.
    func enableAgentSteering(_ coordinator: AgentSteeringCoordinator) {
        agentCoordinator = coordinator
        if !isSubagent {
            let owner = id, runtime = displayEpoch
            familyCancelled = { generation in Task { await coordinator.cancel(owner:owner,runtimeID:runtime,through:generation) } }
        }
    }
    func agentState() -> AgentFamilyState { subagents.family ?? AgentFamilyState(ownerID:subagents.origin?.link.budgetOwnerSessionID ?? id) }
    func agentReceipt(_ key: SubagentCallKey, digest: String) throws -> JSON? {
        guard let op = subagents.family?.operations[AgentOperation.id(key)] else { return nil }
        guard op.digest == digest else { throw AgentError("subagent_operation_conflict", "This accepted call has different arguments") }
        return op.receipt
    }
    func appendAgentRecord<T: Encodable>(_ kind: String, _ data: T, owner: String? = nil) throws {
        guard let journal, !closed else { throw AgentError("subagent_persistence", "The family journal is closed") }
        let row: JSON = ["type":"custom","customType":JSON(kind),"ownerID":JSON(owner ?? subagents.origin?.link.budgetOwnerSessionID ?? id),"data":try subagentJSON(data)]
        var next = subagents; try next.consume(row,sessionID:id)
        try journal.append(row,flush:true); subagents = next
        subagentChangeRevision += 1; event("subagents.changed")
    }
    func acceptAgentOperation(_ proposed: AgentOperation, generation: Int) throws -> AgentOperation {
        if let saved = subagents.family?.operations[proposed.id] {
            guard saved.digest == proposed.digest else { throw AgentError("subagent_operation_conflict", "Conflicting accepted call") }; return saved
        }
        guard agentCoordinator != nil, !isSubagent, !closed, !queuePaused, stopCount == generation,
              activeTaskPresentation != nil, subagents.family?.run?.closed != true else { throw AgentError("subagent_closed", "The parent run no longer accepts agent commands") }
        try Task.checkCancellation(); try enforceCostLimit()
        if proposed.key.parentSessionID == id {
            guard toolHistory.owners[proposed.key.toolCallID] == proposed.key.assistantMessageID else { throw SubagentRecovery.damaged() }
        } else {
            guard let message = proposed.message, message.author == "subagent", message.childID == proposed.key.parentSessionID,
                  subagents.family?.latest(message.childID)?.turn == message.turn,
                  subagents.family?.latest(message.childID)?.status.terminal == false else { throw SubagentRecovery.damaged() }
        }
        try journal?.synchronize() // issuing assistant is durable before acceptance
        try journal?.promoteToSteering(managedChild:false)
        var op = proposed, nextAccounting = accounting, total = spend
        if !familyBudgetEnabled, op.plan != nil {
            var seed = spend.record; seed["reset"] = true; seed["source"] = "family-adoption"
            op.plan?.adoptionSeed = seed
            try nextAccounting.consume(kind:JournalRecordKind.cost,data:seed,spend:&total)
        }
        do { try appendAgentRecord(JournalRecordKind.agentOperation,op) }
        catch { failFamilyAccounting(error); throw error }
        accounting = nextAccounting; spend = total; familyBudgetEnabled = true
        return op
    }
    func prepareAgentTurn(_ turn: AgentChildTurn, owner: AgentSession, coordinator: AgentSteeringCoordinator) throws {
        guard isSubagent, !closed, runTask == nil, subagents.origin?.link.budgetOwnerSessionID == owner.id else { throw SubagentRecovery.damaged() }
        try journal?.promoteToSteering(managedChild:true)
        try appendAgentRecord(JournalRecordKind.agentTurn,turn)
        budgetOwner = owner; budgetOwnerGeneration = turn.generation
        agentLease = turn; agentTurnClosed = false; agentCoordinator = coordinator
        queue.removeAll(); steering.removeAll(); queuePaused = false
        managedCancellation = { Task { await coordinator.stop(owner:owner.id,target:turn.target,human:false) } }
    }
    func startAgentTurn(_ turn: AgentChildTurn) throws {
        guard agentLease?.executionID == turn.executionID, !closed else { throw SubagentRecovery.damaged() }
        _ = try submitManaged(Submission(commandID:turn.executionID,turnID:turn.inputID,text:turn.task),steer:false)
    }
    func agentResult(_ turn: AgentChildTurn, plan: SubagentPlan, cancelled: Bool) -> SubagentToolResult {
        let final = visible.last { $0.role == "assistant" && $0.taskRootID == turn.inputID && !$0.content.contains { $0["type"].text == "toolCall" } }
        let status: SubagentStatus = cancelled || state == .paused || state == .stopping ? .interrupted : state == .error ? .failed : final?.stopReason == "length" ? .outputLimited : .completed
        var result = SubagentToolResult(plan:plan,status:status,text:final?.text ?? "",error:state == .error ? AgentError(errorCode ?? "subagent_failed",errorMessage ?? "Child failed") : nil,messageIDs:final.map { [$0.id] } ?? [],accountingRevision:accounting.revision,began:true)
        result.envelope["version"] = 3; result.envelope["child_id"] = JSON(id); result.envelope["turn"] = JSON(turn.turn)
        result.metadata["version"] = 2; result.metadata["turn"] = JSON(turn.turn); result.metadata["executionID"] = JSON(turn.executionID)
        result.messageID = nil
        return result
    }
    func saveAgentTerminal(_ turn: AgentChildTurn) throws { try appendAgentRecord(JournalRecordKind.agentTerminal,turn); agentTurnClosed = true }
    func agentToolKey(_ call: ToolCall) throws -> SubagentCallKey {
        guard let assistant = toolHistory.owners[call.id] else { throw SubagentRecovery.damaged() }
        try journal?.synchronize()
        return .init(parentSessionID:id,assistantMessageID:assistant,toolCallID:call.id)
    }
}
