import Foundation

/// Accepted messages are bounded by their tool contract and the recipient's
/// context capacity, not communication frequency or small mailbox quotas.
enum AgentMailboxPolicy {
    static func validate(_ op: AgentOperation, state: AgentFamilyState) throws {
        if let message = op.message {
            let limit = message.type == "NEW_TASK" ? 262144 + 4096 : 262144
            guard !message.text.isEmpty, message.text.utf8.count <= limit else { throw AgentError("subagent_arguments","Agent message exceeds its validity bound") }
        }
    }
    // Retained for historical fixtures; no admission path consults a bucket.
    static func tokens(_ operations: [AgentOperation], at now: Double, burst: Double, refill: Double) -> Double {
        guard let first = operations.first else { return burst }
        var value = burst, time = first.acceptedAt
        for op in operations { let next = max(time,op.acceptedAt); value = min(burst,value + (next-time)*refill)-1; time = next }
        return min(burst,value + max(0,now-time)*refill)
    }
}
