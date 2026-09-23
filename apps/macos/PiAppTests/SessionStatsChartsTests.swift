import XCTest
import AppKit
@testable import PiApp

/// A session as the statistics popovers read it: its retained requests and
/// the footer totals the archive would report for exactly those requests.
enum SessionStatsFixture {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// One request with the figures a gateway reports; nil stays unreported.
    static func request(_ index: Int, turn: String = "t1", model: String? = "gpt-5.4-mini", outcome: String = "completed",
                        ttft: Double? = 400, stream: Double? = 1_000, request: Double? = nil, input: Double? = 1_000,
                        cached: Double? = 600, write: Double? = nil, output: Double? = 200, reasoning: Double? = nil,
                        cost: Double? = 0.001) -> SessionTimingSample {
        SessionTimingSample(id: "r\(index)", wall: start.addingTimeInterval(Double(index) * 20), ttftMilliseconds: ttft,
                            streamingMilliseconds: stream, outputTokens: output, costUSD: cost,
                            requestMilliseconds: request ?? ttft.flatMap { t in stream.map { t + $0 } },
                            outcome: outcome, api: "openai-responses", model: model, inputTokens: input, cacheReadTokens: cached,
                            cacheWriteTokens: write, reasoningTokens: reasoning, turn: turn, purpose: "turn")
    }

    /// Eighteen requests over five turns and two models: the context grows,
    /// the cache catches up with it, one attempt fails and one first token is slow.
    static func session(requests count: Int = 18) -> SessionStatsHistory {
        var samples: [SessionTimingSample] = []
        for index in 1...count {
            let turn = "t\((index - 1) / 4 + 1)"
            let fast = index % 3 == 0
            let context = 8_000 + Double(index) * 2_400
            let cached = index == 1 ? 0 : context * min(0.92, 0.35 + Double(index) * 0.05)
            let failed = index == 7
            samples.append(request(index, turn: turn, model: fast ? "claude-sonnet-4.5" : "gpt-5.4-mini", outcome: failed ? "failed" : "completed",
                                   ttft: failed ? 900 : (index == 5 ? 3_400 : 350 + Double((index * 137) % 900)),
                                   stream: failed ? nil : 800 + Double((index * 611) % 5_200),
                                   request: failed ? 2_100 : nil,
                                   input: failed ? nil : context, cached: failed ? nil : cached,
                                   write: index == 2 ? 1_200 : nil,
                                   output: failed ? nil : 180 + Double((index * 97) % 900),
                                   reasoning: failed ? nil : (fast ? 0 : 60 + Double((index * 53) % 400)),
                                   cost: failed ? nil : 0.0004 + context / 4_000_000))
        }
        return SessionStatsHistory(requests: samples)
    }

    /// The footer totals the archive's aggregate would give for these requests.
    static func gateway(_ history: SessionStatsHistory) -> GatewayTotals {
        let samples = history.requests
        func sum(_ values: [Double?]) -> (Double?, Int) {
            let reported = values.compactMap { $0 }
            return (reported.isEmpty ? nil : reported.reduce(0, +), reported.count)
        }
        var totals = GatewayTotals(requests: samples.count)
        (totals.costUSD, totals.costSamples) = sum(samples.map(\.costUSD))
        (totals.cacheReadTokens, totals.cacheReadSamples) = sum(samples.map(\.cacheReadTokens))
        (totals.cacheWriteTokens, totals.cacheWriteSamples) = sum(samples.map(\.cacheWriteTokens))
        let input = sum(samples.map(\.inputTokens)), output = sum(samples.map(\.outputTokens)), reasoning = sum(samples.map(\.reasoningTokens))
        if input.1 > 0 || output.1 > 0 {
            totals.tokens = GatewayTokenTotals(input: input.0, output: output.0, total: (input.0 ?? 0) + (output.0 ?? 0),
                                               inputSamples: input.1, outputSamples: output.1, samples: min(input.1, output.1))
            totals.tokens?.reasoning = reasoning.0; totals.tokens?.reasoningSamples = reasoning.1
        }
        let paired = samples.filter { ($0.inputTokens ?? -1) >= ($0.cacheReadTokens ?? .infinity) }
        if !paired.isEmpty {
            let total = paired.compactMap(\.inputTokens).reduce(0, +), part = paired.compactMap(\.cacheReadTokens).reduce(0, +)
            totals.inputSplit = GatewayTokenSplit(total: total, part: part, samples: paired.count)
            totals.uncachedInputReportedTokens = total - part; totals.uncachedInputSamples = paired.count
        }
        var decode = SettledThroughput(requests: samples.count)
        for sample in samples where sample.outcome == "completed" {
            var one = SettledThroughput(); one.add(decodeMilliseconds: sample.streamingMilliseconds, outputTokens: sample.outputTokens)
            decode.decodeMilliseconds += one.decodeMilliseconds; decode.outputTokens += one.outputTokens; decode.samples += one.samples
        }
        totals.decodeMilliseconds = decode.decodeMilliseconds; totals.decodeOutputTokens = decode.outputTokens; totals.decodeSamples = decode.samples
        (totals.ttftMilliseconds, totals.ttftSamples) = sum(samples.map(\.ttftMilliseconds))
        totals.turnCount = Set(samples.compactMap(\.turn)).count
        return totals
    }

