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
    /// unit, whole numbers above it, and the unit letter uppercase.
    static func tokens(_ value: Double) -> String {
        guard let value = observed(value) else { return "—" }
        if value < 1_000 { return whole(value) }
        if value < 1_000_000 { return scaled(value / 1_000) + "K" }
        return scaled(value / 1_000_000) + "M"
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
    /// exact full hit returns `100`; no billed input at all returns nil.
    /// - Parameters:
    ///   - read: prompt tokens served from cache.
    ///   - prompt: aggregate prompt-side tokens billed.
    ///   - decimals: the ordinary precision, 0 or 1.
    static func cacheHitPercent(read: Double, prompt: Double, decimals: Int = 0) -> String? {
        guard let read = observed(read), let prompt = observed(prompt), prompt > 0, read <= prompt else { return nil }
        let hit = read
        if prompt - hit <= 0 { return "100" }
        let ratio = hit / prompt * 100
        var places = max(0, min(1, decimals))
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

    /// The context ring's reading, without a sign. The same honest rounding as
    /// a cache hit, and a context that holds something but very little reads
    /// `<1` rather than `0`, so an occupied window never looks empty.
    static func occupancyPercent(_ fraction: Double) -> String? {
        guard fraction.isFinite, fraction >= 0 else { return nil }
        guard let text = cacheHitPercent(read: min(fraction, 1) * 1_000_000, prompt: 1_000_000) else { return nil }
        return text == "0" && fraction > 0 ? "<1" : text
    }

    // MARK: Durations

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
        if milliseconds < 1_000 { return whole(milliseconds.rounded()) + " ms" }
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

/// Provider output tokens divided by decode time — the first token to the
/// completion of the same request — accumulated over the requests that
/// reported both. A request missing either figure contributes nothing rather
/// than a zero, and the sample counts keep that visible.
///
/// This is the only throughput the app shows. It is never computed from a
/// request still in flight, and it never includes the wait before the first
/// token, so it reads as the model's decode speed rather than as round-trip
/// latency.
struct SettledThroughput: Equatable, Sendable, Codable {
    /// Summed decode wall time of the sampled requests.
    var decodeMilliseconds: Double = 0
    /// Summed provider output tokens of the same sampled requests.
    var outputTokens: Double = 0
    /// Requests that reported both a decode time and output tokens.
    var samples = 0
    /// Requests considered, whether or not they reported.
    var requests = 0

    init(decodeMilliseconds: Double = 0, outputTokens: Double = 0, samples: Int = 0, requests: Int = 0) {
        self.decodeMilliseconds = decodeMilliseconds; self.outputTokens = outputTokens
        self.samples = samples; self.requests = requests
    }

    /// Fold one request in. Either figure missing, or a decode time of zero,
    /// leaves the rate untouched: a rate needs both ends of the measurement.
    mutating func add(decodeMilliseconds: Double?, outputTokens: Double?) {
        requests += 1
        guard let decode = DurationObservation.valid(decodeMilliseconds), decode > 0,
              let output = outputTokens, output.isFinite, output >= 0 else { return }
        self.decodeMilliseconds += decode
        self.outputTokens += output
        samples += 1
    }

    /// Fold an already-summed group (a turn, a session) in.
    mutating func add(_ other: SettledThroughput) {
        decodeMilliseconds += other.decodeMilliseconds; outputTokens += other.outputTokens
        samples += other.samples; requests += other.requests
    }

    var tokensPerSecond: Double? {
        guard samples > 0, decodeMilliseconds > 0 else { return nil }
        let rate = outputTokens / (decodeMilliseconds / 1_000)
        return rate.isFinite ? rate : nil
    }
    /// `34 tok/s`, or nil when no request reported both figures.
    var label: String? { tokensPerSecond.map(MetricFormat.throughput) }
    /// What the dialog says when only some requests were measurable.
    var coverage: String? { samples < requests ? "\(samples)/\(requests) requests measured" : nil }

    static let explanation = "Provider output tokens divided by decode time — first token to completion — over the requests that reported both. Not a live rate, and not round-trip latency."
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
