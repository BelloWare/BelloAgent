import Foundation

extension SideBudgetRecovery {
    static func childPlans(owner: String, directory: URL) throws -> [String:SubagentPlan] {
        guard let file = try journalURL(owner,directory:directory) else { return [:] }
        let reader = try JournalRecordReader(file)
        var state = SubagentJournalState()
        while let row = try reader.next() { try state.consume(row,sessionID:owner) }
        return state.plans
    }

    /// A side can have lost its owner append while the child's fallback charge
    /// is durable. Recover numeric evidence before adopting the side, without
    /// opening its runtime, taking over a loaded writer or replaying any work.
    static func recoverChildren(_ state: SubagentJournalState, owner: String, directory: URL,
                                accounting: inout AttemptAccounting, spend: inout SessionSpend) throws {
        guard state.origin == nil else { throw SubagentRecovery.damaged() }
        for plan in state.plans.values {
            let link = plan.origin.link
            guard link.valid, link.budgetOwnerSessionID == owner else { throw SubagentRecovery.damaged() }
            let file = canonical(directory.appendingPathComponent(try identity(JSON(link.childSessionID)) + ".jsonl").path)
            guard within(file,canonical(directory.path)) else { throw SubagentRecovery.damaged() }
            if !FileManager.default.fileExists(atPath:file.path) {
                guard !accounting.attempts.values.contains(where: { $0.admission?["delegationId"].text == link.delegationID && $0.admission?["state"].text == "dispatched" }) else { throw SubagentRecovery.damaged() }
                continue
            }
            try SessionJournal.verifyManagedChild(url:file,id:link.childSessionID)
            let reader = try JournalRecordReader(file)
            var child = SubagentJournalState(), ledger = AttemptAccounting(), total = SessionSpend(), markerOnly = true
            while let row = try reader.next() {
                if row["type"].text != "session", !JournalRecordKind.isMarker(row["customType"].text) { markerOnly = false }
                try child.consume(row,sessionID:link.childSessionID)
                try ledger.consumeRecord(row,sessionID:link.childSessionID,spend:&total)
            }
            guard child.origin?.matchesAccepted(plan.origin) == true || child.origin == nil && markerOnly else { throw SubagentRecovery.damaged() }
            for (attempt, entry) in ledger.attempts {
                guard let cost = entry.contribution else { continue }
                guard let owned = accounting.attempts[attempt], let admission = owned.admission,
                      admission["state"].text == "dispatched" else { throw SubagentRecovery.damaged() }
                if let number = admission["scope"]["childTurn"].int {
                    guard let turn = state.family?.turns[AgentTurnTarget(childID:link.childSessionID,turn:number).id],
                          turn.parentExecutionID == admission["scope"]["parentExecutionID"].text else { throw SubagentRecovery.damaged() }
                }
                if let update = try FamilyCharge.merge(cost,into:owned,revision:accounting.revision,
                    child:.init(accepted:plan.origin,observed:child.origin),failure:SubagentRecovery.damaged()) {
                    try accounting.consume(kind:update.kind,data:update.data,spend:&spend)
                }
            }
        }
    }
}
