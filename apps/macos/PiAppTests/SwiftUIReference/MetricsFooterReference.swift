import AppKit
import SwiftUI
@testable import PiApp

// Frozen SwiftUI footer from e97ec9e5, retained only for visual parity.

struct MetricsFooterReference: View {
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
    /// Opens the Session Inspector's Overview.
    let inspect: () -> Void
    /// The room the capture badge keeps for this showing of the chat
    /// (`FooterBadgeRoom`).
    @State private var badgeRoom: FooterBadgeRoom?
    init(model: WorkspaceModel, session: SessionDisplay, contextWindow: Int? = nil, outputReserve: Int? = nil,
         compact: Bool = false, inspect: @escaping () -> Void) {
        self.model = model; self.session = session; self.footer = session.footer; self.selectedContextWindow = contextWindow
        self.selectedOutputReserve = outputReserve; self.compact = compact; self.inspect = inspect
    }
    var body: some View {
        // The badge's room is worked out before either form is tried, with
        // what it says now already in it; a showing's first frame is right.
        let room = FooterBadgeRoom.of(badgeRoom, chat: ObjectIdentifier(footer), showing: session.presentationGeneration, text: badgeText)
        VStack(alignment: .leading, spacing: 0) {
            // Wide: the pills, the run line and the capture badge on one row.
            // Narrower: the run line drops to its own row under the pills.
            Group {
                if compact { compactBar } else {
                    ViewThatFits(in: .horizontal) {
                        bar(full: true, room: room)
                        // The last form still carries the run line, on its own
                        // row: a narrow pane may drop the notice, never the
                        // clock and the action.
                        VStack(alignment: .leading, spacing: PiSpacing.xs) {
                            bar(full: false, room: room)
                            runLine
                        }
                    }
                }
            }
            .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            .padding(.horizontal, PiSpacing.lg).padding(.top, 2).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .task(id: model.automaticContextActivation(session)) { [weak model, id = session.id] in model?.scheduleAutomaticContext(id) }
        .onDisappear { [weak model, id = session.id] in model?.cancelAutomaticContext(id) }
        .help(SettledThroughput.explanation + " " + ContextMeterPresentation.methodExplanation)
        .onChange(of: room, initial: true) { _, room in
            // A room for a showing that has since ended is not kept.
            if room.showing == session.presentationGeneration, badgeRoom != room { badgeRoom = room }
        }
    }

    /// The figures a side conversation owns, and — when there is one — the one
    /// line that tells the reader what to do next.
    private var compactBar: some View {
        FooterRowLayoutReference(spacing: PiSpacing.md) {
            pills(compact: true).layoutValue(key: FooterRowRoleReference.self, value: .pills)
            if !session.notice.isEmpty { noticeLine.layoutValue(key: FooterRowRoleReference.self, value: .notice) }
        }.accessibilityIdentifier("compactMetricsFooter")
    }
    /// What the composer sits on: how much work this conversation did and how
    /// fast, what it consumed, and how full the window is. Each pill opens the
    /// Session Inspector where its figure is explained.
    private func pills(compact: Bool) -> some View {
        SessionStatsPillsReference(session: session, footer: footer, context: model.displayedContext(session),
                          selectedContextWindow: selectedContextWindow, compact: compact,
                          open: { [weak model, id = session.id] focus in model?.openInspector(session: id, focus: focus) })
            .equatable()
    }
    // A notice is the one line here that tells the reader what to do next
    // ("Run cancelled. Pending messages are paused; resume below"). Capped at
    // 300 points it was cut mid-word on every pane width, so the instruction
    // never arrived. It takes whatever the row leaves free beside the pills
    // (`FooterRowLayoutReference`), up to 640 points, and the whole text is in the
    // help. It never takes room from the pills: a notice coming or going
    // (an idle helper's "Host runtime unloaded") moved the conversation.
    private var noticeLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 10.5))
            Text(session.notice).lineLimit(1).truncationMode(.tail).layoutPriority(1)
        }.frame(maxWidth: 640, alignment: .trailing).clipped().help(session.notice)
            .accessibilityLabel(session.notice)
    }
    /// What the badge says in the full form: "Next: " while capture waits for
    /// the chat's helper.
    private var badgeText: String { (session.captureAvailable ? "" : "Next: ") + captureTitle }
    private func bar(full: Bool, room: FooterBadgeRoom) -> some View {
        FooterRowLayoutReference(spacing: PiSpacing.md) {
            pills(compact: false).layoutValue(key: FooterRowRoleReference.self, value: .pills)
            // The clock and the action get their room first; the pills wrap
            // into whatever is left rather than pushing them off the bar. The
            // room is one fixed slot: sized by its text, the line widened and
            // narrowed with each phase ("Generating response…", "Running
            // bash…") and clock step, and the footer switched between one row
            // and two in the middle of a run.
            if full, session.busy {
                SessionRunLineReference(session: session, footer: footer)
                    .frame(width: Self.runSlot, alignment: .leading).layoutValue(key: FooterRowRoleReference.self, value: .run)
            }
            if full && !session.notice.isEmpty { noticeLine.layoutValue(key: FooterRowRoleReference.self, value: .notice) }
            badge(full ? badgeText : "", room: full ? room.text : "").layoutValue(key: FooterRowRoleReference.self, value: .badge)
        }
    }
    /// The capture badge in the room kept for it this showing: a longer text
    /// ("Next: " when an idle helper leaves) is cut to it, a shorter one keeps
    /// it. The room lies before the badge, outside its capsule and its AppKit
    /// press target, which hug what it says.
    private func badge(_ text: String, room: String) -> some View {
        let icon = session.captureAvailable ? "record.circle.fill" : "record.circle"
        return PiBadge(text: room, tone: captureTone, icon: icon).hidden()
            .overlay(alignment: .trailing) {
                PiBadge(text: text, tone: captureTone, icon: icon)
                    .accessibilityElement(children: .ignore).accessibilityHidden(true)
                    .overlay {
                        PiPopoverTrigger(label: "Capture: " + captureTitle + ". Open the Session Inspector", identifier: "capture-badge",
                                         help: "Capture: " + captureTitle + ". Open the Session Inspector: every request, its bodies and the capture settings",
                                         onHover: { _ in }, onPress: { [inspect] _ in inspect() })
                    }
            }
    }
    /// While a run is going: the elapsed clock and the action under way, and
    /// nothing else. The rate that used to tick here was a live figure — it
    /// moved on every delta and said nothing the settled rate does not say
    /// better once the request is done.
    @ViewBuilder private var runLine: some View {
        if session.busy { SessionRunLineReference(session: session, footer: footer) }
    }
    private var captureTitle: String { session.captureMode == "off" ? "Capture off" : session.captureMode == "persist" ? "Persist locally" : "Session memory" }
    /// The one-row form's room for the run line: the clock's template and a
    /// phase such as "Generating response…". A longer action ends in "…" and
    /// is whole in the line's help; on its own row it takes the full width.
    static let runSlot: CGFloat = 220
    private var captureTone: PiTone { session.captureMode == "memory" ? .info : .neutral }
}

