import Foundation
struct TranscriptAnchor: Codable, Sendable, Equatable { var id: String; var offset: Double; var followsBottom: Bool }

struct ToolView: Codable, Sendable, Equatable, Identifiable {
    var id: String; var name: String; var state: String; var input: String; var output: String; var durationMs: Double?; var truncated: Bool
    /// File tools: resolved path and approximate line counts, from the host.
    var path: String? = nil; var added: Int? = nil; var removed: Int? = nil
    /// The inline argument document is short of the whole request, and the
    /// full one can be fetched with `session.tool.input`. Older hosts and
    /// journals leave both nil, which reads as "what you see is all of it".
    var inputTruncated: Bool? = nil
    /// The size of the whole request, whatever arrived inline.
    var inputBytes: Int? = nil
}
struct TranscriptMessage: Codable, Sendable, Identifiable, Equatable {
    var id: String; var role: String; var text: String
    var thinking: String? = nil; var tools: [ToolView]? = nil; var state: String? = nil; var truncated: Bool? = nil
    /// "length" when the reply reached the output limit the request carried.
    var stopReason: String? = nil
    var accounting: GatewayTotals? = nil
    /// Display-only marker kind from the host: "compaction" (summary written by
    /// context compaction) or "branch" (edit-and-resend point). `detail` carries
    /// its human-readable caption. History projection leaves both nil.
    var kind: String? = nil
    var detail: String? = nil
    /// Milliseconds since 1970 when the host appended the message.
    var at: Double? = nil
    /// The turn (user message id) the host appended the row under, when known.
    var turn: String? = nil
    /// Assistant rows: the model request's duration in milliseconds, when the host measured it.
    var modelMs: Double? = nil
    /// Validated logical calls in the whole reply, before bounding its cards.
    var toolCallCount: Int? = nil
    var taskRootID: String? = nil
    var taskExecutionID: String? = nil
    var presentationSourceID: String? = nil
    var operationID: String? = nil
    var responseTimeline: ResponseTimeline? = nil
    static func project(id: String, message: [String: WireValue]) -> TranscriptMessage {
        let stopReason = message["nativeStopReason"]?.string ?? message["stopReason"]?.string
        let content = message["content"], blocks = content?.array ?? []
        let text = content?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
        let thinking = blocks.compactMap { $0.object?["type"]?.string == "thinking" ? $0.object?["thinking"]?.string : nil }.joined()
        let role = message["role"]?.string ?? "system"
        let toolBlocks = blocks.filter { $0.object?["type"]?.string == "toolCall" }
        var result = TranscriptMessage(id: id, role: role == "toolResult" ? "tool" : ["user", "assistant", "system"].contains(role) ? role : "system", text: message["nativeDisplayText"]?.string ?? text, thinking: thinking,
                     tools: toolBlocks.compactMap { value in
            guard let block = value.object, block["type"]?.string == "toolCall", let toolID = block["id"]?.string else { return nil }
            // Preserve the complete parseable document for expanded details.
            let full = (block["arguments"] ?? .null).pretty
            let arguments = (text:full, truncated:false, bytes:full.utf8.count)
            return ToolView(id: String(toolID.prefix(256)), name: String((block["name"]?.string ?? "tool").prefix(256)), state: "recorded",
                            input: arguments.text, output: "", durationMs: nil, truncated: arguments.truncated,
                            inputTruncated: arguments.truncated ? true : nil, inputBytes: arguments.truncated ? arguments.bytes : nil)
        }, state: stopReason, truncated: false, stopReason: stopReason,
                     at: message["timestamp"]?.number, turn: message["nativeTurn"]?.string, modelMs: message["nativeModelMs"]?.number, toolCallCount: role == "assistant" ? toolBlocks.count : nil,
                     taskRootID: message["nativeTaskRoot"]?.string, taskExecutionID: message["nativeTaskExecution"]?.string)
        result.presentationSourceID = message["nativePresentationSourceID"]?.string
        result.operationID = message["nativeOperationID"]?.string ?? message["nativeCompaction"]?.object?["operationId"]?.string
        result.kind = message["nativeKind"]?.string
        if role == "toolResult" { result.kind="toolResult"; result.detail="Tool result · " + (message["toolName"]?.string ?? "tool") }
        result.detail = message["nativeDetail"]?.string ?? result.detail
        let parts: [(kind:String,text:String,callID:String?,name:String?)] = blocks.compactMap { part in
            let block=part.object ?? [:]
            switch block["type"]?.string {
            case "text": return ("text",block["text"]?.string ?? "",nil,nil)
            case "thinking": return ("reasoningText",block["thinking"]?.string ?? "",nil,nil)
            case "toolCall": return ("toolArguments",block["arguments"]?.pretty ?? "{}",block["id"]?.string,block["name"]?.string)
            default: return nil
            }
        }
        result.responseTimeline = message["nativeResponseTimeline"].flatMap { try? JSONDecoder().decode(ResponseTimeline.self, from: JSONEncoder().encode($0)) }?.restoringContent(parts, sourceID:id)
        if result.responseTimeline == nil, role == "assistant", content?.array != nil {
            result.responseTimeline = ResponseTimeline.canonical(parts,sourceID:id)
        }
        return result
    }
}

