import XCTest
@testable import PiApp

final class SessionReadStateTests: XCTestCase {
    @MainActor private func makeModel(root: URL? = nil) async throws -> (WorkspaceModel, URL, SessionDisplay) {
        let base = ProcessInfo.processInfo.environment["PI_BUILD_ROOT"] ?? NSTemporaryDirectory()
        let root = root ?? URL(fileURLWithPath: base).appendingPathComponent("read-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let chat = ChatRecord(id: "chat", workspaceID: "workspace", title: "Saved chat", path: nil, profileID: "profile")
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let view = SessionDisplay(id: chat.id)
        model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
        return (model, root, view)
    }
    private func snapshot(_ count: Int, _ id: String?) -> [String: WireValue] {
        ["assistantMessageCount": .number(Double(count)), "latestAssistantMessageId": id.map(WireValue.string) ?? .null]
    }
    @MainActor private func close(_ model: WorkspaceModel, root: URL, remove: Bool = true) async throws {
        model.shutdown(); await model.flushReadStates(); await model.store?.close()
        if remove { try FileManager.default.removeItem(at: root) }
    }

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

    @MainActor func testStreamingIDsMalformedCountersAndConnectionChecksDoNotCreateUnread() async throws {
        let (model, root, _) = try await makeModel()
        model.observeAssistantOutputs(sessionID: "chat", snapshot: snapshot(0, nil))
        for invalid in [snapshot(1, "stream:partial"), snapshot(-1, "x"), snapshot(100001, "x"), snapshot(1, nil), ["assistantMessageCount": .number(1.5), "latestAssistantMessageId": .string("x")]] {
            model.observeAssistantOutputs(sessionID: "chat", snapshot: invalid)
        }
        XCTAssertEqual(model.unreadCount, 0); XCTAssertEqual(model.unreadStates["chat"]?.observedAssistantCount, 0)
        model.chats.append(.init(id: "connection-test", workspaceID: "workspace", title: "Connection test", path: nil, profileID: "profile", connectionTest: true))
        model.observeAssistantOutputs(sessionID: "connection-test", snapshot: snapshot(0, nil))
        model.observeAssistantOutputs(sessionID: "connection-test", snapshot: snapshot(1, "test-answer"))
        XCTAssertNil(model.unreadStates["connection-test"])
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

    func testReadReceiptUsesPaintedFrameWhenItsAcknowledgementDispatchesAnotherSnapshot() {
        // JS posts rendered(8), then readReply(8). Handling rendered(8) can
        // dispatch dirty snapshot 9 before readReply(8) reaches the native bridge.
        XCTAssertTrue(TranscriptReadVisibility.receiptMatches(receiptSequence: 8, renderedSequence: 8, sentSequence: 9, receiptSession: "chat", currentSession: "chat"))
        XCTAssertFalse(TranscriptReadVisibility.receiptMatches(receiptSequence: 7, renderedSequence: 8, sentSequence: 9, receiptSession: "chat", currentSession: "chat"), "An obsolete painted frame cannot acknowledge")
        XCTAssertFalse(TranscriptReadVisibility.receiptMatches(receiptSequence: 9, renderedSequence: 8, sentSequence: 9, receiptSession: "chat", currentSession: "chat"), "An unpainted future frame is not proof")
        XCTAssertFalse(TranscriptReadVisibility.receiptMatches(receiptSequence: 8, renderedSequence: 8, sentSequence: 9, receiptSession: "old-chat", currentSession: "chat"), "Session switches reject delayed receipts even when imported message IDs coincide")
        XCTAssertFalse(TranscriptReadVisibility.receiptMatches(receiptSequence: 8, renderedSequence: -1, sentSequence: 9, receiptSession: "chat", currentSession: "chat"), "No frame is eligible until this session paints")
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
