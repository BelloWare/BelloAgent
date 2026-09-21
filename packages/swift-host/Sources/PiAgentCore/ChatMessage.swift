import Foundation

// One row of a conversation, in the journal envelope and in the display
// projection.

/// One text block of message content, the shape every provider agrees on.
func textBlock(_ text: String) -> JSON { ["type": "text", "text": JSON(text)] }

public struct ChatMessage: Codable, Sendable {
    public var id: String = UUID().uuidString
    public var role: String
    public var content: [JSON]
    public var providerItems: [JSON]? = nil
    public var providerIdentity: JSON? = nil
    public var providerBinding: JSON? = nil
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
    public var inputLane: String? = nil
    /// Versioned checkpoint metadata also survives saved-side message records.
    public var compaction: JSON? = nil
    /// App-owned retained output file, never an arbitrary model-selected path.
    public var retainedOutput: String? = nil
    public var text: String { content.filter { $0["type"].text == "text" }.compactMap { $0["text"].text }.joined() }
    public var thinking: String { content.filter { $0["type"].text == "thinking" }.compactMap { $0["thinking"].text }.joined() }
    public var pi: JSON {
        var value: JSON = ["role": JSON(role), "content": .array(content), "timestamp": JSON(timestamp ?? Date().timeIntervalSince1970 * 1000), "nativeReplayEligible": JSON(replayEligible)]
        if let toolStats { value["nativeToolStats"] = toolStats }
        if let turn { value["nativeTurn"] = JSON(turn) }
        if let modelMs { value["nativeModelMs"] = JSON(modelMs) }
        if let taskRootID { value["nativeTaskRoot"] = JSON(taskRootID) }
        if let inputLane { value["nativeInputLane"] = JSON(inputLane) }
        if let compaction { value["nativeCompaction"] = compaction }
        if let retainedOutput { value["nativeRetainedOutput"] = JSON(retainedOutput) }
        if let stopReason { value["nativeStopReason"] = JSON(stopReason) }
        if let providerItems { value["nativeProviderItems"] = .array(providerItems) }
        if let providerIdentity { value["nativeProviderIdentity"] = providerIdentity }
        if let providerBinding { value["nativeProviderBinding"] = providerBinding }
        if let toolCallId { value["toolCallId"] = JSON(toolCallId) }
        if let toolName { value["toolName"] = JSON(toolName) }
        if let displayText { value["nativeDisplayText"] = JSON(displayText) }
        if let userInput { value["nativeUserInput"] = userInput }
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
        toolCallId = pi["toolCallId"].text; toolName = pi["toolName"].text; isError = pi["isError"].flag ?? false
        replayEligible = pi["nativeReplayEligible"].flag ?? true; displayText = pi["nativeDisplayText"].text
        if !pi["nativeCompaction"].isNull, pi["nativeCompaction"]["version"].int != 2 { throw AgentError("session_damaged","Unsupported inherited compaction metadata version") }
        userInput = pi["nativeUserInput"].isNull ? nil : pi["nativeUserInput"]
        requestAttemptIDs = pi["nativeRequestAttemptIds"].isNull ? nil : pi["nativeRequestAttemptIds"].list.compactMap(\.text)
        kind = pi["nativeKind"].text; detail = pi["nativeDetail"].text
        timestamp = pi["timestamp"].double; toolStats = pi["nativeToolStats"].isNull ? nil : pi["nativeToolStats"]
        turn = pi["nativeTurn"].text; modelMs = pi["nativeModelMs"].double
        taskRootID=pi["nativeTaskRoot"].text; inputLane=pi["nativeInputLane"].text
        compaction=pi["nativeCompaction"].isNull ? nil : pi["nativeCompaction"]
        retainedOutput=pi["nativeRetainedOutput"].text; stopReason=pi["nativeStopReason"].text
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
        var value: JSON = ["id": JSON(id), "role": JSON(role == "toolResult" ? "tool" : role), "text": JSON(preview(full)), "thinking": JSON(preview(thinking, bytes: 8192)), "tools": .array(Array(tools.prefix(ToolInputDisplay.projectedCards))), "state": JSON(state), "truncated": JSON(full.utf8.count > 16384 || thinking.utf8.count > 8192 || tools.count > ToolInputDisplay.projectedCards)]
        if role == "assistant" { value["toolCallCount"] = JSON(tools.count) }
        if let kind { value["kind"] = JSON(kind) }
        if let stopReason { value["stopReason"] = JSON(stopReason) }
        if let detail { value["detail"] = JSON(preview(detail, bytes: 1024)) }
        if let timestamp { value["at"] = JSON(timestamp) }
        if let turn { value["turn"] = JSON(turn) }
        if let modelMs { value["modelMs"] = JSON(modelMs) }
        return value
    }
}
