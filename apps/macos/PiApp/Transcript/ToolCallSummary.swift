import Foundation

/// Counts issued calls, never paths, results or argument deltas. Row identity
/// scopes provider call ids: two responses may legitimately reuse an id.
struct ToolCallSummary: Equatable, Sendable {
    var total = 0
    var failed = 0
    var skipped = 0
    var uncertain = 0
    var preparing = false
    var partial = false

    init(rows: [TranscriptMessage]) {
        var owners = Set<String>()
        for row in rows where row.role == "assistant" && owners.insert(row.id).inserted {
            let cards = row.tools ?? []
            let confirmed = cards.filter { $0.state != "preparing" }
            if let count = row.toolCallCount, count >= 0 { total += count }
            else { total += confirmed.count; partial = partial || row.truncated == true }
            preparing = preparing || cards.contains { $0.state == "preparing" }
            for card in confirmed {
                switch card.state {
                case "failed": failed += 1
                case "cancelled", "skipped": skipped += 1
                case "recorded", "unknown", "interrupted": uncertain += 1
                default: break
                }
            }
        }
    }
    init(tools: [ToolView]) { self.init(rows: [.init(id: "summary", role: "assistant", text: "", tools: tools)]) }
    var label: String? { label(reasoned: false) }
    func label(reasoned: Bool) -> String? {
        var parts: [String] = reasoned ? ["Reasoned"] : []
        if total > 0 { parts.append((partial ? "at least " : "") + "\(total) tool " + (total == 1 ? "call" : "calls")) }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if uncertain > 0 { parts.append("\(uncertain) outcome unknown") }
        if preparing { parts.append("Preparing tool call…") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
