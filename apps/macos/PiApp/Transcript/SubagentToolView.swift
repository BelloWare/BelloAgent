import Foundation

/// A navigation target from a card is checked against the child's durable
/// origin before opening it. Copied cards retain their original owner.
struct SubagentTarget: Equatable, Sendable {
    var delegationID: String, sessionID: String, ownerID: String, assistantID: String, toolCallID: String
    var turn: Int? = nil
    var messageID: String? = nil
    var receiptSource = false
    var issuingSessionID: String? = nil
    func isHistorical(in sourceID: String?) -> Bool {
        sourceID.map { $0 != ownerID && $0 != sessionID && $0 != issuingSessionID } ?? false
    }
    init(_ link: SubagentLink) {
        delegationID = link.delegationID; sessionID = link.childSessionID; ownerID = link.budgetOwnerSessionID
        assistantID = link.call.assistantMessageID; toolCallID = link.call.toolCallID
    }
    func matchesOrigin(_ link: SubagentLink) -> Bool {
        delegationID == link.delegationID && sessionID == link.childSessionID && ownerID == link.budgetOwnerSessionID
            && (receiptSource || (assistantID == link.call.assistantMessageID && toolCallID == link.call.toolCallID))
    }
    init?(metadata: WireValue) {
        guard let fields = metadata.object, [1, 2].contains(fields["version"]?.number ?? 0),
              let delegation = fields["delegationId"]?.string, let session = fields["sessionId"]?.string,
              let owner = fields["budgetOwnerSessionId"]?.string, let assistant = fields["parentAssistantMessageId"]?.string,
              let call = fields["toolCallId"]?.string,
              [delegation, session, owner, assistant, call].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains { $0 < 32 || $0 == 127 } }),
              session != owner else { return nil }
        delegationID = delegation; sessionID = session; ownerID = owner; assistantID = assistant; toolCallID = call
        if fields["version"]?.number == 2 {
            guard let number = fields["turn"]?.nonnegativeInteger, number > 0 else { return nil }
            turn = number; receiptSource = true
        }
    }
}

