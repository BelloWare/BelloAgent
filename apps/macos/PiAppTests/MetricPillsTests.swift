import XCTest
@testable import PiApp

/// Every figure the pills and their dialogs show, asserted as text. The
/// formats carry the reference harness's own vectors, the throughput carries
/// the fold with and without recorded timing, and the pills carry a fixture
/// session end to end.
final class MetricPillsTests: XCTestCase {

    // MARK: Formats

    func testCompactTokensReadAsTheReferenceWritesThem() {
        XCTAssertEqual(MetricFormat.tokens(0), "0")
        XCTAssertEqual(MetricFormat.tokens(517), "517")
        XCTAssertEqual(MetricFormat.tokens(999), "999")
        XCTAssertEqual(MetricFormat.tokens(1_000), "1K")
        XCTAssertEqual(MetricFormat.tokens(12_200), "12.2K")
        XCTAssertEqual(MetricFormat.tokens(15_800), "15.8K")
        XCTAssertEqual(MetricFormat.tokens(99_949), "99.9K")
        XCTAssertEqual(MetricFormat.tokens(517_000), "517K")
        XCTAssertEqual(MetricFormat.tokens(1_200_000), "1.2M")
        XCTAssertEqual(MetricFormat.tokens(12_000_000), "12M", "A trailing zero says nothing")
        XCTAssertEqual(MetricFormat.tokens(.nan), "—")
        XCTAssertEqual(MetricFormat.tokens(-1), "—", "A negative count is not an observation")
        XCTAssertEqual(MetricFormat.tokenCount(15_800), "15.8K tok")
    }

    func testDialogsShowTheExactGroupedCount() {
        XCTAssertEqual(MetricFormat.exactTokens(15_800), "15,800")
        XCTAssertEqual(MetricFormat.exactTokens(517), "517")
        XCTAssertEqual(MetricFormat.exactTokens(1_200_000), "1,200,000")
        XCTAssertEqual(MetricFormat.exactTokenCount(15_800), "15,800 tok")
    }

