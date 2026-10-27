import Foundation

extension AgentSession {
    func recordAgentUserStop() {
        guard !isSubagent, agentContractVersion == 4 else { return }
        let family = agentState()
        guard var run = family.run, family.turns.values.contains(where: { !$0.status.terminal && $0.taskName != nil }) else { return }
        // Record intent without racing a child's terminal mirror. Sealing
        // applies it to cancelled turns, never to an already sealed answer.
        do {
            run.stoppedByUser = true
            try appendAgentRecord(JournalRecordKind.familyRun,run)
            // Paused turns have no live runner to carry the human initiator.
            // Keep their Resume state, but persist who halted them now.
            if costPaused || costResumePending {
                for var turn in family.turns.values where !turn.status.terminal && turn.taskName != nil {
                    turn.interruptedBy = "the user"
                    try appendAgentRecord(JournalRecordKind.agentTurnState,turn)
                }
            }
        } catch {
            accountingFailure = (error as? AgentError) ?? SubagentRecovery.damaged()
            familyStopReason = accountingFailure
        }
    }
    func requireAgentExecution() throws {
        guard subagents.family == nil || agentCoordinator != nil else {
            throw AgentError("subagent_steering_disabled", "This family requires v3 execution; viewing and export remain available")
        }
    }
    // Internal fixture entry as well as the sole production switch's target.
    func enableAgentSteering(_ coordinator: AgentSteeringCoordinator, codex: Bool = false) async {
        agentNextContractVersion = codex ? 4 : 3
        let legacyPause = costPaused && (journal?.markerKind == JournalRecordKind.steeringMarker || heldToolCalls().0.contains { SubagentSteeringContract.names.contains($0.name) })
        agentContractVersion = codex && !legacyPause ? 4 : 3
        agentCoordinator = coordinator
        if !isSubagent {
            let owner = id, runtime = displayEpoch
            familyCancelled = { generation in Task { await coordinator.cancel(owner:owner,runtimeID:runtime,through:generation) } }
            // A hold left by an earlier runtime of this chat (its pause ended
            // while unloaded, e.g. its only paused side was deleted) goes.
            if !costPaused { await coordinator.releaseStaleHold(owner:self,generation:pauseGeneration) }
        }
    }
    func startAgentEpoch(startingFresh: Bool = false) throws {
        if startingFresh, !isSubagent { agentContractVersion = agentNextContractVersion }
        guard agentCoordinator != nil, !isSubagent, subagents.family != nil, let execution = activeTaskPresentation?.executionID,
              subagents.family?.run?.epoch != execution else { return }
        if agentContractVersion == 4 { try adoptCodexNames() }
        try appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:execution))
    }
    func agentState() -> AgentFamilyState { subagents.family ?? AgentFamilyState(ownerID:subagents.origin?.link.budgetOwnerSessionID ?? id) }
    func agentReceipt(_ key: SubagentCallKey, digest: String) throws -> JSON? {
        guard let op = subagents.family?.operations[AgentOperation.id(key)] else { return nil }
        guard op.digest == digest else { throw AgentError("subagent_operation_conflict", "This accepted call has different arguments") }
        return op.receipt
    }
    func appendAgentRecord<T: Encodable>(_ kind: String, _ data: T, owner: String? = nil) throws {
        guard let journal else { throw AgentError("subagent_persistence", "The family journal is closed") }
        if agentContractVersion == 4 { try journal.promoteToCodex(managedChild:isSubagent) }
        else { try journal.promoteToSteering(managedChild:isSubagent) }
        guard [JournalRecordKind.steeringMarker,JournalRecordKind.codexMarker].contains(journal.markerKind) else { throw AgentError("subagent_promotion", "V3 commands require a promoted journal") }
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
              activeTaskPresentation?.executionID == proposed.epoch, subagents.family?.run?.closed != true || subagents.family?.run?.epoch != proposed.epoch else { throw AgentError("subagent_closed", "The parent run no longer accepts agent commands") }
        try Task.checkCancellation(); try enforceCostLimit()
        if proposed.key.parentSessionID == id {
            guard toolHistory.owners[proposed.key.toolCallID] == proposed.key.assistantMessageID else { throw SubagentRecovery.damaged() }
        } else {
            if proposed.receipt["version"].int == 4 {
                guard let source = proposed.sourceTurn, source.childID == proposed.key.parentSessionID,
                      subagents.family?.latest(source.childID)?.target == source,
                      subagents.family?.latest(source.childID)?.status.terminal == false else { throw SubagentRecovery.damaged() }
            } else {
                guard let message = proposed.message, message.author == "subagent", message.childID == proposed.key.parentSessionID,
                      subagents.family?.latest(message.childID)?.turn == message.turn,
                      subagents.family?.latest(message.childID)?.status.terminal == false else { throw SubagentRecovery.damaged() }
            }
        }
        do { try AgentMailboxPolicy.validate(proposed,state:agentState()) }
        catch { if (error as? AgentError)?.code == "coordination_limit" { familyStopReason = error as? AgentError; stop(userInitiated:false) }; throw error }
        try journal?.synchronize() // issuing assistant is durable before acceptance
        if proposed.receipt["version"].int == 4 { try journal?.promoteToCodex(managedChild:false) }
        else { try journal?.promoteToSteering(managedChild:false) }
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
        // A new accepted turn follows a terminal one. A parked Stop may
        // have sealed only the owner while this runtime was unloaded. Retire
        // its old pause and pair held calls without executing stopped work.
        let paused = costPaused || !costPendingCalls.isEmpty
        let (held, attempts) = heldToolCalls()
        currentAttemptIDs = attempts
        for call in held { try recordTool(call,result:resultText("Not executed: the child turn was stopped.",error:true),started:nil,state:.cancelled) }
        costPendingCalls = []
        _ = endCostPause()
        agentContractVersion = turn.taskName == nil ? 3 : 4
        codexContext = turn.codexContext ?? subagents.origin?.codexContext
        if agentContractVersion == 4 { try journal?.promoteToCodex(managedChild:true) }
        else { try journal?.promoteToSteering(managedChild:true) }
        try appendAgentRecord(JournalRecordKind.agentTurn,turn)
        budgetOwner = owner; budgetOwnerGeneration = turn.currentGeneration
        agentLease = turn; agentTurnClosed = false; agentCoordinator = coordinator
        managedProgress = { [weak coordinator] in await coordinator?.progress(turn.target) }
        queue.removeAll(); steering.removeAll(); queuePaused = false
        managedCancellation = { Task { await coordinator.stop(owner:owner.id,target:turn.target,human:false) } }
        if paused { try persistState(durable:true) }
    }
    /// Resume after a cost-limit pause: the same turn, bound to the owner's
    /// resumed execution. Its mirror records the continuation like the owner.
    func resumeAgentTurn(_ turn: AgentChildTurn, owner: AgentSession, coordinator: AgentSteeringCoordinator, generation: CostPauseGeneration) throws {
        // A child mirror belongs to the committed owner Resume, never a later
        // pause. Holding this synchronous fence orders it before that pause.
        let applied: Void? = try generation.clock.apply(generation) {
            guard generation.clock === owner.costPauseClock, !owner.costPauseClock.isPaused else { throw CancellationError() }
            try installAgentResume(turn,owner:owner,coordinator:coordinator)
        }
        guard applied != nil else { throw CancellationError() }
    }
    private func installAgentResume(_ turn: AgentChildTurn, owner: AgentSession, coordinator: AgentSteeringCoordinator) throws {
        guard isSubagent, !closed, subagents.origin?.link.budgetOwnerSessionID == owner.id else { throw SubagentRecovery.damaged() }
        if agentLease?.id == turn.id, agentLease?.continuations == turn.continuations, !costPaused { return }
        guard runTask == nil, let continuation = turn.continuations?.last else { throw SubagentRecovery.damaged() }
        agentContractVersion = turn.taskName == nil ? 3 : 4
        codexContext = turn.codexContext ?? subagents.origin?.codexContext
        if agentContractVersion == 4 { try journal?.promoteToCodex(managedChild:true) }
        else { try journal?.promoteToSteering(managedChild:true) }
        // A mirror that missed earlier Resumes catches up one continuation at
        // a time, as the owner recorded them.
        var queued = turn; queued.status = .queued; queued.result = nil
        if let saved = subagents.family?.turns[turn.id] {
            for step in queued.mirrorSteps(from:saved) where step != saved { try appendAgentRecord(JournalRecordKind.agentTurnState,step) }
        } else { try appendAgentRecord(JournalRecordKind.agentTurn,queued) }
        budgetOwner = owner; budgetOwnerGeneration = continuation.generation
        agentLease = turn; agentTurnClosed = false; agentCoordinator = coordinator
        managedProgress = { [weak coordinator] in await coordinator?.progress(turn.target) }
        // The turn's own task may be accepted but not yet delivered: it is the
        // input this Resume releases, never a second submission of it.
        queue.removeAll { $0.turnID != turn.inputID }; steering.removeAll(); queuePaused = false
        managedCancellation = { Task { await coordinator.stop(owner:owner.id,target:turn.target,human:false) } }
        if costPaused { _ = endCostPause(); try persistState(durable:true) }
    }
    enum AgentTurnStart { case fresh, accepted, delivered }
    /// How far a resumed turn's task got, from durable evidence (its command
    /// receipt survives compaction and checkpoints; the loaded history window
    /// alone does not): never sent, accepted and waiting, or delivered.
    func agentTurnStart(_ turn: AgentChildTurn) -> AgentTurnStart {
        if queue.contains(where: { $0.turnID == turn.inputID }) { return .accepted }
        if history.contains(where: { $0.id == turn.inputID }) { return .delivered }
        return commands.contains { $0["turnId"].text == turn.inputID } ? .delivered : .fresh
    }
    /// Sends the turn's accepted task that a pause held before delivery.
    func releaseAgentTurn(_ turn: AgentChildTurn) throws {
        guard agentLease?.executionID == turn.executionID, !closed, runTask == nil, queue.contains(where: { $0.turnID == turn.inputID }) else { throw SubagentRecovery.damaged() }
        queuePaused = false; try persistState(); launch()
    }
    /// Continues a resumed turn from its context as it stands, like `run.continue`.
    func continueAgentTurn(_ turn: AgentChildTurn) throws {
        guard agentLease?.executionID == turn.executionID, !closed, runTask == nil else { throw SubagentRecovery.damaged() }
        currentTurnID = turn.inputID; taskRootID = turn.inputID
        activeSubmission = Submission(commandID:Self.continuePrefix + turn.executionID + ":" + String(turn.continuations?.count ?? 0),turnID:Self.continuePrefix + turn.inputID,text:"",thinkingLevel:turn.effort)
        retrySubmission = nil; continuing = true; queuePaused = false; errorMessage = nil; errorCode = nil
        try persistState(active:true)
        launch()
    }
    /// The coordinator parked this turn at the owner's cost-limit pause.
    func parkAgentTurn(_ turn: AgentChildTurn, generation: CostPauseGeneration) throws {
        // Same pause may still be draining during prepare; after commit or a
        // newer pause, this old mirror write is a no-op. No await follows.
        try generation.clock.applyPause(generation) { try parkCurrentAgentTurn(turn) }
    }
    private func parkCurrentAgentTurn(_ turn: AgentChildTurn) throws {
        guard isSubagent,
              subagents.family?.latest(id)?.id == turn.id, subagents.family?.turns[turn.id]?.status.terminal != true else { return }
        endSubagentProgress()
        if let saved = subagents.family?.turns[turn.id], saved.status != turn.status || saved.continuations != turn.continuations, !saved.status.terminal {
            try appendAgentRecord(JournalRecordKind.agentTurnState,turn)
        }
        costPaused = true; queuePaused = true
        if state != .error { state = .paused; runStatus = .cancelled }
        errorCode = Self.costLimitCode; errorMessage = "Paused at the shared cost limit. It goes on when the main chat resumes."
        try persistState(durable:true); event("state")
    }
    func parkOwnedTurn(_ turn: AgentChildTurn, generation: CostPauseGeneration) throws {
        guard generation.clock === costPauseClock, generation.isCurrentPause else { return }
        try appendAgentRecord(JournalRecordKind.agentTurnState,turn)
    }
    func installResumedTurn(_ turn: AgentChildTurn, generation: CostPauseGeneration) throws {
        try generation.check()
        guard generation.clock === costPauseClock, costResumePending else { throw CancellationError() }
        try appendAgentRecord(JournalRecordKind.agentTurnState,turn)
    }
    func publishParkedSummary(_ summary: SubagentSummary, generation: CostPauseGeneration) {
        // A delayed discovery update cannot restore a pre-Resume pause badge.
        guard generation.clock === costPauseClock, generation.isCurrentPause else { return }
        subagentChanged(summary)
    }
    func startAgentTurn(_ turn: AgentChildTurn) async throws {
        guard agentLease?.executionID == turn.executionID, !closed else { throw SubagentRecovery.damaged() }
        if turn.taskName != nil, let coordinator = agentCoordinator { _ = try await coordinator.boundary(self,final:false) }
        _ = try submitManaged(Submission(commandID:turn.executionID,turnID:turn.inputID,text:turn.task,thinkingLevel:turn.effort),steer:false)
    }
    func agentResult(_ turn: AgentChildTurn, plan: SubagentPlan, cancelled: Bool) -> SubagentToolResult {
        let final = visible.last { $0.role == "assistant" && $0.taskRootID == turn.inputID && !$0.content.contains { $0["type"].text == "toolCall" } }
        let status: SubagentStatus = cancelled || state == .paused || state == .stopping ? .interrupted : state == .error ? .failed : final?.stopReason == "length" ? .outputLimited : .completed
        var result = SubagentToolResult(plan:plan,status:status,text:final?.text ?? "",error:state == .error ? AgentError(errorCode ?? "subagent_failed",errorMessage ?? "Child failed") : nil,messageIDs:final.map { [$0.id] } ?? [],accountingRevision:accounting.revision,began:true,textLimit:turn.taskName == nil ? 65_536 : 1_048_576)
        result.envelope["version"] = JSON(turn.taskName == nil ? 3 : 4); result.envelope["child_id"] = JSON(id); result.envelope["turn"] = JSON(turn.turn)
        result.envelope["effort"] = JSON(turn.effort ?? plan.origin.model.thinkingLevel ?? "default")
        result.metadata["effort"] = result.envelope["effort"]
        result.metadata["version"] = 2; result.metadata["turn"] = JSON(turn.turn); result.metadata["executionID"] = JSON(turn.executionID)
        result.messageID = nil
        return result
    }
    /// The parked runner may already have closed its writer while its job
    /// is still settling. Check and write in one actor turn; otherwise the
    /// host resolves a retained reader or the closed journal.
    func retireParkedAgentTurn(_ turn: AgentChildTurn) throws -> Bool {
        guard !closed, journal != nil else { return false }
        try saveAgentTerminal(turn); return true
    }
    func saveAgentTerminal(_ turn: AgentChildTurn) throws {
        if let saved = subagents.family?.turns[turn.id], !saved.status.terminal {
            var queued = turn; queued.status = .queued; queued.result = nil
            for step in queued.mirrorSteps(from:saved) where step != saved { try appendAgentRecord(JournalRecordKind.agentTurnState,step) }
        }
        if subagents.family?.turns[turn.id] != turn { try appendAgentRecord(JournalRecordKind.agentTerminal,turn) }
        guard subagents.family?.latest(id)?.id == turn.id else { return }
        agentTurnClosed = true
        try retireTerminalAgentPause()
    }
    /// A terminal turn is the durable authority to discard its Resume-only
    /// state, including when a crash separated the terminal and state saves.
    /// Pair never-started calls before retiring their IDs; never invoke them.
    func retireTerminalAgentPause() throws {
        guard isSubagent, subagents.family?.latest(id)?.status.terminal == true,
              costPaused || !costPendingCalls.isEmpty || costPendingCompaction else { return }
        let (held, attempts) = heldToolCalls(); currentAttemptIDs = attempts
        for call in held { try recordTool(call,result:resultText("Not executed: the child turn was stopped.",error:true),started:nil,state:.cancelled) }
        let paused = costPauseState, pending = costPendingCalls, compact = (costPendingCompaction,costPendingCompactionFocus)
        let previous = (queue,steering,queuePaused,state,runStatus)
        costPendingCalls = []; costPendingCompaction = false; costPendingCompactionFocus = nil
        _ = endCostPause()
        costResumePending = false; resumingCostPause = false; familyWaitResume = false; compactOnResume = false
        queue.removeAll(); steering.removeAll(); queuePaused = false
        if errorCode == Self.costLimitCode { errorCode = nil; errorMessage = nil }
        if state == .paused { state = .idle; runStatus = .idle }
        do { try persistState(durable:true) }
        catch {
            restoreCostPause(paused); costPendingCalls = pending
            (costPendingCompaction,costPendingCompactionFocus) = compact
            (queue,steering,queuePaused,state,runStatus) = previous
            throw error
        }
        event("state")
    }
    func agentToolKey(_ call: ToolCall) throws -> SubagentCallKey {
        guard let assistant = toolHistory.owners[call.id] else { throw SubagentRecovery.damaged() }
        try journal?.synchronize()
        return .init(parentSessionID:id,assistantMessageID:assistant,toolCallID:call.id)
    }
}
