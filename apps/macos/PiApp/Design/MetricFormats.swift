import Foundation

/// How every figure on a pill, in a pill's dialog and in the per-request
/// ledger is written. One place, so a token count reads the same under the
/// composer, at the end of a turn and in Session info.
///
/// Pure functions over validated numbers: an unobservable value is never
/// invented, and a partial cache hit is never rounded up into a full one.
enum MetricFormat {
    // MARK: Tokens

    /// `517`, `12.2K`, `517K`, `1.2M`. One decimal below a hundred of the
    /// unit, whole numbers above it, and the unit letter uppercase. A value
    /// whose rounding reaches a thousand of one unit is written in the next:
    /// 999,500 is `1M`, never `1000K`.
    static func tokens(_ value: Double) -> String {
        guard let value = observed(value) else { return "—" }
        if value.rounded() < 1_000 { return whole(value) }
        let units: [(scale: Double, letter: String)] = [(1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B")]
        for (index, unit) in units.enumerated() {
            let amount = value / unit.scale
            let shown = amount >= 100 ? amount.rounded() : (amount * 10).rounded() / 10
            if shown < 1_000 || index == units.count - 1 { return scaled(amount) + unit.letter }
        }
        return "—"
    }

    /// `15,800` — the exact count a dialog shows, grouped in threes.
    static func exactTokens(_ value: Double) -> String {
        guard let value = observed(value) else { return "—" }
        return TranscriptActivity.grouped(value)
    }

    /// `15.8K tok` for a pill, `15,800 tok` for a dialog.
    static func tokenCount(_ value: Double) -> String { tokens(value) + " tok" }
    static func exactTokenCount(_ value: Double) -> String { exactTokens(value) + " tok" }

    // MARK: Cache hit

    /// The share of prompt-side input served from cache, as display text
    /// without its percent sign.
    ///
    /// A hit that missed even one token must never read `100`: when the
    /// requested precision would round there, the figure takes as many extra
    /// decimal places as it needs to stay honest (`99.96`, `99.999`). Only an
    /// exact full hit returns `100`; no billed input at all returns nil. The
    /// same honesty holds at the other end: a hit too small for the requested
    /// precision reads `<1` (`<0.1`, `<0.01`), never `0` — only no cached
    /// token at all is a zero.
    /// - Parameters:
    ///   - read: prompt tokens served from cache.
    ///   - prompt: aggregate prompt-side tokens billed.
    ///   - decimals: ordinary precision; compact labels default to zero.
    static func cacheHitPercent(read: Double, prompt: Double, decimals: Int = 0) -> String? {
        guard let read = observed(read), let prompt = observed(prompt), prompt > 0, read <= prompt else { return nil }
        let hit = read
        if prompt - hit <= 0 { return "100" }
        let ratio = hit / prompt * 100
        var places = max(0, min(6, decimals))
        if hit > 0, (ratio * pow(10.0, Double(places))).rounded() == 0 {
            return "<" + trimmed(pow(10.0, -Double(places)), places: places)
        }
        // Climb one decimal place at a time until the rendered figure is
        // strictly under a hundred; nine places is far past any real coverage.
        while places <= 9 {
            let scale = pow(10.0, Double(places))
            let rounded = (ratio * scale).rounded() / scale
            if rounded < 100 { return trimmed(rounded, places: places) }
            places += 1
        }
        return "99.999999999"
    }

    /// The same honest figure written with at least `decimals` places, so a
    /// reading keeps its width: `50.00`, `75.94`, `100.00`. More places only
    /// where honest rounding needs them (`99.996`); `<0.01` stays as it is.
    static func paddedCacheHitPercent(read: Double, prompt: Double, decimals: Int = 2) -> String? {
        guard let text = cacheHitPercent(read: read, prompt: prompt, decimals: decimals) else { return nil }
        guard !text.hasPrefix("<") else { return text }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        guard fraction.count < decimals else { return text }
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: decimals - fraction.count)
    }

    /// The context ring's reading, without a sign. The same honest rounding as
    /// a cache hit, and a context that holds something but very little reads
    /// `<1` rather than `0`, so an occupied window never looks empty. The
    /// detail line asks for a decimal more and still agrees with the ring.
    static func occupancyPercent(_ fraction: Double) -> String? { occupancyPercent(fraction, decimals: 0) }
    static func occupancyPercent(_ fraction: Double, decimals: Int) -> String? {
        guard fraction.isFinite, fraction >= 0 else { return nil }
        guard let text = cacheHitPercent(read: min(fraction, 1) * 1_000_000, prompt: 1_000_000, decimals: decimals) else { return nil }
        return text == "0" && fraction > 0 ? "<1" : text
    }

    // MARK: Durations

    /// Detailed reports retain milliseconds and sub-millisecond latencies,
    /// rather than rounding a quick request to zero or discarding seconds.
    static func detailedDuration(_ milliseconds: Double) -> String {
        guard let value = DurationObservation.valid(milliseconds) else { return "—" }
        if value == 0 { return "0s" }
        // Below a millisecond, three decimals: a quick call never reads as zero.
        if value < 1 { return value < 0.001 ? "<0.001 ms" : trimmed(value, places: 3) + " ms" }
        // Milliseconds that round up to a second are written as the second.
        if (value * 1_000).rounded() < 1_000_000 { return trimmed(value, places: 3) + " ms" }
        guard let rounded = Int(exactly: value.rounded()) else { return "—" }
        let seconds = Double(rounded % 60_000) / 1_000
        let tail = trimmed(seconds, places: 3) + "s"
        let minutes = rounded / 60_000, hours = minutes / 60
        if hours > 0 { return "\(hours)h \(minutes % 60)m " + tail }
        return minutes > 0 ? "\(minutes)m " + tail : tail
    }

    /// Keep small gateway observations useful without floating-point noise.
    /// Extremely small nonzero amounts use six significant digits.
    static func preciseDecimal(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value > 0 && value < 0.000000000001 { return String(format: "%.6g", value) }
        return trimmed(value, places: 12)
    }

    /// `19s`, `1m 05s`, `1h 05m 03s` — the elapsed wall time of a turn or a
    /// session, in whole seconds with the smaller units zero-padded.
    ///
    /// A turn that finished inside a second keeps one decimal (`0.5s`): the
    /// reference never had one that fast, and "0s" would read as no time at all.
    static func runDuration(_ milliseconds: Double) -> String {
        guard let milliseconds = DurationObservation.valid(milliseconds),
              let total = Int(exactly: (milliseconds / 1_000).rounded(.down)) else { return "—" }
        if total == 0 {
            if milliseconds == 0 { return "0s" }
            if milliseconds < 100 { return "<0.1s" }
            return trimmed((milliseconds / 100).rounded(.down) / 10, places: 1) + "s"
        }
        let hours = total / 3_600, minutes = (total / 60) % 60, seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    /// A sub-turn latency such as TTFT or a decode span. Under a second it
    /// reads in milliseconds, because a 2 ms first token is not "0s"; from a
    /// second up it reads in seconds, one decimal under ten.
    static func latency(_ milliseconds: Double) -> String {
        guard let milliseconds = DurationObservation.valid(milliseconds) else { return "—" }
        // Milliseconds that round up to a second are written as the second:
        // 999.6 ms is "1s", never "1000 ms".
        if milliseconds.rounded() < 1_000 { return whole(milliseconds.rounded()) + " ms" }
        let seconds = milliseconds / 1_000
        return (seconds < 10 ? trimmed((seconds * 10).rounded() / 10, places: 1) : whole(seconds.rounded())) + "s"
    }

    // MARK: Throughput

    /// `34 tok/s`, and one decimal under ten (`3.4 tok/s`). The settled rate
    /// only: nothing here is computed while a request is still running.
    static func throughput(_ tokensPerSecond: Double) -> String {
        let value = throughputValue(tokensPerSecond)
        return value == "—" ? value : value + " tok/s"
    }

    /// The same figure without its unit, for a dialog row that names it.
    static func throughputValue(_ tokensPerSecond: Double) -> String {
        guard let value = observed(tokensPerSecond) else { return "—" }
        return value >= 10 ? whole(value.rounded()) : trimmed((value * 10).rounded() / 10, places: 1)
    }

    // MARK: Internals

    private static func observed(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    /// A hundred of the unit and up reads whole; below it, one decimal.
    private static func scaled(_ value: Double) -> String {
        value >= 100 ? whole(value.rounded()) : trimmed((value * 10).rounded() / 10, places: 1)
    }
    private static func whole(_ value: Double) -> String { TranscriptActivity.grouped(value).replacingOccurrences(of: ",", with: "") }
    /// A trailing zero says nothing: `50.0` is `50`, `12.20` is `12.2`.
    private static func trimmed(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(max(0, places))f", value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The model's decode speed, the standard definition (LLMPerf, vLLM's TPOT):
/// a request's reported output tokens after the first (N − 1, hidden
/// reasoning included) over the time from its first generated token to its
/// last. Over that span the first token is already out, so only N − 1 arrive
/// in it; and the response's terminal event, which a gateway can hold while it
/// computes usage and cost, carries none. A group — a turn, a session, a route,
/// a time slice — is one division of the sums, Σ(N − 1) ÷ Σ span, over the
/// requests counted: completed, at least two output tokens, and a span long
/// enough to be a measurement. Any other request contributes nothing rather
/// than a zero, and the sample counts keep that visible.
///
/// This is the only throughput the app shows. It is never computed from a
/// request still in flight, and it never includes the wait before the first
/// token, so it reads as the model's decode speed rather than as round-trip
/// latency.
struct SettledThroughput: Equatable, Sendable, Codable {
    /// Summed decode spans (first to last output) of the sampled requests.
    var decodeMilliseconds: Double = 0
    /// Summed output tokens after each sampled request's first (N − 1): what
    /// the rate divides, not a token count to show. The reported output of a
    /// request, N, is shown from its own usage, never from here.
    var outputTokens: Double = 0
    /// Requests counted in the rate.
    var samples = 0
    /// Requests considered, whether or not they reported.
    var requests = 0

    init(decodeMilliseconds: Double = 0, outputTokens: Double = 0, samples: Int = 0, requests: Int = 0) {
        self.decodeMilliseconds = decodeMilliseconds; self.outputTokens = outputTokens
        self.samples = samples; self.requests = requests
    }

    /// The shortest decode span that is a measurement. A reply delivered in
    /// one burst spans a few milliseconds from its first output to its last,
    /// and its tokens over that read as 100,000 tok/s: below this, timestamp
    /// jitter and batched delivery make the span meaningless. The helper
    /// applies the same floor to the rate it reports
    /// (`metrics.minimumDecodeSpanMs`), and so does the archive's SQL
    /// (`GatewayAccounting.settledThroughputSQL`).
    static let minimumDecodeMilliseconds: Double = 250
    /// The floor as the explanations write it: `250 ms`.
    static let floorLabel = "\(Int(minimumDecodeMilliseconds)) ms"

    /// Fold one request in: its decode span (first to last output) and its
    /// reported output tokens, N. Either figure missing, fewer than two tokens
    /// (one token has no tokens after it) or a span shorter than
    /// `minimumDecodeMilliseconds` leaves the rate untouched. The request is
    /// still counted.
    mutating func add(decodeMilliseconds: Double?, outputTokens: Double?) {
        requests += 1
        guard let decode = DurationObservation.valid(decodeMilliseconds), decode >= Self.minimumDecodeMilliseconds,
              let output = outputTokens, output.isFinite, output >= 2 else { return }
        self.decodeMilliseconds += decode
        self.outputTokens += output - 1
        samples += 1
    }

    /// Fold an already-summed group (a turn, a session) in.
    mutating func add(_ other: SettledThroughput) {
        decodeMilliseconds += other.decodeMilliseconds; outputTokens += other.outputTokens
        samples += other.samples; requests += other.requests
    }

    /// Nil unless the sums are a real measurement: a decode time that is
    /// finite and positive, and an output that is not negative (or NaN). A
    /// sum that overflowed must never read as 0 tok/s.
    var tokensPerSecond: Double? {
        guard samples > 0, decodeMilliseconds.isFinite, decodeMilliseconds > 0, outputTokens >= 0 else { return nil }
        let rate = outputTokens / (decodeMilliseconds / 1_000)
        return rate.isFinite ? rate : nil
    }
    /// `34 tok/s`, or nil when no request reported both figures.
    var label: String? { tokensPerSecond.map(MetricFormat.throughput) }
    /// What the dialog says when only some requests were measurable.
    var coverage: String? { samples < requests ? "\(samples)/\(requests) requests measured" : nil }

    static let explanation = "Output tokens after the first ÷ time from the first generated token to the last (hidden reasoning included); replies under \(floorLabel) of generation are left out. Not a live rate, and not round-trip latency."
}

/// A first-token latency averaged over the requests that recorded it.
struct SettledLatency: Equatable, Sendable, Codable {
    var milliseconds: Double = 0
    var samples = 0
    var requests = 0

    init(milliseconds: Double = 0, samples: Int = 0, requests: Int = 0) {
        self.milliseconds = milliseconds; self.samples = samples; self.requests = requests
    }
    mutating func add(milliseconds value: Double?) {
        requests += 1
        guard let value = DurationObservation.valid(value) else { return }
        milliseconds += value; samples += 1
    }
    mutating func add(_ other: SettledLatency) {
        milliseconds += other.milliseconds; samples += other.samples; requests += other.requests
    }
    var average: Double? { samples > 0 ? milliseconds / Double(samples) : nil }
    var label: String? { average.map(MetricFormat.latency) }
    var coverage: String? { samples < requests ? "\(samples)/\(requests) requests measured" : nil }
}
