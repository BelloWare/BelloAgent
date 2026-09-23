import Foundation

// What the two statistics popovers under the composer draw, built once per
// history and never in a view body. Pure over the session's gateway totals,
// the helper's clocks and the retained per-request history, so every series,
// label and accessibility string is asserted without a window.
//
// Rules the builders keep:
// - A missing observation stays missing: no zero is invented for a request
//   that did not report a figure, and a chart says how many requests it covers.
// - Cached input is part of input and reasoning is part of output; the parts
//   of a whole are disjoint and add up to it, never double counted.
// - A request still running contributes nothing until it settles, and failed
//   attempts are drawn as failures or left out, and the panel says which.
// - Rates are the settled rate (`SettledThroughput`,
//   `SessionTimingSample.settledTokensPerSecond`); nothing here defines its own.

/// What the popovers take from the chat's footer: the gateway totals over the
/// session's whole retained log, the helper's session clocks, and the tool
/// calls the loaded conversation made in each of its turns.
struct SessionStatsInputs: Sendable, Equatable {
    var gateway = GatewayTotals()
    var work: WorkSplit?
    /// Tool calls per turn (the turn's user message id), counted over the
    /// replies of the conversation page that is loaded.
    var toolCallsByTurn: [String: Int] = [:]
    /// Older conversation rows exist that are not loaded, so the tool calls
    /// counted from the page may be short of the session's.
    var conversationPartial = false
}

/// A session's retained requests, oldest first: completed, failed and still
/// running. The source is the one Session info and its ledger read.
struct SessionStatsHistory: Sendable, Equatable {
    /// Long enough for any real session; a longer one reads its latest requests
    /// and every chart says so.
    static let limit = 2_000
    var requests: [SessionTimingSample] = []
    /// Retained requests older than `requests` that were not read.
    var olderRequests = 0
    var total: Int { requests.count + olderRequests }
}

/// One request's place in the popovers: its number in the session, the model
/// that served it, and whether it settled.
struct SessionStatsRequest: Sendable, Equatable {
    enum State: Sendable, Equatable { case completed, failed, running }
    let sample: SessionTimingSample
    let number: Int
    let model: String
    let state: State

    static func state(of sample: SessionTimingSample) -> State {
        switch sample.outcome {
        case "completed", "truncated": .completed
        case "running": .running
        default: .failed
        }
    }
    /// What the ledger calls the request's model: the reported model, else
    /// the API it went out on.
    static func model(of sample: SessionTimingSample) -> String {
        sample.model ?? (sample.api.isEmpty ? "Unreported model" : sample.api)
    }
}

/// Formatting shared by both popovers' builders.
enum SessionStatsFormat {
    /// `45%`, `<1%` for a real sliver, `100%` only for the whole.
    static func share(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction >= 0 else { return "—" }
        return (MetricFormat.cacheHitPercent(read: min(fraction, 1) * 1_000_000, prompt: 1_000_000) ?? "0") + "%"
    }
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    static func cost(_ usd: Double) -> String { compactGatewayUSD(usd) }

    /// Round ticks from zero, spaced for about three steps up to `maximum`,
    /// and continuing to the top of the axis, `limit`, so the highest marks
    /// have a figure beside them.
    static func ticks(upTo maximum: Double, within limit: Double? = nil, count: Int = 3) -> [Double] {
        guard maximum.isFinite, maximum > 0 else { return [0] }
        let raw = maximum / Double(max(1, count))
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        let top = max(maximum, limit ?? maximum)
        var values: [Double] = []
        var value = 0.0
        while value <= top + step * 0.001, values.count < 12 { values.append(value); value += step }
        return values
    }
    /// The top of an axis: the maximum with a little headroom, never zero.
    static func ceiling(_ maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        return maximum * 1.08
    }
    /// The top of a y axis whose labels sit centred on their gridlines: high
    /// enough over the top tick that its label, half a line tall above the
    /// line, stays inside a plot `plotHeight` points tall.
    static func axisTop(_ top: Double, ticks: [Double], plotHeight: Double) -> Double {
        let highest = ticks.last ?? 0
        return max(top, highest / (1 - labelHalfHeight / max(plotHeight, labelHalfHeight * 4)))
    }
    /// Half the height of an axis label in the popovers' micro type, with a point to spare.
    static let labelHalfHeight: Double = 7.5
    /// The space between a bar's end and the number written after it.
    static let markerSpacing: Double = 4
    /// The space between the latest bar's top and its label.
    static let endLabelSpacing: Double = 3
    /// A generous width, in points, of a short figure in the popovers'
    /// micro type (10.5 pt medium): wide enough for `#`, digits and units.
    static func labelWidth(_ text: String) -> Double { Double(text.count) * 6.8 + 2 }
    /// Inward at the axis's ends: the first label starts at its tick, one in
    /// the last seventh of the axis ends at it, the rest centre on theirs.
    static func anchor(forTick value: Double, domain: Double) -> SessionStatsTickAnchor {
        guard domain > 0, value.isFinite else { return .center }
        let at = value / domain
        return at <= 0.001 ? .leading : at >= 6.0 / 7.0 ? .trailing : .center
    }
    static func milliseconds(_ value: Double) -> String { value == 0 ? "0" : MetricFormat.latency(value) }
    /// A clock reading: `820 ms` under a second, never `0.0s`; `12.3s` and
    /// `1m 5s` from there, as the turn lines write them.
    static func duration(_ milliseconds: Double) -> String {
        milliseconds < 999.5 ? MetricFormat.latency(milliseconds) : workDuration(milliseconds)
    }
    static func tokens(_ value: Double) -> String { value == 0 ? "0" : MetricFormat.tokens(value) }
    /// A money axis in one style: every tick with the decimals its step needs,
    /// cents at least below a dollar — `$0.50 $1.00 $1.50`, `$0.025 $0.050` —
    /// and whole dollars from a dollar's step up.
    static func costTicks(_ ticks: [Double]) -> [String] {
        guard ticks.count > 1 else { return ticks.map { $0 == 0 ? "$0" : cost($0) } }
        let step = ticks[1] - ticks[0]
        var places = 0
        while places < 8, abs((step * pow(10, Double(places))).rounded() - step * pow(10, Double(places))) > 1e-9 { places += 1 }
        let decimals = step >= 1 ? 0 : max(2, places)
        return ticks.map { $0 == 0 ? "$0" : "$" + String(format: "%.\(decimals)f", $0) }
    }
    static func rate(_ value: Double) -> String { value == 0 ? "0" : MetricFormat.throughputValue(value) }
}

// MARK: - Session statistics (turns · steps · tok/s)

/// A figure at the top of a popover.
struct SessionStatsFigure: Sendable, Equatable, Identifiable {
    let id: String
    let value: String
    let title: String
    var caption: String? = nil
    var partial = false
}

/// Where the session's time went: waiting for first tokens, generating, and
/// running tools, as one stacked bar and its legend.
struct SessionTimeSplit: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable { case waiting, generating, tools }
    struct Part: Sendable, Equatable, Identifiable {
        let id: Kind
        let title: String
        let milliseconds: Double
        let value: String
        let share: String
        let fraction: Double
    }
    let parts: [Part]
    let total: String
    let note: String?
    let accessibility: String
}

