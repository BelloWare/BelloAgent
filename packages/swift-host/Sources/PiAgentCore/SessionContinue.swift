import Foundation

// Resume: the run a Stop, a quit, a restart or an update cut off goes on
// from the chat's history as it stands, with no new user message. This is
// pi 0.85.1's continue (agent.ts `continue`, agent-loop `agentLoopContinue`):
// the model is asked again from the context; a context that ends with an
// assistant reply has nothing to continue, and only then do pending steering
// and follow-ups go instead, as a prompt would send them.
//
// The no-replay rule stays: nothing here runs a tool. A call that was cut
// off already has its result in the context (cancelled before it ran, or
// interrupted with its effects unknown), and the model reads that and
// decides. A reply cut off mid-stream is kept as its interrupted row, which
// is never sent again (`replayEligible` is false); the continuation is a new
// assistant turn after it.

extension AgentSession {
    /// The receipt key a continuation's command is kept under. It never names
    /// a user turn, so a continuation's receipt cannot replace a message's.
    static let continuePrefix = "continue:"

    /// The last message a request would carry: what a continuation answers.
    var continuationTail: ChatMessage? {
        context.last { $0.replayEligible && !requestExclusions.contains($0.id) }
    }
    /// Whether `run.continue` would run the model now: nothing is running,
    /// no queued edit holds the chat, and the context ends with something the
    /// model has not answered — a user message, or tool results (cut-off
    /// ones included). The snapshot says so, and the app offers Resume.
    var hasPendingAgentEvents: Bool { !(subagents.family?.pending(author:"subagent").isEmpty ?? true) }
    var canContinue: Bool {
        guard !isSubagent, runTask == nil, !closed, queueEdit == nil, !titleTask, !isConnectionTest else { return false }
        // A family paused at its cost limit always has its Resume, and so do
        // tool calls or a compaction the pause cut, even with the pause
        // already ended (a helper that stopped before Resume's run did them).
        if costPaused || membersPendingResume || !costPendingCalls.isEmpty || costPendingCompaction { return true }
        guard let tail = continuationTail else { return false }
        return Self.continues(from: tail) || hasPendingAgentEvents
    }
    /// Unsealed sub-agent turns this owner parked at a cost-limit pause.
    var hasParkedAgentTurns: Bool {
        !isSubagent && agentCoordinator != nil && subagents.family?.turns.values.contains { !$0.status.terminal } == true
    }
    /// Ends a cost-limit pause for a Resume, in memory: the caller persists
    /// (and restores `CostPauseState` on any failure). The next run releases
    /// the coordinator's hold and resumes parked turns. Returns the sides the
    /// app resumes as well; each stays listed until it resumes itself
    /// (`forgetPausedMember`), so a lost reply or failed fan-out can retry.
    func endCostPause() -> [String] {
        guard costPaused else { return costPausedMembers }
        costPaused = false; budgetStopIssued = false; costResumeCount &+= 1
        if familyStopReason?.code == Self.costLimitCode { familyStopReason = nil }
        if errorCode == Self.costLimitCode { errorCode = nil; errorMessage = nil }
        resumingCostPause = !isSubagent && agentCoordinator != nil
        return costPausedMembers
    }
    struct CostPauseState { var paused: Bool, members: [String], reason: AgentError?, issued: Bool, code: String?, message: String?, resumes: Int }
    var costPauseState: CostPauseState { .init(paused:costPaused,members:costPausedMembers,reason:familyStopReason,issued:budgetStopIssued,code:errorCode,message:errorMessage,resumes:costResumeCount) }
    func restoreCostPause(_ saved: CostPauseState) {
        costPaused = saved.paused; costPausedMembers = saved.members; familyStopReason = saved.reason
        budgetStopIssued = saved.issued; errorCode = saved.code; errorMessage = saved.message
        // A refused Resume ended nothing: side pauses issued before it still apply.
        costResumeCount = saved.resumes
        resumingCostPause = false; familyWaitResume = false; compactOnResume = false; costResumePending = false
    }
    /// The whole family's limit, checked before a Resume of a paused chat:
    /// a side reads its root's. Raising the limit alone resumes nothing.
    public func requireCostResumeRoom() async throws {
        guard costPaused else { return }
        do { try await enforceSharedCostLimit() }
        catch let error as AgentError where error.code == Self.costLimitCode {
            throw AgentError(Self.costLimitCode, "Still at the cost limit. Raise the limit above the current spend, then choose Resume.")
        }
    }
    /// A context ending in a user message, tool results, or a compaction
    /// summary (a compaction that summarized the whole tail, before the
    /// request it made room for) has a run to go on with.
    static func continues(from tail: ChatMessage) -> Bool {
        tail.role == "user" || tail.role == "toolResult" || (tail.role == "system" && tail.kind == "compaction")
    }
    /// The turn a continuation belongs to: the newest user message's, or —
    /// when a compaction summarized it and kept its replies — the turn those
    /// replies carry; else the newest shown user message's.
    var continuedTurn: String? {
        let newest = context.last { $0.role == "user" || ($0.role != "system" && $0.turn?.isEmpty == false) }
        return newest.flatMap { $0.role == "user" ? $0.id : $0.turn } ?? visible.last { $0.role == "user" }?.id
    }

