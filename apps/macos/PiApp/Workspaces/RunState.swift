import Foundation

/// What a chat's run is doing: the `state` its helper reports in each
/// snapshot, or the one the app puts up itself — `running` or `queued` the
/// moment a message goes out, `stopping` when Stop is pressed, and
/// `interrupted` when the helper that ran it is gone and nobody can say how
/// its last command ended.
///
/// A value, not a closed enum: a newer helper may report a state this build
/// has never heard of, and that state still has to be shown, kept and handed
/// back as it came. It reads as neither busy nor holding its queue, as the
/// string comparisons it replaces always read it. `SessionDisplay.state`
/// stays the raw string; `SessionDisplay.runState` is it as this value.
struct RunState: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let idle = RunState(rawValue: "idle")
    /// Accepted, and waiting to start behind another run of its project.
    static let queued = RunState(rawValue: "queued")
    static let running = RunState(rawValue: "running")
    static let stopping = RunState(rawValue: "stopping")
    static let compacting = RunState(rawValue: "compacting")
    /// Stopped by the reader, or by a failure the helper can resume from:
    /// the chat's follow-ups wait for Resume.
    static let paused = RunState(rawValue: "paused")
    /// The run's helper went away before it said how the run ended.
    static let interrupted = RunState(rawValue: "interrupted")
    static let error = RunState(rawValue: "error")
    /// Every state this build knows.
    static let known: [RunState] = [.idle, .queued, .running, .stopping, .compacting, .paused, .interrupted, .error]

    /// A run is under way: a turn, a start waiting for its project, a stop
    /// that has not landed yet, or a compaction.
    var isBusy: Bool { self == .queued || self == .running || self == .stopping || self == .compacting }
    /// The run ended without finishing, and whatever the chat queued after
    /// it waits for the reader to resume.
    var holdsQueue: Bool { self == .paused || self == .interrupted }
    /// The run ended without finishing: it failed, or it waits for Resume.
    var isStopped: Bool { self == .error || holdsQueue }
}
