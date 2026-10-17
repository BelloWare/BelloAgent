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
            try await ancestor.registerSideBudget(self, id: id, parents: sideBudgetIDs)
        }
        // Old saved sides and a lost owner acknowledgement are repaired from
        // numeric accounting only. No side messages, titles or prompts travel.
        for entry in accounting.attempts.values {
            guard let record = SideBudgetRecovery.record(entry,side:id,parents:sideBudgetIDs) else { continue }
            for ancestor in sideBudgetParents.reversed() { try await ancestor.importSideRecord(record, side:id, parents:sideBudgetIDs) }
        }
        if let seed = SideBudgetRecovery.unkeyedCharge(spend:spend,accounting:accounting,side:id,parents:sideBudgetIDs) {
            let record = SideBudgetRecovery.AccountingRecord(kind:JournalRecordKind.cost,data:seed)
            for ancestor in sideBudgetParents.reversed() { try await ancestor.importSideRecord(record, side:id, parents:sideBudgetIDs) }
        }
        try await refreshSideCharges()
        // Binding can beat an already issued callback. Take that durable
        // intent before repairing membership or acknowledging the fan-out.
        var intents: [(AgentSession,SidePausePublication)] = []
        for ancestor in sideBudgetParents {
            if let generation = await ancestor.pendingSidePause(id) {
                receiveSidePause(Self.costHoldError,generation:generation); intents.append((ancestor,generation))
            }
        }
        // The root's list of paused sides follows each side's own durable
        // pause: a crash between the two saves is repaired here.
        try persistState(durable:true)
        if let root = sideBudgetParents.last {
            // Cold recovery also serves orphaned sides. Once ancestry is
            // bound, move any recovered descendant membership to the root,
            // where each descendant's Resume will retire it.
            let members = costPausedMembers, publication = SidePausePublication(side:pauseGeneration,root:root.pauseGeneration)
            for member in members { guard await root.notePausedMember(member,publication:publication,repair:true) else { return } }
            guard publication.isCurrent else { return }
            if !members.isEmpty {
                let previous = costPausedMembers
                costPausedMembers.removeAll { members.contains($0) }
                do { try persistState(durable:true) }
                catch { costPausedMembers = previous; throw error }
            }
            if costPaused { guard await publishSidePause(publication,repair:true) else { return } }
            else { await root.forgetPausedMember(id,generation:pauseGeneration,destination:root.pauseGeneration) }
        }
        for (ancestor,generation) in intents { await ancestor.acknowledgeSidePause(id,generation:generation) }
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
    @discardableResult func mirrorSharedCharge(_ cost: JSON, acceptedOrigin: SubagentOrigin? = nil) throws -> Bool {
        guard let attempt = cost["attemptId"].text else { return false }
        let entry = accounting.attempts[attempt]
        let child: FamilyCharge.Child?
        if let origin = subagents.origin {
            if entry == nil, cost["sourceSessionId"].text != id { return false }
            child = .init(accepted:acceptedOrigin ?? origin,observed:origin)
        } else {
            guard let entry else { return false }
            if entry.admission == nil {
                guard let owner = cost["budgetOwnerSessionId"].text,
                      owner == id || sideBudgetMembers[owner]?.contains(id) == true ||
                        FamilyCharge.retainedSideCharge(cost,entry:entry,owner:id) else { throw AttemptAccounting.damaged() }
            }
            child = nil
        }
        guard let update = try FamilyCharge.merge(cost,into:entry,revision:accounting.revision,child:child,
            legacySession:isSideChat ? id : nil) else { return false }
        try appendAccounting(kind:update.kind,data:update.data)
        stopFamilyAtLimit()
        return true
    }

    private func registerSideBudget(_ runtime: AgentSession, id side: String, parents: [String]) throws {
        guard !closed, parents.contains(id), side != id else { throw AttemptAccounting.damaged() }
        if !familyBudgetEnabled { accounting.restoreUsageCoverage(spend:spend) }
        sideBudgetMembers[side] = parents; familyBudgetEnabled = true
        sideBudgetPauseClocks[side] = runtime.costPauseClock
        sideBudgetStops[side] = { [weak self, weak runtime] reason, generation in
            guard let self, let runtime else { return }
            // The family's pause is latched: a limit raised since does not
            // undo it (only Resume does). A Resume accepted since the pause
            // was issued retires it.
            let publication = await runtime.receiveSidePause(reason,generation:generation)
            guard generation.isCurrent, await runtime.publishSidePause(publication,repair:true) else { return }
            await self.acknowledgeSidePause(side,generation:generation)
        }
    }

    /// A failed pause save must not be acknowledged merely because its
    /// in-memory flag is set. Also confirms idle/descendant-only fan-out.
    func publishSidePause(_ publication: SidePausePublication, repair: Bool = false) async -> Bool {
        if !repair { await beforeSidePausePublication?() }
        guard publication.isCurrent, !closed, ephemeral || journal != nil else { return false }
        do { guard try publication.apply({ try persistState(durable:true) }) != nil else { return false } }
        catch { failFamilyAccounting(error); return false }
        guard costPaused, let root = sideBudgetParents.last else { return true }
        let confirmed = await root.notePausedMember(id,publication:publication,repair:repair)
        // Close advances the issuer before retiring its root membership.
        return confirmed && publication.isCurrent && !closed
    }

    func pendingSidePause(_ side: String) -> SidePausePublication? {
        costPendingSidePauses.contains(side) ? SidePausePublication(side:pauseGeneration,root:sideBudgetParents.last?.pauseGeneration ?? pauseGeneration) : nil
    }

    func enforceSharedCostLimit() async throws {
        for parent in sideBudgetParents.reversed() { try await parent.enforceCostLimit() }
        try enforceCostLimit()
    }

    func enforceToolBudget() async throws {
        try await enforceCostHold()
        guard familyBudgetEnabled || isSubagent else { return }
        if let budgetOwner { try await budgetOwner.enforceSharedCostLimit() }
        else { try await enforceSharedCostLimit() }
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
        // A failed append must not skip another ancestor's settlement cleanup
        // or its terminal evidence. Visit every writer and report the first
        // error; cold recovery can repair failed mirrors from surviving ones.
        var firstError: Error?, result: JSON?
        for parent in sideBudgetParents.reversed() {
            do { _ = try await parent.settleOwnedAttempt(settlement) }
            catch { if firstError == nil { firstError = error } }
        }
        do { result = try settleOwnedAttempt(settlement) }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
        return result
    }

    private func importSideRecord(_ incoming: SideBudgetRecovery.AccountingRecord, side: String, parents: [String]) throws {
        guard sideBudgetMembers[side] == parents else { throw AttemptAccounting.damaged() }
        guard var record = try SideBudgetRecovery.adoption(incoming,accounting:accounting) else { return }
        record.data["accountingRevision"] = JSON(accounting.revision + 1)
        try appendAccounting(kind:record.kind,data:record.data)
        stopFamilyAtLimit()
    }
}
