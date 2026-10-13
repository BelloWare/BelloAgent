import XCTest
import AppKit
import Sparkle
@testable import PiApp

/// Updating while chats run (0.1.125, owner: check first, pause only to
/// install): Check for Updates checks at once and pauses nothing. Only when
/// an update is installed (Install and Relaunch, from a check or Sparkle's
/// own offer) is the reader asked, once, whether to pause the running chats;
/// on Pause they pause as Quit pauses them and the install goes ahead.
/// Cancel aborts the install and changes nothing. Sparkle itself is never
/// reached: its check and its relaunch are the controller's seams.
final class UpdatePauseTests: XCTestCase {
    /// The controller with every seam recorded, and the question answered `answer`.
    @MainActor private final class Rig {
        let controller = UpdateController()
        var steps: [String] = []
        var active = true
        var questions: [NSAlert] = []
        init(answer: NSApplication.ModalResponse, pauseFails: Bool = false) {
            controller.hasActiveWork = { [unowned self] in active }
            controller.runningChats = { 2 }
            controller.acquireBarrier = { [unowned self] in guard !active else { return false }; steps.append("barrier"); return true }
            controller.prepareForInstall = { [unowned self] in steps.append("prepare") }
            controller.releaseBarrier = { [unowned self] in steps.append("release") }
            controller.reportFailure = { [unowned self] in steps.append("failure: " + $0) }
            controller.pauseActiveWork = { [unowned self] in
                steps.append("pause")
                if pauseFails { throw HostError.failure("drafts could not be saved") }
                active = false
            }
            controller.startCheckForTesting = { [unowned self] in steps.append("check") }
            PiQuestion.shared.answerAlert = { [unowned self] alert in questions.append(alert); return answer }
        }
    }
    override func tearDown() async throws {
        await MainActor.run { PiQuestion.shared.answerAlert = nil }
    }
    @MainActor private func settled(_ rig: Rig, until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A check with chats running checks at once: no question, nothing paused.
    /// An update not found, or found and declined, changes nothing.
    @MainActor func testACheckWithChatsRunningChecksWithoutAskingOrPausing() async {
        let rig = Rig(answer: .alertFirstButtonReturn)
        rig.controller.checkForUpdates()
        XCTAssertEqual(rig.steps, ["check"]); XCTAssertTrue(rig.questions.isEmpty)
        XCTAssertTrue(rig.active, "the chats keep running")
        rig.active = false
        rig.controller.checkForUpdates()
        XCTAssertEqual(rig.steps, ["check", "check"]); XCTAssertTrue(rig.questions.isEmpty)
    }

    /// Sparkle's "up to date" and error alerts come as sheets: the standard
    /// driver runs them modally inside a main-queue callback, which would stop
    /// every chat streaming during a check. Both are acknowledged at once.
    @MainActor func testSparklesResultAlertsAreSheetsNotModalLoops() {
        var asked: [NSAlert] = []
        PiQuestion.shared.answerAlert = { asked.append($0); return .alertFirstButtonReturn }
        let driver = UpdateUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: nil))
        var acknowledged = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "SUSparkleErrorDomain", code: 1001)) { acknowledged += 1 }
        driver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: "The feed could not be read."])) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 2)
        XCTAssertEqual(asked.map(\.messageText), ["Bello Agent is up to date", "Update Error"])
        XCTAssertEqual(asked.last?.informativeText, "The feed could not be read.")
    }

    /// The pause failing at install says so and installs nothing.
    @MainActor func testAPauseThatFailsAbortsTheInstall() async {
        let rig = Rig(answer: .alertFirstButtonReturn, pauseFails: true)
        XCTAssertTrue(rig.controller.shouldRelaunch())
        var handled = 0
        _ = rig.controller.postponeRelaunch { handled += 1 }
        await settled(rig) { handled == 1 }
        XCTAssertEqual(rig.steps.first, "pause")
        XCTAssertFalse(rig.steps.contains("prepare"))
        XCTAssertTrue(rig.steps.contains { $0.hasPrefix("failure: Chats could not be paused for the update") }, "\(rig.steps)")
        XCTAssertFalse(rig.controller.shouldRelaunch(), "the install is aborted")
    }

    /// Install and Relaunch while chats run (after a check, or from Sparkle's
    /// own offer): asked once, paused, then the install is prepared and the
    /// relaunch goes ahead.
    @MainActor func testInstallingOverRunningChatsAsksPausesThenRelaunches() async {
        let rig = Rig(answer: .alertFirstButtonReturn)
        XCTAssertTrue(rig.controller.shouldRelaunch())
        var handled = 0
        XCTAssertTrue(rig.controller.postponeRelaunch { handled += 1 })
        await settled(rig) { handled == 1 }
        XCTAssertEqual(rig.steps, ["pause", "barrier", "prepare"])
        XCTAssertEqual(rig.questions.count, 1, "asked once")
        XCTAssertEqual(rig.questions.first?.messageText, "Pause 2 running chats and install?")
        XCTAssertEqual(rig.questions.first?.buttons.map(\.title), ["Pause and Install", "Cancel"])
        XCTAssertEqual(handled, 1)
        // Sparkle asks again from the install handler: the barrier is held.
        XCTAssertTrue(rig.controller.shouldRelaunch())
    }

    /// Cancel at that question: nothing is paused, the chats keep running,
    /// and the install aborts through Sparkle's relaunch decision, quietly.
    @MainActor func testCancelAtTheInstallQuestionAbortsItAndPausesNothing() async {
        let rig = Rig(answer: .alertSecondButtonReturn)
        XCTAssertTrue(rig.controller.shouldRelaunch())
        var handled = 0
        _ = rig.controller.postponeRelaunch { handled += 1 }
        await settled(rig) { handled == 1 }
        XCTAssertEqual(rig.steps, ["release"], "no pause, no prepare, no failure banner")
        XCTAssertFalse(rig.controller.shouldRelaunch(), "the re-entered decision aborts the install")
        XCTAssertTrue(rig.active)
    }

    /// Without active work Sparkle's install goes as it always did: no question.
    @MainActor func testAnIdleInstallAsksNothing() async {
        let rig = Rig(answer: .alertSecondButtonReturn); rig.active = false
        XCTAssertTrue(rig.controller.shouldRelaunch())
        var handled = 0
        _ = rig.controller.postponeRelaunch { handled += 1 }
        await settled(rig) { handled == 1 }
        XCTAssertEqual(rig.steps, ["barrier", "prepare"]); XCTAssertTrue(rig.questions.isEmpty)
    }
}
