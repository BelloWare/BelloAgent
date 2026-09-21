import XCTest
import Combine
import AppKit
import SwiftUI
@testable import PiApp

final class MenuBarPresentationTests: XCTestCase {
    @MainActor func testTextAndDraftDoNotProjectActivityAndFooterUpdatesOneID() throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.chats = (0..<10_000).map { ChatRecord(id: "chat\($0)", workspaceID: "p", title: "Chat \($0)", path: nil, profileID: "g") }
        for index in 0..<20 {
            let view = SessionDisplay(id: "chat\(index)"); view.state = "running"
            model.displays[view.id] = view
        }
        _ = model.menuBarActivity()
        let projections = model.activityProjectionCount, invalidations = model.sidebarIndex.computations
        let view = try XCTUnwrap(model.displays["chat0"])
        for index in 0..<100 {
            view.draft = "typing \(index)"; view.notice = "transcript update \(index)"
            _ = model.menuBarActivity()
        }
        XCTAssertEqual(model.activityProjectionCount, projections)
        view.footer.gateway = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.12)
        let snapshot = model.menuBarActivity()
        XCTAssertEqual(model.activityProjectionCount, projections + 1)
        XCTAssertEqual(snapshot.rows.first { $0.id == "chat0" }?.costUSD, 0.12)
        XCTAssertEqual(model.sidebarIndex.computations, invalidations)
    }

    @MainActor func testRunningPresentationExcludesQuietChatsWithoutChangingUnreadOrQueuedWork() throws {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("menu-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let workspace = WorkspaceRecord(id: "workspace", path: root.path, trusted: true)
        model.workspaces = [workspace]
        for id in ["generating", "tool", "compacting", "queued", "paused", "unopened"] {
            model.chats.append(ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: "profile"))
        }
        for (id, phase) in [("generating", "model"), ("tool", "tool"), ("compacting", "compacting")] {
            let display = SessionDisplay(id: id)
            display.state = "running"; display.activityObservedAt = 100
            display.activity = ["version": .number(1), "phase": .string(phase), "modelActive": .bool(phase != "tool"), "estimatedOutputTokensPerSecond": .number(phase == "model" ? 12 : 8), "pendingFollowUps": .number(id == "generating" ? 1 : 0)]
            model.displays[id] = display
        }
        let queued = SessionDisplay(id: "queued"); queued.state = "queued"; queued.queueCount = 3
        let paused = SessionDisplay(id: "paused"); paused.state = "paused"
        model.displays[queued.id] = queued; model.displays[paused.id] = paused
        model.unreadStates["unopened"] = SessionReadState(id: "unopened", observedAssistantCount: 2, latestAssistantID: "answer", unreadOutputs: 1, unreadTargetID: "answer")

        let snapshot = model.menuBarActivity(now: 101)
        XCTAssertEqual(Set(snapshot.runningRows.map(\.id)), Set(["generating", "tool", "compacting"]))
        XCTAssertEqual(snapshot.running, 3)
        XCTAssertEqual(snapshot.runningPending, 1, "The running summary must not count follow-ups belonging to waiting chats")
        XCTAssertEqual(snapshot.attentionRows.map(\.id), ["queued", "paused"]); XCTAssertEqual(snapshot.unreadRows.map(\.id), ["unopened"])
        XCTAssertEqual(queued.queueCount, 3)
        XCTAssertEqual(model.unreadOutputCount(sessionID: "unopened"), 1)
        XCTAssertNil(model.displays["unopened"], "Filtering the menu must not load or mark an unopened chat as read")
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testMenuActiveCountOnlyIncludesRunningSessionsOnRefresh() {
        func row(_ id: String, phase: String) -> MenuBarActivityRow {
            MenuBarActivityRow(id: id, title: id, workspace: "Project", phase: phase, model: "auto-router", resolvedModel: nil, tools: [], followUps: phase == "queued" ? 2 : 0, steering: 0, unread: phase == "idle" ? 1 : 0)
        }
        var current = MenuBarActivitySnapshot(rows: [row("live", phase: "model"), row("queued", phase: "queued"), row("paused", phase: "paused"), row("unread", phase: "idle")], unreadChats: 1)
        let controller = MenuBarMetricsController(load: { _, _, _ in throw CaptureFailure.unavailable }, activity: { current })
        controller.setVisible(true)
        defer { controller.setVisible(false) }
        XCTAssertEqual(controller.activeSessions, 1)
        XCTAssertEqual(controller.activity.runningRows.map(\.id), ["live"])

        current.rows.removeAll { $0.id == "live" }
        controller.refresh()
        XCTAssertEqual(controller.activeSessions, 0, "Queued and paused sessions are not active work")
        XCTAssertTrue(controller.activity.runningRows.isEmpty)
        XCTAssertEqual(current.rows.count, 3, "Menu filtering must leave source session state intact")
    }

    @MainActor func testContinuousChangesPublishWhileStreamingAndStopWhenHidden() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let activityState = MenuActivityTestState()
        let controller = MenuBarMetricsController(load: { _, _, _ in throw CaptureFailure.unavailable }, activity: {
            MenuBarActivitySnapshot(rows: [MenuBarActivityRow(id: "live", title: "Live", workspace: "Project", phase: "model", model: "router", resolvedModel: nil, tools: [], followUps: activityState.pending, steering: 0, unread: 0)])
        }, activityChanges: { changes.eraseToAnyPublisher() })
        controller.setVisible(true)
        defer { controller.setVisible(false) }
        for index in 1...20 {
            activityState.pending = index; changes.send()
            try await Task.sleep(for: .milliseconds(40))
            if index == 16 {
                XCTAssertGreaterThan(controller.activity.runningPending, 0, "A continuous stream must not starve the live panel until it stops")
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.activity.runningPending, 20)
        XCTAssertLessThanOrEqual(controller.activityCounts, 6, "Events are coalesced rather than redrawing on each streamed delta")
        activityState.pending = 99; changes.send(); controller.setVisible(false)
        let count = controller.activityCounts
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controller.activityCounts, count, "Closing cancels a pending refresh")
    }

    @MainActor func testLiveRowsUseReportedAccountingAndElapsedTimeWithoutByteBasedSpeed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "p", path: root.path, trusted: true)]
        model.chats = [ChatRecord(id: "live", workspaceID: "p", title: "Live", path: nil, profileID: "profile")]
        let view = SessionDisplay(id: "live"); view.state = "running"; view.runStatus = "running"
        view.activity = ["phase": .string("model"), "model": .string("auto-router"), "modelActive": .bool(true), "estimatedOutputTokensPerSecond": .number(9999)]
        view.turnTiming = ["startedAt": .number(10_000), "elapsedMs": .number(1_000)]
        view.footer.timing = SessionTimingHistory(samples: [SessionTimingSample(id: "done", wall: Date(), ttftMilliseconds: 100, streamingMilliseconds: 200, outputTokens: 300, requestMilliseconds: 2_000)])
        model.displays[view.id] = view
        model.publishChatStats(GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.0123), sessionID: view.id)
        let live = model.menuBarActivity()
        XCTAssertEqual(live.generating, 1)
        let row = try XCTUnwrap(live.runningRows.first)
        XCTAssertEqual(row.elapsed(at: Date(timeIntervalSince1970: 15)), 5_000)
        XCTAssertEqual(row.latestRate, 150, "Use reported output including hidden reasoning, not visible bytes")
        XCTAssertEqual(row.costUSD, 0.0123)
        view.runStatus = "retrying"
        view.observeRetry(["retry": .object(["attempt": .number(4), "of": .number(6), "reason": .string("Temporary failure")])])
        let retrying = model.menuBarActivity()
        XCTAssertEqual(retrying.generating, 0)
        XCTAssertEqual(retrying.runningRows.first?.phaseLabel, "Retrying · attempt 4 of 6")
        model.chats[0].archivedAt = Date()
        XCTAssertTrue(model.menuBarActivity().runningRows.isEmpty)
    }

    /// Optional visual evidence uses only this synthetic window, never the
    /// desktop or a user's project, archive, credentials, or gateway.
    @MainActor func testCaptureDefaultUsagePanelWhenRequested() async throws {
        guard let path = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") else {
            throw XCTSkip("Set PI_APP_USAGE_CAPTURE_ROOT for the optional menu preview")
        }
        func totals(requests: Int, input: Double, output: Double, cost: Double) -> GatewayTotals {
            var result = GatewayTotals(requests: requests, costSamples: requests, costUSD: cost)
            result.tokens = GatewayTokenTotals(input: input, output: output, total: input + output, inputSamples: requests, outputSamples: requests, samples: requests)
            return result
        }
        let models = [
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "openai/gpt-5.4-mini", identityStatus: "reported", gateway: totals(requests: 6, input: 15_000, output: 1_200, cost: 0.0096), allRequests: 10, historicalRate: HistoricalOutputRate(outputTokens: 1_200, generationMilliseconds: 25_000, samples: 6), costShare: 0.384),
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0-extended-thinking-router", resolvedModel: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0", identityStatus: "reported", gateway: totals(requests: 3, input: 9_000, output: 900, cost: 0.0210), allRequests: 10, historicalRate: HistoricalOutputRate(outputTokens: 900, generationMilliseconds: 12_000, samples: 3)),
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "openai/gpt-5.4", identityStatus: "reported", gateway: totals(requests: 4, input: 5_000, output: 800, cost: 0.0154), allRequests: 10, historicalRate: HistoricalOutputRate(outputTokens: 800, generationMilliseconds: 25_000, samples: 4), costShare: 0.616)
        ]
        let until = Date(timeIntervalSince1970: 1_000_000)
        let from = MenuPeriodStart(until)
        let buckets = (0..<24).map { index -> MenuBarBucket in
            var bucket = MenuBarBucket(id: index, start: from.addingTimeInterval(Double(index) * 3600), end: from.addingTimeInterval(Double(index + 1) * 3600))
            let requests = [0, 0, 1, 2, 0, 3, 1, 0, 0, 2, 4, 1, 0, 0, 1, 3, 2, 0, 1, 0, 0, 2, 1, 0][index]
            if requests > 0 {
                bucket.gateway = totals(requests: requests, input: Double(requests) * 1_500, output: Double(requests) * 200, cost: Double(requests) * 0.0025)
                bucket.historicalRate = HistoricalOutputRate(outputTokens: Double(requests) * 200, generationMilliseconds: Double(requests) * 5_000 + Double(index % 5) * 800, samples: requests)
            }
            return bucket
        }
        let snapshot = MenuBarSnapshot(period: .day, from: from, until: until, counts: DashboardCounts(dispatched: 10, completed: 10), gateway: totals(requests: 10, input: 20_000, output: 2_000, cost: 0.025), workspaces: 2, sessions: 3, compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: models, modelGroups: 2, offset: 0, historicalRate: HistoricalOutputRate(outputTokens: 2_000, generationMilliseconds: 50_000, samples: 10), buckets: buckets)
        let activity = MenuBarActivitySnapshot(rows: [
            MenuBarActivityRow(id: "running", title: "Harden the payment retry loop", workspace: "pi-app", phase: "tool", model: "auto-router", resolvedModel: "openai/gpt-5.4-mini", tools: ["bash"], followUps: 1, steering: 0, unread: 0, startedAt: Date().timeIntervalSince1970 * 1_000 - 82_000, elapsedMs: 82_000, latestRate: 85, tokens: 18_421, costUSD: 0.042),
            MenuBarActivityRow(id: "paused", title: "Explain cache accounting", workspace: "pi-app", phase: "paused", model: "auto-router", resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: 0),
            MenuBarActivityRow(id: "unread", title: "Design notes for the queue", workspace: "Design Reference", phase: "idle", model: "auto-router", resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: 2),
        ], unreadChats: 1)
        var reads = 0
        let controller = MenuBarMetricsController(load: { period, _, offset in
            XCTAssertEqual(period, .day); XCTAssertEqual(offset, 0)
            reads += 1
            return snapshot
        }, activity: { activity })
        let view = MenuBarMetricsView(load: { _,_,_ in throw CaptureFailure.unavailable }, usageController: controller, initialTab: .usage, openApp: {}, openReport: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: view)
        window.contentView = hosted
        defer { controller.setVisible(false); window.orderOut(nil); window.contentView = nil; window.close() }
        window.center(); window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        controller.setVisible(true) // Explicit fixture visibility on an occluded XCTest desktop.
        for _ in 0..<20 where reads == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reads, 1, "Visible menu must load the synthetic Usage snapshot")
        // Allow one SwiftUI presentation transition after the async snapshot.
        // This wait is opt-in and never affects ordinary acceptance tests.
        try await Task.sleep(for: .milliseconds(300))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(hosted.bounds.width, 480, accuracy: 0.5)
        XCTAssertEqual(hosted.bounds.height, 720, accuracy: 0.5)
        XCTAssertFalse(hosted.needsLayout)

        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        XCTAssertGreaterThanOrEqual(image.width, 480)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent("menu-bar-usage.jpg"), options: .atomic)
        // A second capture scrolled to the model distribution, where the long id lives.
        var pending: [NSView] = [hosted], scrolls: [NSScrollView] = []
        while let view = pending.popLast() {
            if let scroll = view as? NSScrollView { scrolls.append(scroll) }
            for child in view.subviews { pending.append(child) }
        }
        if let scroll = scrolls.first, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(300))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scrolled = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
            let models = try XCTUnwrap(NSBitmapImageRep(cgImage: scrolled).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
            try models.write(to: folder.appendingPathComponent("menu-bar-models.jpg"), options: .atomic)
        }
    }
}

private func MenuPeriodStart(_ until: Date) -> Date { MenuBarPeriod.day.start(until: until) ?? until }

@MainActor private final class MenuActivityTestState { var pending = 0 }
