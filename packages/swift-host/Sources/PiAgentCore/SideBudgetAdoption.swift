import Foundation

extension SideBudgetRecovery {
    struct AccountingRecord {
        var kind: String
        var data: JSON
    }

    /// Preserve unresolved admissions, including proof of non-dispatch. A
    /// synthetic terminal cost would prevent a later admission transition.
    static func record(_ entry: AttemptAccounting.Entry, side: String, parents: [String]) -> AccountingRecord? {
        if let cost = entry.contribution { return AccountingRecord(kind:JournalRecordKind.cost,data:charge(cost,side:side,parents:parents)) }
        guard let admission = entry.admission else { return nil }
        let fields: Set<String> = ["attemptId","sourceSessionId","budgetOwnerSessionId","delegationId","purpose","state","scope"]
        return AccountingRecord(kind:JournalRecordKind.budgetAttempt,data:.object(admission.map.filter { fields.contains($0.key) }))
    }

    /// Cold discovery and live binding have the same monotonic merge. The
    /// existing owner's terminal evidence wins over a stale side admission.
    /// Derived ancestry never changes a physical request's identity/scope.
    static func adoption(_ incoming: AccountingRecord, accounting: AttemptAccounting) throws -> AccountingRecord? {
        guard let attempt = incoming.data["attemptId"].text else { throw AttemptAccounting.damaged() }
        guard let entry = accounting.attempts[attempt], let previous = entry.contribution ?? entry.admission else { return incoming }
        for key in ["sourceSessionId","budgetOwnerSessionId","delegationId"] {
            guard previous[key] == incoming.data[key] else { throw AttemptAccounting.damaged() }
        }
        var record = incoming
        if record.kind == JournalRecordKind.budgetAttempt {
            guard entry.contribution == nil, let admission = entry.admission else { return nil }
            guard admission["scope"] == record.data["scope"], admission["purpose"] == record.data["purpose"] else { throw AttemptAccounting.damaged() }
            let state = record.data["state"]
            guard admission["state"] != state, admission["state"].text != "not_dispatched", state.text != "admitted" else { return nil }
            record.data = admission; record.data["state"] = state
        } else if let prior = entry.contribution {
            guard prior["reported"].int != 1, record.data["reported"].int == 1 else { return nil }
            record.kind = JournalRecordKind.costUpdate
        }
        return record
    }
}
