import XCTest
import SwiftUI
import Combine
@testable import PiApp

final class LivePopupTests: XCTestCase {
    private let session = LiveSessionKey(workspace: "project", session: "session")
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ seq: Int, attempt: String = "a", generation: Int = 1, phase: String = "interim", output: Double? = nil, at: Double = 1_000, purpose: String = "turn", model: String = "resolved", status: String = "reported") -> WireValue {
        var usage: [String: WireValue] = ["input": .number(100), "cacheRead": .number(60), "reasoning": .number(5)]
        if let output { usage["output"] = .number(output) }
        let telemetry: [String: WireValue] = [
            "dispatch": phase == "preparing" ? .null : .number(100),
            "firstContent": .number(600), "modelComplete": phase == "final" ? .number(at) : .null,
            "identity": .object(["status": .string("reported"), "effectiveModel": .string(model)]),
            "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.001)])])
        ]
        return .object([
            "kind": .string("request"), "seq": .number(Double(seq)), "generation": .number(Double(generation)),
            "attemptID": .string(attempt), "phase": .string(phase), "purpose": .string(purpose),
            "requestedModel": .string("auto-router"), "receivedAt": .number(at), "usage": .object(usage),
            "status": .object(["input": .string("reported"), "output": .string(output == nil ? "unreported" : status), "cacheRead": .string("reported"), "reasoning": .string("reported")]),
            "fieldPhase": .object(["output": .string(phase)]), "telemetry": .object(telemetry)
        ])
    }
    private func page(_ events: [WireValue], epoch: String = "epoch", gap: Bool = false) -> [String: WireValue] {
        ["epoch": .string(epoch), "cursor": .number(events.last?.object?["seq"]?.number ?? 0), "events": .array(events), "gap": .bool(gap)]
    }
    private func feed(_ value: inout LiveActivityAccumulator, _ events: [WireValue], at: Double = 1, epoch: String = "epoch") {
        value.ingest(page(events, epoch: epoch), session: session, at: at, wall: date.addingTimeInterval(at))
    }
    func testTerminalOnlyUsageNeverInventsLiveTPSAndCountsOnce() throws {
        var store = LiveActivityAccumulator()
        feed(&store, [event(1, phase: "preparing")]); XCTAssertTrue(store.active.isEmpty)
        feed(&store, [event(2, phase: "awaiting")]); XCTAssertEqual(store.active.count, 1)
        XCTAssertNil(store.active.values.first?.output); XCTAssertNil(store.active.values.first?.intervalRate)
        feed(&store, [event(3, phase: "final", output: 400, at: 2_100)], at: 2)
        feed(&store, [event(3, phase: "final", output: 400, at: 2_100)], at: 2)
        XCTAssertTrue(store.active.isEmpty); XCTAssertEqual(store.completions.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.completions.first?.request.rate), 200, accuracy: 0.001)
        XCTAssertEqual(store.buckets.reduce(0) { $0 + $1.completions }, 1)
        XCTAssertEqual(store.buckets.reduce(0) { $0 + $1.interimSamples }, 0)
        feed(&store, [event(4, output: 900, at: 2_500)], at: 3)
        XCTAssertTrue(store.active.isEmpty); XCTAssertEqual(store.completions.first?.request.output, 400)
    }
    func testIntervalsUseActualSpacingExpireAndRebaselineCorrections() throws {
        var store = LiveActivityAccumulator()
        feed(&store, [event(1, output: 10, at: 1_000)])
        feed(&store, [event(2, output: 50, at: 3_000)], at: 3)
        XCTAssertEqual(store.active.values.first?.intervalRate, 20)
        XCTAssertNil(store.snapshot(at: 6, wall: date).requests.first?.intervalRate)
        feed(&store, [event(3, output: 20, at: 4_000)], at: 4)
        XCTAssertNil(store.active.values.first?.intervalRate); XCTAssertEqual(store.active.values.first?.correction, true)
        feed(&store, [event(4, output: 25, at: 4_500)], at: 4.5)
        XCTAssertEqual(store.active.values.first?.intervalRate, 10)
        feed(&store, [event(5, output: .infinity, at: 5_000)], at: 5)
        XCTAssertNil(store.active.values.first?.output); XCTAssertNil(store.active.values.first?.intervalRate)
        feed(&store, [event(6, output: 30, at: 5_500)], at: 5.5)
        XCTAssertNil(store.active.values.first?.intervalRate)
        feed(&store, [event(7, output: 35, at: 6_000, status: "conflict")], at: 6)
        XCTAssertNil(store.active.values.first?.output); XCTAssertNil(store.active.values.first?.intervalRate)
    }
    func testRequestsAndSessionsAndUtilitiesHaveSeparateScopes() throws {
        var store = LiveActivityAccumulator()
        store.phase("model", session: session, at: 1, wall: date)
        let other = LiveSessionKey(workspace: "project", session: "second")
        store.phase("tool", session: other, at: 1, wall: date)
        for i in 1...4 { feed(&store, [event(i, attempt: "a\(i)", generation: i, output: Double(i), purpose: i == 4 ? "compaction" : "turn")]) }
        let result = store.snapshot(at: 1, wall: date)
        XCTAssertEqual(result.counts.total, 2); XCTAssertEqual(result.activeRequests, 4); XCTAssertEqual(result.utilityRequests, 1)
        XCTAssertEqual(result.total(\.input).value, 400); XCTAssertEqual(result.total(\.output).value, 10)
        XCTAssertEqual(result.total(\.cached).value, 240, "Cache is a subset, never added to input")
        XCTAssertEqual(result.total(\.cost).value, 0.004)
        XCTAssertTrue(result.requests.allSatisfy { $0.intervalRate == nil })
    }
    func testMissingFinalOutputIsNotPromotedToFinalAndBadTimingCannotCrash() {
        var store = LiveActivityAccumulator()
        feed(&store, [event(1, output: 100)])
        var final = event(2, phase: "final", output: 100).object!
        final["fieldPhase"] = .object(["output": .string("interim")])
        feed(&store, [.object(final)])
        XCTAssertNil(store.completions.first?.request.rate)
        var bad = event(3, attempt: "b", generation: 2, phase: "final", output: 1e100).object!
        bad["receivedAt"] = .number(.nan)
        bad["telemetry"] = .object(["dispatch": .number(100), "modelComplete": .number(.infinity)])
        feed(&store, [.object(bad)])
        XCTAssertNil(store.completions.last?.request.rate)
        feed(&store, [.object(["seq": .number(Double.greatestFiniteMagnitude)])])
        XCTAssertEqual(store.completions.count, 2)
    }
    func testEpochsGapsAndAliasEchoCannotClaimCurrentRoute() throws {
        var store = LiveActivityAccumulator()
        feed(&store, [event(1, output: 20, model: "auto-router")])
        XCTAssertNil(store.active.values.first?.model)
        feed(&store, [event(2, output: 30, at: 2_000)], at: 2)
        store.disconnect("project", at: 3, wall: date.addingTimeInterval(3))
        XCTAssertTrue(store.snapshot(at: 3, wall: date).disconnected); XCTAssertTrue(store.active.isEmpty)
        feed(&store, [event(1, output: 60, at: 4_000, model: "second-route")], at: 4, epoch: "next")
        XCTAssertNil(store.active.values.first?.intervalRate); XCTAssertEqual(store.active.values.first?.model, "second-route")
        XCTAssertFalse(store.snapshot(at: 4, wall: date).disconnected)
        store.advance(at: 14, wall: date.addingTimeInterval(14))
        XCTAssertTrue(store.buckets.suffix(9).allSatisfy(\.gap))
        feed(&store, [event(2, output: 90, at: 15_000)], at: 15, epoch: "next")
        XCTAssertNil(store.active.values.first?.intervalRate, "No interval crosses sleep or runtime replacement")
    }
    func testSubSecondWorkPeaksSurviveCoalescingAndIdleIsZero() {
        var store = LiveActivityAccumulator()
        let events: [WireValue] = ["model", "tool", "idle"].enumerated().map { .object(["seq": .number(Double($0.offset + 1)), "kind": .string("phase"), "phase": .string($0.element)]) }
        feed(&store, events)
        XCTAssertEqual(store.counts.total, 0); XCTAssertEqual(store.buckets.last?.peak.model, 1); XCTAssertEqual(store.buckets.last?.peak.tools, 1)
        store.advance(at: 2, wall: date.addingTimeInterval(2))
        XCTAssertEqual(store.buckets.last?.peak.total, 0); XCTAssertEqual(store.buckets.last?.gap, false)
        XCTAssertEqual(store.snapshot(at: 9, wall: date.addingTimeInterval(9)).freshnessLabel, "Last observed 8s ago", "A sampling tick is not a fresh source observation")
        feed(&store, events, at: 9)
        XCTAssertEqual(store.snapshot(at: 9, wall: date.addingTimeInterval(9)).freshnessLabel, "Observed just now")
    }
    func testHistoryBudgetsKeepAggregateCoverageWhenDetailsOverflow() throws {
        func footprint() -> UInt64 {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
            }
            return result == 0 ? usage.ri_phys_footprint : 0
        }
        var store = LiveActivityAccumulator()
        let before = footprint()
        for i in 1...2_000 { feed(&store, [event(i, attempt: "a\(i)", generation: i, phase: "final", output: 20, at: 1_100)]) }
        XCTAssertEqual(store.completions.count, 1_000)
        XCTAssertEqual(store.buckets.reduce(0) { $0 + $1.completions }, 2_000)
        XCTAssertEqual(store.buckets.reduce(0) { $0 + $1.rateSamples }, 2_000)
        feed(&store, [event(2_001, attempt: "a1", generation: 1, phase: "final", output: 20, at: 1_100)])
        XCTAssertEqual(store.buckets.reduce(0) { $0 + $1.completions }, 2_000, "Late enrichment of evicted details cannot double-count")
        store.advance(at: 2_000, wall: date.addingTimeInterval(2_000))
        XCTAssertEqual(store.buckets.count, 900)
        let after = footprint()
        print("PERF popup bounded history footprintDeltaBytes=\(Int64(after) - Int64(before)) completions=\(store.completions.count) buckets=\(store.buckets.count)")
    }
    @MainActor func testHiddenStoreHasNoPublicationsAndRepeatedVisibilityDoesNotLeakLoops() async throws {
        let store = LiveActivityStore(observeSleep: false)
        defer { store.shutdown() }
        store.ingest(page([event(1, output: 10)]), workspace: session.workspace, session: session.session)
        for _ in 0..<10 { store.tick() }
        XCTAssertEqual(store.publications, 0)
        for _ in 0..<20 { store.setVisible(true); store.setVisible(false) }
        let before = store.publications
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.publications, before)
        store.setVisible(true)
        XCTAssertEqual(store.snapshot.activeRequests, 1)
    }
    @MainActor func testPanelBudgetIncludesFooterOnShortDisplays() {
        XCTAssertEqual(MenuBarPanelLayout.height(available: 600), 576)
        XCTAssertEqual(MenuBarPanelLayout.height(available: 1_200), 720)
        XCTAssertLessThan(MenuBarPanelLayout.height(available: 380), 380)
    }
    func testRowIdentityAndLocationStayStableThroughHoverAndCompletion() {
        func row(_ id: String, _ phase: String) -> MenuBarActivityRow {
            MenuBarActivityRow(id: id, title: id, workspace: "p", phase: phase, model: "router", resolvedModel: nil, tools: [], followUps: 0, steering: 0, unread: 0)
        }
        var order = LivePopupRowOrder()
        order.reconcile(MenuBarActivitySnapshot(rows: [row("a", "model"), row("b", "model")]), held: [])
        order.reconcile(MenuBarActivitySnapshot(rows: [row("b", "model"), row("a", "error")]), held: ["a"])
        XCTAssertEqual(order.rows(in: .working).map(\.id), ["a", "b"])
        XCTAssertEqual(order.rows(in: .working).first?.phase, "error")
        order.reconcile(MenuBarActivitySnapshot(rows: [row("b", "model"), row("a", "error")]), held: [])
        XCTAssertEqual(order.rows(in: .attention).map(\.id), ["a"])
        order.reconcile(MenuBarActivitySnapshot(rows: [row("b", "model")]), held: ["a"])
        XCTAssertEqual(order.rows(in: .attention).first?.actionable, false)
        order.reconcile(MenuBarActivitySnapshot(rows: [row("b", "model")]), held: [])
        XCTAssertTrue(order.rows(in: .attention).isEmpty)
    }

    @MainActor func testNativePopupWithTwentyStreamsAndTenThousandChats() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("popup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.chats = (0..<10_000).map { ChatRecord(id: "s\($0)", workspaceID: "project", title: "Task \($0)", path: nil, profileID: "fixture") }
        for i in 0..<20 {
            let view = SessionDisplay(id: "s\(i)"); model.displays[view.id] = view
            view.state = "running"; view.activity = ["phase": .string(i % 3 == 0 ? "tool" : "model"), "model": .string("auto-router")]
            model.liveActivity.ingest(page([event(1, output: 10, purpose: i == 0 ? "compaction" : "turn")]), workspace: "project", session: view.id)
        }
        var reads = 0
        let monitor = MenuBarMetricsController(load: { _,_,_ in reads += 1; throw CaptureFailure.unavailable }, period: .fifteenMinutes, activity: { model.menuBarActivity() }, activityChanges: { model.menuBarActivityChanges })
        let view = MenuBarMetricsView(load: { _,_,_ in throw CaptureFailure.unavailable }, live: model.liveActivity, monitorController: monitor, openApp: {}, openReport: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 576), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: view.environment(\.menuBarHeight, 576))
        window.contentView = hosted; window.center()
        defer { monitor.setVisible(false); window.contentView = nil; window.close() }
        // Let the native hosting view actually mount before measuring warm
        // opens. Immediate orderFront/layout calls alone can time only enqueueing.
        window.orderFront(nil); model.liveActivity.setVisible(true)
        try await Task.sleep(for: .milliseconds(150))
        monitor.setVisible(true)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        var openings: [Double] = [], updates: [Double] = [], opportunities: [Double] = []
        for _ in 0..<8 {
            window.orderOut(nil); model.liveActivity.setVisible(false); monitor.setVisible(false)
            let start = ProcessInfo.processInfo.systemUptime
            model.liveActivity.setVisible(true); monitor.setVisible(true); window.orderFront(nil); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            openings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        window.orderFront(nil); model.liveActivity.setVisible(true)
        _ = model.menuBarActivity()
        let projections = model.activityProjectionCount
        for tick in 2...61 {
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<20 {
                model.displays["s\(i)"]?.messages = [TranscriptMessage(id: "answer", role: "assistant", text: "stream \(tick)", state: "streaming")]
                model.liveActivity.ingest(page([event(tick, output: Double(tick * 10), at: Double(tick) * 250, purpose: i == 0 ? "compaction" : "turn")]), workspace: "project", session: "s\(i)")
            }
            model.liveActivity.tick(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            updates.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            // Yield a run-loop opportunity for SwiftUI, then force a display.
            // This elapsed measurement includes the 16 ms scheduling interval;
            // it is not a claim about physical frame presentation or CPU time.
            try await Task.sleep(for: .milliseconds(16))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            opportunities.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        XCTAssertEqual(model.displays.count, 20, "Popup cannot materialize the other 9,980 chats")
        XCTAssertEqual(model.activityProjectionCount, projections, "Text/monitor events cannot rescan the sidebar")
        XCTAssertNil(model.selectedID); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(model.liveActivity.snapshot.activeRequests, 20)
        XCTAssertEqual(hosted.bounds.height, 576, accuracy: 0.5)
        func percentile(_ values: [Double], _ fraction: Double) -> Double { values.sorted()[max(0, Int(ceil(Double(values.count) * fraction)) - 1)] }
        print("PERF popup warm p95Ms=\(percentile(Array(openings.dropFirst()), 0.95)) 20-stream-update p95Ms=\(percentile(updates, 0.95)) p99Ms=\(percentile(updates, 0.99)) maxMs=\(updates.max() ?? 0) historyReads=\(reads)")
        print("PERF popup state-to-display-opportunity p95Ms=\(percentile(opportunities, 0.95)) p99Ms=\(percentile(opportunities, 0.99)) maxMs=\(opportunities.max() ?? 0) (includes 16ms scheduling interval)")
        if let folder = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") {
            try await Task.sleep(for: .milliseconds(300))
            for (appearance, name) in [(NSAppearance.Name.aqua, "live-popup-light-short"), (.darkAqua, "live-popup-dark-short"), (.accessibilityHighContrastAqua, "live-popup-contrast-short")] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(100))
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try capture(window, to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".jpg"))
            }
        }
        window.orderOut(nil); model.liveActivity.setVisible(false); monitor.setVisible(false)
        try await Task.sleep(for: .milliseconds(300))
        let publications = model.liveActivity.publications, hiddenReads = reads
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(model.liveActivity.publications, publications); XCTAssertEqual(reads, hiddenReads)
    }
    @MainActor func testMonitorDesignLightDarkAndNativeZoomWithReportedFixture() async throws {
        var seconds = 1.0
        let date = date
        let live = LiveActivityStore(now: { seconds }, wall: { date.addingTimeInterval(seconds) }, observeSleep: false)
        defer { live.shutdown() }
        let names = ["GPT-5.4 mini", "Claude Sonnet", "GPT-5.4"]
        let titles = ["API refactor", "UI review", "Release notes"]
        var totals = [0.0, 0.0, 0.0]
        for i in 0..<3 { live.phase("model", workspace: "project", session: "s\(i)") }
        for tick in 1...900 {
            seconds = Double(tick)
            for i in 0..<3 {
                totals[i] += Double(25 + i * 15) + sin(Double(tick) / 33) * 8
                live.ingest(page([event(tick, output: totals[i].rounded(), at: seconds * 1_000, model: names[i])]), workspace: "project", session: "s\(i)")
            }
        }
        func gateway(output: Double, cost: Double) -> GatewayTotals {
            var g = GatewayTotals(requests: 12, costSamples: 12, costUSD: cost)
            g.tokens = GatewayTokenTotals(input: 72_000, output: output, total: 72_000 + output, inputSamples: 12, outputSamples: 12, samples: 12)
            g.cacheReadTokens = 48_000; g.cacheReadSamples = 12; g.uncachedInputReportedTokens = 24_000; g.uncachedInputSamples = 12
            return g
        }
        let models = names.enumerated().map { i, name in
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: name, identityStatus: "reported", gateway: gateway(output: [24_100, 14_460, 9_640][i], cost: [0.62, 0.372, 0.248][i]), allRequests: 36, costShare: [0.5, 0.3, 0.2][i], outputShare: [0.5, 0.3, 0.2][i])
        }
        let activity = MenuBarActivitySnapshot(rows: titles.enumerated().map { i, title in
            var row = MenuBarActivityRow(id: "s\(i)", title: title, workspace: "Bello Agent", phase: "model", model: "auto-router", resolvedModel: names[i], tools: [], followUps: 0, steering: 0, unread: 0)
            row.workspaceID = "project"; return row
        })
        var queries: [(Date?, Date)] = []
        let monitor = MenuBarMetricsController(load: { _,_,_ in throw CaptureFailure.unavailable }, scopedLoad: { period, until, _, from, _ in
            queries.append((from, until))
            return MenuBarSnapshot(period: period, from: from ?? period.start(until: until), until: until, counts: DashboardCounts(dispatched: 36, completed: 36), gateway: gateway(output: 48_200, cost: 1.24), workspaces: 1, sessions: 3, compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: models, modelGroups: 3, offset: 0, historicalRate: HistoricalOutputRate(outputTokens: 48_200, generationMilliseconds: 430_000, samples: 36))
        }, period: .fifteenMinutes, activity: { activity }, interval: .seconds(60), now: { date.addingTimeInterval(seconds) })
        let view = MenuBarMetricsView(load: { _,_,_ in throw CaptureFailure.unavailable }, projects: { [MonitorProject(id: "project", title: "Bello Agent")] }, live: live, monitorController: monitor, openApp: {}, openReport: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        window.contentView = hosted; window.center(); window.orderFront(nil)
        defer { monitor.setVisible(false); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        // The XCTest desktop may be occluded by the lock screen. Explicitly
        // publish the isolated fixture; production uses the visibility reader.
        live.setVisible(true); monitor.setVisible(true)
        for _ in 0..<100 where monitor.snapshot == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(queries.count, 1); XCTAssertEqual(live.snapshot.currentRates(workspace: nil).reported, 3)
        func surfaces(_ view: NSView) -> [MonitorChartInteraction.Surface] {
            var pending = [view], result: [MonitorChartInteraction.Surface] = []
            while let candidate = pending.popLast() {
                if let surface = candidate as? MonitorChartInteraction.Surface { result.append(surface) }
                pending.append(contentsOf: candidate.subviews)
            }
            return result
        }
        for (appearance, name) in [(NSAppearance.Name.aqua, "bello-monitor-light"), (.darkAqua, "bello-monitor-dark")] {
            window.appearance = NSAppearance(named: appearance)
            hosted.rootView = view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            try await Task.sleep(for: .milliseconds(150))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            XCTAssertEqual(hosted.bounds.width, 480, accuracy: 0.5)
            let surface = try XCTUnwrap(surfaces(hosted).first)
            XCTAssertGreaterThan(surface.plot.width, 300)
            if let folder = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") {
                try capture(window, to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".jpg"))
            }
        }
        let surface = try XCTUnwrap(surfaces(hosted).first)
        let plot = surface.plot
        func pointer(_ type: NSEvent.EventType, fraction: Double) throws -> NSEvent {
            let point = surface.convert(CGPoint(x: plot.minX + plot.width * fraction, y: plot.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try pointer(.leftMouseDown, fraction: 0.25))
        surface.mouseDragged(with: try pointer(.leftMouseDragged, fraction: 0.75))
        XCTAssertEqual(queries.count, 1)
        surface.mouseUp(with: try pointer(.leftMouseUp, fraction: 0.75))
        for _ in 0..<100 where queries.count < 2 { await Task.yield() }
        XCTAssertEqual(queries.count, 2, "Native brush commits one scoped read")
        XCTAssertEqual(try XCTUnwrap(monitor.selectedRange).upperBound.timeIntervalSince(try XCTUnwrap(monitor.selectedRange).lowerBound), 450, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(200))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let zoomedSurface = try XCTUnwrap(surfaces(hosted).first)
        XCTAssertEqual(zoomedSurface.domain.lowerBound.timeIntervalSince1970, try XCTUnwrap(monitor.selectedRange).lowerBound.timeIntervalSince1970, accuracy: 0.1, "The rendered chart scale must follow the brush, not only its caption")
        XCTAssertEqual(zoomedSurface.domain.upperBound.timeIntervalSince1970, try XCTUnwrap(monitor.selectedRange).upperBound.timeIntervalSince1970, accuracy: 0.1)
        if let folder = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") {
            try capture(window, to: URL(fileURLWithPath: folder).appendingPathComponent("bello-monitor-zoomed.jpg"))
        }
    }

    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let address = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let capture = unsafeBitCast(address, to: Capture.self)
        let image = try XCTUnwrap(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.80]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