/// One thin bar per model request, in the order they ran: the wait for the
/// first token, then the generation. A failed attempt is drawn as one bar in
/// the failure colour; a request that recorded no first token is one plain bar.
struct SessionRequestTimeline: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        let id: String
        /// Top to bottom, oldest first.
        let index: Int
        let number: Int
        let waiting: Double
        let generating: Double
        /// A request that recorded no first token: its whole duration, unsplit.
        let unsplit: Double
        let failed: Bool
        /// Alternate turns sit on a faint band, so a turn's requests read together.
        let band: Bool
        let label: String
        let value: String
        let caption: String
        /// "#5" beside the row with the slowest first token or the longest
        /// generation: the rows the highlights line names.
        var marker: String? = nil
        var end: Double { waiting + generating + unsplit }
    }
    static let maximumRows = 32
    /// The plot's width in the popover: the page less its margins. The chart
    /// has no y axis, so the plot is the whole chart's width.
    static let plotWidth: Double = 436
    /// How far along the axis a bar ending at `end` must stop so the number
    /// written after it fits inside the plot.
    static func axisEnd(fitting marker: String, after end: Double) -> Double {
        let room = SessionStatsFormat.labelWidth(marker) + SessionStatsFormat.markerSpacing
        return end * plotWidth / max(plotWidth / 2, plotWidth - room)
    }
    let rows: [Row]
    /// The x axis runs from zero to this many milliseconds.
    let domain: Double
    let ticks: [Double]
    let tickLabels: [String]
    /// Which side of its tick each label hangs: inward at the axis's two ends.
    let tickAnchors: [SessionStatsTickAnchor]
    let subtitle: String
    let highlights: String?
    let latestCaption: String
    let accessibility: String
    let hasFailures: Bool
    let hasUnsplit: Bool
    func label(forTick value: Double) -> String {
        ticks.firstIndex(of: value).map { tickLabels[$0] } ?? SessionStatsFormat.milliseconds(value)
    }
    func anchor(forTick value: Double) -> SessionStatsTickAnchor {
        ticks.firstIndex(of: value).map { tickAnchors[$0] } ?? SessionStatsFormat.anchor(forTick: value, domain: domain)
    }
}

/// Which side of its tick an x-axis label hangs, so the labels at the two
/// ends of an axis read inward instead of running off the chart.
enum SessionStatsTickAnchor: Sendable, Equatable { case leading, center, trailing }

/// The settled decode rate of each measured request, in order, against the
/// session's average. Past `maximumPoints` requests, consecutive requests are
/// folded into bins and each bin shows its own settled rate.
struct SessionSpeedSeries: Sendable, Equatable {
    struct Point: Sendable, Equatable, Identifiable {
        let id: String
        let index: Int
        /// The request number, or the middle of the bin's numbers.
        let x: Double
        let rate: Double
        let model: String
        let colorIndex: Int
        let label: String
        let value: String
        let caption: String
    }
    struct Model: Sendable, Equatable, Identifiable {
        let id: String
        let colorIndex: Int
    }
    static let maximumPoints = 240
    /// The plot's height in the popover.
    static let plotHeight: Double = 118
    let points: [Point]
    let average: Double?
    let averageLabel: String?
    let xDomain: ClosedRange<Double>
    let yMaximum: Double
    let ticks: [Double]
    let tickLabels: [String]
    let binSize: Int
    /// The models the points are coloured by; empty when there is only one.
    let models: [Model]
    let subtitle: String
    let latestCaption: String
    let accessibility: String
    func label(forTick value: Double) -> String {
        ticks.firstIndex(of: value).map { tickLabels[$0] } ?? SessionStatsFormat.rate(value)
    }
    /// The point nearest to a request number on the x axis.
    func nearest(to x: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let middle = (low + high) / 2
            if points[middle].x < x { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(points[low - 1].x - x) <= abs(points[low].x - x) { return low - 1 }
        return low
    }
}

/// One model of a session that used several: its share of the requests, its
/// own settled rate and its median first token.
struct SessionModelTimeRow: Sendable, Equatable, Identifiable {
    let id: String
    let colorIndex: Int
    let requests: String
    let requestShare: Double
    let requestShareLabel: String
    let speed: String
    let speedCaption: String
    let firstToken: String
    let firstTokenCaption: String
}

struct SessionTimeCharts: Sendable, Equatable {
    var hero: [SessionStatsFigure] = []
    var details: [SessionStatsFigure] = []
    var split: SessionTimeSplit?
    var timeline: SessionRequestTimeline?
    var speed: SessionSpeedSeries?
    var models: [SessionModelTimeRow] = []
    var notes: [String] = []
    /// False until the per-request history is read; the charts wait for it.
    var historyLoaded = false

    init(inputs: SessionStatsInputs, history: SessionStatsHistory?) {
        let gateway = inputs.gateway
        let requests = history.map(Self.requests) ?? []
        let palette = Self.palette(requests)
        hero = Self.hero(gateway)
        details = Self.details(inputs, requests: requests, history: history)
        split = Self.split(inputs, requests: requests)
        historyLoaded = history != nil
        if let history {
            timeline = Self.timeline(requests, history: history)
            speed = Self.speed(requests, gateway: gateway, palette: palette, history: history)
            models = Self.models(requests, palette: palette)
        }
        notes = Self.notes(inputs, requests: requests, history: history)
    }

    // MARK: Builders

    static func requests(_ history: SessionStatsHistory) -> [SessionStatsRequest] {
        history.requests.enumerated().map { offset, sample in
            SessionStatsRequest(sample: sample, number: history.olderRequests + offset + 1,
                                model: SessionStatsRequest.model(of: sample), state: SessionStatsRequest.state(of: sample))
        }
    }

    /// The same model colours as the menu bar and the report.
    static func palette(_ requests: [SessionStatsRequest]) -> MonitorModelPalette {
        var palette = MonitorModelPalette()
        var names: [String] = []
        for request in requests where !names.contains(request.model) { names.append(request.model) }
        palette.include(names)
        return palette
    }

    static func hero(_ gateway: GatewayTotals) -> [SessionStatsFigure] {
        let turns = gateway.turnCount ?? 0, steps = gateway.requests
        let throughput = gateway.settledThroughput
        let decodeCaption: String
        if throughput.samples == 0 { decodeCaption = "no request measured" }
        else if let coverage = throughput.coverage { decodeCaption = coverage }
        else { decodeCaption = "\(SessionStatsFormat.plural(throughput.samples, "request", "requests")) measured" }
        return [
            SessionStatsFigure(id: "turns", value: "\(turns)", title: turns == 1 ? "turn" : "turns", caption: "your messages"),
            SessionStatsFigure(id: "steps", value: "\(steps)", title: steps == 1 ? "step" : "steps", caption: "model requests"),
            SessionStatsFigure(id: "speed", value: throughput.label ?? "—", title: "decode speed", caption: decodeCaption,
                               partial: throughput.coverage != nil),
        ]
    }