    static func inputs(_ history: SessionStatsHistory, modelMs: Double = 61_000, toolMs: Double = 23_500, toolCalls: Int = 3) -> SessionStatsInputs {
        var inputs = SessionStatsInputs(gateway: gateway(history))
        inputs.work = WorkSplit(timing: ["sessionModelMs": .number(modelMs), "sessionToolMs": .number(toolMs)])
        for turn in Set(history.requests.compactMap(\.turn)) { inputs.toolCallsByTurn[turn] = toolCalls }
        return inputs
    }
}

/// The statistics popovers' series, asserted as values: every bar, share,
/// point and caption comes out of these builders before any view draws it.
final class SessionStatsChartsTests: XCTestCase {

    // MARK: Formats

    func testSharesDurationsAndTicksReadHonestly() {
        XCTAssertEqual(SessionStatsFormat.share(0.5), "50%")
        XCTAssertEqual(SessionStatsFormat.share(0.004), "<1%", "A real sliver is never 0%")
        XCTAssertEqual(SessionStatsFormat.share(0.9996), "99.96%", "Nothing short of the whole reads 100%")
        XCTAssertEqual(SessionStatsFormat.share(1), "100%")
        XCTAssertEqual(SessionStatsFormat.duration(24), "24 ms", "A short clock reads in milliseconds, never 0.0s")
        XCTAssertEqual(SessionStatsFormat.duration(61_000), workDuration(61_000))
        XCTAssertEqual(SessionStatsFormat.ticks(upTo: 930, within: 1_004), [0, 500, 1_000], "Ticks reach the top of the axis")
        XCTAssertEqual(SessionStatsFormat.ticks(upTo: 7_400, within: 7_992), [0, 2_500, 5_000, 7_500])
        XCTAssertEqual(SessionStatsFormat.ticks(upTo: 0), [0])
        XCTAssertEqual(SessionStatsFormat.costTicks([0, 0.5, 1, 1.5]), ["$0", "$0.50", "$1.00", "$1.50"], "One money style on one axis")
        XCTAssertEqual(SessionStatsFormat.costTicks([0, 0.025, 0.05]), ["$0", "$0.025", "$0.050"])
        XCTAssertEqual(SessionStatsFormat.costTicks([0, 5, 10]), ["$0", "$5", "$10"])
    }

