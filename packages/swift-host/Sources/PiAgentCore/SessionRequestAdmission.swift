import Foundation

extension AgentSession {
    /// Enabled only by the hidden coordinator (or explicit in-process fixtures).
    func enableFamilyBudget() { familyBudgetEnabled = true }

    func bindBudgetOwner(_ owner: AgentSession, generation: Int) throws {
        guard isSubagent, budgetOwner == nil else { throw AgentError("subagent_identity", "A child has one immutable budget owner") }
        budgetOwner = owner; budgetOwnerGeneration = generation
    }

    func requestLifecycle(turnID: String, purpose: String) async throws -> RequestLifecycle? {
        guard familyBudgetEnabled || isSubagent else { return nil }
        guard let owner = isSubagent ? budgetOwner : self else { throw AgentError("managed_subagent", "The parent must own this child's requests") }
        let sourceGeneration = stopCount
        let scope = RequestScope(sourceSessionID: id, budgetOwnerSessionID: isSubagent ? subagents.origin!.link.budgetOwnerSessionID : id,
                                 turnID: turnID, executionID: activeTaskPresentation?.executionID ?? displayEpoch, purpose: purpose,
                                 ownerGeneration: isSubagent ? budgetOwnerGeneration : stopCount, delegation: subagents.origin?.link)
        return RequestLifecycle(scope: scope, admitAttempt: { [weak self, weak owner] attempt in
            guard let self, let owner else { throw AgentError("accounting_unavailable", "The budget owner is unavailable") }
            let permit = try await owner.admitAttempt(scope: scope, attemptID: attempt)
            await self.attachRequestPermit(permit, generation: sourceGeneration)
            return permit
        }, willDispatch: { [weak owner] attempt in
            guard let owner else { throw AgentError("accounting_unavailable", "The budget owner is unavailable") }
            try await owner.dispatchAttempt(scope: scope, attemptID: attempt)
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
                  activeTaskPresentation?.executionID == link.parentExecutionID else { throw AttemptAccounting.damaged() }
        } else if scope.sourceSessionID != id { throw AttemptAccounting.damaged() }
    }
    func admitAttempt(scope: RequestScope, attemptID: String) throws -> RequestPermit {
        try validateRequestOwner(scope)
        guard !closed, !queuePaused, scope.ownerGeneration == stopCount else { throw CancellationError() }
        try Task.checkCancellation(); try enforceCostLimit()
        guard accounting.attempts[attemptID] == nil else { throw AttemptAccounting.damaged() }
        var admission: JSON = ["attemptId":JSON(attemptID), "sourceSessionId":JSON(scope.sourceSessionID), "budgetOwnerSessionId":JSON(id),
                               "purpose":JSON(scope.purpose), "state":"admitted", "scope":try subagentJSON(scope), "accountingRevision":JSON(accounting.revision + 1)]
        if let link = scope.delegation { admission["delegationId"] = JSON(link.delegationID) }
        do { try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: admission) }
        catch { failFamilyAccounting(error); throw error }
        let permit = RequestPermit(attemptID); requestPermits[attemptID] = permit
        return permit
    }
    func dispatchAttempt(scope: RequestScope, attemptID: String) throws {
        guard !closed, !queuePaused, scope.ownerGeneration == stopCount, let permit = requestPermits[attemptID] else { throw CancellationError() }
        try permit.check(); try enforceCostLimit()
        guard var record = accounting.attempts[attemptID]?.admission, record["scope"] == (try subagentJSON(scope)) else { throw AttemptAccounting.damaged() }
        record["state"] = "dispatched"; record["accountingRevision"] = JSON(accounting.revision + 1)
        do { try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: record) }
        catch { failFamilyAccounting(error); throw error }
    }
    /// Already-admitted attempts may settle after Stop or while close waits.
    /// Ownership comes from their durable admission, not the current turn.
    func settleOwnedAttempt(_ settlement: AttemptSettlement) throws -> JSON? {
        let observation = settlement.observation, attempt = observation.attemptID
        guard let admission = accounting.attempts[attempt]?.admission,
              admission["scope"] == (try subagentJSON(settlement.scope)), observation.sessionID == settlement.scope.sourceSessionID,
              observation.turnID == settlement.scope.turnID, observation.purpose == settlement.scope.purpose else { throw AttemptAccounting.damaged() }
        defer { requestPermits.removeValue(forKey: attempt)?.finish() }
        if !settlement.dispatched {
            var record = admission; record["state"] = "not_dispatched"; record["accountingRevision"] = JSON(accounting.revision + 1)
            try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: record)
            return nil
        }
        if let previous = accounting.attempts[attempt]?.contribution { return previous }
        let data = contribution(observation, owner: id, delegation: settlement.scope.delegation?.delegationID)
        try appendAccounting(kind: JournalRecordKind.cost, data: data)
        stopFamilyAtLimit()
        return data
    }
    private func settleFamilyAttempt(_ settlement: AttemptSettlement, owner: AgentSession) async throws {
        defer { requestPermits.removeValue(forKey: settlement.observation.attemptID)?.finish() }
        do {
            if let data = try await owner.settleOwnedAttempt(settlement), isSubagent {
                try appendAccounting(kind: JournalRecordKind.cost, data: data)
            }
        } catch {
            // Preserve terminal evidence locally if the owner's append failed.
            // Recovery validates it against the owner's admission before use.
            if isSubagent, settlement.dispatched, accounting.attempts[settlement.observation.attemptID]?.contribution == nil {
                let data = contribution(settlement.observation, owner: settlement.scope.budgetOwnerSessionID, delegation: settlement.scope.delegation?.delegationID)
                _ = try? appendAccounting(kind: JournalRecordKind.cost, data: data)
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
    func stopFamilyAtLimit() {
        guard familyBudgetEnabled, costLimitReached else { return }
        do { try enforceCostLimit() } catch { familyStopReason = error as? AgentError }
        stop()
    }
}
