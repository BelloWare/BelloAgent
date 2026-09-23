import Foundation

extension AgentSession {
    /// Pi's overflow recovery takes the reply it retries out of the agent's
    /// context, and only there: the reply stays in the session and in what a
    /// compaction reads, and a rebuilt context (compaction, branch, reopen)
    /// holds it again.
    func excludeFromRequests(_ id: String) {
        requestExclusions.insert(id)
        replayInputsChanged(reason:"overflow-recovery")
    }
    /// The context a model request replays.
    var requestContext: [ChatMessage] {
        requestExclusions.isEmpty ? context : context.filter { !requestExclusions.contains($0.id) }
    }
}

extension AgentSession {
    /// Pi's settings.retry is configurable; tests shorten its back-off.
    func useRetrySettings(_ settings: PiProviderRules.RetrySettings) { retrySettings = settings }
}
