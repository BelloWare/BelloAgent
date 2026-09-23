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
    /// Tool result rows: the call this result belongs to. The reply that made
    /// the call carries the same result in its card, so a chronological
    /// transcript shows it once, at the call, instead of twice.
    var toolCallID: String? = nil
    var responseTimeline: ResponseTimeline? = nil
    /// Display only, set by the planner: the finished turn whose fold hides
    /// this row. Never read from or written to a journal — the projector
    /// leaves it nil and an absent optional encodes to nothing.
    var foldGroup: String? = nil
    /// User rows: the skills the message was sent with, in the order the
    /// model received them ahead of its text. Nil when it used none.
    var skills: [TranscriptSkillUse]? = nil
    /// Assistant rows: what the helper recorded of the request the row came
    /// from. The turn report reads it for a request the request log has no
    /// row for. Nil from helpers before 0.1.88 and for rows it has no record of.
    var reply: ReplyRecord? = nil
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
        if role == "toolResult" {
            result.kind="toolResult"; result.detail="Tool result · " + (message["toolName"]?.string ?? "tool")
            result.toolCallID = message["toolCallId"]?.string
        }
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
        if role == "user" { result.skills = TranscriptSkillUse.recorded(message["nativeUserInput"]?.object?["skills"]) }
        if role == "assistant" { result.reply = ReplyRecord.journaled(message) }
        return result
    }
}

/// One reply's request as the helper recorded it, in the shape its display
/// rows carry: the attempt, the alias the request named, every model name
/// the gateway reported with where it came from, and the usage in pi's
/// shape, whose `input` leaves out cache reads and writes.
struct ReplyRecord: Codable, Sendable, Equatable {
    struct Report: Codable, Sendable, Equatable { var name: String; var source: String }
    struct Usage: Codable, Sendable, Equatable {
        var input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil, totalTokens: Double? = nil
    }
    var attempt: String? = nil
    var requested: String? = nil
    var models: [Report]? = nil
    var usage: Usage? = nil

    /// What answered: the response body's name, as the request log reads it.
    var model: String? { GatewayModelIdentity.answered((models ?? []).map { GatewayModelIdentity.Report(name: $0.name, source: $0.source) }) }
    /// A header's name when it disagrees with the body's.
    var routedVia: String? { GatewayModelIdentity.routedVia((models ?? []).filter { $0.source.hasPrefix("header:") }.map(\.name), answered: model) }
    /// Input as the gateway counts it, cache reads and writes included.
    var input: Double? {
        guard let usage, let input = TranscriptActivity.reported(usage.input) else { return nil }
        return input + (TranscriptActivity.reported(usage.cacheRead) ?? 0) + (TranscriptActivity.reported(usage.cacheWrite) ?? 0)
    }
    var cached: Double? { usage.flatMap { TranscriptActivity.reported($0.cacheRead) } }
    var output: Double? { usage.flatMap { TranscriptActivity.reported($0.output) } }

    /// The same record read from a journal row: `usage`, the routing
    /// identity's model evidence and the request's attempt id.
    static func journaled(_ row: [String: WireValue]) -> ReplyRecord? {
        let identity = row["nativeProviderIdentity"]?.object ?? [:]
        var record = ReplyRecord(attempt: row["nativeRequestAttemptIds"]?.array?.first?.string,
                                 requested: GatewayModelIdentity.modelName(identity["requestedAlias"]?.string))
        let reports = (identity["evidence"]?.array ?? []).compactMap { value -> Report? in
            guard let item = value.object, item["kind"]?.string == "model", let name = GatewayModelIdentity.modelName(item["value"]?.string),
                  let source = item["source"]?.string else { return nil }
            return Report(name: name, source: source)
        }
        if !reports.isEmpty { record.models = Array(reports.prefix(8)) }
        if let usage = row["usage"]?.object, !usage.isEmpty {
            record.usage = Usage(input: usage["input"]?.number, output: usage["output"]?.number, cacheRead: usage["cacheRead"]?.number,
                                 cacheWrite: usage["cacheWrite"]?.number, totalTokens: usage["totalTokens"]?.number)
        }
        return record == ReplyRecord() ? nil : record
    }
}

extension TranscriptMessage {
    /// Display only: the state of a message the reader has sent that the
    /// helper has not shown yet (`SessionDisplay.sendingRows`). The helper's
    /// own row for it has the same id, the submission's `clientTurnId`, and
    /// takes its place when it arrives.
    static let sendingState = "sending"
    var isSending: Bool { role == "user" && state == Self.sendingState }
}

