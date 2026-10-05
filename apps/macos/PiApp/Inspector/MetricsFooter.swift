import SwiftUI

/// Session and last-turn wall-clock split between model inference and tool
/// calls, from the helper's turn metrics. Absent until a turn has run.
struct WorkSplit: Equatable {
    var sessionModelMs: Double
    var sessionToolMs: Double
    var turnModelMs: Double?
    var turnToolMs: Double?
    init?(timing: [String: WireValue]) {
        guard let model = timing["sessionModelMs"]?.number, let tools = timing["sessionToolMs"]?.number,
              DurationObservation.valid(model) != nil, DurationObservation.valid(tools) != nil, model + tools > 0 else { return nil }
        sessionModelMs = model; sessionToolMs = tools
        turnModelMs = DurationObservation.valid(timing["modelMs"]?.number); turnToolMs = DurationObservation.valid(timing["toolMs"]?.number)
    }
    var label: String { "model \(workDuration(sessionModelMs)) · tools \(workDuration(sessionToolMs))" }
    var turn: String? {
        guard let turnModelMs, let turnToolMs, turnModelMs + turnToolMs > 0 else { return nil }
        return "model \(workDuration(turnModelMs)) · tools \(workDuration(turnToolMs))"
    }
    var help: String {
        "Where this session's time went: waiting on the model versus running tools, across every turn."
        + (turn.map { " Last turn: " + $0 + "." } ?? "")
    }
}

