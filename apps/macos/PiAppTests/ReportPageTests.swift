import XCTest
import Combine
import SwiftUI
import AppKit
import Charts
@testable import PiApp

/// Navigation to the report page and the controller state behind it.
final class ReportPageTests: XCTestCase {
    func testLiveChartNeverIgnoresNarrowRequestFilters() {
        let base = DashboardFilter(from: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(base.supportsProjectLiveHistory)
        var project = base; project.workspaceID = "project"
        XCTAssertTrue(project.supportsProjectLiveHistory)
        for key in [\DashboardFilter.sessionID, \.purpose, \.api, \.requestedAlias, \.effectiveModel] {
            var scoped = base; scoped[keyPath: key] = "filtered"
            XCTAssertFalse(scoped.supportsProjectLiveHistory)
        }
        var unreported = base; unreported.unreportedModelOnly = true
        XCTAssertFalse(unreported.supportsProjectLiveHistory)
        var failures = base; failures.status = "failed"
        XCTAssertFalse(failures.supportsProjectLiveHistory)
    }

    func testShortAnalyticsPresetsRemainRelativeAndSaveIndependentlyOfHourFallback() {
        let now = Date(timeIntervalSince1970: 2000)
        for (preset, seconds) in [(DashboardWindowPreset.fiveMinutes, 300.0), (.fifteenMinutes, 900.0)] {
            var preferences = DashboardPreferences()
            DashboardWindow.apply(preset, to: &preferences, now: now)
            let window = DashboardWindow.resolve(preferences, now: now.addingTimeInterval(30))
            XCTAssertEqual(window.span, seconds)
            XCTAssertEqual(window.until, now.addingTimeInterval(30))
            XCTAssertEqual(window.preset, preset)
            XCTAssertNil(preferences.customFrom)
        }
    }
    private func folder() throws -> URL {
        let result = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    @MainActor private func makeModel() throws -> (WorkspaceModel, URL) {
        let root = try folder()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        return (model, root)
    }

    @MainActor private func record(_ model: WorkspaceModel) async throws {
        let metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("s"), "turnId": .string("t"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("alias"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(Date().timeIntervalSince1970 - 605), "dispatchWallTimestamp": .number(Date().timeIntervalSince1970 - 600), "timingVersion": .number(2), "messageIds": .array([.string("m")]), "timings": .object(["dispatch": .number(1000), "firstContent": .number(1010), "modelComplete": .number(1030), "httpEnd": .number(1100)])]
        try await model.traces.begin(metadata, workspace: "w"); try await model.traces.finish(metadata)
    }

    @MainActor func testReportIsAPageThatPreservesChatSelectionAndDraft() async throws {
        let (model, root) = try makeModel()
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
        model.report.suspend()
    }

    @MainActor func testActiveFilterChipsResetAndSelectionFollowTheController() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testPrepareQueriesTheArchiveAndBrushNarrowsTheActiveSnapshot() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testClosingDuringFilterDebounceReappliesChangesOnReturnAndGuardsPaging() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testReturningToReportRefreshesRequestsWithoutResettingChoices() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let report = model.report
        await report.prepare(); report.advancedOpen = true; report.detailsOpen = true; report.chartMetric = "Cost"
        report.preferences.requestedAlias = "alias"; await report.refresh()
        report.suspend(); try await record(model)
        await report.prepare()
        XCTAssertEqual(report.snapshot?.selectedRequests, 2)
        XCTAssertEqual(report.preferences.requestedAlias, "alias")
        XCTAssertTrue(report.advancedOpen); XCTAssertTrue(report.detailsOpen); XCTAssertEqual(report.chartMetric, "Cost")
        report.suspend()
    }

    @MainActor func testConfigurationFailureRetriesSavedDefaultsInsteadOfQueryingFallbacks() async throws {
        let root = try folder()
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"; saved.dashboard.windowHours = 168
        let storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved), failFirst: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        registerWorkspaceFixtureTeardown(model, root: root)
        let report = model.report
        await report.prepare()
        XCTAssertNotNil(report.failure); XCTAssertNil(report.snapshot); XCTAssertFalse(report.loading)
        await report.refresh()
        XCTAssertNil(report.failure); XCTAssertEqual(report.snapshot?.filter.status, "failed")
        XCTAssertEqual(report.appliedWindow.preset, .week); XCTAssertEqual(storage.reads, 2)
        report.suspend()
    }

    @MainActor func testConcurrentPrepareCoalescesAndDoesNotReplaceAnEarlyFilterEdit() async throws {
        let root = try folder()
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"
        let gate = ReportReadGate(), storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved), gate: gate)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        registerWorkspaceFixtureTeardown(model, root: root)
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
        report.suspend()
    }

    @MainActor func testCancelledFirstVisitDoesNotLoadAndLaterVisitKeepsEarlierEdits() async throws {
        let root = try folder()
        var saved = VaultConfiguration(); saved.dashboard.status = "failed"
        let storage = ReportTestVaultStorage(bytes: try JSONEncoder().encode(saved))
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        registerWorkspaceFixtureTeardown(model, root: root)
        let report = model.report
        report.preferences.status = "cancelled"
        let obsolete = Task { await report.prepare() }
        obsolete.cancel(); await obsolete.value
        XCTAssertEqual(storage.reads, 0); XCTAssertNil(report.snapshot); XCTAssertFalse(report.loading)
        await report.prepare()
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(report.snapshot?.filter.status, "cancelled", "First defaults must not overwrite edits made before prepare begins")
        XCTAssertFalse(report.filtersPending)
        report.suspend()
    }

    @MainActor func testLateFailureAfterSuspendCannotReplaceReopenedResults() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testBrushPublishesOnlyItsOwnResultsAndCannotRacePagingOrClearing() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testInvalidPendingFilterKeepsHonestAppliedLabelsUntilRetrySucceeds() async throws {
        let (model, _) = try makeModel()
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
        report.suspend()
    }

    @MainActor func testExpandedSessionsReloadAfterRefreshAndCanceledExpansionCannotReappear() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe()
        let report = ReportController(query: { try await probe.run($0, $1, $2) }, pageQuery: { archive, filter, offset in
            let result = try await probe.run(archive, filter, offset)
            return DashboardRequestPage(filter: result.filter, selectedRequests: result.selectedRequests, requests: result.requests, offset: result.offset)
        }); report.attach(model)
        await report.prepare(); report.toggleSession("s")
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 1)
        try await record(model); await report.refresh()
        // The row keeps its previous requests (never a spinner) until the reload lands.
        for _ in 0..<200 where report.sessionRequests["s"]?.selectedRequests != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(report.expandedSessions.contains("s"))
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2, "An expanded row must reload instead of remaining a spinner")
        report.toggleSession("s"); await report.refresh()
        await probe.blockNext(fail: true); report.toggleSession("s"); await probe.waitForBlock()
        report.suspend(); await probe.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(report.failure, "The cancelled expansion's failure is not published")
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2, "Nor its result: the row keeps the last requests it read")
        await report.prepare()
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2)
        report.suspend()
    }

    @MainActor func testObsoleteSessionPageErrorCannotReplaceNewerPageOrHiddenReport() async throws {
        let (model, _) = try makeModel()
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
    }
}

