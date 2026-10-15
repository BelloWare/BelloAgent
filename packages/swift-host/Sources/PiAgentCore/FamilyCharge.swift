import Foundation

/// One compatibility/merge rule for durable physical charges, whether evidence
/// arrives through recovery, adoption, a live mirror or a failed settlement.
enum FamilyCharge {
    struct Update {
        var kind: String
        var data: JSON
    }
    struct Child {
        var accepted: SubagentOrigin
        var observed: SubagentOrigin?
    }

    static func merge(_ evidence: JSON, into entry: AttemptAccounting.Entry?, revision: Int,
                      admission: JSON? = nil, scope: JSON = .null, child: Child? = nil,
                      legacySession: String? = nil,
                      failure: AgentError = AttemptAccounting.damaged()) throws -> Update? {
        // countAttempt (through 0.1.127) omitted both physical identities.
        // Only the validated physical side origin can supply those omissions;
        // a delegated charge or a conflicting recorded identity never can.
        func identities(_ data: JSON) throws -> JSON {
            let keys = ["sourceSessionId","budgetOwnerSessionId"]
            guard keys.contains(where: { data[$0].isNull }), let legacySession else { return data }
            guard data["delegationId"].isNull else { throw failure }
            var normalized = data
            for key in keys {
                guard data[key].isNull || data[key].text == legacySession else { throw failure }
                normalized[key] = JSON(legacySession)
            }
            return normalized
        }
        var value = try identities(AttemptAccounting.validatedCost(evidence))
        guard let attempt = value["attemptId"].text, !attempt.isEmpty else { throw failure }
        let authority = admission ?? entry?.admission
        var prior = try entry?.contribution.map(identities)
        for previous in [authority,prior].compactMap({ $0 }) {
            for key in ["attemptId","sourceSessionId","budgetOwnerSessionId","delegationId"] {
                guard previous[key] == value[key] else { throw failure }
            }
        }
        if let authority { guard authority["state"].text != "not_dispatched" else { throw failure } }
        if let child {
            let link = child.accepted.link
            guard child.observed?.matchesAccepted(child.accepted) == true, link.valid,
                  value["sourceSessionId"].text == link.childSessionID,
                  value["budgetOwnerSessionId"].text == link.budgetOwnerSessionID,
                  value["delegationId"].text == link.delegationID else { throw failure }
        }
        // Scope was absent from old cost mirrors. An existing immutable scope
        // (especially admission authority) can fill that absence, never replace
        // a conflicting scope. Derived sideParents outside scope are different.
        let scopes = [scope,authority?["scope"] ?? .null,prior?["scope"] ?? .null,value["scope"]].filter { !$0.isNull }
        if let immutable = scopes.first {
            guard scopes.allSatisfy({ $0 == immutable }),
                  let decoded = try? JSONDecoder().decode(RequestScope.self,from:immutable.data()), decoded.valid,
                  decoded.sourceSessionID == value["sourceSessionId"].text,
                  decoded.budgetOwnerSessionID == value["budgetOwnerSessionId"].text,
                  decoded.delegation?.delegationID == value["delegationId"].text,
                  value["purpose"].isNull || decoded.purpose == value["purpose"].text else { throw failure }
            if let child { guard decoded.delegation == child.accepted.link else { throw failure } }
            value["scope"] = immutable
            if prior != nil { prior?["scope"] = immutable }
        }
        if let old = prior {
            if old["reported"].int == 1 {
                guard value["reported"].int == 1 else { return nil }
                let derived: Set<String> = ["accountingRevision","sideParents"]
                guard old.removing(derived) == value.removing(derived) else { throw failure }
            } else if value["reported"].int != 1 {
                // Unknown pricing does not make reported tokens unknown. Fill
                // missing coverage in either direction, but never replace a
                // reported terminal token value with a conflicting one.
                var merged = old
                for key in ["input","output","cacheRead","cacheWrite","reasoning","total"] {
                    let before = old["usage"][key].double, after = value["usage"][key].double
                    if let before, before.isFinite, before >= 0 {
                        if let after, after.isFinite, after >= 0 { guard before == after else { throw failure } }
                        merged["usage"][key] = old["usage"][key]
                        if !old["usageStatus"][key].isNull { merged["usageStatus"][key] = old["usageStatus"][key] }
                    } else if let after, after.isFinite, after >= 0 {
                        merged["usage"][key] = value["usage"][key]
                        if !value["usageStatus"][key].isNull { merged["usageStatus"][key] = value["usageStatus"][key] }
                    }
                }
                value = merged
            }
            // Preserve local ancestry and avoid rewriting already equal mirrors.
            if entry?.contribution?["scope"] == value["scope"],
               old.removing(["accountingRevision","sideParents"]) == value.removing(["accountingRevision","sideParents"]) { return nil }
        }
        if value["sideParents"].isNull, let parents = entry?.contribution?["sideParents"], !parents.isNull { value["sideParents"] = parents }
        value["accountingRevision"] = JSON(max(revision,entry?.revision ?? 0) + 1)
        return Update(kind:entry?.contribution == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate,data:value)
    }
}
