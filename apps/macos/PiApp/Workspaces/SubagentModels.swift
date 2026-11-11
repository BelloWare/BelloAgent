import Foundation

extension ModelCatalog.Entry {
    /// Exactly the descriptors the saved connection's picker offers. Manual
    /// aliases are not grants; the helper can always inherit the current model.
    @MainActor func subagentGrants(chat: ChatRecord, profile: ProfileRecord) -> [SubagentModelGrant] {
        // Every turn, session open and context preview asks, on the main
        // actor, and a catalog can list thousands of models: the connection's
        // own settings are decoded once, not once per model.
        let configuration = profile.configuration
        let inherited = chat.thinkingLevel ?? configuration["thinkingLevel"]?.string
        let declared = configuration["input"]?.array?.compactMap(\.string) ?? []
        return offered(current: chat.model ?? profile.modelId).map { descriptor in
            let limits = descriptor.limits(for: profile)
            var effort = inherited
            if let choices = descriptor.reasoning,
               choices.isEmpty || effort.map({ $0 != "default" && !choices.contains($0) }) == true { effort = "default" }
            return SubagentModelGrant(model: descriptor.id, thinkingLevel: effort, contextWindow: limits.contextWindow,
                                      maxOutputTokens: limits.maxOutputTokens, modelOutputLimit: limits.modelOutputLimit,
                                      input: Array(Set(["text"] + declared + (descriptor.input ?? []))).sorted(),
                                      reasoning: descriptor.reasoning)
        }
    }
}

extension SubagentModelGrant {
    /// The grant as the helper reads it: its coded form, without the encoder
    /// and decoder between (an absent value is an absent key).
    var wire: WireValue {
        var fields: [String: WireValue] = ["model": .string(model)]
        if let thinkingLevel { fields["thinkingLevel"] = .string(thinkingLevel) }
        if let contextWindow { fields["contextWindow"] = .number(Double(contextWindow)) }
        if let maxOutputTokens { fields["maxOutputTokens"] = .number(Double(maxOutputTokens)) }
        if let modelOutputLimit { fields["modelOutputLimit"] = .number(Double(modelOutputLimit)) }
        if let input { fields["input"] = .array(input.map(WireValue.string)) }
        if let reasoning { fields["reasoning"] = .array(reasoning.map(WireValue.string)) }
        return .object(fields)
    }
}

extension WorkspaceModel {
    func subagentModels(for chat: ChatRecord) -> WireValue? {
        guard SubagentPolicy.enabled, !chat.isSubagent, let profile = profiles.first(where: { $0.id == chat.profileID }) else { return nil }
        return .array(catalogEntry(for: profile).subagentGrants(chat: chat, profile: profile).map(\.wire))
    }

    /// Loading is an explicit operation, never a side effect of reading grants.
    /// Previews await the shared, endpoint-bounded load before taking their inputs;
    /// session opens start it in the background without delaying a send.
    func loadSubagentModels(for chat: ChatRecord) async {
        guard !isShutDown, SubagentPolicy.enabled, !chat.isSubagent,
              let profile = profiles.first(where: { $0.id == chat.profileID }) else { return }
        let entry = catalogEntry(for: profile)
        if entry.fetchedAt == nil || entry.loading { _ = await listModels(for: profile) }
    }
}
