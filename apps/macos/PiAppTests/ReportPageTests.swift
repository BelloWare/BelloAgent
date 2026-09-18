import XCTest
@testable import PiApp

/// Navigation to the report page and the controller state behind it.
final class ReportPageTests: XCTestCase {
    private func folder() throws -> URL {
        let result = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    @MainActor private func makeModel() throws -> (WorkspaceModel, URL) {
        let root = try folder()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        return (model, root)
    }

    @MainActor private func record(_ model: WorkspaceModel) async throws {
        let metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("s"), "turnId": .string("t"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("alias"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(Date().timeIntervalSince1970 - 605), "dispatchWallTimestamp": .number(Date().timeIntervalSince1970 - 600), "timingVersion": .number(2), "messageIds": .array([.string("m")]), "timings": .object(["dispatch": .number(1000), "firstContent": .number(1010), "modelComplete": .number(1030), "httpEnd": .number(1100)])]
        try await model.traces.begin(metadata, workspace: "w"); try await model.traces.finish(metadata)
    }

    @MainActor func testReportIsAPageThatPreservesChatSelectionAndDraft() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example.com"; profile.modelId = "alias"
        let connection = VaultProfile(profile: profile, apiKey: "k")
        _ = try await model.vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [connection] }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat-1", workspaceID: "w", title: "Retry loop", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        model.displays[chat.id]?.draft = "half-written follow-up"
        XCTAssertEqual(model.page, .chats)

        model.openReport()
        XCTAssertEqual(model.page, .report)
        XCTAssertTrue(model.showDashboard, "Legacy entry points map onto the page")
        XCTAssertEqual(model.selectedID, chat.id, "Opening the report keeps the selected chat")
        XCTAssertEqual(model.focusedSessionID, chat.id)
        XCTAssertEqual(model.displays[chat.id]?.draft, "half-written follow-up", "The draft is untouched")
        XCTAssertNotNil(model.selected, "The chat pane stays mounted underneath")

        model.toggleReport()
        XCTAssertEqual(model.page, .chats)
        model.showDashboard = true
        XCTAssertEqual(model.page, .report)
        model.closeReport()
        XCTAssertFalse(model.showDashboard)

        model.openReport()
        await model.select(chat.id)
        XCTAssertEqual(model.page, .chats, "Choosing a chat returns to the chat page")
        model.openReport(); model.newChat()
        XCTAssertEqual(model.page, .chats, "New chat returns to the chat page")
        model.report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testActiveFilterChipsResetAndSelectionFollowTheController() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let report = model.report
        XCTAssertEqual(report.activeFilterCount, 0)
        report.preferences.status = "failed"
        report.preferences.api = "anthropic-messages"
        report.preferences.workspaceID = "w"
        report.preferences.sessionID = "s"
        report.unreportedOnly = true
        report.preferences.effectiveModel = "hidden-by-unreported"
        let chips = report.activeFilters(workspaces: [WorkspaceRecord(id: "w", path: "/tmp/repo", trusted: true)], chats: [ChatRecord(id: "s", workspaceID: "w", title: "Explain cache", path: nil, profileID: "p")])
        XCTAssertEqual(chips.map(\.kind), [.workspace, .session, .status, .api, .unreported])
        XCTAssertEqual(chips[0].label, "Project · repo")
        XCTAssertEqual(chips[1].label, "Session · Explain cache")
        XCTAssertEqual(chips[3].label, "API · Messages")
        XCTAssertEqual(report.activeFilterCount, 5)

        report.clear(chips[0])
        XCTAssertNil(report.preferences.workspaceID); XCTAssertNil(report.preferences.sessionID, "Clearing the workspace drops its session filter")
        report.clear(ReportFilterChip(kind: .unreported, label: ""))
        XCTAssertFalse(report.unreportedOnly)
        XCTAssertEqual(report.activeFilters(workspaces: [], chats: []).map(\.kind), [.status, .api, .model], "The resolved-model filter reappears once unreported-only is off")

        report.setWorkspace("w"); report.preferences.sessionID = "s"; report.setWorkspace("other")
        XCTAssertNil(report.preferences.sessionID, "Changing workspace clears the session")
        report.chooseSession(ReportController.manualSession)
        XCTAssertTrue(report.sessionEntry)
        report.chooseSession("abc")
        XCTAssertFalse(report.sessionEntry); XCTAssertEqual(report.preferences.sessionID, "abc")

        report.setPreset(.week)
        XCTAssertEqual(report.window.preset, .week); XCTAssertEqual(report.preferences.windowHours, 168)
        report.setPreset(.custom)
        XCTAssertNotNil(report.preferences.customFrom)
        report.setCustomBound(Date(timeIntervalSince1970: 100), anchorFrom: true)
        XCTAssertEqual(report.preferences.customFrom, Date(timeIntervalSince1970: 100))
        XCTAssertGreaterThanOrEqual(report.preferences.customUntil!.timeIntervalSince(report.preferences.customFrom!), DashboardWindowPreset.minimumSpan)

        report.preferences.metricRetentionDays = 42
        report.reset()
        XCTAssertEqual(report.activeFilterCount, 0)
        XCTAssertEqual(report.preferences.metricRetentionDays, 42, "Reset keeps the retention setting")
        XCTAssertNil(report.brush); XCTAssertEqual(report.window.preset, .day)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testPrepareQueriesTheArchiveAndBrushNarrowsTheActiveSnapshot() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        try await model.traces.configure(key: Data(repeating: 0x29, count: 32), quota: 1_048_576, bodyRetention: 100, metricRetention: 100_000)
        let report = model.report
        let now = Date()
        var metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("s"), "turnId": .string("t"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("alias"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(now.timeIntervalSince1970 - 605), "dispatchWallTimestamp": .number(now.timeIntervalSince1970 - 600), "timingVersion": .number(2), "messageIds": .array([.string("m")])]
        metadata["timings"] = .object(["dispatch": .number(1000), "firstContent": .number(1010), "modelComplete": .number(1030), "httpEnd": .number(1100)])
        try await model.traces.begin(metadata, workspace: "w"); try await model.traces.finish(metadata)
        await report.prepare()
        let snapshot = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(snapshot.scopeCounts.dispatched, 1)
        XCTAssertNil(report.failure)
        XCTAssertTrue(report.hasResults)

        // A brush outside the request narrows the active snapshot to nothing without touching the window.
        let brush = try XCTUnwrap(DashboardBrush(now.addingTimeInterval(-300), now.addingTimeInterval(-60), in: snapshot.filter))
        report.applyBrush(brush)
        for _ in 0..<50 where report.focused == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(report.focused?.selectedRequests, 0)
        XCTAssertEqual(report.snapshot?.scopeCounts.dispatched, 1, "The full window snapshot is unchanged")
        report.clearBrush()
        XCTAssertNil(report.focused); XCTAssertNil(report.brush)

        // Changing a filter refreshes after the debounce and keeps the results available.
        report.preferences.status = "failed"
        try await Task.sleep(for: .milliseconds(ReportController.debounceMilliseconds + 400))
        for _ in 0..<50 where report.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(report.snapshot?.selectedRequests, 0, "No failed requests")
        XCTAssertEqual(report.snapshot?.scopeCounts.dispatched, 1, "Counts still cover every status")
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testClosingDuringFilterDebounceReappliesChangesOnReturnAndGuardsPaging() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe(), report = ReportController { archive, filter, offset in try await probe.run(archive, filter, offset) }
        report.attach(model); await report.prepare()
        let original = try XCTUnwrap(report.snapshot)
        report.preferences.status = "failed"
        XCTAssertTrue(report.filtersPending)
        XCTAssertEqual(report.activeFilterCount, 0, "Visible chips still describe the retained completed snapshot")
        XCTAssertEqual(report.appliedWindow.until, original.filter.until)
        await report.page(offset: 128)
        let before = await probe.calls; XCTAssertEqual(before.count, 1, "Paging cannot fetch old filters while edits are pending")
        report.suspend()
        XCTAssertFalse(report.loading); XCTAssertTrue(report.filtersPending)
        await report.prepare()
        XCTAssertFalse(report.filtersPending); XCTAssertEqual(report.snapshot?.filter.status, "failed")
        XCTAssertEqual(report.snapshot?.selectedRequests, 0)
        XCTAssertEqual(report.activeFilters(workspaces: [], chats: []).map(\.kind), [.status])
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testReturningToReportRefreshesRequestsWithoutResettingChoices() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let report = model.report
        await report.prepare(); report.advancedOpen = true; report.detailsOpen = true; report.chartMetric = "Cost"
        report.preferences.requestedAlias = "alias"; await report.refresh()
        report.suspend(); try await record(model)
        await report.prepare()
        XCTAssertEqual(report.snapshot?.selectedRequests, 2)
        XCTAssertEqual(report.preferences.requestedAlias, "alias")
        XCTAssertTrue(report.advancedOpen); XCTAssertTrue(report.detailsOpen); XCTAssertEqual(report.chartMetric, "Cost")
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testConfigurationFailureRetriesSavedDefaultsInsteadOfQueryingFallbacks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"; saved.dashboard.windowHours = 168
        let storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved), failFirst: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        let report = model.report
        await report.prepare()
        XCTAssertNotNil(report.failure); XCTAssertNil(report.snapshot); XCTAssertFalse(report.loading)
        await report.refresh()
        XCTAssertNil(report.failure); XCTAssertEqual(report.snapshot?.filter.status, "failed")
        XCTAssertEqual(report.appliedWindow.preset, .week); XCTAssertEqual(storage.reads, 2)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testConcurrentPrepareCoalescesAndDoesNotReplaceAnEarlyFilterEdit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"
        let gate = ReportReadGate(), storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved), gate: gate)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        let report = model.report
        let first = Task { await report.prepare() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        let second = Task { await report.prepare() }
        report.preferences.status = "cancelled"
        gate.release(); await first.value; await second.value
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(report.preferences.status, "cancelled"); XCTAssertEqual(report.snapshot?.filter.status, "cancelled")
        XCTAssertFalse(report.filtersPending); XCTAssertFalse(report.loading)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testCancelledFirstVisitDoesNotLoadAndLaterVisitKeepsEarlierEdits() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"
        let storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved))
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        let report = model.report
        report.preferences.status = "cancelled"
        let obsolete = Task { await report.prepare() }
        obsolete.cancel(); await obsolete.value
        XCTAssertEqual(storage.reads, 0); XCTAssertNil(report.snapshot); XCTAssertFalse(report.loading)
        await report.prepare()
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(report.snapshot?.filter.status, "cancelled", "First defaults must not overwrite edits made before prepare begins")
        XCTAssertFalse(report.filtersPending)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testLateFailureAfterSuspendCannotReplaceReopenedResults() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe(), report = ReportController { archive, filter, offset in try await probe.run(archive, filter, offset) }
        report.attach(model); await report.prepare()
        await probe.blockNext(fail: true)
        let obsolete = Task { await report.refresh() }
        await probe.waitForBlock()
        report.suspend(); try await record(model)
        report.preferences.requestedAlias = "alias"
        await report.prepare()
        XCTAssertEqual(report.snapshot?.selectedRequests, 2); XCTAssertNil(report.failure)
        await probe.release(); await obsolete.value
        XCTAssertEqual(report.snapshot?.selectedRequests, 2); XCTAssertEqual(report.snapshot?.filter.requestedAlias, "alias")
        XCTAssertNil(report.failure); XCTAssertFalse(report.loading)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testBrushPublishesOnlyItsOwnResultsAndCannotRacePagingOrClearing() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe(), report = ReportController { archive, filter, offset in try await probe.run(archive, filter, offset) }
        report.attach(model); await report.prepare()
        let original = try XCTUnwrap(report.snapshot), now = Date()
        let brush = try XCTUnwrap(DashboardBrush(now.addingTimeInterval(-300), now.addingTimeInterval(-60), in: original.filter))
        await probe.blockNext()
        report.applyBrush(brush); await probe.waitForBlock()
        XCTAssertTrue(report.loading); XCTAssertNil(report.brush, "Full-window totals must not be labelled as narrowed before results arrive")
        XCTAssertNil(report.focused); XCTAssertEqual(report.brushPreview, brush)
        await report.page(offset: 128)
        let during = await probe.calls; XCTAssertEqual(during.count, 2)
        report.clearBrush(); await probe.release()
        report.applyBrush(brush)
        for _ in 0..<100 where report.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(report.brush, brush); XCTAssertEqual(report.focused?.selectedRequests, 0)
        XCTAssertEqual(report.snapshot?.selectedRequests, 1); XCTAssertNil(report.failure)
        await report.page(offset: 0)
        let calls = await probe.calls; XCTAssertEqual(calls.last?.filter.from, brush.from); XCTAssertEqual(calls.last?.filter.until, brush.until)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testInvalidPendingFilterKeepsHonestAppliedLabelsUntilRetrySucceeds() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let report = model.report; await report.prepare()
        let original = try XCTUnwrap(report.snapshot)
        report.preferences.status = "invalid-status"; await report.refresh()
        XCTAssertNotNil(report.failure); XCTAssertTrue(report.filtersPending)
        XCTAssertEqual(report.snapshot?.filter.status, "completed"); XCTAssertEqual(report.activeFilterCount, 0)
        XCTAssertEqual(report.appliedWindow.from, original.filter.from); XCTAssertEqual(report.appliedWindow.until, original.filter.until)
        report.preferences.status = "failed"; await report.refresh()
        XCTAssertNil(report.failure); XCTAssertFalse(report.filtersPending)
        XCTAssertEqual(report.snapshot?.filter.status, "failed"); XCTAssertEqual(report.activeFilterCount, 1)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testExpandedSessionsReloadAfterRefreshAndCanceledExpansionCannotReappear() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe()
        let report = ReportController(query: { try await probe.run($0, $1, $2) }); report.attach(model)
        await report.prepare(); report.toggleSession("s")
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 1)
        try await record(model); await report.refresh()
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(report.expandedSessions.contains("s"))
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2, "An expanded row must reload instead of remaining a spinner")
        report.toggleSession("s"); await report.refresh()
        await probe.blockNext(fail: true); report.toggleSession("s"); await probe.waitForBlock()
        report.suspend(); await probe.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(report.failure); XCTAssertTrue(report.sessionRequests.isEmpty)
        await report.prepare()
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2)
        report.suspend(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testObsoleteSessionPageErrorCannotReplaceNewerPageOrHiddenReport() async throws {
        let (model, root) = try makeModel(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration(); try await record(model)
        let gate = ReportQueryProbe()
        let report = ReportController(sessionQuery: { archive, filter, offset in
            _ = try await gate.run(archive, filter, offset)
            return try await archive.sessionSummaries(filter, offset: offset)
        }); report.attach(model); await report.prepare()
        await gate.blockNext(fail: true)
        let old = Task { await report.pageSessions(offset: 32) }; await gate.waitForBlock()
        await report.pageSessions(offset: 0)
        await gate.release(); await old.value
        XCTAssertEqual(report.sessions?.offset, 0); XCTAssertEqual(report.sessions?.sessions.count, 1); XCTAssertNil(report.failure)
        await gate.blockNext(fail: true)
        let hidden = Task { await report.reloadSessions() }; await gate.waitForBlock()
        report.suspend(); await gate.release(); await hidden.value
        XCTAssertNil(report.failure, "A hidden query cannot publish errors")
        try await model.traces.close(); await model.store?.close()
    }
}

private actor ReportQueryProbe {
    struct Call: Sendable { let filter: DashboardFilter; let offset: Int }
    private(set) var calls: [Call] = []
    private var shouldBlock = false
    private var failBlocked = false
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func blockNext(fail: Bool = false) { shouldBlock = true; failBlocked = fail; blocked = false }
    func run(_ archive: PayloadArchive, _ filter: DashboardFilter, _ offset: Int) async throws -> DashboardSnapshot {
        calls.append(Call(filter: filter, offset: offset))
        if shouldBlock {
            shouldBlock = false; blocked = true
            let fail = failBlocked
            entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            await withCheckedContinuation { waiter = $0 }
            if fail { throw CaptureFailure.unavailable }
        }
        return try await archive.dashboard(filter, offset: offset)
    }
    func waitForBlock() async { if !blocked { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}

private final class ReportReadGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = semaphore.wait(timeout: .now() + 3) }
    func release() { semaphore.signal() }
}

private final class ReportTestVaultStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private let failFirst: Bool
    private let gate: ReportReadGate?
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    init(bytes: Data, failFirst: Bool = false, gate: ReportReadGate? = nil) { self.bytes = bytes; self.failFirst = failFirst; self.gate = gate }
    func read() throws -> Data? {
        let count = lock.withLock { readCount += 1; return readCount }
        if count == 1, failFirst { throw VaultError.denied(-25308) }
        gate?.hold()
        return bytes
    }
    func replace(expected: Data?, with replacement: Data) throws { throw VaultError.denied(-25308) }
}