    static func details(_ inputs: SessionStatsInputs, requests: [SessionStatsRequest], history: SessionStatsHistory?) -> [SessionStatsFigure] {
        let gateway = inputs.gateway, work = inputs.work
        var figures: [SessionStatsFigure] = []
        figures.append(toolCalls(inputs, requests: requests, history: history))
        figures.append(SessionStatsFigure(id: "ai", value: work.map { SessionStatsFormat.duration($0.sessionModelMs) } ?? "—", title: "AI time",
                                          caption: work == nil ? "not recorded" : "on the model"))
        figures.append(SessionStatsFigure(id: "tools", value: work.map { SessionStatsFormat.duration($0.sessionToolMs) } ?? "—", title: "tool time",
                                          caption: work == nil ? "not recorded" : "running tools"))
        let latency = gateway.settledLatency
        let latencyCaption: String
        if latency.samples == 0 { latencyCaption = "not measured" }
        else if latency.samples < latency.requests { latencyCaption = "average of \(latency.samples)/\(latency.requests)" }
        else { latencyCaption = "average of \(latency.samples)" }
        figures.append(SessionStatsFigure(id: "ttft", value: latency.label ?? "—", title: "first token", caption: latencyCaption,
                                          partial: latency.samples > 0 && latency.samples < latency.requests))
        return figures
    }

    /// Tool calls the session's own turns made, counted in the loaded
    /// conversation. A side or fork shows its parent's replies too; only
    /// the turns this session's requests served are counted.
    static func toolCalls(_ inputs: SessionStatsInputs, requests: [SessionStatsRequest], history: SessionStatsHistory?) -> SessionStatsFigure {
        guard let history else { return SessionStatsFigure(id: "calls", value: "—", title: "tool calls", caption: "reading…") }
        let turns = Set(requests.compactMap(\.sample.turn))
        let counted = inputs.toolCallsByTurn.filter { turns.contains($0.key) }
        // No turn of this session is in the loaded conversation: the count is
        // unknown, not zero.
        guard !counted.isEmpty else {
            return SessionStatsFigure(id: "calls", value: "—", title: "tool calls", caption: "turns not loaded")
        }
        let calls = counted.values.reduce(0, +)
        let partial = inputs.conversationPartial || history.olderRequests > 0 || counted.count < turns.count
        return SessionStatsFigure(id: "calls", value: partial ? "\(calls)+" : "\(calls)", title: calls == 1 && !partial ? "tool call" : "tool calls",
                                  caption: partial ? "in loaded turns" : "in \(SessionStatsFormat.plural(turns.count, "turn", "turns"))")
    }

    static func split(_ inputs: SessionStatsInputs, requests: [SessionStatsRequest]) -> SessionTimeSplit? {
        let gateway = inputs.gateway
        var note: String?
        var values: [(SessionTimeSplit.Kind, Double)]
        var titles: [SessionTimeSplit.Kind: String] = [.waiting: "Waiting for first token", .generating: "Generating", .tools: "Running tools"]
        if let work = inputs.work {
            // The helper's clocks are the whole: its AI time splits into the
            // first-token waits the archive measured and the generation after
            // them. Tools come from the same clocks.
            let ai = work.sessionModelMs
            let measured = (gateway.ttftSamples ?? 0) > 0 ? (gateway.ttftMilliseconds ?? 0) : 0
            let waiting = min(measured, ai)
            values = [(.waiting, waiting), (.generating, ai - waiting), (.tools, work.sessionToolMs)]
            let latency = gateway.settledLatency
            if latency.samples > 0, latency.samples < latency.requests {
                note = "First-token waits were measured on \(latency.samples) of \(latency.requests) requests; the rest of the AI time is counted as generating."
            } else if latency.samples == 0 {
                titles[.generating] = "AI time, not split"
                note = "No request recorded its first token, so the AI time is not split into waiting and generating."
            }
            if measured > ai + 1 { note = "The recorded first-token waits exceed the AI clock; the wait is shown at the AI time." }
        } else {
            // No helper clocks: the model requests alone, from the archive.
            let settled = requests.filter { $0.state == .completed }
            let waiting = settled.compactMap(\.sample.ttftMilliseconds).reduce(0, +)
            let generating = settled.compactMap(\.sample.streamingMilliseconds).reduce(0, +)
            values = [(.waiting, waiting), (.generating, generating)]
            note = "Tool time was not recorded for this session; the bar covers its model requests only."
        }
        let total = values.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let parts = values.filter { $0.1 > 0 }.map { kind, ms in
            SessionTimeSplit.Part(id: kind, title: titles[kind] ?? kind.rawValue, milliseconds: ms, value: SessionStatsFormat.duration(ms),
                                  share: SessionStatsFormat.share(ms / total), fraction: ms / total)
        }
        let spoken = parts.map { "\($0.title) \($0.value), \($0.share)" }.joined(separator: "; ")
        return SessionTimeSplit(parts: parts, total: SessionStatsFormat.duration(total), note: note,
                                accessibility: "Where the time went, \(SessionStatsFormat.duration(total)) in all: " + spoken)
    }

