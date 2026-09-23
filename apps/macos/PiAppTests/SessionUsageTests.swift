import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

/// Deliberately does not cooperate with cancellation until resumed. Archive
/// reads can finish after a user has already selected a different session.
@MainActor private final class SessionUsageReadProbe {
    struct Read {
        let scope: SessionUsageScope
        let until: Date
        let offset: Int
        let continuation: CheckedContinuation<MenuBarSnapshot, Error>
    }
    private(set) var reads: [Read] = []
    private(set) var completedCancellation: [Bool] = []
    private var pending: Set<Int> = []

    func load(_ scope: SessionUsageScope, _ until: Date, _ offset: Int) async throws -> MenuBarSnapshot {
        let value: MenuBarSnapshot = try await withCheckedThrowingContinuation { continuation in
            pending.insert(reads.count)
            reads.append(Read(scope: scope, until: until, offset: offset, continuation: continuation))
        }
        completedCancellation.append(Task.isCancelled)
        return value
    }

    func finish(_ index: Int, with value: MenuBarSnapshot) {
        guard pending.remove(index) != nil else { return }
        reads[index].continuation.resume(returning: value)
    }

    func cancelPending() {
        for index in pending { reads[index].continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}

class SessionUsageTestCase: XCTestCase {
    fileprivate let until = Date(timeIntervalSince1970: 1_000_000)
    fileprivate let scope = SessionUsageScope(sessionID: "session-a", workspaceID: "project-a")

    @MainActor fileprivate func waitFor(_ message: String, seconds: Double = 0.5, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 200) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
        throw NSError(domain: "SessionUsageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    fileprivate func snapshot(requests: Int = 0, offset: Int = 0, models: [MenuBarModelDistribution] = [], groups: Int = 0, gateway: GatewayTotals? = nil) -> MenuBarSnapshot {
        let totals = gateway ?? GatewayTotals(requests: requests)
        return MenuBarSnapshot(period: .retained, from: until.addingTimeInterval(-3_600), until: until,
                        counts: DashboardCounts(dispatched: requests, completed: requests), gateway: gateway ?? GatewayTotals(requests: requests),
                        workspaces: requests > 0 ? 1 : 0, sessions: requests > 0 ? 1 : 0, compactionRequests: 0,
                        costUnreported: totals.requests - totals.costSamples, costInvalid: 0, costConflicts: 0, models: models, modelGroups: groups, offset: offset)
    }

    fileprivate func pagedSnapshot(offset: Int) -> MenuBarSnapshot {
        let models = (offset..<min(offset + MenuBarSnapshot.pageSize, 25)).map { index in
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "provider/model-\(index)", identityStatus: "reported", gateway: GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.4), allRequests: 25, costShare: 0.04)
        }
        return snapshot(requests: 25, offset: offset, models: models, groups: 25, gateway: GatewayTotals(requests: 25, costSamples: 25, costUSD: 10))
    }
}

final class SessionUsageTests: SessionUsageTestCase {
    @MainActor func testHiddenSessionUsageCancelsReadsAndPollingAndRefreshesWhenReopened() async throws {
        let probe = SessionUsageReadProbe(), date = until
        let controller = SessionUsageController(scope: scope, load: probe.load, interval: .milliseconds(25), now: { date })
        defer { controller.setVisible(false); probe.cancelPending() }
        controller.refresh()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(probe.reads.isEmpty, "Opening a conversation alone must not start usage polling")

        controller.setVisible(true)
        try await waitFor("Visible usage did not start its first query") { probe.reads.count == 1 }
        XCTAssertTrue(controller.loading)
        XCTAssertEqual(probe.reads.first?.scope, scope)
        XCTAssertEqual(probe.reads.first?.until, until)
        controller.setVisible(false)
        probe.finish(0, with: snapshot(requests: 10))
        try await waitFor("The old read did not return after hiding") { probe.completedCancellation.count == 1 }
        XCTAssertEqual(probe.completedCancellation, [true])
        XCTAssertNil(controller.snapshot, "A late read must not populate a hidden panel")
        XCTAssertFalse(controller.loading)
        controller.refresh()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.reads.count, 1, "A hidden usage panel must not poll or react to refresh keys")

