import Foundation

extension AgentSession {
    /// Withdrawing the runtime a cancelled open just made. Unlike an idle
    /// unload, restored queued input may exist; it remains in the journal.
    /// The host checks the opening command's ownership and family dependents
    /// before calling this. Never stop a newly admitted turn for an old open.
    func abandonOpening() async -> Bool {
        guard runTask == nil, requestPermits.isEmpty, inFlightBudgetAttempts.isEmpty, !receivingAgentMessage, !ephemeral else { return false }
        await close()
        return true
    }
}
