import Foundation

/// Small presentation evidence, shared by the helper and native reader. This
/// never controls tool execution, provider replay, or queue admission.
public struct TaskPresentationRecord: Codable, Equatable, Sendable {
    public var rootID: String
    public var executionID: String
    public var startedAt: Double
    public var endedAt: Double?
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
    public static func identity(_ root: String, _ execution: String) -> String { "\(root.utf8.count):" + root + execution }
    public var key: String { Self.identity(rootID, executionID) }
    public var terminal: Bool { outcome != nil }
    public init(rootID: String, executionID: String = UUID().uuidString, startedAt: Double) {
        self.rootID = rootID; self.executionID = executionID; self.startedAt = startedAt; self.anchorSourceID = rootID
    }
    public var valid: Bool {
        !rootID.isEmpty && rootID.utf8.count <= 256 && !executionID.isEmpty && executionID.utf8.count <= 256 &&
        startedAt.isFinite && startedAt >= 0 && (endedAt.map { $0.isFinite && $0 >= startedAt } ?? true) &&
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
