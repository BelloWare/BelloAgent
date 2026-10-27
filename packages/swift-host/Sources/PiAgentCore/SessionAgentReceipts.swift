import Foundation

extension AgentSession {
    func savedAgentOperation(_ key: SubagentCallKey) -> AgentOperation? { subagents.family?.operations[AgentOperation.id(key)] }

    /// Live cancellation and crash repair obey the same authority: once an
    /// operation is durable, its control receipt cannot become "not executed".
    /// Reports consult the owner too, since their local mirror can be missing.
    func acceptedAgentToolResult(_ call: ToolCall, stopped: Bool) async -> JSON? {
        guard SubagentSteeringContract.names.contains(call.name), let assistant = toolHistory.owners[call.id] else { return nil }
        let key = SubagentCallKey(parentSessionID:id,assistantMessageID:assistant,toolCallID:call.id)
        var saved = savedAgentOperation(key)
        if saved == nil, let owner = budgetOwner { saved = await owner.savedAgentOperation(key) }
        guard let saved, saved.digest == sha256(Data((call.name + call.arguments.encoded()).utf8)) else { return nil }
        var receipt = saved.receipt
        if stopped, call.name == "subagent_wait" || call.name == "subagent_start" && call.arguments["mode"].text == "wait" {
            receipt["wait"] = ["version":3,"wait_id":JSON(saved.id),"wake_reason":"stopped"]
        }
        return agentToolWire(receipt,key:key)
    }
    func agentToolWire(_ receipt: JSON, key: SubagentCallKey) -> JSON {
        var wire = resultText(receipt["version"].int == 4 ? receipt["output"].text ?? "" : receipt.encoded())
        if receipt["version"].int == 4 {
            wire["nativeResultMessageId"] = JSON("agent-receipt:" + AgentOperation.id(key))
            if !receipt["nativeSubagent"].isNull { wire["nativeSubagent"] = receipt["nativeSubagent"] }
            return wire
        }
        wire["nativeResultMessageId"] = JSON("agent-receipt:" + AgentOperation.id(key))
        if let child = receipt["child_id"].text,
           let origin = subagents.plans.values.first(where: { $0.origin.link.childSessionID == child })?.origin ?? (subagents.origin?.link.childSessionID == child ? subagents.origin : nil) {
            wire["nativeSubagent"] = ["version":2,"sessionId":JSON(child),"delegationId":JSON(origin.link.delegationID),"budgetOwnerSessionId":JSON(origin.link.budgetOwnerSessionID),"parentAssistantMessageId":JSON(key.assistantMessageID),"toolCallId":JSON(key.toolCallID),"turn":receipt["turn"],"route":receipt["route"],"status":"accepted","effects":"completed"]
            if let effort = receipt["effort"].text { wire["nativeSubagent"]["effort"] = JSON(effort) }
        }
        return wire
    }
}
