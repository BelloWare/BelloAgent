import XCTest
@testable import PiApp

private actor MessageNavigationGate {
    private var continuation: CheckedContinuation<HistoryPage, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func read() async -> HistoryPage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting.forEach { $0.resume() }; waiting = []
        }
    }
    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ page: HistoryPage) { continuation?.resume(returning: page); continuation = nil }
}

final class ReportMessageNavigationTests: XCTestCase {
    @MainActor private func makeModel() async throws -> (WorkspaceModel, URL, SessionDisplay) {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("message-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "workspace", title: "Saved chat", path: root.appendingPathComponent("history.jsonl").path, profileID: "profile")
        model.chats = [chat]
        let view = SessionDisplay(id: chat.id)
        view.messages = [.init(id: "latest", role: "assistant", text: "Current page")]
        model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
        return (model, root, view)
    }
    private var oldPage: HistoryPage { .init(messages: [.init(id: "old-input", role: "user", text: "Earlier input"), .init(id: "old-answer", role: "assistant", text: "Earlier answer")], before: nil, total: 102, notice: nil) }
    @MainActor private func close(_ model: WorkspaceModel, root: URL) async throws {
        model.shutdown(); try await model.traces.close(); await model.store?.close(); try FileManager.default.removeItem(at: root)
    }

    @MainActor func testReportNavigationFocusesParentWhenItsSideWasFocused() async throws {
        let (model, root, view) = try await makeModel()
        model.sides["chat"] = .init(id: "side", parentID: "chat", workspaceID: "workspace", profileID: "profile", title: "Side")
        model.displays["side"] = SessionDisplay(id: "side"); model.focusedSessionID = "side"
        model.openReport()
        let result = await model.revealMessage(sessionID: "chat", messageID: "latest")
        XCTAssertTrue(result); XCTAssertEqual(model.focusedSessionID, "chat"); XCTAssertEqual(model.page, .chats)
        XCTAssertEqual(view.scrollAnchor?.id, "latest"); XCTAssertNotNil(model.sides["chat"], "The side remains mounted")
        try await close(model, root: root)
    }

    /// Reaching a side from the report opens its chat on the way: the side
    /// is what was opened, so only it moves to the front of the recently
    /// opened chats (0.1.122).
    @MainActor func testReachingASideFromTheReportOpensOnlyTheSide() async throws {
        let (model, root, _) = try await makeModel()
        var side = ChatRecord(id: "side", workspaceID: "workspace", title: "Side", path: nil, profileID: "profile"); side.parentSessionID = "chat"
        let other = ChatRecord(id: "other", workspaceID: "workspace", title: "Other", path: nil, profileID: "profile")
        model.chats += [side, other]
        model.sides["chat"] = .init(id: "side", parentID: "chat", workspaceID: "workspace", profileID: "profile", title: "Side", kept: true)
        model.displays["side"] = SessionDisplay(id: "side")
        model.focusedSessionID = "other"; model.selectedID = "other"
        XCTAssertEqual(model.recentlyOpened.prefix(2), ["other", "chat"])
        model.openReport()
        _ = await model.revealMessage(sessionID: "side", messageID: nil)
        XCTAssertEqual(model.focusedSessionID, "side")
        XCTAssertEqual(model.recentlyOpened.prefix(3), ["side", "other", "chat"], "the chat passed through is not opened again")
        try await close(model, root: root)
    }

    /// The parent passed over is only the focus the navigation gives it: the
    /// reader coming to it meanwhile is an opening.
    @MainActor func testOnlyTheNavigationsOwnFocusOfTheParentIsPassedOver() async throws {
        let (model, root, _) = try await makeModel()
        model.chats.append(ChatRecord(id: "other", workspaceID: "workspace", title: "Other", path: nil, profileID: "profile"))
        model.focusedSessionID = "other"
        await model.passingThrough("chat") {
            model.focusedSessionID = "chat"      // the navigation's own
            model.focusedSessionID = "other"
            model.focusedSessionID = "chat"      // the reader's
        }
        XCTAssertEqual(model.recentlyOpened.first, "chat")
        // The parent already focused: the navigation's own focus of it still takes the pass.
        await model.passingThrough("chat") {
            model.focusedSessionID = "chat"      // the navigation's own, unchanged
            model.focusedSessionID = "other"
            model.focusedSessionID = "chat"      // the reader's
        }
        XCTAssertEqual(model.recentlyOpened.prefix(2), ["chat", "other"])
        // A New chat thrown away unsent holds no place.
        model.chats.append(ChatRecord(id: "new", workspaceID: "workspace", title: ChatRecord.defaultTitle, path: nil, profileID: "profile"))
        model.pendingChatIDs = ["new"]; model.focusedSessionID = "new"
        model.discardPendingChat("new")
        XCTAssertFalse(model.recentlyOpened.contains("new"))
        try await close(model, root: root)
    }

    @MainActor func testLoadedHistoricalPageReceivesRetainedAccountingWithoutStartingHost() async throws {
        let (model, root, view) = try await makeModel()
        let wall = Date().timeIntervalSince1970
        let metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("chat"), "turnId": .string("old-input"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("auto-router"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(wall), "dispatchWallTimestamp": .number(wall), "timingVersion": .number(2), "timings": .object(["dispatch": .number(1), "httpEnd": .number(3)]), "messageIds": .array([.string("old-input")]), "outputMessageIds": .array([.string("old-answer")]), "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.0013875)])]), "usage": .object(["inputIncludingCache": .number(38), "output": .number(302), "reasoning": .number(253)])]
        try await model.traces.begin(metadata, workspace: "workspace"); try await model.traces.finish(metadata)
        let page = oldPage
        let result = await model.revealMessage(sessionID: "chat", messageID: "old-answer", historyLookup: { _, _ in page })
        XCTAssertTrue(result); XCTAssertTrue(view.browsingHistory); XCTAssertEqual(view.scrollAnchor?.id, "old-answer")
        XCTAssertNil(view.messages.first?.accounting, "Accounting belongs to the answer while input Details stays linked")
        XCTAssertEqual(view.messages.last?.accounting?.costUSD, 0.0013875)
        XCTAssertEqual(view.messages.last?.accounting?.tokens?.total, 340)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        try await close(model, root: root)
    }

    @MainActor func testDelayedOldPageCannotReplaceNewerMessageNavigation() async throws {
        let (model, root, view) = try await makeModel(), gate = MessageNavigationGate()
        let delayed = Task { await model.revealMessage(sessionID: "chat", messageID: "old-answer", historyLookup: { _, _ in await gate.read() }) }
        await gate.entered()
        let current = await model.revealMessage(sessionID: "chat", messageID: "latest")
        XCTAssertTrue(current)
        await gate.release(oldPage)
        let result = await delayed.value
        XCTAssertFalse(result); XCTAssertEqual(view.messages.map(\.id), ["latest"]); XCTAssertEqual(view.scrollAnchor?.id, "latest")
        XCTAssertNil(model.lastInspectorFocus)
        try await close(model, root: root)
    }

    @MainActor func testLeavingAndReturningToSameChatInvalidatesPendingNavigation() async throws {
        let (model, root, view) = try await makeModel(), gate = MessageNavigationGate()
        let delayed = Task { await model.revealMessage(sessionID: "chat", messageID: "old-answer", historyLookup: { _, _ in await gate.read() }) }
        await gate.entered()
        model.selectedID = "another-chat"; model.selectedID = "chat"
        await gate.release(oldPage)
        let result = await delayed.value
        XCTAssertFalse(result); XCTAssertEqual(view.messages.map(\.id), ["latest"]); XCTAssertNil(model.lastInspectorFocus)
        try await close(model, root: root)
    }

    @MainActor func testReopeningReportOrCancellingPreventsDelayedSheetAndPageChanges() async throws {
        for cancel in [false, true] {
            let (model, root, view) = try await makeModel(), gate = MessageNavigationGate()
            let delayed = Task { await model.revealMessage(sessionID: "chat", messageID: "missing", historyLookup: { _, _ in await gate.read() }) }
            await gate.entered()
            if cancel { delayed.cancel() } else { model.openReport() }
            await gate.release(oldPage)
            let result = await delayed.value
            XCTAssertFalse(result); XCTAssertEqual(view.messages.map(\.id), ["latest"]); XCTAssertNil(model.lastInspectorFocus)
            XCTAssertEqual(model.page, cancel ? .chats : .report)
            try await close(model, root: root)
        }
    }

    func testReasoningReportLabelsDescribeSubsetsWithoutChangingTotals() {
        var totals = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.0013875)
        totals.tokens = GatewayTokenTotals(input: 38, output: 302, total: 340, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 253, reasoningSamples: 1)
        totals.reasoningCostUSD = 0.0011385; totals.reasoningCostSamples = 1
        let detail = reportReasoningDetail(totals)
        XCTAssertTrue(detail.contains("253 tokens (1/1 reported) are counted within output"))
        XCTAssertTrue(detail.contains("$0.0011385 USD (1/1 reported) is the gateway's reported share and is never added to the total"))
        XCTAssertEqual(totals.tokens?.total, 340); XCTAssertEqual(totals.costUSD, 0.0013875)
    }
}

extension ReportMessageNavigationTests {
    /// Opening a message from the Report while the chat on screen is an empty
    /// New chat: that chat is dropped on the way, and dropping it used to
    /// count as another navigation, so this one gave up without a word.
    @MainActor func testOpeningAMessageWhileAnEmptyNewChatIsOnScreenReachesIt() async throws {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("message-navigation-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        let empty = ChatRecord(id: "empty", workspaceID: "workspace", title: "New chat", path: nil, profileID: "profile")
        let saved = ChatRecord(id: "saved", workspaceID: "workspace", title: "Saved chat", path: nil, profileID: "profile")
        model.chats = [empty, saved]; model.pendingChatIDs = [empty.id]
        let blank = SessionDisplay(id: empty.id)
        model.displays[empty.id] = blank; model.selectedID = empty.id; model.selected = blank; model.focusedSessionID = empty.id
        model.historyWindowLoader = { id, _, _, _ in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture:" + id), "lineage": .string("root"),
                "messages": .array([.object(["id": .string("question"), "role": .string("user"), "text": .string("Question")]),
                                    .object(["id": .string("target"), "role": .string("assistant"), "text": .string("The answer")])]),
                "older": .null, "newer": .null]))
        }
        model.openReport()
        let result = await model.revealMessage(sessionID: saved.id, messageID: "target")
        XCTAssertTrue(result, "The message opens")
        XCTAssertEqual(model.selectedID, saved.id); XCTAssertEqual(model.page, .chats)
        XCTAssertEqual(model.displays[saved.id]?.scrollAnchor?.id, "target")
        XCTAssertFalse(model.chats.contains { $0.id == empty.id }, "The empty New chat was dropped on the way")
        try await close(model, root: root)
    }
}
