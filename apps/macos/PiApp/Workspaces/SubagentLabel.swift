import Foundation

/// Presentation only. IDs, saved descriptions and model-facing receipts stay
/// unchanged. A missing parent has no guessed ordinal; retain a known cache.
enum SubagentLabel {
    static func task(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "/root" { return "main" }
        let name = value.hasPrefix("/root/") ? String(value.dropFirst(6)) : value
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return name
    }
    static func name(_ number: Int?, taskName: String? = nil) -> String {
        task(taskName) ?? "Sub-agent" + (number.flatMap { $0 > 0 ? " \($0)" : nil } ?? "")
    }
    static func title(_ number: Int?, _ description: String, taskName: String? = nil) -> String {
        task(taskName) ?? name(number) + (description.isEmpty ? "" : " · " + description)
    }
}

extension ChatRecord {
    var displayTitle: String { isSubagent ? SubagentLabel.title(subagentNumber, title, taskName: subagentTaskName) : title }
    var subagentName: String { SubagentLabel.name(subagentNumber, taskName: subagentTaskName) }
}
