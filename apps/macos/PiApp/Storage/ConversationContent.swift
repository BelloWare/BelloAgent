import Foundation

struct ContentHit: Codable, Sendable, Identifiable {
    var id: String; var position: Int; var preview: String
    /// How many times the query occurs in the record's text (nil from a
    /// source that does not count; read as one).
    var count: Int? = nil
    /// A receipt outside the captured page can already be drawn in a card.
    struct Drawing: Codable, Sendable { var messageID: String; var toolCallID: String }
    var drawing: Drawing? = nil
    var omittedOutputs: Set<String>? = nil
}
struct ContentSearch: Codable, Sendable { var hits: [ContentHit]; var total: Int; var next: Int?; var revision: String }
struct ContentCursor: Codable, Sendable { var index: Int; var offset: Int }
struct ContentPage: Codable, Sendable { var text: String; var next: ContentCursor? }

enum ConversationContent {
    /// The same normalized rows the transcript draws, indexed by retained
    /// source. A receipt in its call's card owns that card's output, not a
    /// second copy of it; hidden ledgers/checkpoints own no displayed text.
    struct Presentation {
        var rows: [String: [TranscriptItem]] = [:]
        private var results: [String: ToolView] = [:]
        private(set) var drawings: [String: ContentHit.Drawing] = [:]
        private var outputCalls: Set<String> = []
        private let fetchedInputs: [String: ToolInputDocument]
        init(_ messages: [TranscriptMessage], fetchedInputs: [String: ToolInputDocument] = [:]) {
            self.init(TaskTranscriptPlan.rows(messages, lifecycle: nil), messages: messages, fetchedInputs: fetchedInputs)
        }
        // Keep the large row values out of the planner's call frame on a
        // cooperative worker's small stack.
        private init(_ planned: [TranscriptItem], messages: [TranscriptMessage], fetchedInputs: [String: ToolInputDocument]) {
            self.fetchedInputs = fetchedInputs
            for message in messages { rows[message.id] = [] }
            var cards: [String: [ToolView]] = [:]
            for row in planned {
                switch row {
                case .message(let message): rows[message.id, default: []].append(row)
                case .block(let block):
                    for message in block.replies {
                        rows[message.id, default: []].append(row)
                        if message.role == "assistant" { cards[message.id, default: []] += message.tools ?? [] }
                    }
                }
            }
            var issuers: [String: (String, ToolView)] = [:], receipts: [String: String] = [:]
            for message in messages {
                for tool in cards[message.id] ?? [] { issuers[tool.id] = (message.id, tool) }
                guard message.role == "tool" || message.kind == "toolResult", rows[message.id]?.isEmpty == true,
                      let call = message.toolCallID, let (source, tool) = issuers[call] else { continue }
                let key = ToolOccurrence.key(source, call)
                if let earlier = receipts[key] { results.removeValue(forKey: earlier); drawings.removeValue(forKey: earlier) }
                receipts[key] = message.id; results[message.id] = tool; outputCalls.insert(key)
                drawings[message.id] = .init(messageID: source, toolCallID: call)
            }
        }
        func text(_ id: String, rawReply: Bool = false, toolInputs: [String: String] = [:]) -> String {
            if let tool = results[id] { return payload(tool, receipt: id).output }
            return transcriptText(rows[id] ?? [], rawReply: rawReply, omittingOutputs: outputCalls, toolInputs: toolInputs, fetchedInputs: fetchedInputs)
        }
        func parts(_ id: String, rawReply: Bool = false) -> [TextPart] {
            textParts(rows[id] ?? [], rawReply: rawReply, omittingOutputs: outputCalls)
        }
        private func payload(_ tool: ToolView, receipt: String) -> (input: String, output: String) {
            let fetched = drawings[receipt].flatMap { fetchedInputs[ToolOccurrence.key($0.messageID, $0.toolCallID)] }
            return toolPayload(tool, fetched: fetched)
        }
        func omittedOutputs(_ id: String) -> Set<String>? {
            let calls = Set(drawings.compactMap { receipt, owner -> String? in
                guard owner.messageID == id, let tool = results[receipt], !payload(tool, receipt: receipt).output.isEmpty else { return nil }
                return owner.toolCallID
            })
            return calls.isEmpty ? nil : calls
        }
    }
    /// Find is separate from retained-source search and Copy Conversation.
    static func transcriptText(_ entry: [String: WireValue], managedChild: Bool = false, rawReply: Bool = false) -> String {
        if entry["type"]?.string == "compaction" {
            return transcriptText(TranscriptMessage(id: entry["id"]?.string ?? "", role: "system", text: TranscriptMessage.compactionText(entry), kind: "compaction"))
        }
        let message = TranscriptMessage.project(id: entry["id"]?.string ?? "", message: entry["message"]?.object ?? [:])
        if managedChild, message.role == "user", message.nativeAgentDelivery == nil, message.kind != "agent_message" { return TranscriptMarkdown.renderedText(message.text) }
        return transcriptText(message, rawReply: rawReply)
    }
    /// Called by the history actor, never by a layout or paint pass.
    static func transcriptText(_ message: TranscriptMessage, rawReply: Bool = false) -> String {
        Presentation([message]).text(message.id, rawReply: rawReply)
    }
    /// Presentation belongs to the planner: a persisted system ledger may be
    /// an assistant response, with separate prose, reasoning and card rows.
    enum TextPart {
        case text(String)
        case tool(key: String, value: ToolView, inputOnly: Bool)
        func text(toolInputs: [String: String] = [:], fetchedInputs: [String: ToolInputDocument] = [:]) -> String {
            switch self {
            case .text(let text): return text
            case .tool(let key, let tool, let inputOnly):
                return toolInputs[key] ?? toolText(tool, inputOnly: inputOnly, fetched: fetchedInputs[key])
            }
        }
    }
    private static func transcriptText(_ rows: [TranscriptItem], rawReply: Bool = false, omittingOutputs: Set<String> = [], toolInputs: [String: String] = [:], fetchedInputs: [String: ToolInputDocument] = [:]) -> String {
        joined(textParts(rows, rawReply: rawReply, omittingOutputs: omittingOutputs).map { $0.text(toolInputs: toolInputs, fetchedInputs: fetchedInputs) })
    }
    /// Defer tool bodies so history search can consume the same planned text
    /// without collecting every large receipt in a work row into one string.
    private static func textParts(_ rows: [TranscriptItem], rawReply: Bool, omittingOutputs: Set<String>) -> [TextPart] {
        func tool(_ tool: ToolView, source: String) -> TextPart {
            let key = ToolOccurrence.key(source, tool.id)
            return .tool(key: key, value: tool, inputOnly: omittingOutputs.contains(key))
        }
        return rows.flatMap { row -> [TextPart] in
            switch row {
            case .message(let message): return [.text(messageText(message, rawReply: rawReply))]
            case .block(let block):
                if let part = block.part, let message = block.message {
                    if !["text", "refusal"].contains(part.part.kind), let call = part.part.callID,
                       let value = message.tools?.first(where: { $0.id == call }) { return [tool(value, source: message.id)] }
                    return [.text(partText(part, message: message, rawReply: rawReply))]
                }
                switch block.presentation {
                case .body, .reply: return [.text(block.message.map { replyText($0, raw: rawReply) } ?? "")]
                case .work:
                    return block.activity.flatMap { message in
                        [.text(TranscriptMarkdown.renderedText(message.thinking ?? "", style: .reasoning, streaming: message.isStreaming))]
                            + (message.tools ?? []).map { tool($0, source: message.id) }
                    }
                default: return []
                }
            }
        }
    }
    private static func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n") }
    private static func replyText(_ message: TranscriptMessage, raw: Bool) -> String {
        ReplySource.shows(message, raw: raw) ? message.text : TranscriptMarkdown.renderedText(message.text, streaming: message.isStreaming)
    }
    private static func partText(_ part: ResponseTimeline.Segment, message: TranscriptMessage, rawReply: Bool, omittingOutputs: Set<String> = [], toolInputs: [String: String] = [:], fetchedInputs: [String: ToolInputDocument] = [:]) -> String {
        let row = TranscriptTimelinePart(part: part, message: message)
        if ["text", "refusal"].contains(part.part.kind) { return replyText(row.source, raw: rawReply) }
        if let call = part.part.callID, let tool = message.tools?.first(where: { $0.id == call }) {
            if let input = toolInputs[ToolOccurrence.key(message.id, call)] { return input }
            let payload = toolPayload(tool, fetched: fetchedInputs[ToolOccurrence.key(message.id, call)])
            return omittingOutputs.contains(ToolOccurrence.key(message.id, call)) ? payload.input : joined([payload.input, payload.output])
        }
        if ["toolArguments", "status"].contains(part.part.kind) { return part.text }
        return TranscriptMarkdown.renderedText(part.text, style: row.reasoning ? .reasoning : .prose, streaming: row.source.isStreaming)
    }
    private static func messageText(_ message: TranscriptMessage, rawReply: Bool) -> String {
        func prose(_ source: String) -> String { TranscriptMarkdown.renderedText(source) }
        if message.nativeAgentDelivery != nil || message.kind == "agent_message" {
            let events = AgentMessagePresentation(message).events
            guard !events.isEmpty else { return AgentMessagePresentation.unavailable }
            return events.map { joined([$0.title, $0.label, prose($0.text), $0.note ?? ""]) }.joined(separator: "\n\n")
        }
        if message.kind == "toolResult" || message.role == "tool" { return prose(message.text) }
        if message.kind == "compaction" { return TranscriptMarkdown.renderedText(message.text, style: .summary) }
        if message.kind == "branch" { return message.detail ?? message.text }
        if message.kind == "failure" || message.kind == "versionBanner" { return joined([message.text, message.detail ?? ""]) }
        if message.kind == "requestInfo" { return joined([message.detail ?? "", TranscriptActivity.earlyEnd(message.stopReason) ?? ""]) }
        if message.kind == "execution" {
            let parts = message.responseTimeline.map { timeline in
                timeline.supported ? timeline.segments.map { partText($0, message: message, rawReply: rawReply) } : []
            } ?? []
            let unfinished = message.responseTimeline.map { $0.supported && $0.terminal == nil } ?? false
            return joined([message.detail ?? message.text] + parts + [unfinished ? TranscriptTimelinePart.completionNotRecorded : ""])
        }
        return message.role == "assistant" ? replyText(message, raw: rawReply) : message.text
    }
    /// Search the native card's payload, keeping its file/agent label. The
    /// argument envelope is not the command, diff or formatted JSON it draws.
    static func toolText(_ tool: ToolView, inputOnly: Bool = false, fetched: ToolInputDocument? = nil) -> String {
        let payload = toolPayload(tool, fetched: fetched)
        return inputOnly ? payload.input : joined([payload.input, payload.output])
    }
    static func toolText(_ card: TranscriptToolRow.Card, heading: String? = nil, summary: String? = nil) -> String {
        let payload = toolPayload(card, heading: heading, summary: summary)
        return joined([payload.input, payload.output])
    }
    static func toolPayload(_ tool: ToolView, fetched: ToolInputDocument? = nil) -> (input: String, output: String) {
        let model = TranscriptToolRow.model(of: tool)
        // Conversation panes always enable the file opener. The I/O fallback
        // draws its path header only when that opener has a file to link.
        // Fetched arguments replace the body; the work line keeps this model.
        let heading = [model.title, model.summary].filter { !$0.isEmpty }.joined(separator: " · ")
        return toolPayload(TranscriptToolRow.card(of: tool, fetched: fetched, model: model, linked: model.file != nil), heading: heading, summary: tool.output.isEmpty ? nil : model.summary)
    }
    private static func toolPayload(_ card: TranscriptToolRow.Card, heading: String? = nil, summary: String? = nil) -> (input: String, output: String) {
        switch card {
        case .io(let path, let input, let output, _, _): return (joined([path ?? "", input]), output ?? "")
        case .terminal(let command, let output, _): return (command, output)
        case .read(let text, _, let path, _):
            let window = TranscriptReadCardText.window(of: text)
            return (path ?? "", joined([window.lines.joined(separator: "\n"), window.note ?? ""]))
        case .diff(let request, let path, let outcome, _, _):
            let text = request.tooLarge ? joined(request.mode == "edit" ? [request.before, request.after] : [request.after])
                : request.rows.map(\.text).joined(separator: "\n")
            return (joined([path ?? "", text]), outcome == .failed ? summary ?? "" : "")
        case .subagent(let value):
            return (joined([heading ?? value.title, TranscriptMarkdown.renderedText(value.task)]), joined([TranscriptMarkdown.renderedText(value.result), value.error ?? ""]))
        }
    }
    /// Case-insensitive occurrences of `query` in `text`, as the find bar
    /// and the content search count them.
    static func occurrences(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0, from = text.startIndex
        while let found = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
            count += 1; from = found.upperBound
        }
        return count
    }
    /// The query, lowercased, when it is ASCII alone: what `excludes` can
    /// decide about.
    static func asciiNeedle(_ query: String) -> [UInt8]? {
        var needle: [UInt8] = []
        for byte in query.utf8 {
            guard byte < 0x80 else { return nil }
            needle.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
        }
        return needle.isEmpty ? nil : needle
    }
    /// Whether `text` certainly does not contain the ASCII `needle`, case
    /// insensitively: true only for a text that is ASCII alone and does not
    /// hold it. Swift's case-insensitive `range(of:)` walks a long text a
    /// character at a time and was nearly all a search of a long chat cost;
    /// over ASCII alone the two agree exactly, and any other text is left to
    /// `range(of:)` (a non-ASCII character can fold to ASCII letters).
    static func excludes(_ needle: [UInt8], from text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let count = bytes.count, length = needle.count
            for byte in bytes where byte >= 0x80 { return false }
            guard count >= length else { return true }
            let first = needle[0]
            var at = 0
            while at <= count - length {
                let byte = bytes[at]
                if (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) == first {
                    var matched = 1
                    while matched < length {
                        let next = bytes[at + matched]
                        guard (next >= 0x41 && next <= 0x5A ? next | 0x20 : next) == needle[matched] else { break }
                        matched += 1
                    }
                    if matched == length { return false }
                }
                at += 1
            }
            return true
        }
    }
    static func text(_ entry: [String: WireValue]) -> String {
        if entry["type"]?.string == "compaction" { return "## Compaction\n\n\(entry["summary"]?.string ?? "")\n\n" }
        let message = entry["message"]?.object ?? [:], content = message["content"]
        let timeline = message["nativeResponseTimeline"].flatMap { try? JSONDecoder().decode(ResponseTimeline.self, from: JSONEncoder().encode($0)) }
        if let timeline, timeline.supported {
            let title = message["nativeDetail"]?.string ?? message["role"]?.string ?? "Operation"
            let evidence = "## \(title)\n\n" + timeline.retainedText + "\n\n"
            // If a source exceeds retained event bounds, preserve the original
            // complete canonical content too, explicitly separate from arrival order.
            if !timeline.segments.contains(where: \.truncated) && timeline.omittedEvents == 0 { return evidence }
            var canonical = entry
            var plain = message; plain.removeValue(forKey: "nativeResponseTimeline")
            canonical["message"] = .object(plain)
            return evidence + "## Full saved response\n\n" + text(canonical)
        }
        let body = content?.string ?? (content?.array ?? []).map { value -> String in
            let block = value.object ?? [:]
            switch block["type"]?.string {
            case "text": return block["text"]?.string ?? ""
            case "thinking": return "\n[Exposed reasoning]\n\(block["thinking"]?.string ?? "")\n"
            case "toolCall": return "\n[Tool \(block["name"]?.string ?? "tool")]\n\(block["arguments"]?.pretty ?? "{}")\n"
            case "image": return "\n[Image attachment omitted]\n"
            default: return ""
            }
        }.joined()
        return "## \(message["role"]?.string ?? "system")\n\n\(body)\n\n"
    }
}
