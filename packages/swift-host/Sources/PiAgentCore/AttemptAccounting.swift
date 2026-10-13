import Foundation

/// The parent's journal is the ledger. This index is derived from its records,
/// never trimmed, and carried by checkpoints. Child mirrors use the same index.
struct AttemptAccounting: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var admission: JSON?
        var contribution: JSON?
        var revision = 0
        var effective: JSON {
            if let contribution { return contribution }
            return admission != nil && admission?["state"].text != "not_dispatched" ? ["usd":0,"unreported":1] : [:]
        }
    }
    var attempts: [String: Entry] = [:]
    var revision = 0
    var usageTotals: [String: Double] = [:]
    var usageReported: [String: Int] = [:]
    var usageUnknownRequests = 0

    /// Returns false for repeated evidence. Unknown admitted work counts as
    /// unknown until a terminal cost or proof of non-dispatch replaces it.
    @discardableResult mutating func consume(kind: String, data: JSON, spend: inout SessionSpend) throws -> Bool {
        guard [JournalRecordKind.budgetAttempt, JournalRecordKind.cost, JournalRecordKind.costUpdate].contains(kind) else { return false }
        if kind == JournalRecordKind.cost, data[SessionSpend.resetKey].flag == true {
            attempts = [:]; revision = 0; spend = SessionSpend()
            usageTotals = [:]; usageReported = [:]; usageUnknownRequests = 0
        }
        guard let id = data["attemptId"].text, !id.isEmpty else {
            guard kind == JournalRecordKind.cost else { throw Self.damaged() }
            spend.add(record: data); return true // Existing seed/carried records.
        }
        var entry = attempts[id] ?? Entry()
        let previousEntry = entry
        let before = entry.effective
        if kind == JournalRecordKind.budgetAttempt {
            guard ["admitted", "dispatched", "not_dispatched"].contains(data["state"].text ?? ""),
                  data["sourceSessionId"].text?.isEmpty == false, data["budgetOwnerSessionId"].text?.isEmpty == false else { throw Self.damaged() }
            if let old = entry.admission {
                guard old.removing(["state", "accountingRevision"]) == data.removing(["state", "accountingRevision"]) else { throw Self.damaged() }
                if old["state"] == data["state"] { return false }
                guard old["state"].text == "admitted" || old["state"].text == "dispatched" && data["state"].text == "not_dispatched", entry.contribution == nil else { throw Self.damaged() }
            }
            entry.admission = data
        } else {
            let value = Self.validatedCost(data)
            let incoming = data["accountingRevision"].int ?? 0
            if let old = entry.contribution {
                if old.removing(["accountingRevision"]) == value.removing(["accountingRevision"]) { return false }
                // Old helpers emitted no revisions. A duplicated initial
                // charge is not a correction and must never add spend twice.
                guard kind == JournalRecordKind.costUpdate else { throw Self.damaged() }
                if incoming < entry.revision { return false }
                guard incoming > entry.revision else { throw Self.damaged() }
            } else if kind == JournalRecordKind.costUpdate, entry.admission == nil { throw Self.damaged() }
            if let admission = entry.admission {
                guard admission["state"].text != "not_dispatched",
                      data["sourceSessionId"] == admission["sourceSessionId"],
                      data["budgetOwnerSessionId"] == admission["budgetOwnerSessionId"],
                      data["delegationId"] == admission["delegationId"] else { throw Self.damaged() }
            }
            entry.contribution = value; entry.revision = incoming
        }
        var previous = SessionSpend(); previous.add(record: before)
        spend.usd = max(0, spend.usd - previous.usd); spend.reported -= previous.reported; spend.unreported -= previous.unreported
        spend.add(record: entry.effective)
        countUsage(previousEntry, sign: -1); countUsage(entry, sign: 1)
        attempts[id] = entry; revision = max(revision, data["accountingRevision"].int ?? 0)
        return true
    }

    private mutating func countUsage(_ entry: Entry, sign: Int) {
        guard entry.contribution != nil || entry.admission != nil && entry.admission?["state"].text != "not_dispatched" else { return }
        guard let data = entry.contribution, !data["usage"].map.isEmpty else { usageUnknownRequests += sign; return }
        for key in ["input", "output", "cacheRead", "cacheWrite", "reasoning", "total"] {
            if let value = data["usage"][key].double, value.isFinite, value >= 0 {
                usageTotals[key, default: 0] += Double(sign) * value
                usageReported[key, default: 0] += sign
                if usageReported[key] == 0 { usageTotals[key] = nil; usageReported[key] = nil }
            }
        }
    }

    static func validatedCost(_ data: JSON) -> JSON {
        var value = data
        if data["reported"].int == 1, let amount = data["usd"].double, amount.isFinite, amount >= 0, amount <= 1_000_000_000_000,
           (data["unreported"].int ?? 0) == 0 {
            value["reported"] = 1; value["unreported"] = 0
        } else {
            value["usd"] = 0; value["reported"] = 0; value["unreported"] = 1
        }
        return value
    }
    static func damaged() -> AgentError { AgentError("accounting_damaged", "Attempt accounting is inconsistent; no further family requests may be sent") }
}
