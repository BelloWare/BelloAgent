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

final class SessionUsageTests: XCTestCase {
    private let until = Date(timeIntervalSince1970: 1_000_000)
    private let scope = SessionUsageScope(sessionID: "session-a", workspaceID: "project-a")

    @MainActor private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
        throw NSError(domain: "SessionUsageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

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

    /// Hovering a timing chart moved the selected request, which the page
    /// owned: the whole Session info window, ledger and tables included,
    /// re-rendered at every pointer step. Then the section around the charts
    /// did, and with it all four charts rebuilt their marks and formatted
    /// every point's accessibility strings again, to move a one-point rule.
    /// Only each chart's rule and the request caption watch the pointer now.
    @MainActor func testHoveringATimingChartRedrawsOnlyTheChartsAndTheirCaption() async throws {
        let controller = SessionUsageController(scope: scope, load: { _, _, offset in self.pagedSnapshot(offset: offset) }, interval: .seconds(60))
        var samples: [SessionTimingSample] = []
        for index in 1...16 {
            let step = Double(index)
            samples.append(SessionTimingSample(id: "r\(index)", wall: until.addingTimeInterval(step), ttftMilliseconds: 100 * step, streamingMilliseconds: 1_000,
                                               outputTokens: 40 * step, costUSD: 0.001 * step, requestMilliseconds: 1_500))
        }
        controller.timing = SessionTimingHistory(samples: samples)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("Session info did not load") { controller.snapshot != nil }
        SessionTimingRenderCount.reset()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let hosted = NSHostingView(rootView: SessionUsageView(title: "Session", controller: controller))
        window.contentView = hosted; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
        // The charts sit below the ledger and the models table: scroll the
        // page to its end, as a reader does to reach them. A chart off screen
        // never lays out its overlay, so it would have no rule to redraw.
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for child in view.subviews { found += scrollViews(child) }
            return found
        }
        let page = try XCTUnwrap(scrollViews(hosted).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let document = try XCTUnwrap(page.documentView)
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - page.contentView.bounds.height) : 0))
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        XCTAssertGreaterThanOrEqual(SessionTimingRenderCount.marks, SessionTimingMetric.allCases.count, "The four charts are built")
        XCTAssertGreaterThanOrEqual(SessionTimingRenderCount.rules, SessionTimingMetric.allCases.count, "and on screen, each with its rule")
        SessionUsageRenderCount.reset(); SessionTimingRenderCount.reset()
        // What a pointer moving over the charts writes, one request at a time.
        // (A test host is not the active app: SwiftUI's continuous hover does
        // not answer synthetic events sent to the window, the application
        // queue, the hosting view or its tracking-area owners.)
        for request in [1, 2, 3, 5, 8, 13, 16, nil] {
            controller.timingSelection.request = request
            try await Task.sleep(for: .milliseconds(10)); hosted.layoutSubtreeIfNeeded()
        }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded() }
        print("PERF 8 hover steps re-rendered the Session info window \(SessionUsageRenderCount.builds) times and its timing section \(SessionUsageRenderCount.timingBuilds) times, rebuilt the charts' marks \(SessionTimingRenderCount.marks) times, drew their rules \(SessionTimingRenderCount.rules) times and the request caption \(SessionTimingRenderCount.captions) times")
        XCTAssertEqual(SessionUsageRenderCount.builds, 0, "Hover never redraws the page, its ledger or its tables")
        XCTAssertEqual(SessionUsageRenderCount.timingBuilds, 0, "nor the section around the charts")
        XCTAssertEqual(SessionTimingRenderCount.marks, 0, "nor any chart's marks and their per-point accessibility strings")
        XCTAssertGreaterThanOrEqual(SessionTimingRenderCount.rules, SessionTimingMetric.allCases.count, "Each chart's rule follows the hover")
        XCTAssertGreaterThan(SessionTimingRenderCount.captions, 0, "and so does the request caption")
    }

    /// The caption under the Session info charts existed only while the
    /// pointer was on a chart: the section grew by a line on every hover and
    /// everything below it — the token mix, the token and cache cards — moved
    /// down and back. The line is always there now, reading the latest
    /// request until a chart is hovered, so nothing below ever moves.
    @MainActor func testHoveringATimingChartMovesNothingBelowIt() async throws {
        var samples: [SessionTimingSample] = []
        for index in 1...16 {
            let step = Double(index)
            samples.append(SessionTimingSample(id: "r\(index)", wall: until.addingTimeInterval(step), ttftMilliseconds: 100 * step, streamingMilliseconds: 1_000,
                                               outputTokens: 40 * step, costUSD: 0.001 * step, requestMilliseconds: 1_500))
        }
        let history = SessionTimingHistory(samples: samples)
        // The 16th request: 1,600 ms to its first token, then 640 tokens in 1 s,
        // the 639 after the first decoded at 639 tok/s.
        let latest = SessionUsagePresentation.requestCaption(selected: nil, in: history)
        XCTAssertTrue(latest.hasPrefix("Latest · ") && latest.contains("1600 ms TTFT") && latest.contains("639 tok/s decode") && latest.contains("640 tokens out"), latest)
        XCTAssertTrue(SessionUsagePresentation.requestCaption(selected: 3, in: history).hasPrefix("Request 3 · "))
        XCTAssertEqual(SessionUsagePresentation.requestCaption(selected: 99, in: history), latest, "A request no longer listed reads as the latest")

        // The section, with a row below it whose frame AppKit reports.
        let selection = SessionTimingSelection()
        let below = NSView()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 760, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        // The test is the pointer: wherever the real one rests, it must not
        // hover a chart and select a request of its own.
        let hosted = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            SessionTimingSection(history: history, series: SessionTimingSeries.all(history), selection: selection)
            RowBelowTheCaption(view: below).frame(height: 24)
            Spacer(minLength: 0)
        }.padding(16).frame(width: 760, height: 900, alignment: .topLeading).background(Color.piContent).allowsHitTesting(false))
        window.contentView = hosted; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func settle() async throws {
            for _ in 0..<8 { try await Task.sleep(for: .milliseconds(20)); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        }
        try await settle()
        let idle = below.convert(below.bounds, to: nil)
        XCTAssertGreaterThan(idle.height, 0, "The row below is laid out")
        let rendered = try await SessionTimingTests.recognizedText(in: window, filename: "session-timing-caption-idle.jpg")
        XCTAssertNotNil(rendered.range(of: #"1600 ms ttft\W+639 tok/s decode"#, options: .regularExpression),
                        "Before any hover the caption reads the latest request. OCR: \(rendered)")
        for request in [3, 16, 1, nil] {
            selection.select(request)
            try await settle()
            XCTAssertEqual(below.convert(below.bounds, to: nil), idle, "hovering request \(request.map(String.init) ?? "none") moved the row below the caption")
        }

        // And the whole Session info page keeps its height.
        let controller = SessionUsageController(scope: scope, load: { _, _, offset in self.pagedSnapshot(offset: offset) }, interval: .seconds(60))
        controller.timing = history
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor("Session info did not load") { controller.snapshot != nil }
        let pageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        let pageView = NSHostingView(rootView: SessionUsageView(title: "Session", controller: controller).allowsHitTesting(false))
        pageWindow.contentView = pageView; pageWindow.orderFront(nil)
        defer { pageWindow.contentView = nil; pageWindow.close() }
        func settlePage() async throws {
            for _ in 0..<8 { try await Task.sleep(for: .milliseconds(20)); pageView.layoutSubtreeIfNeeded(); pageWindow.displayIfNeeded() }
        }
        try await settlePage()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for child in view.subviews { found += scrollViews(child) }
            return found
        }
        let page = try XCTUnwrap(scrollViews(pageView).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let document = try XCTUnwrap(page.documentView)
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - page.contentView.bounds.height) : 0))
        try await settlePage()
        let height = document.frame.height
        for request in [3, 16, 1, nil] {
            controller.timingSelection.select(request)
            try await settlePage()
            XCTAssertEqual(document.frame.height, height, "hovering request \(request.map(String.init) ?? "none") changed the page's height")
        }
    }

    /// The hover rule is drawn over the chart from its own x scale, no longer
    /// as a mark, so a hover rebuilds no marks. It must still stand on the
    /// request under the pointer, come with the selection and go with it.
    @MainActor func testTheHoverRuleStandsOnTheSelectedRequest() async throws {
        // Sixteen requests of which only the eighth reported a first token:
        // the TTFT chart draws one point, at request 8.
        let samples = (1...16).map { index in
            SessionTimingSample(id: "r\(index)", wall: until.addingTimeInterval(Double(index)), ttftMilliseconds: index == 8 ? 400 : nil,
                                streamingMilliseconds: 1_000, outputTokens: 100, requestMilliseconds: 1_500)
        }
        let series = SessionTimingSeries(history: SessionTimingHistory(samples: samples), metric: .ttft)
        XCTAssertEqual(series.points.map(\.index), [8]); XCTAssertEqual(series.requests, 16)
        let selection = SessionTimingSelection()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        // The test is the pointer: the real one must not hover the chart.
        window.contentView = NSHostingView(rootView: SessionTimingChart(series: series, selection: selection, height: 120)
            .padding(12).frame(width: 420, height: 200, alignment: .topLeading).background(Color.white).allowsHitTesting(false))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        typealias Pixels = (width: Int, height: Int, bytes: [UInt8])
        /// The window as the window server shows it, as 8-bit RGBA rows.
        func capture() async throws -> Pixels {
            try await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
            let image = try XCTUnwrap(unsafeBitCast(symbol, to: ListImage.self)(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                                                                 CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            XCTAssertTrue(drawn)
            return (image.width, image.height, bytes)
        }
        /// Columns holding a pixel that differs between two captures.
        func changedColumns(_ a: Pixels, _ b: Pixels) -> [Int] {
            guard a.width == b.width, a.height == b.height else { return Array(0..<max(a.width, b.width)) }
            return (0..<a.width).filter { x in
                (0..<a.height).contains { y in
                    let i = (y * a.width + x) * 4
                    return (0..<3).contains { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) > 24 }
                }
            }
        }
        func center(_ columns: [Int]) -> Double { Double(columns.reduce(0, +)) / Double(max(1, columns.count)) }
        let idle = try await capture()
        // The point is the only saturated ink: axis labels and grid are grey.
        let pointColumns = (0..<idle.width).filter { x in
            (0..<idle.height).contains { y in
                let i = (y * idle.width + x) * 4
                let channels = (0..<3).map { Int(idle.bytes[i + $0]) }
                return channels.max()! - channels.min()! > 60
            }
        }
        let scale = Double(window.backingScaleFactor)
        XCTAssertFalse(pointColumns.isEmpty, "The chart drew its one point")
        selection.select(8)
        let hovered = try await capture()
        let rule = changedColumns(idle, hovered)
        XCTAssertFalse(rule.isEmpty, "Selecting a request draws its rule")
        XCTAssertLessThanOrEqual(Double((rule.max() ?? 0) - (rule.min() ?? 0) + 1), 3 * scale, "Only a one-point rule appeared: columns \(rule)")
        XCTAssertEqual(center(rule), center(pointColumns), accuracy: 1.5 * scale, "The rule stands on request 8's point")
        selection.select(nil)
        let cleared = try await capture()
        XCTAssertEqual(changedColumns(idle, cleared), [], "Clearing the selection takes the rule away and leaves the chart as it was")
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

    @MainActor func testNativeUsageWindowReusesScopeAndKeepsOtherSessionsIndependent() async throws {
        let windows = SessionUsageWindows(), owner = NSObject(), otherOwner = NSObject()
        defer { windows.closeAll(owner: owner); windows.closeAll(owner: otherOwner) }
        let first = windows.show(owner: owner, scope: scope, title: "First session", load: { _, _, _ in self.snapshot(requests: 3) })
        try await waitFor("The native usage window did not read its session") { first.usage.snapshot != nil }
        let window = try XCTUnwrap(first.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(window.sheetParent, "Session usage must be an independent window")
        for style in [NSWindow.StyleMask.titled, .closable, .miniaturizable, .resizable] { XCTAssertTrue(window.styleMask.contains(style)) }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { XCTAssertNotNil(window.standardWindowButton(kind)) }
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 720)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 560)
        // The app's own chrome replaces the system title bar, and the title still names the window.
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden); XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.title.hasSuffix("Session Info"))
        window.setContentSize(NSSize(width: 1_020, height: 780))
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 1_020, accuracy: 0.5)

        let again = windows.show(owner: owner, scope: scope, title: "Renamed session", load: { _, _, _ in self.snapshot(requests: 999) }, initialBreakdown: .costs)
        XCTAssertTrue(first === again, "Header and footer must focus the same session window")
        XCTAssertEqual(again.usage.breakdown, .costs)
        XCTAssertEqual(again.sessionTitle.value, "Renamed session")
        XCTAssertEqual(window.title, "Renamed session — Session Info")
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 1_020, accuracy: 0.5, "Reopening must preserve the user's window size")
        XCTAssertEqual(windows.count, 1)

        let otherScope = SessionUsageScope(sessionID: scope.sessionID, workspaceID: "other-project")
        let second = windows.show(owner: owner, scope: otherScope, title: "Other project", load: { _, _, _ in self.snapshot(requests: 7) })
        let third = windows.show(owner: otherOwner, scope: scope, title: "Other archive", load: { _, _, _ in self.snapshot(requests: 8) })
        XCTAssertFalse(second === first); XCTAssertFalse(third === first)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(first.usage.scope, scope)
        XCTAssertTrue(window.isVisible, "Opening another session's usage must retain this window's scope and visibility")
        windows.closeAll(owner: owner)
        XCTAssertTrue(first.isClosed); XCTAssertTrue(second.isClosed); XCTAssertFalse(third.isClosed)
        XCTAssertEqual(windows.count, 1, "Closing an archive must not close another owner's windows")
    }

    @MainActor func testClosingNativeUsageWindowStopsPollingAndRejectsItsLateRead() async throws {
        let windows = SessionUsageWindows(), owner = NSObject(), probe = SessionUsageReadProbe()
        defer { windows.closeAll(owner: owner); probe.cancelPending() }
        let first = windows.show(owner: owner, scope: scope, title: "Pending usage", load: probe.load, interval: .milliseconds(25))
        try await waitFor("Native usage read did not start") { probe.reads.count == 1 }
        first.window?.performClose(nil)
        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(windows.count, 0)
        probe.finish(0, with: snapshot(requests: 999))
        try await waitFor("The cancelled window read did not finish") { probe.completedCancellation.count == 1 }
        XCTAssertNil(first.usage.snapshot)
        XCTAssertEqual(probe.completedCancellation, [true])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.reads.count, 1)

        let reopened = windows.show(owner: owner, scope: scope, title: "Reopened usage", load: probe.load, interval: .seconds(60))
        XCTAssertFalse(reopened === first)
        try await waitFor("Reopened window did not request current data") { probe.reads.count == 2 }
        probe.finish(1, with: snapshot(requests: 2))
        try await waitFor("Reopened window did not show fresh usage") { reopened.usage.snapshot?.gateway.requests == 2 }
        XCTAssertNil(first.usage.snapshot)
    }

    @MainActor func testOpenWindowKeepsTitleAndUsageLiveAfterChatSelectionChanges() async throws {
        let base = testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-usage-window-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let windows = SessionUsageWindows(), footer = SessionMetrics(), otherFooter = SessionMetrics()
        var first = ChatRecord(id: scope.sessionID, workspaceID: scope.workspaceID, title: "Original title", path: nil, profileID: "fixture-profile")
        let other = ChatRecord(id: "other-chat", workspaceID: scope.workspaceID, title: "Other chat", path: nil, profileID: "fixture-profile")
        model.chats = [first, other]; model.selectedID = first.id
        var reads: [SessionUsageScope] = []
        let window = windows.show(owner: model, scope: scope, title: first.title, load: { scope, _, _ in
            reads.append(scope)
            return self.snapshot(requests: reads.count)
        }, interval: .seconds(60))
        window.observe(model: model, footer: footer)
        defer { windows.closeAll(owner: model); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await waitFor("Initial usage was not shown") { window.usage.snapshot?.gateway.requests == 1 }
        model.selectedID = other.id
        first.title = "New session title"; model.chats = [first, other]
        XCTAssertEqual(window.window?.title, "New session title — Session Info")
        XCTAssertEqual(window.sessionTitle.value, first.title)
        XCTAssertEqual(window.usage.scope, scope)
        footer.gateway = GatewayTotals(requests: 5)
        try await waitFor("Offscreen session metrics did not refresh its usage window") { window.usage.snapshot?.gateway.requests == 2 }
        XCTAssertEqual(reads, [scope, scope])
        otherFooter.gateway = GatewayTotals(requests: 20)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reads.count, 2)
        window.close()
        footer.gateway = GatewayTotals(requests: 6)
        first.title = "Changed after closing"; model.chats = [first, other]
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reads.count, 2, "Closed windows must release their metric subscriptions")
        XCTAssertEqual(window.sessionTitle.value, "New session title")
        await model.store?.close(); try await model.traces.close()
    }

    /// Optional synthetic previews of the actual native resizable window. These
    /// never open the real vault, archive, or gateway.
    @MainActor func testSessionUsageSyntheticModelCostAndMissingValuePreviews() async throws {
        guard let path = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") else {
            throw XCTSkip("Set PI_APP_USAGE_CAPTURE_ROOT to capture native session-usage previews")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let known = visualSnapshot(), unknown = visualSnapshot(costs: false), zero = visualSnapshot(zero: true)
        let fixtures: [(String, SessionUsageBreakdown, MenuBarSnapshot, NSAppearance.Name)] = [
            ("session-models-light", .models, known, .aqua),
            ("session-costs-dark", .costs, known, .darkAqua),
            ("session-costs-unreported", .costs, unknown, .aqua),
            ("session-costs-zero", .costs, zero, .aqua),
        ]
        XCTAssertNil(unknown.gateway.costUSD)
        XCTAssertTrue(unknown.models.allSatisfy { $0.costShare == nil && $0.resolvedModel == nil })
        XCTAssertEqual(zero.gateway.costUSD, 0)
        XCTAssertEqual(zero.gateway.costSamples, zero.gateway.requests)
        XCTAssertTrue(zero.models.allSatisfy { $0.costShare == nil }, "A zero total has no defined cost percentage")

        for (name, breakdown, value, appearance) in fixtures {
            var loaded = false
            let controller = SessionUsageWindowController(scope: scope, title: "Refine the release experience", load: { _, _, _ in
                loaded = true
                return value
            })
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance)
            let hosted = try XCTUnwrap(window.contentView)
            defer { controller.close() }
            controller.present(initialBreakdown: breakdown)
            try await waitFor("Synthetic session usage did not load") { loaded }
            // The query completing precedes the next SwiftUI layout/paint pass.
            // Wait only in this opt-in visual test, not in controller regressions.
            try await Task.sleep(for: .milliseconds(180))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            XCTAssertEqual(hosted.bounds.width, 980, accuracy: 0.5)
            XCTAssertTrue(hosted.fittingSize.height.isFinite)
            try capture(window, to: root.appendingPathComponent(name + ".jpg"))
        }
    }

    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        try jpeg.write(to: url, options: .atomic)
    }

    private func visualSnapshot(costs: Bool = true, zero: Bool = false) -> MenuBarSnapshot {
        func totals(requests: Int, cost: Double?, input: Double?, output: Double?, reasoningCost: Double?) -> GatewayTotals {
            var value = GatewayTotals(requests: requests, costSamples: cost == nil ? 0 : requests, costUSD: cost)
            if let input, let output {
                value.tokens = GatewayTokenTotals(input: input, output: output, total: input + output,
                                                  inputSamples: requests, outputSamples: requests, samples: requests,
                                                  reasoning: output * 0.6, reasoningSamples: requests)
                value.cacheHits = requests / 2; value.cacheMisses = requests / 4
                value.cacheUnreported = requests - value.cacheHits - value.cacheMisses
                value.cacheReadTokens = input * 0.4; value.cacheReadSamples = requests
                value.cacheWriteTokens = 0; value.cacheWriteSamples = requests
            } else {
                value.cacheUnreported = requests
            }
            value.reasoningCostUSD = reasoningCost; value.reasoningCostSamples = reasoningCost == nil ? 0 : requests
            return value
        }
        let count = costs && !zero ? 10 : 3
        var total = totals(requests: count, cost: costs ? (zero ? 0 : 0.1) : nil, input: costs ? (zero ? 0 : 18_250) : nil,
                           output: costs ? (zero ? 0 : 5_910) : nil, reasoningCost: costs ? (zero ? 0 : 0.05232) : nil)
        // The session's settled rate: output over 48 s of decoding.
        if costs { total.decodeMilliseconds = 48_000; total.decodeOutputTokens = zero ? 0 : 5_910; total.decodeSamples = count }
        var rows: [MenuBarModelDistribution]
        if costs && !zero {
            rows = [
                MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "openai/gpt-5.4-mini", identityStatus: "reported",
                                         gateway: totals(requests: 7, cost: 0.034, input: 12_350, output: 2_140, reasoningCost: 0.01232), allRequests: 10, costShare: 0.34),
                MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "anthropic/claude-sonnet-4.5", identityStatus: "reported",
                                         gateway: totals(requests: 3, cost: 0.066, input: 5_900, output: 3_770, reasoningCost: 0.04), allRequests: 10, costShare: 0.66),
            ]
        } else {
            rows = [MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: zero ? "openai/gpt-5.4-mini" : nil,
                                             identityStatus: zero ? "reported" : "unreported", gateway: total, allRequests: count)]
        }
        return snapshot(requests: count, models: rows, groups: rows.count, gateway: total)
    }

    private func snapshot(requests: Int = 0, offset: Int = 0, models: [MenuBarModelDistribution] = [], groups: Int = 0, gateway: GatewayTotals? = nil) -> MenuBarSnapshot {
        let totals = gateway ?? GatewayTotals(requests: requests)
        return MenuBarSnapshot(period: .retained, from: until.addingTimeInterval(-3_600), until: until,
                        counts: DashboardCounts(dispatched: requests, completed: requests), gateway: gateway ?? GatewayTotals(requests: requests),
                        workspaces: requests > 0 ? 1 : 0, sessions: requests > 0 ? 1 : 0, compactionRequests: 0,
                        costUnreported: totals.requests - totals.costSamples, costInvalid: 0, costConflicts: 0, models: models, modelGroups: groups, offset: offset)
    }

    private func pagedSnapshot(offset: Int) -> MenuBarSnapshot {
        let models = (offset..<min(offset + MenuBarSnapshot.pageSize, 25)).map { index in
            MenuBarModelDistribution(api: "openai-responses", requestedAlias: "auto-router", resolvedModel: "provider/model-\(index)", identityStatus: "reported", gateway: GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.4), allRequests: 25, costShare: 0.04)
        }
        return snapshot(requests: 25, offset: offset, models: models, groups: 25, gateway: GatewayTotals(requests: 25, costSamples: 25, costUSD: 10))
    }
}

