import Foundation

/// The `customType` of each record the helper writes to a journal of its own,
/// beside pi's `session`, `message`, `compaction` and `branch` records. A
/// journal keeps every kind it was ever written with, so none of these change.
///
/// Records are written with sorted keys and no spaces, and `customType` sorts
/// first in a run-state record: `JournalLineScan.statePrefix` and
/// `CommandReceipts.deltaMarker` read lines by those bytes without parsing them.
enum JournalRecordKind {
    /// The marker after the session header: a native journal, and its binding.
    static let marker = "pi-app.native.v1"
    static let childMarker = "pi-app.native.v2"
    static let steeringMarker = "pi-app.native.v3"
    static let agentOperation = "pi-app.agent-operation.v1"
    static let agentTurn = "pi-app.subagent-turn.v1"
    static let agentTurnState = "pi-app.subagent-turn-state.v1"
    static let agentTerminal = "pi-app.subagent-turn-terminal.v1"
    static let agentMessage = "pi-app.agent-message.v1"
    static let agentDelivery = "pi-app.agent-delivery.v1"
    static let familyRun = "pi-app.family-run.v1"
    static func isMarker(_ value: String?) -> Bool { value == marker || value == childMarker || value == steeringMarker }
    static let budgetAttempt = "pi-app.budget-attempt.v1"
    static let costUpdate = "pi-app.cost-update.v1"
    static let subagentCall = "pi-app.subagent-call.v1"
    static let subagentOrigin = "pi-app.subagent-origin.v1"
    static let subagentState = "pi-app.subagent-state.v1"
    static let subagentTerminal = "pi-app.subagent-terminal.v1"
    /// Run state: the queue, steering and command receipts (`CommandReceipts`).
    static let state = "pi-app.native.state.v1"
    /// The model context, and the rows shown, a fork or a kept side starts from.
    static let context = "pi-app.native.context.v1"
    /// A progress row as it now stands: a compaction's, or a request ledger's.
    static let presentationUpdate = "pi-app.presentation.update.v1"
    /// Where a fork, or a side, came from.
    static let forkOrigin = "pi-app.fork-origin.v1"
    static let sideOrigin = "pi-app.side-origin.v1"
    /// An overflow recovery under way: one compact-and-retry, as in pi.
    static let contextRecovery = "pi-app.context-recovery.v1"
    /// A task's terminal presentation.
    static let taskTerminal = "pi-app.task-terminal.v1"
    /// A compaction that failed, so the same one is not tried again.
    static let compactionFailure = "pi-app.compaction-failure.v1"
    /// The chat's spend (`SessionSpend`).
    static let cost = "pi-app.cost.v1"
    /// The chat moved to another connection: from here on the journal is
    /// bound to `binding`, in place of `previous` (`SessionJournal.rebind`).
    static let rebind = "pi-app.native.rebind.v1"
}
