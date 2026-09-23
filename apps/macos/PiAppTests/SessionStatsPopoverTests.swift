import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The statistics pills of a real conversation pane and the Session
/// Inspector's Overview they open, over a real archive; and the popover
/// presenter the skill pills use.
final class SessionStatsPopoverTests: XCTestCase {

    // MARK: Helpers

    @MainActor static func waitFor(_ what: String, seconds: Double = 20, pane: ConversationPaneTests.Pane? = nil,
                                   file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pane?.draw()
            for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }

    /// A window with a pill-sized anchor near its bottom-left corner, where
    /// the composer's pills sit.
    @MainActor static func anchoredWindow(width: CGFloat = 900, height: CGFloat = 700) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let anchor = NSView(frame: NSRect(x: 40, y: 12, width: 190, height: 22))
        content.addSubview(anchor)
        window.contentView = content
        window.center(); window.orderFront(nil)
        return (window, anchor)
    }

    /// The window and this process's own panels over it — a popover — and
    /// nothing else: the images are composed from our window list by id, so
    /// no other application's window or the desktop can appear in them.
    @MainActor static func capture(_ window: NSWindow, to url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        var frame = window.frame
        // The popovers over the window, frontmost first, then the window.
        let popovers = NSApp.windows.filter { $0.isVisible && $0 != window && String(describing: type(of: $0)).contains("Popover") }
        for popover in popovers { frame = frame.union(popover.frame) }
        // The array holds the window ids themselves, not CFNumbers.
        var ids = (popovers + [window]).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let image = create(bounds, array, options)?.takeRetainedValue() else { throw XCTSkip("Window capture returned no image") }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }

    // MARK: A real pane over a real archive

    /// One retained attempt as the helper records it, carrying a fixture
    /// request's timings, usage, cost and model.
    static func metadata(for sample: SessionTimingSample, session: String) -> [String: WireValue] {
        var timings: [String: WireValue] = ["dispatch": .number(100)]
        if let ttft = sample.ttftMilliseconds { timings["firstContent"] = .number(100 + ttft) }
        if let whole = sample.requestMilliseconds { timings["modelComplete"] = .number(100 + whole); timings["httpEnd"] = .number(110 + whole) }
        var usage: [String: WireValue] = [:]
        if let input = sample.inputTokens { usage["inputIncludingCache"] = .number(input) }
        if let read = sample.cacheReadTokens { usage["cacheRead"] = .number(read.rounded()) }
        if let write = sample.cacheWriteTokens { usage["cacheWrite"] = .number(write) }
        if let output = sample.outputTokens { usage["output"] = .number(output) }
        if let reasoning = sample.reasoningTokens { usage["reasoning"] = .number(reasoning) }
        var value: [String: WireValue] = [
            "attemptId": .string(UUID().uuidString), "sessionId": .string(session), "turnId": .string(sample.turn ?? "turn"),
            "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("auto-router"), "mode": .string("off"),
            "outcome": .string(sample.outcome), "wallTimestamp": .number(sample.wall.timeIntervalSince1970 - 1),
            "dispatchWallTimestamp": .number(sample.wall.timeIntervalSince1970), "timingVersion": .number(2), "timings": .object(timings),
            "messageIds": .array([]), "outputMessageIds": .array([]), "usage": .object(usage),
        ]
        if let cost = sample.costUSD {
            value["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(cost)])])
        }
        if let model = sample.model {
            value["identity"] = .object(["status": .string("reported"), "effectiveModel": .string(model),
                                         "evidence": .array([.object(["kind": .string("model"), "value": .string(model), "source": .string("body.model")])])])
        }
        return value
    }

    /// A conversation pane whose archive holds this session's requests, and
    /// whose footer carries the totals the app reads from that archive.
    @MainActor static func seededPane(requests: Int = 12, width: CGFloat = 900, height: CGFloat = 700) async throws -> ConversationPaneTests.Pane {
        let pane = try ConversationPaneTests.Pane(width: width, height: height)
        let archive = pane.model.traces
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        for sample in SessionStatsFixture.session(requests: requests).requests {
            try await record(sample, in: pane)
        }
        try await refreshFooter(pane)
        pane.session.footer.turnTiming = ["sessionModelMs": .number(24_000), "sessionToolMs": .number(9_000)]
        await pane.settle(12)
        return pane
    }
    @MainActor static func record(_ sample: SessionTimingSample, in pane: ConversationPaneTests.Pane) async throws {
        let value = metadata(for: sample, session: pane.chat.id)
        try await pane.model.traces.begin(value, workspace: pane.chat.workspaceID)
        try await pane.model.traces.finish(value)
    }
    /// What the app's accounting refresh publishes after a request settles.
    @MainActor static func refreshFooter(_ pane: ConversationPaneTests.Pane) async throws {
        let accounting = try await pane.model.traces.gatewayAccounting(sessionID: pane.chat.id, workspaceID: pane.chat.workspaceID,
                                                                       messages: [], includeTiming: true)
        pane.session.footer.gateway = accounting.session
    }
    @MainActor static func escape(_ window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(event)
    }
    /// A pill pressed where the reader presses: the window delivers a click at
    /// its centre to its AppKit press target, which then takes it.
    @MainActor static func press(_ identifier: String, in pane: ConversationPaneTests.Pane, file: StaticString = #filePath, line: UInt = #line) throws {
        let pill = try XCTUnwrap(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted).first { $0.accessibilityIdentifier() == identifier },
                                 "The \(identifier) pill is there", file: file, line: line)
        let center = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        XCTAssertTrue(pane.window.contentView?.superview?.hitTest(center) === pill, "A click at the \(identifier) pill's centre lands on its press target", file: file, line: line)
        pill.performClick(nil)
    }
    @MainActor static func inspector(of pane: ConversationPaneTests.Pane) -> SessionInspectorModel? {
        SessionInspectorWindows.shared.controller(sessionID: pane.chat.id)?.inspector
    }

    /// The pills of a real pane, pressed: the two session pills open the
    /// chat's Session Inspector at its Overview, whose charts are built from
    /// the archive; the context ring opens the next request. One window.
    @MainActor func testThePillsOpenTheInspectorAtItsOverviewAndTheNextRequest() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await Self.seededPane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        try Self.press("session-stats-time", in: pane)
        XCTAssertEqual(pane.model.lastInspectorFocus, .overview)
        let inspector = try XCTUnwrap(Self.inspector(of: pane), "The chat's Session Inspector opened")
        XCTAssertEqual(inspector.page, .overview)
        try await Self.waitFor("The Overview did not build its charts from the archive", pane: pane) {
            inspector.indexLoaded && inspector.timeCharts.timeline?.rows.count == 12 && inspector.tokenCharts.perRequest != nil
        }
        XCTAssertEqual(inspector.index.requests.count, 12, "One row per request the archive holds")
        XCTAssertEqual(Array(inspector.timeCharts.hero.map(\.value).prefix(2)), ["\(pane.session.footer.gateway.turnCount ?? 0)", "12"])
        XCTAssertNotNil(inspector.timeCharts.speed); XCTAssertEqual(inspector.timeCharts.models.count, 2, "Two models, so the by-model rows")
        XCTAssertNotNil(inspector.tokenCharts.composition); XCTAssertNotNil(inspector.tokenCharts.cost)
        XCTAssertEqual(inspector.indexReads, 1)

        try Self.press("session-stats-usage", in: pane)
        XCTAssertEqual(SessionInspectorWindows.shared.count, 1, "The usage pill brings the same window forward")
        XCTAssertTrue(Self.inspector(of: pane) === inspector)
        XCTAssertEqual(inspector.page, .overview)

        try Self.press("session-stats-context", in: pane)
        XCTAssertEqual(pane.model.lastInspectorFocus, .nextRequest)
        XCTAssertEqual(inspector.page, .nextRequest, "The context ring opens what the next request will send")
        XCTAssertEqual(SessionInspectorWindows.shared.count, 1)
    }

    /// A turn that ends while the Overview is open moves the footer's
    /// figures: the Overview reads the log again, once, and draws the new request.
    @MainActor func testTheOverviewFollowsARequestThatSettles() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await Self.seededPane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.openInspector(session: pane.chat.id)
        let inspector = try XCTUnwrap(Self.inspector(of: pane))
        try await Self.waitFor("The Overview did not open", pane: pane) { inspector.timeCharts.timeline?.rows.count == 12 }
        XCTAssertEqual(inspector.indexReads, 1)
        let next = SessionStatsFixture.request(13, turn: "t4", model: "gpt-5.4-mini", ttft: 450, stream: 2_000, input: 40_000, cached: 36_000, output: 420)
        try await Self.record(next, in: pane)
        try await Self.refreshFooter(pane)
        try await Self.waitFor("The open Overview did not follow the settled request", pane: pane) { inspector.timeCharts.timeline?.rows.count == 13 }
        XCTAssertEqual(inspector.indexReads, 2, "One more read, for the new request")
        XCTAssertEqual(inspector.timeCharts.hero[1].value, "13")
        XCTAssertEqual(inspector.index.requests.count, 13)
    }

    /// Moving the pointer over every chart of the Overview redraws the rule,
    /// the band and the caption under the pointer — never a chart's marks and
    /// never the page around them.
    @MainActor func testHoveringTheOverviewChartsRedrawsOnlyWhatFollowsThePointer() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await Self.seededPane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        SessionStatsRenderCount.reset()
        let opened = ProcessInfo.processInfo.systemUptime
        pane.model.openInspector(session: pane.chat.id)
        let inspector = try XCTUnwrap(Self.inspector(of: pane))
        try await Self.waitFor("The Overview did not draw its charts", pane: pane) {
            inspector.timeCharts.timeline?.rows.count == 12 && inspector.tokenCharts.perRequest != nil && SessionStatsRenderCount.marks >= 2
        }
        let openMs = (ProcessInfo.processInfo.systemUptime - opened) * 1_000
        // Let the page finish what opening started (the prompts, the models
        // table): it is still when three looks in a row find no new build.
        var last = -1, still = 0, looks = 0
        while still < 3, looks < 60 {
            await pane.settle(2); try await Task.sleep(for: .milliseconds(100)); looks += 1
            if SessionStatsRenderCount.panels == last { still += 1 } else { still = 0; last = SessionStatsRenderCount.panels }
        }
        let open = (panels: SessionStatsRenderCount.panels, marks: SessionStatsRenderCount.marks)
        SessionStatsRenderCount.reset()
        // What a pointer moving across the charts writes, one item at a time.
        // (A test host is not the active app, so SwiftUI's continuous hover
        // does not answer synthetic mouse moves.)
        let selections = [inspector.timelineSelection, inspector.speedSelection, inspector.tokenSelection, inspector.costSelection]
        var steps = 0
        for selection in selections {
            for index in [0, 1, 2, 4, 7, 9, 3, nil] { selection.select(index); steps += 1; await pane.settle(1) }
        }
        await pane.settle(4)
        print(String(format: "PERF Overview: opened in %.0f ms (%d page builds, %d chart mark builds); %d hover steps redrew %d pointer marks and %d captions, rebuilt %d pages and %d chart marks",
                     openMs, open.panels, open.marks, steps, SessionStatsRenderCount.pointers, SessionStatsRenderCount.captions,
                     SessionStatsRenderCount.panels, SessionStatsRenderCount.marks))
        XCTAssertEqual(SessionStatsRenderCount.marks, 0, "Hover never rebuilds a chart's marks")
        XCTAssertEqual(SessionStatsRenderCount.panels, 0, "nor the page around the charts")
        // The charts on screen answer; a lazy grid has not built the ones below the fold.
        XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.pointers, 2, "The rule or band follows the pointer")
        XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.captions, 2, "and so does the caption")
    }

    /// The popover grows open under the app's motion policy and appears in
    /// one step when motion is reduced.
    @MainActor func testReducedMotionOpensThePopoverInOneStep() async throws {
        for reduce in [false, true] {
            let presenter = PiPopoverPresenter()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: PiStatPopoverPill(symbol: "gauge.with.dots.needle.67percent", label: "3 turns 4 steps · 225 tok/s",
                                                                 identifier: "motion-pill", presenter: presenter) { Text("Panel").padding(40) }
                .environment(\.piReduceMotion, reduce).padding(40))
            window.contentView = host; window.center(); window.orderFront(nil)
            defer { presenter.close(); window.orderOut(nil); window.contentView = nil; window.close() }
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
            let trigger = try XCTUnwrap(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: host).first)
            XCTAssertEqual(trigger.accessibilityLabel(), "3 turns 4 steps · 225 tok/s", "The press target carries the pill's reading")
            trigger.performClick(nil)
            try await Self.waitFor("The pill did not open its popover") { presenter.isShown }
            XCTAssertEqual(presenter.popover?.animates, !reduce, reduce ? "Reduced motion: no animation" : "The popover animates open")
        }
    }

    /// A pill waits a moment for its content before opening: it opens as soon
    /// as the content is ready, opens anyway once the wait is over, and a
    /// second press while it waits cancels rather than opening twice.
    @MainActor func testAPillOpensWholeOrPromptlyAndASecondPressWhileWaitingCancels() async throws {
        final class Flag { var ready = false }
        let flag = Flag()
        let presenter = PiPopoverPresenter()
        let (window, anchor) = Self.anchoredWindow(); defer { presenter.close(); window.orderOut(nil); window.contentView = nil; window.close() }
        func press(within wait: Duration) {
            presenter.toggle(from: anchor, width: 300, maximumHeight: 300, animates: false, within: wait, isReady: { flag.ready }) {
                AnyView(Text("Panel").padding(30))
            }
        }
        press(within: .seconds(5))
        XCTAssertTrue(presenter.isOpening); XCTAssertFalse(presenter.isShown, "Not ready: the popover waits")
        try await Task.sleep(for: .milliseconds(60))
        flag.ready = true
        try await Self.waitFor("The popover did not open once its content was ready", seconds: 1) { presenter.isShown }
        XCTAssertFalse(presenter.isOpening)
        presenter.close()

        flag.ready = false
        press(within: .milliseconds(120))
        try await Self.waitFor("The popover did not open when the wait ran out", seconds: 2) { presenter.isShown }
        presenter.close()

        press(within: .seconds(5))
        XCTAssertTrue(presenter.isOpening)
        press(within: .seconds(5))
        XCTAssertFalse(presenter.isOpening, "A second press while it waits cancels")
        flag.ready = true
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(presenter.isShown, "and nothing opens afterwards")
    }

    // MARK: Reads

    /// A burst of footer updates while the Inspector is open reads the log
    /// once more, not once per update; while it is hidden, none.
    @MainActor func testABurstOfFooterUpdatesIsOneMoreReadAndNoneWhileHidden() async throws {
        let root = scratchRoot("inspector-footer-burst"); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        for sample in SessionStatsFixture.session(requests: 12).requests {
            let value = Self.metadata(for: sample, session: "stats")
            try await archive.begin(value, workspace: "project"); try await archive.finish(value)
        }
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "stats", workspaceID: "project"), title: "Burst",
                                              archive: archive, workspace: nil, usageLoader: { _, _, _ in throw CancellationError() },
                                              cache: InspectorDocumentCache())
        let footer = SessionMetrics()
        inspector.observe(footer: footer, display: nil)
        inspector.setVisible(true)
        defer { inspector.setVisible(false) }
        try await Self.waitFor("The index was not read") { inspector.indexReads == 1 && inspector.index.requests.count == 12 }
        for step in 1...5 {
            footer.gateway = GatewayTotals(requests: 12 + step)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Self.waitFor("The burst was not read") { inspector.indexReads == 2 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(inspector.indexReads, 2, "The open read and one more for the whole burst")

        inspector.setVisible(false)
        for step in 1...5 {
            footer.gateway = GatewayTotals(requests: 20 + step)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(inspector.indexReads, 2, "A hidden Inspector reads nothing, whatever the footer does")
        try await archive.close()
    }

    /// A session of two thousand requests: the Overview's series are built
    /// in one pass, bounded to what a chart can show, and cheaply.
    @MainActor func testTheChartsOfALongSessionAreBoundedAndBuildOnce() async throws {
        let history = SessionStatsFixture.session(requests: 2_000)
        let inputs = SessionStatsFixture.inputs(history)
        let started = ProcessInfo.processInfo.systemUptime
        let time = SessionTimeCharts(inputs: inputs, history: history)
        let tokens = SessionTokenCharts(inputs: inputs, history: history)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF building the Overview's series for %d requests: %.1f ms", history.requests.count, elapsed * 1_000))
        XCTAssertEqual(time.timeline?.rows.count, SessionRequestTimeline.maximumRows)
        XCTAssertLessThanOrEqual(time.speed?.points.count ?? .max, SessionSpeedSeries.maximumPoints)
        XCTAssertLessThanOrEqual(tokens.perRequest?.bars.count ?? .max, SessionTokenBars.maximumBars)
        XCTAssertLessThanOrEqual(tokens.cost?.points.count ?? .max, SessionCostSeries.maximumPoints + 1)
        XCTAssertLessThan(elapsed, releaseBudget(0.06), "Building the series of 2,000 requests took \(elapsed * 1_000) ms")
    }

    /// Opt-in (PI_PERF_STATS=1): reading 1,000 retained requests of one
    /// session from a real archive.
    @MainActor func testMeasureReadingALongSessionsHistory() async throws {
        guard testEnvironment("PI_PERF_STATS") == "1" else { throw XCTSkip("Set PI_PERF_STATS=1 to measure the history read") }
        let root = scratchRoot("session-stats-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 64 * 1_048_576, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        for sample in SessionStatsFixture.session(requests: 1_000).requests {
            let value = Self.metadata(for: sample, session: "long")
            try await archive.begin(value, workspace: "project"); try await archive.finish(value)
        }
        var times: [Double] = []
        for _ in 0..<5 {
            let started = ProcessInfo.processInfo.systemUptime
            let history = try await archive.sessionStatsHistory(sessionID: "long", workspaceID: "project")
            times.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            XCTAssertEqual(history.requests.count, 1_000)
        }
        print(String(format: "PERF reading 1,000 retained requests for the charts: best %.1f ms, median %.1f ms", times.min() ?? 0, times.sorted()[2]))
        try await archive.close()
    }
}
