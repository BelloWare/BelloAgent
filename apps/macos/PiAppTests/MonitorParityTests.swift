import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The menu bar panel and its live monitor are not in the screenshot
/// gallery, so their AppKit ports are drawn next to the SwiftUI originals
/// (`MonitorParityReferences.swift`) here, with the same fixture: the live
/// tab, the usage tab, light and dark, and the parts they are built from.
///
/// Serial: the windows are on screen.
@MainActor final class MonitorParityTests: XCTestCase, SerialTestLane {
    /// Antialiasing of the same text, symbol and curve edges.
    static let allowedShare = 0.012
    static let strongChannel = 64
    static let strongShare = 0.002
    private var results: [PiKitParity.Result] = []

    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("MONITORPARITY " + result.description) }
    }

    private func check<V: View>(_ name: String, canvas: NSColor = .piContent, share: Double = MonitorParityTests.allowedShare,
                                strongShare: Double = MonitorParityTests.strongShare, appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)],
                                _ swiftUI: () -> V, _ appKit: () -> NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in appearances {
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance, swiftUI: swiftUI(), appKit: appKit(), canvas: canvas)
            results.append(result)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 1, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: Self.strongChannel).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * strongShare, "\(result.name): \(strong) px differ past \(Self.strongChannel)", file: file, line: line)
            print("MONITORPARITY \(result.name) strong=\(strong)")
        }
    }

    // MARK: Fixture

    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// Three models reporting for fifteen minutes, three sessions working,
    /// a retained snapshot with three routes and a day of buckets.
    final class Fixture {
        let live: LiveActivityStore
        let monitor: MenuBarMetricsController
        let usage: MenuBarMetricsController
        var seconds = 900.0
        @MainActor init() {
            var seconds = 1.0
            let date = MonitorParityTests.date
            let clock = Clock()
            live = LiveActivityStore(now: { clock.seconds }, wall: { date.addingTimeInterval(clock.seconds) }, observeSleep: false)
            let names = ["GPT-5.4 mini", "Claude Sonnet", "GPT-5.4"]
            var totals = [0.0, 0.0, 0.0]
            for i in 0..<3 { live.phase("model", workspace: "project", session: "s\(i)") }
            for tick in 1...900 {
                seconds = Double(tick); clock.seconds = seconds
                for i in 0..<3 {
                    totals[i] += Double(25 + i * 15) + sin(Double(tick) / 33) * 8
                    live.ingest(MonitorParityTests.page([MonitorParityTests.event(tick, output: totals[i].rounded(), at: seconds * 1_000, model: names[i])]), workspace: "project", session: "s\(i)")
                }
            }
            let snapshot = MonitorParityTests.snapshot(names: names)
            _ = seconds
            let activity = MenuBarActivitySnapshot(rows: ["API refactor", "UI review", "Release notes"].enumerated().map { i, title in
                var row = MenuBarActivityRow(id: "s\(i)", title: title, workspace: "Bello Agent", phase: "model", model: "auto-router", resolvedModel: names[i], tools: [], followUps: 0, steering: 0, unread: 0)
                row.workspaceID = "project"; return row
            })
            monitor = MenuBarMetricsController(load: { _, _, _ in snapshot }, scopedLoad: { period, until, _, from, _ in
                MonitorParityTests.snapshot(names: names, period: period, from: from ?? period.start(until: until), until: until)
            }, period: .fifteenMinutes, activity: { activity }, interval: .seconds(600), now: { date.addingTimeInterval(clock.seconds) })
            usage = MenuBarMetricsController(load: { _, _, _ in snapshot }, interval: .seconds(600), now: { date.addingTimeInterval(clock.seconds) })
        }
        final class Clock { var seconds = 1.0 }
        @MainActor func load() async throws {
            live.setVisible(true); monitor.setVisible(true); usage.setVisible(true)
            try await eventually("the fixture's snapshots", timeout: .seconds(10), poll: .milliseconds(10)) { monitor.snapshot != nil && usage.snapshot != nil }
        }
        @MainActor func shutdown() { monitor.setVisible(false); usage.setVisible(false); live.shutdown() }
    }

    static func snapshot(names: [String], period: MenuBarPeriod = .day, from: Date? = nil, until: Date = date.addingTimeInterval(900)) -> MenuBarSnapshot {
        func gateway(output: Double, cost: Double, requests: Int = 12) -> GatewayTotals {
            var g = GatewayTotals(requests: requests, costSamples: requests, costUSD: cost)
            g.tokens = GatewayTokenTotals(input: 72_000, output: output, total: 72_000 + output, inputSamples: requests, outputSamples: requests, samples: requests)
            g.cacheReadTokens = 48_000; g.cacheReadSamples = requests; g.uncachedInputReportedTokens = 24_000; g.uncachedInputSamples = requests
            g.decodeMilliseconds = 344_000; g.decodeOutputTokens = output; g.decodeSamples = requests
            return g
        }
        let models = names.enumerated().map { i, name in
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: name, identityStatus: "reported",
                                     gateway: gateway(output: [24_100, 14_460, 9_640][i], cost: [0.62, 0.372, 0.248][i]), allRequests: 36,
                                     costShare: [0.5, 0.3, 0.2][i], outputShare: [0.5, 0.3, 0.2][i])
        }
        let start = from ?? until.addingTimeInterval(-86_400)
        let width = until.timeIntervalSince(start) / 24
        let buckets = (0..<24).map { i -> MenuBarBucket in
            let s = start.addingTimeInterval(Double(i) * width)
            return MenuBarBucket(id: i, start: s, end: s.addingTimeInterval(width), gateway: gateway(output: Double(400 + i * 37 % 300), cost: Double(i % 5) * 0.031, requests: 1 + i % 4))
        }
        return MenuBarSnapshot(period: period, from: start, until: until, counts: DashboardCounts(dispatched: 36, completed: 34, failed: 1, cancelled: 1),
                               gateway: gateway(output: 48_200, cost: 1.24, requests: 36), workspaces: 1, sessions: 3, compactionRequests: 1,
                               costUnreported: 0, costInvalid: 0, costConflicts: 0, models: models, modelGroups: 3, offset: 0, buckets: buckets)
    }

    // MARK: The panel

    func testTheLivePanel() async throws {
        let a = Fixture(), b = Fixture()
        defer { a.shutdown(); b.shutdown() }
        try await a.load(); try await b.load()
        try await check("panel-live", canvas: .monitorCanvas, {
            RefMenuBarMetricsView(load: { _, _, _ in throw CaptureFailure.unavailable }, projects: { [MonitorProject(id: "project", title: "Bello Agent")] },
                                  live: a.live, monitorController: a.monitor, usageController: a.usage, openApp: {}, openReport: {})
                .environment(\.refMenuBarHeight, 720)
        }, {
            let view = MenuBarMetricsView(load: { _, _, _ in throw CaptureFailure.unavailable }, projects: { [MonitorProject(id: "project", title: "Bello Agent")] },
                                          live: b.live, monitorController: b.monitor, usageController: b.usage, openApp: {}, openReport: {})
            view.panelHeight = 720
            return view
        })
    }

    func testTheUsagePanel() async throws {
        let a = Fixture(), b = Fixture()
        defer { a.shutdown(); b.shutdown() }
        try await a.load(); try await b.load()
        try await check("panel-usage", canvas: .monitorCanvas, {
            RefMenuBarMetricsView(load: { _, _, _ in throw CaptureFailure.unavailable }, live: a.live, monitorController: a.monitor, usageController: a.usage,
                                  initialTab: .usage, openApp: {}, openReport: {})
                .environment(\.refMenuBarHeight, 720)
        }, {
            let view = MenuBarMetricsView(load: { _, _, _ in throw CaptureFailure.unavailable }, live: b.live, monitorController: b.monitor, usageController: b.usage,
                                          initialTab: .usage, openApp: {}, openReport: {})
            view.panelHeight = 720
            return view
        })
    }

    // MARK: Parts

    func testADisclosureGroupOpenAndClosed() async throws {
        for open in [false, true] {
            try await check("disclosure-\(open ? "open" : "closed")", {
                DisclosureGroup("Usage details", isExpanded: .constant(open)) {
                    Text("A line of content under the group, as wide as it needs.").font(PiFont.micro)
                }
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(width: 320, alignment: .leading)
            }, {
                let content = ShellText("A line of content under the group, as wide as it needs.", font: PiKit.Font.micro, color: .piInkSecondary)
                let group = DisclosureGroupView("Usage details", font: PiKit.Font.caption, color: .piInkSecondary, content: content, isExpanded: open)
                return Sized(group, width: 320)
            })
        }
    }

    /// A view at a fixed width and the height it asks for there.
    final class Sized: NSView, PiKit.WidthSizing {
        let content: NSView
        let width: CGFloat
        init(_ content: NSView, width: CGFloat) {
            self.content = content; self.width = width
            super.init(frame: CGRect(x: 0, y: 0, width: width, height: PiKit.height(of: content, width: width)))
            addSubview(content)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: content, width: self.width) }
        override var intrinsicContentSize: NSSize { NSSize(width: width, height: PiKit.height(of: content, width: width)) }
        override func layout() { super.layout(); content.frame = CGRect(x: 0, y: 0, width: width, height: PiKit.height(of: content, width: width)) }
    }

    // MARK: Live usage pages (as `LivePopupTestCase` writes them)

    static func event(_ seq: Int, output: Double, at: Double, model: String) -> WireValue {
        let usage: [String: WireValue] = ["input": .number(100), "cacheRead": .number(60), "reasoning": .number(5), "output": .number(output)]
        let telemetry: [String: WireValue] = [
            "dispatch": .number(100), "firstContent": .number(600), "modelComplete": .null,
            "identity": .object(["status": .string("reported"), "effectiveModel": .string(model)]),
            "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.001)])]),
        ]
        return .object([
            "kind": .string("request"), "seq": .number(Double(seq)), "generation": .number(1), "attemptID": .string("a"), "phase": .string("interim"),
            "purpose": .string("turn"), "requestedModel": .string("auto-router"), "receivedAt": .number(at), "usage": .object(usage),
            "status": .object(["input": .string("reported"), "output": .string("reported"), "cacheRead": .string("reported"), "reasoning": .string("reported")]),
            "fieldPhase": .object(["output": .string("interim")]), "telemetry": .object(telemetry),
        ])
    }
    static func page(_ events: [WireValue]) -> [String: WireValue] {
        ["epoch": .string("epoch"), "cursor": .number(events.last?.object?["seq"]?.number ?? 0), "events": .array(events), "gap": .bool(false)]
    }
}
