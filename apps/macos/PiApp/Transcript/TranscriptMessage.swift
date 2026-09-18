import Foundation
struct TranscriptAnchor: Codable, Sendable, Equatable { var id: String; var offset: Double; var followsBottom: Bool }

struct ToolView: Codable, Sendable, Equatable, Identifiable {
    var id: String; var name: String; var state: String; var input: String; var output: String; var durationMs: Double?; var truncated: Bool
    /// File tools: resolved path and approximate line counts, from the host.
    var path: String? = nil; var added: Int? = nil; var removed: Int? = nil
}
struct TranscriptMessage: Codable, Sendable, Identifiable, Equatable {
    var id: String; var role: String; var text: String
    var thinking: String? = nil; var tools: [ToolView]? = nil; var state: String? = nil; var truncated: Bool? = nil
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
    private static func bounded(_ text: String, bytes: Int) -> String {
        var prefix = Data(text.utf8.prefix(bytes))
        while !prefix.isEmpty { if let value = String(data: prefix, encoding: .utf8) { return value }; prefix.removeLast() }
        return ""
    }
    static func project(id: String, message: [String: WireValue]) -> TranscriptMessage {
        let content = message["content"], blocks = content?.array ?? []
        let text = content?.string ?? blocks.compactMap { $0.object?["type"]?.string == "text" ? $0.object?["text"]?.string : nil }.joined()
        let thinking = blocks.compactMap { $0.object?["type"]?.string == "thinking" ? $0.object?["thinking"]?.string : nil }.joined()
        let role = message["role"]?.string ?? "system"
        let toolBlocks = blocks.filter { $0.object?["type"]?.string == "toolCall" }
        return .init(id: id, role: role == "toolResult" ? "tool" : ["user", "assistant", "system"].contains(role) ? role : "system", text: bounded(text, bytes: 16_384), thinking: bounded(thinking, bytes: 8192),
                     tools: toolBlocks.prefix(32).compactMap { value in
            guard let block = value.object, block["type"]?.string == "toolCall", let toolID = block["id"]?.string else { return nil }
            let input = (try? JSONEncoder().encode(block["arguments"] ?? .null)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ToolView(id: String(toolID.prefix(256)), name: String((block["name"]?.string ?? "tool").prefix(256)), state: "recorded", input: bounded(input, bytes: 4096), output: "", durationMs: nil, truncated: input.utf8.count > 4096)
        }, state: message["stopReason"]?.string, truncated: text.utf8.count > 16_384 || thinking.utf8.count > 8192 || toolBlocks.count > 32,
                     at: message["timestamp"]?.number, turn: message["nativeTurn"]?.string, modelMs: message["nativeModelMs"]?.number)
    }
}