    func testCacheHitNeverRoundsAPartialHitToAHundred() {
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 50, prompt: 100), "50")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 0, prompt: 100), "0")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 100, prompt: 100), "100", "Only an exact full hit reads 100")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 9_996, prompt: 10_000), "99.96")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 99_999, prompt: 100_000), "99.999")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 999_999, prompt: 1_000_000), "99.9999")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 505, prompt: 1_000, decimals: 1), "50.5")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 500, prompt: 1_000, decimals: 1), "50", "A trailing zero says nothing")
        XCTAssertNil(MetricFormat.cacheHitPercent(read: 10, prompt: 0), "No billed input is no share at all")
        XCTAssertNil(MetricFormat.cacheHitPercent(read: 200, prompt: 100), "Conflicting observations must not become a full cache hit")
    }

    func testRunDurationsPadTheSmallerUnits() {
        XCTAssertEqual(MetricFormat.runDuration(0), "0s")
        XCTAssertEqual(MetricFormat.runDuration(2), "<0.1s")
        XCTAssertEqual(MetricFormat.runDuration(99), "<0.1s")
        XCTAssertEqual(MetricFormat.runDuration(500), "0.5s", "A turn faster than a second must not read as no time at all")
        XCTAssertEqual(MetricFormat.runDuration(999), "0.9s")
        XCTAssertEqual(MetricFormat.runDuration(1_000), "1s", "From a second up, whole seconds as the reference writes them")
        XCTAssertEqual(MetricFormat.runDuration(19_000), "19s")
        XCTAssertEqual(MetricFormat.runDuration(19_900), "19s")
        XCTAssertEqual(MetricFormat.runDuration(60_000), "1m 00s")
        XCTAssertEqual(MetricFormat.runDuration(65_000), "1m 05s")
        XCTAssertEqual(MetricFormat.runDuration(3_903_000), "1h 05m 03s")
        XCTAssertEqual(MetricFormat.runDuration(-1), "—")
        XCTAssertEqual(MetricFormat.runDuration(.infinity), "—")
    }

    func testThroughputAndLatencyTakeOneDecimalUnderTen() {
        XCTAssertEqual(MetricFormat.throughput(34.4), "34 tok/s")
        XCTAssertEqual(MetricFormat.throughput(34.6), "35 tok/s")
        XCTAssertEqual(MetricFormat.throughput(3.44), "3.4 tok/s")
        XCTAssertEqual(MetricFormat.throughput(9.96), "10 tok/s")
        XCTAssertEqual(MetricFormat.throughput(3), "3 tok/s")
        XCTAssertEqual(MetricFormat.throughput(0), "0 tok/s")
        XCTAssertEqual(MetricFormat.throughput(.nan), "—")
        XCTAssertEqual(MetricFormat.latency(2), "2 ms", "A 2 ms first token is not zero seconds")
        XCTAssertEqual(MetricFormat.latency(400), "400 ms")
        XCTAssertEqual(MetricFormat.latency(1_000), "1s")
        XCTAssertEqual(MetricFormat.latency(1_240), "1.2s")
        XCTAssertEqual(MetricFormat.latency(12_300), "12s")
    }

    func testTheContextRingNeverReadsEmptyOrFullWhenItIsNeither() {
        XCTAssertEqual(MetricFormat.occupancyPercent(0.06), "6")
        XCTAssertEqual(MetricFormat.occupancyPercent(0), "0")
        XCTAssertEqual(MetricFormat.occupancyPercent(1), "100")
        XCTAssertEqual(MetricFormat.occupancyPercent(0.0001), "<1", "A window holding something must not read empty")
        XCTAssertEqual(MetricFormat.occupancyPercent(0.9999), "99.99", "A window with room left must not read full")
        XCTAssertNil(MetricFormat.occupancyPercent(.nan))
    }

    // MARK: The settled rate

    func testTheSettledRateFoldsOnlyTheRequestsThatReportedBothHalves() {
        var fold = SettledThroughput()
        fold.add(decodeMilliseconds: 1_000, outputTokens: 34)
        fold.add(decodeMilliseconds: nil, outputTokens: 50)
        fold.add(decodeMilliseconds: 500, outputTokens: nil)
        fold.add(decodeMilliseconds: 0, outputTokens: 10)
        fold.add(decodeMilliseconds: -1, outputTokens: 10)
        fold.add(decodeMilliseconds: .infinity, outputTokens: 10)
        XCTAssertEqual(fold.samples, 1)
        XCTAssertEqual(fold.requests, 6)
        XCTAssertEqual(fold.tokensPerSecond, 34)
        XCTAssertEqual(fold.label, "34 tok/s")
        XCTAssertEqual(fold.coverage, "1/6 requests measured")

        var second = SettledThroughput()
        second.add(decodeMilliseconds: 1_000, outputTokens: 66)
        fold.add(second)
        XCTAssertEqual(fold.tokensPerSecond, 50, "A group's rate is one division of the totals, never an average of rates")
        XCTAssertEqual(fold.samples, 2); XCTAssertEqual(fold.requests, 7)

        var none = SettledThroughput()
        none.add(decodeMilliseconds: nil, outputTokens: nil)
        XCTAssertNil(none.tokensPerSecond); XCTAssertNil(none.label)
        XCTAssertEqual(none.coverage, "0/1 requests measured")
        XCTAssertNil(SettledThroughput().coverage, "Nothing considered is not partial coverage")
    }

    func testAverageLatencyCountsOnlyTheRequestsThatRecordedIt() {
        var fold = SettledLatency()
        fold.add(milliseconds: 400)
        fold.add(milliseconds: nil)
        fold.add(milliseconds: 600)
        XCTAssertEqual(fold.average, 500)
        XCTAssertEqual(fold.label, "500 ms")
        XCTAssertEqual(fold.coverage, "2/3 requests measured")
    }

    // MARK: A fixture session

    /// Two requests of one turn: 12,000 input of which 6,000 came from cache,
    /// 3,800 output including 900 reasoning, $0.0025, and a second of decode
    /// that produced 34 tokens.
    private func fixtureSession() -> GatewayTotals {
        var totals = GatewayTotals(requests: 2, costSamples: 2, costUSD: 0.0025,
                                   cacheReadTokens: 6_000, cacheReadSamples: 2)
        totals.turnCount = 1
        totals.tokens = GatewayTokenTotals(input: 12_000, output: 3_800, total: 15_800,
                                           inputSamples: 2, outputSamples: 2, samples: 2)
        totals.tokens?.reasoning = 900; totals.tokens?.reasoningSamples = 2
        totals.uncachedInputReportedTokens = 6_000; totals.uncachedInputSamples = 2
        totals.decodeMilliseconds = 1_000; totals.decodeOutputTokens = 34; totals.decodeSamples = 2
        totals.ttftMilliseconds = 800; totals.ttftSamples = 2
        return totals
    }
    private func fixtureWork() -> WorkSplit? {
        WorkSplit(timing: ["sessionModelMs": .number(12_400), "sessionToolMs": .number(6_600),
                           "modelMs": .number(9_000), "toolMs": .number(4_000)])
    }

    func testSessionPillsReadAsTheOwnerAskedFor() throws {
        let stats = SessionStatsPresentation(gateway: fixtureSession(), work: fixtureWork())
        XCTAssertEqual(stats.gaugeLabel, "1 turn 2 steps · 34 tok/s")
        XCTAssertEqual(stats.usageLabel, "15.8K tok · Cache hit 50% · $0.0025")
        XCTAssertEqual(stats.usageHeadline, "15,800 tok")
        XCTAssertTrue(stats.hasUsage); XCTAssertTrue(stats.hasTimeDialog)
    }

    func testSessionStatisticsDialogListsTheFourTimings() throws {
        let stats = SessionStatsPresentation(gateway: fixtureSession(), work: fixtureWork())
        XCTAssertEqual(stats.timeRows.map(\.name), ["LLM time", "Tool time", "Average TTFT", "Output speed"])
        XCTAssertEqual(stats.timeRows.map(\.value), ["12.4s", "6.6s", "400 ms", "34 tok/s"])
        XCTAssertTrue(stats.timeRows.allSatisfy { $0.coverage == nil }, "Complete coverage says nothing")
        XCTAssertEqual(stats.timeNotes.first, SettledThroughput.explanation)
    }

    func testTokenUsageDialogListsEveryBucketWithItsCost() throws {
        let stats = SessionStatsPresentation(gateway: fixtureSession(), work: fixtureWork())
        XCTAssertEqual(stats.usageRows.map(\.name), ["Cache hit", "Uncached input", "Cached input", "Output", "Cost"])
        XCTAssertEqual(stats.usageRows.map(\.value), ["50%", "6,000 tok", "6,000 tok", "3,800 tok", "$0.0025 USD"])
        XCTAssertEqual(stats.usageRows.last(where: { $0.name == "Output" })?.detail, "incl. 900 reasoning")
        XCTAssertTrue(stats.usageNotes.contains { $0.contains("Cached input is part of input") })
    }

    func testAPartlyReportingSessionNamesItsCoverageInsteadOfHidingIt() throws {
        var totals = fixtureSession()
        totals.requests = 5
        totals.decodeSamples = 2; totals.ttftSamples = 2
        totals.costSamples = 3
        let stats = SessionStatsPresentation(gateway: totals, work: fixtureWork())
        XCTAssertEqual(stats.throughput.coverage, "2/5 requests measured")
        XCTAssertEqual(stats.timeRows.first { $0.name == "Output speed" }?.coverage, "2/5 requests measured")
        XCTAssertEqual(stats.usageRows.first { $0.name == "Cost" }?.coverage, "3/5 requests reported")
        XCTAssertTrue(stats.usageNotes.contains { $0.contains("2 of 5 requests reported no cost") })
        XCTAssertTrue(stats.timeNotes.contains { $0.contains("covers the 2 that recorded it") })
    }

    func testASessionWithoutAnyTimedFigureOffersNoDialogAndNoRate() throws {
        var totals = GatewayTotals(requests: 2)
        totals.turnCount = 1
        let stats = SessionStatsPresentation(gateway: totals, work: nil)
        XCTAssertEqual(stats.gaugeLabel, "1 turn 2 steps", "No request reported both halves, so there is no rate to show")
        XCTAssertFalse(stats.hasTimeDialog)
        XCTAssertFalse(stats.hasUsage, "A session that billed nothing keeps its counts and drops the usage pill")
        XCTAssertEqual(stats.usageLabel, "")
    }

    // MARK: A fixture turn

    private func fixtureTurn(elapsedMs: Double? = 19_000) -> TurnSummary {
        var accounting = TurnAccounting(requests: 1)
        accounting.input = 12_000; accounting.inputSamples = 1
        accounting.cached = 6_000; accounting.cachedSamples = 1
        accounting.uncached = 6_000; accounting.uncachedSamples = 1
        accounting.cacheWrite = 0; accounting.cacheWriteSamples = 1
        accounting.output = 3_800; accounting.outputSamples = 1
        accounting.reasoning = 900; accounting.reasoningSamples = 1
        accounting.costUSD = 0.0025; accounting.costSamples = 1
        accounting.model = "deepseek-v4-flash"
        accounting.throughput = SettledThroughput(decodeMilliseconds: 1_000, outputTokens: 34, samples: 1, requests: 1)
        accounting.latency = SettledLatency(milliseconds: 400, samples: 1, requests: 1)
        return TurnSummary(replies: 1, tools: 2, startedAt: 1_000, endedAt: 20_000, elapsedMs: elapsedMs,
                           modelMs: 12_400, toolMs: 6_600, live: false, files: 1, partial: false,
                           accounting: accounting, requests: [], outcome: "completed")
    }

    func testCacheWritesRemainAnInputBreakdownInBothScopes() {
        var gateway = fixtureSession()
        gateway.cacheWriteTokens = 600; gateway.cacheWriteSamples = 2
        let session = SessionStatsPresentation(gateway: gateway, work: nil)
        XCTAssertEqual(session.totalTokens, 15_800)
        XCTAssertEqual(session.cacheHit, "50")
        var summary = fixtureTurn()
        summary.accounting.cacheWrite = 600
        let turn = TurnPillsPresentation(summary)
        XCTAssertEqual(turn.totalTokens, 15_800)
        XCTAssertEqual(turn.cacheHit, "50")
        XCTAssertEqual(turn.usageRows.first { $0.name == "Cache write" }?.value, "600 tok")
    }

    func testTurnPillsReadAsTheOwnerAskedFor() throws {
        let turn = TurnPillsPresentation(fixtureTurn())
        XCTAssertEqual(turn.usageLabel, "Usage 15.8K tok · $0.0025")
        XCTAssertEqual(turn.timeLabel, "Ran for 19s")
        XCTAssertEqual(turn.usageHeadline, "15,800 tok")
    }

    func testTurnUsageDialogNamesTheModelTheCacheAndTheReasoningShare() throws {
        let turn = TurnPillsPresentation(fixtureTurn())
        XCTAssertEqual(turn.usageRows.map(\.name), ["Model", "Cache hit", "Uncached input", "Cached input", "Cache write", "Output", "Cost"])
        XCTAssertEqual(turn.usageRows.map(\.value), ["deepseek-v4-flash", "50%", "6,000 tok", "6,000 tok", "0 tok", "3,800 tok", "$0.0025 USD"])
        XCTAssertEqual(turn.usageRows.first { $0.name == "Output" }?.detail, "incl. 900 reasoning")
    }

    func testTurnTimeDialogSplitsModelFromToolsAndNamesTheRate() throws {
        let turn = TurnPillsPresentation(fixtureTurn())
        XCTAssertEqual(turn.timeRows.map(\.name), ["Total run time", "Output speed", "TTFT", "Model vs tools", "Work"])
        XCTAssertEqual(turn.timeRows.map(\.value), ["19s", "34 tok/s", "400 ms", "12s / 6s", "1 reply, 2 tool calls, 1 file changed"])
        XCTAssertEqual(turn.timeNotes, [SettledThroughput.explanation])
    }

    func testATurnThatReportedNoDecodeSpanSaysSoRatherThanShowingZero() throws {
        var summary = fixtureTurn()
        summary.accounting.throughput = SettledThroughput(samples: 0, requests: 1)
        summary.accounting.latency = SettledLatency(samples: 0, requests: 1)
        let turn = TurnPillsPresentation(summary)
        XCTAssertFalse(turn.timeRows.contains { $0.name == "Output speed" })
        XCTAssertFalse(turn.timeRows.contains { $0.name == "TTFT" })
        XCTAssertTrue(turn.timeNotes.contains { $0.contains("a decode span and its output tokens") })
        XCTAssertTrue(turn.hasTimeDialog, "The clock and the model/tool split are still worth a dialog")
    }

    func testAnUnclockedTurnStillShowsWhatItUsed() throws {
        let turn = TurnPillsPresentation(fixtureTurn(elapsedMs: nil))
        XCTAssertNil(turn.timeLabel, "A turn with no duration does not invent one")
        XCTAssertEqual(turn.usageLabel, "Usage 15.8K tok · $0.0025")
    }

    func testAPartialTurnSaysWhatItsFiguresCover() throws {
        var summary = fixtureTurn()
        summary.partial = true
        summary.accounting.requests = 3
        let turn = TurnPillsPresentation(summary)
        XCTAssertEqual(turn.usageRows.first { $0.name == "Cost" }?.coverage, "1/3 requests reported")
        XCTAssertTrue(turn.usageNotes.contains { $0.contains("above the loaded history") })
    }

    // MARK: The per-request ledger

    func testTheLedgerListsEveryRequestAndExcludesTheUnmeasuredOnesFromTheRate() throws {
        let wall = Date(timeIntervalSince1970: 1_000_000)
        let measured = SessionTimingSample(id: "a", wall: wall, ttftMilliseconds: 400, streamingMilliseconds: 1_000,
                                           outputTokens: 34, costUSD: 0.0025, requestMilliseconds: 1_400,
                                           outcome: "completed", api: "openai-responses", model: "deepseek-v4-flash",
                                           inputTokens: 12_000, cacheReadTokens: 6_000, cacheWriteTokens: 0, reasoningTokens: 900)
        let unmeasured = SessionTimingSample(id: "b", wall: wall, ttftMilliseconds: nil, streamingMilliseconds: nil,
                                             outputTokens: nil, costUSD: nil, requestMilliseconds: nil,
                                             outcome: "completed", api: "openai-responses", model: nil, inputTokens: 500)
        let ledger = SessionRequestLedger(history: SessionTimingHistory(samples: [measured, unmeasured], completedRequests: 2))
        XCTAssertEqual(ledger.rows.map(\.number), [1, 2])
        let first = ledger.rows[0]
        XCTAssertEqual(first.model, "deepseek-v4-flash")
        XCTAssertEqual(first.status, "completed")
        XCTAssertEqual(first.input, "12,000")
        XCTAssertEqual(first.inputDetail, "6,000 cached · 6,000 new")
        XCTAssertEqual(first.output, "34")
        XCTAssertEqual(first.outputDetail, "900 reasoning")
        XCTAssertEqual(first.ttft, "400 ms")
        XCTAssertEqual(first.generation, "1s")
        XCTAssertEqual(first.throughput, "34 tok/s")
        XCTAssertEqual(first.cost, "$0.0025")
        XCTAssertFalse(first.unmeasured)
        let second = ledger.rows[1]
        XCTAssertEqual(second.model, "openai-responses", "With no reported model the ledger names the API it went out on")
        XCTAssertEqual([second.output, second.ttft, second.generation, second.throughput, second.cost], ["—", "—", "—", "—", "—"])
        XCTAssertTrue(second.unmeasured)
        XCTAssertEqual(ledger.throughput.tokensPerSecond, 34)
        XCTAssertTrue(ledger.coverageNote.contains("34 tok/s over 1 of 2 listed requests"))
        XCTAssertTrue(ledger.coverageNote.contains("1 request has no completed decode span or output tokens"))
        XCTAssertTrue(ledger.copyText.contains("deepseek-v4-flash"))
        XCTAssertEqual(ledger.subtitle, "2 requests")
    }

    func testAFullyReportingLedgerDoesNotApologiseForCoverage() throws {
        let sample = SessionTimingSample(id: "a", wall: Date(timeIntervalSince1970: 1_000_000), ttftMilliseconds: 400,
                                         streamingMilliseconds: 1_000, outputTokens: 34, requestMilliseconds: 1_400)
        let ledger = SessionRequestLedger(history: SessionTimingHistory(samples: [sample], hasOlderRequests: true, completedRequests: 40))
        XCTAssertEqual(ledger.subtitle, "Most recent 1 request")
        XCTAssertTrue(ledger.coverageNote.contains("every listed request reported both"))
    }
}
