import Foundation

/// Recomputed from immutable acceptance rows: restart/compaction cannot refill
/// quotas. A real user task (or explicit Resume) opens the authorization epoch.
enum AgentMailboxPolicy {
    static func validate(_ op: AgentOperation, state: AgentFamilyState) throws {
        let epoch = state.operations.values.filter { $0.epoch == op.epoch }
        // Replacement children spend the same finite authorization as follow-ups.
        if op.turn != nil { guard epoch.compactMap(\.turn).count < 64 else { throw cap() } }
        if state.run?.epoch == op.epoch, (state.run?.reportContinuations ?? 0) >= 32,
           op.turn != nil || op.message?.author == "parent" { throw cap() }
        if let turn = op.turn, turn.turn > 1 {
            let follows = epoch.compactMap(\.turn).filter { $0.turn > 1 }
            guard follows.count < 64, follows.filter({ $0.childID == turn.childID }).count < 8 else { throw cap() }
        }
        let child = op.message?.childID ?? (op.turn?.turn ?? 0 > 1 ? op.turn?.childID : nil)
        if let child {
            let messages = epoch.filter { $0.message != nil || ($0.turn?.turn ?? 0) > 1 }
            guard messages.count < 256, messages.filter({ ($0.message?.childID ?? $0.turn?.childID) == child }).count < 32 else { throw cap() }
        }
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
    static func cap() -> AgentError { AgentError("coordination_limit", "Family communication limit reached; a new user task or explicit Resume is required") }
}