/// A plain AppKit view placed in a SwiftUI layout, so a test can read the
/// frame SwiftUI gave the row it stands for.
private struct RowBelowTheCaption: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension SessionUsageTests {
    /// Session info always opened centred at 980×880: a size and place the
    /// reader chose were gone the next time, and after every relaunch.
    @MainActor func testSessionInfoOpensWhereItWasLastLeft() throws {
        let name = "SessionInfoTests-" + UUID().uuidString, previous = SessionUsageWindowController.frameAutosaveName
        SessionUsageWindowController.frameAutosaveName = name
        defer { SessionUsageWindowController.frameAutosaveName = previous; UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + name) }
        let scope = SessionUsageScope(sessionID: "session-frame", workspaceID: "project-frame")
        let first = SessionUsageWindowController(scope: scope, title: "Frame", load: { _, _, _ in throw CancellationError() })
        let window = try XCTUnwrap(first.window)
        let chosen = NSRect(x: 180, y: 160, width: 820, height: 640)
        window.setFrame(chosen, display: false)
        first.close()
        let second = SessionUsageWindowController(scope: scope, title: "Frame", load: { _, _, _ in throw CancellationError() })
        defer { second.close() }
        XCTAssertEqual(try XCTUnwrap(second.window).frame, chosen, "The next one opens at the size and place the last was left")
    }
}
