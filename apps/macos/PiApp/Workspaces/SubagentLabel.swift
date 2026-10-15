import Foundation

/// Presentation only. IDs, saved descriptions and model-facing receipts stay
/// unchanged. A missing parent has no guessed ordinal; retain a known cache.
enum SubagentLabel {
    static func name(_ number: Int?) -> String {
        "Sub-agent" + (number.flatMap { $0 > 0 ? " \($0)" : nil } ?? "")
    }
    static func title(_ number: Int?, _ description: String) -> String {
        name(number) + (description.isEmpty ? "" : " · " + description)
    }
}

extension ChatRecord {
    var displayTitle: String { isSubagent ? SubagentLabel.title(subagentNumber, title) : title }
    var subagentName: String { SubagentLabel.name(subagentNumber) }
}
