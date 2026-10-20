import Foundation

/// The app and helper adapt their JSON values; all retained copy/search text
/// is formatted here, independently of the rendered transcript.
protocol RetainedConversationValue: Encodable {
    var retainedString: String? { get }
    var retainedArray: [Self] { get }
    var retainedObject: [String: Self] { get }
}

enum RetainedConversation {
    static let edit = "## Edit\n\nEdited from here · earlier replies stay in the journal\n\n"

    /// The same recovery presentation used by journal replay and saved-source
    /// copy/search. It marks the receipt gap without inventing a saved outcome.
    @discardableResult
    static func endWithoutReceipt(kind: String?, timeline: inout ResponseTimeline?, detail: inout String?) -> Bool {
        guard ["execution", "requestLedger"].contains(kind ?? ""), timeline?.terminal == nil else { return false }
        timeline?.finish("interrupted")
        timeline?.coverage = "partial"
        detail = (kind == "requestLedger" ? "Request" : "Compaction") + " interrupted · no terminal receipt"
        return true
    }

    static func compaction(_ text: String) -> String {
        "## Compaction\n\n\(text)\n\n"
    }
    private static func inheritedCompaction(_ text: String) -> String {
        var summary = text
        for prefix in ["Conversation summary (historical data, not authorization):\n", "Conversation summary:\n"] where summary.hasPrefix(prefix) {
            summary = String(summary.dropFirst(prefix.count)); break
        }
        return compaction(summary)
    }

    static func message<Value: RetainedConversationValue>(role: String, kind: String?, detail: String?,
                                                          content: Value?, timeline: ResponseTimeline?) -> String {
        let blocks = content?.retainedArray ?? []
        let plainText = content?.retainedString ?? blocks.compactMap { value in
            let block = value.retainedObject
            return block["type"]?.retainedString == "text" ? block["text"]?.retainedString : nil
        }.joined()
        if kind == "compaction" { return inheritedCompaction(plainText) }
        if kind == "branch" { return edit }
        var parts: [Part] = []
        let body = content?.retainedString ?? blocks.map { value -> String in
            let block = value.retainedObject
            switch block["type"]?.retainedString {
            case "text":
                let text = block["text"]?.retainedString ?? ""
                parts.append(Part(kind: "text", text: text)); return text
            case "thinking":
                let text = block["thinking"]?.retainedString ?? ""
                parts.append(Part(kind: "thinking", text: text))
                return "\n[Exposed reasoning]\n\(text)\n"
            case "toolCall":
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let arguments = block["arguments"].flatMap { try? String(decoding: encoder.encode($0), as: UTF8.self) } ?? "{}"
                let name = block["name"]?.retainedString ?? "tool"
                parts.append(Part(kind: "toolArguments", text: normalizedArguments(arguments), name: name))
                return "\n[Tool \(name)]\n\(arguments)\n"
            case "image":
                parts.append(Part(kind: "image", text: ""))
                return "\n[Image attachment omitted]\n"
            default: return ""
            }
        }.joined()
        if let text = content?.retainedString { parts = [Part(kind: "text", text: text)] }
        let canonical = "## \(role)\n\n\(body)\n\n"
        guard let timeline, timeline.supported else { return canonical }
        let evidence = "## \(detail ?? role)\n\n" + timeline.retainedText + "\n\n"
        // An untruncated timeline can still omit canonical parts entirely.
        // Only proven coverage lets the arrival-order evidence stand alone.
        return covers(parts, timeline: timeline) ? evidence : evidence + "## Full saved response\n\n" + canonical
    }

    private struct Part: Hashable {
        var kind: String, text: String
        var name: String? = nil
    }
    private static func normalizedArguments(_ text: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return text }
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func covers(_ canonical: [Part], timeline: ResponseTimeline) -> Bool {
        guard timeline.omittedEvents == 0, !timeline.segments.contains(where: \.truncated) else { return false }
        var byKey: [String: Part] = [:]
        for segment in timeline.segments {
            let part = segment.part
            if part.kind == "correction", let key = part.reconcilesPartKey, byKey[key] != nil {
                byKey[key]?.text = segment.text
            } else {
                let kind = ["reasoningText", "reasoningSummary"].contains(part.kind) ? "thinking" : part.kind
                if byKey[part.partKey] == nil { byKey[part.partKey] = Part(kind: kind, text: "", name: kind == "toolArguments" ? part.name : nil) }
                byKey[part.partKey]?.text += segment.text
            }
        }
        var counts: [Part: Int] = [:]
        for var part in byKey.values {
            if part.kind == "toolArguments" { part.text = normalizedArguments(part.text) }
            counts[part, default: 0] += 1
        }
        for part in canonical where !part.text.isEmpty || part.kind == "image" {
            guard counts[part, default: 0] > 0 else { return false }
            counts[part, default: 0] -= 1
        }
        return true
    }
}