/// 0.4s · 12.3s · 1m 12s · 1h 2m, matching the transcript's turn headers.
/// Under a minute the figure is rounded to a tenth, and a rounding that
/// reaches the minute is written as one: 59.96 s is `1m 0s`, never `60.0s`.
/// From a minute up it counts whole seconds and minutes, as a clock does.
func workDuration(_ milliseconds: Double) -> String {
    guard DurationObservation.valid(milliseconds) != nil else { return "n/a" }
    let tenths = (milliseconds / 100).rounded()
    if tenths < 600 { return String(format: "%.1fs", tenths / 10) }
    guard let counted = Int(exactly: (milliseconds / 1_000).rounded(.down)) else { return "n/a" }
    let seconds = max(60, counted), minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

/// An unloaded conversation has not been calculated yet, rather than having
/// unknowable context. Both the ring and inspector use these validated counts.
struct ContextMeterPresentation {
    /// How the helper counts context, as pi does, in plain words.
    static let methodExplanation = "The context ring counts the last reply's reported tokens, plus about 4 characters per token for the messages since. After a compaction it waits for the next reply."
    let context: [String: WireValue]
    var capacity: Double? = nil
    private var counts: (tokens: Double, capacity: Double)? {
        let configuredCapacity = context["scope"]?.string == "current-request" || context["scope"]?.string == "last-request" || context["requestFingerprint"]?.string != nil ? context["contextWindow"]?.number : capacity ?? context["contextWindow"]?.number
        guard let tokens = context["tokens"]?.number, tokens.isFinite, tokens >= 0,
              let maximum = configuredCapacity,
              maximum.isFinite, maximum > 0 else { return nil }
        return (tokens,maximum)
    }
    var estimated: Bool { context["estimated"]?.bool ?? true }
    var methodLabel: String {
        switch context["method"]?.string {
        case "gateway-reported": return "LiteLLM reported"
        case "provider-count": return "Provider count"
        case "tokenizer": return "Gateway tokenizer"
        case "pi-estimate": return "Last reply + ~4 characters per token"
        case "usage-baseline": return "Usage baseline"
        case "heuristic": return "Request heuristic"
        default: return "Count method unavailable"
        }
    }
    var warnings: [String] { context["warnings"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? [] }
    var modelLabel: String? {
        guard let requested = context["requestedModel"]?.string else { return nil }
        guard let counted = context["countedModel"]?.string else { return "Requested \(requested) · counted model unverified" }
        return "Requested \(requested) · counted \(counted)"
    }
    var budgetLabel: String? {
        let fields: [(String, String)] = [("inputBudget", "Input budget"), ("outputBudget", "output reserve"), ("safetyMargin", "safety margin"), ("modelOutputLimit", "model output ceiling"), ("outputCap", "limit sent")]
        let parts = fields.compactMap { key, label -> String? in
            guard let value = context[key]?.number, value.isFinite, value >= 0 else { return nil }
            return label + " " + value.formatted(.number.precision(.fractionLength(0)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// The breakdown the context dialog lists, one named budget per row. These
    /// are the parts the helper actually reports; nothing is inferred.
    var budgetParts: [(name: String, value: String)] {
        let fields: [(String, String)] = [("inputBudget", "Input budget"), ("outputBudget", "Output reserve"), ("safetyMargin", "Safety margin"), ("modelOutputLimit", "Model output ceiling"), ("outputCap", "Limit sent")]
        return fields.compactMap { key, label in
            guard let value = context[key]?.number, value.isFinite, value >= 0 else { return nil }
            return (label, MetricFormat.exactTokens(value))
        }
    }
    /// `~32K / 128K` — the reading the dialog puts beside its title. The tilde
    /// marks an estimate, exactly as the compact label's `≈` does.
    var compactFigures: String {
        guard let counts else { return compactLabel }
        return (estimated ? "~" : "") + MetricFormat.tokens(counts.tokens) + " / " + MetricFormat.tokens(counts.capacity)
    }
    var fraction: Double? { counts.map { $0.tokens / $0.capacity } }
    private var pending: Bool { ["post-compaction", "pending"].contains(context["state"]?.string ?? "") }
    var compactLabel: String {
        guard let counts else { return pending ? (context["scope"] == nil ? "Context pending" : context["source"]?.string ?? "Context pending") : "Inspect context" }
        let scopeLabel=context["scope"]?.string == "next-input" ? " · next input" : context["scope"]?.string == "last-request" ? " · last request" : context["scope"]?.string == "legacy" ? " · legacy estimate" : ""
        return (estimated ? "≈" : "") + "\(compact(counts.tokens)) / \(compact(counts.capacity))" + (context["method"]?.string == "gateway-reported" ? " · reported" : context["awaitingUsage"]?.bool == true ? " · awaiting usage" : "") + scopeLabel
    }
    var fullLabel: String {
        guard let counts else { return compactLabel }
        return (estimated ? "≈" : "") + "\(counts.tokens.formatted(.number.precision(.fractionLength(0)))) / \(counts.capacity.formatted(.number.precision(.fractionLength(0))))"
    }
    var detailLabel: String {
        guard let counts else { return pending ? (context["source"]?.string ?? "Context is waiting for the next prepared-request calculation") : "Click to calculate and inspect context; no response is generated" }
        let source = context["source"]?.string ?? "Estimated conversation context"
        let scope=context["scope"]?.string == "last-request" ? " · last request" : context["scope"]?.string == "next-input" ? " · next input" : ""
        let preparation = context["preparation"]?.string.map { " · " + $0 } ?? ""
        let warning = warnings.isEmpty ? "" : " · " + warnings.joined(separator: " ")
        // The ring's own honest rounding, one decimal finer: 99.96% is never
        // "100.0%". A count past the window (the ring stops at full) keeps
        // its figure, so the detail still says by how much.
        let ratio = counts.tokens / counts.capacity
        let percent = ratio > 1 ? String(format: "%.1f", ratio * 100) : MetricFormat.occupancyPercent(ratio, decimals: 1) ?? "—"
        // Pi's source already says how it was counted, in plain words.
        let method = context["method"]?.string == "pi-estimate" ? "" : " · " + methodLabel
        return fullLabel + " configured · \(percent)%\(method) · \(source)" + scope + preparation + warning
    }
    /// Each unit starts where the one below would round up to a thousand of
    /// itself: 999,600 tokens is "1M", never "1000K".
    private func compact(_ value: Double) -> String {
        if value >= 999_500 { return String(format:"%.1fM",value / 1_000_000).replacingOccurrences(of:".0M",with:"M") }
        if value >= 10_000 { return String(format:"%.0fK",value / 1000) }
        if value >= 999.5 { return String(format:"%.1fK",value / 1000).replacingOccurrences(of:".0K",with:"K") }
        return String(format:"%.0f",value)
    }
}

struct ContextRing: View {
    let fraction: Double?
    /// 23 pt in the inspector's header; 14 pt as a pill's glyph.
    var size: CGFloat = 23
    private var bounded: Double { min(1, max(0, fraction.map { $0.isFinite ? $0 : 0 } ?? 0)) }
    private var tint: Color { bounded >= 0.95 ? .piDanger : bounded >= 0.8 ? .piWarning : .piAccent }
    private var stroke: CGFloat { size < 18 ? 2 : 2.5 }
    var body: some View {
        ZStack {
            Circle().stroke(Color.piHairlineStrong, lineWidth: stroke)
            Circle().trim(from: 0, to: bounded).stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round)).rotationEffect(.degrees(-90))
                .piAnimation(PiMotion.base, value: bounded)
            // The glyph only fits at the inspector's size; the pill's ring is
            // the reading, and its percentage is right beside it.
            if size >= 18 { Image(systemName: "square.stack.3d.up").font(.system(size: 9, weight: .medium)).foregroundStyle(tint) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Reasoning is a reported subset of output. Coverage belongs to the component,
/// so an absent value never becomes a zero or implies every request reported it.
func reasoningUsageSummary(_ totals: GatewayTotals) -> String {
    let tokenSamples = totals.tokens?.reasoningSamples ?? 0
    let costSamples = totals.reasoningCostSamples ?? 0
    return "Reasoning \(menuBarTokens(totals.tokens?.reasoning)) tokens (\(tokenSamples)/\(totals.requests) reported) · \(gatewayUSD(totals.reasoningCostUSD)) (\(costSamples)/\(totals.requests) reported) · included in output"
}

/// The room the capture badge keeps for one showing of its chat
/// (`SessionDisplay.presentationGeneration`): what it said first there. The
/// footer is kept across chats, so the room is keyed by the chat too.
struct FooterBadgeRoom: Equatable {
    let chat: ObjectIdentifier
    let showing: UUID
    let text: String
    /// The room held for this chat and showing, or a new one that what the
    /// badge says now starts.
    static func of(_ held: FooterBadgeRoom?, chat: ObjectIdentifier, showing: UUID, text: String) -> FooterBadgeRoom {
        if let held, held.chat == chat, held.showing == showing { return held }
        return FooterBadgeRoom(chat: chat, showing: showing, text: text)
    }
}
