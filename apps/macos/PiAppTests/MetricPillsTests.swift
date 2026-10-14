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

    // MARK: Boundaries

    /// Rounding that reaches the next unit is written in it: 999,500 tokens
    /// is "1M", never "1000K", and 59.96 s is a minute, never "60.0s". Past
    /// a minute a work duration counts whole seconds, as a clock does.
    func testRoundingCarriesIntoTheNextUnit() {
        XCTAssertEqual(MetricFormat.tokens(999_499), "999K")
        XCTAssertEqual(MetricFormat.tokens(999_500), "1M")
        XCTAssertEqual(MetricFormat.tokens(999_999), "1M")
        XCTAssertEqual(MetricFormat.tokens(99_949), "99.9K")
        XCTAssertEqual(MetricFormat.tokens(99_950), "100K")
        XCTAssertEqual(MetricFormat.tokens(999_500_000), "1B")
        XCTAssertEqual(TranscriptActivity.formatCompactTokens(999_499), "999K")
        XCTAssertEqual(TranscriptActivity.formatCompactTokens(999_500), "1M")
        XCTAssertEqual(TranscriptActivity.formatTokenCount(999_999), "1M")
        XCTAssertEqual(workDuration(59_949), "59.9s")
        XCTAssertEqual(workDuration(59_960), "1m 0s")
        XCTAssertEqual(workDuration(119_600), "1m 59s")
        XCTAssertEqual(workDuration(3_599_600), "59m 59s")
        XCTAssertEqual(workDuration(3_753_000), "1h 2m")
        XCTAssertEqual(workDuration(400), "0.4s")
        XCTAssertEqual(TranscriptActivity.formatDuration(949), "0.9s")
        XCTAssertEqual(TranscriptActivity.formatDuration(990), "1s")
        XCTAssertEqual(MetricFormat.latency(999.4), "999 ms")
        XCTAssertEqual(MetricFormat.latency(999.6), "1s")
        XCTAssertEqual(MetricFormat.detailedDuration(999.999), "999.999 ms")
        XCTAssertEqual(MetricFormat.detailedDuration(999.9996), "1s")
        XCTAssertEqual(SessionRatePresentation.compactRate(999.6), "1K tok/s")
        XCTAssertEqual(SessionRatePresentation.compactRate(999_499), "999K tok/s")
        XCTAssertEqual(SessionRatePresentation.compactRate(999_500), "1M tok/s")
        let context = ContextMeterPresentation(context: ["tokens": .number(999_600), "contextWindow": .number(2_000_000), "scope": .string("last-request")])
        XCTAssertEqual(context.compactLabel, "≈1M / 2M · last request")
    }

    /// A small cache hit is a hit: 0.4% must not read as a 0% cache hit.
    /// Only no cached token at all reads zero.
    func testASmallButRealCacheHitIsNeverWrittenAsZero() {
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 4, prompt: 1_000), "<1")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 4, prompt: 10_000, decimals: 1), "<0.1")
        XCTAssertEqual(MetricFormat.cacheHitPercent(read: 0, prompt: 1_000), "0", "No cached token at all is a zero")
        var totals = GatewayTotals(requests: 1, costSamples: 0, cacheReadTokens: 4, cacheReadSamples: 1)
        totals.tokens = GatewayTokenTotals(input: 1_000, output: 10, total: 1_010, inputSamples: 1, outputSamples: 1, samples: 1)
        totals.inputSplit = GatewayTokenSplit(total: 1_000, part: 4, samples: 1)
        XCTAssertEqual(SessionStatsPresentation(gateway: totals, work: nil).usageLabel, "1K tok · 996 uncached · 4 cached · 10 out · Cache hit 0.40%")
        totals.tokens?.input = 1_000_000; totals.inputSplit = GatewayTokenSplit(total: 1_000_000, part: 4, samples: 1)
        XCTAssertEqual(SessionStatsPresentation(gateway: totals, work: nil).cacheHit, "<0.01", "Two places still never write a real hit as zero")
    }

    /// The session's cache hit always has two decimal places (the owner asked
    /// for them), and still never rounds a partial hit up to a full one.
    func testTheSessionCacheHitHasTwoDecimalPlaces() {
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 50, prompt: 100), "50.00")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 7_594, prompt: 10_000), "75.94")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 505, prompt: 1_000), "50.50")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 100, prompt: 100), "100.00")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 0, prompt: 100), "0.00")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 99_996, prompt: 100_000), "99.996", "Never rounded up to a full hit")
        XCTAssertEqual(MetricFormat.paddedCacheHitPercent(read: 4, prompt: 1_000_000), "<0.01")
        XCTAssertNil(MetricFormat.paddedCacheHitPercent(read: 10, prompt: 0))
    }

    /// The context dialog's detail line and the ring it explains agree to the
    /// last digit either of them shows: 99.96% is never "100.0%".
    func testTheContextDetailAgreesWithTheRingItExplains() {
        let meter = ContextMeterPresentation(context: ["tokens": .number(199_920), "contextWindow": .number(200_000),
                                                       "estimated": .bool(false), "method": .string("provider-count"),
                                                       "scope": .string("last-request")])
        XCTAssertEqual(meter.fraction.flatMap { MetricFormat.occupancyPercent($0) }, "99.96")
        XCTAssertTrue(meter.detailLabel.contains(" 99.96% "), meter.detailLabel)
        XCTAssertFalse(meter.detailLabel.contains("100.0%"), meter.detailLabel)
        let small = ContextMeterPresentation(context: ["tokens": .number(24_600), "contextWindow": .number(200_000), "scope": .string("last-request")])
        XCTAssertTrue(small.detailLabel.contains(" 12.3% "), small.detailLabel)
        let over = ContextMeterPresentation(context: ["tokens": .number(210_000), "contextWindow": .number(200_000), "scope": .string("last-request")])
        XCTAssertTrue(over.detailLabel.contains(" 105.0% "), "A count past the window says by how much: \(over.detailLabel)")
    }

    // MARK: The settled rate

    func testTheSettledRateFoldsOnlyTheRequestsThatReportedBothHalves() {
        var fold = SettledThroughput()
        // All 35 tokens over one second, including zero measured TTFT.
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: 1_000, outputTokens: 35)
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: nil, outputTokens: 50)
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: 500, outputTokens: nil)
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: 0, outputTokens: 10)
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: -1, outputTokens: 10)
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: .infinity, outputTokens: 10)
        XCTAssertEqual(fold.samples, 1)
        XCTAssertEqual(fold.requests, 6)
        XCTAssertEqual(fold.tokensPerSecond, 35)
        XCTAssertEqual(fold.label, "35 tok/s")
        XCTAssertEqual(fold.coverage, "1/6 requests measured")

        var second = SettledThroughput()
        second.add(ttftMilliseconds: 0, decodeMilliseconds: 1_000, outputTokens: 67)
        fold.add(second)
        XCTAssertEqual(fold.tokensPerSecond, 51, "A group uses one division of sums: (35 + 67) / 2 s")
        XCTAssertEqual(fold.samples, 2); XCTAssertEqual(fold.requests, 7)

        var none = SettledThroughput()
        none.add(ttftMilliseconds: 0, decodeMilliseconds: nil, outputTokens: nil)
        XCTAssertNil(none.tokensPerSecond); XCTAssertNil(none.label)
        XCTAssertEqual(none.coverage, "0/1 requests measured")
        XCTAssertNil(SettledThroughput().coverage, "Nothing considered is not partial coverage")
    }

    func testTheSettledRateCountsAllOutputIncludingSingleTokenReplies() throws {
        var fold = SettledThroughput()
        fold.add(ttftMilliseconds: 500, decodeMilliseconds: 1_000, outputTokens: 101)
        XCTAssertEqual(fold.tokensPerSecond, 101 / 1.5)
        XCTAssertEqual(fold.outputTokens, 101)
        fold.add(ttftMilliseconds: 250, decodeMilliseconds: 0, outputTokens: 1)
        fold.add(ttftMilliseconds: 500, decodeMilliseconds: 2_000, outputTokens: 0)
        XCTAssertEqual(fold.samples, 2)
        XCTAssertEqual(fold.requests, 3)
        XCTAssertEqual(fold.coverage, "2/3 requests measured")
        fold.add(ttftMilliseconds: 0, decodeMilliseconds: 500, outputTokens: 51)
        XCTAssertEqual(fold.tokensPerSecond, 153 / 2.25)
        fold.add(ttftMilliseconds: 200, decodeMilliseconds: 49, outputTokens: 1_000)
        XCTAssertEqual(fold.samples, 3, "Below the total floor is unmeasured")
        fold.add(ttftMilliseconds: 200, decodeMilliseconds: 50, outputTokens: 2)
        XCTAssertEqual(fold.samples, 4)
        XCTAssertEqual(fold.outputTokens, 155)
        XCTAssertEqual(try XCTUnwrap(fold.tokensPerSecond), 155 / 2.5, accuracy: 1e-9)
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

    /// The two requests of `fixtureSession()`, as the popovers read them
    /// from the archive: together they report exactly the fixture's totals.
    private func fixtureHistory() -> SessionStatsHistory {
        SessionStatsHistory(requests: (1...2).map { index in
            SessionTimingSample(id: "r\(index)", wall: Date(timeIntervalSince1970: 1_000_000 + Double(index)), ttftMilliseconds: 400,
                                streamingMilliseconds: 500, outputTokens: 1_900, costUSD: 0.00125, requestMilliseconds: 900,
                                model: "deepseek-v4-flash", inputTokens: 6_000, cacheReadTokens: 3_000, reasoningTokens: 450, turn: "u1")
        })
    }
    private func figure(_ id: String, in figures: [SessionStatsFigure]) -> SessionStatsFigure? { figures.first { $0.id == id } }

    func testSessionPillsReadAsTheOwnerAskedFor() throws {
        let stats = SessionStatsPresentation(gateway: fixtureSession(), work: fixtureWork())
        XCTAssertEqual(stats.gaugeLabel, "1 turn 2 steps · 34 tok/s")
        XCTAssertEqual(stats.usageLabel, "15.8K tok · 6K uncached · 6K cached · 3.8K out (900 reasoning) · Cache hit 50.00% · $0.0025")
        XCTAssertEqual(stats.tokenSplit, ["6K uncached", "6K cached", "3.8K out (900 reasoning)"], "The parts add up to the total: 6K + 6K + 3.8K")
        XCTAssertTrue(stats.hasUsage); XCTAssertTrue(stats.hasTimeDialog)
        // What the usage pill opens leads with the exact total.
        let tokens = SessionTokenCharts(inputs: SessionStatsInputs(gateway: fixtureSession()), history: nil)
        XCTAssertEqual(figure("tokens", in: tokens.hero)?.value, "15,800")
    }

    /// The session statistics popover leads with the four timings, larger:
    /// AI and tool time from the helper's clocks, the average first token and
    /// the settled output speed, each saying what it covers.
    func testSessionStatisticsPopoverLeadsWithTheFourTimings() throws {
        let time = SessionTimeCharts(inputs: SessionStatsInputs(gateway: fixtureSession(), work: fixtureWork()), history: nil)
        let figures = time.hero + time.details
        XCTAssertEqual(figure("ai", in: figures)?.value, "12.4s")
        XCTAssertEqual(figure("tools", in: figures)?.value, "6.6s")
        XCTAssertEqual(figure("ttft", in: figures)?.value, "400 ms")
        XCTAssertEqual(figure("speed", in: figures)?.value, "34 tok/s")
        XCTAssertEqual(figure("speed", in: figures)?.caption, "2 requests measured")
        XCTAssertEqual(figure("ttft", in: figures)?.caption, "average of 2")
        XCTAssertTrue(figures.allSatisfy { !$0.partial }, "Complete coverage is never written in warning ink")
        XCTAssertEqual(time.notes.first, SettledThroughput.explanation)
        // Where the time went is the same clocks: the waits, the rest of the AI time, the tools.
        XCTAssertEqual(time.split?.parts.map(\.value), ["800 ms", "11.6s", "6.6s"])
    }

    /// The token usage popover carries every bucket: the exact total, the cost
    /// and the cache hit on top, and cached input, uncached input, reasoning and
    /// the rest of the output as the parts of that total.
    func testTokenUsagePopoverCarriesEveryBucketWithItsCost() throws {
        let tokens = SessionTokenCharts(inputs: SessionStatsInputs(gateway: fixtureSession(), work: fixtureWork()), history: fixtureHistory())
        XCTAssertEqual(tokens.hero.map(\.value), ["15,800", "$0.0025", "50.00%"])
        XCTAssertEqual(figure("tokens", in: tokens.hero)?.caption, "12,000 in · 3,800 out")
        XCTAssertNil(tokens.coverage, "Every request reported every figure")
        let parts = Dictionary(uniqueKeysWithValues: (tokens.composition?.parts ?? []).map { ($0.id, $0.value) })
        XCTAssertEqual(parts, [.cached: "6,000", .uncached: "6,000", .reasoning: "900", .output: "2,900"],
                       "3,800 output, 900 of it reasoning; 12,000 input, 6,000 of it cached")
        XCTAssertEqual(tokens.composition?.totalLabel, "15,800", "The parts are the pill's total, nothing counted twice")
        XCTAssertTrue(tokens.notes.contains { $0.contains("Cached input is part of input") })
    }

    func testAPartlyReportingSessionNamesItsCoverageInsteadOfHidingIt() throws {
        var totals = fixtureSession()
        totals.requests = 5
        totals.decodeSamples = 2; totals.ttftSamples = 2
        totals.costSamples = 3
        let stats = SessionStatsPresentation(gateway: totals, work: fixtureWork())
        XCTAssertEqual(stats.throughput.coverage, "2/5 requests measured")
        let time = SessionTimeCharts(inputs: SessionStatsInputs(gateway: totals, work: fixtureWork()), history: nil)
        let speed = figure("speed", in: time.hero), ttft = figure("ttft", in: time.details)
        XCTAssertEqual(speed?.caption, "2/5 requests measured"); XCTAssertEqual(speed?.partial, true, "Partial coverage reads in warning ink")
        XCTAssertEqual(ttft?.caption, "average of 2/5"); XCTAssertEqual(ttft?.partial, true)
        XCTAssertTrue(time.notes.contains { $0.contains("covers the 2 that recorded it") })
        let tokens = SessionTokenCharts(inputs: SessionStatsInputs(gateway: totals), history: nil)
        XCTAssertEqual(tokens.coverage, "Tokens reported by 2 of 5 requests, cost by 3 of 5; the figures count only those.",
                       "The popover names the requests that reported no cost instead of hiding them")
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
        XCTAssertEqual(session.cacheHit, "50.00")
        var summary = fixtureTurn()
        summary.accounting.cacheWrite = 600
        let turn = TurnPillsPresentation(summary)
        XCTAssertEqual(turn.totalTokens, 15_800)
        XCTAssertEqual(turn.cacheHit, "50")
        XCTAssertEqual(turn.usageRows.first { $0.name == "Cache write" }?.value, "600 tok")
    }

    /// A cache hit is the cached share of the input of the requests that
    /// reported both counters. Two requests that reported their input but no
    /// cache counter at all are not two requests that missed the cache: they
    /// stay out of the share, and the coverage says so.
    func testTheCacheHitCountsOnlyTheRequestsThatReportedBothCounters() {
        var gateway = GatewayTotals(requests: 3, costSamples: 3, costUSD: 0.003, cacheReadTokens: 900, cacheReadSamples: 1)
        gateway.tokens = GatewayTokenTotals(input: 3_000, output: 300, total: 3_300, inputSamples: 3, outputSamples: 3, samples: 3)
        gateway.inputSplit = GatewayTokenSplit(total: 1_000, part: 900, samples: 1)
        gateway.uncachedInputReportedTokens = 100; gateway.uncachedInputSamples = 1
        let session = SessionStatsPresentation(gateway: gateway, work: nil)
        XCTAssertEqual(session.cacheHit, "90.00")
        // One request of three reported its cache use: the input does not
        // split, since its parts would not add up to the total.
        XCTAssertEqual(session.usageLabel, "3.3K tok · 3K in · 300 out · Cache hit 90.00% · $0.003")
        let popover = SessionTokenCharts(inputs: SessionStatsInputs(gateway: gateway), history: nil)
        XCTAssertEqual(figure("cache", in: popover.hero)?.value, "90.00%")
        XCTAssertEqual(popover.coverage, "1 of 3 requests reported their cache use; the figures count only those.")

        var summary = fixtureTurn()
        summary.accounting.requests = 3
        summary.accounting.input = 3_000; summary.accounting.inputSamples = 3
        summary.accounting.cached = 900; summary.accounting.cachedSamples = 1
        summary.accounting.inputSplit = GatewayTokenSplit(total: 1_000, part: 900, samples: 1)
        let turn = TurnPillsPresentation(summary)
        XCTAssertEqual(turn.cacheHit, "90")
        XCTAssertEqual(turn.usageRows.first { $0.name == "Cache hit" }?.coverage, "1/3 requests reported")
        // With no request reporting both, there is no share to show.
        summary.accounting.inputSplit = nil
        XCTAssertNil(TurnPillsPresentation(summary).cacheHit)
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
        XCTAssertTrue(turn.timeNotes.contains { $0.contains("valid timing from request to last output over at least 250 ms") }, "\(turn.timeNotes)")
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
        // All 34 output tokens over 400 ms TTFT + one second of generation.
        XCTAssertEqual(first.throughput, "24 tok/s")
        XCTAssertEqual(first.cost, "$0.0025")
        XCTAssertFalse(first.unmeasured)
        let second = ledger.rows[1]
        XCTAssertEqual(second.model, "openai-responses", "With no reported model the ledger names the API it went out on")
        XCTAssertEqual([second.output, second.ttft, second.generation, second.throughput, second.cost], ["—", "—", "—", "—", "—"])
        XCTAssertTrue(second.unmeasured)
        XCTAssertEqual(ledger.throughput.tokensPerSecond, 34 / 1.4)
        XCTAssertTrue(ledger.coverageNote.contains("24 tok/s over 1 of 2 listed requests"), ledger.coverageNote)
        XCTAssertTrue(ledger.coverageNote.contains("1 request has no output speed"), ledger.coverageNote)
        XCTAssertTrue(ledger.copyText.contains("deepseek-v4-flash"))
        XCTAssertEqual(ledger.subtitle, "2 requests")
    }

    func testAFullyReportingLedgerDoesNotApologiseForCoverage() throws {
        let sample = SessionTimingSample(id: "a", wall: Date(timeIntervalSince1970: 1_000_000), ttftMilliseconds: 400,
                                         streamingMilliseconds: 1_000, outputTokens: 34, requestMilliseconds: 1_400)
        let ledger = SessionRequestLedger(history: SessionTimingHistory(samples: [sample], hasOlderRequests: true, completedRequests: 40))
        XCTAssertEqual(ledger.subtitle, "Most recent 1 request")
        XCTAssertTrue(ledger.coverageNote.contains("every listed request was measured"), ledger.coverageNote)
        XCTAssertTrue(ledger.coverageNote.hasPrefix("Session throughput 24 tok/s"), "34 tokens over 1.4 seconds including TTFT. \(ledger.coverageNote)")
    }
}