    static func timeline(_ requests: [SessionStatsRequest], history: SessionStatsHistory) -> SessionRequestTimeline? {
        let drawn = requests.filter { $0.state != .running }
        guard !drawn.isEmpty else { return nil }
        let shown = Array(drawn.suffix(SessionRequestTimeline.maximumRows))
        var rows: [SessionRequestTimeline.Row] = []
        var band = false, previousTurn: String?? = nil
        for (index, request) in shown.enumerated() {
            let sample = request.sample
            if let previousTurn, previousTurn != sample.turn { band.toggle() }
            previousTurn = sample.turn
            var waiting = 0.0, generating = 0.0, unsplit = 0.0
            let failed = request.state == .failed
            if failed {
                unsplit = sample.requestMilliseconds ?? ((sample.ttftMilliseconds ?? 0) + (sample.streamingMilliseconds ?? 0))
            } else if let ttft = sample.ttftMilliseconds, let generation = sample.streamingMilliseconds ?? sample.requestMilliseconds.map({ max(0, $0 - ttft) }) {
                waiting = ttft; generating = generation
            } else if let whole = sample.requestMilliseconds {
                unsplit = whole
            } else if let ttft = sample.ttftMilliseconds {
                waiting = ttft
            }
            let parts = timelineParts(request)
            rows.append(SessionRequestTimeline.Row(id: sample.id, index: index, number: request.number, waiting: waiting, generating: generating,
                                                   unsplit: unsplit, failed: failed, band: band,
                                                   label: "Request \(request.number), \(request.model), \(SessionStatsFormat.clock(sample.wall))",
                                                   value: parts.joined(separator: ", "),
                                                   caption: (["Request \(request.number)", SessionStatsFormat.clock(sample.wall), request.model] + parts).joined(separator: " · ")))
        }
        var subtitle = "One bar per request, oldest first"
        if drawn.count > shown.count || history.olderRequests > 0 {
            subtitle = "The latest \(shown.count) of \(history.total) requests, oldest first"
        }
        let settled = shown.enumerated().filter { $0.element.state == .completed }
        var highlights: [String] = []
        if settled.count > 1 {
            if let slow = settled.max(by: { (rows[$0.offset].waiting) < (rows[$1.offset].waiting) }), rows[slow.offset].waiting > 0 {
                highlights.append("Slowest first token: #\(slow.element.number), \(MetricFormat.latency(rows[slow.offset].waiting))")
                rows[slow.offset].marker = "#\(slow.element.number)"
            }
            if let long = settled.max(by: { rows[$0.offset].generating < rows[$1.offset].generating }), rows[long.offset].generating > 0 {
                highlights.append("longest generation: #\(long.element.number), \(MetricFormat.latency(rows[long.offset].generating))")
                rows[long.offset].marker = "#\(long.element.number)"
            }
        }
        // The axis runs past the longest bar, and far enough past a marked
        // row's end for the number written there; its ticks reach its top.
        let maximum = rows.map(\.end).max() ?? 0
        var top = SessionStatsFormat.ceiling(maximum)
        for row in rows { if let marker = row.marker { top = max(top, SessionRequestTimeline.axisEnd(fitting: marker, after: row.end)) } }
        let ticks = SessionStatsFormat.ticks(upTo: maximum, within: top)
        let domain = max(top, ticks.last ?? 0)
        let highlight = highlights.isEmpty ? nil : highlights.joined(separator: " · ")
        let failures = rows.filter(\.failed).count
        var spoken = "Request timeline, \(SessionStatsFormat.plural(rows.count, "request", "requests")) oldest first."
        if let highlight { spoken += " " + highlight + "." }
        if failures > 0 { spoken += " \(SessionStatsFormat.plural(failures, "failed attempt", "failed attempts")) drawn in red." }
        return SessionRequestTimeline(rows: rows, domain: domain, ticks: ticks, tickLabels: ticks.map(SessionStatsFormat.milliseconds),
                                      tickAnchors: ticks.map { SessionStatsFormat.anchor(forTick: $0, domain: domain) },
                                      subtitle: subtitle, highlights: highlight.map { $0.prefix(1).uppercased() + $0.dropFirst() },
                                      latestCaption: rows.last.map { "Latest · " + $0.caption } ?? "",
                                      accessibility: spoken, hasFailures: failures > 0, hasUnsplit: rows.contains { $0.unsplit > 0 && !$0.failed })
    }

    /// The figures a timeline row names: its wait, its generation, its tokens and its rate.
    private static func timelineParts(_ request: SessionStatsRequest) -> [String] {
        let sample = request.sample
        if request.state == .failed {
            let when = sample.requestMilliseconds.map { " after " + MetricFormat.latency($0) } ?? ""
            return ["\(sample.outcome.isEmpty ? "failed" : sample.outcome)\(when)"]
        }
        var parts: [String] = []
        parts.append(sample.ttftMilliseconds.map { "first token " + MetricFormat.latency($0) } ?? "first token not recorded")
        if let generation = sample.streamingMilliseconds { parts.append("generating " + MetricFormat.latency(generation)) }
        else if let whole = sample.requestMilliseconds { parts.append("whole request " + MetricFormat.latency(whole)) }
        if let output = sample.outputTokens { parts.append(MetricFormat.exactTokens(output) + " out") }
        parts.append(sample.settledTokensPerSecond.map(MetricFormat.throughput) ?? "rate not measured")
        return parts
    }

    static func speed(_ requests: [SessionStatsRequest], gateway: GatewayTotals, palette: MonitorModelPalette, history: SessionStatsHistory) -> SessionSpeedSeries? {
        let completed = requests.filter { $0.state == .completed }
        let measured = completed.filter { $0.sample.settledTokensPerSecond != nil }
        guard !measured.isEmpty else { return nil }
        let names = Set(measured.map(\.model))
        let binSize = max(1, Int((Double(measured.count) / Double(SessionSpeedSeries.maximumPoints)).rounded(.up)))
        var points: [SessionSpeedSeries.Point] = []
        var start = 0
        while start < measured.count {
            let bin = Array(measured[start..<min(start + binSize, measured.count)])
            start += binSize
            guard let first = bin.first, let last = bin.last else { continue }
            if bin.count == 1, let rate = first.sample.settledTokensPerSecond {
                let sample = first.sample
                var parts = [MetricFormat.throughput(rate)]
                if let output = sample.outputTokens, let decode = sample.streamingMilliseconds {
                    parts.append("\(MetricFormat.exactTokens(output)) out in \(MetricFormat.latency(decode)) of generating")
                }
                points.append(SessionSpeedSeries.Point(id: sample.id, index: points.count, x: Double(first.number), rate: rate, model: first.model,
                                                       colorIndex: palette.index(first.model),
                                                       label: "Request \(first.number), \(first.model)", value: parts.joined(separator: ", "),
                                                       caption: (["Request \(first.number)", SessionStatsFormat.clock(sample.wall), first.model] + parts).joined(separator: " · ")))
            } else {
                // A bin's rate is the settled rate of its requests: one division
                // of their sums, the same rule as the session figure.
                guard let rate = SessionTimingHistory(samples: bin.map(\.sample)).settledThroughput.tokensPerSecond else { continue }
                let models = Set(bin.map(\.model))
                let model = models.count == 1 ? first.model : "Several models"
                let range = "Requests \(first.number)–\(last.number)"
                let value = "\(MetricFormat.throughput(rate)) over \(bin.count) measured requests"
                points.append(SessionSpeedSeries.Point(id: first.sample.id, index: points.count, x: Double(first.number + last.number) / 2, rate: rate,
                                                       model: model, colorIndex: models.count == 1 ? palette.index(first.model) : 6,
                                                       label: range, value: value, caption: "\(range) · \(model) · \(value)"))
            }
        }
        // One point is its own average: the figure at the top already says it.
        guard points.count > 1, let first = points.first, let last = points.last else { return nil }
        let average = gateway.settledThroughput.tokensPerSecond
        let maximum = max(points.map(\.rate).max() ?? 0, average ?? 0)
        let ticks = SessionStatsFormat.ticks(upTo: maximum, within: SessionStatsFormat.ceiling(maximum))
        let top = SessionStatsFormat.axisTop(SessionStatsFormat.ceiling(maximum), ticks: ticks, plotHeight: SessionSpeedSeries.plotHeight)
        let span = max(1, last.x - first.x)
        let pad = max(0.5, span * 0.03)
        var subtitle = "\(measured.count) of \(SessionStatsFormat.plural(completed.count, "completed request", "completed requests")) measured"
        if binSize > 1 { subtitle += " · each point is \(binSize) requests" }
        if history.olderRequests > 0 { subtitle += " · the latest \(history.requests.count) of \(history.total)" }
        let averageLabel = average.map { "Session average " + MetricFormat.throughput($0) }
        var spoken = "Decode speed per request, \(points.count) points."
        if let averageLabel { spoken += " \(averageLabel)." }
        if let fastest = points.max(by: { $0.rate < $1.rate }), let slowest = points.min(by: { $0.rate < $1.rate }), points.count > 1 {
            spoken += " Fastest \(fastest.label), \(MetricFormat.throughput(fastest.rate)); slowest \(slowest.label), \(MetricFormat.throughput(slowest.rate))."
        }
        let models = names.count > 1 ? names.sorted().map { SessionSpeedSeries.Model(id: $0, colorIndex: palette.index($0)) } : []
        return SessionSpeedSeries(points: points, average: average, averageLabel: averageLabel,
                                  xDomain: (first.x - pad)...(last.x + pad), yMaximum: top,
                                  ticks: ticks, tickLabels: ticks.map(SessionStatsFormat.rate), binSize: binSize, models: models,
                                  subtitle: subtitle, latestCaption: "Latest · " + last.caption,
                                  accessibility: spoken)
    }

