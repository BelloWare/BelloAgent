import AppKit
import Combine
import Sparkle

@MainActor
// Sparkle 2.8.1's Objective-C delegate is main-thread-only but lacks Swift actor annotations.
final class UpdateController: NSObject, ObservableObject, @preconcurrency SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    let configurationError: String?
    // The workspace supervisor will provide this before a host is introduced.
    var hasActiveWork: () -> Bool = { false }
    var acquireBarrier: () -> Bool = { true }
    var prepareForInstall: () async throws -> Void = {}
    var releaseBarrier: () -> Void = {}
    var reportFailure: (String) -> Void = { _ in }
    private var rejectNextInstall = false
    private var updater: SPUUpdater?
    /// Sparkle's standard windows, with its result and error alerts as sheets.
    private var userDriver: UpdateUserDriver?
    private var observation: AnyCancellable?
    private var started = false

    override init() {
        let configuration = ReleaseConfiguration.current
        configurationError = configuration.error
        super.init()
        #if !PI_TEST_HOST && !PI_LAUNCH_FIXTURE
        guard configuration.error == nil,
              ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // What SPUStandardUpdaterController builds, with the standard user
        // driver wrapped: its "up to date" and error alerts run a modal loop
        // inside a main-queue callback, which stops every streaming chat
        // until dismissed. Updates are checked with chats running (0.1.125).
        let driver = UpdateUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: nil))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        userDriver = driver; self.updater = updater
        observation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] available in self?.canCheckForUpdates = available }
        #endif
    }

    func configure(automaticChecks: Bool, configurationAvailable: Bool) {
        guard let updater else { return }
        // The vault is the configuration authority. Sparkle's internal defaults
        // are overwritten before it starts; it never chooses this preference.
        updater.automaticallyChecksForUpdates = configurationAvailable && automaticChecks
        guard configurationAvailable, !started else { return }
        started = true
        do { try updater.start() } catch { started = false; reportFailure("The updater could not start. \(error.localizedDescription)") }
    }

    /// Pauses every running chat as Quit does, before an update installs.
    /// Set by the workspace model (`pauseRunsForUpdate`).
    var pauseActiveWork: () async throws -> Void = {}
    /// How many chats are running, for the question's words.
    var runningChats: () -> Int = { 0 }
    /// Test seam: what starts Sparkle's own check. Nil in the app.
    var startCheckForTesting: (() -> Void)?
    /// Set when Sparkle is about to relaunch while work is active: the
    /// postponement asks whether to pause it first.
    private var pauseBeforeRelaunch = false
    /// The pause question is up, or the pause it led to is under way.
    private(set) var pausing = false

    /// Check for Updates: Sparkle checks at once, running chats or not
    /// (owner, 0.1.125: check first, pause only to install). Nothing is
    /// paused by a check; an update found and declined, or none found,
    /// changes nothing. Running chats are asked about only when an update is
    /// installed (`postponeRelaunch`). Sparkle's "up to date" and error
    /// alerts come as sheets (`UpdateUserDriver`), so a check never stops
    /// the chats streaming meanwhile.
    func checkForUpdates() { startCheck() }
    private func startCheck() {
        if let startCheckForTesting { startCheckForTesting(); return }
        updater?.checkForUpdates()
    }
    /// The one question, asked when an update is about to install over
    /// running chats. True for Pause and Install. A sheet, never a modal
    /// loop: the question must not stop the runs it is asking about.
    private func askToPause(answered: @escaping (Bool) -> Void) {
        let count = max(1, runningChats())
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Pause the running chat and install?" : "Pause \(count) running chats and install?"
        alert.informativeText = "They pause as they do when you quit: a reply that was arriving is kept as it is, and a tool call that was cut off is not run again. After the update, each paused chat shows Resume. Side chats that were not kept close; what you typed in them moves to their chats. Cancel installs nothing and leaves the chats running."
        alert.addButton(withTitle: "Pause and Install")
        alert.addButton(withTitle: "Cancel")
        if !PiQuestion.shared.ask(alert, over: nil, answered: { answered($0 == .alertFirstButtonReturn) }) {
            // Another question is up: this one was never asked.
            reportFailure(PiQuestion.busyNotice); answered(false)
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { shouldRelaunch() }
    /// Sparkle's relaunch decision. With active work the relaunch goes ahead
    /// only through the postponement below, which asks to pause it first.
    func shouldRelaunch() -> Bool {
        if rejectNextInstall { rejectNextInstall = false; return false }
        if !hasActiveWork() && acquireBarrier() { return true }
        pauseBeforeRelaunch = true
        return true
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunch(installHandler)
    }
    /// Holds Sparkle's relaunch while the install is prepared: with chats
    /// running, the reader is asked once whether to pause them (Install and
    /// Relaunch chosen from a check or from Sparkle's own offer); on Pause
    /// they pause as Quit pauses them, then the barrier, drafts and helpers
    /// are settled as before. Cancel, or a failure, aborts the install and
    /// leaves the chats as they were.
    func postponeRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
        let pauseFirst = pauseBeforeRelaunch; pauseBeforeRelaunch = false
        Task { @MainActor in
            do {
                if pauseFirst {
                    pausing = true; defer { pausing = false }
                    let confirmed = await withCheckedContinuation { continuation in askToPause { continuation.resume(returning: $0) } }
                    guard confirmed else { throw UpdateDeclined() }
                    do { try await pauseActiveWork() }
                    catch { throw HostError.failure("Chats could not be paused for the update, so it was not installed. \(error.localizedDescription)") }
                    guard !hasActiveWork(), acquireBarrier() else { throw HostError.failure("Work started again before the update could install. Pause it and try again.") }
                }
                try await prepareForInstall(); installHandler()
            } catch {
                rejectNextInstall = true; releaseBarrier()
                if !(error is UpdateDeclined) { reportFailure(error.localizedDescription) }
                // Sparkle re-enters updaterShouldRelaunchApplication; false
                // aborts this install through its public delegate contract.
                installHandler()
            }
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { releaseBarrier() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { releaseBarrier() }
    }
}

/// The reader chose Cancel at the pause question: the install stops quietly.
private struct UpdateDeclined: Error {}
