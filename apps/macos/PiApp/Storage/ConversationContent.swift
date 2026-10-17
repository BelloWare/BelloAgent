import Foundation

struct ContentHit: Codable, Sendable, Identifiable {
    var id: String; var position: Int; var preview: String
    /// How many times the query occurs in the record's text (nil from a
    /// source that does not count; read as one).
    var count: Int? = nil
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
        private var outputCalls: Set<String> = []
        init(_ messages: [TranscriptMessage]) {
            self.init(TaskTranscriptPlan.rows(messages, lifecycle: nil), messages: messages)
        }
        // Keep the large row values out of the planner's call frame on a
        // cooperative worker's small stack.
        private init(_ planned: [TranscriptItem], messages: [TranscriptMessage]) {
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
                if let earlier = receipts[key] { results.removeValue(forKey: earlier) }
                receipts[key] = message.id; results[message.id] = tool; outputCalls.insert(key)
            }
        }
        func text(_ id: String, rawReply: Bool = false, toolInputs: [String: String] = [:]) -> String {
            if let tool = results[id] { return toolPayload(tool).output }
            return transcriptText(rows[id] ?? [], rawReply: rawReply, omittingOutputs: outputCalls, toolInputs: toolInputs)
        }
    }
    /// Find is separate from retained-source search and Copy Conversation.
    static func transcriptText(_ entry: [String: WireValue], managedChild: Bool = false, rawReply: Bool = false) -> String {
        if entry["type"]?.string == "compaction" {
            return transcriptText(TranscriptMessage(id: entry["id"]?.string ?? "", role: "system", text: TranscriptMessage.compactionText(entry), kind: "compaction"))
        }
        let message = TranscriptMessage.project(id: entry["id"]?.string ?? "", message: entry["message"]?.object ?? [:])
        if managedChild, message.role == "user" { return TranscriptMarkdown.renderedText(message.text) }
        return transcriptText(message, rawReply: rawReply)
    }
    /// Called by the history actor, never by a layout or paint pass.
    static func transcriptText(_ message: TranscriptMessage, rawReply: Bool = false) -> String {
        Presentation([message]).text(message.id, rawReply: rawReply)
    }
    /// Presentation belongs to the planner: a persisted system ledger may be
    /// an assistant response, with separate prose, reasoning and card rows.
    private static func transcriptText(_ rows: [TranscriptItem], rawReply: Bool = false, omittingOutputs: Set<String> = [], toolInputs: [String: String] = [:]) -> String {
        joined(rows.map { row in
            switch row {
            case .message(let message): return messageText(message, rawReply: rawReply)
            case .block(let block):
                if let part = block.part, let message = block.message {
                    return partText(part, message: message, rawReply: rawReply, omittingOutputs: omittingOutputs, toolInputs: toolInputs)
                }
                switch block.presentation {
                case .body, .reply: return block.message.map { replyText($0, raw: rawReply) } ?? ""
                case .work:
                    return joined(block.activity.flatMap { message in
                        [TranscriptMarkdown.renderedText(message.thinking ?? "", style: .reasoning, streaming: message.isStreaming)]
                            + (message.tools ?? []).map { tool in
                                if let input = toolInputs[ToolOccurrence.key(message.id, tool.id)] { return input }
                                let payload = toolPayload(tool)
                                return omittingOutputs.contains(ToolOccurrence.key(message.id, tool.id)) ? payload.input : joined([payload.input, payload.output])
                            }
                    })
                default: return ""
                }
            }
        })
    }
    private static func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n") }
    private static func replyText(_ message: TranscriptMessage, raw: Bool) -> String {
        ReplySource.shows(message, raw: raw) ? message.text : TranscriptMarkdown.renderedText(message.text, streaming: message.isStreaming)
    }
    private static func partText(_ part: ResponseTimeline.Segment, message: TranscriptMessage, rawReply: Bool, omittingOutputs: Set<String> = [], toolInputs: [String: String] = [:]) -> String {
        let row = TranscriptTimelinePart(part: part, message: message)
        if ["text", "refusal"].contains(part.part.kind) { return replyText(row.source, raw: rawReply) }
        if let call = part.part.callID, let tool = message.tools?.first(where: { $0.id == call }) {
            if let input = toolInputs[ToolOccurrence.key(message.id, call)] { return input }
            let payload = toolPayload(tool)
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
    static func toolText(_ tool: ToolView, inputOnly: Bool = false) -> String {
        let payload = toolPayload(tool)
        return inputOnly ? payload.input : joined([payload.input, payload.output])
    }
    private static func toolPayload(_ tool: ToolView) -> (input: String, output: String) {
        switch TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) {
        case .io(_, let input, let output, _, _): return (input, output ?? "")
        case .terminal(let command, let output, _): return (command, output)
        case .read(let text, _, let path, _):
            let window = TranscriptReadCardText.window(of: text)
            return (path ?? "", joined([window.lines.joined(separator: "\n"), window.note ?? ""]))
        case .diff(let request, let path, _, _, _):
            let text = request.tooLarge ? joined(request.mode == "edit" ? [request.before, request.after] : [request.after])
                : request.rows.map(\.text).joined(separator: "\n")
            return (joined([path ?? "", text]), "")
        case .subagent(let value):
            return (joined([value.title, TranscriptMarkdown.renderedText(value.task)]), joined([TranscriptMarkdown.renderedText(value.result), value.error ?? ""]))
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
