import Foundation

// A chat's run, as the helper tracks it. The raw values are the protocol's
// strings: snapshots name them (`state`, `runStatus`), the saved state record
// keeps `runStatus`, and the app reads both. They must never change.

/// Where a chat's run is: a snapshot's `state`.
enum SessionState: String, Sendable {
    case idle, running, stopping, paused, error
}

/// What a run is doing, and how the last one ended: a snapshot's `runStatus`,
/// and the saved state record's.
enum RunStatus: String, Sendable {
    case idle, running, waitingTool, retrying, compacting, failed, cancelled
}

/// How one tool call ended, as `recordTool` records it. The outcome and the
/// card state written for the call are derived from it.
enum ToolRunState: String, Sendable {
    case completed, failed, cancelled
}
