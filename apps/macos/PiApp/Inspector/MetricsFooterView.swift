import AppKit
import CoreText

/// What the composer sits on: the session's three readings as pills, and —
/// only while a run is going — the elapsed clock and the action under way.
/// Every figure is settled; nothing here ticks with a stream. The details
/// behind the figures are in the Session Inspector, which the pills and the
/// capture badge open.
@MainActor final class MetricsFooter: DashView, PiKit.WidthSizing {
    let model: WorkspaceModel
    private(set) var session: SessionDisplay
    private var footer: SessionMetrics { session.footer }
    let selectedContextWindow: Int?
    let selectedOutputReserve: Int?
    /// A side conversation shares the window with the chat it was opened from,
    /// and its own status bar repeated every figure of that chat's. The
    /// compact form keeps what belongs to this conversation alone: how much
    /// context it holds and what it has cost.
    let compact: Bool
    /// Opens the Session Inspector's Overview.
    let inspect: () -> Void
    /// The room the capture badge keeps for this showing of the chat (`FooterBadgeRoom`).
    private var badgeRoom: FooterBadgeRoom?
    private var observer: ShellObserver!
    private var activationObserver: ShellObserver!
    private var scheduledActivation: AutomaticContextActivation?
    /// A disabled pane's footer (`.disabled`), its controls' own state kept.
    var inheritedEnabled = true { didSet { if inheritedEnabled != oldValue { refresh() } } }

    let pills: SessionStatsPills
    private let run: SessionRunLine
    private let notice = FooterNotice()
    private let badge = CaptureBadge()
    /// The full form: pills, run slot, notice and badge on one row; else the
    /// run line on its own row under the pills.
    private(set) var fullForm = true

    init(model: WorkspaceModel, session: SessionDisplay, contextWindow: Int? = nil, outputReserve: Int? = nil,
         compact: Bool = false, inspect: @escaping () -> Void) {
        self.model = model; self.session = session; selectedContextWindow = contextWindow; selectedOutputReserve = outputReserve
        self.compact = compact; self.inspect = inspect
        pills = SessionStatsPills(session: session, selectedContextWindow: contextWindow, compact: compact) { [weak model, id = session.id] focus in
            model?.openInspector(session: id, focus: focus)
        }
        run = SessionRunLine(session: session)
        super.init(frame: .zero)
        clipsToBounds = true
        badge.onPress = { [weak self] in self?.inspect() }
        for view in [pills, run, notice, badge] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        toolTip = SettledThroughput.explanation + " " + ContextMeterPresentation.methodExplanation
        if compact { setAccessibilityIdentifier("compactMetricsFooter") }
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(session)
        observer.observe(session.footer)
        observer.observe(publisher: model.$chats)
        observer.observe(publisher: model.$configuration)
        // Eligibility depends on the page, focus and configuration as well
        // as the chat. Those changes need not redraw any settled figures.
        activationObserver = ShellObserver { [weak self] in self?.refreshActivation() }
        activationObserver.observe(model)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `.onDisappear`: the chat's automatic context count waits for it to show again.
        if window == nil { model.cancelAutomaticContext(session.id); scheduledActivation = nil }
        else { refresh() }
    }

    private var captureTitle: String { session.captureMode == "off" ? "Capture off" : session.captureMode == "persist" ? "Persist locally" : "Session memory" }
    /// What the badge says in the full form: "Next: " while capture waits for the chat's helper.
    private var badgeText: String { (session.captureAvailable ? "" : "Next: ") + captureTitle }
    private var captureTone: PiTone { session.captureMode == "memory" ? .info : .neutral }

    private func refreshActivation() {
        // `.task(id: model.automaticContextActivation(session))`
        if window != nil {
            let activation = model.automaticContextActivation(session)
            if activation != scheduledActivation { scheduledActivation = activation; model.scheduleAutomaticContext(session.id) }
        }
    }

