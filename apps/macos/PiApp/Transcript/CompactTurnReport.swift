import AppKit

/// A turn's input or output: every token the turn's requests reported, as the
/// headline, and the share of it that was cached (or reasoning), drawn from
/// the requests that reported both counters. Those two need not be the same
/// requests — a request can report its input and no cache counter — so the
/// headline says how many requests it covers, and the colours keep the last
/// matched split while later requests are pending or never report one.
struct TurnTokenPartition: Equatable {
    enum Fill: Equatable { case empty, reported, split(Double) }
    let title: String
    /// Every reported token of this kind, whichever requests reported it.
    let total: Double?
    /// The requests `total` covers, of the turn's `requests`.
    let totalSamples: Int
    let requests: Int
    /// The parent of the split: the same requests as `part`.
    let splitTotal: Double?
    let splitSamples: Int?
    let part: Double?
    let remainder: Double?
    let partName: String
    let remainderName: String
    let fraction: Double?
    let partial: Bool
    /// A running turn has requests whose counters may still arrive.
    let running: Bool

    init(_ a: TurnAccounting, input: Bool, running: Bool = false) {
        title = input ? "Input" : "Output"
        partName = input ? "Cached" : "Reasoning"
        remainderName = input ? "Uncached" : "Other"
        requests = a.requests
        self.running = running
        let samples = input ? a.inputSamples : a.outputSamples
        let partSamples = input ? a.cachedSamples : a.reasoningSamples
        func valid(_ value: Double?, _ count: Int) -> Double? {
            guard count > 0, let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let paired = a.split(input: input)
        let reported = valid(input ? a.input : a.output, samples)
        total = reported ?? paired?.total
        totalSamples = reported != nil ? samples : paired?.samples ?? 0
        part = paired?.part ?? valid(input ? a.cached : a.reasoning, partSamples)
        splitTotal = paired?.total; splitSamples = paired?.samples
        if let paired {
            remainder = paired.total - paired.part
            fraction = paired.total > 0 ? paired.part / paired.total : nil
        } else {
            remainder = input ? valid(a.uncached, a.uncachedSamples) : nil
            fraction = nil
        }
        partial = a.requests > 0 && (paired.map { $0.samples < a.requests } ?? (samples < a.requests || partSamples < a.requests))
    }

    /// `11,800`, and `11,800 (2/3)` when some requests have not reported it.
    var totalLabel: String {
        guard let total else { return "—" }
        return MetricFormat.exactTokens(total) + (requests > 0 && totalSamples < requests ? " (\(totalSamples)/\(requests))" : "")
    }
    /// The track represents reported tokens, not reporting completeness.
    /// Keep it filled when a breakdown is missing, without inventing a split.
    var fill: Fill {
        if let fraction { return .split(fraction) }
        return [total, part, remainder].contains { ($0 ?? 0) > 0 } ? .reported : .empty
    }
    /// A share is of the split's own parent, never of the larger headline.
    func label(part first: Bool) -> String {
        let name = first ? partName : remainderName
        let value = first ? part : remainder
        var text = name + " " + (value.map(MetricFormat.exactTokens) ?? "—")
        if let splitTotal, fraction != nil, let value,
           let percent = MetricFormat.cacheHitPercent(read: value, prompt: splitTotal, decimals: 2) {
            text += " · " + percent + "%"
        }
        return text
    }
    var help: String {
        let count: (Double?) -> String = { $0.map(MetricFormat.exactTokens) ?? "unreported" }
        let coverage = requests > 0 && total != nil && totalSamples < requests ? " from \(totalSamples) of \(requests) requests" : ""
        var text = "\(title): \(count(total)) tokens\(coverage). \(partName): \(count(part)); \(remainderName): \(count(remainder)). "
        if partial {
            if fraction != nil, let splitSamples {
                text += "The split covers the \(splitSamples) of \(requests) requests that reported both counters"
                    + (running ? "; newer requests may still be pending. " : ". ")
            } else {
                text += "Some requests have not reported both counters. "
            }
        }
        if fill == .reported { text += "The filled bar represents reported tokens; the percentage breakdown is unavailable. " }
        return text + (title == "Input" ? "Cached tokens are included in input." : "Reasoning tokens are included in output.")
    }
}
