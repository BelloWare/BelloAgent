import Foundation

extension AgentSession {
    /// Runtime ownership is bound by the host from the journal's side origin,
    /// never from a provider or a tool argument. Forks keep independent budgets.
    func bindSideBudget(to parent: AgentSession) async throws {
        guard isSideChat, parentInfo["parentSessionId"].text == parent.id, parent.id != id else { throw AttemptAccounting.damaged() }
        guard !(await parent.isSubagent) else { throw AttemptAccounting.damaged() }
        let ancestors = await parent.sideBudgetParents
        guard !ancestors.contains(where: { $0.id == id }), ancestors.count < 128 else { throw AttemptAccounting.damaged() }
        sideBudgetParents = [parent] + ancestors
        sideBudgetIDs = sideBudgetParents.map(\.id)
        familyBudgetEnabled = true; costLimitUSD = nil
        for ancestor in sideBudgetParents {
            try await ancestor.registerSideBudget(id, parents: sideBudgetIDs)
        }
        // Old saved sides and a lost owner acknowledgement are repaired from
        // numeric accounting only. No side messages, titles or prompts travel.
        for entry in accounting.attempts.values {
            guard let cost = entry.contribution else { continue }
            for ancestor in sideBudgetParents.reversed() { try await ancestor.importSideCharge(cost, side: id, parents: sideBudgetIDs) }
        }
        if let seed = SideBudgetRecovery.unkeyedCharge(spend:spend,accounting:accounting,side:id,parents:sideBudgetIDs) {
            for ancestor in sideBudgetParents.reversed() { try await ancestor.importSideCharge(seed, side:id, parents:sideBudgetIDs) }
        }
        try await refreshSideCharges()
    }

    func refreshSideCharges() async throws {
        for parent in sideBudgetParents.reversed() {
            let costs = await parent.sharedCharges(Array(accounting.attempts.keys))
            for cost in costs {
                let changed = try mirrorSharedCharge(cost)
                if changed, let delegation = cost["delegationId"].text, let plan = subagents.plans[delegation] {
                    try SubagentRecovery.mirrorCapturedCost(cost, plan:plan, directory:directory)
                }
            }
        }
    }
    func sharedCharges(_ attempts: [String]) -> [JSON] { attempts.compactMap { accounting.attempts[$0]?.contribution } }
    func committedSideCharges() -> [JSON] { accounting.sideCharges(owner:id) }
    @discardableResult func mirrorSharedCharge(_ cost: JSON) throws -> Bool {
        guard let attempt = cost["attemptId"].text, cost["reported"].int == 1 else { return false }
        if accounting.attempts[attempt] == nil {
            // The owner can have dispatched/settled while the child's first
            // mirror was lost. A loaded reader owns its writer, so repair it
            // here instead of skipping both the runtime and disk mirror.
            guard let origin = subagents.origin, cost["sourceSessionId"].text == id else { return false }
            guard origin.link.childSessionID == id,
                  origin.link.budgetOwnerSessionID == cost["budgetOwnerSessionId"].text,
                  origin.link.delegationID == cost["delegationId"].text else { throw AttemptAccounting.damaged() }
            if !cost["scope"].isNull {
                let scope = try JSONDecoder().decode(RequestScope.self,from:cost["scope"].data())
                guard scope.valid, scope.sourceSessionID == id, scope.delegation == origin.link,
                      scope.budgetOwnerSessionID == origin.link.budgetOwnerSessionID else { throw AttemptAccounting.damaged() }
            }
            var value = cost; value["accountingRevision"] = JSON(accounting.revision + 1)
            try appendAccounting(kind:JournalRecordKind.cost,data:value)
            stopFamilyAtLimit()
            return true
        }
        guard let entry = accounting.attempts[attempt],
              let previous = entry.contribution ?? entry.admission, previous["reported"].int != 1, cost["reported"].int == 1 else { return false }
        guard previous["sourceSessionId"] == cost["sourceSessionId"], previous["budgetOwnerSessionId"] == cost["budgetOwnerSessionId"],
              previous["delegationId"] == cost["delegationId"] else { throw AttemptAccounting.damaged() }
        var value = cost; value["accountingRevision"] = JSON(max(accounting.revision, entry.revision) + 1)
        if value["sideParents"].isNull, !previous["sideParents"].isNull { value["sideParents"] = previous["sideParents"] }
        if entry.admission != nil { try correctAccounting(value); return true }
        // A managed reader or a migrated side charge has a contribution-only
        // mirror, not admission authority. Validate that relationship separately.
        if let origin = subagents.origin {
            guard origin.link.childSessionID == cost["sourceSessionId"].text,
                  origin.link.budgetOwnerSessionID == cost["budgetOwnerSessionId"].text,
                  origin.link.delegationID == cost["delegationId"].text else { throw AttemptAccounting.damaged() }
        } else {
            guard let owner = cost["budgetOwnerSessionId"].text,
                  sideBudgetMembers[owner]?.contains(id) == true else { throw AttemptAccounting.damaged() }
        }
        try appendAccounting(kind:JournalRecordKind.costUpdate,data:value)
        stopFamilyAtLimit()
        return true
    }