extension ReportPageTests {
    /// A refresh used to clear the per-route split, the session page and the
    /// expanded sessions' requests while it read their replacements: the
    /// routing map and cost card said "No model routes reported", the lists
    /// showed spinners, then everything refilled.
    @MainActor func testRefreshKeepsRoutingAndGroupedListsUntilTheirReplacementsLand() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let gate = ReportGate()
        let report = ReportController(modelQuery: { archive, filter in
            await gate.pass()
            return try await archive.modelSummaries(filter)
        })
        report.attach(model); await report.prepare()
        report.toggleSession("s")
        for _ in 0..<200 where report.sessionRequests["s"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(report.modelSummaries); XCTAssertNotNil(report.sessions); XCTAssertNotNil(report.sessionRequests["s"])
        var blanks: [String] = []
        let observers = [report.$modelSummaries.sink { if $0 == nil { blanks.append("routes") } },
                         report.$sessions.sink { if $0 == nil { blanks.append("sessions") } },
                         report.$sessionRequests.sink { if $0["s"] == nil { blanks.append("session requests") } }]
        defer { observers.forEach { $0.cancel() }; report.suspend() }
        try await record(model)
        await gate.arm()
        let refresh = Task { await report.refresh() }
        await gate.waitForBlock()
        XCTAssertNotNil(report.modelSummaries, "The routing map keeps its routes while the refresh reads new ones")
        XCTAssertNotNil(report.sessions, "The session list stays while its replacement is read")
        XCTAssertNotNil(report.sessionRequests["s"], "An expanded session keeps its requests")
        await gate.release(); await refresh.value
        for _ in 0..<200 where report.sessionRequests["s"]?.selectedRequests != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(report.snapshot?.selectedRequests, 2)
        XCTAssertEqual(report.modelSummaries?.first?.requests, 2)
        XCTAssertEqual(report.sessions?.sessions.first?.requests, 2)
        XCTAssertEqual(report.sessionRequests["s"]?.selectedRequests, 2)
        XCTAssertEqual(blanks, [], "No grouping passes through an empty or loading state between two real values")
    }

