import XCTest
import AppKit
import SwiftUI
@testable import PiApp

final class MenuBarPresentationTests: XCTestCase {
    @MainActor func testRunningPresentationExcludesQuietChatsWithoutChangingUnreadOrQueuedWork() throws {
        let base = ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()
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

    /// Optional visual evidence uses only this synthetic window, never the
    /// desktop or a user's project, archive, credentials, or gateway.
    @MainActor func testCaptureDefaultUsagePanelWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PI_APP_USAGE_CAPTURE_ROOT"] ?? environment["TEST_RUNNER_PI_APP_USAGE_CAPTURE_ROOT"] else {
            throw XCTSkip("Set PI_APP_USAGE_CAPTURE_ROOT for the optional menu preview")
        }
        func totals(requests: Int, input: Double, output: Double, cost: Double) -> GatewayTotals {
            var result = GatewayTotals(requests: requests, costSamples: requests, costUSD: cost)
            result.tokens = GatewayTokenTotals(input: input, output: output, total: input + output, inputSamples: requests, outputSamples: requests, samples: requests)
            return result
        }
        let models = [
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "openai/gpt-5.4-mini", identityStatus: "reported", gateway: totals(requests: 6, input: 15_000, output: 1_200, cost: 0.0096), allRequests: 10, historicalRate: HistoricalOutputRate(outputTokens: 1_200, generationMilliseconds: 25_000, samples: 6), costShare: 0.384),
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
            MenuBarActivityRow(id: "running", title: "Harden the payment retry loop", workspace: "pi-app", phase: "tool", model: "auto-router", resolvedModel: nil, tools: ["bash"], followUps: 1, steering: 0, unread: 0),
            MenuBarActivityRow(id: "paused", title: "Explain cache accounting", workspace: "pi-app", phase: "paused", model: "auto-router", resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: 0),
            MenuBarActivityRow(id: "unread", title: "Design notes for the queue", workspace: "Design Reference", phase: "idle", model: "auto-router", resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: 2),
        ], unreadChats: 1)
        var reads = 0
        let view = MenuBarMetricsView(load: { period, _, offset in
            XCTAssertEqual(period, .day); XCTAssertEqual(offset, 0)
            reads += 1
            return snapshot
        }, activity: { activity }, openApp: {}, openReport: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 428, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: view)
        window.contentView = hosted
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.center(); window.orderFront(nil)
        for _ in 0..<20 where reads == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reads, 1, "Visible menu must load the synthetic Usage snapshot")
        // Allow one SwiftUI presentation transition after the async snapshot.
        // This wait is opt-in and never affects ordinary acceptance tests.
        try await Task.sleep(for: .milliseconds(300))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(hosted.bounds.width, 428, accuracy: 0.5)
        XCTAssertEqual(hosted.bounds.height, 720, accuracy: 0.5)
        XCTAssertFalse(hosted.needsLayout)

        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        XCTAssertGreaterThanOrEqual(image.width, 428)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent("menu-bar-usage.jpg"), options: .atomic)
    }
}

private func MenuPeriodStart(_ until: Date) -> Date { MenuBarPeriod.day.start(until: until) ?? until }
