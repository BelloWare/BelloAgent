import AppKit

/// One optional preparation allowance for the whole window, including both
/// transcript panes. Work is in small indivisible units (one host/measurement),
/// so the deadline bounds admission, not the duration of a native sizing call.
/// Required viewport layout never goes through this scheduler.
@MainActor final class TranscriptIdleScheduler {
    static let shared = TranscriptIdleScheduler()
    static let budget: TimeInterval = 0.0015
    /// The pause after a unit of work: one unit per frame. A test seam: a
    /// fixture that waits for the work to finish may drop the pause. The
    /// units, their order and what each one does stay the app's.
    static var interval: TimeInterval = 1.0 / 60
    /// Two kinds of optional work, which stand aside for different things.
    ///
    /// `preparation` gets the rows the reader is about to reach ready. It runs
    /// while they scroll and while a reply arrives, because that is exactly
    /// when they are about to reach a row: waiting for quiet would mean the
    /// scroll meets a row with no tree and pays for it in the frame that has
    /// to show it. Its per-frame allowance is what bounds it.
    ///
    /// `reconciliation` measures history nobody is looking at. It waits for
    /// the reader's hands to stop, as it always did.
    enum Work { case preparation, reconciliation }
    private struct Job {
        weak var owner: NSView?
        var work: Work
        var readyAt: TimeInterval
        /// When this work was first asked for, since it last finished.
        var since: TimeInterval
        var step: () -> Bool
    }
    /// How long a stream of changes may keep pushing reconciliation back.
    /// Every token of a reply moves its quiet deadline later, so without a
    /// limit rows left standing at an estimate — history above a chat opened
    /// mid-reply — stayed unmeasured for the whole reply, and every token
    /// placed the whole page again because of them.
    static let longestDeferral: TimeInterval = 0.5
    private var jobs: [Job] = []
    private var inputQuietUntil: TimeInterval = 0
    private var nextAllowedAt: TimeInterval = 0
    private var nextWake: TimeInterval?
    private var running = false
    nonisolated(unsafe) private var wakeup: DispatchWorkItem?
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let clock: () -> TimeInterval
    private let visible: (NSView) -> Bool
    private let automatic: Bool
    private(set) var callbackCount = 0
    private(set) var workCount = 0
    private(set) var noWorkCount = 0
    private(set) var longestUnit: TimeInterval = 0
    /// How many units of getting-ready work have run, as distinct from
    /// measuring history nobody is looking at.
    private(set) var preparationCount = 0

    init(automatic: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         visible: @escaping (NSView) -> Bool = {
             guard let window = $0.window else { return false }
             return !$0.isHiddenOrHasHiddenAncestor && window.isVisible && !window.isMiniaturized
                 && window.occlusionState.contains(.visible)
         }) {
        self.automatic = automatic; self.clock = clock; self.visible = visible
        guard automatic else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.pauseForInput() }
            return event
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            })
        }
    }
    deinit {
        wakeup?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func request(_ owner: NSView, work: Work = .reconciliation, after deadline: TimeInterval, step: @escaping () -> Bool) {
        if let index = jobs.firstIndex(where: { $0.owner === owner && $0.work == work }) {
            jobs[index].readyAt = work == .preparation ? min(jobs[index].readyAt, deadline)
                : min(max(jobs[index].readyAt, deadline), max(jobs[index].since + Self.longestDeferral, jobs[index].readyAt))
            jobs[index].step = step
        } else { jobs.append(Job(owner: owner, work: work, readyAt: deadline, since: clock(), step: step)) }
        reschedule()
    }
    func cancel(_ owner: NSView) {
        jobs.removeAll { $0.owner == nil || $0.owner === owner }
        reschedule()
    }
    func cancel(_ owner: NSView, work: Work) {
        jobs.removeAll { $0.owner == nil || ($0.owner === owner && $0.work == work) }
        reschedule()
    }
    var remainingInputQuietTime: TimeInterval { max(0, inputQuietUntil - clock()) }
    func pauseForInput() {
        inputQuietUntil = clock() + TranscriptNativeDocument.sliceQuietPeriod
        reschedule()
    }
    func visibilityChanged() { reschedule() }
    private func reschedule() {
        guard automatic, !running else { return }
        jobs.removeAll { $0.owner == nil }
        let deadline = jobs.compactMap { job -> TimeInterval? in
            guard let owner = job.owner, visible(owner) else { return nil }
            return max(job.readyAt, job.work == .preparation ? 0 : inputQuietUntil, nextAllowedAt)
        }.min()
        guard let deadline else {
            wakeup?.cancel(); wakeup = nil; nextWake = nil
            return
        }
        // A newer delta moves the quiet deadline rather than waking every 4ms.
        // Keep an earlier wake only when it is already due this run-loop turn.
        if let nextWake, abs(nextWake - deadline) < 0.001 { return }
        wakeup?.cancel()
        nextWake = deadline
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeup = nil; self.nextWake = nil
            self.runReady()
            self.reschedule()
        }
        wakeup = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - clock()), execute: item)
    }
    /// Deterministic seam: fixtures supply a clock and visibility policy and
    /// account for work performed inside the callback, including host creation.
    func runReady() {
        running = true
        defer { running = false }
        callbackCount += 1
        let start = clock(), deadline = start + Self.budget
        // Input pauses the work that waits for quiet, not the work that is
        // getting ready for where the input is taking the reader.
        guard start >= nextAllowedAt,
              start >= inputQuietUntil || jobs.contains(where: { $0.work == .preparation && $0.readyAt <= start }) else { noWorkCount += 1; return }
        var worked = false
        // Remove before calling: a step may enqueue its successor or another
        // pane. Rotation also prevents a long history from starving its side.
        // A cheap host must not consume an entire frame's allowance. Rotate
        // after every unit and keep using the shared time budget while some
        // owner is ready. Bound zero-duration units too (including test clocks).
        var skipped = 0, units = 0
        while !jobs.isEmpty, clock() < deadline, units < 32 {
            var job = jobs.removeFirst()
            guard let owner = job.owner else { continue }
            guard visible(owner), job.readyAt <= clock(),
                  job.work == .preparation || clock() >= inputQuietUntil else {
                jobs.append(job); skipped += 1
                if skipped >= jobs.count { break }
                continue
            }
            let began = clock()
            let more = job.step()
            longestUnit = max(longestUnit, clock() - began)
            workCount += 1; worked = true; units += 1; skipped = 0
            if job.work == .preparation { preparationCount += 1 }
            if !jobs.contains(where: { $0.owner === owner && $0.work == job.work }), more {
                job.readyAt = clock(); jobs.append(job)
            }
        }
        if worked { nextAllowedAt = clock() + Self.interval }
        else { noWorkCount += 1 }
    }
}
