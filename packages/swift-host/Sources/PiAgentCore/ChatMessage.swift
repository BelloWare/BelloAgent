import Foundation

// One row of a conversation, in the journal envelope and in the display
// projection.

/// One text block of message content, the shape every provider agrees on.
func textBlock(_ text: String) -> JSON { ["type": "text", "text": JSON(text)] }

/// Text the model receives as a user message of its own just before the
/// message that carries it, and that no transcript shows: a side chat's note
/// that it is a read-only side (`kind` "side-read-only"), or that its editing
/// tools were turned on later ("editing-on"). Carried by the user message it
/// precedes rather than journaled as a row, so every timeline, edit plan and
/// history reader sees the rows they always saw.
public struct ContextNote: Codable, Sendable, Equatable {
    public var kind: String, text: String
    public init(kind: String, text: String) { self.kind = kind; self.text = text }
    var json: JSON { ["kind": JSON(kind), "text": JSON(text)] }
}

public struct ChatMessage: Codable, Sendable {
    public var id: String = UUID().uuidString
    public var role: String
    public var content: [JSON]
    public var providerItems: [JSON]? = nil
    public var providerIdentity: JSON? = nil
    public var providerBinding: JSON? = nil
    public var presentationSourceID: String? = nil
    public var operationID: String? = nil
    public var responseTimeline: ResponseTimeline? = nil
    public var toolCallId: String? = nil
    public var toolName: String? = nil
    public var isError: Bool = false
    public var replayEligible: Bool = true
    public var displayText: String? = nil
    /// Original explicit inputs, without expanded skill bodies or image bytes.
    public var userInput: JSON? = nil
    public var sourceMessageIDs: [String]? = nil
    public var requestAttemptIDs: [String]? = nil
    /// Display-only classification: "compaction" for a summary written by
    /// compaction, "branch" for the marker left by turn.edit. Nil for ordinary rows.
    public var kind: String? = nil
    public var detail: String? = nil
    /// Milliseconds since 1970 when the message was appended; journals written
    /// before this field carried the same key, so old history keeps its clock.
    public var timestamp: Double? = nil
    /// For tool results: durationMs plus, for file tools, path/added/removed.
    public var toolStats: JSON? = nil
    /// "length" when the model stopped at the output budget; nil otherwise.
    public var stopReason: String? = nil
    /// Assistant rows: the reply's usage in pi's shape (input, output,
    /// cacheRead, cacheWrite, totalTokens), which the context count anchors on.
    /// Nil for rows journaled before 0.1.87 and for replies without usage.
    public var usage: JSON? = nil
    /// The turn this row was appended under: the id of the user message that
    /// started the run. The transcript groups work by it instead of guessing
    /// at boundaries from row order. Nil for rows journaled before 0.1.34.
    public var turn: String? = nil
    /// Assistant rows: how long the model request that produced the row took,
    /// in milliseconds, measured by the host around the request.
    public var modelMs: Double? = nil
    /// Independent of the turn/steering display identity. A delivered steering
    /// message belongs to the original task, not a new compaction objective.
    public var taskRootID: String? = nil
    public var taskExecutionID: String? = nil
    public var inputLane: String? = nil
    /// Versioned checkpoint metadata also survives saved-side message records.
    public var compaction: JSON? = nil
    /// The saved output file of a result cut before 0.1.94, for its removed
    /// history_read tool. Nothing sets it now; it is kept so those saved
    /// records read and write back unchanged.
    public var retainedOutput: String? = nil
    /// User rows: the hidden note sent ahead of this message (`ContextNote`).
    public var contextNote: ContextNote? = nil
    public var text: String { content.filter { $0["type"].text == "text" }.compactMap { $0["text"].text }.joined() }
    public var thinking: String { content.filter { $0["type"].text == "thinking" }.compactMap { $0["thinking"].text }.joined() }
    public var pi: JSON {
        var value: JSON = ["role": JSON(role), "content": .array(content), "timestamp": JSON(timestamp ?? Date().timeIntervalSince1970 * 1000), "nativeReplayEligible": JSON(replayEligible)]
        if let presentationSourceID { value["nativePresentationSourceID"] = JSON(presentationSourceID) }
        if let operationID { value["nativeOperationID"] = JSON(operationID) }
        if let responseTimeline { value["nativeResponseTimeline"] = (try? JSON.parse(JSONEncoder().encode(responseTimeline))) ?? .null }
        if let toolStats { value["nativeToolStats"] = toolStats }
        if let turn { value["nativeTurn"] = JSON(turn) }
        if let modelMs { value["nativeModelMs"] = JSON(modelMs) }
        if let taskRootID { value["nativeTaskRoot"] = JSON(taskRootID) }
        if let taskExecutionID { value["nativeTaskExecution"] = JSON(taskExecutionID) }
        if let inputLane { value["nativeInputLane"] = JSON(inputLane) }
        if let compaction { value["nativeCompaction"] = compaction }
        if let retainedOutput { value["nativeRetainedOutput"] = JSON(retainedOutput) }
        if let stopReason { value["nativeStopReason"] = JSON(stopReason) }
        if let usage { value["usage"] = usage }
        if let providerItems { value["nativeProviderItems"] = .array(providerItems) }
        if let providerIdentity { value["nativeProviderIdentity"] = providerIdentity }
        if let providerBinding { value["nativeProviderBinding"] = providerBinding }
        if let toolCallId { value["toolCallId"] = JSON(toolCallId) }
        if let toolName { value["toolName"] = JSON(toolName) }
        if let displayText { value["nativeDisplayText"] = JSON(displayText) }
        if let userInput { value["nativeUserInput"] = userInput }
        if let contextNote { value["nativeContextNote"] = contextNote.json }
        if let requestAttemptIDs { value["nativeRequestAttemptIds"] = .array(requestAttemptIDs.map { JSON($0) }) }
        if let kind { value["nativeKind"] = JSON(kind) }
        if let detail { value["nativeDetail"] = JSON(detail) }
        value["isError"] = JSON(isError)
        return value
    }
    public init(role: String, content: [JSON]) { self.role = role; self.content = content }
    public init(id: String, pi: JSON) throws {
        guard let role = pi["role"].text, ["user","assistant","toolResult","system"].contains(role) else { throw AgentError("invalid_session", "Unsupported message role") }
        self.id=id; self.role=role
        content = pi["content"].text.map { [textBlock($0)] } ?? pi["content"].list
        providerItems = pi["nativeProviderItems"].isNull ? nil : pi["nativeProviderItems"].list
        providerIdentity = pi["nativeProviderIdentity"].isNull ? nil : pi["nativeProviderIdentity"]
        providerBinding = pi["nativeProviderBinding"].isNull ? nil : pi["nativeProviderBinding"]
        presentationSourceID = pi["nativePresentationSourceID"].text; operationID = pi["nativeOperationID"].text
        responseTimeline = try? JSONDecoder().decode(ResponseTimeline.self, from: pi["nativeResponseTimeline"].data())
        toolCallId = pi["toolCallId"].text; toolName = pi["toolName"].text; isError = pi["isError"].flag ?? false
        replayEligible = pi["nativeReplayEligible"].flag ?? true; displayText = pi["nativeDisplayText"].text
        if !pi["nativeCompaction"].isNull, pi["nativeCompaction"]["version"].int != 2 { throw AgentError("session_damaged","Unsupported inherited compaction metadata version") }
        userInput = pi["nativeUserInput"].isNull ? nil : pi["nativeUserInput"]
        if let kind = pi["nativeContextNote"]["kind"].text, let note = pi["nativeContextNote"]["text"].text { contextNote = ContextNote(kind: kind, text: note) }
        requestAttemptIDs = pi["nativeRequestAttemptIds"].isNull ? nil : pi["nativeRequestAttemptIds"].list.compactMap(\.text)
        kind = pi["nativeKind"].text; detail = pi["nativeDetail"].text
        timestamp = pi["timestamp"].double; toolStats = pi["nativeToolStats"].isNull ? nil : pi["nativeToolStats"]
        turn = pi["nativeTurn"].text; modelMs = pi["nativeModelMs"].double
        taskRootID=pi["nativeTaskRoot"].text; inputLane=pi["nativeInputLane"].text
        taskExecutionID=pi["nativeTaskExecution"].text
        compaction=pi["nativeCompaction"].isNull ? nil : pi["nativeCompaction"]
        retainedOutput=pi["nativeRetainedOutput"].text; stopReason=pi["nativeStopReason"].text
        usage=role == "assistant" && !pi["usage"].map.isEmpty ? pi["usage"] : nil
    }
    public func view(toolStates: [String: JSON] = [:], state: String = "complete") -> JSON {
        let tools = content.filter { $0["type"].text == "toolCall" }.map { block -> JSON in
            let id = block["id"].text ?? "unknown"
            if let live = toolStates[id] { return live }
            let fields = toolInputFields(block["arguments"])
            return merging(["id": JSON(id), "name": block["name"], "state": "prepared", "output": "", "durationMs": .null,
                            "truncated": JSON(fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false)], fields)
        }
        let full = displayText ?? text
        var value: JSON = ["id": JSON(id), "role": JSON(role == "toolResult" ? "tool" : role), "text": JSON(full), "thinking": JSON(thinking), "tools": .array(tools), "state": JSON(state), "truncated": false]
        if let presentationSourceID { value["presentationSourceID"] = JSON(presentationSourceID) }
        if let operationID { value["operationID"] = JSON(operationID) }
        if role == "toolResult" {
            value["kind"] = "toolResult"; value["detail"] = JSON("Tool result · " + (toolName ?? "tool") + " · " + (toolStats?["outcome"].text ?? (isError ? "failed":"recorded")))
            // Which call this result belongs to. The reply that made the call
            // already carries the card with this result's output, so a display
            // that shows the call in its chronological place can say that this
            // row is the same result rather than repeating it underneath.
            if let toolCallId { value["toolCallID"] = JSON(toolCallId) }
        }
        let parts: [(kind:String,text:String,callID:String?,name:String?)] = content.compactMap { part in
            switch part["type"].text {
            case "text": return ("text",part["text"].text ?? "",nil,nil)
            case "thinking": return ("reasoningText",part["thinking"].text ?? "",nil,nil)
            case "toolCall": return ("toolArguments",part["arguments"].encoded(),part["id"].text,part["name"].text)
            default: return nil
            }
        }
        let responseTimeline = responseTimeline?.restoringContent(parts, sourceID:id) ?? (role == "assistant" ? ResponseTimeline.canonical(parts,sourceID:id) : nil)
        if let responseTimeline { value["responseTimeline"] = (try? JSON.parse(JSONEncoder().encode(responseTimeline.projected()))) ?? .null }
        if role == "assistant" { value["toolCallCount"] = JSON(tools.count) }
        if let kind { value["kind"] = JSON(kind) }
        if let stopReason { value["stopReason"] = JSON(stopReason) }
        if let detail { value["detail"] = JSON(preview(detail, bytes: 1024)) }
        if let timestamp { value["at"] = JSON(timestamp) }
        if let turn { value["turn"] = JSON(turn) }
        if let taskRootID { value["taskRootID"] = JSON(taskRootID) }
        if let taskExecutionID { value["taskExecutionID"] = JSON(taskExecutionID) }
        if let modelMs { value["modelMs"] = JSON(modelMs) }
        if role == "user", let skills = displaySkills { value["skills"] = skills }
        if role == "assistant", let reply = replyRecord { value["reply"] = reply }
        return value
    }
    /// What this reply's own request reported, for a turn report whose request
    /// log has no row for it: the attempt, the alias it named, the model names
    /// the gateway reported with their sources, and the usage in pi's shape.
    /// The same fields sit in the journal row, so a reopened chat reads the same.
    var replyRecord: JSON? {
        var record: [String: JSON] = [:]
        if let attempt = requestAttemptIDs?.first { record["attempt"] = JSON(attempt) }
        if let alias = providerIdentity?["requestedAlias"].text { record["requested"] = JSON(alias) }
        let models: [JSON] = (providerIdentity?["evidence"].list ?? []).compactMap { item in
            guard item["kind"].text == "model", let name = item["value"].text, let source = item["source"].text else { return nil }
            return ["name": JSON(name), "source": JSON(source)]
        }
        if !models.isEmpty { record["models"] = .array(Array(models.prefix(8))) }
        if let usage { record["usage"] = usage }
        return record.isEmpty ? nil : .object(record)
    }
    /// The skills a user message was sent with, as its row shows them: the
    /// explicit selections the model received ahead of the text. Every field
    /// the row carries is a string, and a recorded entry without an identity
    /// or a name is left out. Nil when the message used none.
    var displaySkills: JSON? {
        let recorded = userInput?["skills"].list ?? []
        let rows: [JSON] = recorded.compactMap { skill in
            guard let id = skill["id"].text, let name = skill["name"].text else { return nil }
            var row: JSON = ["id": JSON(id), "name": JSON(name), "path": JSON(skill["path"].text ?? ""),
                             "contentHash": JSON(skill["contentHash"].text ?? ""), "metadataHash": JSON(skill["metadataHash"].text ?? ""),
                             "arguments": JSON(skill["arguments"].text ?? "")]
            for key in ["description", "scope", "policy"] { if let text = skill[key].text { row[key] = JSON(text) } }
            return row
        }
        return rows.isEmpty ? nil : .array(rows)
    }
}

// Presentation records have no model-facing content. Their retained display
// source is read explicitly; ordinary assistant full-text reads stay complete.
extension ChatMessage {
    var retainedDisplayText: String {
        if ["execution", "requestLedger"].contains(kind ?? ""), let responseTimeline {
            return (detail ?? "Operation") + "\n\n" + responseTimeline.retainedText
        }
        return displayText ?? text
    }
}
