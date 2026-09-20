import AppKit

/// Watches the helper's bounded command receipts, not streamed messages: a
/// tool round is not a finished task. Opening retained history establishes a
/// silent baseline before a submission can run, including very fast replies.
struct SessionCompletionTracker {
    private var epoch: String?
    private var states: [String: String]?

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
        return next.contains { $0.value == "completed" && states[$0.key] != "completed" }
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
        guard !accountingStopped, let display = displays[sessionID] else { return }
        let completed = display.completionTracker.observe(snapshot, baseline: baseline)
        // Always consume the receipt, including while muted, so turning sound
        // on or restoring a chat cannot replay a completion that already passed.
        guard completed, configuration.playsCompletionSound,
              let item = record(sessionID), !item.isArchived, !item.isBackgroundTask,
              item.connectionTest != true, !item.imported else { return }
        completionSound.play()
    }
}
