import Foundation

struct SubagentSpec: Sendable {
    static let modelDescription = "An offered model for this connection; omit to inherit the parent's model. If the requested model is not offered, the parent's model is used instead and the result identifies it."
    let task: String, description: String
    let model: String?
    let tools: Set<String>?
    init(_ value: JSON) throws {
        guard value.isObject, Set(value.map.keys).isSubset(of: ["task", "description", "model", "tools"]),
              let task = value["task"].text, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.utf8.count <= 262_144 else { throw AgentError("subagent_arguments", "Provide a self-contained task of at most 256 KiB") }
        self.task = task
        if value.map.keys.contains("description") {
            guard let text = value["description"].text, !text.isEmpty, text.count <= 120, text.utf8.count <= 480 else { throw AgentError("subagent_arguments", "Description must be 1–120 characters") }
            description = text
        } else { description = String(SubagentToolResult.bounded(task.split(whereSeparator: \.isWhitespace).joined(separator: " "), bytes: 480).prefix(120)) }
        model = value["model"].text
        if value.map.keys.contains("model"), model == nil { throw AgentError("subagent_model", "Model must be a model ID string") }
        if value.map.keys.contains("tools") {
            guard case .array(let list) = value["tools"], list.allSatisfy({ $0.text != nil }), Set(list.compactMap(\.text)).count == list.count else {
                throw AgentError("subagent_tools", "Tools must be a list of unique tool names")
            }
            tools = Set(list.compactMap(\.text))
        } else { tools = nil }
    }
    static func definition(models: [SubagentModelGrant]) -> ToolDefinition {
        var model: JSON = ["type":"string", "description":JSON(modelDescription)]
        if !models.isEmpty { model["enum"] = .array(models.map(\.model).sorted().map(JSON.string)) }
        return ToolDefinition("subagent", "Delegate a self-contained task and wait for its result. Multiple calls run concurrently, sharing project files and this chat's cost limit. Include all necessary context: children start fresh and cannot delegate. Interrupted calls are never automatically replayed. " + SubagentSteeringContract.delegationPolicy,
            ["type":"object", "properties":["task":["type":"string","minLength":1], "description":["type":"string","maxLength":120],
                                             "model":model,"tools":["type":"array","items":["type":"string"],"uniqueItems":true]],
             "required":["task"],"additionalProperties":false])
    }
}

/// Exact model envelope and local provenance, saved together in the child
/// terminal record and adopted without regeneration by later recovery.
struct SubagentToolResult: Codable, Sendable, Equatable {
    var envelope: JSON
    var metadata: JSON
    var messageID: String?
    var status: SubagentStatus { SubagentStatus(rawValue: envelope["status"].text ?? "") ?? .failed }
    var wire: JSON {
        ["content":[textBlock(envelope.encoded())], "isError":JSON(![.completed, .outputLimited].contains(status)),
         "nativeSubagent":metadata, "nativeResultMessageId":messageID.map { JSON($0) } ?? .null]
    }
    init(plan: SubagentPlan? = nil, status: SubagentStatus, text: String = "", error: AgentError? = nil,
         messageIDs: [String] = [], accountingRevision: Int = 0, began: Bool = false, textLimit: Int = 65_536) {
        let notice = "\n\n[Final answer truncated at 1 MiB.]"
        let kept = textLimit == 1_048_576 && text.utf8.count > textLimit ? Self.bounded(text,bytes:textLimit-notice.utf8.count) + notice : Self.bounded(text,bytes:textLimit)
        envelope = ["status":JSON(status.rawValue),"text":JSON(kept),"truncated":JSON(kept.utf8.count < text.utf8.count)]
        if let error { envelope["error"] = ["code":JSON(Self.bounded(error.code, bytes:128)),"message":JSON(Self.bounded(error.message, bytes:2048))] }
        metadata = .null; messageID = plan?.resultMessageID
        if let plan {
            let link = plan.origin.link
            metadata = ["version":1,"delegationId":JSON(link.delegationID),"sessionId":JSON(link.childSessionID),"budgetOwnerSessionId":JSON(link.budgetOwnerSessionID),
                        "parentAssistantMessageId":JSON(link.call.assistantMessageID),"toolCallId":JSON(link.call.toolCallID),
                        "resultRef":["messageIds":.array(messageIDs.map { JSON($0) })],"status":JSON(status.rawValue),
                        "effects":JSON(!began ? "not_executed" : [.completed, .outputLimited].contains(status) ? "completed" : "unknown"),"accountingRevision":JSON(accountingRevision)]
        }
    }
    static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var data = Data(text.utf8.prefix(bytes))
        while !data.isEmpty {
            if let value = String(data: data, encoding: .utf8) { return value }
            data.removeLast()
        }
        return ""
    }
}