        controller.setVisible(true)
        try await waitFor("Reopening did not request fresh retained usage") { probe.reads.count == 2 }
        probe.finish(1, with: snapshot(requests: 12))
        try await waitFor("Fresh usage was not published") { controller.snapshot?.gateway.requests == 12 }
        controller.setVisible(false)
        let count = probe.reads.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.reads.count, count)
    }

    @MainActor func testProjectAndSessionScopeChangeClearsPreviousResultsAndRejectsLateRead() async throws {
        let probe = SessionUsageReadProbe()
        let controller = SessionUsageController(scope: scope, load: probe.load, interval: .seconds(60))
        defer { controller.setVisible(false); probe.cancelPending() }
        controller.setVisible(true)
        try await waitFor("Initial usage read did not start") { probe.reads.count == 1 }
        probe.finish(0, with: snapshot(requests: 100))
        try await waitFor("Initial usage was not published") { controller.snapshot != nil }
        controller.refresh()
        try await waitFor("Refresh did not start") { probe.reads.count == 2 }

        // Identical session IDs in separate projects must remain distinct.
        let otherProject = SessionUsageScope(sessionID: scope.sessionID, workspaceID: "project-b")
        controller.setScope(otherProject)
        XCTAssertEqual(controller.scope, otherProject)
        XCTAssertNil(controller.snapshot, "Never flash the previous project's bill in the new session")
        XCTAssertEqual(controller.offset, 0)
        try await waitFor("New project scope did not start") { probe.reads.count == 3 }
        XCTAssertEqual(probe.reads[2].scope, otherProject)
        probe.finish(2, with: snapshot(requests: 2))
        try await waitFor("New project result was not published") { controller.snapshot?.gateway.requests == 2 }
        probe.finish(1, with: snapshot(requests: 999))
        try await waitFor("The cancelled refresh did not finish") { probe.completedCancellation.count == 3 }
        XCTAssertEqual(controller.snapshot?.gateway.requests, 2)
        XCTAssertEqual(probe.completedCancellation.last, true)

        let anotherSession = SessionUsageScope(sessionID: "session-b", workspaceID: otherProject.workspaceID)
        controller.setVisible(false)
        controller.setScope(anotherSession)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.scope, anotherSession)
        XCTAssertEqual(controller.offset, 0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.reads.count, 3, "Changing a hidden scope must not start archive work")
    }

    @MainActor func testPagingUsesBoundedOffsetsAndPreservesWholeSessionShares() async throws {
        var offsets: [Int] = []
        let controller = SessionUsageController(scope: scope, load: { _, _, offset in
            offsets.append(offset)
            return self.pagedSnapshot(offset: offset)
        }, interval: .seconds(60))
        defer { controller.setVisible(false) }
        controller.previousPage(); controller.nextPage()
        XCTAssertEqual(controller.offset, 0)
        controller.setVisible(true)
        try await waitFor("First model page did not load") { controller.snapshot != nil }
        XCTAssertEqual(controller.snapshot?.models.count, MenuBarSnapshot.pageSize)
        XCTAssertEqual(controller.snapshot?.hasNext, true)

        controller.nextPage()
        try await waitFor("Second model page did not load") { controller.snapshot?.offset == MenuBarSnapshot.pageSize }
        let last = try XCTUnwrap(controller.snapshot), row = try XCTUnwrap(last.models.first)
        XCTAssertEqual(last.models.count, 1)
        XCTAssertFalse(last.hasNext)
        XCTAssertEqual(last.gateway.requests, 25)
        XCTAssertEqual(last.gateway.costUSD, 10)
        XCTAssertEqual(row.requestShare, 0.04, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(row.costShare), 0.04, accuracy: 1e-12)
        controller.nextPage()
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(offsets, [0, MenuBarSnapshot.pageSize], "Next at the last page must not read an unbounded empty page")

        controller.previousPage()
        try await waitFor("Previous model page did not load") { controller.snapshot?.offset == 0 }
        controller.previousPage()
        XCTAssertEqual(offsets, [0, MenuBarSnapshot.pageSize, 0])
        XCTAssertEqual(controller.offset, 0)
        controller.nextPage()
        try await waitFor("Second model page did not load again") { controller.snapshot?.offset == MenuBarSnapshot.pageSize }
        controller.setVisible(false)
        controller.setScope(SessionUsageScope(sessionID: "different-session", workspaceID: scope.workspaceID))
        XCTAssertEqual(controller.offset, 0)
        XCTAssertNil(controller.snapshot)
    }

    /// Every 10 s poll embedded a fresh `until`, bucket bounds and read
    /// stamps, so identical figures never compared equal and the whole
    /// Session info window re-rendered on each poll.
    @MainActor func testPollingRepublishesOnlyWhenTheSessionsFiguresChange() async throws {
        var polls = 0, clock = until
        let controller = SessionUsageController(scope: scope, load: { _, now, offset in
            polls += 1
            let from = self.until.addingTimeInterval(-3_600)
            return MenuBarSnapshot(period: .retained, from: from, until: now, counts: DashboardCounts(dispatched: 3, completed: 3), gateway: GatewayTotals(requests: 3),
                                   workspaces: 1, sessions: 1, compactionRequests: 0, costUnreported: 3, costInvalid: 0, costConflicts: 0, models: [], modelGroups: 0, offset: offset,
                                   buckets: [MenuBarBucket(id: 0, start: from, end: now)], summaryReadAt: now, modelPageReadAt: now)
        }, interval: .milliseconds(10), now: { clock = clock.addingTimeInterval(10); return clock })
        var publications = 0
        let observer = controller.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observer.cancel(); controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("The window did not keep polling") { polls >= 5 }
        XCTAssertEqual(publications, 1, "The same figures are published once, however often they are read")
    }

    /// Paging the Models table set the snapshot to nil until the page
    /// landed: the whole window blanked to "Reading session info…".
    @MainActor func testPagingTheModelsTableKeepsTheWindowOnScreen() async throws {
        var pending: CheckedContinuation<Void, Never>?
        let controller = SessionUsageController(scope: scope, load: { _, _, offset in
            if offset > 0 { await withCheckedContinuation { pending = $0 } }
            return self.pagedSnapshot(offset: offset)
        }, interval: .seconds(60))
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("First model page did not load") { controller.snapshot != nil }
        var blanks = 0
        let observer = controller.$snapshot.dropFirst().sink { if $0 == nil { blanks += 1 } }
        defer { observer.cancel() }
        controller.nextPage()
        try await waitFor("The next page was not requested") { pending != nil }
        XCTAssertNotNil(controller.snapshot, "The current page stays while the next one is read")
        XCTAssertTrue(controller.loading)
        pending?.resume()
        try await waitFor("Second model page did not load") { controller.snapshot?.offset == MenuBarSnapshot.pageSize }
        XCTAssertEqual(blanks, 0)
    }

    /// The caption under the per-request charts quoted output over the whole
    /// request time, while the chart above it plots the settled decode rate.
    func testRequestCaptionQuotesTheRateTheChartPlots() {
        let sample = SessionTimingSample(id: "r", wall: until, ttftMilliseconds: 2_000, streamingMilliseconds: 3_000, outputTokens: 300, costUSD: 0.01, requestMilliseconds: 5_000)
        let caption = SessionUsagePresentation.requestCaption(index: 1, sample: sample)
        let plotted = SessionTimingMetric.rate.label(SessionTimingMetric.rate.value(in: sample))
        XCTAssertEqual(plotted, "100 tok/s")
        XCTAssertTrue(caption.contains(plotted), caption)
        XCTAssertFalse(caption.contains("60 tok/s"), caption)
    }

    @MainActor func testRetentionShrinkingCurrentPageReturnsToFirstPage() async throws {
        var offsets: [Int] = []
        let controller = SessionUsageController(scope: scope, load: { _, _, offset in
            offsets.append(offset)
            if offset == 0 { return self.pagedSnapshot(offset: 0) }
            return self.snapshot(requests: 1, offset: offset)
        }, interval: .seconds(60))
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("First model page did not load") { controller.snapshot?.hasNext == true }
        controller.nextPage()
        try await waitFor("An expired last page did not return to the first page") { offsets.count == 3 && controller.snapshot?.offset == 0 }
        XCTAssertEqual(offsets, [0, MenuBarSnapshot.pageSize, 0])
        XCTAssertEqual(controller.offset, 0)
    }

    @MainActor func testFailedReadShowsNoticeAndExplicitRetryRecoversWithoutChangingScope() async throws {
        enum Failure: LocalizedError { case unavailable; var errorDescription: String? { "Synthetic usage read failed" } }
        var reads = 0
        let controller = SessionUsageController(scope: scope, load: { _, _, _ in
            reads += 1
            if reads == 1 { throw Failure.unavailable }
            return self.snapshot(requests: 3)
        }, interval: .seconds(60))
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("Query failure did not reach the usage panel") { !controller.notice.isEmpty }
        XCTAssertFalse(controller.loading)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.notice, "Synthetic usage read failed")
        controller.refresh()
        try await waitFor("Retry did not publish usage") { controller.snapshot != nil }
        XCTAssertEqual(controller.scope, scope)
        XCTAssertEqual(controller.snapshot?.gateway.requests, 3)
        XCTAssertTrue(controller.notice.isEmpty)
        XCTAssertFalse(controller.loading)
        XCTAssertEqual(reads, 2)
    }

    func testSessionInfoTimingSummarizesLatencyRateAndWorkClocks() {
        let base = Date(timeIntervalSince1970: 1_000)
        var history = SessionTimingHistory()
        history.samples = [
            SessionTimingSample(id: "1", wall: base, ttftMilliseconds: 400, streamingMilliseconds: 1_600, outputTokens: 200, requestMilliseconds: 2_000),
            SessionTimingSample(id: "2", wall: base.addingTimeInterval(1), ttftMilliseconds: nil, streamingMilliseconds: nil, outputTokens: 90, requestMilliseconds: 900),
            SessionTimingSample(id: "3", wall: base.addingTimeInterval(2), ttftMilliseconds: 250, streamingMilliseconds: 750, outputTokens: 500, requestMilliseconds: 1_000),
        ]
        let work: [String: WireValue] = ["sessionModelMs": .number(72_000), "sessionToolMs": .number(14_300), "modelMs": .number(4_200), "toolMs": .number(300)]
        let timing = SessionInfoTiming(history: history, work: work)
        XCTAssertEqual(timing.latestTTFT, 250); XCTAssertEqual(timing.medianTTFT, 325, "The median skips the request without a measurement"); XCTAssertEqual(timing.ttftSamples, 2)
        // The rates are settled: the 499 tokens after the first over a 750 ms
        // decode span, and 199 + 499 tokens over the 2.35 s the two measurable
        // requests decoded for. The request that reported no decode span is
        // left out of both.
        XCTAssertEqual(timing.latestDurationMs, 1_000)
        XCTAssertEqual(timing.latestRate.map { ($0 * 100).rounded() / 100 }, 665.33)
        XCTAssertEqual(timing.averageRate.map { ($0 * 10).rounded() / 10 }, 297.0)
        XCTAssertEqual(timing.sessionModelMs, 72_000); XCTAssertEqual(timing.sessionToolMs, 14_300); XCTAssertEqual(timing.turnModelMs, 4_200); XCTAssertEqual(timing.turnToolMs, 300)
        XCTAssertEqual(timing.firstTokenCaption, "median 325 ms · 2 measured · last request 1.0s")
        XCTAssertEqual(timing.modelCaption, "last turn 4.2s"); XCTAssertEqual(timing.toolCaption, "last turn 0.3s")
        XCTAssertEqual(SessionUsagePresentation.milliseconds(250), "250 ms"); XCTAssertEqual(SessionUsagePresentation.milliseconds(1_250), "1.25 s"); XCTAssertEqual(SessionUsagePresentation.milliseconds(nil), "n/a")

        let empty = SessionInfoTiming(history: SessionTimingHistory(), work: [:])
        XCTAssertNil(empty.latestTTFT); XCTAssertNil(empty.medianTTFT); XCTAssertNil(empty.latestRate); XCTAssertNil(empty.sessionModelMs); XCTAssertNil(empty.turnModelMs)
        XCTAssertEqual(empty.firstTokenCaption, "median n/a · 0 measured"); XCTAssertEqual(empty.modelCaption, "waiting on the model, whole session")
        XCTAssertEqual(SessionInfoTiming.median([3, 1, 2]), 2); XCTAssertEqual(SessionInfoTiming.median([4, 1, 2, 3]), 2.5); XCTAssertNil(SessionInfoTiming.median([]))
    }

    func testTokenBarStacksCachedUncachedAndOutput() {
        var totals = GatewayTotals(requests: 3)
        totals.tokens = GatewayTokenTotals(input: 1_000, output: 200, total: 1_200, inputSamples: 3, outputSamples: 3, samples: 3, reasoning: 50, reasoningSamples: 3)
        totals.cacheReadTokens = 300; totals.cacheReadSamples = 3
        totals.uncachedInputReportedTokens = 700; totals.uncachedInputSamples = 3
        let bar = SessionTokenBar(totals)
        XCTAssertEqual(bar.segments.map(\.id), ["cached", "uncached", "output"]); XCTAssertEqual(bar.segments.map(\.tokens), [300, 700, 200])
        XCTAssertEqual(bar.total, 1_200); XCTAssertEqual(bar.reasoning, 50)
        XCTAssertEqual(bar.fraction(bar.segments[1]), 700 / 1_200, accuracy: 1e-9)
        XCTAssertEqual(bar.coverage, "cached input, uncached input and output, stacked", "Complete coverage says nothing about counts")
        var sparse = totals; sparse.cacheReadSamples = 2
        XCTAssertEqual(SessionTokenBar(sparse).coverage, "cache 2/3 requests reported")

        // Without paired uncached observations the difference is used only when input and cache are fully reported.
        var derived = GatewayTotals(requests: 2)
        derived.tokens = GatewayTokenTotals(input: 500, output: 80, total: 580, inputSamples: 2, outputSamples: 2, samples: 2)
        derived.cacheReadTokens = 100; derived.cacheReadSamples = 2
        XCTAssertEqual(SessionTokenBar(derived).segments.map(\.tokens), [100, 400, 80])
        var partial = derived; partial.cacheReadSamples = 1
        XCTAssertEqual(SessionTokenBar(partial).segments.map(\.id), ["cached", "output"], "A partially reported cache cannot yield an uncached figure")
        var noCache = GatewayTotals(requests: 1)
        noCache.tokens = GatewayTokenTotals(input: 40, output: 10, total: 50, inputSamples: 1, outputSamples: 1, samples: 1)
        XCTAssertEqual(SessionTokenBar(noCache).segments.map(\.id), ["input", "output"], "Input alone is one segment when the cache was never reported")
        XCTAssertTrue(SessionTokenBar(GatewayTotals(requests: 0)).segments.isEmpty); XCTAssertNil(SessionTokenBar(GatewayTotals(requests: 0)).reasoning)
    }

    func testResponseCacheRateKeepsUnknownAndPromptCacheDistinctFromHits() throws {
        var totals = GatewayTotals(requests: 13, cacheHits: 7, cacheMisses: 3, cacheUnreported: 2, cacheConflicts: 1,
                                   cacheReadTokens: 12_345, cacheWriteTokens: 456, cacheReadSamples: 13, cacheWriteSamples: 13)
        XCTAssertEqual(SessionUsageResponseCache(totals).known, 10)
        XCTAssertEqual(try XCTUnwrap(SessionUsageResponseCache(totals).rate), 0.7, accuracy: 1e-12)
        totals.cacheHits = 0; totals.cacheMisses = 0; totals.cacheUnreported = 12
        XCTAssertNil(SessionUsageResponseCache(totals).rate, "Prompt cache reads and unknown response-cache metadata cannot imply a hit rate")
        XCTAssertEqual(SessionUsageResponseCache(totals).rateLabel, "Unavailable")
        totals.cacheMisses = 3
        XCTAssertEqual(SessionUsageResponseCache(totals).rate, 0, "Reported all-miss traffic is a known zero rate")
        XCTAssertEqual(SessionUsagePresentation.rate(nil), "Unavailable")
        XCTAssertEqual(SessionUsagePresentation.rate(.infinity), "Unavailable")
        XCTAssertEqual(SessionUsagePresentation.rate(0), 0.0.formatted(.number.precision(.fractionLength(1))))
    }

    /// A project window to own Inspectors, with an archive the Inspector can read.
    @MainActor fileprivate func inspectorOwner(_ chats: [ChatRecord]) async throws -> (WorkspaceModel, () async -> Void) {
        let base = testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-inspector-window-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.traces.configure(quota: 1 << 20, bodyRetention: 100, metricRetention: 1_000_000)
        model.chats = chats
        return (model, {
            model.shutdown(); await model.store?.close(); try? await model.traces.close()
            try? FileManager.default.removeItem(at: root)
        })
    }

    /// Ported from Session info: a chat's Session Inspector is its own window
    /// in the app's chrome, reused for the same chat, kept apart for the same
    /// session id in another project or another project window, and closing
    /// a project window closes only its own.
    @MainActor func testTheInspectorWindowIsReusedPerChatAndKeptApartForOthers() async throws {
        SessionInspectorWindows.shared.closeAll()
        var chat = ChatRecord(id: scope.sessionID, workspaceID: scope.workspaceID, title: "First session", path: nil, profileID: "fixture-profile")
        let (model, finish) = try await inspectorOwner([chat])
        let (otherOwner, finishOther) = try await inspectorOwner([chat])
        defer { SessionInspectorWindows.shared.closeAll() }
        model.openInspector(session: chat.id)
        let first = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        let window = try XCTUnwrap(first.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(window.sheetParent, "The Inspector is an independent window")
        XCTAssertEqual(window.identifier?.rawValue, SessionInspectorWindowController.identifier)
        for style in [NSWindow.StyleMask.titled, .closable, .miniaturizable, .resizable] { XCTAssertTrue(window.styleMask.contains(style)) }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { XCTAssertNotNil(window.standardWindowButton(kind)) }
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 700)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 520)
        // The app's own chrome replaces the system title bar, and the title still names the window.
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden); XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.title, "First session — Session Inspector")
        window.setContentSize(NSSize(width: 1_020, height: 780))
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 1_020, accuracy: 0.5)

        chat.title = "Renamed session"; model.chats = [chat]
        model.openInspector(session: chat.id, focus: .nextRequest)
        let again = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        XCTAssertTrue(first === again, "Every entry point focuses the same chat's window")
        XCTAssertEqual(again.inspector.page, .nextRequest, "at the page it asked for")
        XCTAssertEqual(window.title, "Renamed session — Session Inspector")
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 1_020, accuracy: 0.5, "Reopening keeps the reader's window size")
        XCTAssertEqual(SessionInspectorWindows.shared.count, 1)

        // The same session id in another project (a usage report row), and in another project window.
        model.openInspector(session: chat.id, workspaceID: "other-project", title: "Other project", focus: .overview)
        otherOwner.openInspector(session: chat.id)
        XCTAssertEqual(SessionInspectorWindows.shared.count, 3)
        XCTAssertEqual(first.inspector.scope, scope)
        XCTAssertTrue(window.isVisible, "Opening another session's Inspector leaves this one as it was")
        let others = SessionInspectorWindows.shared.controllers.filter { $0 !== first }
        SessionInspectorWindows.shared.closeAll(owner: model)
        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(others.filter(\.isClosed).count, 1, "Only the closed project's own Inspectors close")
        XCTAssertEqual(SessionInspectorWindows.shared.count, 1)
        await finish(); await finishOther()
        XCTAssertEqual(SessionInspectorWindows.shared.count, 0, "Shutting a project window down closes its Inspectors")
    }

    /// Ported from Session info: a closed Inspector reads nothing more, and
    /// opening it again makes a new window that reads afresh.
    @MainActor func testClosingTheInspectorStopsItsReads() async throws {
        SessionInspectorWindows.shared.closeAll()
        let chat = ChatRecord(id: scope.sessionID, workspaceID: scope.workspaceID, title: "Pending", path: nil, profileID: "fixture-profile")
        let (model, finish) = try await inspectorOwner([chat])
        defer { SessionInspectorWindows.shared.closeAll() }
        model.openInspector(session: chat.id)
        let first = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        first.inspector.pollInterval = .milliseconds(20)
        try await waitFor("The Inspector did not read its session", seconds: 5) { first.inspector.indexReads >= 1 }
        first.window?.performClose(nil)
        XCTAssertTrue(first.isClosed)
        XCTAssertNil(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        XCTAssertFalse(first.inspector.visible)
        let reads = first.inspector.indexReads
        first.inspector.refresh()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(first.inspector.indexReads, reads, "A closed Inspector neither polls nor reads")

        model.openInspector(session: chat.id)
        let reopened = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        XCTAssertFalse(reopened === first)
        try await waitFor("The reopened Inspector did not read its session", seconds: 5) { reopened.inspector.indexReads >= 1 }
        await finish()
    }

    /// Ported from Session info: the window follows its own chat, not the
    /// selected one: a rename retitles it, and its footer's figures moving
    /// read the log again while another chat's footer moving does not.
    @MainActor func testAnOpenInspectorFollowsItsChatAfterTheSelectionChanges() async throws {
        SessionInspectorWindows.shared.closeAll()
        var first = ChatRecord(id: scope.sessionID, workspaceID: scope.workspaceID, title: "Original title", path: nil, profileID: "fixture-profile")
        let other = ChatRecord(id: "other-chat", workspaceID: scope.workspaceID, title: "Other chat", path: nil, profileID: "fixture-profile")
        let (model, finish) = try await inspectorOwner([first, other])
        defer { SessionInspectorWindows.shared.closeAll() }
        let display = SessionDisplay(id: first.id), otherDisplay = SessionDisplay(id: other.id)
        model.displays = [first.id: display, other.id: otherDisplay]; model.selectedID = first.id
        model.openInspector(session: first.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: first.id))
        try await waitFor("The Inspector did not read its session", seconds: 5) { controller.inspector.indexReads == 1 }
        model.selectedID = other.id
        first.title = "New session title"; model.chats = [first, other]
        XCTAssertEqual(controller.window?.title, "New session title — Session Inspector")
        XCTAssertEqual(controller.inspector.title, first.title)
        display.footer.gateway = GatewayTotals(requests: 5)
        try await waitFor("Its chat's footer moving did not read the log again", seconds: 5) { controller.inspector.indexReads == 2 }
        otherDisplay.footer.gateway = GatewayTotals(requests: 20)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.inspector.indexReads, 2, "Another chat's footer reads nothing")
        controller.close()
        display.footer.gateway = GatewayTotals(requests: 6)
        first.title = "Changed after closing"; model.chats = [first, other]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.inspector.indexReads, 2, "A closed window lets go of the chat's figures")
        XCTAssertEqual(controller.inspector.title, "New session title")
        await finish()
    }
}