    /// Every label an axis or a mark carries fits inside its chart at the
    /// popover's size, whatever the session. The timeline's axis labels are
    /// its full values, measured in the popovers' own type: they hang inward
    /// at the axis's two ends and never run into each other; the number after
    /// a marked row fits before the edge; and every y axis leaves its top
    /// label, and the figure over the latest bar or the line's end, room.
    func testEveryChartLabelFitsInsideItsChart() {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        func width(_ text: String) -> Double { Double((text as NSString).size(withAttributes: [.font: font]).width) }
        XCTAssertLessThanOrEqual(Double(font.ascender - font.descender), 2 * SessionStatsFormat.labelHalfHeight - 1,
                                 "The room kept for a label is taller than the label")
        let sessions: [(String, SessionStatsHistory)] = [
            ("one request", SessionStatsHistory(requests: [SessionStatsFixture.request(1, reasoning: 80)])),
            ("session", SessionStatsFixture.session()),
            ("long", SessionStatsFixture.session(requests: 64)),
            ("very long", SessionStatsFixture.session(requests: 2_000)),
            ("milliseconds", SessionStatsHistory(requests: (1...4).map { SessionStatsFixture.request($0, ttft: Double($0) * 3, stream: Double($0) * 120) })),
            ("minutes", SessionStatsHistory(requests: (1...6).map { SessionStatsFixture.request($0, turn: "t\($0)", ttft: 9_000, stream: 95_000 + Double($0) * 7_000) })),
        ]
        let plotWidth = SessionRequestTimeline.plotWidth
        for (name, history) in sessions {
            let inputs = SessionStatsFixture.inputs(history)
            let time = SessionTimeCharts(inputs: inputs, history: history), tokens = SessionTokenCharts(inputs: inputs, history: history)
            let timeline = try! XCTUnwrap(time.timeline, name)
            XCTAssertEqual(timeline.tickLabels, timeline.ticks.map(SessionStatsFormat.milliseconds), "\(name): every tick is labelled with its full value")
            var previousEnd = -Double.infinity
            for (index, tick) in timeline.ticks.enumerated() {
                let label = timeline.tickLabels[index], labelWidth = width(label), x = tick / timeline.domain * plotWidth
                let start: Double = switch timeline.tickAnchors[index] {
                case .leading: x
                case .center: x - labelWidth / 2
                case .trailing: x - labelWidth
                }
                XCTAssertGreaterThanOrEqual(start, -0.5, "\(name): “\(label)” starts before the chart")
                XCTAssertLessThanOrEqual(start + labelWidth, plotWidth + 0.5, "\(name): “\(label)” runs past the chart's edge")
                XCTAssertGreaterThanOrEqual(start, previousEnd + 4, "\(name): “\(label)” runs into the label before it")
                previousEnd = start + labelWidth
            }
            XCTAssertEqual(timeline.tickAnchors.first, .leading, "\(name): the first label starts at the axis")
            for row in timeline.rows {
                guard let marker = row.marker else { continue }
                XCTAssertLessThanOrEqual(row.end / timeline.domain * plotWidth + SessionStatsFormat.markerSpacing + width(marker), plotWidth + 0.5,
                                         "\(name): \(marker) runs past the chart's edge")
                XCTAssertLessThanOrEqual(width(marker), SessionStatsFormat.labelWidth(marker) - 1, "\(name): the room kept for \(marker) is too tight")
            }
            func assertTopLabelFits(_ ticks: [Double], _ top: Double, _ plotHeight: Double, _ chart: String) {
                guard let highest = ticks.last, top > 0 else { return }
                XCTAssertGreaterThanOrEqual((1 - highest / top) * plotHeight, SessionStatsFormat.labelHalfHeight - 0.001,
                                            "\(name): the \(chart) chart's top label leaves the chart")
            }
            if let speed = time.speed { assertTopLabelFits(speed.ticks, speed.yMaximum, SessionSpeedSeries.plotHeight, "speed") }
            if let bars = tokens.perRequest, let last = bars.bars.last {
                assertTopLabelFits(bars.ticks, bars.yMaximum, SessionTokenBars.plotHeight, "per-request")
                XCTAssertGreaterThanOrEqual((1 - last.total / bars.yMaximum) * SessionTokenBars.plotHeight,
                                            2 * SessionStatsFormat.labelHalfHeight + SessionStatsFormat.endLabelSpacing - 0.001,
                                            "\(name): the latest bar's label has no room over it")
            }
            if let cost = tokens.cost, let last = cost.points.last {
                assertTopLabelFits(cost.ticks, cost.yMaximum, SessionCostSeries.plotHeight, "cost")
                XCTAssertGreaterThanOrEqual((1 - last.cumulative / cost.yMaximum) * SessionCostSeries.plotHeight, SessionStatsFormat.labelHalfHeight - 0.001,
                                            "\(name): the cost line's total has no room beside it")
            }
        }
    }

    // MARK: The request timeline

