import SwiftUI

/// What the composer sits on: the session's three readings as pills, and —
/// only while a run is going — the elapsed clock and the action under way.
/// Every figure is settled; nothing here ticks with a stream.
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
            // Wide: the pills, the run line and the capture badge on one row.
            // Narrower: the run line drops to its own row under the pills.
            Group {
                if compact { compactBar } else {
                    ViewThatFits(in: .horizontal) {
                        bar(full: true)
                        // The last form still carries the run line, on its own
                        // row: a narrow pane may drop the notice, never the
                        // clock and the action.
                        VStack(alignment: .leading, spacing: PiSpacing.xs) {
                            bar(full: false)
                            runLine
                        }
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
        .sheet(isPresented: $showContext) { [weak model, weak session] in
            if let model, let session { ContextInspector(model: model, session: session) }
        }
        .task(id: model.automaticContextActivation(session)) { [weak model, id = session.id] in model?.scheduleAutomaticContext(id) }
        .onDisappear { [weak model, id = session.id] in model?.cancelAutomaticContext(id) }
        .help(SettledThroughput.explanation + " The context ring uses the helper's matching request count; inspect it for its method, model and uncertainty.")
    }

    /// The figures a side conversation owns, and — when there is one — the one
    /// line that tells the reader what to do next.
    private var compactBar: some View {
        HStack(spacing: PiSpacing.md) {
            pills(compact: true).frame(maxWidth: .infinity, alignment: .leading)
            if !session.notice.isEmpty { noticeLine }
        }.accessibilityIdentifier("compactMetricsFooter")
    }
    /// What the composer sits on: how much work this conversation did and how
    /// fast, what it consumed, and how full the window is. The figures the
    /// footer used to spell out live here, each behind its own small dialog.
    private func pills(compact: Bool) -> some View {
        SessionStatsPills(model: model, session: session, footer: footer,
                          selectedContextWindow: selectedContextWindow, compact: compact,
                          exploreContext: { showContext = true }, openLedger: openLedger)
    }
    private func openLedger() {
        guard let chat = model.record(session.id) else { return }
        SessionUsageWindows.shared.show(model: model, chat: chat, footer: footer, initialBreakdown: .requests)
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
        let disclosure = $expanded
        return HStack(spacing: PiSpacing.md) {
            pills(compact: false).frame(maxWidth: .infinity, alignment: .leading)
            // The clock and the action get their room first; the pills wrap
            // into whatever is left rather than pushing them off the bar.
            if full { runLine.fixedSize().layoutPriority(2) }
            if full && !session.notice.isEmpty { noticeLine.layoutPriority(2) }
            Button(action: inspect) {
                PiBadge(text: full ? (session.captureAvailable ? "" : "Next: ") + captureTitle : "", tone: captureTone, icon: session.captureAvailable ? "record.circle.fill" : "record.circle")
            }.buttonStyle(.plain).piPointer().help("Capture: " + captureTitle + ". Bounded HTTP-body capture; the inspector shows coverage and retained traces")
            PiIconButton(symbol: "chevron.up", label: expanded ? "Hide details" : "Show details", size: 22) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { disclosure.wrappedValue.toggle() }
            }.rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }
    /// While a run is going: the elapsed clock and the action under way, and
    /// nothing else. The rate that used to tick here was a live figure — it
    /// moved on every delta and said nothing the settled rate does not say
    /// better once the request is done.
    @ViewBuilder private var runLine: some View {
        if session.busy { SessionRunLine(session: session, footer: footer) }
    }
    private var workSplit: WorkSplit? { WorkSplit(timing: footer.turnTiming) }
    private var captureTitle: String { session.captureMode == "off" ? "Capture off" : session.captureMode == "persist" ? "Persist locally" : "Session memory" }
    private var captureTone: PiTone { session.captureMode == "memory" ? .info : .neutral }

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
            Text(SettledThroughput.explanation + " Draft and skill estimates are chars/4, exclude wrappers and images, and are not the context count.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
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
    private var displayedContext: [String: WireValue] { model.displayedContext(session) }
    private var contextMeter: ContextMeterPresentation {
        ContextMeterPresentation(context:displayedContext,capacity:session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }
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
        return fullLabel + " configured · \(percent)% · \(methodLabel) · \(source)" + scope + preparation + warning
    }
    /// Each unit starts where the one below would round up to a thousand of
    /// itself: 999,600 tokens is "1M", never "1000k".
    private func compact(_ value: Double) -> String {
        if value >= 999_500 { return String(format:"%.1fM",value / 1_000_000).replacingOccurrences(of:".0M",with:"M") }
        if value >= 10_000 { return String(format:"%.0fk",value / 1000) }
        if value >= 999.5 { return String(format:"%.1fk",value / 1000).replacingOccurrences(of:".0k",with:"k") }
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

/// The only figures the footer shows while a request is in flight: how long
/// the turn has been going, and what it is doing. Both come from the helper's
/// own snapshot, so neither is measured from a stream in the view.
struct SessionRunLine: View {
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics

    /// "Running bash…", "Compacting context…", "Stopping…".
    var action: String {
        if session.state == "stopping" { return "Stopping…" }
        if let progress = session.compactionProgress, !progress.isEmpty { return progress + "…" }
        if session.state == "compacting" { return "Compacting context…" }
        let tools = session.activity["toolNames"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        switch session.activity["phase"]?.string ?? session.state {
        case "queued", "preparing": return "Preparing response…"
        case "retrying": return "Waiting to retry…"
        case "tools": return "Running " + (tools.first ?? "tools") + "…"
        case "model": return "Generating response…"
        default: return tools.isEmpty ? "Working…" : "Running " + tools.joined(separator: ", ") + "…"
        }
    }
    /// Elapsed since the helper says the turn began. `startedAt` is a
    /// machine-uptime stamp from the helper process, not a calendar instant, so
    /// it is only ever compared with this process's own uptime — both read the
    /// same clock. A snapshot's own `elapsedMs` is the floor, so a late
    /// snapshot can never make the clock run backwards, and a turn with no
    /// start stamp shows the action alone rather than a clock from zero.
    static func elapsed(_ timing: [String: WireValue], atUptimeMs now: Double) -> String? {
        let reported = DurationObservation.valid(timing["elapsedMs"]?.number)
        if let end = timing["endedAt"]?.number {
            let measured = timing["startedAt"]?.number.flatMap { DurationObservation.valid(end - $0) }
            return (reported ?? measured).map(MetricFormat.runDuration)
        }
        guard let started = timing["startedAt"]?.number, started.isFinite, started >= 0,
              let measured = DurationObservation.valid(now - started) else {
            return reported.map(MetricFormat.runDuration)
        }
        return MetricFormat.runDuration(max(reported ?? 0, measured))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                if let elapsed = Self.elapsed(footer.turnTiming, atUptimeMs: ProcessInfo.processInfo.systemUptime * 1_000) {
                    Text(elapsed).monospacedDigit().lineLimit(1).fixedSize()
                        .frame(minWidth: 34, alignment: .leading)
                }
                Text(action).lineLimit(1).truncationMode(.tail)
            }
            .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }
        .help("The turn under way: elapsed time and the current action")
        .accessibilityIdentifier("session-run-line")
        .accessibilityLabel(action)
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
