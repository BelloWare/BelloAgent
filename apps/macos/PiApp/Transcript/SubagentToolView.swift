import Foundation

/// A navigation target from a card is checked against the child's durable
/// origin before opening it. Copied cards retain their original owner.
struct SubagentTarget: Equatable, Sendable {
    var delegationID: String, sessionID: String, ownerID: String, assistantID: String, toolCallID: String
    init(_ link: SubagentLink) {
        delegationID = link.delegationID; sessionID = link.childSessionID; ownerID = link.budgetOwnerSessionID
        assistantID = link.call.assistantMessageID; toolCallID = link.call.toolCallID
    }
    init?(metadata: WireValue) {
        guard let fields = metadata.object, fields["version"]?.number == 1,
              let delegation = fields["delegationId"]?.string, let session = fields["sessionId"]?.string,
              let owner = fields["budgetOwnerSessionId"]?.string, let assistant = fields["parentAssistantMessageId"]?.string,
              let call = fields["toolCallId"]?.string,
              [delegation, session, owner, assistant, call].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains { $0 < 32 || $0 == 127 } }),
              session != owner else { return nil }
        delegationID = delegation; sessionID = session; ownerID = owner; assistantID = assistant; toolCallID = call
    }
}

struct SubagentToolView: Equatable, Sendable {
    let target: SubagentTarget?
    let summary: SubagentSummary?
    let task: String, description: String, result: String, error: String?
    let status: SubagentStatus
    let truncated: Bool
    init(_ tool: ToolView) {
        let input = tool.input.data(using: .utf8).flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?.object ?? [:]
        let output = tool.output.data(using: .utf8).flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?.object ?? [:]
        summary = tool.subagent ?? tool.nativeSubagent?.object?["summary"].flatMap { try? JSONDecoder().decode(SubagentSummary.self, from: JSONEncoder().encode($0)) }
        target = summary.flatMap { $0.link.valid ? SubagentTarget($0.link) : nil } ?? tool.nativeSubagent.flatMap(SubagentTarget.init(metadata:))
        task = input["task"]?.string ?? tool.input
        description = summary?.description ?? input["description"]?.string ?? String(task.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
        status = summary?.status ?? output["status"]?.string.flatMap(SubagentStatus.init(rawValue:)) ?? (tool.state == "running" ? .running : tool.state == "failed" ? .failed : .queued)
        result = output["text"]?.string ?? tool.output
        error = output["error"]?.object?["message"]?.string
        truncated = output["truncated"]?.bool == true || tool.truncated
    }
    var label: String {
        guard !status.terminal, status != .queued, status != .stopping else { return status.label }
        switch summary?.progress?.phase {
        case "retry": return "Retrying"
        case "compacting": return "Compacting"
        default: return status.label
        }
    }
}