/// Session and last-turn wall-clock split between model inference and tool
/// calls, from the helper's turn metrics. Absent until a turn has run.

struct SessionRunLineReference: View {
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

    /// Where the run clock's one-second ticks are laid from: half a second
    /// past the turn's start, to the hundredth, so every update of this line
    /// names the same schedule and each tick falls mid-second. A schedule
    /// from `.now` restarted with every update, and the seconds shown stepped
    /// unevenly (12s, 12s, 14s). Without a start stamp, the current instant.
    static func clockOrigin(_ timing: [String: WireValue], atUptimeMs now: Double, date: Date) -> Date {
        guard let started = timing["startedAt"]?.number, started.isFinite, started >= 0, started <= now else { return date }
        let origin = date.timeIntervalSinceReferenceDate - (now - started) / 1_000 + 0.5
        return Date(timeIntervalSinceReferenceDate: (origin * 100).rounded() / 100)
    }

    var body: some View {
        TimelineView(.periodic(from: Self.clockOrigin(footer.turnTiming, atUptimeMs: ProcessInfo.processInfo.systemUptime * 1_000, date: Date()), by: 1)) { _ in
            HStack(spacing: 6) {
                if let elapsed = Self.elapsed(footer.turnTiming, atUptimeMs: ProcessInfo.processInfo.systemUptime * 1_000) {
                    // As wide as "00m 00s" from the first second on, so no
                    // clock step (9s → 10s → 1m 00s) moves what follows it.
                    ZStack(alignment: .leading) {
                        Text("00m 00s").hidden()
                        Text(elapsed)
                    }.monospacedDigit().lineLimit(1).fixedSize()
                }
                Text(action).lineLimit(1).truncationMode(.tail)
            }
            .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }
        .help("The turn under way: " + action)
        .accessibilityIdentifier("session-run-line")
        .accessibilityLabel(action)
    }
}


/// What each part of the footer's row is to `FooterRowLayoutReference`.
enum FooterRowRoleReference: LayoutValueKey {
    static let defaultValue = FooterRowRoleReference.pills
    case pills, run, notice, badge
}

