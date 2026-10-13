import XCTest
import AppKit
@testable import PiApp

/// Check for Updates while chats run (0.1.125): instead of refusing, it asks
/// once whether to pause them; on Pause they pause as Quit pauses them, and
/// only then does Sparkle check. Cancel changes nothing. An install Sparkle
/// offered on its own asks the same before it relaunches. Sparkle itself is
/// never reached: its check and its relaunch are the controller's seams.
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

    @MainActor func testWithNothingRunningTheCheckStartsWithoutAQuestion() async {
        let rig = Rig(answer: .alertFirstButtonReturn); rig.active = false
        rig.controller.checkForUpdates()
        XCTAssertEqual(rig.steps, ["check"]); XCTAssertTrue(rig.questions.isEmpty)
    }

    @MainActor func testPauseAndCheckPausesTheRunsThenChecks() async {
        let rig = Rig(answer: .alertFirstButtonReturn)
        rig.controller.checkForUpdates()
        await settled(rig) { rig.steps.contains("check") }
        XCTAssertEqual(rig.steps, ["pause", "check"], "the runs pause before Sparkle checks")
        let question = try? XCTUnwrap(rig.questions.first)
        XCTAssertEqual(rig.questions.count, 1, "asked once")
        XCTAssertEqual(question?.messageText, "Pause 2 running chats and update?")
        XCTAssertEqual(question?.buttons.map(\.title), ["Pause and Check", "Cancel"])
        XCTAssertFalse(rig.controller.pausing)
    }

    @MainActor func testCancelLeavesTheRunsAloneAndChecksNothing() async {
        let rig = Rig(answer: .alertSecondButtonReturn)
        rig.controller.checkForUpdates()
        await settled(rig) { !rig.controller.pausing }
        XCTAssertEqual(rig.steps, [], "nothing paused, nothing checked")
        XCTAssertTrue(rig.active)
    }

    @MainActor func testAPauseThatFailsSaysSoAndDoesNotCheck() async {
        let rig = Rig(answer: .alertFirstButtonReturn, pauseFails: true)
        rig.controller.checkForUpdates()
        await settled(rig) { !rig.controller.pausing && rig.steps.count >= 2 }
        XCTAssertEqual(rig.steps.first, "pause")
        XCTAssertTrue(rig.steps.last?.hasPrefix("failure: Chats could not be paused") == true, "\(rig.steps)")
        XCTAssertFalse(rig.steps.contains("check"))
    }

    /// Sparkle offered an update on its own and the reader chose Install and
    /// Relaunch while chats ran: asked once, paused, then the install is
    /// prepared and the relaunch goes ahead.
    @MainActor func testSparklesOwnInstallAsksPausesThenRelaunches() async {
        let rig = Rig(answer: .alertFirstButtonReturn)
        XCTAssertTrue(rig.controller.shouldRelaunch())
        var handled = 0
        XCTAssertTrue(rig.controller.postponeRelaunch { handled += 1 })
        await settled(rig) { handled == 1 }
        XCTAssertEqual(rig.steps, ["pause", "barrier", "prepare"])
        XCTAssertEqual(rig.questions.first?.buttons.first?.title, "Pause and Install")
        XCTAssertEqual(handled, 1)
        // Sparkle asks again from the install handler: the barrier is held.
        XCTAssertTrue(rig.controller.shouldRelaunch())
    }

    /// Cancel at that question: nothing is paused, and the install aborts
    /// through Sparkle's relaunch decision, quietly.
    @MainActor func testDecliningSparklesInstallAbortsItAndPausesNothing() async {
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
