import Foundation

/// Small presentation evidence, shared by the helper and native reader. This
/// never controls tool execution, provider replay, or queue admission.
public struct TaskPresentationRecord: Codable, Equatable, Sendable {
    public var rootID: String
    public var executionID: String
    /// Monotonic system-uptime milliseconds, retained for elapsed durations.
    /// These have never been Unix timestamps; keep the v1 wire contract.
    public var startedAt: Double
    public var endedAt: Double?
    /// Calendar observations are separate. Older v1 receipts lack these;
    /// their elapsed duration remains usable, but their clock time is unknown.
    public var startedAtUnixMs: Double?
    public var endedAtUnixMs: Double?
    public var outcome: String?
    public var phase: String = "preparing"
    public var activeInputID: String?
    public var anchorSourceID: String?
    public var assistantID: String?
    public var attemptID: String?
    public var operationID: String?
    public var lastSourceID: String?
    public var issuedCalls: Int = 0
    public var preparingCalls: Int = 0
    public var replies: Int = 0
    public var modelMs: Double = 0
    public var toolMs: Double = 0
    public var currentTool: String?
    public var detail: String?
    /// The failed run's error code: `cost_limit` for a stop at the chat's cost limit.
    public var errorCode: String?
    public static func identity(_ root: String, _ execution: String) -> String { "\(root.utf8.count):" + root + execution }
    public var key: String { Self.identity(rootID, executionID) }
    public var terminal: Bool { outcome != nil }
    public init(rootID: String, executionID: String = UUID().uuidString, startedAt: Double, startedAtUnixMs: Double? = nil) {
        self.rootID = rootID; self.executionID = executionID; self.startedAt = startedAt; self.anchorSourceID = rootID
        self.startedAtUnixMs = startedAtUnixMs
    }
    /// A runtime interruption has no observed finish, including after a reboot
    /// when the saved uptime belongs to a different boot. Do not fabricate it.
    public func elapsedMilliseconds(atUptimeMs now: Double? = nil) -> Double? {
        guard outcome != "interrupted", let end = endedAt ?? now, startedAt.isFinite, startedAt >= 0,
              end.isFinite, end >= startedAt else { return nil }
        return end - startedAt
    }
    public var valid: Bool {
        !rootID.isEmpty && rootID.utf8.count <= 256 && !executionID.isEmpty && executionID.utf8.count <= 256 &&
        startedAt.isFinite && startedAt >= 0 && (endedAt.map { $0.isFinite && $0 >= startedAt } ?? true) &&
        [startedAtUnixMs, endedAtUnixMs].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true } &&
        issuedCalls >= 0 && preparingCalls >= 0 && replies >= 0 && modelMs.isFinite && modelMs >= 0 && toolMs.isFinite && toolMs >= 0 &&
        [activeInputID, anchorSourceID, assistantID, attemptID, operationID, lastSourceID].allSatisfy { $0.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true } &&
        (detail?.utf8.count ?? 0) <= 8192 && (currentTool?.utf8.count ?? 0) <= 1024 && phase.utf8.count <= 64 &&
        (outcome.map { ["completed", "failed", "cancelled", "interrupted", "output-limited"].contains($0) && endedAt != nil } ?? (endedAt == nil))
    }
}

public struct TaskPresentationProjection: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sessionID: String
    public var epoch: String
    public var timeline: String
    public var sequence: Int
    public var sourceRevision: String
    public var active: TaskPresentationRecord?
    public var recent: [TaskPresentationRecord]
    public var utilityPhase: String?
    public init(sessionID: String, epoch: String, timeline: String, sequence: Int, sourceRevision: String,
                active: TaskPresentationRecord?, recent: [TaskPresentationRecord], utilityPhase: String? = nil) {
        self.sessionID = sessionID; self.epoch = epoch; self.timeline = timeline; self.sequence = sequence
        self.sourceRevision = sourceRevision; self.active = active; self.recent = recent; self.utilityPhase = utilityPhase
    }
    public var valid: Bool {
        version == 1 && !sessionID.isEmpty && !epoch.isEmpty && !timeline.isEmpty && sequence >= 0 && recent.count <= 64 &&
        recent.allSatisfy { $0.valid && $0.terminal } && Set(recent.map(\.key)).count == recent.count &&
        (active.map { task in task.valid && !task.terminal && !recent.contains(where: { $0.key == task.key }) } ?? true)
    }
}
