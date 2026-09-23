import XCTest
@testable import PiApp

class SessionReadStateTestCase: XCTestCase {
    @MainActor fileprivate func makeModel(root: URL? = nil) async throws -> (WorkspaceModel, URL, SessionDisplay) {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = root ?? URL(fileURLWithPath: base).appendingPathComponent("read-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "chat", workspaceID: "workspace", title: "Saved chat", path: nil, profileID: "profile")
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let view = SessionDisplay(id: chat.id)
        model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
        return (model, root, view)
    }
    fileprivate func snapshot(_ count: Int, _ id: String?) -> [String: WireValue] {
        ["assistantMessageCount": .number(Double(count)), "latestAssistantMessageId": id.map(WireValue.string) ?? .null]
    }
    @MainActor fileprivate func close(_ model: WorkspaceModel, root: URL, remove: Bool = true) async throws {
        model.shutdown(); await model.flushReadStates(); try await model.traces.close(); await model.store?.close()
        if remove { try FileManager.default.removeItem(at: root) }
    }


}

final class SessionReadStateTests: SessionReadStateTestCase {
    @MainActor func testRepliesBecomeUnreadOnlyAfterTheRunReportsBack() async throws {
        let (model, root, view) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(4, "baseline"))
        var running = snapshot(5, "tool-round"); running["state"] = .string("running")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: running)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0, "Mid-run tool rounds raise no badge")
        running = snapshot(6, "another-round"); running["state"] = .string("compacting")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: running)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        var idle = snapshot(7, "final"); idle["state"] = .string("idle")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: idle)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 3, "The finished run counts every reply it produced")
        XCTAssertEqual(model.unreadStates["chat"]?.unreadTargetID, "final")
        model.updateDockBadge()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1", "The Dock counts unread chats, not replies")
        model.markSessionRead("chat"); model.updateDockBadge()
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        _ = view
        try await close(model, root: root)
    }

    @MainActor func testExistingHistoryBaselinesReadAndStatusOnlyNewRepliesBecomeUnread() async throws {
        let (model, root, _) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(40, "historic"))
        XCTAssertEqual(model.unreadCount, 0, "Upgrading or loading existing history is not new output")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(42, "newest"))
        XCTAssertEqual(model.unreadCount, 1); XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 2)
        XCTAssertTrue(model.displays["chat"]!.messages.isEmpty, "Status-only observation does not load hidden transcripts")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(42, "newest"))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 2, "Repeated polls are idempotent")
        try await close(model, root: root)
    }

    @MainActor func testLateReadOfAnOlderReplyAndReportOrOtherChatNeverClearsNewest() async throws {
        let (model, root, view) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "a1"))
        view.messages = [.init(id: "a1", role: "assistant", text: "First")]
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(2, "a2"))
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a1")
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 2)
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2")
        XCTAssertEqual(model.unreadCount, 1, "An unread target absent from the loaded page is not read")
        view.messages.append(.init(id: "a2", role: "assistant", text: "Second"))
        model.openReport(); model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2")
        XCTAssertEqual(model.unreadCount, 1)
        model.closeReport(); model.selectedID = "other"; model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2")
        XCTAssertEqual(model.unreadCount, 1)
        model.selectedID = "chat"; model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2")
        XCTAssertEqual(model.unreadCount, 0, "A new viewport proof clears only the current latest target")
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(3, "a3"))
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2")
        XCTAssertEqual(model.unreadCount, 1, "A delayed acknowledgement cannot consume output produced afterward")
        try await close(model, root: root)
    }

    @MainActor func testUnreadAndReadPersistAcrossRestartWithoutDiscardingNewCounterDifferences() async throws {
        let (first, root, _) = try await makeModel()
        first.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(5, "old"))
        first.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(6, "new"))
        try await close(first, root: root, remove: false)
        let (second, _, view) = try await makeModel(root: root)
        try await second.restoreReadStates()
        XCTAssertEqual(second.unreadOutputCount(sessionID: "chat"), 1)
        second.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(7, "newer"))
        XCTAssertEqual(second.unreadOutputCount(sessionID: "chat"), 2, "Existing persisted counters detect later completed replies on reopening")
        view.messages = [.init(id: "newer", role: "assistant", text: "Newer")]
        second.acknowledgeVisibleReply(sessionID: "chat", messageID: "newer")
        try await close(second, root: root, remove: false)
        let (third, _, _) = try await makeModel(root: root)
        try await third.restoreReadStates()
        third.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(7, "newer"))
        XCTAssertEqual(third.unreadCount, 0, "Read state also survives restarting")
        try await close(third, root: root)
    }

    @MainActor func testMalformedCountersAndConnectionChecksDoNotCreateUnread() async throws {
        let (model, root, _) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        for invalid in [snapshot(1, ""), snapshot(-1, "x"), snapshot(100001, "x"), snapshot(1, nil), ["assistantMessageCount": .number(1.5), "latestAssistantMessageId": .string("x")]] {
            model.observeAssistantOutputs(sessionID: "chat", snapshot: invalid)
        }
        XCTAssertEqual(model.unreadCount, 0); XCTAssertEqual(model.unreadStates["chat"]?.observedAssistantCount, 0)
        model.chats.append(.init(id: "connection-test", workspaceID: "workspace", title: "Connection test", path: nil, profileID: "profile", connectionTest: true))
        model.observeAssistantOutputs(sessionID: "connection-test", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "connection-test", snapshot: snapshot(1, "test-answer"))
        XCTAssertNil(model.unreadStates["connection-test"])
        try await close(model, root: root)
    }

    @MainActor func testCompletedLegacyIDIsOpaqueWhileExplicitStreamingStateCannotBeRead() async throws {
        let (model, root, view) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "stream:historical"))
        XCTAssertEqual(model.unreadCount, 1)
        view.messages = [.init(id: "stream:historical", role: "assistant", text: "Answer", state: "streaming")]
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "stream:historical")
        XCTAssertEqual(model.unreadCount, 1)
        view.messages[0].state = "completed"
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "stream:historical")
        XCTAssertEqual(model.unreadCount, 0)
        try await close(model, root: root)
    }

    @MainActor func testSideUnreadRemainsIndependentAndOnlyKeptSideStatePersists() async throws {
        let (model, root, _) = try await makeModel()
        model.sides["chat"] = .init(id: "side", parentID: "chat", workspaceID: "workspace", profileID: "profile", title: "Side")
        let view = SessionDisplay(id: "side"); model.displays["side"] = view
        model.observeAssistantOutputs(sessionID: "side", snapshot: snapshot(4, "inherited"))
        model.observeAssistantOutputs(sessionID: "side", snapshot: snapshot(5, "side-answer"))
        await model.flushReadStates()
        let ephemeral = try await model.store?.get(SessionReadState.self, kind: "session-read", id: "side")
        XCTAssertNil(ephemeral); XCTAssertEqual(model.unreadCount, 1); XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        model.sides["chat"]?.kept = true
        model.chats.append(.init(id: "side", workspaceID: "workspace", title: "Saved side", path: nil, profileID: "profile"))
        await model.retainSideReadState("side")
        let kept = try await model.store?.get(SessionReadState.self, kind: "session-read", id: "side")
        XCTAssertEqual(kept?.unreadOutputs, 1)
        view.messages = [.init(id: "side-answer", role: "assistant", text: "Side answer")]
        model.acknowledgeVisibleReply(sessionID: "side", messageID: "side-answer")
        XCTAssertEqual(model.unreadCount, 0, "A visible side can be read without changing the parent")
        try await close(model, root: root)
    }

    func testBackgroundOcclusionHiddenReportAndModalWindowsCannotAcknowledgeReads() {
        XCTAssertTrue(TranscriptReadVisibility.permits(appActive: true, keyWindow: true, windowVisible: true, occluded: false, minimized: false, viewHidden: false, sheetOpen: false))
        for missing in 0..<7 {
            XCTAssertFalse(TranscriptReadVisibility.permits(appActive: missing != 0, keyWindow: missing != 1, windowVisible: missing != 2, occluded: missing == 3, minimized: missing == 4, viewHidden: missing == 5, sheetOpen: missing == 6))
        }
    }

    @MainActor func testExplicitMarkReadClearsAbandonedReplyButFutureOutputRemainsUnread() async throws {
        let (model, root, _) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "abandoned-answer"))
        model.markSessionRead("chat")
        XCTAssertEqual(model.unreadCount, 0)
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(2, "replacement-answer"))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1)
        try await close(model, root: root)
    }

    @MainActor func testOfflineSelectionReconcilesDurableAppendCounterAcrossBranchesAndCachedPages() async throws {
        let (model, root, _) = try await makeModel()
        try await model.reloadConfiguration()
        let path = root.appendingPathComponent("history.jsonl")
        let text = """
        {"type":"session","id":"chat","version":3}
        {"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"First question"}}
        {"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":"First answer"}}
        {"type":"message","id":"u2","parentId":"a1","message":{"role":"user","content":"Old question"}}
        {"type":"message","id":"a2","parentId":"u2","message":{"role":"assistant","content":"Abandoned answer"}}
        {"type":"branch","id":"edit","parentId":"a2","fromMessageId":"u2","keptIds":["u1","a1"]}
        {"type":"message","id":"u3","parentId":"edit","message":{"role":"user","content":"Replacement"}}
        {"type":"message","id":"a3","parentId":"u3","message":{"role":"assistant","content":"New answer"}}
        """ + "\n"
        try Data(text.utf8).write(to: path)
        model.chats[0].path = path.path
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "a1"))
        await model.select("chat")
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 2, "Unpolled durable replies are detected without starting a helper")
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertEqual(model.selected?.messages.last?.id, "a3")
        XCTAssertFalse(model.selected?.messages.contains(where: { $0.id == "a2" }) ?? true)
        let cached = try await model.history.read(path: path.path, before: "edit")
        XCTAssertEqual(cached.assistantMessageCount, 3); XCTAssertEqual(cached.latestAssistantMessageID, "a3")
        XCTAssertEqual(cached.messages.map(\.id), ["u1", "a1"], "A historical page retains the full durable counter")
        try Data((text + "{\"unfinished\":").utf8).write(to: path)
        let damaged = try await model.history.read(path: path.path)
        XCTAssertNotNil(damaged.notice); XCTAssertNil(damaged.assistantMessageCount, "Incomplete history is never authoritative read state")
        try await close(model, root: root)
    }
}

