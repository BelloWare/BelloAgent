import Foundation

struct ContentHit: Codable, Sendable, Identifiable { var id: String; var position: Int; var preview: String }
struct ContentSearch: Codable, Sendable { var hits: [ContentHit]; var total: Int; var next: Int?; var revision: String }
struct ContentCursor: Codable, Sendable { var index: Int; var offset: Int }
struct ContentPage: Codable, Sendable { var text: String; var next: ContentCursor? }

enum ConversationContent {
    static func text(_ entry: [String: WireValue]) -> String {
        if entry["type"]?.string == "compaction" { return "## Compaction\n\n\(entry["summary"]?.string ?? "")\n\n" }
        let message = entry["message"]?.object ?? [:], content = message["content"]
        let timeline = message["nativeResponseTimeline"].flatMap { try? JSONDecoder().decode(ResponseTimeline.self, from: JSONEncoder().encode($0)) }
        if let timeline {
            let title = message["nativeDetail"]?.string ?? message["role"]?.string ?? "Operation"
            let evidence = "## \(title)\n\n" + timeline.retainedText + "\n\n"
            // If a source exceeds retained event bounds, preserve the original
            // complete canonical content too, explicitly separate from arrival order.
            if !timeline.segments.contains(where: \.truncated) && timeline.omittedEvents == 0 { return evidence }
            var canonical = entry
            var plain = message; plain.removeValue(forKey: "nativeResponseTimeline")
            canonical["message"] = .object(plain)
            return evidence + "## Canonical retained content (arrival order unavailable)\n\n" + text(canonical)
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
