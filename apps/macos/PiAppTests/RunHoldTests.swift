import XCTest
import Combine
@testable import PiApp

/// Paused after a restart (0.1.122): a chat whose run was stopped, cut off,
/// or holds work waiting for Resume still says so after the app restarts —
/// on its sidebar row before it is opened, and in the chat once it is. The
/// journal decides; the app keeps a small hold record per chat so the row
/// can say it at once (`WorkspaceRunHolds.swift`). The real-helper relaunch
/// is `LifecycleHelperTests.testAPausedChatIsStillPausedAfterARelaunch`.
final class RunHoldTests: XCTestCase {
    /// A journal as the helper writes one: sorted keys, a session header,
    /// a question, a reply, then run-state records.
    private func journal(_ states: [[String: WireValue]], padding: Int = 0) throws -> String {
        var data = Data(), parent: String?
        func append(_ id: String, _ fields: [String: WireValue], timestamp: Bool = true) throws {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            if timestamp { record["timestamp"] = .string("2026-10-08T12:00:00Z") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data.append(try encoder.encode(record)); data.append(10); parent = id
        }
        try append("chat", ["type": .string("session"), "version": .number(3)], timestamp: false); parent = nil
        try append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1")])
        try append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Question")])])
        for (index, state) in states.enumerated() {
            try append("state-\(index)", ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(state)])
        }
        if padding > 0 {
            try append("answer", ["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .string(String(repeating: "x", count: padding))])])
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("run-hold-" + UUID().uuidString + ".jsonl")
        try data.write(to: path); addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path.path
    }
    private let running: [String: WireValue] = ["active": .bool(true), "queue": .array([]), "steering": .array([]), "runStatus": .string("running"), "queuePaused": .bool(false)]
    private let stopped: [String: WireValue] = ["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("cancelled"), "queuePaused": .bool(true)]
    private let finished: [String: WireValue] = ["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("completed"), "queuePaused": .bool(false)]
    private let failed: [String: WireValue] = ["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("failed"), "queuePaused": .bool(true), "errorMessage": .string("Gateway said no")]
    private var queued: [String: WireValue] {
        var value = finished
        value["queue"] = .array([.object(["commandID": .string("c1"), "turnID": .string("t1"), "text": .string("and then summarize"), "attachments": .array([]), "skills": .array([])])])
        return value
    }

    /// Stopped with nothing queued was read as idle: the chat came back
    /// "Ready" although its helper restores it paused.
    func testAStoppedRunWithNothingQueuedIsReadAsPaused() async throws {
        let page = try await HistoryReader().read(path: try journal([running, stopped]))
        let run = try XCTUnwrap(page.retainedRun, "a stopped run leaves the chat waiting for Resume")
        XCTAssertFalse(run.active); XCTAssertTrue(run.queuePaused); XCTAssertTrue(run.queue.isEmpty)
        let done = try await HistoryReader().read(path: try journal([running, finished]))
        XCTAssertNil(done.retainedRun, "a finished run leaves nothing")
        let failure = try await HistoryReader().read(path: try journal([running, failed]))
        XCTAssertNil(failure.retainedRun, "a failure is shown as a failure"); XCTAssertEqual(failure.failureMessage, "Gateway said no")
    }

    func testTheEndOfAJournalSaysWhetherTheChatWaits() throws {
        XCTAssertEqual(JournalRunHold.read(path: try journal([running, stopped])), .held("paused"))
        XCTAssertEqual(JournalRunHold.read(path: try journal([running, queued])), .held("paused"))
        XCTAssertEqual(JournalRunHold.read(path: try journal([stopped, running])), .held("interrupted"))
        XCTAssertEqual(JournalRunHold.read(path: try journal([stopped, finished])), .clear, "only the newest state counts")
        XCTAssertEqual(JournalRunHold.read(path: try journal([running, failed])), .clear)
        XCTAssertEqual(JournalRunHold.read(path: try journal([])), .clear, "a journal that never ran has nothing waiting")
        XCTAssertEqual(JournalRunHold.read(path: "/nonexistent/journal.jsonl"), .clear, "a journal that is gone has nothing to resume")
        // A state further back than the window is unknown, not a guess.
        XCTAssertEqual(JournalRunHold.read(path: try journal([stopped], padding: 40_000), window: 16_384), .unknown)
        XCTAssertEqual(JournalRunHold.read(path: try journal([], padding: 40_000), window: 16_384), .unknown)
        XCTAssertEqual(JournalRunHold.read(path: try journal([stopped], padding: 40_000), window: 65_536), .held("paused"))
    }

    /// Round 8: a root whose own Resume was accepted before its sides were
    /// resumed keeps their ids (`costPausedMembers`) without `costPaused`; a
    /// journal-only read shows the family's pause, as the helper does.
    func testAJournalWithSidesStillWaitingReadsAsPaused() throws {
        var waiting = finished; waiting["costPausedMembers"] = .array([.string("side")])
        XCTAssertEqual(JournalRunHold.read(path: try journal([running, waiting])), .held("paused"))
        var none = finished; none["costPausedMembers"] = .array([])
        XCTAssertEqual(JournalRunHold.read(path: try journal([running, none])), .clear)
    }

    /// Round 8: a family Resume reaches paused sides ancestors first, so a
    /// nested side never meets its still-paused parent's pause.
    @MainActor func testPausedSidesResumeAncestorsFirst() {
        let parents = ["nested": "side", "side": "root", "other": "root", "deeper": "nested"]
        let order = WorkspaceModel.ancestorsFirst(["deeper", "nested", "other", "side"]) { parents[$0] }
        XCTAssertEqual(order, ["other", "side", "nested", "deeper"])
    }

    @MainActor func testADisplaysHoldFollowsItsRun() {
        let view = SessionDisplay(id: "c")
        XCTAssertNil(view.runHold)
        view.runState = .running; XCTAssertEqual(view.runHold, "active")
        view.runState = .paused; XCTAssertEqual(view.runHold, "paused")
        view.runState = .interrupted; XCTAssertEqual(view.runHold, "interrupted")
        view.runState = .idle; view.uncertain = true; XCTAssertEqual(view.runHold, "interrupted")
        view.uncertain = false; view.queuePaused = true; view.queue = [["turnId": .string("t")]]; XCTAssertEqual(view.runHold, "paused")
        view.runState = .error; XCTAssertNil(view.runHold, "a failure is not a hold")
        XCTAssertEqual(RunHoldRecord(id: "c", state: "active").presented, "paused", "a run under way when the app quit was stopped by the quit")
    }

    /// Resume (0.1.125) is offered where the run stopped: a paused chat the
    /// helper can continue (or whose helper has not said, as after a
    /// restart) ends with the Paused row; one with nothing to continue, one
    /// running, or one whose Resume is on its way does not. A run a restart
    /// cut off, read from the journal, offers Resume on its failure row.
    @MainActor func testAPausedChatOffersResumeWhereItStopped() {
        let view = SessionDisplay(id: "c")
        view.observeRunState(["state": .string("paused"), "runStatus": .string("cancelled"), "queuePaused": .bool(true), "continuable": .bool(true)])
        XCTAssertTrue(view.offersResume)
        XCTAssertEqual(view.presentedMessages.last?.id, "paused:run:c")
        XCTAssertEqual(view.presentedMessages.last?.failureCode, SessionDisplay.pausedCode)
        XCTAssertNil(view.presentedMessages.last?.detail)
        view.queue = [["turnId": .string("t")]]
        XCTAssertEqual(view.presentedMessages.last?.detail, "Queued follow-ups go on after it.")
        view.resuming = true
        XCTAssertFalse(view.offersResume, "one Resume at a time")
        XCTAssertEqual(view.presentedMessages.last?.failureCode, SessionDisplay.pausedResumingCode, "the row stays, without its button")
        view.resuming = false
        view.observeRunState(["state": .string("paused"), "runStatus": .string("cancelled"), "queuePaused": .bool(true), "continuable": .bool(false)])
        XCTAssertFalse(view.offersResume, "nothing the model has not answered: the queue's Resume is the one")
        view.observeRunState(["state": .string("running"), "runStatus": .string("running"), "continuable": .bool(false)])
        XCTAssertFalse(view.offersResume)
        // An older helper says nothing: Resume stays offered for a paused chat.
        view.observeRunState(["state": .string("paused"), "runStatus": .string("cancelled"), "queuePaused": .bool(true)])
        XCTAssertNil(view.continuable); XCTAssertTrue(view.offersResume)

        let cut = SessionDisplay(id: "d")
        cut.runState = .interrupted; cut.failureMessage = "The previous run was interrupted before it finished."
        XCTAssertEqual(cut.presentedMessages.last?.id, "failure:run:d")
        XCTAssertEqual(cut.presentedMessages.last?.failureCode, SessionDisplay.interruptedCode)
        cut.resuming = true
        XCTAssertEqual(cut.presentedMessages.last?.failureCode, SessionDisplay.resumingCode, "no Retry in Resume's place while it is on its way")
    }

    /// A helper that died mid-run said "nothing to continue" while it ran:
    /// that no longer stands, and the interrupted chat offers Resume.
    @MainActor func testALostHelperForgetsWhetherTheChatCouldContinue() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-lost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        let view = SessionDisplay(id: "c")
        view.observeRunState(["state": .string("running"), "runStatus": .string("running"), "continuable": .bool(false)])
        XCTAssertEqual(view.continuable, false)
        model.settlePausedForUpdate(view)
        XCTAssertNil(view.continuable); XCTAssertEqual(view.runState, .paused); XCTAssertTrue(view.offersResume)
        XCTAssertFalse(view.uncertain, "a pause for an update is not a crash")
        await close(model)
    }

    /// An update's pause lets a send already under way finish first (its
    /// run is then paused with the rest), holds new ones off meanwhile, and
    /// says so if the send does not finish in time.
    @MainActor func testTheUpdatePauseWaitsForASendUnderWay() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        let view = SessionDisplay(id: "c"); view.loading = true; model.displays["c"] = view
        let pause = Task { try await model.pauseRunsForUpdate() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        // Still waiting: the pause holds the barrier until it ends.
        XCTAssertTrue(model.installPreparing, "the send under way finishes first, and no new work starts meanwhile")
        view.loading = false
        try await pause.value
        XCTAssertFalse(model.installPreparing, "the app takes work again after the pause")
        view.loading = true
        do { try await model.pauseRunsForUpdate(settleTimeout: 0.05); XCTFail("a send that never finishes holds the pause") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still being sent"), error.localizedDescription) }
        XCTAssertFalse(model.installPreparing)
        // A command opening its chat's session (awaiting credentials) gets there first too.
        model.sessionOpenCallers["c"] = 1
        do { try await model.pauseRunsForUpdate(settleTimeout: 0.05); XCTFail("an open under way holds the pause") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still being sent"), error.localizedDescription) }
        model.sessionOpenCallers["c"] = nil
        // A background request loading for as long as its model answers does not hold the pause.
        var probe = ChatRecord(id: "t", workspaceID: "w", title: "T", path: nil, profileID: "p"); probe.connectionTest = true
        model.chats = [probe]; view.loading = false
        let background = SessionDisplay(id: "t"); background.loading = true; model.displays["t"] = background
        try await model.pauseRunsForUpdate(settleTimeout: 0.05)
        // But its session being opened does: once open it would start a helper the pause did not stop.
        model.sessionOpenCallers["t"] = 1
        do { try await model.pauseRunsForUpdate(settleTimeout: 0.05); XCTFail("a background open under way holds the pause") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still being sent"), error.localizedDescription) }
        model.sessionOpenCallers["t"] = nil
        // A title being generated ends with the pause, so nothing holds the install after it.
        model.displays["t"] = nil
        model.titleGenerationTasks["c"] = Task { [weak model] in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            model?.titleGenerationTasks["c"] = nil
        }
        XCTAssertTrue(model.hasActiveWork)
        try await model.pauseRunsForUpdate(settleTimeout: 0.05)
        XCTAssertFalse(model.hasActiveWork, "the update's barrier can be taken right after the pause")
        // A title the pause cut off is asked again on the chat's next send.
        var source = ChatRecord(id: "s", workspaceID: "w", title: "S", path: nil, profileID: "p"); source.titleTaskSessionID = "tt"
        var titleTask = ChatRecord(id: "tt", workspaceID: "w", title: "Title", path: nil, profileID: "p")
        titleTask.backgroundTask = BackgroundRequestKind.title.raw; titleTask.backgroundTaskNotice = "Title generation interrupted. Nothing was retried."
        titleTask.backgroundTaskOutcome = "failed"
        model.chats = [source, titleTask]
        model.titleGenerationTasks["s"] = Task { [weak model] in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            model?.titleGenerationTasks["s"] = nil
        }
        try await model.pauseRunsForUpdate(settleTimeout: 0.05)
        XCTAssertEqual(model.record("tt")?.backgroundTaskNotice, BackgroundRequests.interruptedNotice)
        XCTAssertEqual(model.record("tt")?.backgroundTaskOutcome, "interrupted")
        await close(model)
    }

    /// Resume goes on in the latest version: a chat showing an earlier
    /// version of an edited message returns to the latest, as a send does.
    @MainActor func testResumeReturnsToTheLatestVersion() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-version-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        model.chats = [ChatRecord(id: "c", workspaceID: "w", title: "C", path: nil, profileID: "p")]
        let view = SessionDisplay(id: "c"); model.displays["c"] = view
        view.runState = .paused
        view.versionView = TranscriptVersionView(latestID: "m", index: 1, count: 2, ids: ["m0", "m"], live: 2)
        model.resumeRun(sessionID: "c")
        XCTAssertNil(view.versionView, "the transcript shows the latest version the run goes on in")
        XCTAssertTrue(view.resuming)
        for _ in 0..<100 where view.resuming { try await Task.sleep(for: .milliseconds(10)) }
        await close(model)
    }

    /// The queue's Resume while a send is on its way does nothing: what the
    /// send does decides whether the stopped run is still there to go on with.
    @MainActor func testTheQueuesResumeWaitsForASendOnItsWay() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        model.chats = [ChatRecord(id: "c", workspaceID: "w", title: "C", path: nil, profileID: "p")]
        let view = SessionDisplay(id: "c"); model.displays["c"] = view
        view.runState = .paused; view.queuePaused = true; view.queue = [["turnId": .string("t")]]; view.loading = true
        model.resumeOrSendQueued(view)
        XCTAssertFalse(view.resuming)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.error, "nothing was sent: \(model.error ?? "")")
        view.loading = false
        model.resumeOrSendQueued(view)
        XCTAssertTrue(view.resuming, "with the send settled, Resume goes on with the stopped run first")
        for _ in 0..<100 where view.resuming { try await Task.sleep(for: .milliseconds(10)) }
        await close(model)
    }

    /// Work held for Resume does not hold a quit or an update; a run does,
    /// and so do follow-ups about to go.
    @MainActor func testOnlyWorkThatRunsWithoutTheReaderIsActive() {
        let view = SessionDisplay(id: "c")
        view.queueCount = 1; view.queuePaused = true
        XCTAssertTrue(view.hasWork); XCTAssertFalse(view.hasActiveWork, "paused follow-ups wait in the journal")
        view.queuePaused = false
        XCTAssertTrue(view.hasActiveWork, "follow-ups about to go")
        view.queueCount = 0; view.runState = .running
        XCTAssertTrue(view.hasActiveWork)
        view.runState = .paused; view.resuming = true
        XCTAssertTrue(view.hasActiveWork, "a Resume on its way holds the update's barrier")
        XCTAssertTrue(view.hasWork, "and keeps its chat's display and helper session")
    }

    @MainActor private func model(root: URL) async throws -> WorkspaceModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        _ = await model.prepareStore()
        return model
    }
    @MainActor private func close(_ model: WorkspaceModel) async {
        model.shutdown(); await model.flushRunHolds(); try? await model.traces.close(); await model.store?.close()
    }

    /// The row of a chat paused before the restart says "Paused" (and VoiceOver
    /// "paused") until the chat is opened; then the chat's own state decides.
    @MainActor func testTheRowShowsTheSavedHoldUntilTheChatKnowsItsOwnState() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-row-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await model(root: root)
        let chat = ChatRecord(id: "c", workspaceID: "w", title: "Refund edge cases", path: nil, profileID: "p")
        first.chats = [chat]; try await first.store?.put(chat, kind: "chat", id: chat.id)
        let view = SessionDisplay(id: "c"); first.displays["c"] = view
        view.runState = .paused
        XCTAssertNil(first.runHolds["c"], "a display that has not adopted a snapshot or the journal writes nothing")
        view.runStateKnown = true; first.reconcileRunHold("c")
        XCTAssertEqual(first.runHolds["c"]?.state, "paused")
        await close(first)

        let second = try await model(root: root)
        second.chats = [chat]
        await second.restoreRunHolds(); await second.runHoldVerification?.value
        XCTAssertEqual(second.heldRunState("c"), "paused", "the hold survives the restart")
        let state = SidebarChatRowState(heldRun: second.runHolds["c"]?.presented)
        let content = SidebarChatRowView.content(model: second, chat: chat, state: state, display: nil, retained: nil)
        XCTAssertEqual(content.stats.state, "paused"); XCTAssertTrue(content.stats.hasActivity, "the state word shows even without figures")
        XCTAssertEqual(content.accessibilityLabel, "Refund edge cases, paused")
        let row = SidebarChatRowView(model: second, chat: chat, state: state, projectID: "w", glide: PiKit.SelectionGlide())
        XCTAssertEqual(row.row.accessibilityLabel(), "Refund edge cases, paused")
        XCTAssertEqual(second.menuBarActivity().rows.first { $0.id == "c" }?.phase, "paused", "the menu bar lists it as waiting")
        // A new display reads idle until it knows: the hold still shows, in the row and the menu bar.
        let fresh = SessionDisplay(id: "c"); second.displays["c"] = fresh; second.noteActivityChanged()
        XCTAssertEqual(second.menuBarActivity().rows.first { $0.id == "c" }?.phase, "paused")
        XCTAssertEqual(SidebarChatRowView.content(model: second, chat: chat, state: state, display: fresh, retained: nil).stats.state, "paused")
        second.noteActivityChanged("c"); second.reconcileRunHold("c")
        XCTAssertNotNil(second.runHolds["c"], "an unknown display does not clear the hold")
        // Its journal said nothing waits: the hold goes, here and on disk.
        fresh.runStateKnown = true; second.reconcileRunHold("c")
        XCTAssertNil(second.runHolds["c"])
        XCTAssertEqual(SidebarChatRowView.content(model: second, chat: chat, state: SidebarChatRowState(), display: fresh, retained: nil).stats.state, "idle")
        await close(second)
        let third = try await model(root: root)
        third.chats = [chat]
        await third.restoreRunHolds(); await third.runHoldVerification?.value
        XCTAssertNil(third.heldRunState("c"), "the clear was saved")
        await close(third)
    }

    /// A chat paused under an older build has no hold: the first launch of
    /// this one reads every journal's end once. Later launches read only the
    /// journals the holds name, and a hold the journal no longer bears out
    /// (a run that finished after the app last saw it) goes.
    @MainActor func testTheJournalsDecideAtLaunchAndOlderPausedChatsAreFoundOnce() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-boot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pausedPath = try journal([running, stopped]), donePath = try journal([running, finished]), cutPath = try journal([running])
        let chats = [ChatRecord(id: "paused", workspaceID: "w", title: "Paused", path: pausedPath, profileID: "p"),
                     ChatRecord(id: "done", workspaceID: "w", title: "Done", path: donePath, profileID: "p"),
                     ChatRecord(id: "cut", workspaceID: "w", title: "Cut", path: cutPath, profileID: "p")]
        let first = try await model(root: root)
        first.chats = chats
        try await first.store?.put(RunHoldRecord(id: "done", state: "active"), kind: RunHoldRecord.kind, id: "done")
        await first.restoreRunHolds()
        XCTAssertEqual(first.heldRunState("done"), "paused", "the saved hold shows at once")
        var publications = 0
        let watch = first.$runHolds.dropFirst().sink { _ in publications += 1 }
        await first.runHoldVerification?.value
        watch.cancel()
        XCTAssertEqual(publications, 1, "the journals' answers are one change to the sidebar")
        XCTAssertEqual(first.heldRunState("paused"), "paused", "found in its journal on the first launch")
        XCTAssertEqual(first.heldRunState("cut"), "interrupted")
        XCTAssertNil(first.heldRunState("done"), "the journal says the run finished")
        await close(first)
        // The journals change behind the app's back: only the held ones are read again.
        try Data(contentsOf: URL(fileURLWithPath: pausedPath)).write(to: URL(fileURLWithPath: donePath))
        let second = try await model(root: root)
        second.chats = chats
        await second.restoreRunHolds(); await second.runHoldVerification?.value
        XCTAssertNil(second.heldRunState("done"), "a chat with no hold is not read again after the first launch")
        XCTAssertEqual(second.heldRunState("paused"), "paused")
        await close(second)
    }

    /// A journal that cannot say (its state too far back, or unreadable) does
    /// not take a saved hold away; on the first launch it is asked again next time.
    @MainActor func testAJournalThatCannotSayKeepsTheHoldAndIsAskedAgain() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-unknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let unreadable = try journal([running, stopped])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable) }
        let chats = [ChatRecord(id: "u", workspaceID: "w", title: "U", path: unreadable, profileID: "p")]
        let first = try await model(root: root)
        first.chats = chats
        try await first.store?.put(RunHoldRecord(id: "u", state: "paused"), kind: RunHoldRecord.kind, id: "u")
        await first.restoreRunHolds(); await first.runHoldVerification?.value
        XCTAssertEqual(first.heldRunState("u"), "paused", "the saved hold stays")
        let marker = try await first.store?.get(Int64.self, kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)
        XCTAssertNil(marker, "the first launch's reading is not done while a journal could not say")
        await close(first)
    }

    /// A hold that could not be written stays to be written: the quit's flush
    /// says it did not get there.
    @MainActor func testAHoldThatCouldNotBeWrittenIsNotForgotten() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-fail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        model.chats = [ChatRecord(id: "c", workspaceID: "w", title: "C", path: nil, profileID: "p")]
        await model.store?.close()
        model.setRunHold("c", "paused")
        let flushed = await model.flushRunHolds(timeout: 0.3)
        XCTAssertFalse(flushed, "the flush says the hold is not saved")
        XCTAssertTrue(model.dirtyRunHolds.contains("c"), "and it is still to be written")
        model.shutdown()
    }

    /// The first launch's reading is done only once what it found is saved.
    @MainActor func testTheFirstLaunchsReadingIsNotDoneUntilItsHoldsAreSaved() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-boot-fail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await model(root: root)
        first.chats = [ChatRecord(id: "p", workspaceID: "w", title: "P", path: try journal([running, stopped]), profileID: "p")]
        first.runHoldWritesFail = true
        await first.restoreRunHolds(); await first.runHoldVerification?.value
        XCTAssertEqual(first.heldRunState("p"), "paused")
        var marker = try await first.store?.get(Int64.self, kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)
        XCTAssertNil(marker, "a hold that was not saved keeps the first launch's reading to do")
        first.runHoldWritesFail = false
        await first.restoreRunHolds(); await first.runHoldVerification?.value
        marker = try await first.store?.get(Int64.self, kind: RunHoldRecord.bootstrapKind, id: RunHoldRecord.bootstrapID)
        XCTAssertNotNil(marker)
        let saved = try await first.store?.get(RunHoldRecord.self, kind: RunHoldRecord.kind, id: "p")
        XCTAssertEqual(saved?.state, "paused")
        await close(first)
    }

    /// A paused chat that is archived, then restored, comes back to the
    /// menu bar as waiting, though nothing else about it changed.
    @MainActor func testARestoredArchivedPausedChatReturnsToTheMenuBar() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        var chat = ChatRecord(id: "c", workspaceID: "w", title: "C", path: nil, profileID: "p"); chat.archivedAt = Date()
        model.chats = [chat]
        model.runHolds = ["c": RunHoldRecord(id: "c", state: "paused")]
        XCTAssertNil(model.menuBarActivity().rows.first { $0.id == "c" }, "archived: not listed")
        model.chats[0].archivedAt = nil
        XCTAssertEqual(model.menuBarActivity().rows.first { $0.id == "c" }?.phase, "paused", "restored: waiting again")
        await close(model)
    }

    @MainActor func testArchivedAndUtilityChatsShowNoHold() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-hold-kinds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root)
        var archived = ChatRecord(id: "a", workspaceID: "w", title: "A", path: nil, profileID: "p"); archived.archivedAt = Date()
        var probe = ChatRecord(id: "t", workspaceID: "w", title: "T", path: nil, profileID: "p"); probe.connectionTest = true
        model.chats = [archived, probe]
        model.runHolds = ["a": RunHoldRecord(id: "a", state: "paused"), "t": RunHoldRecord(id: "t", state: "paused")]
        XCTAssertNil(model.heldRunState("a")); XCTAssertNil(model.heldRunState("t"))
        await close(model)
    }
}
