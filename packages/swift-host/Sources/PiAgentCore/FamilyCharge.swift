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
                      failure: AgentError = AttemptAccounting.damaged()) throws -> Update? {
        var value = AttemptAccounting.validatedCost(evidence)
        guard let attempt = value["attemptId"].text, !attempt.isEmpty else { throw failure }
        let authority = admission ?? entry?.admission
        var prior = entry?.contribution
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
                value = old // Repeated unknown evidence cannot discard usage.
            }
            // Preserve local ancestry and avoid rewriting already equal mirrors.
            if entry?.contribution?["scope"] == value["scope"],
               old["reported"].int == 1 || value["reported"].int != 1 { return nil }
        }
        if value["sideParents"].isNull, let parents = entry?.contribution?["sideParents"], !parents.isNull { value["sideParents"] = parents }
        value["accountingRevision"] = JSON(max(revision,entry?.revision ?? 0) + 1)
        return Update(kind:entry?.contribution == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate,data:value)
    }
}