    /// `run.continue`. `overrides` are the chat's current choices (model,
    /// thinkingLevel, contextWindow, maxOutputTokens, modelOutputLimit, input),
    /// as for a send or a retry; absent keys mean the connection's defaults.
    ///
    /// Idempotent by `commandID`: the receipt is saved with the run state
    /// before the run starts, so the same command sent again — a reply lost
    /// to a helper that then restarted — finds it and runs nothing. A second
    /// Resume with a new identity while this one runs is refused as busy.
    public func continueRun(commandID: String, overrides: JSON = [:]) throws -> JSON {
        try requireIndependentSession()
        try requireAgentExecution()
        guard !closed else { throw AgentError("session_closed", "Session runtime is unloaded") }
        let receiptKey = Self.continuePrefix + commandID
        if let receipt = commands.last(where: { $0["commandId"].text == commandID }) {
            guard receipt["turnId"].text == receiptKey else { throw AgentError("command_conflict", "Command identity already used for another command") }
            var reply: JSON = ["accepted": true, "duplicate": true, "continued": true, "state": receipt["state"]]
            // A retried family Resume still learns which sides wait for it.
            if !costPausedMembers.isEmpty { reply["pausedMembers"] = .array(costPausedMembers.map(JSON.string)) }
            return reply
        }
        guard runTask == nil else { throw AgentError("session_busy", "Run already active") }
        guard queueEdit == nil else { throw Self.editHeldError }
        // A family paused at its limit resumes only below it. Its parked
        // sub-agent turns go on with the run; its sides are named for the app.
        let paused = costPauseState
        var members: [String] = []
        if costPaused { try enforceCostLimit() }
        // Every refusal from here on leaves the pause exactly as it was.
        var committed = false
        defer {
            if !committed, paused.paused { restoreCostPause(paused) }
            // A side that resumed no longer needs its root to name it.
            // Not before the Resume's run has taken the paused work
            // (`costResumePending`): a crash before then reopens the side
            // paused, and its root must still name it.
            if committed, paused.paused, !costResumePending, let root = sideBudgetParents.last { let side = id; Task { await root.forgetPausedMember(side) } }
        }
        // A root whose own Resume was accepted before its sides were
        // resumed (an app that quit in between) still hands them out.
        if costPaused { members = endCostPause() } else if !isSubagent { members = costPausedMembers }
        // A manual compaction the pause cut runs first in the Resume's own run
        // (with its overrides), which then goes on with the rest of the work.
        // Also once the pause is over (a helper that ended before it ran).
        let compactFirst = costPendingCompaction && !titleTask
        let familyOnly = paused.paused && hasParkedAgentTurns || compactFirst
        // Held tool calls are a run to go on with: they run first.
        let tailContinues = continuationTail.map { Self.continues(from: $0) } ?? false || hasPendingAgentEvents || !costPendingCalls.isEmpty
        // With nothing of its own cut off, the run waits for the resumed
        // family first, as its turn's end did; follow-ups go after it.
        guard !titleTask, !isConnectionTest, tailContinues || familyOnly else {
            if paused.paused || !members.isEmpty, queue.isEmpty, steering.isEmpty {
                // Nothing of its own waits: the pause is over once saved.
                commandState(Submission(commandID: commandID, turnID: receiptKey, text: ""), "completed")
                queuePaused = false
                if state != .error { state = .idle; runStatus = .idle }
                do { try persistState(durable:true) } catch {
                    commands.removeAll { $0["turnId"].text == receiptKey }; restoreCostPause(paused); queuePaused = true; throw error
                }
                event("state")
                // No run: release the coordinator's hold now.
                resumingCostPause = false; committed = true
                if !isSubagent, let coordinator = agentCoordinator { let generation = costPauseCount; Task { try? await coordinator.resumeParked(owner:self,generation:generation) } }
                return ["accepted": true, "continued": false, "resumedFamily": true, "pausedMembers": .array(members.map(JSON.string))]
            }
            // Pi: from an answered context (or none: a first message stopped
            // before it was delivered), continue sends what waits instead.
            // So does a chat the model is never asked to go on in by itself
            // (a connection test, a title).
            guard !queue.isEmpty || !steering.isEmpty else {
                throw AgentError(AgentErrorCode.nothingToContinue, "There is nothing to resume; send a new message instead")
            }
            // Its receipt goes with the queue's release, in the same record:
            // the same command sent again releases nothing twice.
            commandState(Submission(commandID: commandID, turnID: receiptKey, text: ""), "completed")
            do { try resumeQueue() } catch { commands.removeAll { $0["turnId"].text == receiptKey }; restoreCostPause(paused); throw error }
            committed = true
            var reply: JSON = ["accepted": true, "continued": false, "resumedQueue": true]
            if paused.paused || !members.isEmpty { reply["resumedFamily"] = true; reply["pausedMembers"] = .array(members.map(JSON.string)) }
            return reply
        }
        var submission = Submission(commandID: commandID, turnID: receiptKey, text: "")
        submission.model = overrides["model"].text; submission.thinkingLevel = overrides["thinkingLevel"].text
        submission.contextWindow = overrides["contextWindow"].int; submission.maxOutputTokens = overrides["maxOutputTokens"].int
        submission.modelOutputLimit = overrides["modelOutputLimit"].int; submission.input = try NativeHostService.turnInput(overrides["input"])
        _ = try profile.overriding(submission)
        // The continuation's rows belong to the turn they continue.
        let previous = (turn: currentTurnID, paused: queuePaused, message: errorMessage, code: errorCode)
        if let turn = continuedTurn { currentTurnID = turn }
        activeSubmission = submission; continuing = true; queuePaused = false; errorMessage = nil; errorCode = nil
        familyWaitResume = !tailContinues
        compactOnResume = compactFirst
        costResumePending = paused.paused
        commandState(submission, "queued")
        // Saved as a run under way, with its receipt: a helper that dies
        // before the run's own first record leaves the chat interrupted, so
        // it offers Resume again after the restart, never idle.
        do { try persistState(active: true, durable: true) } catch {
            commands.removeAll { $0["turnId"].text == receiptKey }
            activeSubmission = nil; continuing = false
            currentTurnID = previous.turn; queuePaused = previous.paused; errorMessage = previous.message; errorCode = previous.code
            restoreCostPause(paused)
            throw error
        }
        committed = true
        launch()
        var reply: JSON = ["accepted": true, "continued": true]
        if compactFirst { reply["compacting"] = true }
        if paused.paused || !members.isEmpty { reply["resumedFamily"] = true; reply["pausedMembers"] = .array(members.map(JSON.string)) }
        return reply
    }
}