    static func models(_ requests: [SessionStatsRequest], palette: MonitorModelPalette) -> [SessionModelTimeRow] {
        let counted = requests.filter { $0.state != .running }
        var order: [String] = []
        var groups: [String: [SessionStatsRequest]] = [:]
        for request in counted {
            if groups[request.model] == nil { order.append(request.model) }
            groups[request.model, default: []].append(request)
        }
        guard order.count > 1 else { return [] }
        let total = Double(counted.count)
        return order.sorted { (groups[$0]?.count ?? 0) > (groups[$1]?.count ?? 0) }.map { name in
            let group = groups[name] ?? []
            let completed = group.filter { $0.state == .completed }.map(\.sample)
            let rate = SessionTimingHistory(samples: completed).settledThroughput
            let ttfts = completed.compactMap(\.ttftMilliseconds)
            let share = Double(group.count) / total
            return SessionModelTimeRow(id: name, colorIndex: palette.index(name), requests: "\(group.count)", requestShare: share,
                                       requestShareLabel: SessionStatsFormat.share(share) + " of requests",
                                       speed: rate.label ?? "—", speedCaption: "\(rate.samples)/\(group.count) measured",
                                       firstToken: SessionInfoTiming.median(ttfts).map(MetricFormat.latency) ?? "—",
                                       firstTokenCaption: ttfts.isEmpty ? "not measured" : "median of \(ttfts.count)")
        }
    }

    static func notes(_ inputs: SessionStatsInputs, requests: [SessionStatsRequest], history: SessionStatsHistory?) -> [String] {
        let gateway = inputs.gateway
        var notes = [SettledThroughput.explanation]
        let latency = gateway.settledLatency
        if latency.samples < latency.requests, latency.requests > 0 {
            notes.append("First-token latency was not recorded for every request; the average covers the \(latency.samples) that recorded it.")
        }
        let running = requests.filter { $0.state == .running }.count
        if running > 0 {
            notes.append("\(SessionStatsFormat.plural(running, "request is", "requests are")) still running and \(running == 1 ? "is" : "are") not drawn; every figure here is settled.")
        }
        let failed = requests.filter { $0.state == .failed }.count
        if failed > 0 {
            notes.append("\(SessionStatsFormat.plural(failed, "failed attempt is", "failed attempts are")) drawn in red on the timeline and left out of the speeds.")
        }
        if gateway.expiredRecords > 0 { notes.append("\(gateway.expiredRecords) expired records are excluded from every figure here.") }
        return notes
    }
}

// MARK: - Token usage (tokens · cache · cost)

/// The session's tokens as one bar of disjoint parts: cached input, cache
/// write and uncached input make up the input; reasoning and the rest make
/// up the output. Input whose cache use went unreported is its own part.
struct SessionTokenComposition: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable { case cached, cacheWrite, uncached, inputUnsplit, reasoning, output }
    struct Part: Sendable, Equatable, Identifiable {
        let id: Kind
        let title: String
        let tokens: Double
        let value: String
        let share: String
        let fraction: Double
        let detail: String?
    }
    let parts: [Part]
    let total: Double
    let totalLabel: String
    let subtitle: String
    let accessibility: String
}

/// The per-request token stack: what each request sent from cache and not,
/// and what it produced, in order. Past `maximumBars` requests, consecutive
/// requests are folded into bins that show their average request.
struct SessionTokenBars: Sendable, Equatable {
    struct Bar: Sendable, Equatable, Identifiable {
        let id: String
        let index: Int
        let x: Double
        let cached: Double
        let uncached: Double
        let inputUnsplit: Double
        let reasoning: Double
        let output: Double
        let label: String
        let value: String
        let caption: String
        var total: Double { cached + uncached + inputUnsplit + reasoning + output }
        /// The bar's category on the chart's x axis.
        var category: String { String(index) }
        /// The reported parts, stacked from zero in the chart's fixed order.
        var segments: [Segment] {
            var start = 0.0
            return [(SessionTokenComposition.Kind.cached, cached), (.uncached, uncached), (.inputUnsplit, inputUnsplit), (.reasoning, reasoning), (.output, output)]
                .compactMap { kind, tokens in
                    guard tokens > 0 else { return nil }
                    defer { start += tokens }
                    return Segment(kind: kind, from: start, to: start + tokens)
                }
        }
    }
    struct Segment: Sendable, Equatable {
        let kind: SessionTokenComposition.Kind
        let from: Double
        let to: Double
    }
    /// Each bar's reported parts, stacked, and the categories of the x axis:
    /// laid out once with the bars, never while a chart draws.
    var stacks: [[Segment]] = []
    var categories: [String] = []
    static let maximumBars = 96
    /// The plot's height in the popover.
    static let plotHeight: Double = 132
    let bars: [Bar]
    /// The first and last request numbers the bars cover.
    let requests: ClosedRange<Int>
    let binSize: Int
    let kinds: [SessionTokenComposition.Kind]
    let xDomain: ClosedRange<Double>
    let yMaximum: Double
    let ticks: [Double]
    let tickLabels: [String]
    let subtitle: String
    let summary: String?
    /// Written over the latest bar.
    var endLabel: String?
    let latestCaption: String
    let accessibility: String
    func label(forTick value: Double) -> String {
        ticks.firstIndex(of: value).map { tickLabels[$0] } ?? SessionStatsFormat.tokens(value)
    }
    func nearest(to x: Double) -> Int? {
        guard !bars.isEmpty else { return nil }
        return bars.indices.min { abs(bars[$0].x - x) < abs(bars[$1].x - x) }
    }
}

/// What the session has cost so far, request by request.
struct SessionCostSeries: Sendable, Equatable {
    struct Point: Sendable, Equatable, Identifiable {
        let id: String
        let index: Int
        let x: Double
        let cumulative: Double
        let label: String
        let value: String
        let caption: String
    }
    static let maximumPoints = 240
    /// The plot's height in the popover.
    static let plotHeight: Double = 96
    let points: [Point]
    let xDomain: ClosedRange<Double>
    let yMaximum: Double
    let ticks: [Double]
    let tickLabels: [String]
    let subtitle: String
    let latestCaption: String
    let accessibility: String
    /// Written at the end of the line: the session's cost so far.
    var endLabel: String?
    func label(forTick value: Double) -> String {
        ticks.firstIndex(of: value).map { tickLabels[$0] } ?? SessionStatsFormat.cost(value)
    }
    func nearest(to x: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        return points.indices.min { abs(points[$0].x - x) < abs(points[$1].x - x) }
    }
}