    func testTheTimelineSplitsEachRequestIntoItsWaitAndItsGeneration() {
        let history = SessionStatsHistory(requests: [
            SessionStatsFixture.request(1, ttft: 400, stream: 1_000, output: 34),
            SessionStatsFixture.request(2, ttft: nil, stream: nil, request: 900),
            SessionStatsFixture.request(3, outcome: "failed", ttft: 700, stream: nil, request: 2_000, input: nil, cached: nil, output: nil, cost: nil),
        ])
        let timeline = try! XCTUnwrap(SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history).timeline)
        XCTAssertEqual(timeline.rows.map(\.number), [1, 2, 3])
        let measured = timeline.rows[0], unsplit = timeline.rows[1], failed = timeline.rows[2]
        XCTAssertEqual([measured.waiting, measured.generating, measured.unsplit], [400, 1_000, 0], "The wait for the first token, then the generation")
        XCTAssertFalse(measured.failed)
        XCTAssertEqual([unsplit.waiting, unsplit.generating, unsplit.unsplit], [0, 0, 900],
                       "A request that recorded no first token is drawn whole, never split by a guess")
        XCTAssertTrue(failed.failed, "A failed attempt is drawn as a failure")
        XCTAssertEqual(failed.unsplit, 2_000, "for as long as it ran")
        XCTAssertTrue(timeline.hasFailures); XCTAssertTrue(timeline.hasUnsplit)
        // The request's own settled rate, however the app defines it.
        let rate = MetricFormat.throughput(try! XCTUnwrap(history.requests[0].settledTokensPerSecond))
        XCTAssertTrue(measured.caption.contains("first token 400 ms") && measured.caption.contains("generating 1s") && measured.caption.contains(rate),
                      measured.caption)
        XCTAssertTrue(failed.caption.contains("failed after 2s"), failed.caption)
        XCTAssertTrue(timeline.latestCaption.hasPrefix("Latest · Request 3 · "), timeline.latestCaption)
        XCTAssertGreaterThanOrEqual(timeline.domain, 2_000, "The axis reaches the longest bar")
        XCTAssertEqual(timeline.ticks.first, 0)
        XCTAssertTrue(timeline.accessibility.contains("1 failed attempt"), timeline.accessibility)
    }

    func testALongSessionShowsItsLatestRequestsAndSaysSo() {
        let history = SessionStatsFixture.session(requests: 60)
        let timeline = try! XCTUnwrap(SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history).timeline)
        XCTAssertEqual(SessionRequestTimeline.maximumRows, 32)
        XCTAssertEqual(timeline.rows.count, 32)
        XCTAssertEqual(timeline.rows.first?.number, 29, "The latest thirty-two, oldest of them first")
        XCTAssertEqual(timeline.rows.last?.number, 60)
        XCTAssertTrue(timeline.subtitle.contains("The latest 32 of 60 requests"), timeline.subtitle)
        // Turns alternate their band, so the requests of one turn read together.
        let bands = timeline.rows.map(\.band)
        XCTAssertTrue(bands.contains(true) && bands.contains(false))
        XCTAssertEqual(timeline.rows[0].band, timeline.rows[3].band, "Requests 29–32 are one turn")
        XCTAssertNotEqual(timeline.rows[3].band, timeline.rows[4].band, "and request 33 starts the next")
    }

    /// The timeline names its slowest first token and longest generation,
    /// under the chart and beside the two rows themselves.
    func testTheTimelineNamesItsSlowestAndLongestRequests() {
        let history = SessionStatsFixture.session()
        let timeline = try! XCTUnwrap(SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history).timeline)
        let completed = history.requests.filter { $0.outcome == "completed" }
        let slow = try! XCTUnwrap(completed.max { ($0.ttftMilliseconds ?? 0) < ($1.ttftMilliseconds ?? 0) })
        let long = try! XCTUnwrap(completed.max { ($0.streamingMilliseconds ?? 0) < ($1.streamingMilliseconds ?? 0) })
        let slowNumber = history.requests.firstIndex(of: slow)! + 1, longNumber = history.requests.firstIndex(of: long)! + 1
        XCTAssertEqual(timeline.highlights, "Slowest first token: #\(slowNumber), \(MetricFormat.latency(slow.ttftMilliseconds!)) · longest generation: #\(longNumber), \(MetricFormat.latency(long.streamingMilliseconds!))")
        XCTAssertEqual(timeline.rows.compactMap(\.marker), ["#\(slowNumber)", "#\(longNumber)"], "The two rows carry their numbers, and no other row does")
        XCTAssertEqual(timeline.rows[slowNumber - 1].marker, "#\(slowNumber)")
    }

    // MARK: Where the time went

    func testTheTimeSplitCutsTheHelpersAIClockAtTheMeasuredFirstTokens() {
        let history = SessionStatsFixture.session()
        let inputs = SessionStatsFixture.inputs(history, modelMs: 61_000, toolMs: 23_500)
        let split = try! XCTUnwrap(SessionTimeCharts(inputs: inputs, history: history).split)
        let waiting = history.requests.compactMap(\.ttftMilliseconds).reduce(0, +)
        XCTAssertEqual(split.parts.map(\.id), [.waiting, .generating, .tools])
        XCTAssertEqual(split.parts[0].milliseconds, waiting, accuracy: 0.001, "Waiting is every recorded first token")
        XCTAssertEqual(split.parts[1].milliseconds, 61_000 - waiting, accuracy: 0.001, "Generating is the rest of the AI clock")
        XCTAssertEqual(split.parts[2].milliseconds, 23_500)
        XCTAssertEqual(split.parts.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9, "The parts are the whole")
        XCTAssertEqual(split.total, workDuration(84_500))
        XCTAssertNil(split.note, "Every request recorded its first token")

        // Without the helper's clocks, the bar is the model requests alone and says so.
        var bare = inputs; bare.work = nil
        let modelOnly = try! XCTUnwrap(SessionTimeCharts(inputs: bare, history: history).split)
        XCTAssertEqual(modelOnly.parts.map(\.id), [.waiting, .generating])
        XCTAssertTrue(modelOnly.note?.contains("Tool time was not recorded") == true)

        // First tokens measured on some requests only: the note says how many.
        var partial = inputs; partial.gateway.ttftSamples = 5
        XCTAssertTrue(SessionTimeCharts(inputs: partial, history: history).split?.note?.contains("5 of 18 requests") == true)
    }

    // MARK: Speed

    func testSpeedPlotsEachMeasuredRequestAgainstTheSessionAverage() {
        let history = SessionStatsFixture.session()
        let inputs = SessionStatsFixture.inputs(history)
        let speed = try! XCTUnwrap(SessionTimeCharts(inputs: inputs, history: history).speed)
        let measured = history.requests.filter { $0.settledTokensPerSecond != nil }
        XCTAssertEqual(speed.points.count, measured.count, "One point per measured request")
        XCTAssertEqual(speed.points.map(\.rate), measured.compactMap(\.settledTokensPerSecond), "Each is the request's own settled rate")
        XCTAssertFalse(speed.points.map(\.x).contains(7), "The failed attempt has no speed")
        XCTAssertEqual(speed.average, inputs.gateway.settledThroughput.tokensPerSecond, "The rule is the session's settled rate")
        XCTAssertEqual(Set(speed.models.map(\.id)), ["gpt-5.4-mini", "claude-sonnet-4.5"], "Two models, coloured apart")
        XCTAssertEqual(speed.nearest(to: 8.4).map { speed.points[$0].x }, 8)
        XCTAssertEqual(speed.binSize, 1)
    }

    func testAVeryLongSessionFoldsItsSpeedsIntoBinsOfTheSameRule() {
        let samples = (1...500).map { SessionStatsFixture.request($0, stream: 1_000 + Double($0 % 7) * 100, output: 100 + Double($0 % 11) * 10) }
        let history = SessionStatsHistory(requests: samples)
        let speed = try! XCTUnwrap(SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history).speed)
        XCTAssertLessThanOrEqual(speed.points.count, SessionSpeedSeries.maximumPoints)
        XCTAssertEqual(speed.binSize, 3)
        let first = Array(samples.prefix(3))
        XCTAssertEqual(speed.points[0].rate, SessionTimingHistory(samples: first).settledThroughput.tokensPerSecond ?? -1, accuracy: 1e-9,
                       "A bin's rate is one division of its requests' sums, never an average of their rates")
        XCTAssertEqual(speed.points[0].x, 2, "plotted at the middle of its requests")
        XCTAssertTrue(speed.subtitle.contains("each point is 3 requests"), speed.subtitle)
    }

    // MARK: By model

    func testByModelGroupsTheRequestsOfEachModelWithTheirOwnRates() {
        let history = SessionStatsFixture.session()
        let charts = SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        XCTAssertEqual(charts.models.map(\.id), ["gpt-5.4-mini", "claude-sonnet-4.5"], "Busiest first")
        let gpt = history.requests.filter { $0.model == "gpt-5.4-mini" }
        let claude = history.requests.filter { $0.model == "claude-sonnet-4.5" }
        XCTAssertEqual(charts.models.map(\.requests), ["\(gpt.count)", "\(claude.count)"])
        XCTAssertEqual(charts.models[0].requestShare + charts.models[1].requestShare, 1, accuracy: 1e-9)
        let claudeRate = SessionTimingHistory(samples: claude.filter { $0.outcome == "completed" }).settledThroughput
        XCTAssertEqual(charts.models[1].speed, claudeRate.label, "Each model's own settled rate, never the blend")
        XCTAssertEqual(charts.models[1].firstToken, SessionInfoTiming.median(claude.compactMap(\.ttftMilliseconds)).map(MetricFormat.latency))
        let tokens = SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        XCTAssertEqual(tokens.models.count, 2)
        XCTAssertEqual(tokens.models.reduce(0) { $0 + $1.tokenShare }, 1, accuracy: 1e-9)
        XCTAssertEqual(tokens.models.compactMap(\.costShare).reduce(0, +), 1, accuracy: 1e-9)
        // One model is not a table.
        let single = SessionStatsHistory(requests: (1...4).map { SessionStatsFixture.request($0) })
        XCTAssertTrue(SessionTimeCharts(inputs: SessionStatsFixture.inputs(single), history: single).models.isEmpty)
        XCTAssertTrue(SessionTokenCharts(inputs: SessionStatsFixture.inputs(single), history: single).models.isEmpty)
    }

    // MARK: Token composition

    func testTheCompositionSplitsTheTotalIntoDisjointPartsThatAddUpToIt() {
        let history = SessionStatsHistory(requests: [
            SessionStatsFixture.request(1, input: 1_000, cached: 600, write: 100, output: 300, reasoning: 120),
            SessionStatsFixture.request(2, input: 500, cached: nil, output: 50, reasoning: nil),
        ])
        let inputs = SessionStatsFixture.inputs(history)
        let composition = try! XCTUnwrap(SessionTokenCharts(inputs: inputs, history: history).composition)
        let parts = Dictionary(uniqueKeysWithValues: composition.parts.map { ($0.id, $0.tokens) })
        XCTAssertEqual(parts[.cached], 600, "Cached input, part of the input")
        XCTAssertEqual(parts[.cacheWrite], 100)
        XCTAssertEqual(parts[.uncached], 300, "the rest of the first request's input: 1,000 − 600 cached − 100 written")
        XCTAssertEqual(parts[.inputUnsplit], 500, "Input whose cache use went unreported is its own part, never counted as uncached")
        XCTAssertEqual(parts[.reasoning], 120, "Reasoning, part of the output")
        XCTAssertEqual(parts[.output], 230, "the rest of the output: 300 − 120 + 50")
        XCTAssertEqual(composition.total, 1_850)
        XCTAssertEqual(composition.total, inputs.gateway.billedTotalTokens, "The parts add up to the headline total, nothing counted twice")
        XCTAssertEqual(composition.parts.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertEqual(composition.parts.first { $0.id == .inputUnsplit }?.title, "Input, cache not reported")
        XCTAssertEqual(composition.parts.first { $0.id == .output }?.title, "Other output")
        XCTAssertEqual(composition.parts.map(\.id), [.cached, .cacheWrite, .uncached, .inputUnsplit, .reasoning, .output], "Input first, then output, in a fixed order")

        // The fixture session: the same rule over many requests, and a failed attempt that reported nothing.
        let session = SessionStatsFixture.session()
        let whole = try! XCTUnwrap(SessionTokenCharts(inputs: SessionStatsFixture.inputs(session), history: session).composition)
        XCTAssertEqual(whole.total, SessionStatsFixture.gateway(session).billedTotalTokens ?? -1, accuracy: 1e-6)
    }

    func testASessionWithoutCacheFieldsSaysSoInsteadOfCallingItUncached() {
        let history = SessionStatsHistory(requests: (1...3).map { SessionStatsFixture.request($0, input: 2_000, cached: nil, output: 100, reasoning: nil) })
        let charts = SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        let composition = try! XCTUnwrap(charts.composition)
        XCTAssertEqual(composition.parts.map(\.id), [.inputUnsplit, .output])
        XCTAssertEqual(composition.parts.map(\.title), ["Input", "Output"])
        XCTAssertEqual(composition.parts.first?.detail, "no request reported its cache use")
        XCTAssertEqual(charts.hero.first { $0.id == "cache" }?.value, "—", "No cache counter, no cache hit")
        XCTAssertEqual(charts.perRequest?.kinds, [.inputUnsplit, .output])
    }

    // MARK: Tokens per request and cost

    func testTokensPerRequestStackCachedUncachedAndOutput() {
        let history = SessionStatsFixture.session()
        let bars = try! XCTUnwrap(SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history).perRequest)
        XCTAssertEqual(bars.bars.count, 17, "Every request that reported usage; the failed attempt reported none")
        let second = bars.bars[1], sample = history.requests[1]
        XCTAssertEqual(second.cached, sample.cacheReadTokens)
        XCTAssertEqual(second.uncached, (sample.inputTokens ?? 0) - (sample.cacheReadTokens ?? 0), "Uncached input includes what was written to the cache")
        XCTAssertEqual(second.reasoning + second.output, sample.outputTokens)
        XCTAssertEqual(second.total, (sample.inputTokens ?? 0) + (sample.outputTokens ?? 0))
        XCTAssertTrue(bars.summary?.hasPrefix("Input grew from 10.4K to 51.2K per request") == true, bars.summary ?? "")
        XCTAssertEqual(bars.endLabel, MetricFormat.tokens(bars.bars.last?.total ?? 0), "The latest bar says how big it is")
        XCTAssertGreaterThan(bars.yMaximum, bars.bars.map(\.total).max() ?? 0, "with room over it for the label")
        XCTAssertEqual(bars.stacks[1].map(\.kind), [.cached, .uncached, .reasoning, .output], "Each bar's parts, stacked from zero in a fixed order")
        XCTAssertEqual(bars.stacks[1].last?.to ?? 0, bars.bars[1].total, accuracy: 1e-9)
        XCTAssertEqual(bars.categories, bars.bars.map { String($0.index) })
        XCTAssertTrue(bars.caption(forBar: 1).contains("cached"), bars.caption(forBar: 1))
    }

    func testAVeryLongSessionAveragesItsTokenBarsInBins() {
        let samples = (1...300).map { SessionStatsFixture.request($0, input: Double($0) * 100, cached: Double($0) * 50, output: 10) }
        let history = SessionStatsHistory(requests: samples)
        let bars = try! XCTUnwrap(SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history).perRequest)
        XCTAssertLessThanOrEqual(bars.bars.count, SessionTokenBars.maximumBars)
        XCTAssertEqual(bars.binSize, 4)
        XCTAssertEqual(bars.bars[0].cached, (50 + 100 + 150 + 200) / 4, "A bin draws its average request")
        XCTAssertTrue(bars.subtitle.contains("averages 4 consecutive requests"), bars.subtitle)
    }

    func testCumulativeCostAddsOnlyTheCostsThatWereReported() {
        let history = SessionStatsHistory(requests: [
            SessionStatsFixture.request(1, cost: 0.001),
            SessionStatsFixture.request(2, cost: nil),
            SessionStatsFixture.request(3, cost: 0.002),
            SessionStatsFixture.request(4, cost: 0.0005),
        ])
        let cost = try! XCTUnwrap(SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history).cost)
        XCTAssertEqual(cost.points.map(\.cumulative), [0.001, 0.001, 0.003, 0.0035].map { $0 }, "A request with no reported cost adds nothing")
        XCTAssertTrue(cost.points[1].caption.contains("cost not reported"), cost.points[1].caption)
        XCTAssertTrue(cost.points[2].caption.contains("$0.002 this request") && cost.points[2].caption.contains("$0.003 so far"), cost.points[2].caption)
        XCTAssertEqual(cost.subtitle, "3 of 4 requests reported a cost; the others add nothing here")
        XCTAssertGreaterThanOrEqual(cost.yMaximum, 0.0035)
        XCTAssertEqual(cost.endLabel, "$0.0035", "The line ends on the session's cost so far")
    }

    // MARK: Edge cases

    func testOneRequestKeepsItsTimelineAndCompositionAndDropsChartsOfOnePoint() {
        let history = SessionStatsHistory(requests: [SessionStatsFixture.request(1)])
        let inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history), tokens = SessionTokenCharts(inputs: inputs, history: history)
        XCTAssertEqual(time.timeline?.rows.count, 1)
        XCTAssertNil(time.timeline?.highlights, "One request has no slowest or longest")
        XCTAssertNil(time.speed, "One point is its own average; the figure above says it")
        XCTAssertTrue(time.models.isEmpty)
        XCTAssertNil(tokens.perRequest, "One request's bar would repeat the composition above it")
        XCTAssertNil(tokens.cost, "One request's cost is the headline figure")
        XCTAssertNotNil(tokens.composition)
    }

    func testASessionThatReportedNoCostHasNoCostChartAndSaysSo() {
        let history = SessionStatsHistory(requests: (1...5).map { SessionStatsFixture.request($0, cost: nil) })
        let tokens = SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        XCTAssertNil(tokens.cost)
        XCTAssertEqual(tokens.hero.first { $0.id == "cost" }?.value, "—")
        XCTAssertEqual(tokens.hero.first { $0.id == "cost" }?.caption, "not reported")
        XCTAssertTrue(tokens.models.isEmpty)
    }

    func testFailedAttemptsAreDrawnAsFailuresAndLeftOutOfTheSpeeds() {
        let history = SessionStatsFixture.session()
        let time = SessionTimeCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        XCTAssertEqual(time.timeline?.rows.filter(\.failed).map(\.number), [7])
        XCTAssertTrue(time.notes.contains { $0.contains("1 failed attempt is drawn in red") })
        let tokens = SessionTokenCharts(inputs: SessionStatsFixture.inputs(history), history: history)
        XCTAssertTrue(tokens.notes.contains { $0.contains("1 failed attempt reported no usage") })
    }

    func testARequestStillRunningIsLeftOutUntilItSettlesAndThePanelSaysSo() {
        var history = SessionStatsFixture.session(requests: 6)
        history.requests.append(SessionStatsFixture.request(7, outcome: "running", ttft: 300, stream: nil, input: nil, cached: nil, output: nil, cost: nil))
        let inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history)
        XCTAssertEqual(time.timeline?.rows.map(\.number), [1, 2, 3, 4, 5, 6], "Settled requests only")
        XCTAssertFalse(time.speed?.points.contains { $0.x == 7 } ?? true)
        XCTAssertTrue(time.notes.contains { $0.contains("1 request is still running") && $0.contains("every figure here is settled") })
        let tokens = SessionTokenCharts(inputs: inputs, history: history)
        XCTAssertEqual(tokens.perRequest?.bars.count, 6)
        XCTAssertTrue(tokens.notes.contains { $0.contains("1 request is still running") })
    }

    // MARK: The figures at the top

    func testTheFiguresAtTheTopAreThePillsNumbersLarger() {
        let history = SessionStatsFixture.session()
        let inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history)
        let pill = SessionStatsPresentation(gateway: inputs.gateway, work: inputs.work)
        XCTAssertEqual(time.hero.map(\.id), ["turns", "steps", "speed"])
        XCTAssertEqual(time.hero.map(\.value), ["\(pill.turns)", "\(pill.steps)", pill.throughput.label ?? "—"])
        XCTAssertEqual(time.hero[2].caption, "17/18 requests measured", "The decode speed says what it covers")
        XCTAssertTrue(time.hero[2].partial)
        XCTAssertEqual(time.details.map(\.id), ["calls", "ai", "tools", "ttft"])
        XCTAssertEqual(time.details[0].value, "15", "Three tool calls in each of the five turns")
        XCTAssertEqual(time.details[1].value, workDuration(61_000))
        XCTAssertEqual(time.details[3].value, inputs.gateway.settledLatency.label)
        // The loaded conversation starts later than the session: a lower bound.
        var partial = inputs; partial.conversationPartial = true
        XCTAssertEqual(SessionTimeCharts(inputs: partial, history: history).details[0].value, "15+")
        // Before the history is read, the figures are there and the charts wait.
        let early = SessionTimeCharts(inputs: inputs, history: nil)
        XCTAssertFalse(early.historyLoaded)
        XCTAssertEqual(early.hero, time.hero)
        XCTAssertNil(early.timeline); XCTAssertNil(early.speed)
        XCTAssertEqual(time.notes.first, SettledThroughput.explanation, "The rate's definition is the app's own")

        let tokens = SessionTokenCharts(inputs: inputs, history: history)
        XCTAssertEqual(tokens.hero.map(\.id), ["tokens", "cost", "cache"])
        XCTAssertEqual(tokens.hero[0].value, pill.totalTokens.map(MetricFormat.exactTokens), "The exact total")
        XCTAssertEqual(tokens.hero[2].value, (pill.cacheHit ?? "") + "%")
    }
}

extension SessionTokenBars {
    func caption(forBar index: Int) -> String { bars.indices.contains(index) ? bars[index].caption : "" }
}
