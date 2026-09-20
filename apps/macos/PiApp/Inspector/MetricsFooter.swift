import SwiftUI

/// Compact session status bar. Narrow panes keep timing on a second line so
/// the latest and average output rates remain visible together.
struct MetricsFooter: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    let selectedContextWindow: Int?
    let selectedOutputReserve: Int?
    /// A side conversation shares the window with the chat it was opened from,
    /// and its own status bar repeated every figure of that chat's. The
    /// compact form keeps what belongs to this conversation alone: how much
    /// context it holds and what it has cost.
    let compact: Bool
    let inspect: () -> Void
    @State private var expanded = false
    @State private var showContext = false
    init(model: WorkspaceModel, session: SessionDisplay, contextWindow: Int? = nil, outputReserve: Int? = nil,
         compact: Bool = false, inspect: @escaping () -> Void) {
        self.model = model; self.session = session; self.footer = session.footer; self.selectedContextWindow = contextWindow
        self.selectedOutputReserve = outputReserve; self.compact = compact; self.inspect = inspect
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wide: one row. Narrower: the timing on a second row. Narrower still: the
            // timing without the work split, then the bar alone; Session info keeps every figure.
            Group {
                if compact { compactBar } else {
                    ViewThatFits(in: .horizontal) {
                        bar(full: true)
                        VStack(alignment: .leading, spacing: PiSpacing.xs) {
                            bar(full: false)
                            timingLine
                        }
                        VStack(alignment: .leading, spacing: PiSpacing.xs) {
                            bar(full: false)
                            timing
                        }
                        bar(full: false)
                    }
                }
            }
            .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            .padding(.horizontal, PiSpacing.lg).padding(.top, 2).padding(.bottom, 6)
            if expanded && !compact { details.transition(AnyTransition.move(edge: .bottom).combined(with: .opacity)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showContext) { ContextInspector(model: model, session: session) }
        .task(id: model.automaticContextActivation(session)) { model.scheduleAutomaticContext(session.id) }
        .onDisappear { model.cancelAutomaticContext(session.id) }
        .help(SessionRatePresentation.explanation + " The context ring uses the helper's matching request count; inspect it for its method, model and uncertainty.")
    }

    /// The two figures a side conversation owns, and — when there is one —
    /// the one line that tells the reader what to do next.
    private var compactBar: some View {
        HStack(spacing: PiSpacing.md) {
            contextControl
            dot
            costControl
            Spacer(minLength: PiSpacing.sm)
            if !session.notice.isEmpty { noticeLine }
        }.accessibilityIdentifier("compactMetricsFooter")
    }
    private var contextControl: some View {
        Button { showContext = true } label: {
            HStack(spacing: 7) {
                ContextRing(fraction: contextFraction)
                Text(compactContext).lineLimit(1).monospacedDigit().fixedSize().contentTransition(.numericText()).piAnimation(PiMotion.base, value: compactContext)
            }
        }.buttonStyle(.plain).piPointer().help(contextLabel + ". Explore instructions, messages, tool results, provider state and the prepared request.")
            .accessibilityLabel("Explore context").accessibilityValue(contextLabel)
    }
    @ViewBuilder private var costControl: some View {
        if let chat = model.record(session.id) {
            SessionUsageButton(model: model, chat: chat, footer: footer, costLabel: compactCost)
        } else {
            stat("dollarsign.circle", compactCost, help: footer.gateway.costLabel)
        }
    }
    // A notice is the one line here that tells the reader what to do next
    // ("Run cancelled. Pending messages are paused; resume below"). Capped at
    // 300 points it was cut mid-word on every pane width, so the instruction
    // never arrived. It now takes whatever the bar has left, and the whole
    // text is selectable in Session info and in the help.
    private var noticeLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 10.5))
            Text(session.notice).lineLimit(1).truncationMode(.tail).layoutPriority(1)
        }.frame(maxWidth: 640, alignment: .trailing).help(session.notice)
            .accessibilityLabel(session.notice)
    }
    private func bar(full: Bool) -> some View {
        HStack(spacing: PiSpacing.md) {
            contextControl
            if full {
                dot
                timingLine
            }
            dot
            costControl
            Spacer(minLength: PiSpacing.sm)
            if full && !session.notice.isEmpty { noticeLine }
            Button(action: inspect) {
                PiBadge(text: full ? (session.captureAvailable ? "" : "Next: ") + captureTitle : "", tone: captureTone, icon: session.captureAvailable ? "record.circle.fill" : "record.circle")
            }.buttonStyle(.plain).piPointer().help("Capture: " + captureTitle + ". Bounded HTTP-body capture; the inspector shows coverage and retained traces")
            PiIconButton(symbol: "chevron.up", label: expanded ? "Hide details" : "Show details", size: 22) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { expanded.toggle() }
            }.rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }
    private var timing: some View { SessionTimingControls(footer: footer, sessionTitle: model.record(session.id)?.title ?? "This session") }
    /// Request timing plus where the session's wall-clock went: model inference versus tool calls.
    private var timingLine: some View {
        HStack(spacing: PiSpacing.md) {
            timing
            if let split = workSplit {
                dot
                stat("timer", split.label, help: split.help).accessibilityLabel("Session time split").accessibilityValue(split.label).accessibilityIdentifier("session-work-split")
            }
        }
    }
    private var workSplit: WorkSplit? { WorkSplit(timing: footer.turnTiming) }
    private var captureTitle: String { session.captureMode == "off" ? "Capture off" : session.captureMode == "persist" ? "Persist locally" : "Session memory" }
    private var captureTone: PiTone { session.captureMode == "memory" ? .info : .neutral }
    private var dot: some View { Circle().fill(Color.piHairlineStrong).frame(width: 3, height: 3) }
    private func stat(_ symbol: String, _ text: String, help: String) -> some View {
        Button(action: inspect) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Color.piInkTertiary)
                // Figures roll to their new value rather than swapping.
                Text(text).lineLimit(1).monospacedDigit().fixedSize().contentTransition(.numericText()).piAnimation(PiMotion.base, value: text)
            }
        }.buttonStyle(.plain).piPointer().help(help)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.lg) {
                detailColumn("Context", contextLabel)
                detailColumn("Model", (footer.metrics["requestedModel"]?.string).map { "\($0) → \(reportedModel)" } ?? "No request yet")
                detailColumn("Timing", "First text \(milliseconds(metrics["firstTextMs"])) · " + reserveLabel)
            }
            HStack(spacing: PiSpacing.lg) {
                detailColumn("Cost", footer.gateway.costLabel)
                detailColumn("Response cache", footer.gateway.cacheLabel + (footer.gateway.expiredRecords > 0 ? " · \(footer.gateway.expiredRecords) expired records excluded" : ""))
                DraftEstimate(draft: session.composerDraft, skills: session.skills)
            }
            Text("Gateway-reported usage · " + footer.gateway.tokenCacheLabel).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            Text(reasoningUsageSummary(footer.gateway)).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !footer.gatewayNotice.isEmpty { PiNote(footer.gatewayNotice) }
            Text(SessionRatePresentation.explanation + " Draft and skill estimates are chars/4, exclude wrappers and images, and are not the context count.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
        }
        .padding(PiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piSurfaceSunken, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .padding(.horizontal, PiSpacing.lg).padding(.bottom, PiSpacing.sm)
    }
    private func detailColumn(_ title: String, _ value: String) -> some View {
        Button(action: inspect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
                Text(value).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(2).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).piPointer()
    }

    private var reportedModel: String {
        let identity = footer.metrics["identity"]?.object ?? [:]
        if let model = identity["effectiveModel"]?.string { return model }
        let names = identity["reportedModels"]?.array?.compactMap(\.string) ?? []
        if identity["status"]?.string == "conflict", let primary = dashboardPrimaryModel(names) { return primary + " · \(names.count) names" }
        return identity["status"]?.string ?? "unreported"
    }
    private var metrics: [String: WireValue] { footer.metrics["metrics"]?.object ?? [:] }
    private var reserveLabel: String {
        let reserve = displayedContext["outputBudget"]?.number ?? (session.hasWork ? displayedContext["outputReserve"]?.number : selectedOutputReserve.map(Double.init) ?? displayedContext["outputReserve"]?.number)
        let margin = displayedContext["safetyMargin"]?.number.map { " + \(grouped($0)) safety" } ?? ""
        let budget = reserve.map { "output budget \(grouped($0))" + margin } ?? "output budget unavailable"
        let elapsed: String = footer.turnTiming["elapsedMs"]?.number.map { " · turn " + workDuration($0) } ?? ""
        let split: String = workSplit?.turn.map { " (" + $0 + ")" } ?? ""
        return budget + elapsed + split
    }
    private var compactCost: String {
        guard let value = footer.gateway.costUSD, value.isFinite, value >= 0 else { return "cost n/a" }
        if value == 0 { return "$0" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
    private var displayedContext: [String: WireValue] { model.displayedContext(session) }
    private var contextMeter: ContextMeterPresentation {
        ContextMeterPresentation(context:displayedContext,capacity:session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }
    private var contextFraction: Double? { contextMeter.fraction }
    private var compactContext: String { contextMeter.fraction == nil && footer.preparingContext ? "Calculating context…" : contextMeter.compactLabel }
    private var contextLabel: String { contextMeter.detailLabel }
    private func grouped(_ value: Double) -> String { TranscriptActivity.grouped(value) }
    private func milliseconds(_ value: WireValue?) -> String { value?.number.map { String(format: "%.0f ms", $0) } ?? "n/a" }
}

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
func workDuration(_ milliseconds: Double) -> String {
    guard DurationObservation.valid(milliseconds) != nil else { return "n/a" }
    let seconds = milliseconds / 1000
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds / 60), rest = Int(seconds) % 60
    if minutes < 60 { return "\(minutes)m \(rest)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

/// An unloaded conversation has not been calculated yet, rather than having
/// unknowable context. Both the ring and inspector use these validated counts.
struct ContextMeterPresentation {
    let context: [String: WireValue]
    var capacity: Double? = nil
    private var counts: (tokens: Double, capacity: Double)? {
        let configuredCapacity = context["requestFingerprint"]?.string == nil ? capacity ?? context["contextWindow"]?.number : context["contextWindow"]?.number
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
    var fraction: Double? { counts.map { $0.tokens / $0.capacity } }
    private var pending: Bool { ["post-compaction", "pending"].contains(context["state"]?.string ?? "") }
    var compactLabel: String {
        guard let counts else { return pending ? "Context pending" : "Inspect context" }
        return (estimated ? "≈" : "") + "\(compact(counts.tokens)) / \(compact(counts.capacity))" + (context["method"]?.string == "gateway-reported" ? " · reported" : context["awaitingUsage"]?.bool == true ? " · awaiting usage" : "")
    }
    var fullLabel: String {
        guard let counts else { return compactLabel }
        return (estimated ? "≈" : "") + "\(counts.tokens.formatted(.number.precision(.fractionLength(0)))) / \(counts.capacity.formatted(.number.precision(.fractionLength(0))))"
    }
    var detailLabel: String {
        guard let counts else { return pending ? "Context is waiting for the next prepared-request calculation" : "Click to calculate and inspect context; no response is generated" }
        let source = context["source"]?.string ?? "Estimated conversation context"
        let preparation = context["preparation"]?.string.map { " · " + $0 } ?? ""
        let warning = warnings.isEmpty ? "" : " · " + warnings.joined(separator: " ")
        return fullLabel + String(format:" configured · %.1f%% · %@ · %@",counts.tokens / counts.capacity * 100,methodLabel,source) + preparation + warning
    }
    private func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format:"%.1fM",value / 1_000_000).replacingOccurrences(of:".0M",with:"M") }
        if value >= 10_000 { return String(format:"%.0fk",value / 1000) }
        if value >= 1_000 { return String(format:"%.1fk",value / 1000).replacingOccurrences(of:".0k",with:"k") }
        return String(format:"%.0f",value)
    }
}

struct ContextRing: View {
    let fraction: Double?
    private var bounded: Double { min(1, max(0, fraction.map { $0.isFinite ? $0 : 0 } ?? 0)) }
    private var tint: Color { bounded >= 0.95 ? .piDanger : bounded >= 0.8 ? .piWarning : .piAccent }
    var body: some View {
        ZStack {
            Circle().stroke(Color.piHairlineStrong, lineWidth: 2.5)
            Circle().trim(from: 0, to: bounded).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: "square.stack.3d.up").font(.system(size: 9, weight: .medium)).foregroundStyle(tint)
        }.frame(width: 23, height: 23).accessibilityHidden(true)
    }
}