/// One model of a session that used several: its share of the tokens and of the cost.
struct SessionModelTokenRow: Sendable, Equatable, Identifiable {
    let id: String
    let colorIndex: Int
    let tokens: String
    let tokenShare: Double
    let tokenShareLabel: String
    let cost: String
    let costShare: Double?
    let costShareLabel: String
}

struct SessionTokenCharts: Sendable, Equatable {
    var hero: [SessionStatsFigure] = []
    /// Said once under the figures when some requests reported less than others.
    var coverage: String?
    var composition: SessionTokenComposition?
    var perRequest: SessionTokenBars?
    var cost: SessionCostSeries?
    var models: [SessionModelTokenRow] = []
    var notes: [String] = []
    var historyLoaded = false

    init(inputs: SessionStatsInputs, history: SessionStatsHistory?) {
        let gateway = inputs.gateway
        hero = Self.hero(gateway)
        coverage = Self.heroCoverage(gateway)
        historyLoaded = history != nil
        let requests = history.map(SessionTimeCharts.requests) ?? []
        if let history {
            let palette = SessionTimeCharts.palette(requests)
            composition = Self.composition(requests, history: history)
            perRequest = Self.bars(requests, history: history)
            cost = Self.cost(requests, history: history)
            models = Self.models(requests, palette: palette)
        }
        notes = Self.notes(gateway, requests: requests)
    }

    static func hero(_ gateway: GatewayTotals) -> [SessionStatsFigure] {
        let tokens = gateway.tokens ?? GatewayTokenTotals()
        var totalCaption: [String] = []
        if tokens.inputSamples > 0, let input = tokens.input { totalCaption.append("\(MetricFormat.exactTokens(input)) in") }
        if tokens.outputSamples > 0, let output = tokens.output { totalCaption.append("\(MetricFormat.exactTokens(output)) out") }
        let cost = gateway.costSamples > 0 ? gateway.costUSD : nil
        return [
            SessionStatsFigure(id: "tokens", value: gateway.billedTotalTokens.map(MetricFormat.exactTokens) ?? "—", title: "tokens",
                               caption: totalCaption.isEmpty ? "none reported" : totalCaption.joined(separator: " · ")),
            SessionStatsFigure(id: "cost", value: cost.map(SessionStatsFormat.cost) ?? "—", title: "cost",
                               caption: cost == nil ? "not reported" : "gateway-reported"),
            SessionStatsFigure(id: "cache", value: gateway.cacheHitPercent.map { $0 + "%" } ?? "—", title: "cache hit",
                               caption: gateway.cacheHitPercent == nil ? "not reported" : "of input, from cache"),
        ]
    }

    /// Which of the figures above cover fewer than all the session's
    /// requests, said once under them rather than under each.
    static func heroCoverage(_ gateway: GatewayTotals) -> String? {
        let tokens = gateway.tokens.map { max($0.inputSamples, $0.outputSamples) } ?? 0
        let figures = [("tokens", tokens), ("cost", gateway.costSamples), ("cache use", gateway.cacheHitSamples)]
        let partial = figures.filter { $0.1 > 0 && $0.1 < gateway.requests }
        guard let first = partial.first else { return nil }
        if partial.allSatisfy({ $0.1 == first.1 }) {
            let names = partial.map(\.0)
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            return "\(first.1) of \(gateway.requests) requests reported their \(list); the figures count only those."
        }
        // "Tokens reported by 4 of 5 requests, cache use by 2 of 5; …"
        let parts = partial.enumerated().map { index, entry in
            index == 0 ? "\(entry.0.prefix(1).uppercased() + entry.0.dropFirst()) reported by \(entry.1) of \(gateway.requests) requests"
                       : "\(entry.0) by \(entry.1) of \(gateway.requests)"
        }
        return parts.joined(separator: ", ") + "; the figures count only those."
    }

    /// One request's tokens, split into disjoint parts. Only reported figures
    /// count; a subset larger than its whole is a conflicting report and is
    /// not split.
    struct Split: Equatable {
        var cached = 0.0, cacheWrite = 0.0, uncached = 0.0, inputUnsplit = 0.0, reasoning = 0.0, output = 0.0
        var reportedCache = false, reportedReasoning = false, reportedInput = false, reportedOutput = false
        init(_ sample: SessionTimingSample) {
            if let input = sample.inputTokens {
                reportedInput = true
                if let read = sample.cacheReadTokens, read <= input {
                    reportedCache = true
                    cached = read
                    let rest = input - read
                    if let write = sample.cacheWriteTokens, write <= rest { cacheWrite = write; uncached = rest - write }
                    else { uncached = rest }
                } else { inputUnsplit = input }
            }
            if let out = sample.outputTokens {
                reportedOutput = true
                if let thinking = sample.reasoningTokens, thinking <= out { reportedReasoning = true; reasoning = thinking; output = out - thinking }
                else { output = out }
            }
        }
        var input: Double { cached + cacheWrite + uncached + inputUnsplit }
        var total: Double { input + reasoning + output }
    }

    static func composition(_ requests: [SessionStatsRequest], history: SessionStatsHistory) -> SessionTokenComposition? {
        var sums = [SessionTokenComposition.Kind: Double]()
        var cacheReported = 0, inputReported = 0, reasoningReported = 0, outputReported = 0
        for request in requests {
            let split = Split(request.sample)
            sums[.cached, default: 0] += split.cached; sums[.cacheWrite, default: 0] += split.cacheWrite
            sums[.uncached, default: 0] += split.uncached; sums[.inputUnsplit, default: 0] += split.inputUnsplit
            sums[.reasoning, default: 0] += split.reasoning; sums[.output, default: 0] += split.output
            if split.reportedInput { inputReported += 1; if split.reportedCache { cacheReported += 1 } }
            if split.reportedOutput { outputReported += 1; if split.reportedReasoning { reasoningReported += 1 } }
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return nil }
        let anyCache = cacheReported > 0, anyReasoning = reasoningReported > 0
        func title(_ kind: SessionTokenComposition.Kind) -> String {
            switch kind {
            case .cached: "Cached input"
            case .cacheWrite: "Cache write"
            case .uncached: "Uncached input"
            case .inputUnsplit: anyCache ? "Input, cache not reported" : "Input"
            case .reasoning: "Reasoning"
            case .output: anyReasoning ? "Other output" : "Output"
            }
        }
        func detail(_ kind: SessionTokenComposition.Kind) -> String? {
            switch kind {
            case .cached: "served from the prompt cache"
            case .cacheWrite: "written to the prompt cache"
            case .uncached: "sent in full"
            case .inputUnsplit: anyCache ? "\(SessionStatsFormat.plural(inputReported - cacheReported, "request", "requests")) reported no cache counter" : "no request reported its cache use"
            case .reasoning: "part of output"
            case .output: anyReasoning ? (reasoningReported < outputReported ? "\(SessionStatsFormat.plural(outputReported - reasoningReported, "request", "requests")) reported no reasoning" : "the reply and its tool calls") : "no request reported reasoning"
            }
        }
        let parts = SessionTokenComposition.Kind.allCases.compactMap { kind -> SessionTokenComposition.Part? in
            guard let tokens = sums[kind], tokens > 0 else { return nil }
            return SessionTokenComposition.Part(id: kind, title: title(kind), tokens: tokens, value: MetricFormat.exactTokens(tokens),
                                                share: SessionStatsFormat.share(tokens / total), fraction: tokens / total, detail: detail(kind))
        }
        var subtitle = "\(MetricFormat.exactTokens(total)) tokens, the input and then the output"
        if history.olderRequests > 0 { subtitle = "The latest \(history.requests.count) of \(history.total) requests, \(MetricFormat.exactTokens(total)) tokens" }
        let spoken = parts.map { "\($0.title) \($0.value) tokens, \($0.share)" }.joined(separator: "; ")
        return SessionTokenComposition(parts: parts, total: total, totalLabel: MetricFormat.exactTokens(total), subtitle: subtitle,
                                       accessibility: "Token composition, \(MetricFormat.exactTokens(total)) tokens: " + spoken)
    }

