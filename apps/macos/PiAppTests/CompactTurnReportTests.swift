import XCTest
import SwiftUI
@testable import PiApp

final class CompactTurnReportTests: XCTestCase {
    private func accounting() -> TurnAccounting {
        var a = TurnAccounting(requests: 2)
        a.input = 12_000; a.inputSamples = 2
        a.cached = 6_000; a.cachedSamples = 2
        a.uncached = 6_000; a.uncachedSamples = 2
        a.output = 3_800; a.outputSamples = 2
        a.reasoning = 900; a.reasoningSamples = 2
        a.costUSD = 0.000001; a.costSamples = 2
        a.modelNames = ["gpt-5.4-mini", "gpt-5.4"]
        a.modelRoutes = [GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4-mini", latestWall: 1),
                         GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4", latestWall: 2)]
        return a
    }
    private func turn() -> TurnSummary {
        TurnSummary(replies: 2, tools: 2, startedAt: nil, endedAt: nil, elapsedMs: 19_000,
                    modelMs: 12_400, toolMs: 6_600, live: false, files: 1, partial: false,
                    accounting: accounting(), requests: [], outcome: "completed")
    }

    func testSharesPartitionTheirOwnParentWithoutAddingSubsetsAgain() throws {
        let a = accounting(), input = TurnTokenPartition(a, input: true), output = TurnTokenPartition(a, input: false)
        XCTAssertEqual(try XCTUnwrap(input.fraction), 0.5)
        XCTAssertEqual(try XCTUnwrap(output.fraction), 900 / 3_800, accuracy: 0.000001)
        XCTAssertEqual(input.remainder, 6_000); XCTAssertEqual(output.remainder, 2_900)
        XCTAssertEqual(input.label(part: true), "Cached 6,000 · 50%")
        XCTAssertEqual(input.label(part: false), "Uncached 6,000 · 50%")
        XCTAssertEqual(output.label(part: true), "Reasoning 900 · 23.68%")
        XCTAssertEqual(TurnPillsPresentation(turn()).totalTokens, 15_800)
        XCTAssertTrue(TurnLineView.copyText(turn()).contains("Models: gpt-5.4-mini, gpt-5.4"))
        XCTAssertTrue(TurnLineView.copyText(turn()).contains("$0.000001"))
    }

    func testPartialAndConflictingReportsDoNotDrawAFalsePercentage() {
        var a = accounting(); a.cachedSamples = 1; a.uncachedSamples = 1
        let partial = TurnTokenPartition(a, input: true)
        XCTAssertNil(partial.fraction); XCTAssertTrue(partial.partial)
        XCTAssertEqual(partial.fill, .reported, "Partial reporting must not look like an empty token bar")
        XCTAssertEqual(partial.totalLabel, "12,000")
        XCTAssertTrue(partial.help.contains("percentage breakdown is unavailable"))
        XCTAssertFalse(partial.label(part: true).contains("%"))
        // Matching counts still cannot justify reasoning exceeding all output.
        a.reasoning = 4_000
        XCTAssertNil(TurnTokenPartition(a, input: false).fraction)
        XCTAssertNil(TurnTokenPartition(a, input: false).remainder)
        a.reasoning = .nan
        XCTAssertNil(TurnTokenPartition(a, input: false).part)
    }

    func testModelListKeepsDistinctNamesAndLatestResponseModel() {
        let messages = ["gpt-5.4-mini", "gpt-5.4", "gpt-5.4-mini"].enumerated().map { index, name in
            var message = TranscriptMessage(id: "reply-\(index)", role: "assistant", text: "Reply")
            var totals = GatewayTotals(); totals.requests = 1
            totals.models = GatewayModelSummary(names: [name], nameCount: 1, reportedRequests: 1)
            message.accounting = totals
            return message
        }
        let result = TranscriptActivity.aggregate(messages)
        XCTAssertEqual(result.reportedModels, ["gpt-5.4-mini", "gpt-5.4"])
        XCTAssertEqual(result.model, "gpt-5.4-mini", "A return to an earlier model is still the latest response")
    }

    func testPendingRequestsKeepThePreviousMatchedTokenColorsAndCounts() throws {
        var reported = GatewayTotals(requests: 1)
        reported.tokens = GatewayTokenTotals(input: 12000, output: 3800, total: 15800, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 900, reasoningSamples: 1)
        reported.cacheReadTokens = 6000; reported.cacheReadSamples = 1
        var answer = TranscriptMessage(id: "answer", role: "assistant", text: "First result")
        answer.accounting = reported
        var pending = TranscriptMessage(id: "pending", role: "assistant", text: "")
        pending.accounting = GatewayTotals(requests: 1)
        let before = TranscriptActivity.aggregate([answer])
        let during = TranscriptActivity.aggregate([answer, pending])
        for input in [true, false] {
            let settled = TurnTokenPartition(before, input: input), continuing = TurnTokenPartition(during, input: input)
            XCTAssertEqual(continuing.fill, settled.fill)
            XCTAssertEqual(continuing.total, settled.total)
            XCTAssertEqual(continuing.part, settled.part)
            XCTAssertEqual(continuing.remainder, settled.remainder)
            XCTAssertTrue(continuing.partial, "Coverage remains truthful in details without replacing the split")
        }
        // A later input total without a matching cache report must not change
        // the denominator of the retained green/brown breakdown.
        pending.accounting?.tokens = GatewayTokenTotals(input: 90000, output: 8000, total: 98000, inputSamples: 1, outputSamples: 1, samples: 1)
        let unmatched = TranscriptActivity.aggregate([answer, pending])
        XCTAssertEqual(TurnTokenPartition(unmatched, input: true).fraction, 0.5)
        XCTAssertEqual(TurnTokenPartition(unmatched, input: false).total, 3800)
        pending.accounting = reported
        let next = TranscriptActivity.aggregate([answer, pending])
        XCTAssertEqual(TurnTokenPartition(next, input: true).total, 24000)
        XCTAssertFalse(TurnTokenPartition(next, input: true).partial)
        XCTAssertEqual(TurnTokenPartition(TurnAccounting(), input: true).fill, .empty, "Another turn cannot inherit this turn’s values")
    }

    func testRequestedAndResponseModelsStayPairedAndUseDispatchTime() throws {
        let older = GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4-mini", latestWall: 10)
        let newer = GatewayModelRoute(requested: "gpt-5.4", responded: "gpt-5.4", latestWall: 20)
        XCTAssertEqual(older.label, "auto-router → gpt-5.4-mini")
        XCTAssertEqual(newer.label, "gpt-5.4")
        XCTAssertEqual(GatewayModelRoute(requested: "auto-router", responded: nil).label, "auto-router → —")
        var a = accounting(); a.modelRoutes = [newer, older]
        XCTAssertEqual(a.latestModelRoute, newer, "Message order need not be dispatch order")
        var value = turn(); value.accounting = a
        let rows = TurnInfoPresentation.rows(value)
        XCTAssertEqual(rows.first { $0.name == "Requested models" }?.value, "auto-router, gpt-5.4")
        XCTAssertTrue(TurnLineView.copyText(value).contains(older.detail))
        let legacy = try JSONDecoder().decode(GatewayModelSummary.self, from: Data(#"{"names":["gpt-5.4"],"nameCount":1,"reportedRequests":1,"unreportedRequests":0,"conflictingRequests":0,"incompleteRequests":0}"#.utf8))
        XCTAssertNil(legacy.routes, "Old snapshots do not invent a requested model")
    }

    func testZeroAndMissingCountersStayDifferentAndDoNotDivideByZero() {
        var a = accounting(); a.input = 0; a.cached = 0; a.output = 0; a.reasoning = 0
        for input in [true, false] {
            let zero = TurnTokenPartition(a, input: input)
            XCTAssertEqual(zero.totalLabel, "0"); XCTAssertEqual(zero.remainder, 0)
            XCTAssertNil(zero.fraction); XCTAssertFalse(zero.label(part: true).contains("%"))
            XCTAssertEqual(zero.fill, .empty)
            let missing = TurnTokenPartition(TurnAccounting(requests: 1), input: input)
            XCTAssertEqual(missing.totalLabel, "—"); XCTAssertNil(missing.part)
            XCTAssertNil(missing.remainder); XCTAssertNil(missing.fraction)
            XCTAssertEqual(missing.fill, .empty, "No observations must not invent token usage")
        }
        a.input = 10_000; a.cached = 9_996
        XCTAssertEqual(TurnTokenPartition(a, input: true).label(part: true), "Cached 9,996 · 99.96%")
        XCTAssertEqual(TurnTokenPartition(a, input: true).label(part: false), "Uncached 4 · 0.04%")
    }

    func testDetailedNumbersKeepSmallCostsAndFastRequestsVisible() {
        var value = turn()
        for cost in [0, 0.0013875, 0.000001, 0.000000123456, 1.23456789] {
            value.accounting.costUSD = cost
            let text = TurnInfoPresentation.costLabel(value)
            XCTAssertEqual(Double(text.dropFirst()), cost, "Displayed cost must preserve this gateway observation")
        }
        XCTAssertEqual(MetricFormat.detailedDuration(2.403), "2.403 ms")
        XCTAssertEqual(MetricFormat.detailedDuration(0.03125), "0.03125 ms")
        XCTAssertEqual(MetricFormat.detailedDuration(12_345), "12.345s")
        XCTAssertEqual(MetricFormat.detailedDuration(3_662_345), "1h 1m 2.345s")
        XCTAssertEqual(MetricFormat.detailedDuration(59_999.9), "1m 0s", "Rounding carries across the minute boundary")
        XCTAssertEqual(MetricFormat.detailedDuration(.nan), "—")
        XCTAssertEqual(TurnTokenPartition(accounting(), input: true).totalLabel, "12,000")
    }

    @MainActor func testReportIsCompactAndWrapsWithoutChangingHeightAsCountersArrive() throws {
        let value = turn()
        for width: CGFloat in [280, 640, 900] {
            let host = NSHostingView(rootView: CompactTurnReport(turn: value).frame(width: width))
            host.safeAreaRegions = []
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            XCTAssertLessThan(host.fittingSize.height, width >= 640 ? 105 : 215)
            var running = value; running.live = true; running.outcome = nil; running.phase = "compacting"
            running.accounting = TurnAccounting()
            host.rootView = CompactTurnReport(turn: running, status: "Compacting context…").frame(width: width)
            let empty = host.fittingSize.height
            running.accounting = value.accounting
            host.rootView = CompactTurnReport(turn: running, status: "Compacting context…").frame(width: width)
            XCTAssertEqual(host.fittingSize.height, empty, accuracy: 1, "Usage arriving must not move the chat")
        }
    }

    /// Opt-in visual evidence of the actual SwiftUI component, in both themes
    /// and a side-chat width. Kept out of production and routine test output.
    @MainActor func testCaptureCompactReportGallery() throws {
        guard let root = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else { throw XCTSkip("No screenshot destination") }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [280, 760] {
                var live = turn(); live.live = true; live.outcome = nil; live.phase = "compacting"
                live.accounting.inputSplit = GatewayTokenSplit(total: 12_000, part: 6_000, samples: 2)
                live.accounting.outputSplit = GatewayTokenSplit(total: 3_800, part: 900, samples: 2)
                live.accounting.requests = 3 // The next request has not reported usage yet.
                let view = VStack(alignment: .leading, spacing: 18) {
                    Text("Completed turn").font(.headline)
                    StableTurnSummaryView(turn: turn(), actions: TranscriptActions())
                    Text("Ongoing turn").font(.headline)
                    CompactTurnReport(turn: live, status: "Compacting context…")
                }.padding(16).frame(width: width + 32).background(TranscriptPalette.canvas)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let host = NSHostingView(rootView: view); host.safeAreaRegions = []
                host.appearance = NSAppearance(named: appearance); host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = host.appearance; window.makeKeyAndOrderFront(nil)
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("compact-report-\(Int(width))-\(name).png"))
            }
        }
    }
}
