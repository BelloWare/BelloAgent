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
        XCTAssertFalse(model.showMessageDetail)
        try await close(model, root: root)
    }

    @MainActor func testLeavingAndReturningToSameChatInvalidatesPendingNavigation() async throws {
        let (model, root, view) = try await makeModel(), gate = MessageNavigationGate()
        let delayed = Task { await model.revealMessage(sessionID: "chat", messageID: "old-answer", historyLookup: { _, _ in await gate.read() }) }
        await gate.entered()
        model.selectedID = "another-chat"; model.selectedID = "chat"
        await gate.release(oldPage)
        let result = await delayed.value
        XCTAssertFalse(result); XCTAssertEqual(view.messages.map(\.id), ["latest"]); XCTAssertFalse(model.showMessageDetail)
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
            XCTAssertFalse(result); XCTAssertEqual(view.messages.map(\.id), ["latest"]); XCTAssertFalse(model.showMessageDetail)
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
