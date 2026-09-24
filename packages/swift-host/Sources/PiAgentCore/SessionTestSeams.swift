import Foundation

// Test seams: internals a test may read to assert a contract that timing,
// sleeping or a private field would otherwise be needed for. They are grouped
// here so their cost is visible in one place, and each one is a plain read of
// state the session already keeps — no counter is maintained for a test alone,
// and none of them allocates.
//
// The two seams that cannot live here are stored properties, so they stay on
// the actor's declaration in Sessions.swift:
//
// - `displayProjectionBuildCount` — how many times a display page was built.
// - `displayRowProjectionCount` — how many rows were projected into one.
//
// Two more are injection points on `init`, defaulted to the real thing:
//
// - `displayClock` — the clock display observations are stamped with.
// - `beforeJournalAppend` — a hook that can fail one journal write, so the
//   recovery paths can be driven without a full disk.
//
// `MCPManager.installForTesting` and `BlockingWorkExecutor.occupancy` are the
// same idea outside the session.

extension AgentSession {
    /// Journal records written, and how many times they were forced to stable
    /// storage: the rule that a run batches its writes and an idle session
    /// does not, asserted without timing a disk.
    var journalAppendCount: Int { journal?.appends ?? 0 }
    var journalSynchronizationCount: Int { journal?.synchronizations ?? 0 }
    /// What the live tool cards retain, in arrival order and in preview bytes,
    /// so their bounds are testable without exposing the cards themselves.
    var retainedToolStateIDs: [String] { toolStateOrder }
    var retainedToolStateBytes: Int { toolStateBytes.values.reduce(0,+) }
    /// Parsed journal records still held after open, and whether a context
    /// preview is: both are released, not kept for the session's life.
    var journalLoadedRecordCount: Int { journal?.loaded.count ?? 0 }
    var holdsPreparedContext: Bool { preparedContext != nil }
}