/// The footer's row: the pills from the leading edge; at the trailing edge
/// the capture badge and, while a run goes, the run slot before it; and the
/// notice in what the pills leave free before those, right against them. It
/// is cut with "…" to that room, and not shown where that is too little to
/// read. So a notice coming or going never wraps the pills, never moves the
/// clock or the badge, and never changes which form the footer takes, since
/// the row's own width leaves it out.
struct FooterRowLayoutReference: Layout {
    var spacing: CGFloat
    /// Narrower than this, a notice is not shown: its help still has it.
    static let noticeLeast: CGFloat = 48

    private struct Parts {
        var pills: LayoutSubview?, run: LayoutSubview?, notice: LayoutSubview?, badge: LayoutSubview?
        init(_ subviews: LayoutSubviews) {
            for subview in subviews {
                switch subview[FooterRowRoleReference.self] {
                case .pills: pills = subview
                case .run: run = subview
                case .notice: notice = subview
                case .badge: badge = subview
                }
            }
        }
        /// The run slot's and the badge's width, and the gaps before them.
        func trailing(_ spacing: CGFloat) -> CGFloat {
            [run, badge].compactMap { $0 }.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        }
        var trailingHeight: CGFloat { [run, badge].compactMap { $0?.sizeThatFits(.unspecified).height }.max() ?? 0 }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let parts = Parts(subviews), trailing = parts.trailing(spacing)
        guard let width = proposal.width, width.isFinite else {
            let pills = parts.pills?.sizeThatFits(.unspecified) ?? .zero
            return CGSize(width: pills.width + trailing, height: max(pills.height, parts.trailingHeight))
        }
        let pills = parts.pills?.sizeThatFits(ProposedViewSize(width: max(0, width - trailing), height: nil)) ?? .zero
        return CGSize(width: width, height: max(pills.height, parts.trailingHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = Parts(subviews), trailing = parts.trailing(spacing)
        let pills = parts.pills?.sizeThatFits(ProposedViewSize(width: max(0, bounds.width - trailing), height: nil)) ?? .zero
        parts.pills?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(pills))
        // From the trailing edge: the badge, the run slot, then the notice,
        // so neither of the first two ever moves for the third.
        var x = bounds.maxX
        for part in [parts.badge, parts.run].compactMap({ $0 }) {
            let size = part.sizeThatFits(.unspecified)
            x -= size.width
            part.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x -= spacing
        }
        if let notice = parts.notice {
            let free = x - (bounds.minX + pills.width + spacing)
            let ideal = notice.sizeThatFits(.unspecified)
            let width = free >= Self.noticeLeast ? min(ideal.width, free) : 0
            notice.place(at: CGPoint(x: x - width, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: ideal.height))
        }
    }
}

struct SessionStatsPillsReference: View, Equatable {
    @ObservedObject var session: SessionDisplay
    @ObservedObject var footer: SessionMetrics
    /// The context the ring reads (`WorkspaceModel.displayedContext`), worked
    /// out by the footer that holds the pills. The pills do not observe the
    /// whole workspace for this one reading: every change to it laid the
    /// pills out again, twice, for the two forms the footer tries.
    let context: [String: WireValue]
    let selectedContextWindow: Int?
    /// A side conversation shares the window with its parent; it keeps the two
    /// readings that are its own and drops the session gauge.
    var compact = false
    /// Opens the Session Inspector at a page.
    let open: (InspectorFocus) -> Void

    init(session: SessionDisplay, footer: SessionMetrics, context: [String: WireValue], selectedContextWindow: Int?, compact: Bool = false,
         open: @escaping (InspectorFocus) -> Void) {
        self.session = session; self.footer = footer; self.context = context
        self.selectedContextWindow = selectedContextWindow; self.compact = compact; self.open = open
    }
    /// What the session and its figures change reaches the pills through
    /// their own observation; a footer drawn again for anything else hands
    /// them the same reading. `open` goes to the Inspector of the session
    /// they were made for.
    nonisolated static func == (lhs: SessionStatsPillsReference, rhs: SessionStatsPillsReference) -> Bool {
        MainActor.assumeIsolated {
            lhs.session === rhs.session && lhs.footer === rhs.footer && lhs.context == rhs.context
                && lhs.selectedContextWindow == rhs.selectedContextWindow && lhs.compact == rhs.compact
        }
    }

    private var presentation: SessionStatsPresentation {
        SessionStatsPresentation(gateway: footer.gateway, work: WorkSplit(timing: footer.turnTiming), cost: footer.cost)
    }
    private var meter: ContextMeterPresentation {
        ContextMeterPresentation(context: context,
                                 capacity: session.hasWork ? nil : selectedContextWindow.map(Double.init))
    }

