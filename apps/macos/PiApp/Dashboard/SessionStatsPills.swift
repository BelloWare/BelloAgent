import SwiftUI

/// The readings of the two session pills under the composer.
///
/// Pure over the session's gateway totals and the helper's session clocks, so
/// every string here is asserted without a view. Nothing is a live figure: the
/// throughput is the settled rate over the whole retained log, and the counts
/// only change when a turn ends. What the pills open is built from the same
/// totals by `SessionTimeCharts` and `SessionTokenCharts`.
struct SessionStatsPresentation: Equatable {
    /// The session's own attempts over the whole retained log: every figure
    /// here rides it, so paging the transcript cannot change a reading.
    var gateway: GatewayTotals
    /// The helper's session clocks: where the wall time went.
    var work: WorkSplit?
    /// The chat's spend against its cost limit. Without one the cost reads
    /// as the request log has it, as it always did.
    var cost: SessionCostReading?

    init(gateway: GatewayTotals, work: WorkSplit?, cost: SessionCostReading? = nil) {
        self.gateway = gateway; self.work = work; self.cost = cost
    }

    /// Distinct turns these requests belong to. A title or suggestion request
    /// carries no turn and is counted as neither a turn nor a step.
    var turns: Int { gateway.turnCount ?? 0 }
    /// One model request is one step.
    var steps: Int { gateway.requests }

    // MARK: The gauge pill

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    var countsLabel: String {
        Self.plural(turns, "turn", "turns") + " " + Self.plural(steps, "step", "steps")
    }
    var throughput: SettledThroughput { gateway.settledThroughput }
    var latency: SettledLatency { gateway.settledLatency }
    /// `2 turns 3 steps · 34 tok/s`, and the counts alone when no request
    /// reported both halves of the rate.
    var gaugeLabel: String {
        [countsLabel, throughput.label].compactMap { $0 }.joined(separator: " · ")
    }
    /// A window with no timed figure has nothing to open; the pill stays a reading.
    var hasTimeDialog: Bool {
        (work?.sessionModelMs ?? 0) > 0 || (work?.sessionToolMs ?? 0) > 0 || latency.samples > 0 || throughput.samples > 0
    }

    // MARK: The usage pill

    var totalTokens: Double? { gateway.billedTotalTokens }
    var cacheHit: String? { gateway.cacheHitPercent }
    /// The total's parts, as the turn's usage dialog lists them: input as
    /// uncached and cached, then output with its reasoning part. Cached input
    /// is part of the input and reasoning part of the output; neither is
    /// added again. `3.2K uncached · 10.1K cached · 2.5K out (1.2K reasoning)`
    ///
    /// The input splits only when every request that reported its input also
    /// reported its cache use (the cache hit's pairs are then all the input);
    /// otherwise the parts would not add up to the total, and it reads `in`.
    var tokenSplit: [String] {
        var parts: [String] = []
        if let t = gateway.tokens, t.inputSamples > 0, let input = TranscriptActivity.reported(t.input) {
            if let split = GatewayTokenSplit.reported(gateway, input: true), split.samples == t.inputSamples, split.total == input {
                parts.append(MetricFormat.tokens(split.total - split.part) + " uncached")
                parts.append(MetricFormat.tokens(split.part) + " cached")
            } else {
                parts.append(MetricFormat.tokens(input) + " in")
            }
        }
        if let t = gateway.tokens, t.outputSamples > 0, let output = TranscriptActivity.reported(t.output) {
            let reasoning = (t.reasoningSamples ?? 0) > 0 ? TranscriptActivity.reported(t.reasoning) : nil
            parts.append(MetricFormat.tokens(output) + " out" + (reasoning.map { " (\(MetricFormat.tokens($0)) reasoning)" } ?? ""))
        }
        return parts
    }
    private func usageParts(split: Bool) -> [String] {
        var parts: [String] = []
        if let total = totalTokens { parts.append(MetricFormat.tokenCount(total)) }
        if split { parts += tokenSplit }
        if let cacheHit { parts.append("Cache hit \(cacheHit)%") }
        return parts
    }
    /// The spend the pill shows: what the chat's helper counted, once it has
    /// counted a reported cost, else the request log's.
    private var spent: Double? {
        let logged = gateway.costSamples > 0 ? gateway.costUSD : nil
        guard let cost, let counted = cost.spentUSD, cost.reportedRequests > 0 || counted > 0 else { return logged }
        return counted
    }
    /// `$0.0025`, or `$4.12 of $5.00` under a cost limit.
    var costFigure: String? {
        guard let cost else { return spent.map(compactGatewayUSD) }
        return cost.figure(spent: spent)
    }
    /// The spend is at 80% of the chat's limit or more.
    var costWarning: Bool { cost?.warning(spent: spent) ?? false }
    /// `15.8K tok · 3.2K uncached · 10.1K cached · 2.5K out (1.2K reasoning) · Cache hit 75.94% · $0.0025`
    var usageLabel: String { (usageParts(split: true) + [costFigure].compactMap { $0 }).joined(separator: " · ") }
    /// What the pill draws: the reading, with the cost apart, in warning
    /// ink, once it nears the limit.
    var usageFace: (label: String, warningTail: String?) { face(split: true) }
    /// The same pill without the token split, for a pane too narrow for it:
    /// `15.8K tok · Cache hit 50.00% · $0.0025`.
    var compactUsageFace: (label: String, warningTail: String?) { face(split: false) }
    private func face(split: Bool) -> (label: String, warningTail: String?) {
        let parts = usageParts(split: split)
        guard costWarning, let figure = costFigure else { return ((parts + [costFigure].compactMap { $0 }).joined(separator: " · "), nil) }
        return (parts.joined(separator: " · "), figure)
    }
    /// A session whose requests all settled without billing keeps its counts
    /// and drops this pill rather than showing an empty one.
    var hasUsage: Bool { !usageLabel.isEmpty }
}

/// The room the context pill keeps for one showing of its chat
/// (`SessionDisplay.presentationGeneration`): the first thing it showed there,
/// and the shape of every figure since, digits as zeros ("00%", "00.00%"),
/// since the pill's digits are all one width. The pill takes the widest of
/// them, so what it says next never needs a row it did not have.
struct ContextPillSlot: Equatable {
    let showing: UUID
    private(set) var labels: [String] = []

    /// The room kept for `showing`: the one held, if it is for this showing,
    /// else an empty one that its first label starts.
    static func of(_ held: ContextPillSlot?, showing: UUID) -> ContextPillSlot {
        held?.showing == showing ? held! : ContextPillSlot(showing: showing)
    }
    /// With `label` shown: the first label starts the room, a figure adds its
    /// shape, and words after the first never widen it.
    func adding(_ label: String, figure: Bool) -> ContextPillSlot {
        let held = figure ? Self.shape(of: label) : label
        guard labels.isEmpty || (figure && !labels.contains(held)) else { return self }
        var slot = self
        slot.labels.append(held)
        return slot
    }
    static func shape(of figure: String) -> String { String(figure.map { $0.isNumber ? "0" : $0 }) }
}
