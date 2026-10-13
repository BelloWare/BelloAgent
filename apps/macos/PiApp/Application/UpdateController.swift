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
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private var started = false

    override init() {
        let configuration = ReleaseConfiguration.current
        configurationError = configuration.error
        super.init()
        guard configuration.error == nil,
              ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] available in self?.canCheckForUpdates = available }
    }

    func configure(automaticChecks: Bool, configurationAvailable: Bool) {
        guard let controller else { return }
        // The vault is the configuration authority. Sparkle's internal defaults
        // are overwritten before it starts; it never chooses this preference.
        controller.updater.automaticallyChecksForUpdates = configurationAvailable && automaticChecks
        guard configurationAvailable, !started else { return }
        controller.startUpdater(); started = true
    }

    /// Pauses every running chat as Quit does, before an update. Set by the
    /// workspace model (`pauseRunsForUpdate`).
    var pauseActiveWork: () async throws -> Void = {}
    /// How many chats are running, for the question's words.
    var runningChats: () -> Int = { 0 }
    /// Test seam: what starts Sparkle's own check. Nil in the app.
    var startCheckForTesting: (() -> Void)?
    /// Set when Sparkle is about to relaunch while work is active: the
    /// postponement asks whether to pause it first.
    private var pauseBeforeRelaunch = false
    /// The question is up, or the pause it led to is under way: a second
    /// Check for Updates does nothing meanwhile.
    private(set) var pausing = false

    /// Check for Updates. With chats running, asks once whether to pause them
    /// (a sheet, never a modal loop: an update check must not stop the runs
    /// it is asking about); on Pause and Check they pause as Quit pauses them,
    /// then Sparkle checks. Whatever Sparkle finds — an update installed, one
    /// declined, or none — the paused chats wait for Resume. Cancel changes nothing.
    func checkForUpdates() {
        guard !pausing else { return }
        guard hasActiveWork() else { startCheck(); return }
        pausing = true
        askToPause(installing: false) { [weak self] confirmed in
            guard let self else { return }
            guard confirmed else { self.pausing = false; return }
            Task { @MainActor in
                defer { self.pausing = false }
                do { try await self.pauseActiveWork() }
                catch { self.reportFailure("Chats could not be paused for the update. \(error.localizedDescription)"); return }
                self.startCheck()
            }
        }
    }
    private func startCheck() {
        if let startCheckForTesting { startCheckForTesting(); return }
        controller?.checkForUpdates(nil)
    }
    /// The one question, for Check for Updates and for an install Sparkle
    /// offered on its own. True for Pause.
    private func askToPause(installing: Bool, answered: @escaping (Bool) -> Void) {
        let count = max(1, runningChats())
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Pause the running chat and update?" : "Pause \(count) running chats and update?"
        alert.informativeText = "They pause as they do when you quit: a reply that was arriving is kept as it is, and a tool call that was cut off is not run again. Each paused chat shows Resume, after the update or if you don’t install one. Side chats that were not kept close; what you typed in them moves to their chats."
        alert.addButton(withTitle: installing ? "Pause and Install" : "Pause and Check")
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
    /// Holds Sparkle's relaunch while the install is prepared: running chats
    /// are paused first when the reader agrees (Install and Relaunch chosen
    /// from Sparkle's own offer), then the barrier, drafts and helpers are
    /// settled as before. A refusal or failure aborts the install.
    func postponeRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
        let pauseFirst = pauseBeforeRelaunch; pauseBeforeRelaunch = false
        Task { @MainActor in
            do {
                if pauseFirst {
                    pausing = true; defer { pausing = false }
                    let confirmed = await withCheckedContinuation { continuation in askToPause(installing: true) { continuation.resume(returning: $0) } }
                    guard confirmed else { throw UpdateDeclined() }
                    try await pauseActiveWork()
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