/// What a journal recorded about one finished call: the helper writes this
/// beside the result row, and a live snapshot folds the same fields into the
/// card of the reply that made the call.
struct ToolResultRecord: Sendable, Equatable {
    var output: String
    var isError: Bool
    var durationMs: Double? = nil
    var path: String? = nil
    var added: Int? = nil
    var removed: Int? = nil
    /// What the helper recorded became of the call: "completed", "failed",
    /// "not_executed" or "unknown". Journals from before it recorded one
    /// leave it nil.
    var outcome: String? = nil
    /// The card this record reads as — the helper's own reading of a saved
    /// result (`AgentSession.cardState`): the recorded outcome decides, and a
    /// journal without one keeps its isError reading. A call stopped while it
    /// ran is "unknown", never "failed"; one that never ran is "cancelled".
    var cardState: String {
        switch outcome {
        case "completed"?: return "completed"
        case "unknown"?: return "unknown"
        case "not_executed"?: return "cancelled"
        case "failed"?: return "failed"
        default: return isError ? "failed" : "completed"
        }
    }
    /// The record as it sits in a journal's message row, or nil when the row
    /// is not a tool result or names no call.
    static func of(_ message: [String: WireValue]) -> (call: String, record: ToolResultRecord)? {
        guard message["role"]?.string == "toolResult", let call = message["toolCallId"]?.string else { return nil }
        let blocks = message["content"]?.array ?? []
        let output = message["content"]?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
        let stats = message["nativeToolStats"]?.object ?? [:]
        func whole(_ value: WireValue?) -> Int? { value?.number.flatMap { Int(exactly: $0) } }
        return (call, ToolResultRecord(output: output, isError: message["isError"]?.bool ?? false,
                                       durationMs: stats["durationMs"]?.number, path: stats["path"]?.string,
                                       added: whole(stats["added"]), removed: whole(stats["removed"]), outcome: stats["outcome"]?.string))
    }
}

extension TranscriptMessage {
    /// Fills each reply's cards from the results recorded for its calls, so a
    /// chat read from a journal shows the same card as a live one: the call,
    /// its outcome, its clock and its output in one place. A call with no
    /// recorded result keeps the "recorded" card it was projected with, and
    /// its result row — if the page holds one — stays where it is.
    ///
    /// `results` are keyed by the id of the result's own row. Providers reuse
    /// call ids, so a result belongs to the latest reply before it on the page
    /// that made its call — the owner the helper pairs it with — and fills that
    /// one card. A result whose reply is on another page fills nothing.
    static func resolvingToolResults(_ rows: [TranscriptMessage], results: [String: ToolResultRecord]) -> [TranscriptMessage] {
        guard !results.isEmpty else { return rows }
        var issuers: [String: Int] = [:], owned: [Int: [String: ToolResultRecord]] = [:]
        for (index, row) in rows.enumerated() {
            if row.role == "assistant" { for tool in row.tools ?? [] { issuers[tool.id] = index } }
            else if let result = results[row.id], let call = row.toolCallID, let owner = issuers[call] { owned[owner, default: [:]][call] = result }
        }
        guard !owned.isEmpty else { return rows }
        var resolved = rows
        for (index, records) in owned {
            resolved[index].tools = resolved[index].tools?.map { tool in
                guard tool.state == "recorded", let result = records[tool.id] else { return tool }
                var card = tool
                card.state = result.cardState
                card.output = result.output
                card.durationMs = result.durationMs
                card.path = result.path; card.added = result.added; card.removed = result.removed
                return card
            }
        }
        return resolved
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
        row.toolCallID = try optionalString(fields["toolCallID"])
        if let timeline = fields["responseTimeline"], timeline != .null { row.responseTimeline = try JSONDecoder().decode(ResponseTimeline.self, from: JSONEncoder().encode(timeline)) }
        if let list = fields["skills"], list != .null {
            guard let skills = list.array else { throw Unexpected.shape }
            row.skills = try skills.map(skill)
        }
        row.reply = try reply(fields["reply"])
        return row
    }
    private static func reply(_ value: WireValue?) throws -> ReplyRecord? {
        guard let value, value != .null else { return nil }
        guard let fields = value.object else { throw Unexpected.shape }
        var record = ReplyRecord(attempt: try optionalString(fields["attempt"]), requested: try optionalString(fields["requested"]))
        if let list = fields["models"], list != .null {
            guard let items = list.array else { throw Unexpected.shape }
            record.models = try items.map {
                guard let report = $0.object else { throw Unexpected.shape }
                return ReplyRecord.Report(name: try string(report["name"]), source: try string(report["source"]))
            }
        }
        if let usage = fields["usage"], usage != .null {
            guard let u = usage.object else { throw Unexpected.shape }
            record.usage = ReplyRecord.Usage(input: try optionalDouble(u["input"]), output: try optionalDouble(u["output"]), cacheRead: try optionalDouble(u["cacheRead"]),
                                             cacheWrite: try optionalDouble(u["cacheWrite"]), totalTokens: try optionalDouble(u["totalTokens"]))
        }
        return record
    }
    private static func skill(_ value: WireValue) throws -> TranscriptSkillUse {
        guard let fields = value.object else { throw Unexpected.shape }
        return TranscriptSkillUse(id: try string(fields["id"]), name: try string(fields["name"]), path: try string(fields["path"]),
                                  contentHash: try string(fields["contentHash"]), metadataHash: try string(fields["metadataHash"]),
                                  arguments: try string(fields["arguments"]), description: try optionalString(fields["description"]),
                                  scope: try optionalString(fields["scope"]), policy: try optionalString(fields["policy"]))
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