    /// Replacing a chart selection used to clear the old one first. The
    /// throughput panel saw "no selection", reset its zoom, and that reset
    /// cancelled the new selection's query: zooming inside a zoom snapped back.
    @MainActor func testReplacingAChartSelectionNeverPassesThroughNoSelection() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let report = model.report; await report.prepare()
        defer { report.suspend() }
        let window = try XCTUnwrap(report.snapshot).filter, now = Date()
        let first = try XCTUnwrap(DashboardBrush(now.addingTimeInterval(-900), now.addingTimeInterval(-60), in: window))
        report.applyBrush(first)
        for _ in 0..<200 where report.brush != first || report.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(report.brush, first)
        var published: [DashboardBrush?] = []
        let observer = report.$brush.dropFirst().sink { published.append($0) }
        defer { observer.cancel() }
        let second = try XCTUnwrap(DashboardBrush(now.addingTimeInterval(-700), now.addingTimeInterval(-500), in: window))
        report.applyBrush(second)
        XCTAssertEqual(report.brush, first, "The current selection and its totals stay until the new ones arrive")
        XCTAssertEqual(report.brushPreview, second, "The chart shows the new selection meanwhile")
        for _ in 0..<200 where report.brush != second || report.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(report.brush, second)
        XCTAssertEqual(report.focused?.filter.from, second.from)
        XCTAssertNil(report.brushPreview)
        XCTAssertFalse(published.contains(nil), "The selection never passes through none: \(published)")
    }

    @MainActor private func surfaces(_ view: NSView) -> [MonitorChartInteraction.Surface] {
        (view as? MonitorChartInteraction.Surface).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
    }
    @MainActor private func drag(_ surface: MonitorChartInteraction.Surface, in window: NSWindow, from start: Double, to end: Double) throws {
        let plot = surface.plot
        func pointer(_ type: NSEvent.EventType, _ fraction: Double) throws -> NSEvent {
            let point = surface.convert(CGPoint(x: plot.minX + plot.width * fraction, y: plot.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try pointer(.leftMouseDown, start))
        surface.mouseDragged(with: try pointer(.leftMouseDragged, (start + end) / 2))
        surface.mouseDragged(with: try pointer(.leftMouseDragged, end))
        surface.mouseUp(with: try pointer(.leftMouseUp, end))
    }

    /// The Output tok/s chart on a real report page: a second drag inside the
    /// zoomed chart narrows the selection instead of snapping back, and a
    /// refresh keeps it and reads the window and the selection once each.
    @MainActor func testThroughputChartZoomsInsideItsZoomAndKeepsItThroughARefresh() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let probe = ReportQueryProbe()
        let report = ReportController(query: { try await probe.run($0, $1, $2) }, accounting: { _ in })
        report.attach(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: ReportPage(model: model, report: report))
        window.contentView = hosted; window.orderFront(nil)
        defer { report.suspend(); window.contentView = nil; window.close() }
        func settle(_ done: () -> Bool) async throws {
            for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)); hosted.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(100)); hosted.layoutSubtreeIfNeeded()
        }
        try await settle { report.snapshot != nil && !report.loading && !surfaces(hosted).isEmpty }
        try drag(try XCTUnwrap(surfaces(hosted).first), in: window, from: 0.2, to: 0.8)
        try await settle { report.brush != nil && !report.loading }
        let first = try XCTUnwrap(report.brush, "The first drag selects a range")
        try drag(try XCTUnwrap(surfaces(hosted).first), in: window, from: 0.25, to: 0.75)
        try await settle { report.brush != first && !report.loading }
        let second = try XCTUnwrap(report.brush, "Zooming inside the zoomed chart keeps a selection")
        XCTAssertGreaterThan(second.from, first.from); XCTAssertLessThan(second.until, first.until)
        let domain = try XCTUnwrap(surfaces(hosted).first).domain
        XCTAssertEqual(domain.lowerBound.timeIntervalSince1970, second.from.timeIntervalSince1970, accuracy: 1, "The chart shows the selection")
        XCTAssertEqual(domain.upperBound.timeIntervalSince1970, second.until.timeIntervalSince1970, accuracy: 1)
        let before = await probe.calls.count
        await report.refresh()
        try await settle { !report.loading }
        XCTAssertEqual(report.brush, second, "A refresh keeps the chart selection")
        let calls = await probe.calls.count - before
        XCTAssertEqual(calls, 2, "One pass: the window and the selection, once each")
    }

    /// Clicking a route in "By model" set only its alias and model. For an
    /// unresolved route (no model) that meant every model of the alias, on
    /// either API; the route's own count and the narrowed report disagreed.
    @MainActor func testChoosingARouteNarrowsTheReportToExactlyThatRoute() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration()
        func request(api: String, model reported: String?) async throws {
            var metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string("s"), "turnId": .string("t"), "purpose": .string("turn"), "api": .string(api), "requestedModel": .string("alias"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(Date().timeIntervalSince1970 - 605), "dispatchWallTimestamp": .number(Date().timeIntervalSince1970 - 600), "timingVersion": .number(2), "messageIds": .array([.string("m")]), "timings": .object(["dispatch": .number(1000), "firstContent": .number(1010), "modelComplete": .number(1030), "httpEnd": .number(1100)])]
            if let reported { metadata["identity"] = .object(["effectiveModel": .string(reported)]) }
            try await model.traces.begin(metadata, workspace: "w"); try await model.traces.finish(metadata)
        }
        try await request(api: "anthropic-messages", model: nil)
        try await request(api: "anthropic-messages", model: "alias")   // an alias echo is not a resolved model
        try await request(api: "anthropic-messages", model: "claude-model")
        try await request(api: "openai-responses", model: nil)
        let report = ReportController(accounting: { _ in }); report.attach(model)
        defer { report.suspend() }
        await report.prepare()
        let unresolved = try XCTUnwrap(report.modelSummaries?.first { $0.api == "anthropic-messages" && $0.model == nil })
        let resolved = try XCTUnwrap(report.modelSummaries?.first { $0.model == "claude-model" })
        XCTAssertEqual(unresolved.requests, 2)
        report.narrow(toRoute: unresolved)
        XCTAssertEqual(report.preferences.api, "anthropic-messages")
        XCTAssertTrue(report.unreportedOnly)
        await report.refresh()
        XCTAssertEqual(report.snapshot?.selectedRequests, unresolved.requests, "The narrowed report lists exactly the route's requests")
        XCTAssertEqual(report.modelSummaries?.map(\.id), [unresolved.id], "…and its routes are that one route")
        report.narrow(toRoute: resolved)
        XCTAssertFalse(report.unreportedOnly)
        await report.refresh()
        XCTAssertEqual(report.snapshot?.selectedRequests, 1)
    }

    /// Paging the request list replaced the rows but kept the total read with
    /// the first page: "129–145 of 139".
    @MainActor func testRequestPagerCountsWithTheTotalItsPageWasReadWith() {
        let filter = DashboardFilter(from: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 2_000))
        func row(_ index: Int) -> DashboardRequest {
            DashboardRequest(id: "r\(index)", sessionID: "s", workspaceID: "w", wall: Date(timeIntervalSince1970: 1_500), purpose: "turn", api: "openai-responses", alias: "alias",
                             effectiveModel: nil, identityStatus: "unreported", outcome: "completed", ttft: nil, streaming: nil, http: nil)
        }
        var snapshot = DashboardSnapshot(filter: filter, scopeCounts: DashboardCounts(), selectedRequests: 139, ttft: DashboardPercentiles(), streaming: DashboardPercentiles(),
                                         http: DashboardPercentiles(), buckets: [], requests: (0..<128).map(row), offset: 0)
        XCTAssertEqual(ReportPage.requestPageLabel(snapshot), "1–128 of 139")
        snapshot.replaceRows(DashboardRequestPage(filter: filter, selectedRequests: 145, requests: (128..<145).map(row), offset: 128))
        XCTAssertEqual(ReportPage.requestPageLabel(snapshot), "129–145 of 145")
    }

    /// "Cost by model" lists eight routes and the ring's legend four, both cut
    /// from a list ranked by output tokens: an expensive route with little
    /// output fell off the cost card.
    @MainActor func testCostCardAndCostLegendRankRoutesByCost() {
        var models = (0..<8).map { MonitorDistribution(id: "busy-\($0)", aliases: ["router"], tokens: Double(10_000 - $0), cost: 0.01, costShare: 0.01, requests: 10) }
        models.append(MonitorDistribution(id: "expensive", aliases: ["router"], tokens: 10, cost: 5, costShare: 0.9, requests: 1))
        XCTAssertEqual(ModelCostBreakdown.shown(models).first?.id, "expensive", "The costliest route leads the cost card")
        XCTAssertEqual(ModelCostBreakdown.shown(models).count, 8)
        XCTAssertEqual(ModelDistributionRing.legend(models, metric: .cost).first?.id, "expensive")
        XCTAssertEqual(ModelDistributionRing.legend(models, metric: .tokens).first?.id, "busy-0", "The token view keeps its token ranking")
    }

    /// Resizing the report across its wide-layout breakpoint rebuilt the
    /// throughput chart and routing map, resetting their zoom, metric and
    /// "Show all": the two layouts were different view trees.
    @MainActor func testThroughputChartKeepsItsIdentityAcrossTheWideLayoutBreakpoint() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration(); try await record(model)
        let report = ReportController(accounting: { _ in }); report.attach(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: ReportPage(model: model, report: report))
        window.contentView = hosted; window.orderFront(nil)
        defer { report.suspend(); window.contentView = nil; window.close() }
        for _ in 0..<300 where report.snapshot == nil || surfaces(hosted).isEmpty { try await Task.sleep(for: .milliseconds(10)); hosted.layoutSubtreeIfNeeded() }
        let chart = try XCTUnwrap(surfaces(hosted).first)
        for width in [1000.0, 1200, 1000] {
            window.setContentSize(NSSize(width: width, height: 900))
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
            XCTAssertTrue(surfaces(hosted).first === chart, "At \(Int(width)) pt the chart is the same view, so its zoom and metric survive")
        }
    }

    /// Dragging a range on the Requests/Cost/Latency/Cache chart wrote the
    /// preview into the report controller at every pointer move, so the whole
    /// report page re-rendered per move. Only the overlay should.
    @MainActor func testDraggingARangeRedrawsOnlyTheSelectionOverlay() async throws {
        let filter = DashboardFilter(from: Date(timeIntervalSince1970: 1_800_000_000), until: Date(timeIntervalSince1970: 1_800_003_600))
        var commits: [DashboardBrush?] = []
        BrushHostRenders.count = 0
        let host = BrushHost(filter: filter, commit: { commits.append($0) }, store: BrushHostStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: host)
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
        let rendered = BrushHostRenders.count
        // Straight to the hosting view: a test app is rarely the active one,
        // and an inactive window takes a first click as activation only.
        func send(_ type: NSEvent.EventType, x: Double) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 120), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            switch type {
            case .leftMouseDown: hosted.mouseDown(with: event)
            case .leftMouseDragged: hosted.mouseDragged(with: event)
            default: hosted.mouseUp(with: event)
            }
        }
        try send(.leftMouseDown, x: 110)
        for step in 1...20 {
            try send(.leftMouseDragged, x: 110 + Double(step) * 10)
            try await Task.sleep(for: .milliseconds(5)); hosted.layoutSubtreeIfNeeded()
        }
        try send(.leftMouseUp, x: 310)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
        XCTAssertEqual(commits.count, 1, "The drag committed one range")
        XCTAssertNotNil(commits.first ?? nil)
        print("PERF range drag of 20 pointer moves re-rendered the chart's owner \(BrushHostRenders.count - rendered) times")
        XCTAssertLessThanOrEqual(BrushHostRenders.count - rendered, 1, "The owner of the chart does not re-render per pointer move")
    }

    /// A short preset's retained averages slid out of view as the live clock
    /// moved on: the chart's time axis followed the clock, its data did not.
    @MainActor func testRetainedAverageChartKeepsItsOwnWindowWhenTheLiveClockMovesOn() async throws {
        let from = Date(timeIntervalSince1970: 1_800_000_000), until = from.addingTimeInterval(900)
        var measured = DashboardBucket(id: 0, start: from, end: from.addingTimeInterval(450), requests: 1)
        measured.gateway = GatewayTotals(requests: 1)
        measured.gateway.decodeMilliseconds = 3_000; measured.gateway.decodeOutputTokens = 300; measured.gateway.decodeSamples = 1
        let snapshot = DashboardSnapshot(filter: DashboardFilter(from: from, until: until, bucketCount: 2), scopeCounts: DashboardCounts(dispatched: 1, completed: 1),
                                         selectedRequests: 1, ttft: DashboardPercentiles(), streaming: DashboardPercentiles(), http: DashboardPercentiles(),
                                         buckets: [measured, DashboardBucket(id: 1, start: from.addingTimeInterval(450), end: until)], requests: [], offset: 0)
        var seconds = 1.0
        let live = LiveActivityStore(now: { seconds }, wall: { until.addingTimeInterval(seconds) }, observeSleep: false)
        defer { live.shutdown() }
        let panel = ReportThroughputPanel(live: live, snapshot: snapshot, window: DashboardWindow(from: from, until: until, preset: .fifteenMinutes),
                                          palette: MonitorModelPalette(), controls: { AnyView(EmptyView()) }, registerModels: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: panel)
        window.contentView = hosted; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // A full span after the retained window was read, with no refresh.
        live.setVisible(true, owner: "test"); seconds = 900; live.tick()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
        XCTAssertEqual(live.snapshot.observedAt, until.addingTimeInterval(900))
        let domain = try XCTUnwrap(surfaces(hosted).first).domain
        XCTAssertLessThanOrEqual(domain.lowerBound, from.addingTimeInterval(1), "The retained averages stay in view")
        XCTAssertGreaterThanOrEqual(domain.upperBound, until.addingTimeInterval(-1))
        live.setVisible(false, owner: "test")
    }

    /// The report used to stay "loading" after its figures appeared, while it
    /// refreshed every open chat's retained totals; a range dragged meanwhile
    /// was dropped. The chats' totals now refresh after the report, and only
    /// when its reads expired metrics.
    @MainActor func testReportIsReadyWhileChatTotalsRefreshAndKeepsARangeDraggedDuringARefresh() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 100_000, metricRetention: 600.5)
        try await record(model)
        let gate = ReportGate(), probe = ReportQueryProbe()
        var accountingRuns = 0
        let report = ReportController(query: { try await probe.run($0, $1, $2) }, accounting: { _ in accountingRuns += 1; await gate.pass() })
        report.attach(model)
        defer { report.suspend() }
        await report.prepare()
        XCTAssertEqual(accountingRuns, 0, "Nothing expired, so the chats' totals are already current")
        // The record's metrics expire; the next refresh's reads sweep them.
        try await Task.sleep(for: .milliseconds(600))
        await gate.arm()
        let refresh = Task { await report.refresh() }
        await gate.waitForBlock()
        XCTAssertEqual(accountingRuns, 1)
        XCTAssertNotNil(report.snapshot)
        XCTAssertFalse(report.loading, "The report is ready once its own figures are published")
        await gate.release(); await refresh.value
        // A range dragged while a refresh runs is applied when it finishes.
        await probe.blockNext()
        let running = Task { await report.refresh() }
        await probe.waitForBlock()
        let window = try XCTUnwrap(report.snapshot).filter
        let range = try XCTUnwrap(DashboardBrush(window.from.addingTimeInterval(60), window.until.addingTimeInterval(-60), in: window))
        report.applyBrush(range)
        XCTAssertEqual(report.brushPreview, range, "The dragged range stays on the chart")
        await probe.release(); await running.value
        for _ in 0..<200 where report.brush != range || report.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(report.brush, range, "The range dragged during the refresh is applied after it")
    }
}

