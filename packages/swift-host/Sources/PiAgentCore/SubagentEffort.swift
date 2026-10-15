import Foundation

extension SubagentModelGrant {
    /// The catalog is authoritative when it reports capabilities. An unknown
    /// model uses the connection's existing reasoning flag/map; a different
    /// model never inherits another alias's translation map.
    func supportedEfforts(parent: Profile) -> [String] {
        let map = model == parent.model ? parent.raw["thinkingLevelMap"] : .null
        let choices: [String]
        if let reasoning { choices = reasoning }
        else if parent.raw["reasoning"].flag == true { choices = PiProviderRules.thinkingLevels }
        else { return [] }
        let levels = PiProviderRules.thinkingLevels.filter { choices.contains($0) && map.map[$0]?.isNull != true }
        return levels.isEmpty ? [] : ["default"] + levels
    }

    /// Validate before acceptance, journal creation, or scheduling. Never let
    /// provider clamping silently turn an explicit unsupported choice into a
    /// different effort. Omission inherits the parent's effective choice,
    /// falling back to model default if that model cannot use it.
    func selectingEffort(_ requested: String?, parent: Profile) throws -> Self {
        let allowed = supportedEfforts(parent:parent)
        if let requested, !allowed.contains(requested) {
            throw AgentError("subagent_effort", "Effort is not supported by the chosen child model")
        }
        let level = parent.raw["thinkingLevel"].text ?? "default"
        let inherited = parent.raw["reasoning"].flag == true
            ? (level == "default" || level == "off" ? level : PiProviderRules.clampThinkingLevel(level,map:parent.raw["thinkingLevelMap"])) : "default"
        var grant = self
        grant.reasoning = allowed.filter { $0 != "default" }
        grant.thinkingLevel = requested ?? (allowed.contains(inherited) ? inherited : "default")
        return grant
    }

    static func childModel(_ requested: String?, parent: Profile, grants: [Self]) throws -> Self {
        var (grant, _) = try resolve(requested,parent:parent,grants:grants)
        if requested == nil { grant.reasoning = grants.first { $0.model == parent.model }?.reasoning }
        return grant
    }
}
