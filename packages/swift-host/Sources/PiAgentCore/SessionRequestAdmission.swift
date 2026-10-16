import Foundation

extension AgentSession {
    /// Accounting fixture seam. Production adopts the ledger atomically with
    /// the first accepted plan in `registerDelegation`, including its spend seed.
    func enableFamilyBudget() { familyBudgetEnabled = true }

    func bindBudgetOwner(_ owner: AgentSession, generation: Int) throws {
        guard isSubagent, budgetOwner == nil else { throw AgentError("subagent_identity", "A child has one immutable budget owner") }
        budgetOwner = owner; budgetOwnerGeneration = generation
    }

    func requestLifecycle(turnID: String, purpose: String, requestMessages: [ChatMessage]? = nil) async throws -> RequestLifecycle? {
        guard familyBudgetEnabled || isSubagent else { return nil }
        guard let owner = isSubagent ? budgetOwner : self else { throw AgentError("managed_subagent", "The parent must own this child's requests") }
        let sourceGeneration = stopCount
        // Manual compaction may summarize an idle, paused parent without
        // releasing its follow-ups. This permission belongs to this request;
        // a later Stop still revokes it through the generation and permit.
        let allowsPausedQueue = !isSubagent && purpose == "compaction" && compactionState["reason"].text == "manual"
        var scope = RequestScope(sourceSessionID: id, budgetOwnerSessionID: isSubagent ? subagents.origin!.link.budgetOwnerSessionID : id,
                                 turnID: turnID, executionID: activeTaskPresentation?.executionID ?? displayEpoch, purpose: purpose,
                                 ownerGeneration: isSubagent ? budgetOwnerGeneration : stopCount, delegation: subagents.origin?.link)
        scope.childTurn = agentLease?.turn; scope.parentExecutionID = agentLease?.currentParentExecutionID
        if agentCoordinator != nil, let requestMessages { scope.agentDeliveryIDs = requestMessages.flatMap { $0.nativeAgentDelivery?["eventIds"].list.compactMap(\.text) ?? [] } }
        scope = await owner.sharedRequestScope(scope)
        let admittedScope = scope
        return RequestLifecycle(scope: admittedScope, admitAttempt: { [weak self, weak owner] attempt in
            guard let self, let owner else { throw AgentError("accounting_unavailable", "The budget owner is unavailable") }
            let permit = try await owner.admitSharedAttempt(scope: admittedScope, attemptID: attempt, allowsPausedQueue: allowsPausedQueue)
            await self.attachRequestPermit(permit, generation: sourceGeneration)
            return permit
        }, willDispatch: { [weak owner] attempt in
            guard let owner else { throw AgentError("accounting_unavailable", "The budget owner is unavailable") }
            try await owner.dispatchSharedAttempt(scope: admittedScope, attemptID: attempt, allowsPausedQueue: allowsPausedQueue)
        }, settleAttempt: { [weak self, weak owner] settlement in
            guard let self, let owner else { throw AgentError("accounting_unavailable", "The budget owner is unavailable") }
            try await self.settleFamilyAttempt(settlement, owner: owner)
        })
    }

