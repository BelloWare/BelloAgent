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

    func checkForUpdates() {
        guard !hasActiveWork() else {
            let alert = NSAlert()
            alert.messageText = "Finish or stop active work before updating."
            alert.runModal()
            return
        }
        controller?.checkForUpdates(nil)
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        if rejectNextInstall { rejectNextInstall = false; return false }
        return !hasActiveWork() && acquireBarrier()
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Task {
            do { try await prepareForInstall(); installHandler() }
            catch {
                rejectNextInstall = true; releaseBarrier(); reportFailure(error.localizedDescription)
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
