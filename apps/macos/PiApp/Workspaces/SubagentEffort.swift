import Foundation

/// Small display metadata rebuilt from the accepted model grant. The current
/// turn's accepted effort wins; the grant supplies legacy journals' level and
/// distinguishes model default from a model with no effort control.
struct SubagentEffort: Equatable, Sendable {
    var initial: String?
    var reasoning: [String]?

    func label(_ accepted: String?) -> String? {
        guard reasoning?.isEmpty != true, let level = accepted ?? initial else { return nil }
        if level == "default" { return reasoning?.isEmpty == false ? "model default" : nil }
        return ThinkingLevel(rawValue: level).map { $0.rawValue }
    }
}

extension WorkspaceModel {
    func subagentEffortLabel(_ id: String, summary: SubagentSummary? = nil) -> String? {
        let context = subagentEfforts[id] ?? SubagentEffort(initial: record(id)?.thinkingLevel)
        return context.label((summary ?? subagentSummaries[id])?.effort)
    }
    func publishSubagentEffort(_ grant: SubagentModelGrant, child: ChatRecord) {
        // An older recovery header may omit capabilities. A cached accepted
        // grant or the connection's existing catalog fills only that omission.
        let levels = grant.reasoning ?? subagentEfforts[child.id]?.reasoning
            ?? profiles.first(where: { $0.id == child.profileID }).flatMap { catalogEntry(for: $0).descriptor(for: grant.model)?.reasoning }
        let context = SubagentEffort(initial: grant.thinkingLevel, reasoning: levels)
        guard subagentEfforts[child.id] != context else { return }
        objectWillChange.send()
        subagentEfforts[child.id] = context
        subagentFamilies.removeAll(); invalidateConversationFamily()
        for display in displays.values { display.subagentEfforts[child.id] = context }
    }
}