/// Reading state that needs the machine to itself: a reply read in the
/// active app's key window, and a flush held to a tenth of a second. They
/// run in the serial lane (`scripts/test-lanes.py`).
final class SessionReadFocusTests: SessionReadStateTestCase, SerialTestLane {
    @MainActor func testFlushDeadlineNeverHangsQuitAndNormalFlushPersistsLatestRevision() async throws {
        let (model, root, _) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "new-answer"))
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = await model.flushReadStates(timeout: 0)
        XCTAssertFalse(timedOut); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)
        model.markSessionRead("chat")
        let flushed = await model.flushReadStates()
        XCTAssertTrue(flushed)
        let saved = try await model.store?.get(SessionReadState.self, kind: "session-read", id: "chat")
        XCTAssertEqual(saved?.observedAssistantCount, 1); XCTAssertEqual(saved?.unreadOutputs, 0)
        try await close(model, root: root)
    }

    /// The chat the reader is looking at, at the bottom of its page, reads its
    /// own new reply a frame or two after the reply lands. It must never be
    /// marked unread first: that put a dot on its sidebar row, and a count on
    /// the Dock, for those frames every time a run finished.
    @MainActor func testTheChatBeingReadNeverFlashesUnreadWhenItsRunFinishes() async throws {
        let shell = try SmoothShellTests.Shell(chats: ["Reading"], rows: 12)
        registerWorkspaceFixtureTeardown(shell.model, root: shell.root)
        defer { shell.close() }
        let model = shell.model, chat = shell.chats[0]
        NSApp.activate(ignoringOtherApps: true); shell.window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(20)) }
        await model.select(chat.id)
        await shell.settle(1.0)
        shell.page?.jumpToLatest()
        await shell.settle(0.8)
        guard shell.page?.readingIsVisible == true else {
            throw XCTSkip("Reading a reply needs this app's own key, unoccluded window; this desktop cannot provide one.")
        }
        let view = try XCTUnwrap(model.displays[chat.id])
        XCTAssertEqual(view.scrollAnchor?.followsBottom, true, "The reader is at the newest row")
        let latest = try XCTUnwrap(view.messages.last { $0.role == "assistant" }?.id)
        model.observeAssistantOutputs(sessionID: chat.id, snapshot: ["assistantMessageCount": .number(6), "latestAssistantMessageId": .string(latest), "state": .string("idle")])
        model.updateDockBadge()
        XCTAssertEqual(model.unreadOutputCount(sessionID: chat.id), 0); XCTAssertNil(NSApp.dockTile.badgeLabel)
        /// A run finishes: its reply and its count arrive in one snapshot.
        /// Returns the frames, of those drawn over the next 1.5 s, that showed
        /// the chat unread or put a count on the Dock.
        @MainActor func finishRun(_ index: Int) async -> (unread: Int, badge: Int, frames: Int) {
            var answer = TranscriptMessage(id: "fresh-answer-\(index)", role: "assistant", text: "The finished answer to question \(index).", turn: chat.id + "-m10")
            answer.at = Double(20_000 + index)
            view.messages.append(answer)
            model.observeAssistantOutputs(sessionID: chat.id, snapshot: ["assistantMessageCount": .number(Double(6 + index)),
                                                                         "latestAssistantMessageId": .string(answer.id), "state": .string("idle")])
            var unread = 0, badge = 0, frames = 0
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                if model.unreadOutputCount(sessionID: chat.id) > 0 || model.projectHasUnread(shell.project.id) { unread += 1 }
                if NSApp.dockTile.badgeLabel != nil { badge += 1 }
                shell.draw(); frames += 1
                await Task.yield(); try? await Task.sleep(for: .milliseconds(8))
            } while Date() < deadline
            return (unread, badge, frames)
        }
        // The path this replaced, in the same window: the reply is published
        // unread at once and the page reads it a few frames later.
        model.applicationIsActiveOverride = false
        let unheld = await finishRun(1)
        print("PERF unread flash for the chat being read, published at once (before): \(unheld.unread) of \(unheld.frames) frames unread, \(unheld.badge) with a Dock badge")
        XCTAssertEqual(model.unreadOutputCount(sessionID: chat.id), 0, "The page read the first reply")
        model.applicationIsActiveOverride = nil
        let held = await finishRun(2)
        print("PERF unread flash for the chat being read, held for the page's read check (after): \(held.unread) of \(held.frames) frames unread, \(held.badge) with a Dock badge")
        XCTAssertEqual(held.unread, 0, "The reply the reader is looking at never shows as unread")
        XCTAssertEqual(held.badge, 0, "Nor does it put a count on the Dock")
        XCTAssertEqual(model.unreadStates[chat.id]?.observedAssistantCount, 8)
        XCTAssertEqual(model.unreadOutputCount(sessionID: chat.id), 0)
    }
}

