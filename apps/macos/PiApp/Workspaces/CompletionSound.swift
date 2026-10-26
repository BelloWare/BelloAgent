import AppKit

/// Watches the helper's bounded command receipts, not streamed messages: a
/// tool round is not a finished task. Opening retained history establishes a
/// silent baseline before a submission can run, including very fast replies.
struct SessionCompletionTracker {
    /// The receipt states it takes for an end: the chime's, a completed run
    /// only; a brief's (`runEndings`), every run's end.
    let endings: Set<String>
    /// A run that completed, failed, was stopped, cut short or hit its
    /// output limit.
    static let runEndings: Set<String> = ["completed", "failed", "cancelled", "interrupted", "output-limited"]
    private var epoch: String?
    private var states: [String: String]?

    init(endings: Set<String> = ["completed"]) { self.endings = endings }

    mutating func observe(_ snapshot: [String: WireValue], baseline: Bool = false) -> Bool {
        guard let commands = snapshot["commands"]?.array else { return false }
        let nextEpoch = snapshot["monitoring"]?.object?["epoch"]?.string
        var next: [String: String] = [:]
        for command in commands.suffix(128) {
            guard let receipt = command.object,
                  let id = receipt["commandId"]?.string, !id.isEmpty,
                  let turn = receipt["turnId"]?.string, !turn.isEmpty,
                  !turn.hasPrefix("compaction:"),
                  let state = receipt["state"]?.string else { continue }
            next[id] = state
        }
        defer { epoch = nextEpoch; states = next }
        guard !baseline, epoch == nextEpoch, let states else { return false }
        // A follow-up can already be running by this snapshot. Its completed
        // predecessor still deserves a cue; waiting for idle would miss it.
        return next.contains { endings.contains($0.value) && states[$0.key] != $0.value }
    }
}

/// Every run's end, for chat briefs: a command receipt that becomes
/// terminal, or a run that ended leaving its receipt as it was (a retry runs
/// its failed command again, and fails again): the session's last run has a
/// new end time (`turnMetrics.endedAt`, which every run sets as it ends). A
/// read of history with no run (older versions opened) moves the display
/// revision but no run's end, and counts for nothing.
struct RunEndTracker {
    private var receipts = SessionCompletionTracker(endings: SessionCompletionTracker.runEndings)
    private var epoch: String?
    /// Whether the run end time has been seen since the helper (its epoch)
    /// was first seen: the first one seen is where things stand, not an end.
    private var seen = false
    /// The end time of the last run seen to end.
    private var lastEnded: Double?

    mutating func observe(_ snapshot: [String: WireValue], baseline: Bool = false) -> Bool {
        let ended = receipts.observe(snapshot, baseline: baseline)
        let nextEpoch = snapshot["monitoring"]?.object?["epoch"]?.string
        if baseline || epoch != nextEpoch { seen = false; lastEnded = nil }
        epoch = nextEpoch
        guard let metrics = snapshot["turnMetrics"]?.object else { return ended }
        // A run under way has none; one that ends sets it.
        let endedAt = metrics["endedAt"]?.number
        guard seen else { seen = true; lastEnded = endedAt; return ended }
        guard let endedAt, endedAt != lastEnded else { return ended }
        lastEnded = endedAt
        return true
    }
}

/// One short native chime, shared by every session. Completions within one
/// second share a cue instead of overlapping or building a playback backlog.
@MainActor final class CompletionSound {
    private let now: () -> TimeInterval
    private let playback: (() -> Bool)?
    private var sound: NSSound?
    private var lastPlayed: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, playback: (() -> Bool)? = nil) {
        self.now = now; self.playback = playback
    }

    @discardableResult func play() -> Bool {
        let instant = now()
        guard lastPlayed.map({ instant - $0 >= 1 }) ?? true else { return false }
        let played: Bool
        if let playback { played = playback() }
        else {
            // Native fixtures must never make audible sounds. Injected playback
            // exercises the real policy without depending on an audio device.
            guard ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1",
                  NSClassFromString("XCTestCase") == nil else { return false }
            if sound == nil { sound = NSSound(named: NSSound.Name("Tink")); sound?.volume = 0.8 }
            guard sound?.isPlaying != true else { return false }
            played = sound?.play() ?? false
        }
        if played { lastPlayed = instant }
        return played
    }
}

extension WorkspaceModel {
    func observeSessionCompletion(sessionID: String, snapshot: [String: WireValue], baseline: Bool = false) {
        guard !isShutDown, let display = displays[sessionID] else { return }
        let completed = display.completionTracker.observe(snapshot, baseline: baseline)
        let ended = display.runEndTracker.observe(snapshot, baseline: baseline)
        observeWebhookFinish(sessionID: sessionID, snapshot: snapshot, baseline: baseline)
        // The chat's brief is updated at every run's end, a failed or stopped
        // run's too, not only at the completed ones the chime is for
        // (`WorkspaceChatBriefs.swift`).
        if ended { noteBriefRunFinished(sessionID) }
        // Always consume the receipt, including while muted, so turning sound
        // on or restoring a chat cannot replay a completion that already passed.
        guard completed, configuration.playsCompletionSound,
              let item = record(sessionID), !item.isSubagent, !item.isArchived, !item.isBackgroundTask,
              item.connectionTest != true, !item.imported else { return }
        completionSound.play()
    }
}
