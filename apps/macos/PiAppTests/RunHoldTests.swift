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