    var body: some View {
        let _ = RedrawCounter.note("statsPills")
        let stats = presentation
        // The pills flow like a sentence: a narrow pane wraps between them
        // rather than cutting a figure in half.
        PiFlow(spacing: PiSpacing.xs, rowSpacing: 3, reportsUsedWidth: true) {
            if !compact, stats.steps > 0 {
                PiStatButtonReference(symbol: "gauge.with.dots.needle.67percent", label: stats.gaugeLabel, scope: ObjectIdentifier(footer),
                             accessibility: "Session statistics: " + stats.gaugeLabel, identifier: "session-stats-time",
                             help: SettledThroughput.explanation + " Opens the Session Inspector.") { open(.overview) }
            }
            if stats.hasUsage {
                // Near the chat's cost limit, the spend is apart, in warning ink.
                // The token split where the pane has room for it; a narrower
                // pane keeps the total, the cache hit and the cost whole.
                ViewThatFits(in: .horizontal) {
                    usagePill(stats, face: stats.usageFace)
                    usagePill(stats, face: stats.compactUsageFace)
                }
            }
            contextPill
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionStatsPills")
    }

    private func usagePill(_ stats: SessionStatsPresentation, face: (label: String, warningTail: String?)) -> some View {
        PiStatButtonReference(symbol: "cylinder.split.1x2", label: face.label, warningTail: face.warningTail, scope: ObjectIdentifier(footer),
                     accessibility: "Token usage: " + stats.usageLabel, identifier: "session-stats-usage",
                     help: "Gateway-reported usage and cost for this session's retained requests, and its cost limit. Uncached and cached input make up the input; reasoning is part of the output. Opens the Session Inspector.") { open(.overview) }
    }

    /// A 14 pt ring and its reading. A conversation whose context has not been
    /// counted yet says so instead of drawing an empty ring at zero.
    ///
    /// Its words ("Inspect context", "Calculating context…" while a shown
    /// chat is counted, "Compacting context…") and its figures take different
    /// room. Where the pill ends a row, a longer label used to start a row of
    /// its own: the footer grew a row and the conversation above it jumped,
    /// and jumped back when a shorter one came. The pill now keeps one room
    /// for each showing of its chat (`ContextPillSlot`): words are cut to it
    /// where the row has no more, a shorter figure keeps it, and only a wider
    /// figure widens it. The room lies behind and after the pill, so its fill
    /// and press target stay the size of what it says. A figure is never cut.
    private var contextPill: some View {
        let meter = meter
        let reading = meter.fraction.flatMap(MetricFormat.occupancyPercent)
        let figure = reading.map { $0 + "%" }
        let label = figure ?? (footer.preparingContext ? "Calculating context…" : meter.compactLabel)
        // What the pill shows now is in the room already: a showing's first
        // frame, and a wider figure, are laid out right the first time.
        let slot = ContextPillSlot.of(footer.contextSlot, showing: session.presentationGeneration).adding(label, figure: figure != nil)
        return ZStack(alignment: .leading) {
            ForEach(slot.labels, id: \.self) { held in
                PiStatPillFace(symbol: "square.stack.3d.up", ring: .some(meter.fraction), label: held).hidden()
            }
            PiStatButtonReference(symbol: "square.stack.3d.up", ring: .some(meter.fraction), label: label, truncates: figure == nil, scope: ObjectIdentifier(footer),
                         accessibility: reading.map { "\($0)% of context used" } ?? meter.detailLabel,
                         identifier: "session-stats-context", help: meter.detailLabel + " Opens the next request in the Session Inspector.") { open(.nextRequest) }
        }
        .onChange(of: slot, initial: true) { [footer, session] _, slot in
            // A room for a showing that has since ended is not kept.
            if slot.showing == session.presentationGeneration, footer.contextSlot != slot { footer.contextSlot = slot }
        }
        .layoutValue(key: PiFlowFillsRow.self, value: true)
    }
}


/// A stat pill that opens something: the pill's face, a soft fill under the
/// pointer, and an AppKit press target over it (`PiPopoverTrigger`) that keeps
/// its size, so nothing about it asks for another layout, and that a test can
/// press without an active app.
struct PiStatButtonReference: View {
    let symbol: String
    var ring: Double?? = nil
    let label: String
    /// A last figure in warning ink (see `PiStatPillFace.warningTail`).
    var warningTail: String? = nil
    /// Words that may end in "…" (`PiStatPillFace.truncates`).
    var truncates = false
    /// What the figures are of (`PiStatPillFace.scope`).
    var scope: AnyHashable? = nil
    var accessibility: String? = nil
    var identifier: String? = nil
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        PiStatPillFace(symbol: symbol, ring: ring, label: label, highlighted: hovering, warningTail: warningTail, truncates: truncates, scope: scope)
            .accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: accessibility ?? label, identifier: identifier, help: help.isEmpty ? label : help,
                                 onHover: { inside in if hovering != inside { hovering = inside } },
                                 onPress: { _ in action() })
            }
    }
}