@MainActor private enum BrushHostRenders { static var count = 0 }

/// Stands in for the report controller: the chart's owner observes it, as
/// the report page observes its controller. (Before the fix the drag preview
/// was one of its published values, bound into the overlay: 20 pointer moves
/// re-rendered the owner 21 times.)
@MainActor private final class BrushHostStore: ObservableObject {
    @Published var selection: DashboardBrush?
}

/// A chart with the report's drag-to-select overlay, owned by a view that
/// counts its own renders.
private struct BrushHost: View {
    let filter: DashboardFilter
    let commit: (DashboardBrush?) -> Void
    @ObservedObject var store: BrushHostStore
    var body: some View {
        let _ = { BrushHostRenders.count += 1 }()
        Chart { RuleMark(x: .value("Start", filter.from)) }
            .chartXScale(domain: filter.from...filter.until)
            .dashboardBrush(filter: filter, committed: store.selection, commit: commit)
            .frame(width: 400, height: 200).padding(20)
    }
}

/// Holds the next call that passes through it until released.
private actor ReportGate {
    private var armed = false, blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true; blocked = false }
    func pass() async {
        guard armed else { return }
        armed = false; blocked = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        await withCheckedContinuation { waiter = $0 }
    }
    func waitForBlock() async { if !blocked { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
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
        let (model, root) = try makeModel()
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
        XCTAssertEqual(model.displays[chat.id]?.messages.map(\.id), ["m-visible"],
                       "A missing retained message must not clear the visible conversation")

        // Opening a chat without a message just navigates.
        model.showMessageDetail = false; model.openReport()
        let opened = await model.revealMessage(sessionID: chat.id, messageID: nil)
        XCTAssertTrue(opened); XCTAssertEqual(model.page, .chats); XCTAssertFalse(model.showMessageDetail)
    }

    @MainActor func testNewChatRequiresAWorkspaceAndGroupingStateFollowsTheController() async throws {
        let (model, _) = try makeModel()
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

extension ReportPageTests {
    /// The report's "Requests and session details" section closed every time
    /// the reader came back from a chat: its state lived in the page, which
    /// is rebuilt on each return, while the sessions opened inside it stayed.
    @MainActor func testTheRequestSectionStaysOpenAcrossLeavingAndReturning() async throws {
        let (model, _) = try makeModel()
        try await model.reloadConfiguration()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.report.suspend() }
        func show() async {
            window.contentView = NSHostingView(rootView: ReportPage(model: model))
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<6 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(10)) }
        }
        model.openReport(); await show()
        model.report.requestListOpen = true; model.report.expandedSessions = ["chat-1"]
        // Going to a chat takes the page down; coming back builds a new one.
        model.page = .chats; window.contentView = nil
        model.openReport(); await show()
        XCTAssertTrue(model.report.requestListOpen, "The section is still open")
        XCTAssertEqual(model.report.expandedSessions, ["chat-1"])
    }
}
