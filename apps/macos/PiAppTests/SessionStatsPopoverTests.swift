import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The statistics popovers in real windows: opened from the pills of a real
/// conversation pane, measured against the screen, and hovered.
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

    /// A hosted view drawn into a bitmap by AppKit itself, off the screen.
    @MainActor static func render(_ view: NSView, to url: URL) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
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
    @MainActor static func trigger(_ identifier: String, in pane: ConversationPaneTests.Pane) -> PiPopoverTriggerButton? {
        ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted).first { $0.accessibilityIdentifier() == identifier }
    }
    /// A press where the reader would press: the window must deliver a click
    /// at the pill's centre to its press target, which then takes it.
    @MainActor static func click(_ button: PiPopoverTriggerButton, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        XCTAssertTrue(window.contentView?.superview?.hitTest(center) === button,
                      "A click at the pill's centre lands on its press target", file: file, line: line)
        button.performClick(nil)
    }
    @MainActor static func popoverWindow(_ presenter: PiPopoverPresenter) -> NSWindow? {
        presenter.popover?.contentViewController?.view.window
    }
    @MainActor static func escape(_ window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(event)
    }
    /// The popover is on the screen whole, and what it cannot show at once
    /// scrolls inside it rather than being cut off.
    @MainActor static func assertFitsOnScreen(_ presenter: PiPopoverPresenter, anchoredIn window: NSWindow, _ what: String,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let popover = try XCTUnwrap(popoverWindow(presenter), "\(what): no popover window", file: file, line: line)
        let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(popover.frame),
                      "\(what): the popover \(popover.frame) leaves the screen's visible frame \(visible)", file: file, line: line)
        let content = try XCTUnwrap(popover.contentView)
        let host = try XCTUnwrap(presenter.popover?.contentViewController?.view)
        XCTAssertLessThanOrEqual(host.frame.height, PiPopoverPanel.maximumHeight + 0.5, "\(what): taller than the popover's ceiling", file: file, line: line)
        let scroll = try XCTUnwrap(ConversationPaneTests.views(NSScrollView.self, in: content).max { $0.frame.height < $1.frame.height },
                                   "\(what): the page is not in a scroll view", file: file, line: line)
        let scrollFrame = scroll.convert(scroll.bounds, to: nil), hostFrame = host.convert(host.bounds, to: nil)
        XCTAssertTrue(hostFrame.insetBy(dx: -0.5, dy: -0.5).contains(scrollFrame), "\(what): the scrolling page overhangs the popover", file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5, "\(what): the page is wider than the popover", file: file, line: line)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 120, "\(what): too little of the page shows", file: file, line: line)
    }

    /// Both pills of a real pane, pressed where the reader presses: each opens
    /// its popover with its charts built from the archive, one at a time, and
    /// Escape closes it.
    @MainActor func testEachPillOpensItsChartsOneAtATimeAndEscapeClosesThem() async throws {
        let pane = try await Self.seededPane(); defer { pane.close() }
        let store = SessionStatsStore.shared(archive: pane.model.traces, sessionID: pane.session.id)
        let time = try XCTUnwrap(Self.trigger("session-stats-time", in: pane), "The turns · steps · tok/s pill is there")
        let usage = try XCTUnwrap(Self.trigger("session-stats-usage", in: pane), "The tokens · cache · cost pill is there")
        XCTAssertEqual(store.reads, 0, "Nothing is read until a popover opens")
        SessionStatsRenderCount.reset()

        Self.click(time, in: pane.window)
        try await Self.waitFor("The session statistics popover did not open", pane: pane) { store.timePresenter.isShown }
        XCTAssertTrue(store.time.historyLoaded, "The popover opens whole: its charts were ready when it appeared")
        try await Self.waitFor("The session statistics popover did not draw its charts", pane: pane) {
            store.timePresenter.popover?.isShown == true && SessionStatsRenderCount.marks > 0
        }
        await pane.settle(6)
        XCTAssertEqual(store.time.timeline?.rows.count, 12, "One row per request the archive holds")
        XCTAssertEqual(Array(store.time.hero.map(\.value).prefix(2)), ["\(pane.session.footer.gateway.turnCount ?? 0)", "12"])
        XCTAssertNotNil(store.time.speed); XCTAssertEqual(store.time.models.count, 2, "Two models, so the by-model rows")
        XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.marks, 2, "The timeline and the speed chart drew their marks")
        XCTAssertEqual(store.reads, 1)
        try Self.assertFitsOnScreen(store.timePresenter, anchoredIn: pane.window, "Session statistics")

        // The other pill: the first popover gives way to it.
        Self.click(usage, in: pane.window)
        try await Self.waitFor("The token usage popover did not open", pane: pane) { store.tokenPresenter.popover?.isShown == true && store.tokens.historyLoaded }
        await pane.settle(6)
        XCTAssertFalse(store.timePresenter.isShown, "One popover at a time")
        XCTAssertNotNil(store.tokens.composition); XCTAssertNotNil(store.tokens.perRequest); XCTAssertNotNil(store.tokens.cost)
        XCTAssertEqual(store.reads, 1, "The same session's history serves both popovers")
        try Self.assertFitsOnScreen(store.tokenPresenter, anchoredIn: pane.window, "Token usage")

        // Escape closes it.
        try Self.escape(try XCTUnwrap(Self.popoverWindow(store.tokenPresenter)))
        try await Self.waitFor("Escape did not close the token usage popover", pane: pane) { !store.tokenPresenter.isShown }

        // So does a click anywhere else: here, in the conversation above the composer.
        Self.click(usage, in: pane.window)
        try await Self.waitFor("The token usage popover did not reopen", pane: pane) { store.tokenPresenter.isShown }
        // Posted to the application's queue: AppKit's transient popovers watch
        // the events the run loop takes from it.
        let elsewhere = NSPoint(x: pane.window.frame.width / 2, y: pane.window.frame.height - 120)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: elsewhere, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: pane.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                                                         pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: false)
        }
        try await Self.waitFor("A click outside did not close the token usage popover", pane: pane) { !store.tokenPresenter.isShown }

        // A press on an open pill closes it rather than reopening it.
        Self.click(time, in: pane.window)
        try await Self.waitFor("The session statistics popover did not reopen", pane: pane) { store.timePresenter.isShown }
        XCTAssertEqual(store.reads, 1, "Reopening on the same figures reads nothing")
        Self.click(time, in: pane.window)
        await pane.settle(4)
        XCTAssertFalse(store.timePresenter.isShown, "The pill closes its own popover")
    }

    /// At the window's smallest size, high on the screen where the room above
    /// the pills is shortest, and low where it is longest: the popover stays on
    /// the screen and scrolls inside itself.
    @MainActor func testThePopoversFitOnScreenAtTheSmallestWindow() async throws {
        let pane = try await Self.seededPane(requests: 40, width: 620, height: 600); defer { pane.close() }
        let store = SessionStatsStore.shared(archive: pane.model.traces, sessionID: pane.session.id)
        let visible = try XCTUnwrap(pane.window.screen ?? NSScreen.main).visibleFrame
        for (place, origin) in [("high", NSPoint(x: visible.minX + 60, y: visible.maxY - pane.window.frame.height)),
                                ("low", NSPoint(x: visible.minX + 60, y: visible.minY))] {
            pane.window.setFrameOrigin(origin)
            await pane.settle(6)
            for (name, identifier, presenter) in [("Session statistics", "session-stats-time", store.timePresenter),
                                                  ("Token usage", "session-stats-usage", store.tokenPresenter)] {
                let pill = try XCTUnwrap(Self.trigger(identifier, in: pane))
                Self.click(pill, in: pane.window)
                try await Self.waitFor("\(name) did not open with the window \(place) on the screen", pane: pane) {
                    presenter.popover?.isShown == true && store.time.historyLoaded
                }
                await pane.settle(8)
                try Self.assertFitsOnScreen(presenter, anchoredIn: pane.window, "\(name), window \(place)")
                let height = Self.popoverWindow(presenter)?.frame.height ?? 0
                print(String(format: "PERF %@ at a 620x600 window %@ on the screen: popover %.0f pt tall", name, place, height))
                presenter.close()
                await pane.settle(3)
            }
        }
    }

    /// A turn that ends while a popover is open moves the footer's figures;
    /// the popover reads the history again and draws the new request.
    @MainActor func testAnOpenPopoverFollowsARequestThatSettles() async throws {
        let pane = try await Self.seededPane(); defer { pane.close() }
        let store = SessionStatsStore.shared(archive: pane.model.traces, sessionID: pane.session.id)
        let time = try XCTUnwrap(Self.trigger("session-stats-time", in: pane))
        Self.click(time, in: pane.window)
        try await Self.waitFor("The popover did not open", pane: pane) { store.time.timeline?.rows.count == 12 }
        XCTAssertEqual(store.reads, 1)
        let next = SessionStatsFixture.request(13, turn: "t4", model: "gpt-5.4-mini", ttft: 450, stream: 2_000, input: 40_000, cached: 36_000, output: 420)
        try await Self.record(next, in: pane)
        try await Self.refreshFooter(pane)
        try await Self.waitFor("The open popover did not follow the settled request", pane: pane) { store.time.timeline?.rows.count == 13 }
        XCTAssertEqual(store.reads, 2, "One more read, for the new request")
        XCTAssertEqual(store.time.hero[1].value, "13")
        XCTAssertTrue(store.timePresenter.isShown, "The popover stays open while it refreshes")
        store.timePresenter.close()
    }

    /// A narrow pane lays its footer out again when a run starts and when it
    /// ends: the run line takes its own row. An open popover must survive
    /// that and still follow the run, which is exactly when it refreshes.
    @MainActor func testAnOpenPopoverSurvivesTheFooterReflowingAroundARun() async throws {
        for width in [900.0, 520.0] {
            let pane = try await Self.seededPane(width: width); defer { pane.close() }
            let store = SessionStatsStore.shared(archive: pane.model.traces, sessionID: pane.session.id)
            let time = try XCTUnwrap(Self.trigger("session-stats-time", in: pane))
            Self.click(time, in: pane.window)
            try await Self.waitFor("The popover did not open at \(width) points", pane: pane) { store.time.timeline?.rows.count == 12 }
            let before = Set(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted).map(ObjectIdentifier.init))
            pane.session.state = "running"
            await pane.settle(12)
            XCTAssertTrue(store.timePresenter.isShown, "At \(width) points the popover stays open when the run starts")
            let next = SessionStatsFixture.request(13, turn: "t4", ttft: 450, stream: 2_000, input: 40_000, cached: 36_000, output: 420)
            try await Self.record(next, in: pane)
            pane.session.state = "idle"
            try await Self.refreshFooter(pane)
            try await Self.waitFor("At \(width) points the popover did not follow the run's last request", pane: pane) { store.time.timeline?.rows.count == 13 }
            await pane.settle(12)
            let after = Set(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted).map(ObjectIdentifier.init))
            print("PERF footer reflow at \(Int(width)) points: pill press targets \(before == after ? "kept" : "rebuilt") across the run")
            XCTAssertTrue(store.timePresenter.isShown, "At \(width) points the popover stays open when the run ends")
            if let popover = Self.popoverWindow(store.timePresenter) {
                XCTAssertTrue((pane.window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: -1, dy: -1).contains(popover.frame) ?? false)
            }
            store.timePresenter.close()
        }
    }

    /// Moving the pointer over every chart of both popovers redraws the rule,
    /// the band and the caption under the pointer — never a chart's marks and
    /// never the page around them.
    @MainActor func testHoveringTheChartsRedrawsOnlyWhatFollowsThePointer() async throws {
        let pane = try await Self.seededPane(); defer { pane.close() }
        let store = SessionStatsStore.shared(archive: pane.model.traces, sessionID: pane.session.id)
        for (name, identifier, presenter, selections) in [
            ("Session statistics", "session-stats-time", store.timePresenter, [store.timelineSelection, store.speedSelection]),
            ("Token usage", "session-stats-usage", store.tokenPresenter, [store.tokenSelection, store.costSelection]),
        ] {
            let pill = try XCTUnwrap(Self.trigger(identifier, in: pane))
            SessionStatsRenderCount.reset()
            let opened = ProcessInfo.processInfo.systemUptime
            Self.click(pill, in: pane.window)
            try await Self.waitFor("\(name) did not draw its charts", pane: pane) { presenter.popover?.isShown == true && store.time.historyLoaded && SessionStatsRenderCount.marks >= 2 }
            let openMs = (ProcessInfo.processInfo.systemUptime - opened) * 1_000
            await pane.settle(8)
            let open = (panels: SessionStatsRenderCount.panels, marks: SessionStatsRenderCount.marks)
            SessionStatsRenderCount.reset()
            // What a pointer moving across the charts writes, one item at a
            // time. (A test host is not the active app, so SwiftUI's
            // continuous hover does not answer synthetic mouse moves.)
            var steps = 0
            for selection in selections {
                for index in [0, 1, 2, 4, 7, 9, 3, nil] { selection.select(index); steps += 1; await pane.settle(1) }
            }
            await pane.settle(4)
            print(String(format: "PERF %@: opened in %.0f ms (%d page builds, %d chart mark builds); %d hover steps redrew %d pointer marks and %d captions, rebuilt %d pages and %d chart marks",
                         name, openMs, open.panels, open.marks, steps, SessionStatsRenderCount.pointers, SessionStatsRenderCount.captions,
                         SessionStatsRenderCount.panels, SessionStatsRenderCount.marks))
            XCTAssertEqual(SessionStatsRenderCount.marks, 0, "\(name): hover never rebuilds a chart's marks")
            XCTAssertEqual(SessionStatsRenderCount.panels, 0, "\(name): nor the page around the charts")
            XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.pointers, selections.count, "\(name): the rule or band follows the pointer")
            XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.captions, selections.count, "\(name): and so does the caption")
            presenter.close()
            await pane.settle(3)
        }
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

    // MARK: The store

    /// The archive as the store sees it: every read counted, and failing on request.
    actor Reads {
        private(set) var count = 0
        var history: SessionStatsHistory
        var failing = false
        init(_ history: SessionStatsHistory) { self.history = history }
        func next() throws -> SessionStatsHistory {
            count += 1
            if failing { throw CaptureFailure.unavailable }
            return history
        }
        func fail() { failing = true }
    }
    private let scope = SessionUsageScope(sessionID: "stats", workspaceID: "project")

    /// Nothing is read until a popover opens; reopening on figures that have
    /// not moved reads nothing and shows what was built; a closed popover does
    /// not follow the footer; new helper clocks rebuild without a read.
    @MainActor func testTheStoreReadsOnlyWhenAPopoverOpensAndKeepsWhatItBuilt() async throws {
        let history = SessionStatsFixture.session()
        let reads = Reads(history)
        let store = SessionStatsStore(load: { _ in try await reads.next() })
        let inputs = SessionStatsFixture.inputs(history)
        var count = await reads.count
        XCTAssertEqual(count, 0)
        store.open(scope: scope, inputs: inputs)
        XCTAssertFalse(store.time.historyLoaded, "The figures go up at once, the charts follow the read")
        XCTAssertEqual(store.time.hero, SessionTimeCharts(inputs: inputs, history: nil).hero)
        try await Self.waitFor("The history was not read") { store.time.historyLoaded && store.tokens.historyLoaded && !store.loading }
        count = await reads.count
        XCTAssertEqual(count, 1)
        let built = store.builds

        store.open(scope: scope, inputs: inputs)
        try await Task.sleep(for: .milliseconds(250))
        count = await reads.count
        XCTAssertEqual(count, 1, "Reopening on unchanged figures reads nothing")
        XCTAssertEqual(store.builds, built, "and builds nothing")

        var moved = inputs
        moved.gateway.requests += 1
        store.footerChanged(moved)
        try await Task.sleep(for: .milliseconds(250))
        count = await reads.count
        XCTAssertEqual(count, 1, "A closed popover does not follow the footer")

        store.open(scope: scope, inputs: moved)
        try await Self.waitFor("Opening on moved figures did not read again") { store.time.hero[1].value == "19" }
        count = await reads.count
        XCTAssertEqual(count, 2)

        var clocks = moved
        clocks.work = WorkSplit(timing: ["sessionModelMs": .number(99_000), "sessionToolMs": .number(1_000)])
        store.open(scope: scope, inputs: clocks)
        try await Self.waitFor("New helper clocks did not rebuild the figures") { store.time.details[1].value == workDuration(99_000) }
        count = await reads.count
        XCTAssertEqual(count, 2, "The helper's clocks are not in the archive: nothing is read for them")
    }

    /// A burst of footer updates while a popover is open reads once more
    /// after the read in flight, not once per update.
    @MainActor func testABurstOfFooterUpdatesWhileOpenIsOneMoreRead() async throws {
        let history = SessionStatsFixture.session()
        let reads = Reads(history)
        let store = SessionStatsStore(load: { _ in try await reads.next() })
        let inputs = SessionStatsFixture.inputs(history)
        store.open(scope: scope, inputs: inputs)
        try await Self.waitFor("The history was not read") { store.time.historyLoaded && !store.loading }
        let (window, anchor) = Self.anchoredWindow(); defer { window.orderOut(nil); window.contentView = nil; window.close() }
        store.timePresenter.show(from: anchor, width: PiPopoverPanel.width, maximumHeight: PiPopoverPanel.maximumHeight, animates: false) {
            AnyView(SessionTimePopover(store: store, openLedger: {}))
        }
        defer { store.timePresenter.close() }
        XCTAssertTrue(store.isShowing)
        for step in 1...5 {
            var moved = inputs
            moved.gateway.requests += step
            store.footerChanged(moved)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Self.waitFor("The burst was not read") { store.time.hero[1].value == "23" && !store.loading }
        try await Task.sleep(for: .milliseconds(400))
        let count = await reads.count
        XCTAssertEqual(count, 3, "The open read, the burst's first, and one more for what came during it")
    }

    /// A read that fails leaves the figures up and says what went wrong in
    /// the place of the charts.
    @MainActor func testAFailedReadKeepsTheFiguresAndSaysSo() async throws {
        let history = SessionStatsFixture.session()
        let reads = Reads(history)
        await reads.fail()
        let store = SessionStatsStore(load: { _ in try await reads.next() })
        store.open(scope: scope, inputs: SessionStatsFixture.inputs(history))
        try await Self.waitFor("The failure was not reported") { store.failure != nil }
        XCTAssertFalse(store.loading)
        XCTAssertFalse(store.time.historyLoaded)
        XCTAssertEqual(store.time.hero.map(\.id), ["turns", "steps", "speed"], "The footer's figures stay")
        XCTAssertTrue(store.failure?.hasPrefix("This session's requests could not be read") == true, store.failure ?? "")
    }

    /// A session of two thousand requests: both popovers' series are built
    /// in one pass, bounded to what a popover can show, and cheaply.
    @MainActor func testTheChartsOfALongSessionAreBoundedAndBuildOnce() async throws {
        let history = SessionStatsFixture.session(requests: 2_000)
        let inputs = SessionStatsFixture.inputs(history)
        let started = ProcessInfo.processInfo.systemUptime
        let time = SessionTimeCharts(inputs: inputs, history: history)
        let tokens = SessionTokenCharts(inputs: inputs, history: history)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF building both popovers' series for %d requests: %.1f ms", history.requests.count, elapsed * 1_000))
        XCTAssertEqual(time.timeline?.rows.count, SessionRequestTimeline.maximumRows)
        XCTAssertLessThanOrEqual(time.speed?.points.count ?? .max, SessionSpeedSeries.maximumPoints)
        XCTAssertLessThanOrEqual(tokens.perRequest?.bars.count ?? .max, SessionTokenBars.maximumBars)
        XCTAssertLessThanOrEqual(tokens.cost?.points.count ?? .max, SessionCostSeries.maximumPoints + 1)
        XCTAssertLessThan(elapsed, releaseBudget(0.06), "Building the series of 2,000 requests took \(elapsed * 1_000) ms")
    }

    /// Opt-in (PI_PERF_STATS=1): reading 1,000 retained requests of one
    /// session from a real archive, as a popover does when it opens.
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
        print(String(format: "PERF reading 1,000 retained requests for the popovers: best %.1f ms, median %.1f ms", times.min() ?? 0, times.sorted()[2]))
        try await archive.close()
    }

    // MARK: Preview

    /// Opt-in: the two popovers over a synthetic session in both appearances,
    /// as PNGs in PI_APP_STATS_PREVIEW. Nothing here reads the vault or a gateway.
    @MainActor func testRenderStatsPopoverPreviews() async throws {
        guard let path = testEnvironment("PI_APP_STATS_PREVIEW") else { throw XCTSkip("Set PI_APP_STATS_PREVIEW to render the popover previews") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { NSApp.appearance = nil }
        let scenes: [(String, SessionStatsHistory)] = [
            ("session", SessionStatsFixture.session()),
            ("long", SessionStatsFixture.session(requests: 64)),
            ("one", SessionStatsHistory(requests: [SessionStatsFixture.request(1, reasoning: 80)])),
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (scene, history) in scenes {
                for kind in ["time", "tokens"] {
                    let store = SessionStatsStore(load: { _ in history })
                    store.open(scope: SessionUsageScope(sessionID: "preview", workspaceID: "preview"), inputs: SessionStatsFixture.inputs(history))
                    try await Self.waitFor("The preview history did not load") { store.time.historyLoaded && store.tokens.historyLoaded }
                    let (window, anchor) = Self.anchoredWindow(height: 820)
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    let presenter = kind == "time" ? store.timePresenter : store.tokenPresenter
                    presenter.show(from: anchor, width: PiPopoverPanel.width, maximumHeight: PiPopoverPanel.maximumHeight, animates: false) {
                        kind == "time" ? AnyView(SessionTimePopover(store: store, openLedger: {})) : AnyView(SessionTokenPopover(store: store, openLedger: {}))
                    }
                    try await Task.sleep(for: .milliseconds(700))
                    try Self.capture(window, to: folder.appendingPathComponent("\(kind)-\(scene)-\(appearanceName).png"))
                    presenter.close()
                    // The whole page, unscrolled, for review.
                    let page = NSHostingView(rootView: (kind == "time" ? AnyView(SessionTimePopover(store: store, openLedger: {}))
                                                        : AnyView(SessionTokenPopover(store: store, openLedger: {})))
                        .frame(width: PiPopoverPanel.width).fixedSize(horizontal: false, vertical: true).background(Color.piSurface))
                    let size = page.fittingSize
                    let sheet = NSWindow(contentRect: NSRect(x: -4_000, y: 60, width: size.width, height: min(size.height, 2_400)), styleMask: [.borderless], backing: .buffered, defer: false)
                    sheet.isReleasedWhenClosed = false; sheet.contentView = page; sheet.orderFront(nil)
                    defer { sheet.orderOut(nil); sheet.contentView = nil; sheet.close() }
                    try await Task.sleep(for: .milliseconds(500))
                    page.layoutSubtreeIfNeeded(); sheet.displayIfNeeded()
                    try Self.render(page, to: folder.appendingPathComponent("\(kind)-\(scene)-\(appearanceName)-page.png"))
                }
            }
        }
    }
}
