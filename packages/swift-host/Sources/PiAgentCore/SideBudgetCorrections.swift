import Foundation

extension SideBudgetRecovery {
    /// Deletion can follow a crash after an owner commit but before its mirror.
    /// Read the saved numeric ledger under its normal lock, without opening a
    /// runtime, executing work, or depending on the capture retention window.
    static func committedSideCharges(owner: String, directory: URL) throws -> [JSON] {
        guard !(try savedFamily(owner:owner,directory:directory)).isEmpty,
              let file = try journalURL(owner,directory:directory) else { return [] }
        let writer = try SessionJournal(url:file,id:owner,cwd:directory,binding:nil,create:false)
        let reader = try JournalRecordReader(file)
        var accounting = AttemptAccounting(), spend = SessionSpend()
        while let line = try reader.nextLine() {
            if line.isEmpty { continue }
            try accounting.consumeRecord(JSON.parse(line),sessionID:owner,spend:&spend)
        }
        withExtendedLifetime(writer) { }
        return accounting.sideCharges(owner:owner)
    }

    /// The owner has committed already. Before acknowledging reconciliation,
    /// make saved sides independently recoverable even if the owner is later
    /// deleted and the capture has expired. The host holds its runtime gate;
    /// live mirrors retain their own writers and are handled by the host.
    static func mirrorCapturedCosts(_ costs: [JSON], owner: String, directory: URL, loaded: Set<String>) throws {
        guard !costs.isEmpty else { return }
        let family = try savedFamily(owner:owner,directory:directory)
        for (origin, _) in family where !loaded.contains(origin.id) {
            let relevant = costs.filter { $0["budgetOwnerSessionId"].text == origin.id || $0["sideParents"].list.contains(JSON(origin.id)) }
            guard !relevant.isEmpty else { continue }
            // create:false verifies the identity/chain and takes the ordinary
            // exclusive journal lock. Never recreate discarded side content.
            let writer = try SessionJournal(url:origin.file,id:origin.id,cwd:directory,binding:nil,create:false)
            let reader = try JournalRecordReader(origin.file)
            var accounting = AttemptAccounting(), spend = SessionSpend(), children = SubagentJournalState()
            while let line = try reader.nextLine() {
                if line.isEmpty { continue }
                let record = try JSON.parse(line)
                try accounting.consumeRecord(record,sessionID:origin.id,spend:&spend)
                try children.consume(record,sessionID:origin.id)
            }
            guard children.origin == nil else { throw AttemptAccounting.damaged() }
            for cost in relevant {
                guard let attempt = cost["attemptId"].text, let entry = accounting.attempts[attempt] else { continue }
                guard let logicalOwner = cost["budgetOwnerSessionId"].text,
                      logicalOwner == origin.id || family.contains(where: { $0.origin.id == logicalOwner && $0.parents.contains(origin.id) }) ||
                        FamilyCharge.retainedSideCharge(cost,entry:entry,owner:origin.id) else { throw AttemptAccounting.damaged() }
                if let update = try FamilyCharge.merge(cost,into:entry,revision:accounting.revision,legacySession:origin.id) {
                    try accounting.consume(kind:update.kind,data:update.data,spend:&spend)
                    try writer.append(["type":"custom","customType":JSON(update.kind),"data":update.data],flush:true)
                }
                // A prior failed mirror is retried even when the side already
                // has the correction. Each child keeps its local revision.
                if logicalOwner == origin.id, let delegation = cost["delegationId"].text {
                    guard let plan = children.plans[delegation], plan.origin.link.childSessionID == cost["sourceSessionId"].text else { throw AttemptAccounting.damaged() }
                    if !loaded.contains(plan.origin.link.childSessionID) {
                        try SubagentRecovery.mirrorCapturedCost(cost,plan:plan,directory:directory)
                    }
                }
            }
        }
    }
}

extension AttemptAccounting {
    func sideCharges(owner: String) -> [JSON] {
        attempts.values.compactMap { entry in
            guard let cost = entry.contribution,
                  cost["sideParents"].list.contains(JSON(owner)) else { return nil }
            return cost
        }
    }
}
