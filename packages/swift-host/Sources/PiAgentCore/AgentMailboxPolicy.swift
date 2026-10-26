import Foundation

/// Bounds a family's mailboxes and its report rate, recomputed from immutable
/// acceptance rows so restart/compaction cannot refill them. How much a family
/// communicates is not capped (owner, 2026-10-26): starts, follow-ups,
/// messages and report continuations are unlimited; the chat's cost limit
/// bounds a runaway family.
enum AgentMailboxPolicy {
    static func validate(_ op: AgentOperation, state: AgentFamilyState) throws {
        let epoch = state.operations.values.filter { $0.epoch == op.epoch }
        if let message = op.message {
            let pending = state.messages.values.filter { $0.author == message.author && $0.disposition == "pending" }
            if message.author == "parent" {
                guard pending.filter({ $0.childID == message.childID }).count < 64 else { throw AgentError("subagent_mailbox_full", "Child has 64 pending messages; wait for delivery") }
            } else {
                let reports = pending.filter { $0.kind != "result" && $0.kind != "not_delivered_interrupted" }
                guard reports.count < 64, reports.filter({ $0.childID == message.childID }).count < 4 else { throw AgentError("subagent_mailbox_full", "Report mailbox is full; consolidate discoveries") }
                let accepted = epoch.filter { $0.message?.author == "subagent" }.sorted { $0.acceptedAt < $1.acceptedAt }
                guard tokens(accepted,at:op.acceptedAt,burst:16,refill:1) >= 1,
                      tokens(accepted.filter { $0.message?.childID == message.childID },at:op.acceptedAt,burst:2,refill:0.1) >= 1 else {
                    throw AgentError("subagent_rate_limited", "Report accepted too recently; consolidate notes and wait at least 10 seconds")
                }
            }
        }
    }
    static func tokens(_ operations: [AgentOperation], at now: Double, burst: Double, refill: Double) -> Double {
        guard let first = operations.first else { return burst }
        var value = burst, time = first.acceptedAt
        for op in operations {
            let next = max(time,op.acceptedAt); value = min(burst,value + (next-time)*refill)-1; time = next
        }
        return min(burst,value + max(0,now-time)*refill)
    }
}