    func refresh() {
        refreshActivation()
        // The badge's room is worked out before either form is tried, with
        // what it says now already in it; a showing's first frame is right.
        let room = FooterBadgeRoom.of(badgeRoom, chat: ObjectIdentifier(footer), showing: session.presentationGeneration, text: badgeText)
        if room.showing == session.presentationGeneration { badgeRoom = room }
        pills.update(context: model.displayedContext(session))
        run.isHidden = compact || !session.busy
        run.refresh()
        notice.text = session.notice
        notice.isHidden = session.notice.isEmpty
        badge.isHidden = compact
        badge.configure(text: badgeText, room: room.text, tone: captureTone, available: session.captureAvailable,
                        label: "Capture: " + captureTitle + ". Open the Session Inspector",
                        help: "Capture: " + captureTitle + ". Open the Session Inspector: every request, its bodies and the capture settings")
        badge.isEnabled = inheritedEnabled
        for control in PiKit.controls(in: pills) { control.isEnabled = inheritedEnabled }
        invalidateIntrinsicContentSize(); needsLayout = true
        PiKit.sizeChanged(self)
    }

    // MARK: Layout

    static let padding = NSEdgeInsets(top: 2, left: PiSpacing.lg, bottom: 6, right: PiSpacing.lg)
    /// The one-row form's room for the run line: the clock's template and a
    /// phase such as "Generating response…". A longer action ends in "…" and
    /// is whole in the line's help; on its own row it takes the full width.
    static let runSlot: CGFloat = 220
    /// Narrower than this, a notice is not shown: its help still has it.
    static let noticeLeast: CGFloat = 48
    private let spacing = PiSpacing.md

    /// The trailing parts in the form: (view, width).
    private func trailing(full: Bool) -> [(NSView, CGFloat)] {
        guard !compact else { return [] }
        var parts: [(NSView, CGFloat)] = [(badge, badge.slotWidth(full: full))]
        if full, session.busy { parts.append((run, Self.runSlot)) }
        return parts
    }
    private func trailingWidth(full: Bool) -> CGFloat { trailing(full: full).reduce(0) { $0 + $1.1 + spacing } }
    /// `ViewThatFits`: the full form when its ideal width (the pills on one
    /// row and the trailing parts) fits.
    private func fits(_ inner: CGFloat) -> Bool { compact || pills.oneRowWidth + trailingWidth(full: true) <= inner }
    private func rowHeight(full: Bool, inner: CGFloat) -> CGFloat {
        let pillsHeight = pills.height(forWidth: max(0, inner - trailingWidth(full: full)))
        let trailingHeight = trailing(full: full).map { $0.0 === badge ? badge.intrinsicContentSize.height : run.intrinsicContentSize.height }.max() ?? 0
        return max(pillsHeight, trailingHeight)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(0, width - Self.padding.left - Self.padding.right)
        let full = fits(inner)
        var height = rowHeight(full: full, inner: inner)
        if !full, session.busy { height += PiSpacing.xs + run.intrinsicContentSize.height }
        return height + Self.padding.top + Self.padding.bottom
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 900)) }
    override func layout() {
        super.layout()
        let scale = piScale
        let inner = CGRect(x: Self.padding.left, y: Self.padding.top, width: max(0, bounds.width - Self.padding.left - Self.padding.right), height: 0)
        let full = fits(inner.width)
        fullForm = full
        badge.setFull(full)
        notice.isHidden = session.notice.isEmpty || (!full && !compact)
        let row = rowHeight(full: full, inner: inner.width)
        let midY = inner.minY + row / 2
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = CGRect(x: x, y: PiKit.round(midY - height / 2, scale), width: width, height: height)
        }
        let pillsWidth = max(0, inner.width - trailingWidth(full: full))
        let pillsSize = CGSize(width: pills.usedWidth(forWidth: pillsWidth), height: pills.height(forWidth: pillsWidth))
        place(pills, x: inner.minX, width: pillsSize.width, height: pillsSize.height)
        // From the trailing edge: the badge, the run slot, then the notice,
        // so neither of the first two ever moves for the third.
        var x = inner.maxX
        for (view, width) in trailing(full: full) {
            x -= width
            let height = view === badge ? badge.intrinsicContentSize.height : run.intrinsicContentSize.height
            place(view, x: x, width: width, height: height)
            x -= spacing
        }
        if !notice.isHidden {
            let free = x - (inner.minX + pillsSize.width + spacing)
            let ideal = notice.idealWidth
            let width = free >= Self.noticeLeast ? min(ideal, free) : 0
            notice.isHiddenForRoom = width == 0
            place(notice, x: x - width, width: width, height: notice.intrinsicContentSize.height)
        }
        if !full, session.busy, !compact {
            let h = run.intrinsicContentSize.height
            run.frame = CGRect(x: inner.minX, y: inner.minY + row + PiSpacing.xs, width: inner.width, height: h)
        }
    }
}