extension MetricPillsTests {
    func testOutputSpeedIncludesTTFTCountsEveryTokenAndUsesOneDivisionOfSums() throws {
        let a = SessionTimingSample(id: "a", wall: Date(), ttftMilliseconds: 2_000, streamingMilliseconds: 1_000, outputTokens: 101, requestMilliseconds: 9_000)
        let b = SessionTimingSample(id: "b", wall: Date(), ttftMilliseconds: 100, streamingMilliseconds: 400, outputTokens: 49)
        XCTAssertEqual(try XCTUnwrap(a.settledTokensPerSecond), 101 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.ttftMilliseconds, 2_000)
        let group = SessionTimingHistory(samples: [a, b]).settledThroughput
        XCTAssertEqual(group.outputTokens, 150)
        XCTAssertEqual(group.decodeMilliseconds, 3_500)
        XCTAssertEqual(try XCTUnwrap(group.tokensPerSecond), 150 / 3.5, accuracy: 1e-9)
        XCTAssertEqual(SessionRequestLedger(history: SessionTimingHistory(samples: [a, b])).throughput, group)
    }

    func testOutputSpeedFloorValidityAndArchiveSQLMatchSwift() throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("output-speed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try CaptureDatabase(url: root.appendingPathComponent("rates.sqlite"))
        try db.execute("CREATE TABLE attempts(outcome TEXT,ttft_ms REAL,stream_ms REAL,output_tokens REAL)")
        let cases: [(Double?, Double?, Double?, String, Double?)] = [
            (2_000, 1_000, 101, "completed", 101 / 3.0),
            (250, 0, 1, "completed", 4), (200, 50, 10, "completed", 40),
            (0, 250, 2, "completed", 8), (200, 49, 100, "completed", nil),
            (nil, 1_000, 100, "completed", nil), (1_000, nil, 100, "completed", nil),
            (-1, 1_000, 100, "completed", nil), (1_000, -1, 100, "completed", nil),
            (.infinity, 1_000, 100, "completed", nil), (1_000, .infinity, 100, "completed", nil),
            (.greatestFiniteMagnitude, .greatestFiniteMagnitude, 100, "completed", nil),
            (1_000, 1_000, nil, "completed", nil), (1_000, 1_000, 0, "completed", nil),
            (1_000, 1_000, .infinity, "completed", nil), (1_000, 1_000, 100, "failed", nil)
        ]
        var samples: [SessionTimingSample] = []
        for (index, item) in cases.enumerated() {
            let (ttft, span, output, outcome, expected) = item
            try db.execute("INSERT INTO attempts VALUES(?,?,?,?)", [.text(outcome)] + [ttft, span, output].map { $0.map(CaptureSQLValue.real) ?? .null })
            let sample = SessionTimingSample(id: String(index), wall: Date(), ttftMilliseconds: ttft, streamingMilliseconds: span, outputTokens: output, outcome: outcome)
            XCTAssertEqual(sample.settledTokensPerSecond, expected, "case \(index)")
            samples.append(sample)
        }
        let swift = SessionRequestLedger(history: SessionTimingHistory(samples: samples)).throughput
        let row = try XCTUnwrap(db.rows("SELECT COUNT(*) AS requests,\(PayloadArchive.settledThroughputSQL) FROM attempts").first)
        let sql = PayloadArchive.gatewayTotals(row).settledThroughput
        XCTAssertEqual(sql, swift)
        XCTAssertEqual(SessionTimingHistory(samples: samples).settledThroughput, swift)
        XCTAssertEqual(swift.samples, 4); XCTAssertEqual(swift.requests, cases.count)
        XCTAssertEqual(swift.outputTokens, 114); XCTAssertEqual(swift.decodeMilliseconds, 3_750)
    }

