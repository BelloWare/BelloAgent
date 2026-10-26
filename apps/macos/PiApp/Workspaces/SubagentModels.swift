import Foundation

extension ModelCatalog.Entry {
    /// Exactly the descriptors the saved connection's picker offers. Manual
    /// aliases are not grants; the helper can always inherit the current model.
    @MainActor func subagentGrants(chat: ChatRecord, profile: ProfileRecord) -> [SubagentModelGrant] {
        offered(current: chat.model ?? profile.modelId).map { descriptor in
            let effective = descriptor.applying(to: profile)
            var effort = chat.thinkingLevel ?? profile.configuration["thinkingLevel"]?.string
            if let choices = descriptor.reasoning,
               choices.isEmpty || effort.map({ $0 != "default" && !choices.contains($0) }) == true { effort = "default" }
            return SubagentModelGrant(model: descriptor.id, thinkingLevel: effort, contextWindow: effective.contextWindow,
                                      maxOutputTokens: effective.maxOutputTokens, modelOutputLimit: effective.modelOutputLimit,
                                      input: Array(Set(["text"] + WorkspaceModel.declaredInput(profile) + (descriptor.input ?? []))).sorted(),
                                      reasoning: descriptor.reasoning)
        }
    }
}

extension WorkspaceModel {
    func subagentModels(for chat: ChatRecord) -> WireValue? {
        guard SubagentPolicy.enabled, !chat.isSubagent, let profile = profiles.first(where: { $0.id == chat.profileID }) else { return nil }
        let entry = catalogEntry(for: profile)
        if entry.descriptors.isEmpty, entry.fetchedAt == nil, !entry.loading {
            Task { [weak self] in
                guard let self, !self.isShutDown else { return }
                _ = await self.listModels(for: profile)
            }
        }
        return (try? JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(entry.subagentGrants(chat: chat, profile: profile))))
    }
}