struct SubagentToolView: Equatable, Sendable {
    static let historicalNotice = "From the original chat"
    static let codexTools: Set<String> = ["spawn_agent", "send_message", "followup_task", "wait_agent", "interrupt_agent", "list_agents"]
    static func isControl(_ name: String) -> Bool { codexTools.contains(name) || name == "subagent" || ["subagent_start", "subagent_send", "subagent_wait", "subagent_status", "subagent_stop", "subagent_report"].contains(name) }
    static func isPresented(_ tool: ToolView) -> Bool { isControl(tool.name) && (!codexTools.contains(tool.name) || tool.codexAgents) }
    let originalAvailability: OriginalSubagentAvailability?
    let operation: String
    let number: Int?
    let effort: String?
    /// The accepted turn's saved receipt, before any live display overlay.
    let receiptEffort: String?
    let childID: String?
    let codex: Bool
    let taskName: String?
    let forkTurns: String?
    let toolState: String
    var name: String { SubagentLabel.name(number, taskName: taskName) }
    var title: String { codex ? heading : SubagentLabel.title(number, description, taskName: taskName) }
    var heading: String {
        guard codex else { return name }
        switch operation {
        case "spawn_agent": return (accepted == false || error != nil || toolState == "unknown" ? "Start " : toolState == "running" || toolState == "recorded" ? "Starting " : "Started ") + name
        case "send_message": return "To " + name
        case "followup_task": return "New task for " + name + (receiptTurn.map { " · turn \($0)" } ?? "")
        case "wait_agent": return "Waiting for agents"
        case "interrupt_agent": return (accepted == false || error != nil || toolState == "unknown" ? "Interrupt " : toolState == "running" || toolState == "recorded" ? "Interrupting " : "Interrupted ") + name
        default: return "Agents"
        }
    }
    var preview: String { codex && ["wait_agent", "interrupt_agent", "list_agents"].contains(operation) ? "" : description }
    var showsTurnDetails: Bool { !codex || ["spawn_agent", "followup_task"].contains(operation) }
    let route: String?
    let receiptTurn: Int?
    let accepted: Bool?
    let messageReference: AgentMessageReference?
    let receiptMessageID: String?
    let messageState: String?
    let heldByUser: Bool
    let wakeReason: String?
    let messageKind: String?
    let target: SubagentTarget?
    let summary: SubagentSummary?
    let cost: SubagentCostPresentation?
    let task: String, description: String, result: String, error: String?
    let status: SubagentStatus
    let truncated: Bool
    init(_ tool: ToolView) {
        originalAvailability = tool.originalSubagentAvailability
        cost = tool.subagentCost
        operation = tool.name
        codex = tool.codexAgents && Self.codexTools.contains(tool.name)
        toolState = tool.state
        number = tool.subagentNumber
        effort = tool.subagentEffort
        let input = tool.input.data(using: .utf8).flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?.object ?? [:]
        let output = tool.output.data(using: .utf8).flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?.object ?? [:]
        let savedName = tool.subagentTaskName ?? tool.subagent?.taskName ?? tool.nativeSubagent?.object?["taskName"]?.string
        let requestedName = output["task_name"]?.string ?? input["task_name"]?.string ?? input["target"]?.string
        taskName = savedName ?? requestedName
        forkTurns = tool.nativeSubagent?.object?["forkTurns"]?.string ?? tool.subagent?.forkTurns ?? input["fork_turns"]?.string
        receiptEffort = tool.nativeSubagent?.object?["effort"]?.string ?? output["effort"]?.string
        accepted = output["accepted"]?.bool
        messageState = tool.agentDeliveryState
        heldByUser = tool.agentHeldByUser == true
        wakeReason = output["wake_reason"]?.string
        wakeSummary = tool.name == "wait_agent" && !tool.output.isEmpty ? tool.output : nil
        messageKind = input["kind"]?.string
        receiptMessageID = tool.agentEvent?.id ?? output["message_id"]?.string
        messageReference = tool.agentEvent.map { AgentMessageReference(childID: $0.childID, turn: $0.turn, eventID: $0.id, recipient: true) } ?? output["child_id"]?.string.flatMap { child in
            output["turn"]?.nonnegativeInteger.map { AgentMessageReference(childID: child, turn: $0, eventID: output["message_id"]?.string, recipient: true) }
        }
        route = tool.nativeSubagent?.object?["route"]?.string ?? output["route"]?.string
        receiptTurn = tool.nativeSubagent?.object?["turn"]?.nonnegativeInteger ?? output["turn"]?.nonnegativeInteger
        summary = tool.subagent ?? tool.nativeSubagent?.object?["summary"].flatMap { try? JSONDecoder().decode(SubagentSummary.self, from: JSONEncoder().encode($0)) }
        var destination = tool.nativeSubagent.flatMap(SubagentTarget.init(metadata:)) ?? summary.flatMap { $0.link.valid ? SubagentTarget($0.link) : nil }
        if (["subagent_start", "spawn_agent"].contains(tool.name) || destination?.turn == nil), let number = summary?.turn { destination?.turn = number }
        if tool.name == "subagent_send", route == "steer", let reference = messageReference,
           reference.childID == destination?.sessionID, reference.turn == destination?.turn,
           let id = reference.eventID, !id.isEmpty, id.utf8.count <= 512 { destination?.messageID = id }
        if codex, let event = tool.agentEvent, event.recipientID == destination?.sessionID {
            destination?.turn = event.turn; destination?.messageID = event.id
            destination?.issuingSessionID = event.sourceSessionID
        }
        target = destination
        childID = destination?.sessionID ?? output["child_id"]?.string ?? input["child_id"]?.string
        task = codex && ["wait_agent", "interrupt_agent", "list_agents"].contains(tool.name) ? "" : input["task"]?.string ?? input["message"]?.string ?? input["reason"]?.string ?? (tool.name == "subagent_wait" ? "Wait for selected child turns to settle." : tool.input)
        let taskLabel = String(task.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
        description = codex && ["send_message", "followup_task"].contains(tool.name) ? taskLabel : summary?.description ?? input["description"]?.string ?? taskLabel
        let savedState = (output["status"]?.string == "accepted" || output["accepted"]?.bool == true) ? SubagentStatus.queued : tool.state == "unknown" ? SubagentStatus.interrupted : SubagentStatus(rawValue: tool.state) ?? .queued
        status = summary?.status ?? output["status"]?.string.flatMap(SubagentStatus.init(rawValue:)) ?? savedState
        if codex {
            if tool.name == "list_agents" {
                result = (output["agents"]?.array ?? []).compactMap { value in
                    guard let agent = value.object, let name = SubagentLabel.task(agent["agent_name"]?.string) else { return nil }
                    let status = (agent["agent_status"]?.string ?? "").replacingOccurrences(of: "_", with: " ").capitalized
                    return "- " + name + " · " + status + (agent["turn"]?.nonnegativeInteger.map { " · turn \($0)" } ?? "")
                }.joined(separator: "\n") + (output["next_cursor"].flatMap { $0 == .null ? nil : $0 } == nil ? "" : "\n\nMore agents available")
            } else if tool.name == "wait_agent" { result = tool.output
            } else if tool.name == "interrupt_agent" { result = output["previous_status"]?.string.map { "Previous status: " + $0.replacingOccurrences(of: "_", with: " ") } ?? ""
            } else { result = output["model_notice"]?.string ?? "" }
        } else { result = tool.name == "subagent" ? output["text"]?.string ?? tool.output : output["text"]?.string ?? (output.isEmpty ? tool.output : "") }
        error = output["error"]?.object?["message"]?.string ?? (accepted == false || output["ok"]?.bool == false ? output["message"]?.string ?? "The operation was not accepted." : tool.state == "failed" ? tool.output : nil)
        truncated = output["truncated"]?.bool == true || tool.truncated
    }
    var label: String {
        statusLabel + (effort.map { " · " + $0 } ?? "")
    }
    private var statusLabel: String {
        if codex {
            if toolState == "unknown" { return "Outcome unknown" }
            if accepted == false || error != nil { return "Not accepted" }
            if heldByUser { return "Stopped by you" }
            if messageState == "waiting_next_turn" || summary?.deliveryState == "waiting_next_turn" { return "Waiting for its next turn" }
            if let messageState, messageState == "delivered" { return "Delivered" }
            if messageState == "held" { return "Pending for parent Resume" }
            switch operation {
            case "spawn_agent": return (forkTurns == "none" ? "fresh" : "with this chat's context") + (summary.map { " · " + $0.presentationLabel } ?? "")
            case "send_message": return toolState == "running" ? "Sending" : "Queued for delivery"
            case "followup_task": return summary?.presentationLabel ?? (route == "follow_up" ? "Task accepted" : "Queued for running agent")
            case "wait_agent": return resultText.isEmpty ? "Waiting for agents" : resultText
            case "interrupt_agent": return toolState == "running" ? "Interrupting" : "Agent remains available"
            default: return "Team status"
            }
        }
        if operation != "subagent" {
            if accepted == false { return "Not accepted" }
            if heldByUser { return "Stopped by you" + ((operation == "subagent_start" ? summary?.turn ?? receiptTurn : receiptTurn).map { " · turn \($0)" } ?? "") }
            if let messageState {
                switch messageState {
                case "delivered": return "Delivered" + (receiptTurn.map { " · turn \($0)" } ?? "")
                case "not_delivered_interrupted": return "Not delivered · interrupted"
                case "held": return "Pending for parent Resume"
                default: break
                }
            }
            let suffix = receiptTurn.map { " · turn \($0)" } ?? ""
            if route == "steer" { return "Queued for steering" + suffix }
            if operation == "subagent_report" { return "To parent · queued for delivery" + suffix }
            if operation == "subagent_wait" {
                guard let wakeReason else { return "Waiting for sub-agents" }
                let reason = ["message":"new report", "steering":"new guidance", "settled":"agents finished", "empty":"no agents to wait for", "timeout":"wait time elapsed", "stopped":"stopped", "paused":"paused at the cost limit"][wakeReason]
                return "Wait ended" + (reason.map { " · " + $0 } ?? "")
            }
            if let summary, operation == "subagent_start" || summary.turn == receiptTurn { return summary.presentationLabel }
            if route == "follow_up" { return "Follow-up accepted" + suffix }
            return "Accepted" + suffix
        }
        if summary?.pausedAtCostLimit == true { return "Paused at cost limit" }
        guard !status.terminal, status != .queued, status != .stopping else { return status.label }
        switch summary?.progress?.phase {
        case "retry": return "Retrying"
        case "compacting": return "Compacting"
        default: return status.label
        }
    }
    private var resultText: String { wakeSummary ?? "" }
    let wakeSummary: String?
}