    private func attachRequestPermit(_ permit: RequestPermit, generation: Int) {
        requestPermits[permit.attemptID] = permit
        if closed || stopCount != generation { permit.cancel() }
    }
    func validateRequestOwner(_ scope: RequestScope) throws {
        guard familyBudgetEnabled, !isSubagent, scope.budgetOwnerSessionID == id else { throw AttemptAccounting.damaged() }
        if let link = scope.delegation {
            guard link.valid, link.childSessionID == scope.sourceSessionID,
                  subagents.plans[link.delegationID]?.origin.link == link,
                  activeTaskPresentation?.executionID == (scope.parentExecutionID ?? link.parentExecutionID) else { throw AttemptAccounting.damaged() }
            if let number = scope.childTurn {
                guard let turn = subagents.family?.turns[AgentTurnTarget(childID:scope.sourceSessionID,turn:number).id],
                      !turn.status.terminal, turn.currentParentExecutionID == scope.parentExecutionID, turn.currentGeneration == scope.ownerGeneration else { throw AttemptAccounting.damaged() }
            }
        } else if scope.sourceSessionID != id { throw AttemptAccounting.damaged() }
    }
    func admitAttempt(scope: RequestScope, attemptID: String, allowsPausedQueue: Bool = false) throws -> RequestPermit {
        try validateRequestOwner(scope)
        try enforceCostLimit()
        guard !closed, !queuePaused || allowsPausedQueue, scope.ownerGeneration == stopCount else { throw CancellationError() }
        try Task.checkCancellation()
        guard accounting.attempts[attemptID] == nil else { throw AttemptAccounting.damaged() }
        var admission: JSON = ["attemptId":JSON(attemptID), "sourceSessionId":JSON(scope.sourceSessionID), "budgetOwnerSessionId":JSON(id),
                               "purpose":JSON(scope.purpose), "state":"admitted", "scope":try subagentJSON(scope), "accountingRevision":JSON(accounting.revision + 1)]
        if let link = scope.delegation { admission["delegationId"] = JSON(link.delegationID) }
        do { try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: admission) }
        catch { failFamilyAccounting(error); throw error }
        let permit = RequestPermit(attemptID); requestPermits[attemptID] = permit
        return permit
    }
    func dispatchAttempt(scope: RequestScope, attemptID: String, allowsPausedQueue: Bool = false) throws {
        guard !closed, !queuePaused || allowsPausedQueue, scope.ownerGeneration == stopCount, let permit = requestPermits[attemptID] else { throw CancellationError() }
        try permit.check(); try enforceCostLimit()
        guard var record = accounting.attempts[attemptID]?.admission, record["scope"] == (try subagentJSON(scope)) else { throw AttemptAccounting.damaged() }
        record["state"] = "dispatched"; record["accountingRevision"] = JSON(accounting.revision + 1)
        do { try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: record); inFlightBudgetAttempts.insert(attemptID) }
        catch { failFamilyAccounting(error); throw error }
    }
    /// Already-admitted attempts may settle after Stop or while close waits.
    /// Ownership comes from their durable admission, not the current turn.
    func settleOwnedAttempt(_ settlement: AttemptSettlement) throws -> JSON? {
        let observation = settlement.observation, attempt = observation.attemptID
        guard let admission = accounting.attempts[attempt]?.admission,
              admission["scope"] == (try subagentJSON(settlement.scope)), observation.sessionID == settlement.scope.sourceSessionID,
              observation.turnID == settlement.scope.turnID, observation.purpose == settlement.scope.purpose else { throw AttemptAccounting.damaged() }
        defer { requestPermits.removeValue(forKey: attempt)?.finish(); inFlightBudgetAttempts.remove(attempt); stopFamilyAtLimit() }
        if !settlement.dispatched {
            var record = admission; record["state"] = "not_dispatched"; record["accountingRevision"] = JSON(accounting.revision + 1)
            try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: record)
            return nil
        }
        if let previous = accounting.attempts[attempt]?.contribution { return previous }
        var data = contribution(observation, owner: settlement.scope.budgetOwnerSessionID, delegation: settlement.scope.delegation?.delegationID)
        if let parents = settlement.scope.sideParents { data["sideParents"] = .array(parents.map { JSON($0) }) }
        if let update = try FamilyCharge.merge(data,into:accounting.attempts[attempt],revision:accounting.revision,scope:subagentJSON(settlement.scope)) {
            try appendAccounting(kind:update.kind,data:update.data)
        }
        stopFamilyAtLimit()
        return accounting.attempts[attempt]?.contribution
    }
    private func settleFamilyAttempt(_ settlement: AttemptSettlement, owner: AgentSession) async throws {
        defer { requestPermits.removeValue(forKey: settlement.observation.attemptID)?.finish() }
        let origin = subagents.origin
        let accepted = await owner.subagents.plans[settlement.scope.delegation?.delegationID ?? ""]?.origin
        let child = origin.map { FamilyCharge.Child(accepted:accepted ?? $0,observed:$0) }
        do {
            if let data = try await owner.settleSharedAttempt(settlement), isSubagent,
               let update = try FamilyCharge.merge(data,into:accounting.attempts[settlement.observation.attemptID],revision:accounting.revision,child:child) {
                try appendAccounting(kind:update.kind,data:update.data)
            }
        } catch {
            // Preserve terminal evidence locally if the owner's append failed.
            // Recovery validates it against the owner's admission before use.
            if isSubagent, settlement.dispatched, accounting.attempts[settlement.observation.attemptID]?.contribution == nil {
                let data = contribution(settlement.observation, owner: settlement.scope.budgetOwnerSessionID, delegation: settlement.scope.delegation?.delegationID)
                if let update = try? FamilyCharge.merge(data,into:accounting.attempts[settlement.observation.attemptID],revision:accounting.revision,
                       scope:subagentJSON(settlement.scope),child:child) {
                    _ = try? appendAccounting(kind:update.kind,data:update.data)
                }
            }
            await owner.failFamilyAccounting(error)
            throw error
        }
    }
    func failFamilyAccounting(_ error: Error) {
        accountingFailure = (error as? AgentError) ?? AttemptAccounting.damaged()
        familyStopReason = accountingFailure
        stop()
    }
    /// The only budget-induced Stop: the family pauses at once. Admission
    /// and tool gates close, and every dispatched request, retry wait, tool
    /// and child turn is cancelled the way Stop cancels it; aborted requests
    /// keep whatever usage they reported (unknown stays unknown). Rechecked on
    /// settlement, corrections, limit changes and budget errors. A managed
    /// child only latches the reason: its coordinator parks the turn.
    func stopFamilyAtLimit(_ inherited: AgentError? = nil) {
        if inherited?.code == Self.costLimitCode { familyStopReason = inherited }
        if familyBudgetEnabled, costLimitReached {
            do { try enforceCostLimit() } catch { familyStopReason = error as? AgentError }
        }
        guard let reason = familyStopReason, reason.code == Self.costLimitCode, !isSubagent else { return }
        pauseAtCostLimit(reason)
    }
}
