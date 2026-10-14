import Foundation

extension AgentSession {
    var isSubagent: Bool { subagents.origin != nil }
    func requireIndependentSession() throws {
        guard !isSubagent else { throw AgentError("managed_subagent", "Sub-agents are managed by their parent; only viewing and Stop are available") }
    }
    func requireSubagentCommand(_ method: String) throws {
        guard isSubagent else { return }
        let reads: Set<String> = ["turn.stop", "session.status", "session.snapshot", "session.history", "session.message.read",
            "session.tool.input", "session.content.search", "session.content.page", "session.event-page", "session.events",
            "session.versions", "session.version.page", "context.info", "context.preview", "context.preview.read", "context.preview.clear", "session.close"]
        guard reads.contains(method) else { try requireIndependentSession(); return }
    }
    func configureSubagentModels(_ grants: [SubagentModelGrant]) throws {
        try requireIndependentSession()
        try validateSubagentModels(grants)
        guard subagentModelGrants != grants else { return }
        subagentModelGrants = grants
        if runTask == nil { replayInputsChanged(); event("context.inputs-changed") }
    }
    func validateSubagentModels(_ grants: [SubagentModelGrant]) throws {
        // Validate before accepting the complete replacement. Route, headers,
        // credentials and connection identity always remain the parent's.
        guard Set(grants.map(\.model)).count == grants.count else { throw AgentError("subagent_model", "Duplicate model grant") }
        for grant in grants { _ = try grant.applying(to: profile) }
    }
}

extension SubagentModelGrant {
    func applying(to parent: Profile) throws -> Profile {
        try parent.overriding(Submission(commandID: "delegation", turnID: "delegation", text: "",
                                        model: model, thinkingLevel: thinkingLevel, contextWindow: contextWindow,
                                        maxOutputTokens: maxOutputTokens, modelOutputLimit: modelOutputLimit, input: input))
    }
    static func inherited(_ profile: Profile) -> Self {
        Self(model: profile.model, thinkingLevel: profile.raw["thinkingLevel"].text, contextWindow: profile.contextWindow,
             maxOutputTokens: profile.maxOutput, modelOutputLimit: profile.modelOutputLimit,
             input: profile.raw["input"].isNull ? nil : profile.raw["input"].list.compactMap(\.text))
    }
    static func resolve(_ requested: String?, parent: Profile, grants: [Self]) throws -> (Self, Profile) {
        guard let requested else { return (inherited(parent), parent) }
        guard let grant = grants.first(where: { $0.model == requested }) else { throw AgentError("subagent_model", "The model is not offered for the parent's saved connection") }
        return (grant, try grant.applying(to: parent))
    }
}
