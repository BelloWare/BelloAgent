import Foundation

extension AgentSession {
    /// Page registered identities, not capture totals. A cursor is independent
    /// of corrections removing earlier entries from the unresolved set.
    func budgetAttempts(after: String?) throws -> JSON {
        try requireIndependentSession()
        guard !closed else { throw AgentError("session_closed", "Session runtime is unloaded") }
        if runTask != nil || !requestPermits.isEmpty || !inFlightBudgetAttempts.isEmpty { return ["attemptIds":[], "next":.null] }
        let ids = accounting.attempts.keys.filter { id in
            let entry = accounting.attempts[id]!
            // A legacy side's admission contributes to the new family totals,
            // but its immutable scope may still authorize only the side to
            // reconcile captures. Do not widen that scope through adoption.
            let local = entry.admission?["budgetOwnerSessionId"].text == self.id || entry.admission?["scope"]["sideParents"].list.contains(JSON(self.id)) == true
            return local && id > (after ?? "") && entry.admission?["state"].text == "dispatched" && entry.contribution?["reported"].int != 1
        }.sorted()
        let page = Array(ids.prefix(128))
        return ["attemptIds":.array(page.map { JSON($0) }), "next":ids.count > page.count ? JSON(page.last!) : .null]
    }

    func reconcileCapturedAccounting(_ evidence: [JSON], mirrorChildren: Bool = true) throws -> JSON {
        try requireIndependentSession()
        guard !closed, runTask == nil, requestPermits.isEmpty, inFlightBudgetAttempts.isEmpty else { throw AgentError("session_busy", "Wait for settlement before reconciling captured costs") }
        guard evidence.count <= 128 else { throw AttemptAccounting.damaged() }
        do {
            for metadata in evidence {
                guard let attempt = metadata["attemptId"].text, let entry = accounting.attempts[attempt], let admission = entry.admission,
                      admission["state"].text == "dispatched",
                      let scope = try? JSONDecoder().decode(RequestScope.self, from: metadata["requestScope"].data()), scope.valid,
                      metadata["requestScope"] == admission["scope"], scope.budgetOwnerSessionID == id || scope.sideParents?.contains(id) == true,
                      metadata["sessionId"].text == scope.sourceSessionID, metadata["turnId"].text == scope.turnID,
                      metadata["purpose"].text == scope.purpose,
                      ["completed", "truncated", "failed", "cancelled", "interrupted"].contains(metadata["outcome"].text ?? "") else { throw AttemptAccounting.damaged() }
                if let link = scope.delegation, scope.budgetOwnerSessionID == id {
                    guard subagents.plans[link.delegationID]?.origin.link == link else { throw AttemptAccounting.damaged() }
                }
                let cost = metadata["gateway"]["cost"]
                // Missing/conflicting pricing is still unknown, never free.
                guard cost["status"].text == "reported", let usd = cost["usd"].double,
                      usd.isFinite, usd >= 0, usd <= 1_000_000_000_000 else { continue }
                let candidate: JSON
                if let prior = entry.contribution, prior["reported"].int == 1 {
                    guard prior["usd"].double == usd else { throw AttemptAccounting.damaged() }
                    candidate = prior
                } else {
                    var observation = RequestObservation(sessionID: scope.sourceSessionID, turnID: scope.turnID, attemptID: attempt, purpose: scope.purpose, fingerprint: "", profile: profile)
                    observation.monitoring = metadata
                    for key in ["input", "output", "cacheRead", "cacheWrite", "reasoning", "total"] {
                        let value = metadata["usage"][key == "input" ? "inputIncludingCache" : key]
                        if let number = value.double, number.isFinite, number >= 0 { observation.fields[key] = value; observation.fieldStatus[key] = "reported" }
                    }
                    var value = self.contribution(observation, owner: scope.budgetOwnerSessionID, delegation: scope.delegation?.delegationID)
                    if let parents = scope.sideParents { value["sideParents"] = .array(parents.map { JSON($0) }); value["scope"] = try subagentJSON(scope) }
                    candidate = value
                }
                if let update = try FamilyCharge.merge(candidate,into:entry,revision:accounting.revision) {
                    try appendAccounting(kind:update.kind,data:update.data)
                    stopFamilyAtLimit()
                }
                if mirrorChildren, let link = scope.delegation, let plan = subagents.plans[link.delegationID],
                   let contribution = accounting.attempts[attempt]?.contribution {
                    try SubagentRecovery.mirrorCapturedCost(contribution,plan:plan,directory:directory)
                }
            }
            return costSnapshot
        } catch { failFamilyAccounting(error); throw error }
    }
}

extension SubagentRecovery {
    /// Owner commits first. A failed mirror leaves that charge durable, and
    /// normal reopen recovery repairs the mirror before any continuation.
    static func mirrorCapturedCost(_ cost: JSON, plan: SubagentPlan, directory: URL) throws {
        _ = try mirrorCapturedCosts([cost],plan:plan,directory:directory)
    }

    /// One replay per child, even when a correction batch has many attempts.
    /// An empty batch is a native numeric read of the same validated ledger.
    static func mirrorCapturedCosts(_ costs: [JSON], plan: SubagentPlan, directory: URL) throws -> JSON {
        let id = try identity(JSON(plan.origin.link.childSessionID))
        let url = canonical(directory.appendingPathComponent(id + ".jsonl").path)
        guard within(url, canonical(directory.path)) else { throw damaged() }
        try SessionJournal.verifyManagedChild(url: url, id: id)
        let writer = try SessionJournal(url: url, id: id, cwd: directory, binding: nil, create: false)
        var child = SubagentJournalState(), accounting = AttemptAccounting(), spend = SessionSpend()
        let reader = try JournalRecordReader(url)
        while let line = try reader.nextLine() {
            if line.isEmpty { continue }
            let record = try JSON.parse(line)
            try child.consume(record, sessionID: id)
            if let kind = record["customType"].text { try accounting.consume(kind: kind, data: record["data"], spend: &spend) }
        }
        guard let origin = child.origin, origin.matchesAccepted(plan.origin) else { throw damaged() }
        for cost in costs {
            guard let attempt = cost["attemptId"].text else { throw damaged() }
            if let update = try FamilyCharge.merge(cost,into:accounting.attempts[attempt],revision:accounting.revision,
                child:.init(accepted:plan.origin,observed:origin),failure:damaged()) {
                try writer.append(["type":"custom","customType":JSON(update.kind),"data":update.data],flush:true)
                try accounting.consume(kind:update.kind,data:update.data,spend:&spend)
            }
        }
        return ["spentUSD":JSON(spend.usd),"reportedRequests":JSON(spend.reported),
                "unreportedRequests":JSON(spend.unreported),"accountingRevision":JSON(accounting.revision)]
    }
}
