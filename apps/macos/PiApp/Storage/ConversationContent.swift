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
    /// Find's display projection is separate from retained-source search and
    /// Copy Conversation. Tool receipts keep their own record identity, even
    /// when the transcript draws their prose in the issuing call's card.
    static func transcriptText(_ entry: [String: WireValue], managedChild: Bool = false) -> String {
        let message = entry["message"]?.object ?? [:]
        func prose(_ source: String) -> String { TranscriptMarkdown.plainText(TranscriptMarkdown.blocks(source)) }
        if message["nativeAgentDelivery"]?.object != nil {
            return transcriptText(.project(id: entry["id"]?.string ?? "", message: message))
        }
        if managedChild, message["role"]?.string == "user" {
            return prose(TranscriptMessage.project(id: "", message: message).text)
        }
        if let name = message["toolName"]?.string, SubagentToolView.isControl(name), let result = ToolResultRecord.of(message) {
            let value = SubagentToolView(ToolView(id: result.call, name: name, state: result.record.cardState, input: "", output: result.record.output, durationMs: nil, truncated: false))
            return [prose(value.result), value.error ?? ""].joined(separator: "\n")
        }
        let blocks = message["content"]?.array ?? []
        guard blocks.contains(where: { $0.object?["type"]?.string == "toolCall" && SubagentToolView.isControl($0.object?["name"]?.string ?? "") }) else {
            return text(entry)
        }
        var plain = message
        // Preserve ordinary text/tools, but replace agent argument envelopes
        // with exactly the Task/Message prose drawn by the native card.
        plain.removeValue(forKey: "nativeResponseTimeline")
        plain["content"] = .array(blocks.map { block in
            guard let fields = block.object, fields["type"]?.string == "toolCall", let name = fields["name"]?.string, SubagentToolView.isControl(name) else { return block }
            let value = SubagentToolView(ToolView(id: fields["id"]?.string ?? "", name: name, state: "recorded", input: ToolInputDisplay.encoded(fields["arguments"] ?? .null), output: "", durationMs: nil, truncated: false))
            return .object(["type": .string("text"), "text": .string("\n" + value.title + "\n" + prose(value.task) + "\n")])
        })
        var projected = entry; projected["message"] = .object(plain)
        return text(projected)
    }
    /// Current streaming text and rows that have not reached the journal yet.
    /// Called by the history actor, never by a layout or paint pass.
    static func transcriptText(_ message: TranscriptMessage) -> String {
        func prose(_ source: String) -> String { TranscriptMarkdown.plainText(TranscriptMarkdown.blocks(source)) }
        if message.nativeAgentDelivery != nil {
            return AgentMessagePresentation(message).events.map {
                [$0.title, $0.label, prose($0.text), $0.note ?? ""].joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        let tools = (message.tools ?? []).map { tool in
            guard SubagentToolView.isControl(tool.name) else { return [tool.input, tool.output].joined(separator: "\n") }
            let value = SubagentToolView(tool)
            return [value.title, prose(value.task), prose(value.result), value.error ?? ""].joined(separator: "\n")
        }
        return ([message.text, message.thinking ?? ""] + tools).joined(separator: "\n")
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
