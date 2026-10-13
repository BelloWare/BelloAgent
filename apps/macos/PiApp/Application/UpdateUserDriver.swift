import AppKit
import Sparkle

/// Sparkle's standard user driver, with the two alerts it shows as a modal
/// loop — "You're up to date" and an update error — shown as sheets instead
/// (`PiQuestion`). The standard driver runs them as application-modal alerts
/// inside a main-queue callback, and the main queue does not run anything
/// else until it returns: every chat streaming meanwhile stopped updating
/// until the alert was dismissed. Updates are checked with chats running
/// since 0.1.125. Everything else is the standard driver's own windows.
@MainActor
final class UpdateUserDriver: NSObject, @preconcurrency SPUUserDriver {
    let standard: SPUStandardUserDriver
    /// Its own asker: a sheet another screen has up never refuses, and so
    /// never drops, an update's result.
    let questions: PiQuestion
    /// Results waiting for a sheet: the one up now answered, or a window to
    /// put one on. None is dropped, and none falls back to a modal loop.
    private(set) var pending: [NSAlert] = []
    private var windowObserver: NSObjectProtocol?
    init(standard: SPUStandardUserDriver, questions: PiQuestion = PiQuestion()) {
        self.standard = standard; self.questions = questions; super.init()
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let recovery = (error as NSError).localizedRecoverySuggestion
        present(title: recovery == nil ? "Bello Agent is up to date" : error.localizedDescription,
                detail: recovery ?? "There is no newer version to install.", button: "OK")
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let recovery = (error as NSError).localizedRecoverySuggestion
        present(title: recovery == nil ? "Update Error" : error.localizedDescription,
                detail: recovery ?? error.localizedDescription, button: "Cancel Update")
        acknowledgement()
    }
    /// Closes the standard driver's checking and progress windows, as its
    /// own versions of the two methods above do first, then says it on a sheet.
    private func present(title: String, detail: String, button: String) {
        standard.dismissUpdateInstallation()
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button)
        pending.append(alert); presentNext()
    }
    /// The next waiting result, on a sheet, when one can go up. With no
    /// window to hold it (the workspace closed meanwhile), it waits for one.
    func presentNext() {
        guard let alert = pending.first, !questions.asking else { return }
        guard questions.answerAlert != nil || PiQuestion.host() != nil else {
            if windowObserver == nil {
                windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let observer = self.windowObserver { NotificationCenter.default.removeObserver(observer) }
                        self.windowObserver = nil; self.presentNext()
                    }
                }
            }
            return
        }
        pending.removeFirst()
        questions.ask(alert, over: nil) { [weak self] _ in self?.presentNext() }
    }
    /// Sparkle calls this on its driver at launch (`SPUGentleUserDriverReminders`):
    /// the standard driver's launch-time update notice depends on it.
    @objc func resetTimeSinceOpportuneUpdateNotice() {
        let selector = NSSelectorFromString("resetTimeSinceOpportuneUpdateNotice")
        if standard.responds(to: selector) { _ = standard.perform(selector) }
    }

    // Everything else: the standard driver.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { standard.show(request, reply: reply) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { standard.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { standard.showReady(toInstallAndRelaunch: reply) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
}