/// The capture badge in the room kept for it this showing: a longer text
/// ("Next: " when an idle helper leaves) is cut to it, a shorter one keeps
/// it. The room lies before the badge, outside its capsule and its press
/// target, which hug what it says.
@MainActor final class CaptureBadge: DashView {
    private let badge = PiKit.Badge(text: "")
    private let sizer = PiKit.Badge(text: "")
    private let target = Target()
    var onPress: (() -> Void)? { get { target.onPress } set { target.onPress = newValue } }
    var isEnabled: Bool { get { target.isEnabled } set { target.isEnabled = newValue } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.setAccessibilityElement(false)
        addSubview(badge); addSubview(target)
        target.setAccessibilityIdentifier("capture-badge")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var full = true
    private var caption = ""
    func configure(text: String, room: String, tone: PiTone, available: Bool, label: String, help: String) {
        let icon = available ? "record.circle.fill" : "record.circle"
        caption = text
        badge.text = full ? text : ""; badge.tone = tone; badge.icon = icon
        sizer.text = room; sizer.tone = tone; sizer.icon = icon
        target.setAccessibilityLabel(label); target.toolTip = help
        needsLayout = true
    }
    func setFull(_ value: Bool) {
        guard full != value else { return }
        full = value
        badge.text = full ? caption : ""
        needsLayout = true
    }
    /// The slot: the room's badge in the full form, the bare badge in the other.
    func slotWidth(full: Bool) -> CGFloat {
        if full { return sizer.intrinsicContentSize.width }
        let bare = PiKit.Badge(text: "", tone: badge.tone, icon: badge.icon)
        return bare.intrinsicContentSize.width
    }
    override var intrinsicContentSize: NSSize { NSSize(width: sizer.intrinsicContentSize.width, height: badge.intrinsicContentSize.height) }
    override func layout() {
        super.layout()
        let size = badge.intrinsicContentSize
        // Trailing in its slot; a text longer than the room is cut to it.
        let width = min(size.width, bounds.width)
        badge.frame = CGRect(x: bounds.width - width, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: width, height: size.height)
        target.frame = badge.frame
    }
    /// The press target over the badge.
    final class Target: PiKit.ButtonBase {
        override init(frame: NSRect) { super.init(frame: frame); pressScales = false }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    }
}

/// The one line here that tells the reader what to do next ("Run cancelled.
/// Pending messages are paused; resume below"): an info symbol and the notice,
/// cut with "…" to the room the row leaves, up to 640 points, whole in its help.
@MainActor final class FooterNotice: DashView {
    var text = "" { didSet { if text != oldValue { setAccessibilityLabel(text); toolTip = text; needsDisplay = true } } }
    var isHiddenForRoom = false { didSet { setAccessibilityElement(!isHiddenForRoom) } }
    private let glyph = PiKit.Symbol("info.circle", size: 10.5)
    private var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.caption, color: .piInkSecondary) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    var idealWidth: CGFloat { min(640, glyph.layoutSize.width + 5 + line.size(scale: piScale).width) }
    override var intrinsicContentSize: NSSize { NSSize(width: idealWidth, height: max(line.lineHeight, glyph.layoutSize.height)) }
    override func draw(_ dirtyRect: NSRect) {
        let scale = piScale
        // `.frame(maxWidth: 640, alignment: .trailing).clipped()`: the symbol and the words from the trailing edge.
        let g = glyph.layoutSize
        let textWidth = max(0, min(line.size(scale: scale).width, bounds.width - g.width - 5))
        // A truncated SwiftUI Text reports the rounded width of its actual
        // glyphs; the enclosing trailing HStack leaves that spare room on
        // the leading edge, rather than after the ellipsis.
        let original = CTLineCreateWithAttributedString(line.attributed)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: line.attributes()))
        let shown = line.width > textWidth + 0.01 ? CTLineCreateTruncatedLine(original, textWidth, .end, token) : original
        let occupied = shown.map { PiKit.ceil(CTLineGetTypographicBounds($0, nil, nil, nil), scale) } ?? 0
        // The symbol retains its minimum size even in a zero-width
        // proposal, as the reference HStack does. The footer clips it.
        let x = max(0, bounds.width - occupied - 5 - g.width)
        glyph.draw(centredIn: CGRect(x: x, y: 0, width: g.width, height: bounds.height), color: .piInkSecondary, scale: scale)
        line.draw(in: CGRect(x: x + g.width + 5, y: PiKit.round((bounds.height - line.lineHeight) / 2, scale), width: textWidth, height: line.lineHeight), scale: scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The only figures the footer shows while a request is in flight: how long
/// the turn has been going, and what it is doing. Both come from the helper's
/// own snapshot, so neither is measured from a stream in the view.
@MainActor final class SessionRunLine: DashView {
    let session: SessionDisplay
    private var footer: SessionMetrics { session.footer }
    private var clock: Timer?
    private var clockOriginShown: Date?
    init(session: SessionDisplay) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("session-run-line")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    /// "Running bash…", "Compacting context…", "Stopping…".
    var action: String { Self.action(session) }
    static func action(_ session: SessionDisplay) -> String {
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
    /// names the same schedule and each tick falls mid-second. Without a
    /// start stamp, the current instant.
    static func clockOrigin(_ timing: [String: WireValue], atUptimeMs now: Double, date: Date) -> Date {
        guard let started = timing["startedAt"]?.number, started.isFinite, started >= 0, started <= now else { return date }
        let origin = date.timeIntervalSinceReferenceDate - (now - started) / 1_000 + 0.5
        return Date(timeIntervalSinceReferenceDate: (origin * 100).rounded() / 100)
    }
    private static var font: NSFont { PiKit.Font.caption }
    private var elapsedText: String? { Self.elapsed(footer.turnTiming, atUptimeMs: ProcessInfo.processInfo.systemUptime * 1_000) }
    /// As wide as "00m 00s" from the first second on, so no clock step moves what follows it.
    private var clockWidth: CGFloat {
        let template = PiKit.Line("00m 00s", font: PiKit.Font.monospacedDigits(Self.font), color: .black).size(scale: piScale).width
        let now = elapsedText.map { PiKit.Line($0, font: PiKit.Font.monospacedDigits(Self.font), color: .black).size(scale: piScale).width } ?? 0
        return max(template, now)
    }
    func refresh() {
        let action = self.action
        setAccessibilityLabel(action); toolTip = "The turn under way: " + action
        needsDisplay = true
        guard !isHidden, window != nil else { clock?.invalidate(); clock = nil; clockOriginShown = nil; return }
        // `TimelineView(.periodic(from: clockOrigin, by: 1))`
        let origin = Self.clockOrigin(footer.turnTiming, atUptimeMs: ProcessInfo.processInfo.systemUptime * 1_000, date: Date())
        guard origin != clockOriginShown || clock == nil else { return }
        clockOriginShown = origin
        clock?.invalidate()
        let now = Date()
        let next = origin > now ? origin : origin.addingTimeInterval((now.timeIntervalSince(origin) / 1).rounded(.up))
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override var isHidden: Bool { didSet { if isHidden != oldValue { refresh() } } }
    override var intrinsicContentSize: NSSize {
        let line = PiKit.Line(action, font: Self.font, color: .piInkSecondary)
        let clock = elapsedText == nil ? 0 : clockWidth + 6
        return NSSize(width: clock + line.size(scale: piScale).width, height: line.lineHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        let scale = piScale
        var x: CGFloat = 0
        if let elapsed = elapsedText {
            PiKit.Line(elapsed, font: PiKit.Font.monospacedDigits(Self.font), color: .piInkSecondary).draw(at: .zero, scale: scale)
            x = clockWidth + 6
        }
        let line = PiKit.Line(action, font: Self.font, color: .piInkSecondary)
        line.draw(in: CGRect(x: x, y: 0, width: max(0, bounds.width - x), height: line.lineHeight), scale: scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Session statistics under the composer: how much work the conversation did
/// and how fast, what it consumed, and how full the window is. Three pills,
/// no figure that ticks while a request runs. Each opens the Session
/// Inspector where its figure is explained: the first two its Overview, the
/// context ring the next request.
@MainActor final class SessionStatsPills: DashView, PiKit.WidthSizing {
    let session: SessionDisplay
    private var footer: SessionMetrics { session.footer }
    let selectedContextWindow: Int?
    let compact: Bool
    let open: (InspectorFocus) -> Void
    private var context: [String: WireValue] = [:]
    let gauge = PiKit.StatPill(symbol: "gauge.with.dots.needle.67percent", label: "")
    let usage = PiKit.StatPill(symbol: "cylinder.split.1x2", label: "")
    let contextPill = PiKit.StatPill(symbol: "square.stack.3d.up", ring: .some(nil), label: "")
    private var contextLabelWidths: [String: CGFloat] = [:]
    private var contextLabelWidthScale: CGFloat?
    /// The usage pill's two faces (`ViewThatFits`): the token split, else the compact one.
    typealias Face = (label: String, warningTail: String?)
    private var usageFaces: (full: Face, compact: Face)?
    private let fullUsageSizer = PiKit.StatPill(symbol: "cylinder.split.1x2", label: "")
    private let compactUsageSizer = PiKit.StatPill(symbol: "cylinder.split.1x2", label: "")
    private struct UsageScope: Hashable {
        let footer: ObjectIdentifier
        let full: Bool
    }
    /// The room the context pill keeps (`ContextPillSlot`): its widest label's pill.
    private var contextSlotWidth: CGFloat = 0
    static let spacing = PiSpacing.xs, rowSpacing: CGFloat = 3

    init(session: SessionDisplay, selectedContextWindow: Int?, compact: Bool, open: @escaping (InspectorFocus) -> Void) {
        self.session = session; self.selectedContextWindow = selectedContextWindow; self.compact = compact; self.open = open
        super.init(frame: .zero)
        gauge.onPress = { [weak self] in self?.open(.overview) }
        usage.onPress = { [weak self] in self?.open(.overview) }
        contextPill.onPress = { [weak self] in self?.open(.nextRequest) }
        gauge.setAccessibilityIdentifier("session-stats-time")
        usage.setAccessibilityIdentifier("session-stats-usage")
        contextPill.setAccessibilityIdentifier("session-stats-context")
        gauge.toolTip = SettledThroughput.explanation + " Opens the Session Inspector."
        usage.toolTip = "Gateway-reported usage and cost for this session's retained requests, and its cost limit. Uncached and cached input make up the input; reasoning is part of the output. Opens the Session Inspector."
        for view in [gauge, usage, contextPill] as [NSView] { addSubview(view) }
        setAccessibilityElement(false); setAccessibilityRole(.group)
        setAccessibilityIdentifier("sessionStatsPills")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    func update(context: [String: WireValue]) {
        RedrawCounter.note("statsPills")
        self.context = context
        let stats = SessionStatsPresentation(gateway: footer.gateway, work: WorkSplit(timing: footer.turnTiming), cost: footer.cost)
        let scope = AnyHashable(ObjectIdentifier(footer))
        gauge.isHidden = compact || stats.steps == 0
        if !gauge.isHidden {
            gauge.update(label: stats.gaugeLabel, scope: scope)
            gauge.accessibilityName = "Session statistics: " + stats.gaugeLabel
        }
        usage.isHidden = !stats.hasUsage
        usageFaces = stats.hasUsage ? (full: stats.usageFace, compact: stats.compactUsageFace) : nil
        if let faces = usageFaces {
            fullUsageSizer.update(label: faces.full.label, warningTail: faces.full.warningTail, scope: nil)
            compactUsageSizer.update(label: faces.compact.label, warningTail: faces.compact.warningTail, scope: nil)
            usage.accessibilityName = "Token usage: " + stats.usageLabel
        }
        // The context pill keeps one room for each showing of its chat.
        let meter = ContextMeterPresentation(context: context, capacity: session.hasWork ? nil : selectedContextWindow.map(Double.init))
        let reading = meter.fraction.flatMap(MetricFormat.occupancyPercent)
        let figure = reading.map { $0 + "%" }
        let label = figure ?? (footer.preparingContext ? "Calculating context…" : meter.compactLabel)
        let slot = ContextPillSlot.of(footer.contextSlot, showing: session.presentationGeneration).adding(label, figure: figure != nil)
        if slot.showing == session.presentationGeneration, footer.contextSlot != slot { footer.contextSlot = slot }
        contextPill.update(glyph: .ring(meter.fraction), label: label, scope: scope)
        contextPill.truncates = figure == nil
        contextPill.accessibilityName = reading.map { "\($0)% of context used" } ?? meter.detailLabel
        contextPill.toolTip = meter.detailLabel + " Opens the next request in the Session Inspector."
        contextSlotWidth = slot.labels.map { pillWidth(label: $0) }.max() ?? pillWidth(label: label)
        chooseUsageFace(width: bounds.width > 0 ? bounds.width : .infinity)
        needsLayout = true
    }
    private func pillWidth(label: String) -> CGFloat {
        // The measuring pill is off-window and uses the main screen's scale.
        // Its fonts and glyph are fixed; repeated readings keep the same width.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if contextLabelWidthScale != scale {
            contextLabelWidthScale = scale
            contextLabelWidths.removeAll(keepingCapacity: true)
        }
        if let width = contextLabelWidths[label] { return width }
        let width = PiKit.StatPill(symbol: "square.stack.3d.up", ring: .some(nil), label: label).intrinsicContentSize.width
        if contextLabelWidths.count >= 64 { contextLabelWidths.removeAll(keepingCapacity: true) }
        contextLabelWidths[label] = width
        return width
    }
    /// The full usage face when it fits the row's width, else the compact one.
    private func chooseUsageFace(width: CGFloat) {
        guard let faces = usageFaces else { return }
        let full = fullUsageSizer.intrinsicContentSize.width <= width
        let face = full ? faces.full : faces.compact
        let scope = AnyHashable(UsageScope(footer: ObjectIdentifier(footer), full: full))
        if usage.label != face.label || usage.warningTail != face.warningTail || usage.scope != scope {
            usage.update(label: face.label, warningTail: face.warningTail, scope: scope)
        }
    }
    /// Measuring a proposal does not change the displayed face or start a
    /// numeric animation. Measurement and placement choose the same form.
    private func usageSize(width: CGFloat) -> NSSize {
        let full = fullUsageSizer.intrinsicContentSize
        return full.width <= width ? full : compactUsageSizer.intrinsicContentSize
    }

    // MARK: Flow (`PiFlow(spacing: 4, rowSpacing: 3, reportsUsedWidth: true)`)

    /// Each pill's frame at `width`; the context pill fills what its row leaves, down to its narrowest.
    private func place(width: CGFloat) -> (frames: [(NSView, CGRect)], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var frames: [(NSView, CGRect)] = []
        for view in [gauge, usage] where !view.isHidden {
            let size = view === usage ? usageSize(width: width) : view.intrinsicContentSize
            if x > 0, x + size.width > width { x = 0; y += rowHeight + Self.rowSpacing; rowHeight = 0 }
            frames.append((view, CGRect(x: x, y: y, width: size.width, height: size.height)))
            x += size.width + Self.spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - Self.spacing)
        }
        // The hidden held labels in the reference keep the whole slot as
        // its minimum width, including while context is being calculated.
        let height = contextPill.intrinsicContentSize.height
        let least = contextSlotWidth
        let wraps = width.isFinite && x > 0 && x + least > width
        if wraps { x = 0; y += rowHeight + Self.rowSpacing; rowHeight = 0 }
        let room = width.isFinite ? max(least, width - x) : contextSlotWidth
        let slot = min(contextSlotWidth, room)
        let face = min(contextPill.intrinsicContentSize.width, slot)
        frames.append((contextPill, CGRect(x: x, y: y, width: face, height: height)))
        x += slot + Self.spacing; rowHeight = max(rowHeight, height); maxX = max(maxX, x - Self.spacing)
        return (frames, CGSize(width: width.isFinite ? min(width, maxX) : maxX, height: y + rowHeight))
    }
    /// The pills on one row: the footer's full form needs this much.
    var oneRowWidth: CGFloat { place(width: .infinity).size.width }
    func usedWidth(forWidth width: CGFloat) -> CGFloat { place(width: width).size.width }
    func height(forWidth width: CGFloat) -> CGFloat { place(width: width).size.height }
    override var intrinsicContentSize: NSSize { place(width: .infinity).size }
    override func layout() {
        super.layout()
        chooseUsageFace(width: bounds.width)
        let scale = piScale
        let (frames, size) = place(width: bounds.width)
        // Each row's pills centred on the row.
        for (view, frame) in frames {
            view.frame = CGRect(x: frame.minX, y: PiKit.round(frame.minY + (rowHeightAt(frame.minY, frames) - frame.height) / 2, scale), width: frame.width, height: frame.height)
        }
        _ = size
    }
    private func rowHeightAt(_ y: CGFloat, _ frames: [(NSView, CGRect)]) -> CGFloat {
        frames.filter { $0.1.minY == y }.map(\.1.height).max() ?? 0
    }
}
