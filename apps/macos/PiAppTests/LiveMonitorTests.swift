import XCTest
import SwiftUI
@testable import PiApp

final class LiveMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor func testNativePlotMouseEventsCommitOneZoomHoverAndReset() throws {
        let surface = MonitorChartInteraction.Surface(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = surface
        defer { window.contentView = nil; window.close() }
        surface.plot = CGRect(x: 40, y: 10, width: 380, height: 160)
        let domain = start...start.addingTimeInterval(300)
        surface.domain = domain
        var zoom = MonitorChartZoom(), commits = 0
        var hovered: Date?
        surface.hover = { hovered = $0 }
        surface.drag = { a, b, width, held in zoom.update(startX: a, x: b, width: width, domain: held) }
        surface.finish = { x, y in if zoom.finish(horizontal: x, vertical: y) { commits += 1 } }
        surface.reset = { zoom.reset() }
        func event(_ type: NSEvent.EventType, x: Double, y: Double = 70, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: surface.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        surface.mouseMoved(with: try event(.mouseMoved, x: 230))
        XCTAssertEqual(hovered, start.addingTimeInterval(150))
        surface.mouseDown(with: try event(.leftMouseDown, x: 100))
        for x in stride(from: 120.0, through: 300, by: 20) { surface.mouseDragged(with: try event(.leftMouseDragged, x: x)) }
        XCTAssertEqual(commits, 0, "No history query while the brush moves")
        XCTAssertNotNil(zoom.brush)
        // A sampler tick moves the live domain but the original drag wins.
        surface.domain = start.addingTimeInterval(10)...start.addingTimeInterval(310)
        surface.mouseUp(with: try event(.leftMouseUp, x: 320))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(try XCTUnwrap(zoom.range?.lowerBound).timeIntervalSince(start), 60 / 380.0 * 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(zoom.range?.upperBound).timeIntervalSince(start), 280 / 380.0 * 300, accuracy: 0.001, "Use the final release position even when the last drag event was earlier")
        surface.mouseDown(with: try event(.leftMouseDown, x: 200, clicks: 2))
        XCTAssertNil(zoom.range)
        surface.mouseDown(with: try event(.leftMouseDown, x: 100))
        surface.mouseDragged(with: try event(.leftMouseDragged, x: 105, y: 150))
        surface.mouseUp(with: try event(.leftMouseUp, x: 105, y: 150))
        XCTAssertNil(zoom.range); XCTAssertEqual(commits, 1)
    }
    func testBrushFreezesLiveDomainClampsReverseDragAndRejectsClicksAndScrolls() throws {
        var zoom = MonitorChartZoom()
        let domain = start...start.addingTimeInterval(300)
        zoom.update(startX: 80, x: 20, width: 100, domain: domain)
        zoom.update(startX: 80, x: -10, width: 100, domain: start.addingTimeInterval(20)...start.addingTimeInterval(320))
        XCTAssertEqual(zoom.domain(following: start...start.addingTimeInterval(320)), domain)
        XCTAssertTrue(zoom.finish(horizontal: -90, vertical: 4))
        XCTAssertEqual(zoom.range, start...start.addingTimeInterval(240))
        zoom.reset()
        zoom.update(startX: 30, x: 32, width: 100, domain: domain)
        XCTAssertFalse(zoom.finish(horizontal: 2, vertical: 0)); XCTAssertNil(zoom.range)
        zoom.update(startX: 20, x: 50, width: 100, domain: domain)
        XCTAssertFalse(zoom.finish(horizontal: 30, vertical: 80)); XCTAssertNil(zoom.range)
        zoom.update(startX: 10, x: 50, width: 100, domain: domain); zoom.cancel()
        XCTAssertNil(zoom.brush); XCTAssertNil(zoom.range)
    }
    func testHistoryReplacesCurrentSecondBoundsMemoryAndPreservesGaps() {
        var history = LiveRateHistory()
        let a = LiveRateKey(workspace: "p", model: "a")
        history.record(at: start, rates: [a: 10], active: 1, reported: 1, gap: false)
        history.record(at: start.addingTimeInterval(0.9), rates: [a: 20], active: 1, reported: 1, gap: false)
        XCTAssertEqual(history.recent.count, 1); XCTAssertEqual(history.recent.first?.rates[a], 20)
        for i in 1...3600 { history.record(at: start.addingTimeInterval(Double(i)), rates: [a: 20], active: 1, reported: 1, gap: i == 300) }
        XCTAssertEqual(history.recent.count, LiveRateHistory.recentLimit)
        XCTAssertLessThanOrEqual(history.minutes.count, 61)
        XCTAssertTrue(history.minutes.contains(where: \.gap))
        XCTAssertEqual(history.minutes.first?.models(workspace: "p")["a"], 20)
        XCTAssertTrue(history.minutes.first?.models(workspace: "other").isEmpty == true)
        history.record(at: start.addingTimeInterval(200_000), rates: [:], active: 0, reported: 0, gap: true)
        XCTAssertTrue(history.minutes.isEmpty, "History expires even after sleep with no new requests")
        history.record(at: start.addingTimeInterval(50), rates: [a: 30], active: 1, reported: 1, gap: true)
        XCTAssertEqual(history.recent.count, 1, "No chart bridges a backward clock jump")
    }
    func testChartBoundsSeriesDoesNotBridgeUnknownUsageAndSeparatesProjects() {
        let a = LiveRateKey(workspace: "p", model: "a"), b = LiveRateKey(workspace: "other", model: "b")
        let samples = (0..<900).map { i in LiveRateSample(id: Int(start.timeIntervalSince1970) + i, end: Int(start.timeIntervalSince1970) + i + 1, rates: i == 450 ? [:] : [a: 12, b: 9], active: 2, reported: i == 450 ? 0 : 2, gap: false) }
        let series = MonitorRateSeries(samples: samples, domain: start...start.addingTimeInterval(900), workspace: "p")
        XCTAssertLessThanOrEqual(series.points.count, 120); XCTAssertEqual(series.models, ["a"])
        XCTAssertTrue(series.points.allSatisfy { $0.rate == 12 })
        XCTAssertEqual(Set(series.points.map(\.segment)).count, 2)
        let empty = MonitorRateSeries(samples: samples, domain: start...start.addingTimeInterval(900), workspace: "absent")
        XCTAssertTrue(empty.points.isEmpty)
        let partial = LiveRateSample(id: Int(start.timeIntervalSince1970), end: Int(start.timeIntervalSince1970) + 1, rates: [a: 12], active: 2, reported: 1, gap: false, missingWorkspaces: ["other"])
        XCTAssertTrue(MonitorRateSeries(samples: [partial], domain: start...start.addingTimeInterval(60), workspace: nil).points.isEmpty)
        XCTAssertEqual(MonitorRateSeries(samples: [partial], domain: start...start.addingTimeInterval(60), workspace: "p").points.first?.rate, 12, "A different project's missing usage cannot hide this project's observations")
    }
    func testPaletteDistinguishesModelsAndSurvivesRankChanges() {
        var palette = MonitorModelPalette()
        palette.include(["GPT-5.4 mini", "Claude Sonnet", "GPT-5.4"])
        let before = ["GPT-5.4 mini", "Claude Sonnet", "GPT-5.4"].map { palette.index($0) }
        XCTAssertEqual(Set(before).count, 3)
        palette.include(["new", "GPT-5.4", "Claude Sonnet", "GPT-5.4 mini"])
        XCTAssertEqual(["GPT-5.4 mini", "Claude Sonnet", "GPT-5.4"].map { palette.index($0) }, before)
        XCTAssertNotEqual(palette.index("Other models"), palette.index("GPT-5.4 mini"))
    }
    func testCurrentRatesDoNotSumCompletedAveragesOrTreatMissingAsZero() {
        var snapshot = LivePopupSnapshot()
        let key = LiveAttemptKey(session: LiveSessionKey(workspace: "p", session: "s"), epoch: "e", generation: 1, attempt: "a")
        var request = LiveRequestState(id: key, purpose: "turn", alias: "router", phase: "interim")
        request.intervalRate = 42
        snapshot.requests = [request]
        XCTAssertEqual(snapshot.currentRates(workspace: "p").rate, 42)
        snapshot.requests[0].intervalRate = nil
        XCTAssertNil(snapshot.currentRates(workspace: "p").rate)
        XCTAssertEqual(snapshot.currentRates(workspace: "p").active, 1)
        XCTAssertEqual(snapshot.currentRates(workspace: "other").active, 0)
    }
    func testDistributionCombinesAliasesAndPreservesMissingCostAndPairedCacheCoverage() {
        var first = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.5)
        first.tokens = GatewayTokenTotals(output: 100, outputSamples: 1)
        let models = [
            MenuBarModelDistribution(api: "responses", requestedAlias: "router", resolvedModel: "a", identityStatus: "reported", gateway: first, allRequests: 2),
            MenuBarModelDistribution(api: "responses", requestedAlias: "direct", resolvedModel: "a", identityStatus: "reported", gateway: first, allRequests: 2),
            MenuBarModelDistribution(api: "responses", requestedAlias: "unknown", resolvedModel: nil, identityStatus: "unreported", gateway: GatewayTotals(requests: 1), allRequests: 2)
        ]
        let rows = MonitorDistribution.make(models)
        XCTAssertEqual(rows.first?.tokens, 200); XCTAssertEqual(rows.first?.cost, 1)
        XCTAssertEqual(rows.first?.aliases, ["router", "direct"]); XCTAssertNil(rows.last?.cost)
        first.cacheReadTokens = 80; first.uncachedInputReportedTokens = 20
        first.cacheReadSamples = 1; first.uncachedInputSamples = 1
        XCTAssertEqual(monitorCacheShare(first), "80.000%")
        first.cacheReadSamples = 2
        XCTAssertEqual(monitorCacheShare(first), "—", "Unpaired token populations cannot make a cache percentage")
    }
    @MainActor func testZoomAndProjectChangeCancelStaleReadAndDoNotPollWhileHidden() async throws {
        var queries: [(Date, Date?, String?)] = []
        var held: [CheckedContinuation<MenuBarSnapshot, Error>] = []
        let controller = MenuBarMetricsController(load: { _,_,_ in throw CaptureFailure.unavailable }, scopedLoad: { _, until, _, from, project in
            queries.append((until, from, project))
            return try await withCheckedThrowingContinuation { held.append($0) }
        }, period: .fifteenMinutes, interval: .seconds(60), now: { self.start })
        controller.setVisible(true)
        for _ in 0..<100 where held.isEmpty { await Task.yield() }
        let range = start.addingTimeInterval(-80)...start.addingTimeInterval(-20)
        controller.setScope(range: range, workspaceID: "p")
        for _ in 0..<100 where held.count < 2 { await Task.yield() }
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries.last?.0, range.upperBound); XCTAssertEqual(queries.last?.1, range.lowerBound); XCTAssertEqual(queries.last?.2, "p")
        held[1].resume(returning: snapshot(until: range.upperBound)); held[0].resume(returning: snapshot(until: start))
        for _ in 0..<100 where controller.snapshot == nil { await Task.yield() }
        XCTAssertEqual(controller.snapshot?.until, range.upperBound)
        controller.setVisible(false); controller.setScope(range: nil, workspaceID: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(queries.count, 2)
    }
    @MainActor func testLegacyLoaderCannotMislabelUnfilteredTotalsAsZoomed() async throws {
        var reads = 0
        let controller = MenuBarMetricsController(load: { period, until, _ in
            reads += 1
            return self.snapshot(until: until)
        })
        controller.setScope(range: start...start.addingTimeInterval(50), workspaceID: "p")
        controller.setVisible(true)
        defer { controller.setVisible(false) }
        for _ in 0..<100 where controller.notice.isEmpty { await Task.yield() }
        XCTAssertEqual(reads, 0); XCTAssertNil(controller.snapshot); XCTAssertFalse(controller.notice.isEmpty)
    }
    private func snapshot(until: Date) -> MenuBarSnapshot {
        MenuBarSnapshot(period: .fifteenMinutes, from: until.addingTimeInterval(-900), until: until, counts: DashboardCounts(), gateway: GatewayTotals(), workspaces: 0, sessions: 0, compactionRequests: 0, costUnreported: 0, costInvalid: 0, costConflicts: 0, models: [], modelGroups: 0, offset: 0)
    }
}