    static func bars(_ requests: [SessionStatsRequest], history: SessionStatsHistory) -> SessionTokenBars? {
        let reported = requests.filter { $0.state != .running && ($0.sample.inputTokens != nil || $0.sample.outputTokens != nil) }
        guard !reported.isEmpty else { return nil }
        let binSize = max(1, Int((Double(reported.count) / Double(SessionTokenBars.maximumBars)).rounded(.up)))
        var bars: [SessionTokenBars.Bar] = []
        var kinds = Set<SessionTokenComposition.Kind>()
        var start = 0
        while start < reported.count {
            let bin = Array(reported[start..<min(start + binSize, reported.count)])
            start += binSize
            guard let first = bin.first, let last = bin.last else { continue }
            let splits = bin.map { Split($0.sample) }
            // A bin draws its average request; a single request, itself.
            let inputs = max(1, Double(splits.filter(\.reportedInput).count)), outputs = max(1, Double(splits.filter(\.reportedOutput).count))
            let cached = splits.reduce(0) { $0 + $1.cached } / inputs
            let uncached = splits.reduce(0) { $0 + $1.uncached + $1.cacheWrite } / inputs
            let unsplit = splits.reduce(0) { $0 + $1.inputUnsplit } / inputs
            let reasoning = splits.reduce(0) { $0 + $1.reasoning } / outputs
            let output = splits.reduce(0) { $0 + $1.output } / outputs
            if cached > 0 { kinds.insert(.cached) }; if uncached > 0 { kinds.insert(.uncached) }; if unsplit > 0 { kinds.insert(.inputUnsplit) }
            if reasoning > 0 { kinds.insert(.reasoning) }; if output > 0 { kinds.insert(.output) }
            var parts: [String] = []
            let single = bin.count == 1
            let sample = first.sample
            if single {
                if let input = sample.inputTokens {
                    var input = "\(MetricFormat.exactTokens(input)) in"
                    if let read = sample.cacheReadTokens, read <= (sample.inputTokens ?? 0) {
                        input += " (\(MetricFormat.exactTokens(read)) cached, \(MetricFormat.exactTokens(uncached)) uncached)"
                    } else { input += " (cache not reported)" }
                    parts.append(input)
                }
                if let out = sample.outputTokens {
                    parts.append("\(MetricFormat.exactTokens(out)) out" + (sample.reasoningTokens.map { $0 <= out ? " (\(MetricFormat.exactTokens($0)) reasoning)" : "" } ?? ""))
                }
            } else {
                parts.append("average \(MetricFormat.exactTokens((cached + uncached + unsplit).rounded())) in (\(MetricFormat.exactTokens(cached.rounded())) cached)")
                parts.append("\(MetricFormat.exactTokens((reasoning + output).rounded())) out")
            }
            let name = single ? "Request \(first.number)" : "Requests \(first.number)–\(last.number)"
            let lead = single ? [name, SessionStatsFormat.clock(sample.wall), first.model] : [name]
            bars.append(SessionTokenBars.Bar(id: sample.id, index: bars.count, x: single ? Double(first.number) : Double(first.number + last.number) / 2,
                                             cached: cached, uncached: uncached, inputUnsplit: unsplit, reasoning: reasoning, output: output,
                                             label: single ? "\(name), \(first.model)" : name, value: parts.joined(separator: ", "),
                                             caption: (lead + parts).joined(separator: " · ")))
        }
        // One request's bar is the composition above, already drawn.
        guard bars.count > 1, let first = bars.first, let last = bars.last else { return nil }
        let maximum = bars.map(\.total).max() ?? 0
        // Room over the tallest bar for the latest bar's label.
        // Room over the latest bar for its label, and over the top tick for its own.
        let labelRoom = (SessionStatsFormat.labelHalfHeight * 2 + SessionStatsFormat.endLabelSpacing) / SessionTokenBars.plotHeight
        let clear = max(SessionStatsFormat.ceiling(maximum), last.total / (1 - labelRoom))
        let ticks = SessionStatsFormat.ticks(upTo: maximum, within: clear)
        let top = SessionStatsFormat.axisTop(clear, ticks: ticks, plotHeight: SessionTokenBars.plotHeight)
        let span = max(1, last.x - first.x)
        let pad = max(0.6, span / Double(max(1, bars.count)) * 0.6)
        var subtitle = "Each request's input, cached and not, then its output, in the order they ran"
        if binSize > 1 { subtitle = "Each bar averages \(binSize) consecutive requests: input, cached and not, then output" }
        if history.olderRequests > 0 { subtitle += " · the latest \(history.requests.count) of \(history.total)" }
        // What the stack says at a glance: how far the context grew, and what the cache took of it.
        var summary: String?
        let inputs = reported.compactMap(\.sample.inputTokens)
        if inputs.count > 1, let firstInput = inputs.first, let lastInput = inputs.last {
            let from = MetricFormat.tokens(firstInput), to = MetricFormat.tokens(lastInput)
            if lastInput > firstInput * 1.05, from != to { summary = "Input grew from \(from) to \(to) per request" }
            else if lastInput < firstInput * 0.95, from != to { summary = "Input fell from \(from) to \(to) per request" }
            else { summary = "Input held at about \(to) per request" }
        }
        let splits = reported.map { Split($0.sample) }
        let cachedTotal = splits.reduce(0) { $0 + $1.cached }, pairedInput = splits.filter(\.reportedCache).reduce(0) { $0 + $1.input }
        if cachedTotal > 0, pairedInput > 0 {
            let saved = "the cache served \(SessionStatsFormat.share(cachedTotal / pairedInput)) of it"
            summary = summary.map { $0 + "; " + saved } ?? ("The cache served " + SessionStatsFormat.share(cachedTotal / pairedInput) + " of input")
        }
        let spoken = "Tokens per request, \(bars.count) bars" + (binSize > 1 ? " of \(binSize) requests each" : "") + ". " + (summary.map { $0 + "." } ?? "")
        let numbers = (reported.first?.number ?? 1)...max(reported.first?.number ?? 1, reported.last?.number ?? 1)
        var series = SessionTokenBars(bars: bars, requests: numbers, binSize: binSize, kinds: SessionTokenComposition.Kind.allCases.filter { kinds.contains($0) },
                                      xDomain: (first.x - pad)...(last.x + pad), yMaximum: top,
                                      ticks: ticks, tickLabels: ticks.map(SessionStatsFormat.tokens), subtitle: subtitle, summary: summary,
                                      latestCaption: "Latest · " + last.caption, accessibility: spoken)
        series.stacks = bars.map(\.segments)
        series.categories = bars.map(\.category)
        // The latest bar says how big it is: where the context stands now.
        series.endLabel = MetricFormat.tokens(last.total)
        return series
    }