    func testOutputSpeedWordingIncludesTheWaitAndHiddenReasoning() {
        for explanation in [SettledThroughput.explanation, SessionRatePresentation.explanation, MonitorRateAverage.explanation, MenuBarRateText.scope] {
            XCTAssertTrue(explanation.contains("time to first token included"), explanation)
            XCTAssertTrue(explanation.contains("hidden reasoning included"), explanation)
            for old in ["after the first", "decode speed", "not round-trip latency"] { XCTAssertFalse(explanation.contains(old), explanation) }
        }
        XCTAssertFalse(SessionTimingMetric.rate.title.contains("decode"))
        XCTAssertEqual(SessionTimeCharts.hero(GatewayTotals()).last?.title, "output speed")
    }
}

extension MetricPillsTests {
    func testSerializedOldDefinitionSumsCannotMixWithOutputSpeed() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayTotals(requests: 2))) as? [String: Any])
        json["decodeMilliseconds"] = 1_000; json["decodeOutputTokens"] = 200; json["decodeSamples"] = 2
        let old = try JSONDecoder().decode(GatewayTotals.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.settledThroughput.tokensPerSecond)
        XCTAssertEqual(old.settledThroughput.requests, 2)
        let raw = Data(#"{"decodeMilliseconds":1000,"outputTokens":200,"samples":2,"requests":2}"#.utf8)
        let oldSum = try JSONDecoder().decode(SettledThroughput.self, from: raw)
        XCTAssertNil(oldSum.tokensPerSecond); XCTAssertEqual(oldSum.requests, 2)
        let new = SessionTimingHistory(samples: [.init(id: "one", wall: Date(), ttftMilliseconds: 200, streamingMilliseconds: 50, outputTokens: 10)]).settledThroughput
        XCTAssertEqual(try JSONDecoder().decode(SettledThroughput.self, from: JSONEncoder().encode(new)), new)
        var combined = new; combined.add(oldSum)
        XCTAssertEqual(combined.tokensPerSecond, 40); XCTAssertEqual(combined.requests, 3)
    }
}
