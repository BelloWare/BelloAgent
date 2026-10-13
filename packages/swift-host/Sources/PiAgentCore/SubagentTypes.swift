import Foundation

/// Shared by the app and helper. The sole production rollout switch stays
/// off until the complete feature has passed its final review. Test fixtures
/// inject availability into the helper; no preference or wire flag enables it.
public enum SubagentPolicy {
    public static let enabled = false
    public static let maximumActiveChildren = 16
    public static let maximumDepth = 1
    public static var capabilities: [String] { enabled ? ["subagents-v1", "shared-budget-v1"] : [] }
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
}