    static func cost(_ requests: [SessionStatsRequest], history: SessionStatsHistory) -> SessionCostSeries? {
        let settled = requests.filter { $0.state != .running }
        let reported = settled.filter { $0.sample.costUSD != nil }
        // No reported cost has no line; one request's cost is the figure above.
        guard !reported.isEmpty, settled.count > 1 else { return nil }
        var running = 0.0
        var all: [(request: SessionStatsRequest, cumulative: Double)] = []
        for request in settled {
            running += request.sample.costUSD ?? 0
            all.append((request, running))
        }
        // A long session keeps every step of the line's shape at a fraction of the marks.
        let stride = max(1, Int((Double(all.count) / Double(SessionCostSeries.maximumPoints)).rounded(.up)))
        let kept = all.enumerated().filter { $0.offset % stride == 0 || $0.offset == all.count - 1 }.map(\.element)
        let points = kept.enumerated().map { index, entry in
            let sample = entry.request.sample
            let own = sample.costUSD.map { SessionStatsFormat.cost($0) + " this request" } ?? "cost not reported"
            let value = "\(own), \(SessionStatsFormat.cost(entry.cumulative)) so far"
            return SessionCostSeries.Point(id: sample.id, index: index, x: Double(entry.request.number), cumulative: entry.cumulative,
                                           label: "Request \(entry.request.number), \(entry.request.model)", value: value,
                                           caption: ["Request \(entry.request.number)", SessionStatsFormat.clock(sample.wall), entry.request.model, own,
                                                     SessionStatsFormat.cost(entry.cumulative) + " so far"].joined(separator: " · "))
        }
        guard let first = points.first, let last = points.last else { return nil }
        // Room over the line's end for the total written beside it.
        let clear = max(SessionStatsFormat.ceiling(running), running / (1 - SessionStatsFormat.labelHalfHeight / SessionCostSeries.plotHeight))
        let ticks = SessionStatsFormat.ticks(upTo: running, within: clear)
        let top = SessionStatsFormat.axisTop(clear, ticks: ticks, plotHeight: SessionCostSeries.plotHeight)
        var subtitle = reported.count < settled.count
            ? "\(reported.count) of \(settled.count) requests reported a cost; the others add nothing here"
            : "Every request reported its cost"
        if stride > 1 { subtitle += " · every \(stride)th request drawn" }
        if history.olderRequests > 0 { subtitle += " · from the latest \(history.requests.count) of \(history.total)" }
        let spoken = "Cumulative cost over \(SessionStatsFormat.plural(settled.count, "request", "requests")), \(SessionStatsFormat.cost(running)) in all."
        var series = SessionCostSeries(points: points, xDomain: first.x...max(first.x + 1, last.x), yMaximum: top,
                                       ticks: ticks, tickLabels: SessionStatsFormat.costTicks(ticks), subtitle: subtitle,
                                       latestCaption: "Latest · " + last.caption, accessibility: spoken)
        series.endLabel = SessionStatsFormat.cost(running)
        return series
    }

    static func models(_ requests: [SessionStatsRequest], palette: MonitorModelPalette) -> [SessionModelTokenRow] {
        var order: [String] = []
        var tokens: [String: Double] = [:], costs: [String: Double] = [:], costed: [String: Int] = [:]
        for request in requests where request.state != .running {
            if tokens[request.model] == nil { order.append(request.model) }
            let split = Split(request.sample)
            tokens[request.model, default: 0] += split.total
            if let cost = request.sample.costUSD { costs[request.model, default: 0] += cost; costed[request.model, default: 0] += 1 }
        }
        guard order.count > 1 else { return [] }
        let allTokens = tokens.values.reduce(0, +), allCost = costs.values.reduce(0, +)
        return order.sorted { (tokens[$0] ?? 0) > (tokens[$1] ?? 0) }.map { name in
            let share = allTokens > 0 ? (tokens[name] ?? 0) / allTokens : 0
            let cost = costs[name]
            let costShare = cost.flatMap { allCost > 0 ? $0 / allCost : nil }
            return SessionModelTokenRow(id: name, colorIndex: palette.index(name), tokens: MetricFormat.exactTokens(tokens[name] ?? 0),
                                        tokenShare: share, tokenShareLabel: SessionStatsFormat.share(share) + " of tokens",
                                        cost: cost.map(SessionStatsFormat.cost) ?? "—", costShare: costShare,
                                        costShareLabel: costShare.map { SessionStatsFormat.share($0) + " of cost" } ?? "no cost reported")
        }
    }

    static func notes(_ gateway: GatewayTotals, requests: [SessionStatsRequest]) -> [String] {
        // Partial coverage of the figures is said once, under them.
        var notes = ["Cached input is part of input; reasoning is part of output. Neither is added again."]
        let running = requests.filter { $0.state == .running }.count
        if running > 0 {
            notes.append("\(SessionStatsFormat.plural(running, "request is", "requests are")) still running; \(running == 1 ? "its" : "their") usage appears once \(running == 1 ? "it settles" : "they settle").")
        }
        let failed = requests.filter { $0.state == .failed }
        if !failed.isEmpty {
            let billed = failed.filter { $0.sample.inputTokens != nil || $0.sample.outputTokens != nil || $0.sample.costUSD != nil }.count
            notes.append(billed > 0
                         ? "\(SessionStatsFormat.plural(failed.count, "failed attempt", "failed attempts")) \(failed.count == 1 ? "is" : "are") counted where the gateway reported usage or cost for \(failed.count == 1 ? "it" : "them")."
                         : "\(SessionStatsFormat.plural(failed.count, "failed attempt", "failed attempts")) reported no usage and \(failed.count == 1 ? "adds" : "add") nothing here.")
        }
        if gateway.expiredRecords > 0 { notes.append("\(gateway.expiredRecords) expired records are excluded.") }
        return notes
    }
}