extension SessionReadStateTests {
    /// A failed run marks the chat, but the Dock badge counts only replies in chats that are neither failed nor archived.
    @MainActor func testArchivedChatsHideUnreadEverywhereWithoutDiscardingReadState() async throws {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("read-state-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        var chat = ChatRecord(id: "chat", workspaceID: "workspace", title: "Saved chat", path: nil, profileID: "profile")
        let other = ChatRecord(id: "other", workspaceID: "workspace", title: "Other chat", path: nil, profileID: "profile")
        model.chats = [chat, other]; try await model.store?.put(chat, kind: "chat", id: chat.id); try await model.store?.put(other, kind: "chat", id: other.id)
        let view = SessionDisplay(id: chat.id), otherView = SessionDisplay(id: other.id)
        model.displays = [chat.id: view, other.id: otherView]; model.selectedID = other.id; model.selected = otherView; model.focusedSessionID = other.id
        // The chat is not in front; its run fails without producing a reply.
        model.markRunFailed(sessionID: "chat")
        XCTAssertTrue(model.unreadFailure(sessionID: "chat")); XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        model.updateDockBadge(); XCTAssertNil(NSApp.dockTile.badgeLabel, "A failure is a sidebar mark, not a badge")
        // A reply that did arrive before the failure stays unread but the badge still ignores the chat.
        var failed = ["assistantMessageCount": WireValue.number(1), "latestAssistantMessageId": .string("a1"), "state": .string("error"), "runStatus": .string("failed")]
        model.observeAssistantOutputs(sessionID: "chat", snapshot: ["assistantMessageCount": .number(0), "latestAssistantMessageId": .null])
        model.observeAssistantOutputs(sessionID: "chat", snapshot: failed)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1)
        model.updateDockBadge(); XCTAssertNil(NSApp.dockTile.badgeLabel)
        // Opening the chat clears the failure mark; the reply then counts as an ordinary unread reply.
        await model.select("chat")
        XCTAssertFalse(model.unreadFailure(sessionID: "chat"))
        model.updateDockBadge(); XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        // Archiving takes the chat out of the badge and the bounce, and it refuses to run.
        chat.archivedAt = Date(); model.chats[0] = chat; try await model.store?.put(chat, kind: "chat", id: chat.id)
        model.updateDockBadge(); XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertFalse(model.unreadFailure(sessionID: "chat"))
        XCTAssertFalse(model.projectHasUnread("workspace"))
        XCTAssertFalse(model.menuBarActivity().rows.contains { $0.id == "chat" })
        XCTAssertEqual(model.unreadStates["chat"]?.unreadOutputs, 1, "Archive hides marks without pretending the output was read")
        chat.archivedAt = nil; model.chats[0] = chat
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1, "Restoring keeps the original unread state")
        chat.archivedAt = Date(); model.chats[0] = chat
        view.draft = "hello"
        model.send(sessionID: "chat")
        XCTAssertEqual(view.notice, WorkspaceModel.archivedNotice); XCTAssertFalse(view.loading); XCTAssertTrue(model.hosts.isEmpty)
        model.action("queue.resume", sessionID: "chat")
        XCTAssertEqual(view.notice, WorkspaceModel.archivedNotice)
        failed["assistantMessageCount"] = .number(2); failed["latestAssistantMessageId"] = .string("a2")
        model.markSessionRead("chat")
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0); XCTAssertFalse(model.unreadFailure(sessionID: "chat"))
        await model.flushReadStates()
    }
}