/// Reading the helper's display rows out of a frame that is already decoded.
///
/// The frame arrives as a `WireValue` tree. Handing those rows to Codable
/// meant encoding the tree back to JSON and parsing it a second time: 4.24 ms
/// for a 300-row page, on the path that opens a chat and the one that resyncs
/// it. Reading the same rows directly is 0.24 ms.
///
/// It is deliberately exact rather than lenient: anything it is not certain
/// about — a field of an unexpected type, a number that is not a whole number
/// where an integer belongs, an `accounting` block, which only the app adds —
/// makes it decline, and `page(_:)` falls back to Codable. Codable therefore
/// remains the contract in every case, and `TranscriptWirePageTests` holds the
/// two answers to being byte-for-byte identical.
extension TranscriptMessage {
    private enum Unexpected: Error { case shape }

    /// The rows of one `messages` array from the helper.
    static func page(_ value: WireValue) throws -> [TranscriptMessage] {
        if let rows = try? projected(value) { return rows }
        return try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))
    }
    /// Test seam: the projector on its own, so the tests can hold its answer
    /// against Codable's instead of only against the fallback.
    static func projected(_ value: WireValue) throws -> [TranscriptMessage] {
        guard let items = value.array else { throw Unexpected.shape }
        var rows: [TranscriptMessage] = []
        rows.reserveCapacity(items.count)
        for item in items { rows.append(try row(item)) }
        return rows
    }
    private static func row(_ value: WireValue) throws -> TranscriptMessage {
        guard let fields = value.object, (fields["accounting"] ?? .null) == .null else { throw Unexpected.shape }
        var row = TranscriptMessage(id: try string(fields["id"]), role: try string(fields["role"]), text: try string(fields["text"]))
        row.thinking = try optionalString(fields["thinking"])
        if let list = fields["tools"], list != .null {
            guard let cards = list.array else { throw Unexpected.shape }
            row.tools = try cards.map(tool)
        }
        row.state = try optionalString(fields["state"])
        row.truncated = try optionalBool(fields["truncated"])
        row.stopReason = try optionalString(fields["stopReason"])
        row.kind = try optionalString(fields["kind"])
        row.detail = try optionalString(fields["detail"])
        row.at = try optionalDouble(fields["at"])
        row.turn = try optionalString(fields["turn"])
        row.modelMs = try optionalDouble(fields["modelMs"])
        row.toolCallCount = try optionalInt(fields["toolCallCount"])
        row.taskRootID = try optionalString(fields["taskRootID"])
        row.taskExecutionID = try optionalString(fields["taskExecutionID"])
        row.presentationSourceID = try optionalString(fields["presentationSourceID"])
        row.operationID = try optionalString(fields["operationID"])
        if let timeline = fields["responseTimeline"], timeline != .null { row.responseTimeline = try JSONDecoder().decode(ResponseTimeline.self, from: JSONEncoder().encode(timeline)) }
        return row
    }
    private static func tool(_ value: WireValue) throws -> ToolView {
        guard let fields = value.object else { throw Unexpected.shape }
        return ToolView(id: try string(fields["id"]), name: try string(fields["name"]), state: try string(fields["state"]),
                        input: try string(fields["input"]), output: try string(fields["output"]),
                        durationMs: try optionalDouble(fields["durationMs"]), truncated: try bool(fields["truncated"]),
                        path: try optionalString(fields["path"]), added: try optionalInt(fields["added"]), removed: try optionalInt(fields["removed"]),
                        inputTruncated: try optionalBool(fields["inputTruncated"]), inputBytes: try optionalInt(fields["inputBytes"]))
    }
    // A key that is absent and a key that is null both read as nothing, which
    // is what Codable's decodeIfPresent does; a key of another type declines.
    private static func string(_ value: WireValue?) throws -> String {
        guard let text = value?.string else { throw Unexpected.shape }
        return text
    }
    private static func optionalString(_ value: WireValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try string(value)
    }
    private static func bool(_ value: WireValue?) throws -> Bool {
        guard let flag = value?.bool else { throw Unexpected.shape }
        return flag
    }
    private static func optionalBool(_ value: WireValue?) throws -> Bool? {
        guard let value, value != .null else { return nil }
        return try bool(value)
    }
    private static func optionalDouble(_ value: WireValue?) throws -> Double? {
        guard let value, value != .null else { return nil }
        guard let number = value.number else { throw Unexpected.shape }
        return number
    }
    private static func optionalInt(_ value: WireValue?) throws -> Int? {
        guard let number = try optionalDouble(value) else { return nil }
        guard let whole = Int(exactly: number) else { throw Unexpected.shape }
        return whole
    }
}
