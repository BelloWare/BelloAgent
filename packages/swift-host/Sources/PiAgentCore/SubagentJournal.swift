import Foundation

struct SubagentOrigin: Codable, Sendable, Equatable {
    var link: SubagentLink
    var description: String
    var model: SubagentModelGrant
    var tools: [String]
    var readOnly: Bool
    var resourceRevision: String
    var mcpPolicy: JSON? = nil
}

struct SubagentPlan: Codable, Sendable, Equatable {
    var origin: SubagentOrigin
    var task: String
    var resultMessageID: String
    var adoptionSeed: JSON? = nil
}

func subagentJSON<T: Encodable>(_ value: T) throws -> JSON { try JSON.parse(JSONEncoder().encode(value)) }

/// Replayed with the messages, including through compaction and checkpoints.
/// A copied parent record is historical provenance, never transferred authority.
struct SubagentJournalState: Codable, Sendable, Equatable {
    var plans: [String: SubagentPlan] = [:]
    var callOrder: [String]? = nil
    var outcomes: [String: SubagentStatus]? = nil
    var origin: SubagentOrigin?
    var status: SubagentStatus?
    var terminal: JSON?

    mutating func consume(_ record: JSON, sessionID: String) throws {
        if record["type"].text == "message", record["message"]["role"].text == "toolResult" {
            let metadata = record["message"]["nativeSubagent"]
            if let key = metadata["delegationId"].text, let plan = plans[key],
               metadata["sessionId"].text == plan.origin.link.childSessionID,
               let status = metadata["status"].text.flatMap(SubagentStatus.init(rawValue:)), status.terminal {
                if outcomes == nil { outcomes = [:] }; outcomes?[key] = status
            }
        }
        let data = record["data"]
        switch record["customType"].text {
        case JournalRecordKind.subagentCall:
            let plan = try JSONDecoder().decode(SubagentPlan.self, from: data.data())
            guard plan.origin.link.valid else { throw damaged() }
            guard plan.origin.link.call.parentSessionID == sessionID else { return }
            let key = plan.origin.link.delegationID
            guard plans[key] == nil || plans[key] == plan,
                  !plans.values.contains(where: { $0.origin.link.call == plan.origin.link.call && $0 != plan }) else { throw damaged() }
            if plans[key] == nil { if callOrder == nil { callOrder = plans.keys.sorted() }; callOrder?.append(key) }
            plans[key] = plan
        case JournalRecordKind.subagentOrigin:
            let value = try JSONDecoder().decode(SubagentOrigin.self, from: data.data())
            guard value.link.valid, value.link.childSessionID == sessionID,
                  origin == nil || origin == value else { throw damaged() }
            origin = value
        case JournalRecordKind.subagentState, JournalRecordKind.subagentTerminal:
            guard let origin, data["delegationID"].text == origin.link.delegationID,
                  let next = data["status"].text.flatMap(SubagentStatus.init(rawValue:)) else { throw damaged() }
            if record["customType"].text == JournalRecordKind.subagentTerminal {
                guard next.terminal, terminal == nil || terminal == data else { throw damaged() }
                terminal = data
            } else if terminal != nil { throw damaged() }
            status = next
        default: break
        }
    }

    mutating func retarget(_ sessionID: String) {
        plans = plans.filter { $0.value.origin.link.call.parentSessionID == sessionID }
        callOrder = callOrder?.filter { plans[$0] != nil }; outcomes = outcomes?.filter { plans[$0.key] != nil }
        if origin?.link.childSessionID != sessionID { origin = nil; status = nil; terminal = nil }
    }

    private func damaged() -> AgentError { AgentError("session_damaged", "Sub-agent journal identity or outcome is inconsistent") }
}