extension SessionReadStateTests {

    /// The same, frame by frame, without depending on this desktop letting the
    /// test app come to the front: the reader follows the newest row of the
    /// chat in front, the reply lands, and the page reads it three frames
    /// later. No frame in between shows it unread or counts it on the Dock. A
    /// reply the page does not read within the grace becomes unread then.
    @MainActor func testAReplyInTheChatBeingReadWaitsForThePagesReadCheck() async throws {
        let (model, root, view) = try await makeModel()
        model.applicationIsActiveOverride = true
        view.scrollAnchor = .init(id: "a1", offset: 0, followsBottom: true)
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "a1"))
        model.updateDockBadge()
        view.messages = [.init(id: "a2", role: "assistant", text: "The answer")]
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(2, "a2"))
        var unreadFrames = 0
        for frame in 0..<12 {
            if model.unreadOutputCount(sessionID: "chat") > 0 || model.unreadCount > 0 || NSApp.dockTile.badgeLabel != nil { unreadFrames += 1 }
            if frame == 3 { model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a2") }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(unreadFrames, 0, "The reply the reader is looking at never shows as unread")
        try await Task.sleep(for: WorkspaceModel.visibleReplyGrace + .milliseconds(150))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0, "Read within the grace, it stays read")
        XCTAssertEqual(model.unreadStates["chat"]?.observedAssistantCount, 2)
        // A reply the page cannot read (a sheet is up, say) is unread once the grace is over.
        view.messages.append(.init(id: "a3", role: "assistant", text: "Another answer"))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(3, "a3"))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        try await Task.sleep(for: WorkspaceModel.visibleReplyGrace + .milliseconds(150))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1, "Unread once the page has had its chance")
        XCTAssertEqual(model.unreadStates["chat"]?.unreadTargetID, "a3")
        model.acknowledgeVisibleReply(sessionID: "chat", messageID: "a3")
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 0)
        // In the background the reply is unread at once, as before.
        model.applicationIsActiveOverride = false
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(4, "a4"))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1)
        try await close(model, root: root)
    }

    /// A reply that lands while the reader is scrolled up is unread as before,
    /// only a moment later, and stays unread until they reach it.
    @MainActor func testAReplyTheReaderIsNotLookingAtStillBecomesUnread() async throws {
        let (model, root, view) = try await makeModel()
        view.scrollAnchor = .init(id: "earlier", offset: -40, followsBottom: false)
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "a1"))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(2, "a2"))
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat"), 1, "A reader scrolled away has not read the reply")
        try await close(model, root: root)
    }

    /// A run that failed while another app was in front marks the chat. When
    /// the reader comes back to it the mark must be clearable: clicking the
    /// chat again, or Mark as Read, which used to be offered only for replies.
    @MainActor func testAFailureMarkOnTheChatBeingViewedCanBeCleared() async throws {
        let (model, root, view) = try await makeModel()
        model.chats.append(ChatRecord(id: "other", workspaceID: "workspace", title: "Other", path: nil, profileID: "profile"))
        model.selectedID = "other"
        model.markRunFailed(sessionID: "chat")
        XCTAssertTrue(model.unreadFailure(sessionID: "chat"))
        // The chat is the one on screen when the reader returns.
        model.selectedID = "chat"; model.selected = view; view.historyState = .ready
        await model.select("chat")
        XCTAssertFalse(model.unreadFailure(sessionID: "chat"), "Clicking the chat that is already open clears its failure mark")
        model.selectedID = "other"; model.markRunFailed(sessionID: "chat"); model.selectedID = "chat"
        var state = SidebarChatRowState(); state.unreadFailure = model.unreadFailure(sessionID: "chat")
        XCTAssertTrue(state.offersMarkAsRead, "Mark as Read is offered for a failure mark too")
        model.markSessionRead("chat")
        XCTAssertFalse(model.unreadFailure(sessionID: "chat"))
        try await close(model, root: root)
    }

    /// A collapsed topic says it holds something to look at: a failed run is
    /// such a thing, as it is for the project's own header.
    @MainActor func testACollapsedTopicShowsAFailureMarkInside() async throws {
        let (model, root, _) = try await makeModel()
        let project = WorkspaceRecord(id: "workspace", path: root.path, trusted: true)
        model.workspaces = [project]
        model.topics = [TopicRecord(id: "topic", workspaceID: project.id, title: "Billing", expanded: false)]
        var chat = model.chats[0]; chat.topicID = "topic"; model.chats = [chat, ChatRecord(id: "other", workspaceID: "workspace", title: "Other", path: nil, profileID: "profile")]
        model.selectedID = "other"
        model.markRunFailed(sessionID: "chat")
        XCTAssertTrue(model.projectHasUnread(project.id))
        let header = model.topicGroupContents(in: project, topic: model.topics[0], archived: false, filter: "", sidebarWidth: 300, namesConnection: false).header
        XCTAssertTrue(header.hasUnread, "The topic's header shows the failed chat inside it")
        try await close(model, root: root)
    }

    /// Deleting a chat forgets its read state; the Dock must stop counting it.
    @MainActor func testForgettingAReadStateTakesItOffTheDockBadge() async throws {
        let (model, root, _) = try await makeModel()
        model.selectedID = nil
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(1, "a1"))
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(2, "a2"))
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        model.forgetReadState("chat")
        XCTAssertNil(NSApp.dockTile.badgeLabel, "A forgotten chat no longer counts on the Dock")
        try await close(model, root: root)
    }
}
