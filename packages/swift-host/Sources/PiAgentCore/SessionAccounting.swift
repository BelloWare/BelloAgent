import Foundation

extension AgentSession {
    /// Commit before publishing: a failed write never leaves a usable total
    /// that exists only in memory. The family stays closed to new admissions.
    @discardableResult func appendAccounting(kind: String, data: JSON) throws -> Bool {
        var next = accounting, total = spend
        do {
            guard try next.consume(kind: kind, data: data, spend: &total) else { return false }
            if !ephemeral {
                guard let journal else { throw AgentError("accounting_unavailable", "The accounting journal is closed") }
                try journal.append(["type":"custom", "customType":JSON(kind), "data":data], flush: true)
            }
            accounting = next; spend = total; spendTracked = true
            event("cost.spend", costSnapshot)
            return true
        } catch {
            let failure = AgentError("accounting_persistence", "Attempt accounting could not be saved; no further family requests may be sent")
            accountingFailure = failure
            throw failure
        }
    }

    func contribution(_ observation: RequestObservation, owner: String, delegation: String? = nil) -> JSON {
        let cost = observation.monitoring["gateway"]["cost"]
        var value: JSON = ["attemptId":JSON(observation.attemptID), "sourceSessionId":JSON(observation.sessionID),
                           "budgetOwnerSessionId":JSON(owner), "purpose":JSON(observation.purpose),
                           "outcome":observation.monitoring["outcome"], "usage":observation.fields, "usageStatus":observation.fieldStatus,
                           "accountingRevision":JSON(accounting.revision + 1)]
        if let delegation { value["delegationId"] = JSON(delegation) }
        if cost["status"].text == "reported", let amount = cost["usd"].double, amount.isFinite, amount >= 0, amount <= 1_000_000_000_000 {
            value["usd"] = JSON(amount); value["reported"] = 1; value["unreported"] = 0
        } else {
            value["usd"] = 0; value["reported"] = 0; value["unreported"] = 1
            value["status"] = JSON(cost["status"].text ?? "unreported")
        }
        return value
    }

    /// Corrections only replace registered physical attempts, never seeds or
    /// historical request-log totals. Callers must supply validated evidence.
    func correctAccounting(_ data: JSON) throws {
        guard let id = data["attemptId"].text, let entry = accounting.attempts[id], entry.admission != nil else { throw AttemptAccounting.damaged() }
        do {
            _ = try appendAccounting(kind: JournalRecordKind.costUpdate, data: data)
            stopFamilyAtLimit()
        } catch { failFamilyAccounting(error); throw error }
    }

    var familyUsage: JSON {
        var result = JSON.object(accounting.usageTotals.mapValues { JSON($0) })
        result["reportedFields"] = .object(accounting.usageReported.mapValues { JSON($0) })
        result["unknownRequests"] = JSON(accounting.usageUnknownRequests)
        return result
    }
}