/// The Inspector reopens where it was left: the frame is saved in the standard
/// user defaults, which every test host shares, so this runs in the serial
/// lane (`scripts/test-lanes.py`).
final class SessionUsageWindowFrameTests: SessionUsageTestCase, SerialTestLane {
    /// Ported from Session info, which always opened centred: a size and
    /// place the reader chose were gone the next time, and after a relaunch.
    @MainActor func testTheInspectorOpensWhereItWasLastLeft() throws {
        let name = "SessionInspectorTests-" + UUID().uuidString, previous = SessionInspectorWindowController.frameAutosaveName
        SessionInspectorWindowController.frameAutosaveName = name
        defer { SessionInspectorWindowController.frameAutosaveName = previous; UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + name) }
        let root = scratchRoot("inspector-frame"); defer { try? FileManager.default.removeItem(at: root) }
        func inspector() -> SessionInspectorModel {
            SessionInspectorModel(scope: SessionUsageScope(sessionID: "session-frame", workspaceID: "project-frame"), title: "Frame",
                                  archive: PayloadArchive(root: root), workspace: nil,
                                  usageLoader: { _, _, _ in throw CancellationError() }, cache: InspectorDocumentCache())
        }
        let first = SessionInspectorWindowController(inspector: inspector())
        let window = try XCTUnwrap(first.window)
        let chosen = NSRect(x: 180, y: 160, width: 820, height: 640)
        window.setFrame(chosen, display: false)
        first.close()
        let second = SessionInspectorWindowController(inspector: inspector())
        defer { second.close() }
        XCTAssertEqual(try XCTUnwrap(second.window).frame, chosen, "The next one opens at the size and place the last was left")
    }
}