/// Reasoning is a reported subset of output. Coverage belongs to the component,
/// so an absent value never becomes a zero or implies every request reported it.
func reasoningUsageSummary(_ totals: GatewayTotals) -> String {
    let tokenSamples = totals.tokens?.reasoningSamples ?? 0
    let costSamples = totals.reasoningCostSamples ?? 0
    return "Reasoning \(menuBarTokens(totals.tokens?.reasoning)) tokens (\(tokenSamples)/\(totals.requests) reported) · \(gatewayUSD(totals.reasoningCostUSD)) (\(costSamples)/\(totals.requests) reported) · included in output"
}

private struct DraftEstimate: View {
    @ObservedObject var draft: ComposerDraft
    let skills: [SkillChip]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Draft").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            Text("≈\(max(0, (draft.text as NSString).length / 4))" + skillEstimate + " tokens (chars/4)").font(PiFont.caption).foregroundStyle(Color.piInk)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var skillEstimate: String {
        guard !skills.isEmpty else { return "" }
        guard skills.allSatisfy({ $0.sourceCharacters != nil }) else { return " · selected skills unavailable" }
        var characters = 0
        for skill in skills {
            guard let count = skill.sourceCharacters, count >= 0 else { return " · selected skills unavailable" }
            let (subtotal, overflow) = characters.addingReportingOverflow(count)
            let (total, argumentsOverflow) = subtotal.addingReportingOverflow((skill.arguments as NSString).length)
            guard !overflow, !argumentsOverflow else { return " · selected skills unavailable" }
            characters = total
        }
        return " + skills ≈\(characters / 4)"
    }
}
