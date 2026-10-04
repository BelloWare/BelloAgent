import AppKit
import Combine
import QuartzCore

// One chat on one line: its title, its state, its figures and its unread
// dot, plus the side conversation that hangs under it. Every row here is
// given values its parent already looked up, so it changes only what changed.

/// Compact live stats for a sidebar row: state, cost and the session's input,
/// cached-input and output tokens. The composer footer owns the separate
/// context-size estimate.
struct ChatRowStats: Equatable {
    /// The chat's `RunState` as a string, or "tool" while its run waits on a tool.
    var state = "idle"
    /// The last run stopped at the chat's cost limit: a stop, not a failure.
    var costLimited = false
    var busy = false
    var loading = false
    var costUSD: Double?
    var cacheHits = 0
    var cacheMisses = 0
    var requests = 0
    var tokens: Double?
    var tokenSamples = 0
    var inputTokens: Double?
    var cachedTokens: Double?
    var outputTokens: Double?
    var inputSamples = 0
    var cachedSamples = 0
    var outputSamples = 0
    var generating = false
    var timing: SessionTimingHistory?
    /// Seconds since 1970 of the latest request or message, for the "3m ago" stamp.
    private(set) var lastActivity: Double?
    /// "3m ago", "2h ago", "yesterday", or a short date, as of when the row
    /// was built; nil without any activity. Stored rather than worked out on
    /// reading, so a row whose stamp now reads differently compares unequal
    /// and is drawn again: one that held only the time kept "just now".
    private(set) var recencyLabel: String?
    init(totals: GatewayTotals?, timing: SessionTimingHistory? = nil, now: Date = Date()) {
        self.timing = timing
        costUSD = totals?.costUSD; cacheHits = totals?.cacheHits ?? 0; cacheMisses = totals?.cacheMisses ?? 0; requests = totals?.requests ?? 0
        tokens = totals?.tokens?.total; tokenSamples = totals?.tokens?.samples ?? 0
        inputTokens = totals?.tokens?.input; outputTokens = totals?.tokens?.output; cachedTokens = totals?.cacheReadTokens
        inputSamples = totals?.tokens?.inputSamples ?? 0; outputSamples = totals?.tokens?.outputSamples ?? 0; cachedSamples = totals?.cacheReadSamples ?? 0
        noteActivity(totals?.lastActivity, now: now)
    }
    mutating func noteActivity(_ seconds: Double?, now: Date = Date()) {
        lastActivity = seconds
        recencyLabel = seconds.flatMap { $0.isFinite && $0 > 0 ? ChatRowStats.relative(Date(timeIntervalSince1970: $0), now: now) : nil }
    }
    var hasActivity: Bool { requests > 0 || busy || loading || tokens != nil || timing?.latest != nil }
    /// "12k in · 8.1k cached · 2.4k out". Unreported usage reads n/a, never zero.
    var usageLabel: String? {
        guard requests > 0 || inputTokens != nil || outputTokens != nil else { return nil }
        return "\(compactTokens(inputTokens)) in · \(compactTokens(cachedTokens)) cached · \(compactTokens(outputTokens)) out"
    }
    var usageHelp: String {
        "Session tokens · input \(menuBarTokens(inputTokens)) (\(inputSamples)/\(requests) requests reported) · cached input \(menuBarTokens(cachedTokens)) (\(cachedSamples)/\(requests) reported) · output \(menuBarTokens(outputTokens)) (\(outputSamples)/\(requests) reported). "
        + "Input counts cached tokens once; reasoning is included in output. Context size is shown below the composer."
    }
    var costLabel: String? {
        guard let costUSD, costUSD.isFinite, costUSD >= 0 else { return requests > 0 ? "cost n/a" : nil }
        if costUSD == 0 { return "$0.00" }
        return MetricFormat.centsUSD(costUSD, places: 4, padded: true)
    }
    var tokensLabel: String? {
        guard let tokens, tokens.isFinite, tokens >= 0 else { return requests > 0 ? "tok n/a" : nil }
        return MetricFormat.rowTokenCount(tokens)
    }
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        if seconds < 172_800 { return "yesterday" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    var tokensHelp: String {
        "Session tokens consumed: \(menuBarTokens(tokens)). \(tokenSamples)/\(requests) requests reported both input and output. "
        + (tokenSamples < requests ? "Partial total; missing usage is excluded. " : "")
        + "Input includes cached tokens once; reasoning is included in output. Context size is shown below the composer."
    }
    mutating func updateActivity(state: String, loading: Bool, activity: [String: WireValue]) {
        self.state = state; self.loading = loading
        busy = RunState(rawValue: state).isBusy
        let phase = activity["phase"]?.string ?? ""
        generating = busy && !loading && RunState(rawValue: state) != .stopping && [1, 2].contains(activity["version"]?.number ?? 0)
            && activity["modelActive"]?.bool == true && ["model", "compacting"].contains(phase)
        if busy && phase == "tool" { self.state = "tool" }
    }
    var rateLabel: String? { timing.flatMap { SessionRatePresentation(history: $0).label } }
}

/// The minute the sidebar's "3m ago" stamps are worked out against: one
/// clock for every row, ticking on the minute. A row whose stamp still reads
/// the same draws nothing new.
@MainActor final class SidebarMinute {
    static let shared = SidebarMinute()
    /// Ticks on each minute, for the rows to redraw their stamps.
    @Published private(set) var tick = Date()
    /// The time a stamp is worked out against: read when a row draws, as
    /// SwiftUI's clock gave the date of the pass.
    var now: Date { Date() }
    private var timer: Timer?
    private init() { schedule() }
    private func schedule() {
        let next = (floor(Date().timeIntervalSinceReferenceDate / 60) + 1) * 60
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// A small accent dot marks a chat with replies the user has not viewed. The
/// sidebar records only whether a chat is unread, never how many replies.
@MainActor final class UnreadDotView: NSView {
    /// A run that failed while you were away: marked, but never counted in the Dock badge.
    var failure = false { didSet { if oldValue != failure { apply() } } }
    static let size: CGFloat = 7
    init(failure: Bool = false) {
        self.failure = failure
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        setAccessibilityElement(true); setAccessibilityRole(.image)
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    private func apply() {
        setAccessibilityLabel(failure ? "Run failed" : "Unread replies")
        toolTip = failure ? "The last run failed while you were away" : "New replies you have not viewed"
        needsDisplay = true; updateLayer()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(failure ? .piDanger : .piBrandOrange) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
    /// Arrives with a small spring, as `.transition(.scale.combined(with: .opacity))`.
    func popIn() {
        guard !PiKit.Motion.reduced, let layer else { return }
        let pop = PiKit.Motion.pop("transform.scale"); pop.fromValue = 0; pop.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = pop.duration
        layer.add(pop, forKey: "pop"); layer.add(fade, forKey: "fade")
    }
}

/// The sidebar's rate slot: the latest completed request's output rate, as
/// plain text in one stable 108-point slot (the Dashboard's `SidebarReportedRate`).
@MainActor final class SidebarRateView: NSView {
    static let width: CGFloat = 108
    private let line = PiKit.TextLine(PiKit.Line("", font: SidebarRateView.font, color: .piInkTertiary))
    static var font: NSFont { PiKit.Font.monospacedDigits(PiKit.Font.caption) }
    var presentation: SessionRatePresentation? { didSet { if oldValue != presentation { apply(fade: oldValue != nil) } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        line.setAccessibilityElement(false)
        toolTip = SessionRatePresentation.explanation
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("Latest completed output rate"); setAccessibilityIdentifier("sidebar-reported-rate")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: line.intrinsicContentSize.height) }
    private func apply(fade: Bool) {
        let label = presentation?.label
        line.line = PiKit.Line(label ?? "", font: Self.font, color: presentation?.latest == nil ? .piInkTertiary : .piInkSecondary)
        setAccessibilityValue(label ?? "Not measured")
        if fade, window != nil, !PiKit.Motion.reduced {
            let transition = CATransition(); transition.type = .fade; transition.duration = PiKit.Motion.quick
            line.wantsLayer = true; line.layer?.add(transition, forKey: "label")
        }
    }
    override func layout() { super.layout(); line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height) }
}

/// The metrics line under a chat's title: its state, cost, rate, tokens and
/// recency, in the widest form that fits (`SidebarMetricsFigures`); below the
/// narrowest single line the rate goes under the state and cost.
@MainActor final class ChatRowMetricsView: NSView, PiKit.WidthSizing {
    private var stats: ChatRowStats?
    private var form: SidebarMetricsForm = .full
    private let stateLine = PiKit.TextLine()
    private let costLine = PiKit.TextLine()
    private let rate = SidebarRateView()
    private let tokensLine = PiKit.TextLine()
    private let recencyLine = PiKit.TextLine()
    static var font: NSFont { PiKit.Font.monospacedDigits(PiKit.Font.caption) }
    static var stateFont: NSFont { PiKit.Font.monospacedDigits(.systemFont(ofSize: PiKit.Font.captionSize, weight: .medium)) }
    static let spacing = SidebarMetricsFigures.spacing

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [stateLine, costLine, rate, tokensLine, recencyLine] as [NSView] { addSubview(view) }
        tokensLine.truncation = .end; recencyLine.truncation = .end
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(stats: ChatRowStats, available: CGFloat) {
        let form = SidebarMetricsFigures(stats).form(fitting: available)
        guard stats != self.stats || form != self.form else { return }
        self.stats = stats; self.form = form
        var state: (String, NSColor)?
        if (stats.busy || stats.loading) && !stats.generating {
            state = (PiSessionState.label(stats.state, loading: stats.loading), .piWarning)
        } else if RunState(rawValue: stats.state).isStopped {
            state = (PiSessionState.label(stats.state, costLimited: stats.costLimited),
                     RunState(rawValue: stats.state) == .paused ? .piInfo : stats.costLimited ? .piWarning : .piDanger)
        }
        stateLine.isHidden = state == nil
        if let state { stateLine.line = PiKit.Line(state.0, font: Self.stateFont, color: state.1) }
        costLine.isHidden = stats.costLabel == nil
        costLine.line = PiKit.Line(stats.costLabel ?? "", font: Self.font, color: .piInkTertiary)
        rate.isHidden = stats.timing == nil
        rate.presentation = stats.timing.map(SessionRatePresentation.init(history:))
        let showsTokens = form.showsTokens && !stats.busy && stats.tokensLabel != nil && form != .stacked
        tokensLine.isHidden = !showsTokens
        tokensLine.line = PiKit.Line("· " + (stats.tokensLabel ?? ""), font: Self.font, color: .piInkTertiary)
        tokensLine.setAccessibilityLabel(stats.usageHelp); tokensLine.toolTip = stats.usageHelp
        let showsRecency = form.showsRecency && stats.recencyLabel != nil && form != .stacked
        recencyLine.isHidden = !showsRecency
        recencyLine.line = PiKit.Line("· " + (stats.recencyLabel ?? ""), font: Self.font, color: .piInkTertiary)
        recencyLine.setAccessibilityLabel("Last activity " + (stats.recencyLabel ?? "")); recencyLine.toolTip = "Last activity"
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    private var lineHeight: CGFloat { PiKit.Line("Ag", font: Self.font, color: .black).lineHeight }
    func height(forWidth width: CGFloat) -> CGFloat {
        form == .stacked && !rate.isHidden ? lineHeight * 2 + 2 : lineHeight
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: 0)) }
    override func layout() {
        super.layout()
        let scale = piScale, height = lineHeight
        var x: CGFloat = 0
        var y: CGFloat = 0
        let width = bounds.width
        func place(_ view: NSView, _ natural: CGFloat) {
            guard !view.isHidden else { return }
            if x > 0 { x += Self.spacing }
            let room = max(0, width - x)
            view.frame = CGRect(x: x, y: y, width: min(natural, room), height: height)
            x += min(natural, room)
        }
        place(stateLine, stateLine.intrinsicContentSize.width)
        place(costLine, costLine.intrinsicContentSize.width)
        if form == .stacked {
            if !rate.isHidden { x = 0; y = height + 2; place(rate, SidebarRateView.width) }
        } else {
            place(rate, SidebarRateView.width)
            place(tokensLine, tokensLine.intrinsicContentSize.width)
            place(recencyLine, recencyLine.intrinsicContentSize.width)
        }
        _ = scale
    }
}

/// What a chat row shows: its status icon or spinner, its title, the pin,
/// the unread dot, its archive and fold controls, and its figures or state
/// under the title.
@MainActor final class ChatRowBodyView: NSView, PiKit.WidthSizing {
    struct Content: Equatable {
        var stats: ChatRowStats
        var title: String
        var subtitle: String
        var symbol: String
        var selected: Bool
        var unreadCount = 0
        var unreadFailure = false
        var hasSide = false
        var expanded = true
        var pinned = false
        var archived = false
        var archivable = false
        var available: CGFloat = .infinity
        var help: String {
            subtitle + (stats.requests > 0 ? " · \(stats.requests) requests · cache \(stats.cacheHits) hit / \(stats.cacheMisses) miss" : "")
        }
    }
    private(set) var content: Content?
    var toggle: () -> Void = {}
    var archive: () -> Void = {}
    /// The buttons at the row's end changed (the archive confirmation).
    var controlsChanged: (() -> Void)?

    private let icon = PiKit.SymbolView(PiKit.Symbol("bubble.left", size: 12, weight: .medium), color: .piInkSecondary)
    private var spinner: PiSpinnerView?
    private let title = PiKit.TextLine()
    private let pin = PiKit.SymbolView(PiKit.Symbol("pin.fill", size: 9), color: .piInkTertiary)
    private let dot = UnreadDotView()
    private let archiveButton = PiKit.IconButton(symbol: "archivebox", label: "Archive chat", size: 18)
    private let confirm = PiKit.Button("Archive", style: .primary, compact: true)
    private let keep = PiKit.IconButton(symbol: "xmark", label: "Keep chat", size: 18)
    private let chevron = PiKit.IconButton(symbol: "chevron.down", label: "Hide child chats", size: 18)
    private let controls: ShellStack
    private let row1: ShellStack
    private let metrics = ChatRowMetricsView()
    private let subtitle = PiKit.TextLine()
    private var confirming = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        controls = ShellStack(.horizontal, spacing: 4, [.view(archiveButton), .view(confirm), .view(keep), .view(chevron)])
        row1 = ShellStack(.horizontal, spacing: 4, [.view(title, .flexible), .view(pin), .spacer(4), .view(dot), .view(controls)])
        super.init(frame: frame)
        title.truncation = .end; subtitle.truncation = .end
        pin.setAccessibilityElement(true); pin.setAccessibilityRole(.image); pin.setAccessibilityLabel("Pinned chat")
        for view in [icon, row1, metrics, subtitle] as [NSView] { addSubview(view) }
        archiveButton.onPress = { [weak self] in
            guard let self, let content = self.content else { return }
            if content.archived { self.archive() } else { self.setConfirming(true) }
        }
        confirm.onPress = { [weak self] in self?.setConfirming(false); self?.archive() }
        confirm.setAccessibilityIdentifier("confirmArchive")
        keep.onPress = { [weak self] in self?.setConfirming(false) }
        chevron.onPress = { [weak self] in self?.toggle() }
        archiveButton.wantsLayer = true
        chevron.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// The row's own buttons, for a drag surface over it to leave alone.
    var controlFrames: [CGRect] {
        guard !controls.isHidden else { return [] }
        return [controls.convert(controls.bounds, to: self)]
    }

    func update(_ new: Content) {
        let before = content
        guard new != before else { return }
        content = new
        // The icon, or a spinner while it works.
        let working = new.stats.busy || new.stats.loading
        if working, spinner == nil {
            let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
            view.configure(lineWidth: 1.6, turning: !PiKit.Motion.reduced)
            addSubview(view); spinner = view
        } else if !working, let spinner { spinner.removeFromSuperview(); self.spinner = nil }
        icon.isHidden = working
        icon.symbol = PiKit.Symbol(new.symbol, size: 12, weight: .medium)
        icon.color = new.selected ? .piAccent : .piInkSecondary
        // The title: semibold when open or unread; quieter when archived.
        let titleLine = PiKit.Line(new.title, font: .systemFont(ofSize: 13, weight: new.selected || new.unreadCount > 0 ? .semibold : .regular),
                                   color: new.archived && !new.selected ? .piInkSecondary : .piInk)
        if let before, before.title != new.title, window != nil, !PiKit.Motion.reduced {
            let fade = CATransition(); fade.type = .fade; fade.duration = PiKit.Motion.base
            title.wantsLayer = true; title.layer?.add(fade, forKey: "title")
        }
        title.line = titleLine
        pin.isHidden = !new.pinned
        let showsDot = new.unreadCount > 0 || new.unreadFailure
        dot.failure = new.unreadFailure && new.unreadCount == 0
        if dot.isHidden == showsDot {
            dot.isHidden = !showsDot
            if showsDot, before != nil { dot.popIn() }
        }
        archiveButton.symbol = new.archived ? "arrow.uturn.backward" : "archivebox"
        archiveButton.label = new.archived ? "Restore chat" : "Archive chat"
        archiveButton.setAccessibilityIdentifier(new.archived ? "restoreChat" : "archiveChat")
        chevron.label = new.expanded ? "Hide child chats" : "Show child chats"
        if before?.expanded != new.expanded { rotateChevron(animated: before != nil) }
        if !new.archivable { confirming = false }
        applyControls()
        // Under the title: the figures, or the state.
        if new.stats.hasActivity {
            metrics.isHidden = false; subtitle.isHidden = true
            metrics.update(stats: new.stats, available: new.available)
        } else {
            metrics.isHidden = true; subtitle.isHidden = false
            subtitle.line = PiKit.Line(new.subtitle, font: PiKit.Font.caption, color: .piInkTertiary)
        }
        toolTip = new.help
        row1.relayoutAll()
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    private func applyControls() {
        guard let content else { return }
        archiveButton.isHidden = !content.archivable || confirming
        confirm.isHidden = !content.archivable || !confirming
        keep.isHidden = !content.archivable || !confirming
        chevron.isHidden = !content.hasSide
        controls.isHidden = !content.archivable && !content.hasSide
        // Quiet at rest, solid under the pointer: a control the pointer only
        // strengthens, never conjures.
        PiKit.Motion.layers(PiKit.Motion.quick, animated: window != nil) {
            archiveButton.layer?.opacity = hovering || confirming ? 1 : 0.28
        }
        controls.relayoutAll(); row1.relayoutAll()
    }
    private func setConfirming(_ value: Bool) {
        guard confirming != value else { return }
        confirming = value
        applyControls()
        needsLayout = true
        controlsChanged?()
    }
    /// The fold chevron turns a quarter to the left when the side chats are
    /// hidden (`.rotationEffect`), on the button's content layer.
    private func rotateChevron(animated: Bool) {
        guard let content else { return }
        let angle: CGFloat = content.expanded ? 0 : .pi / 2
        CATransaction.begin()
        if !animated || PiKit.Motion.reduced || window == nil { CATransaction.setDisableActions(true) } else {
            CATransaction.setAnimationDuration(0.18); CATransaction.setAnimationTimingFunction(PiKit.Motion.timing(.easeInOut))
        }
        // The content layer is flipped with its view: a positive angle turns it the way SwiftUI's −90° does.
        chevron.content.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyControls() }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        // Leaving the row puts the question away.
        if confirming { setConfirming(false) } else { applyControls() }
    }

    // MARK: Layout

    private var titleHeight: CGFloat { PiKit.Line("Ag", font: .systemFont(ofSize: 13), color: .black).lineHeight }
    private func row1Height(width: CGFloat) -> CGFloat { row1.height(forWidth: width) }
    private var secondHeight: CGFloat { metrics.isHidden ? subtitle.intrinsicContentSize.height : metrics.height(forWidth: 0) }
    func height(forWidth width: CGFloat) -> CGFloat {
        let text = row1Height(width: max(0, width - 24)) + 2 + secondHeight
        return max(16, text)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 200)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let scale = piScale
        let textWidth = max(0, bounds.width - 24)
        let r1 = row1Height(width: textWidth), r2 = secondHeight
        let total = r1 + 2 + r2
        let top = PiKit.round((bounds.height - total) / 2, scale)
        let iconY = PiKit.round((bounds.height - 16) / 2, scale)
        icon.frame = CGRect(x: 0, y: iconY, width: 16, height: 16)
        spinner?.frame = CGRect(x: 2.5, y: iconY + 2.5, width: 11, height: 11)
        row1.frame = CGRect(x: 24, y: top, width: textWidth, height: r1)
        let second: NSView = metrics.isHidden ? subtitle : metrics
        second.frame = CGRect(x: 24, y: top + r1 + 2, width: textWidth, height: r2)
    }
}
