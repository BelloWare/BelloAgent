import Foundation

/// Normative schemas from subagents-steering.md. Validation is strict, without coercion.
enum SubagentSteeringContract {
    static let delegationPolicy = "Start sub-agents only when the user explicitly asks for sub-agents/agents, delegation, or parallel work; otherwise do the work yourself, even for large tasks."
    static let parentNames = ["subagent_start", "subagent_send", "subagent_wait", "subagent_status", "subagent_stop"]
    static let names = Set(parentNames + ["subagent_report"])
    static func definitions(child: Bool, models: [SubagentModelGrant] = [], profile: Profile? = nil, connectionSupportsReasoning: Bool,
                            children: [String:SubagentModelGrant] = [:]) -> [ToolDefinition] {
        (child ? ["subagent_report"] : parentNames).map { name in
            var schema = schemas[name]!
            if name == "subagent_start", !models.isEmpty { schema["properties"]["model"]["enum"] = .array(models.map { JSON($0.model) }) }
            if let profile, name == "subagent_start" {
                var inherited = SubagentModelGrant.inherited(profile)
                inherited.reasoning = models.first { $0.model == profile.model }?.reasoning
                let inheritedLevels = inherited.supportedEfforts(parent:profile,connectionSupportsReasoning:connectionSupportsReasoning)
                let groups = Dictionary(grouping:models) { $0.supportedEfforts(parent:profile,connectionSupportsReasoning:connectionSupportsReasoning) }
                // Most connections use one capability set. Keep their schema
                // compact; only differing models need conditional branches.
                if groups.keys.allSatisfy({ $0 == inheritedLevels }) {
                    schema = effortVariant(schema,levels:inheritedLevels)
                    return ToolDefinition(name, descriptions[name]!, schema)
                }
                var variants = [effortVariant(schema,levels:inheritedLevels)]
                variants[0]["properties"] = variants[0]["properties"].removing(["model"])
                for levels in groups.keys.sorted(by: { $0.joined() < $1.joined() }) {
                    var variant = effortVariant(schema,levels:levels)
                    variant["properties"]["model"]["enum"] = .array(groups[levels]!.map { JSON($0.model) })
                    variant["required"] = .array(schema["required"].list + ["model"])
                    variants.append(variant)
                }
                schema = effortVariants(schema,variants)
            } else if let profile, name == "subagent_send" {
                // Group children with the same capabilities, keeping schema
                // growth bounded by capability sets rather than turn count.
                let groups = Dictionary(grouping:children.keys.sorted()) { children[$0]!.supportedEfforts(parent:profile,connectionSupportsReasoning:connectionSupportsReasoning) }
                if groups.count <= 1 {
                    schema = effortVariant(schema,levels:groups.keys.first ?? [])
                    return ToolDefinition(name, descriptions[name]!, schema)
                }
                let variants = groups.keys.sorted { $0.joined() < $1.joined() }.map { levels -> JSON in
                    var variant = effortVariant(schema,levels:levels)
                    variant["properties"]["child_id"]["enum"] = .array(groups[levels]!.map(JSON.string))
                    return variant
                }
                schema = effortVariants(schema,variants)
            }
            return ToolDefinition(name, descriptions[name]!, schema)
        }
    }
    static let descriptions: [String:String] = [
        "subagent_start": "Start a child with a self-contained task and fresh conversation. Choose background to continue working, or wait for a bounded wait. Children share project files and this chat's cost limit. Results and child messages arrive automatically at your next safe boundary. Children cannot delegate. " + delegationPolicy,
        "subagent_send": "Message one of your existing children. A queued/running turn receives steering at its next safe boundary. A finished child starts a follow-up turn with its previous conversation. Optional effort applies only to a follow-up; steering keeps the running turn's effort. This call returns an acceptance receipt; use wait if you need the answer before proceeding.",
        "subagent_wait": "Wait for one, any or all of the selected child turns to settle. A child report or user steering can wake this wait early so you can respond. Inspect wake_reason and pending_count; timeout leaves children running. Results are delivered once through your agent-event lane, not copied into this tool response.",
        "subagent_status": "List your children's latest state, or read a page of a saved result. Reading never starts a child or marks an automatic event delivered.",
        "subagent_stop": "Stop this specific child turn, including queued work. Its saved conversation remains available. No accepted step is rerun. Wait for settlement before sending a new follow-up.",
        "subagent_report": "Send your parent an important discovery, partial result, blocker or question before you finish. This queues a durable message; it does not wait for a reply. Keep working where possible. If blocked, report the question and finish with the blocker so your parent can answer in a follow-up. Do not send routine progress, acknowledgements or repeated reminders.",
    ]
    static func effortVariant(_ schema: JSON, levels: [String]) -> JSON {
        var result = schema
        if !levels.isEmpty {
            result["properties"]["effort"] = ["type":"string","enum":.array(levels.map(JSON.string)),
                "description":"Reasoning effort for the chosen child model. Omit to inherit the parent's current effort; use \"default\" for the model's own default."]
        }
        return result
    }
    static func effortVariants(_ schema: JSON, _ variants: [JSON]) -> JSON {
        guard !variants.isEmpty else { return schema }
        let levels = Profile.thinkingLevels.filter { level in variants.contains { $0["properties"]["effort"]["enum"].list.contains(JSON(level)) } }
        var result = effortVariant(schema,levels:levels)
        result["oneOf"] = .array(variants)
        return result
    }
    static let schemas: [String:JSON] = [
        "subagent_start": try! JSON.parse(Data(#"{"type":"object","properties":{"task":{"type":"string","minLength":1,"maxLength":262144},"description":{"type":"string","minLength":1,"maxLength":120},"mode":{"type":"string","enum":["background","wait"]},"timeout_ms":{"type":"integer","minimum":0,"maximum":60000,"default":60000},"model":{"type":"string","minLength":1,"maxLength":512},"tools":{"type":"array","items":{"type":"string","minLength":1,"maxLength":512},"uniqueItems":true}},"required":["task","mode"],"additionalProperties":false}"#.utf8)),
        "subagent_send": try! JSON.parse(Data(#"{"type":"object","properties":{"child_id":{"type":"string","minLength":1,"maxLength":512},"message":{"type":"string","minLength":1,"maxLength":262144},"expected_turn":{"type":"integer","minimum":1},"reply_to":{"type":"string","minLength":1,"maxLength":512}},"required":["child_id","message"],"additionalProperties":false}"#.utf8)),
        "subagent_wait": try! JSON.parse(Data(#"{"type":"object","properties":{"mode":{"type":"string","enum":["one","any","all"]},"targets":{"type":"array","minItems":1,"uniqueItems":true,"items":{"type":"object","properties":{"child_id":{"type":"string","minLength":1,"maxLength":512},"turn":{"type":"integer","minimum":1}},"required":["child_id","turn"],"additionalProperties":false}},"timeout_ms":{"type":"integer","minimum":0,"maximum":60000,"default":60000}},"required":["mode"],"additionalProperties":false}"#.utf8)),
        "subagent_status": try! JSON.parse(Data(#"{"oneOf":[{"type":"object","properties":{"action":{"type":"string","const":"list"},"child_id":{"type":"string","minLength":1,"maxLength":512},"wait_id":{"type":"string","minLength":1,"maxLength":512},"cursor":{"type":"string","minLength":1,"maxLength":512},"limit":{"type":"integer","minimum":1,"maximum":100,"default":32}},"required":["action"],"additionalProperties":false},{"type":"object","properties":{"action":{"type":"string","const":"read_result"},"child_id":{"type":"string","minLength":1,"maxLength":512},"turn":{"type":"integer","minimum":1},"offset":{"type":"integer","minimum":0,"default":0},"limit_bytes":{"type":"integer","minimum":1,"maximum":16384,"default":8192}},"required":["action","child_id","turn"],"additionalProperties":false}]}"#.utf8)),
        "subagent_stop": try! JSON.parse(Data(#"{"type":"object","properties":{"child_id":{"type":"string","minLength":1,"maxLength":512},"turn":{"type":"integer","minimum":1},"reason":{"type":"string","minLength":1,"maxLength":1024}},"required":["child_id","turn"],"additionalProperties":false}"#.utf8)),
        "subagent_report": try! JSON.parse(Data(#"{"type":"object","properties":{"kind":{"type":"string","enum":["note","blocker","question"]},"message":{"type":"string","minLength":1,"maxLength":4096},"reply_to":{"type":"string","minLength":1,"maxLength":512}},"required":["kind","message"],"additionalProperties":false}"#.utf8)),
    ]
}

extension SubagentSteeringContract {
    static func validate(_ name: String, _ value: JSON) throws {
        guard var schema = schemas[name] else { throw invalid() }
        // Model-specific membership is checked against the frozen grant by
        // the coordinator; shape validation remains strict and uncoerced.
        if name == "subagent_start" || name == "subagent_send" {
            schema["properties"]["effort"] = ["type":"string","minLength":1,"maxLength":64]
        }
        guard matches(value, schema) else { throw invalid() }
        for key in ["task", "message", "reason"] where value.map[key] != nil {
            guard let text = value[key].text, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= (name == "subagent_report" ? 4096 : key == "reason" ? 1024 : 262144) else { throw invalid() }
        }
        if let description = value["description"].text, description.utf8.count > 480 { throw invalid() }
        if name == "subagent_start", value["mode"].text == "background", value.map["timeout_ms"] != nil { throw invalid() }
        if name == "subagent_wait", value["mode"].text == "one", value["targets"].list.count != 1 { throw invalid() }
        if name == "subagent_status", value["child_id"].text != nil, value["action"].text == "list",
           value["cursor"].text != nil || value["wait_id"].text != nil { throw invalid() }
    }
    private static func invalid() -> AgentError { AgentError("subagent_arguments", "Arguments do not match the sub-agent tool contract") }
    // Only the schema vocabulary used above; no permissive fallback for unknown types.
    private static func matches(_ v: JSON, _ s: JSON) -> Bool {
        if !s["oneOf"].isNull { return s["oneOf"].list.filter { matches(v,$0) }.count == 1 }
        if !s["enum"].isNull, !s["enum"].list.contains(v) { return false }
        if !s["const"].isNull, s["const"] != v { return false }
        switch s["type"].text {
        case "object":
            return v.isObject && Set(v.map.keys).isSubset(of:Set(s["properties"].map.keys))
                && s["required"].list.allSatisfy { v.map[$0.text ?? ""] != nil }
                && v.map.allSatisfy { matches($0.value,s["properties"][$0.key]) }
        case "array":
            guard case .array(let values) = v, values.count >= (s["minItems"].int ?? 0) else { return false }
            return values.allSatisfy { matches($0,s["items"]) }
                && (s["uniqueItems"].flag != true || Set(values.map { $0.encoded() }).count == values.count)
        case "string":
            guard let text = v.text else { return false }
            return text.count >= (s["minLength"].int ?? 0) && text.count <= (s["maxLength"].int ?? Int.max)
        case "integer":
            guard let number = v.int else { return false }
            return number >= (s["minimum"].int ?? Int.min) && number <= (s["maximum"].int ?? Int.max)
        default: return false
        }
    }
}
