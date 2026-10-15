import Foundation

extension SideBudgetRecovery {
    /// Follow only surviving, validated side origins. A missing parent ends
    /// ownership; fork provenance and recovered independent copies do not
    /// authorize accounting writes. Discovery of unrelated files stays isolated.
    static func ancestors(of id: String, directory: URL) throws -> [String] {
        var result: [String] = [], next = id, seen: Set<String> = [id]
        while let file = try journalURL(next,directory:directory) {
            // Unrelated/damaged history can still be explicitly deleted. As
            // with discovery, only an established side origin authorizes an
            // upward write; its ledger is read strictly by deletionRecords.
            guard file.lastPathComponent == "side_" + next + ".jsonl",
                  let origin = try? readOrigin(file) else { break }
            guard origin.id == next, seen.insert(origin.parent).inserted, result.count < 128 else { throw AttemptAccounting.damaged() }
            guard try parentExists(origin.parent,directory:directory) else { break }
            result.append(origin.parent); next = origin.parent
        }
        return result
    }

    /// Before a side's sole surviving evidence can be removed, adopt its own
    /// ledger and descendants through the same merge used by cold opening.
    /// Numeric records only; no conversation or capture content is copied.
    static func deletionRecords(side: String, ancestor: String, directory: URL) throws -> [AccountingRecord] {
        let family = try savedFamily(owner:ancestor,directory:directory).filter {
            $0.origin.id == side || $0.parents.contains(side)
        }
        guard family.contains(where: { $0.origin.id == side }) else { throw AttemptAccounting.damaged() }
        return try charges(owner:ancestor,directory:directory,family:family)
    }

    static func importDeletionRecords(_ records: [AccountingRecord], owner: String, directory: URL) throws {
        guard let file = try journalURL(owner,directory:directory) else { throw AttemptAccounting.damaged() }
        let writer = try SessionJournal(url:file,id:owner,cwd:directory,binding:nil,create:false)
        let reader = try JournalRecordReader(file)
        var accounting = AttemptAccounting(), spend = SessionSpend(), children = SubagentJournalState()
        while let row = try reader.next() {
            try accounting.consumeRecord(row,sessionID:owner,spend:&spend)
            try children.consume(row,sessionID:owner)
        }
        guard children.origin == nil else { throw AttemptAccounting.damaged() }
        for incoming in records {
            guard var update = try adoption(incoming,accounting:accounting) else { continue }
            update.data["accountingRevision"] = JSON(accounting.revision + 1)
            try accounting.consume(kind:update.kind,data:update.data,spend:&spend)
            try writer.append(["type":"custom","customType":JSON(update.kind),"data":AttemptAccounting.journalData(update.data)],flush:true)
        }
    }
}

extension AgentSession {
    /// The host's runtime gate validates persisted ancestry and owns discovery.
    /// A loaded ancestor keeps its writer and publishes repaired spend normally.
    func importDeletionRecords(_ records: [SideBudgetRecovery.AccountingRecord]) throws {
        guard !isSubagent, !closed else { throw AttemptAccounting.damaged() }
        for incoming in records {
            guard var update = try SideBudgetRecovery.adoption(incoming,accounting:accounting) else { continue }
            update.data["accountingRevision"] = JSON(accounting.revision + 1)
            try appendAccounting(kind:update.kind,data:update.data)
            familyBudgetEnabled = true
        }
        stopFamilyAtLimit()
    }
}
