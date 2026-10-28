import Foundation

/// Shared by the app and helper. The sole production rollout switch, enabled
/// after the complete managed-session, accounting and UI work in phase 12.
/// No preference or wire flag can bypass this policy.
public enum SubagentPolicy {
    public static let enabled = true
    /// Background runs, steering and follow-ups ship together in 0.1.126.
    public static let steeringEnabled = true
    public static let codexEnabled = true
    public static let maximumActiveChildren = 16
    public static let maximumDepth = 1
    public static var capabilities: [String] { enabled ? ["subagents-v1", "shared-budget-v1"] + (steeringEnabled ? ["subagents-steering-v3"] + (codexEnabled ? ["subagents-codex-v4", "subagents-mailbox-cutin-v1"] : []) : []) : [] }
}

/// A provider may reuse a call ID in another response or another session.
public struct SubagentCallKey: Codable, Sendable, Hashable {
    public var parentSessionID: String
    public var assistantMessageID: String
    public var toolCallID: String
}

/// Durable authority, not sidebar ancestry. A side which delegates owns its
/// children's budget itself; its sidebar parent has no part in this link.
public struct SubagentLink: Codable, Sendable, Hashable {
    public var version = 1
    public var delegationID: String
    public var childSessionID: String
    public var budgetOwnerSessionID: String
    public var call: SubagentCallKey
    public var parentTurnID: String
    public var parentExecutionID: String
    public var parentAttemptID: String?
    public var depth = 1

    public var valid: Bool {
        let ids = [delegationID, childSessionID, budgetOwnerSessionID, call.parentSessionID,
                   call.assistantMessageID, call.toolCallID, parentTurnID, parentExecutionID] + (parentAttemptID.map { [$0] } ?? [])
        return version == 1 && depth == SubagentPolicy.maximumDepth
            && childSessionID != call.parentSessionID && budgetOwnerSessionID == call.parentSessionID
            && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains { $0 < 32 || $0 == 127 } }
    }
}

/// Only model settings from the saved connection's existing picker. Never
/// endpoints, headers, credentials, roots, capture policy or budget settings.
public struct SubagentModelGrant: Codable, Sendable, Hashable {
    public var model: String
    public var thinkingLevel: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var modelOutputLimit: Int?
    public var input: [String]?
    /// Picker capabilities: nil is unreported; [] means no effort control.
    public var reasoning: [String]? = nil
}

public enum SubagentStatus: String, Codable, Sendable {
    case queued, running, stopping, completed, failed, cancelled, interrupted
    case outputLimited = "output_limited", notExecuted = "not_executed"
    public var terminal: Bool { ![.queued, .running, .stopping].contains(self) }
}

public struct SubagentSummary: Codable, Sendable, Equatable {
    public var link: SubagentLink
    public var description: String
    public var model: String
    public var status: SubagentStatus
    public var revision: Int
    public var tools: [String]? = nil
    public var progress: SubagentProgress? = nil
    public var turn: Int? = nil
    public var executionID: String? = nil
    public var deliveryState: String? = nil
    public var pendingMessages: Int? = nil
    public var followUpsRemaining: Int? = nil
    public var parentWaiting: Bool? = nil
    /// Transient progress belongs to this session runtime inside the wire's
    /// hostEpoch. Semantic revision is the durable owner's family revision.
    public var progressEpoch: String? = nil
    public var effort: String? = nil
    public var taskName: String? = nil
    public var forkTurns: String? = nil
    public var pendingQueueOnlyMessages: Int? = nil
    /// The owner paused at its family's cost limit with this turn unsealed:
    /// it goes on (from where it stopped, or from the queue) on Resume.
    public var costPaused: Bool? = nil
    public var receivingAgentMessage: Bool? = nil
}

/// Display-only progress, coalesced while running and saved once with the
/// terminal result. No reasoning, capture bodies, or per-token journal rows.
public struct SubagentProgress: Codable, Sendable, Equatable {
    public var phase: String
    public var elapsedMs: Double
    public var requests: Int, tools: Int
    public var preview: String
    public var usd: Double
    public var reported: Int, unreported: Int
    public var inputTokens: Int?, outputTokens: Int?
    public var receivingAgentMessage: Bool? = nil
}
