import Foundation
@testable import PiApp

/// A frozen copy of `HistoryReader.IndexRecord`'s decoding as the merged tree
/// had it before `HistoryIndexScan` (0.1.136, round 2): the reference the
/// scanner is held to. Do not change it with the reader.
struct ReferenceIndexRecord: Decodable {
    var type: String?; var id: String?; var parentId: String?
    var fromMessageId: String?; var keptIds: [String]?; var nativeKeptIDs: [String]?; var contextIDs: [String]?
    var version: Int?; var customType: String?; var pendingWork: PendingWork?
    var nativeCompactionVersion: Int?; var nativeCompaction: Checkpoint?
    var historicalBranch: HistoricalBranch?; var selectedTimeline: [String]?
    var presentationTarget: String?
    var taskTerminal: TaskPresentationRecord?
    struct Checkpoint: Decodable { var operationId: String?; var version: Int; var sourceIDs: [String]; var protectedIDs: [String]; var keptIDs: [String]; var dependencyIDs: [String]?; var summarySourceIDs: [String]? }
    struct PendingItem: Decodable { var turnID: String?; var text: String? }
    struct PendingWork: Decodable {
        var active: Bool?; var queue: [PendingItem]?; var steering: [PendingItem]?
        var runStatus: String?; var errorMessage: String?; var queuePaused: Bool?
        var errorCode: String?; var skillUpdatedTurnId: String?
        /// The helper's cost-limit pause (`costPaused`, 0.1.129).
        var costPaused: Bool?
        /// Sides still waiting for the family's Resume (`costPausedMembers`).
        var costPausedMembers: [String]?
        /// Tool calls the pause held before they began (`costPendingCalls`):
        /// they run on Resume, so they are not unresolved.
        var costPendingCalls: [String]?
        /// Paused at the family's limit, or (a root whose own Resume was
        /// accepted before its sides were resumed) still handing sides
        /// out: the helper's `membersPendingResume`, shown as the pause.
        var pausedForResume: Bool { costPaused == true || active != true && !(costPausedMembers ?? []).isEmpty }
        /// The failure's code, as the helper reports it: a skill-update
        /// stop's only while its re-pinned message waits.
        var failureCode: String? {
            guard failure != nil else { return nil }
            return errorCode == SessionDisplay.skillUpdatedCode && !skillUpdateWaiting ? nil : errorCode
        }
        /// A skill-update stop whose re-pinned message still waits.
        var skillUpdateWaiting: Bool {
            errorCode == SessionDisplay.skillUpdatedCode && ((queue ?? []) + (steering ?? [])).contains { $0.turnID != nil && $0.turnID == skillUpdatedTurnId }
        }
        var exists: Bool { active == true || !(queue ?? []).isEmpty || !(steering ?? []).isEmpty }
        var failure: String? {
            guard active != true, runStatus == "failed" else { return nil }
            let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // As the helper says it: once the re-pinned message is gone, the run's failure.
            if errorCode == SessionDisplay.skillUpdatedCode, !skillUpdateWaiting {
                return "The run stopped for a queued message whose skill had changed, and that message is no longer waiting. Retry request finishes the stopped turn."
            }
            return detail.isEmpty ? "Run failed." : detail
        }
        /// Stopped by the reader (or a quit) with nothing queued: the run
        /// is over, but the chat waits for Resume, as the helper restores
        /// it. Not a failure, which is shown as one.
        var pausedWithoutWork: Bool { !exists && queuePaused == true && runStatus != "failed" || pausedForResume }
        func retained(unanswered: Set<String>) -> RetainedRun? {
            guard exists || pausedWithoutWork else { return nil }
            let active = self.active == true && !pausedForResume
            func row(_ item: PendingItem, steering: Bool) -> [String: WireValue]? {
                guard let id = item.turnID else { return nil }
                let text = item.text ?? "", kept = String(text.prefix(1024))
                var value: [String: WireValue] = ["turnId": .string(id), "text": .string(steering ? "[Steering] " + kept : kept), "textTruncated": .bool(kept.count < text.count)]
                if steering { value["kind"] = .string("steering") }
                return value
            }
            let rows = (steering ?? []).compactMap { row($0, steering: true) } + (queue ?? []).compactMap { row($0, steering: false) }
            return RetainedRun(active: active, runStatus: runStatus, queuePaused: queuePaused == true || !rows.isEmpty || active || pausedForResume,
                               queue: rows, unansweredCalls: self.active == true ? unanswered.subtracting(costPendingCalls ?? []) : [], heldCalls: Set(costPendingCalls ?? []), costPaused: pausedForResume)
        }
    }
    struct MessageRole: Decodable {
        struct Block: Decodable { var type: String?; var id: String? }
        var role: String?; var toolCallId: String?; var calls: [String]; var contentIndexed: Bool; var nativeReplayEligible: Bool?
        var nativeKind: String?; var nativeOperationID: String?; var nativeCompaction: Checkpoint?
        var taskKey: String?
        /// An agent's delivery: a user row that is work of a turn, not its start.
        var agentDelivery = false
        /// The row opens a display turn (`HistoryWindowPolicy.startsTurn`).
        var startsTurn: Bool { HistoryWindowPolicy.startsTurn(role: role, kind: nativeKind, agentDelivery: agentDelivery) }
        private enum CodingKeys: String, CodingKey { case role, toolCallId, content, nativeReplayEligible, nativeKind, nativeCompaction, nativeOperationID, nativeAgentDelivery, nativeTaskRoot, nativeTaskExecution }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            role = try value.decodeIfPresent(String.self, forKey: .role)
            agentDelivery = value.contains(.nativeAgentDelivery) && !((try? value.decodeNil(forKey: .nativeAgentDelivery)) ?? true)
            toolCallId = try value.decodeIfPresent(String.self, forKey: .toolCallId)
            nativeReplayEligible = try value.decodeIfPresent(Bool.self, forKey: .nativeReplayEligible)
            nativeKind = try value.decodeIfPresent(String.self, forKey: .nativeKind)
            nativeOperationID = try value.decodeIfPresent(String.self, forKey: .nativeOperationID)
            nativeCompaction = try value.decodeIfPresent(Checkpoint.self, forKey: .nativeCompaction)
            if let execution = try value.decodeIfPresent(String.self, forKey: .nativeTaskExecution) {
                taskKey = TaskPresentationRecord.identity(try value.decodeIfPresent(String.self, forKey: .nativeTaskRoot) ?? "", execution)
            }
            // String-form user content is valid. Only normalized call IDs
            // are indexed; text/provider content is never retained here.
            let blocks = try? value.decode([Block].self, forKey: .content)
            calls = (blocks ?? []).filter { $0.type == "toolCall" }.map { $0.id ?? "" }
            // A malformed mixed array can still contain a helper-visible
            // call. Preserve browsing, but do not auto-open unknown content.
            contentIndexed = blocks != nil || (try? value.decode(String.self, forKey: .content)) != nil
        }
    }
    var message: MessageRole?
    private struct ContextSelection: Decodable { var ids: [String]?; var visibleIDs: [String]? }
    private enum CodingKeys: String, CodingKey { case type, id, parentId, fromMessageId, keptIds, nativeKeptIDs, version, customType, nativeState, data, message, nativeCompactionVersion, nativeCompaction, nativeBranchVersion }
    /// A run-state record read from its tail (`StateRecordTail`): its id
    /// and parent. What it says about unfinished work is read from the
    /// newest one only.
    init(stateID: String, parentID: String?) { type = "custom"; id = stateID; parentId = parentID; customType = StateRecordTail.customType }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        type = try value.decodeIfPresent(String.self, forKey: .type); id = try value.decodeIfPresent(String.self, forKey: .id)
        parentId = try value.decodeIfPresent(String.self, forKey: .parentId)
        fromMessageId = try value.decodeIfPresent(String.self, forKey: .fromMessageId); keptIds = try value.decodeIfPresent([String].self, forKey: .keptIds)
        nativeKeptIDs = try value.decodeIfPresent([String].self, forKey: .nativeKeptIDs)
        nativeCompactionVersion = try value.decodeIfPresent(Int.self, forKey: .nativeCompactionVersion)
        nativeCompaction = try value.decodeIfPresent(Checkpoint.self, forKey: .nativeCompaction)
        version = try value.decodeIfPresent(Int.self, forKey: .version); customType = try value.decodeIfPresent(String.self, forKey: .customType)
        message = try value.decodeIfPresent(MessageRole.self, forKey: .message)
        if type == "branch" {
            pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .nativeState)
            if value.contains(.nativeBranchVersion) { historicalBranch = try HistoricalBranch(from: decoder) }
        }
        else if customType == "pi-app.native.state.v1" { pendingWork = try value.decodeIfPresent(PendingWork.self, forKey: .data) }
        else if customType == "pi-app.presentation.update.v1" {
            struct Target: Decodable { var id: String }
            presentationTarget = try value.decode(Target.self, forKey: .data).id
        }
        else if customType == "pi-app.task-terminal.v1" {
            let task = try value.decode(TaskPresentationRecord.self, forKey:.data)
            guard task.valid, task.terminal else { throw StoreError.unreadableRecord }
            taskTerminal = task
        }
        if customType == "pi-app.native.context.v1" {
            let selection = try value.decodeIfPresent(ContextSelection.self, forKey: .data)
            contextIDs = selection?.ids ?? []; selectedTimeline = selection?.visibleIDs
        }
    }
}