    private func registerSideBudget(_ side: String, parents: [String]) throws {
        guard !closed, parents.contains(id), side != id else { throw AttemptAccounting.damaged() }
        sideBudgetMembers[side] = parents; familyBudgetEnabled = true
    }

    func enforceSharedCostLimit() async throws {
        for parent in sideBudgetParents.reversed() { try await parent.enforceCostLimit() }
        try enforceCostLimit()
    }

    func sharedRequestScope(_ scope: RequestScope) -> RequestScope {
        var scope = scope
        if !sideBudgetIDs.isEmpty { scope.sideParents = sideBudgetIDs }
        return scope
    }

    func admitSharedAttempt(scope: RequestScope, attemptID: String, allowsPausedQueue: Bool) async throws -> RequestPermit {
        try validateRequestOwner(scope)
        var recorded: [AgentSession] = []
        do {
            for parent in sideBudgetParents.reversed() {
                try await parent.recordSideAdmission(scope, attempt: attemptID, state: "admitted")
                recorded.append(parent)
            }
            return try admitAttempt(scope: scope, attemptID: attemptID, allowsPausedQueue: allowsPausedQueue)
        } catch {
            for parent in recorded { try? await parent.recordSideAdmission(scope, attempt: attemptID, state: "not_dispatched") }
            throw error
        }
    }

    func dispatchSharedAttempt(scope: RequestScope, attemptID: String, allowsPausedQueue: Bool) async throws {
        for parent in sideBudgetParents.reversed() { try await parent.recordSideAdmission(scope, attempt: attemptID, state: "dispatched") }
        try dispatchAttempt(scope: scope, attemptID: attemptID, allowsPausedQueue: allowsPausedQueue)
    }

    private func recordSideAdmission(_ scope: RequestScope, attempt: String, state: String) throws {
        guard scope.valid, sideBudgetMembers[scope.budgetOwnerSessionID] == scope.sideParents, !closed else { throw AttemptAccounting.damaged() }
        if state != "not_dispatched" { try enforceCostLimit() }
        var data: JSON = ["attemptId":JSON(attempt), "sourceSessionId":JSON(scope.sourceSessionID),
            "budgetOwnerSessionId":JSON(scope.budgetOwnerSessionID), "purpose":JSON(scope.purpose),
            "state":JSON(state), "scope":try subagentJSON(scope), "accountingRevision":JSON(accounting.revision + 1)]
        if let link = scope.delegation { data["delegationId"] = JSON(link.delegationID) }
        try appendAccounting(kind: JournalRecordKind.budgetAttempt, data: data)
        if state == "dispatched" { inFlightBudgetAttempts.insert(attempt) }
        else if state == "not_dispatched" { inFlightBudgetAttempts.remove(attempt); stopFamilyAtLimit() }
    }

    func settleSharedAttempt(_ settlement: AttemptSettlement) async throws -> JSON? {
        // The outermost owner commits first. A child mirror may be repaired
        // from its owner's admission after interruption, just like sub-agents.
        do {
            for parent in sideBudgetParents.reversed() { _ = try await parent.settleOwnedAttempt(settlement) }
            return try settleOwnedAttempt(settlement)
        } catch {
            // Keep numeric evidence in the source-side journal if an owner
            // write fails; cold-open recovery repairs the missing owner charge.
            _ = try? settleOwnedAttempt(settlement)
            throw error
        }
    }

    private func importSideCharge(_ original: JSON, side: String, parents: [String]) throws {
        guard sideBudgetMembers[side] == parents, let attempt = original["attemptId"].text else { throw AttemptAccounting.damaged() }
        var data = SideBudgetRecovery.charge(original, side: side, parents: parents)
        if data["sourceSessionId"].isNull { data["sourceSessionId"] = JSON(side) }
        if data["budgetOwnerSessionId"].isNull { data["budgetOwnerSessionId"] = JSON(side) }
        data["sideParents"] = .array(parents.map { JSON($0) })
        if accounting.attempts[attempt]?.contribution != nil { try mirrorSharedCharge(data); return }
        data["accountingRevision"] = JSON(accounting.revision + 1)
        try appendAccounting(kind: JournalRecordKind.cost, data: data)
    }
}