extension ReportPageTests {
    @MainActor func testRevealMessageOpensTheChatOrExplainsWhyItCannot() async throws {
        let (model, root) = try makeModel(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example.com"; profile.modelId = "alias"
        let connection = VaultProfile(profile: profile, apiKey: "k")
        _ = try await model.vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [connection] }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat-1", workspaceID: "w", title: "Retry loop", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        model.displays[chat.id]?.messages = [TranscriptMessage(id: "m-visible", role: "user", text: "hello")]
        model.openReport()

        // A request whose chat was deleted (or was an unkept side) is explained, not silently ignored.
        let missing = await model.revealMessage(sessionID: "gone", messageID: "m")
        XCTAssertFalse(missing); XCTAssertTrue(model.error?.contains("no longer available") == true)
        XCTAssertEqual(model.page, .report, "Nothing to navigate to")
        model.error = nil

        // A visible message scrolls the transcript and returns to the chat page.
        let before = model.displays[chat.id]?.viewportRequest ?? 0
        let visible = await model.revealMessage(sessionID: chat.id, messageID: "m-visible")
        XCTAssertTrue(visible); XCTAssertEqual(model.page, .chats); XCTAssertEqual(model.selectedID, chat.id)
        XCTAssertEqual(model.displays[chat.id]?.scrollAnchor?.id, "m-visible")
        XCTAssertEqual(model.displays[chat.id]?.viewportRequest, before + 1)
        XCTAssertFalse(model.showMessageDetail)

        // A message that left the visible transcript (edited away or unloaded) opens its details with an explanation.
        model.openReport()
        let hidden = await model.revealMessage(sessionID: chat.id, messageID: "m-edited-away")
        XCTAssertTrue(hidden); XCTAssertEqual(model.page, .chats)
        XCTAssertTrue(model.showMessageDetail); XCTAssertEqual(model.messageDetailID, "m-edited-away"); XCTAssertEqual(model.messageDetailSessionID, chat.id)

        // Opening a chat without a message just navigates.
        model.showMessageDetail = false; model.openReport()
        let opened = await model.revealMessage(sessionID: chat.id, messageID: nil)
        XCTAssertTrue(opened); XCTAssertEqual(model.page, .chats); XCTAssertFalse(model.showMessageDetail)
    }

    @MainActor func testNewChatRequiresAWorkspaceAndGroupingStateFollowsTheController() async throws {
        let (model, root) = try makeModel(); defer { try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        XCTAssertTrue(model.workspaces.isEmpty)
        model.newChat()
        XCTAssertTrue(model.showWorkspaceManager, "Without a workspace, New Chat opens the workspace manager instead of creating a chat")
        XCTAssertTrue(model.chats.isEmpty)

        let report = model.report
        XCTAssertEqual(report.grouping, "requests")
        report.toggleSession("s1")
        XCTAssertTrue(report.expandedSessions.contains("s1"))
        report.toggleSession("s1")
        XCTAssertFalse(report.expandedSessions.contains("s1"))
        XCTAssertNil(report.sessions, "No query has run yet")
    }
}
