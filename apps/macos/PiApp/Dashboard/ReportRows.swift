import AppKit

// The rows and cells of the report's grids, split out of `ReportPage.swift`.

/// Column widths shared by the header and rows of the request grid.
enum ReportColumns {
    static let started: CGFloat = 112
    static let session: CGFloat = 150
    static let status: CGFloat = 96
    static let cost: CGFloat = 128
    static let tokens: CGFloat = 150
    /// Extra leading inset for requests listed under their session.
    static let nestedIndent: CGFloat = 32
    static let duration: CGFloat = 78
    static let cache: CGFloat = 116
    static let widths: [CGFloat?] = [started, session, nil, status, cost, tokens, duration, cache]
    static let sessionWidths: [CGFloat?] = [started, nil, 112, cost, tokens, 96, 110, 132]
    static let modelRequests: CGFloat = 132
    static let modelRate: CGFloat = 116
    static let modelFirstToken: CGFloat = 176
    static let modelWidths: [CGFloat?] = [nil, modelRequests, cost, tokens, 96, modelRate, modelFirstToken]
}

/// Row cost without the currency suffix; the column header and help text carry the unit.
func reportUSD(_ value: Double?) -> String {
    guard let value else { return "—" }
    guard value.isFinite, value >= 0 else { return "Cost unavailable" }
    return MetricFormat.exactUSD(value, unit: false)
}

/// Short token counts for tiles and rows: 1.2K, 340K, 2.1M. Rounded half-up,
/// as the pills round the same count (`MetricFormat.tokens`), and a count
/// whose rounding reaches the next step is written at it: 9,960 is `10K`,
/// never `10.0K`, and 999,950 is `1.0M`, never `1000K`.
func reportTokens(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value.rounded() < 1_000 { return String(format: "%.0f", value.rounded()) }
    let thousands = value / 1_000, tenths = (thousands * 10).rounded()
    if tenths < 100 { return String(format: "%.1fK", tenths / 10) }
    if thousands.rounded() < 1_000 { return String(format: "%.0fK", thousands.rounded()) }
    let millions = (value / 1_000_000 * 10).rounded()
    if millions < 10_000 { return String(format: "%.1fM", millions / 10) }
    return String(format: "%.1fB", (value / 1_000_000_000 * 10).rounded() / 10)
}

/// Reasoning is a reported subset of output and cost, never a second charge.
func reportReasoningDetail(_ totals: GatewayTotals) -> String {
    "Reasoning \(reportTokens(totals.tokens?.reasoning)) tokens (\(totals.tokens?.reasoningSamples ?? 0)/\(totals.requests) reported) are counted within output. Reasoning cost \(gatewayUSD(totals.reasoningCostUSD)) (\(totals.reasoningCostSamples ?? 0)/\(totals.requests) reported) is the gateway's reported share and is never added to the total; the two are summed over different requests."
}

/// Lines of text over each other, each one line cut at its end (or the
/// middle), `spacing` apart: a grid cell's `VStack` of `Text`s.
@MainActor final class TextLines: DashView {
    var lines: [PiKit.Line] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(lines.map(\.text).joined(separator: ", ")) } }
    var spacing: CGFloat
    var truncation: CTLineTruncationType = .end
    init(_ lines: [PiKit.Line], spacing: CGFloat = 1) {
        self.lines = lines; self.spacing = spacing
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(lines.map(\.text).joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize {
        let scale = piScale
        let width = lines.map { $0.size(scale: scale).width }.max() ?? 0
        let height = lines.reduce(0) { $0 + $1.lineHeight } + spacing * CGFloat(max(0, lines.count - 1))
        return NSSize(width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 0
        for line in lines {
            line.draw(in: CGRect(x: 0, y: y, width: min(bounds.width, line.size(scale: piScale).width), height: line.lineHeight), truncation: truncation, scale: piScale)
            y += line.lineHeight + spacing
        }
    }
}

/// The header of a grid: its column names, small capitals on the sunken surface.
@MainActor final class ReportGridRow: DashView {
    private let row: ShellStack
    init(cells: [String], widths: [CGFloat?] = ReportColumns.widths) {
        let items: [ShellItem] = cells.enumerated().map { index, cell in
            let text = PiKit.TextLine(PiKit.Line(cell, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
            return .view(text, widths[index].map { .fixed($0) } ?? .fill)
        }
        row = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 8, left: PiSpacing.md, bottom: 8, right: PiSpacing.md), items)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piSurfaceSunken) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: row.height(forWidth: 1_000)) }
    override func layout() { super.layout(); row.frame = bounds }
}

/// A grid row that is one button: a soft fill under the pointer, the
/// pointing hand, its cells laid out in a row.
@MainActor class ReportRowButton: PiKit.ButtonBase {
    let row: ShellStack
    init(row: ShellStack, action: @escaping () -> Void) {
        self.row = row
        super.init(frame: .zero)
        pressScales = false
        onPress = action
        addSubview(row)
        onHover = { [weak self] _ in self?.hoverChanged() }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func hoverChanged() {}
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = hovering ? piCGColor(.piFill) : CGColor.clear; stroke.borderColor = CGColor.clear }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: row.height(forWidth: bounds.width > 0 ? bounds.width : 1_100)) }
    override func layout() { super.layout(); row.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The row's own controls take their clicks; the rest is the row's.
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSControl { return current }
            view = current.superview
        }
        return frame.contains(point) ? self : nil
    }
}

/// One request: when, which chat, requested over final model, how it ended,
/// what it cost and used, how long it took, its cache state and a way to
/// its message.
@MainActor final class ReportRequestRow: ReportRowButton {
    let item: DashboardRequest
    private let messageButton: PiKit.IconButton
    private let chevron = PiKit.SymbolView(PiKit.Symbol("chevron.right", size: 9, weight: .semibold), color: .piInkTertiary)

    init(item: DashboardRequest, title: String?, detailed: Bool, inspect: @escaping () -> Void, message: @escaping () -> Void = {}, nested: Bool = false) {
        self.item = item
        func tokens(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        let mono = PiKit.Font.monospacedDigits(PiKit.Font.caption)
        let purpose = (item.api == "openai-responses" ? "Responses" : "Messages") + " · " + item.purpose
        let tone: PiTone = item.outcome == "completed" ? .success : item.outcome == "failed" ? .danger : item.outcome == "running" ? .warning : .neutral
        let started = PiKit.TextLine(PiKit.Line(item.wall.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()), font: mono, color: .piInkSecondary))
        let session: NSView
        if nested {
            let text = PiKit.TextLine(PiKit.Line(purpose, font: PiKit.Font.caption, color: .piInkSecondary))
            session = text
        } else {
            let first = title.flatMap { $0.isEmpty ? nil : PiKit.Line($0, font: PiKit.Font.caption, color: .piInk) }
                ?? PiKit.Line(String(item.sessionID.prefix(8)) + "…", font: PiKit.Font.mono, color: .piInkSecondary)
            let lines = TextLines([first, PiKit.Line(purpose, font: PiKit.Font.caption, color: .piInkTertiary)])
            lines.truncation = .middle
            lines.toolTip = "Session " + item.sessionID + (title == nil ? " (no chat title known)" : "")
            session = lines
        }
        let route = ModelRouteCell(requested: item.alias, final: item.effectiveModel, reported: item.reportedModels, status: item.identityStatus)
        let badge = PiKit.Badge(text: item.outcome, tone: tone, dot: true)
        var costLines = [PiKit.Line(item.gateway.costUSD == nil ? item.gateway.costStatus : reportUSD(item.gateway.costUSD), font: mono, color: .piInk)]
        if detailed { costLines.append(PiKit.Line("reasoning " + reportUSD(item.gateway.reasoningCostUSD), font: mono, color: .piInkTertiary)) }
        let cost = TextLines(costLines)
        cost.toolTip = "LiteLLM-reported USD cost (\(item.gateway.costStatus)); includes reasoning \(gatewayUSD(item.gateway.reasoningCostUSD)) (\(item.gateway.reasoningCostStatus)). Provider prompt-cache tokens read \(tokens(item.gateway.cacheReadTokens)), write \(tokens(item.gateway.cacheWriteTokens))."
        var tokenLines = [PiKit.Line(item.gateway.inputTokens == nil && item.gateway.outputTokens == nil ? "—" : "↓\(reportTokens(item.gateway.inputTokens)) ↑\(reportTokens(item.gateway.outputTokens))", font: mono, color: .piInk)]
        if item.gateway.reasoningTokens != nil { tokenLines.append(PiKit.Line("\(reportTokens(item.gateway.reasoningTokens)) reasoning", font: mono, color: .piInkTertiary)) }
        if detailed { tokenLines.append(PiKit.Line("cached \(reportTokens(item.gateway.cacheReadTokens)) · uncached \(reportTokens(item.gateway.uncachedInputTokens))", font: mono, color: .piInkTertiary)) }
        let tokenCell = TextLines(tokenLines)
        tokenCell.toolTip = "Input \(tokens(item.gateway.inputTokens)) tokens (cached \(tokens(item.gateway.cacheReadTokens)), not cached \(tokens(item.gateway.uncachedInputTokens))) · output \(tokens(item.gateway.outputTokens)) tokens including \(tokens(item.gateway.reasoningTokens)) reasoning tokens, as reported by the gateway. Reasoning is not added again."
        var durationLines = [PiKit.Line(ms(item.http), font: mono, color: .piInk)]
        if detailed { durationLines.append(PiKit.Line("ttft \(ms(item.ttft))", font: mono, color: .piInkTertiary)) }
        let duration = TextLines(durationLines)
        duration.toolTip = "Whole request \(ms(item.http)) · first token \(ms(item.ttft)) · streaming \(ms(item.streaming))"
        messageButton = PiKit.IconButton(symbol: "text.bubble", label: "Go to the linked message", size: 22, action: message)
        let cacheRow = ShellStack(.horizontal, spacing: 4, [.view(dashboardCacheBadge(item.gateway.cacheStatus)), .spacer(0), .view(messageButton), .view(chevron)])
        cacheRow.toolTip = "LiteLLM response-cache state: " + item.gateway.cacheStatus + ". Separate from provider prompt-cache tokens."
        let leading = nested ? PiSpacing.md + ReportColumns.nestedIndent : PiSpacing.md
        let row = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 7, left: leading, bottom: 7, right: PiSpacing.md), [
            .view(started, .fixed(ReportColumns.started)),
            .view(session, .fixed(nested ? ReportColumns.session - ReportColumns.nestedIndent : ReportColumns.session)),
            .view(route, .fill),
            .view(badge, .fixed(ReportColumns.status)),
            .view(cost, .fixed(ReportColumns.cost)),
            .view(tokenCell, .fixed(ReportColumns.tokens)),
            .view(duration, .fixed(ReportColumns.duration)),
            .view(cacheRow, .fixed(ReportColumns.cache)),
        ])
        super.init(row: row, action: inspect)
        // A badge keeps its own width inside its column.
        badgeHug = badge
        setAccessibilityIdentifier("inspectRequest-" + item.id)
        setAccessibilityLabel("Inspect request from " + item.wall.formatted())
        hoverChanged()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private weak var badgeHug: NSView?
    override func hoverChanged() {
        PiKit.Motion.layers(0.12, animated: !piReducesMotion) {
            messageButton.alphaValue = hovering ? 1 : 0.35
            chevron.alphaValue = hovering ? 1 : 0
        }
    }
    override func layout() {
        super.layout()
        if let badge = badgeHug { let size = badge.intrinsicContentSize; badge.setFrameSize(NSSize(width: min(size.width, ReportColumns.status), height: badge.frame.height)) }
    }
}

/// One requested route in the By model table, with its share of the window's
/// requests and cost, and its own output rate and first-token median.
@MainActor final class ReportModelRow: ReportRowButton {
    let summary: DashboardModelSummary
    init(summary: DashboardModelSummary, allRequests: Int, allCost: Double?, detailed: Bool, filter: @escaping () -> Void) {
        self.summary = summary
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
        let requestShare = allRequests > 0 ? Double(summary.requests) / Double(allRequests) : 0
        var costShare: Double?
        if let cost = summary.gateway.costUSD, let allCost, allCost > 0 { costShare = cost / allCost }
        let mono = PiKit.Font.monospacedDigits(PiKit.Font.caption)
        let route = ModelRouteCell(requested: summary.alias, final: summary.model, reported: [], status: summary.status)
        let requests = ReportShareCell(value: "\(summary.requests)", detail: percent(requestShare) + " of requests" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : ""),
                                       share: requestShare, tone: .piAccent)
        let cost = ReportShareCell(value: summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD),
                                   detail: costShare.map { percent($0) + " of cost" } ?? (summary.gateway.costSamples < summary.requests ? "\(summary.gateway.costSamples)/\(summary.requests) reported" : "no cost reported"),
                                   share: costShare, tone: .piSuccess)
        cost.toolTip = summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway)
        var tokenLines = [PiKit.Line(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—", font: mono, color: .piInk)]
        if summary.gateway.tokens?.reasoning != nil { tokenLines.append(PiKit.Line("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning", font: mono, color: .piInkTertiary)) }
        if detailed { tokenLines.append(PiKit.Line("cached \(reportTokens(summary.gateway.cacheReadTokens))", font: mono, color: .piInkTertiary)) }
        let tokens = TextLines(tokenLines)
        tokens.toolTip = summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway)
        let cache = ReportCacheCell(ratio: summary.gateway.cacheHitRatio)
        cache.toolTip = summary.gateway.cacheLabel
        let rate = TextLines([PiKit.Line(SessionUsagePresentation.rate(summary.gateway.settledThroughput.tokensPerSecond), font: mono, color: .piInk),
                              PiKit.Line("\(summary.gateway.settledThroughput.samples)/\(summary.requests) measured", font: mono, color: .piInkTertiary)])
        rate.toolTip = SettledThroughput.explanation
        let first = TextLines([PiKit.Line("p50 " + ms(summary.ttftP50), font: mono, color: .piInk),
                               PiKit.Line(summary.ttftSamples > 0 ? "HTTP \(ms(summary.httpP50)) · \(summary.ttftSamples) measured" : "not measured", font: mono, color: .piInkTertiary)])
        first.toolTip = "Nearest-rank medians for this route: first token and whole request."
        let row = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .top, padding: NSEdgeInsets(top: 8, left: PiSpacing.md, bottom: 8, right: PiSpacing.md), [
            .view(route, .fill),
            .view(requests, .fixed(ReportColumns.modelRequests)),
            .view(cost, .fixed(ReportColumns.cost)),
            .view(tokens, .fixed(ReportColumns.tokens)),
            .view(cache, .fixed(96)),
            .view(rate, .fixed(ReportColumns.modelRate)),
            .view(first, .fixed(ReportColumns.modelFirstToken)),
        ])
        super.init(row: row, action: filter)
        setAccessibilityLabel("Route \(summary.alias), \(summary.resolutionLabel), \(summary.requests) requests")
        setAccessibilityIdentifier("reportModelRow-" + summary.alias)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

/// A figure, a share capsule under it, and what the share is of.
@MainActor final class ReportShareCell: DashView {
    let value: PiKit.Line, detail: PiKit.Line
    let bar: PiKit.ShareBar
    init(value: String, detail: String, share: Double?, tone: NSColor) {
        self.value = PiKit.Line(value, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk)
        self.detail = PiKit.Line(detail, font: PiKit.Font.micro, color: .piInkTertiary)
        bar = PiKit.ShareBar(fraction: share ?? 0, tone: tone)
        super.init(frame: .zero)
        addSubview(bar)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(value + ", " + detail)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: value.lineHeight + 3 + 4 + 3 + detail.lineHeight) }
    override func layout() { super.layout(); bar.frame = CGRect(x: 0, y: value.lineHeight + 3, width: bounds.width, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        value.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: value.lineHeight), scale: piScale)
        detail.draw(in: CGRect(x: 0, y: value.lineHeight + 3 + 4 + 3, width: bounds.width, height: detail.lineHeight), scale: piScale)
    }
}

/// The cache hit ratio: a small ring and its percentage, or a dash.
@MainActor final class ReportCacheCell: DashView {
    private let ring: PiKit.Ring?
    private let text: PiKit.Line
    init(ratio: Double?) {
        ring = ratio.map { PiKit.Ring(fraction: $0, size: 10) }
        text = PiKit.Line(ratio.map { String(format: "%.0f%%", $0 * 100) } ?? "—", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk)
        super.init(frame: .zero)
        if let ring { addSubview(ring) }
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text.text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: max(text.lineHeight, ring == nil ? 0 : 10)) }
    override func layout() {
        super.layout()
        ring?.frame = CGRect(x: 0, y: PiKit.round((bounds.height - 10) / 2, piScale), width: 10, height: 10)
    }
    override func draw(_ dirtyRect: NSRect) {
        let x: CGFloat = ring == nil ? 0 : 15
        text.draw(at: CGPoint(x: x, y: PiKit.round((bounds.height - text.lineHeight) / 2, piScale)), scale: piScale)
    }
}

/// Requested alias over the model the gateway actually served, so routing is
/// readable at a glance: the same model, a different route, or no report.
@MainActor final class ModelRouteCell: DashView {
    private let requested = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInk))
    private let finalLine = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInk))
    private let branch = PiKit.SymbolView(PiKit.Symbol("arrow.triangle.branch", size: 9, weight: .semibold), color: .piAccent)
    private var finalLabel: FinalModelLabel?
    private let routed: Bool
    private let requestedTag = PiKit.TextLine(PiKit.Line("requested", font: PiKit.Font.micro, color: .piInkTertiary))
    private let finalTag = PiKit.TextLine(PiKit.Line("final", font: PiKit.Font.micro, color: .piInkTertiary))
    init(requested: String, final: String?, reported: [String], status: String) {
        routed = final != nil && final != requested
        super.init(frame: .zero)
        self.requested.line.text = requested; self.requested.truncation = .middle
        if let final {
            finalLine.line = PiKit.Line(final == requested ? "same model" : final, font: PiKit.Font.caption, color: routed ? .piInk : .piInkSecondary)
            finalLine.truncation = .middle
            addSubview(finalLine)
        } else {
            let label = FinalModelLabel(final: nil, reported: reported, status: status)
            finalLabel = label
            addSubview(label)
        }
        for view in [requestedTag, finalTag, self.requested] as [NSView] { addSubview(view) }
        if routed { addSubview(branch) }
        toolTip = final.map { "Requested \(requested); the gateway served \($0)." } ?? "Requested \(requested); the gateway did not report one model that served it (\(status))."
        setAccessibilityElement(false)
        setAccessibilityLabel("Requested \(requested)")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var firstHeight: CGFloat { max(requestedTag.intrinsicContentSize.height, requested.intrinsicContentSize.height) }
    private var secondHeight: CGFloat {
        let text = finalLabel.map { PiKit.height(of: $0, width: 200) } ?? finalLine.intrinsicContentSize.height
        return max(finalTag.intrinsicContentSize.height, text)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: firstHeight + 1 + secondHeight) }
    override func layout() {
        super.layout()
        let scale = piScale
        let first = firstHeight
        func put(_ view: NSView, x: CGFloat, y: CGFloat, height: CGFloat, maxWidth: CGFloat) {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: PiKit.round(y + (height - size.height) / 2, scale), width: max(0, min(size.width, maxWidth)), height: size.height)
        }
        put(requestedTag, x: 0, y: 0, height: first, maxWidth: 58)
        put(requested, x: 63, y: 0, height: first, maxWidth: bounds.width - 63)
        let y = first + 1
        put(finalTag, x: 0, y: y, height: finalTag.intrinsicContentSize.height, maxWidth: 58)
        var x: CGFloat = 63
        if routed {
            let size = branch.intrinsicContentSize
            branch.frame = CGRect(x: x, y: y + PiKit.round((finalLine.intrinsicContentSize.height - size.height) / 2, scale), width: size.width, height: size.height)
            x += size.width + 5
        }
        if let finalLabel {
            let width = bounds.width - x
            finalLabel.frame = CGRect(x: x, y: y, width: width, height: PiKit.height(of: finalLabel, width: width))
        } else {
            put(finalLine, x: x, y: y, height: finalLine.intrinsicContentSize.height, maxWidth: bounds.width - x)
        }
    }
}

/// The gateway's final model. Agreeing reports show one name; conflicting
/// reports show the shortest name by default and reveal every reported name
/// on click, since the longer ones are usually the same model with a
/// provider prefix or date suffix.
@MainActor final class FinalModelLabel: DashView, PiKit.WidthSizing {
    let final: String?
    let reported: [String]
    let status: String
    let font: NSFont
    /// The other reported names shown; a row made again for new figures keeps it.
    var revealed = false {
        didSet {
            guard revealed != oldValue else { return }
            button.redrawContent(); invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
            // The names open and close with the page moving round them (`.easeInOut(duration: 0.16)`).
            guard window != nil, !piReducesMotion else { PiKit.sizeChanged(self); return }
            DashMotion.reflow(duration: 0.16, timing: .easeInEaseOut) {
                PiKit.sizeChanged(self)
                self.window?.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }
    private var conflict: Bool { final == nil && reported.count > 1 }
    private lazy var button = Reveal(owner: self)
    var text: String {
        if let final { return final }
        if let primary = dashboardPrimaryModel(reported) { return primary }
        switch status {
        case "conflict": return "conflicting reports"
        case "incomplete": return "partial report"
        default: return "—"
        }
    }
    /// A gateway that echoed no final model is routine, so the dash is quiet; only conflicts are warnings.
    private var routineUnreported: Bool { final == nil && !conflict && !["conflict", "incomplete"].contains(status) && reported.isEmpty }
    private var tone: NSColor {
        if routineUnreported { return .piInkTertiary }
        if final != nil || conflict { return .piInk }
        return status == "conflict" ? .piDanger : .piWarning
    }
    init(final: String?, reported: [String], status: String, font: NSFont = PiKit.Font.caption) {
        self.final = final; self.reported = reported; self.status = status; self.font = font
        super.init(frame: .zero)
        if conflict {
            addSubview(button)
            button.toolTip = "The gateway reported \(reported.count) model names for this request: \(reported.joined(separator: ", ")). Click to show or hide all of them."
            button.setAccessibilityLabel("Final model \(text), \(reported.count) reported names")
            button.setAccessibilityHelp("Shows every reported name")
            button.setAccessibilityIdentifier("finalModelReveal")
        } else {
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Final model \(text)")
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var others: [String] { reported.filter { $0 != text } }
    fileprivate var badgeText: String { revealed ? "hide" : "+\(reported.count - 1)" }
    private var lineHeight: CGFloat { PiKit.Line("Ag", font: font, color: .black).lineHeight }
    func height(forWidth width: CGFloat) -> CGFloat {
        guard conflict else { return lineHeight }
        let first = max(lineHeight, PiKit.Line("Ag", font: PiKit.Font.micro, color: .black).lineHeight + 2)
        return first + (revealed ? CGFloat(others.count) * (lineHeight + 1) : 0)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: PiKit.Line(text, font: font, color: .black).size(scale: piScale).width + (conflict ? 4 + 30 : 0), height: height(forWidth: 200))
    }
    fileprivate func toggle() { revealed.toggle() }
    override func layout() { super.layout(); if conflict { button.frame = bounds } }
    override func draw(_ dirtyRect: NSRect) {
        guard !conflict else { return }
        let line = PiKit.Line(text, font: font, color: tone)
        line.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: line.lineHeight), truncation: .middle, scale: piScale)
    }
    /// The name, a "+n"/"hide" capsule, and the other names while revealed.
    final class Reveal: PiKit.ButtonBase {
        weak var owner: FinalModelLabel?
        init(owner: FinalModelLabel) { self.owner = owner; super.init(frame: .zero); pressScales = false; onPress = { [weak owner] in owner?.toggle() } }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            guard let owner else { return }
            let scale = piScale
            let name = PiKit.Line(owner.text, font: owner.font, color: .piInk)
            let badge = PiKit.Line(owner.badgeText, font: PiKit.Font.micro, color: .piWarning)
            let badgeSize = badge.size(scale: scale)
            let badgeBox = CGSize(width: badgeSize.width + 10, height: badgeSize.height + 2)
            let firstHeight = max(name.lineHeight, badgeBox.height)
            let nameWidth = min(name.size(scale: scale).width, max(0, rect.width - 4 - badgeBox.width))
            name.draw(in: CGRect(x: 0, y: PiKit.round((firstHeight - name.lineHeight) / 2, scale), width: nameWidth, height: name.lineHeight), truncation: .middle, scale: scale)
            let box = CGRect(x: nameWidth + 4, y: PiKit.round((firstHeight - badgeBox.height) / 2, scale), width: badgeBox.width, height: badgeBox.height)
            NSColor.piWarning.piOpacity(0.14).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            badge.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 1), scale: scale)
            var y = firstHeight + 1
            for other in owner.others where owner.revealed {
                let line = PiKit.Line(other, font: owner.font, color: .piInkSecondary)
                line.draw(in: CGRect(x: 0, y: y, width: rect.width, height: line.lineHeight), truncation: .middle, scale: scale)
                y += line.lineHeight + 1
            }
        }
    }
}

/// A filter's pill: its symbol, the chosen value cut in the middle at 230
/// points, and the up-down chevron, on the surface in a hairline capsule;
/// it opens the choice list.
@MainActor final class ReportDropdown: PiKit.ButtonBase {
    var items: [(String, String)] { didSet { if !oldValue.elementsEqual(items, by: ==) { refreshLabel() } } }
    var selection: String { didSet { if oldValue != selection { refreshLabel() } } }
    let icon: String
    var onSelect: ((String) -> Void)?
    private var popover: NSPopover?
    private(set) var list: PiKit.ChoiceList<String>?
    private var current: String { items.first { $0.0 == selection }?.1 ?? selection }
    init(selection: String, items: [(String, String)], icon: String, onSelect: @escaping (String) -> Void) {
        self.items = items; self.selection = selection; self.icon = icon; self.onSelect = onSelect
        super.init(frame: .zero)
        pressScales = false
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = { [weak self] in self?.toggleChoices() }
        refreshLabel()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func refreshLabel() {
        toolTip = current; setAccessibilityLabel("Filter"); setAccessibilityValue(current)
        invalidateIntrinsicContentSize(); redrawContent()
        // An open list shows the choices there are now, not the ones it opened with.
        if popover?.isShown == true { list?.update(selection: selection, choices: items.map { PiKit.Choice(id: $0.0, title: $0.1) }) }
    }
    private var text: PiKit.Line { PiKit.Line(current, font: .systemFont(ofSize: 12, weight: .medium), color: .piInk) }
    private var glyph: PiKit.Symbol { PiKit.Symbol(icon, size: 11, weight: .semibold) }
    private var chevron: PiKit.Symbol { PiKit.Symbol("chevron.up.chevron.down", size: 9, weight: .semibold) }
    private var textWidth: CGFloat { min(230, text.size(scale: piScale).width) }
    override var intrinsicContentSize: NSSize {
        let height = max(text.lineHeight, glyph.layoutSize.height, chevron.layoutSize.height)
        return NSSize(width: 10 + glyph.layoutSize.width + 6 + textWidth + 6 + chevron.layoutSize.width + 10, height: height + 10)
    }
    override func cornerRadius(for size: CGSize) -> CGFloat { size.height / 2 }
    override func styleFace() { fill.backgroundColor = piCGColor(.piSurface); stroke.borderColor = piCGColor(.piHairlineStrong) }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        var x: CGFloat = 10
        let g = glyph.layoutSize
        glyph.draw(centredIn: CGRect(x: x, y: 0, width: g.width, height: rect.height), color: .piInkSecondary, scale: scale)
        x += g.width + 6
        text.draw(in: CGRect(x: x, y: PiKit.round((rect.height - text.lineHeight) / 2, scale), width: textWidth, height: text.lineHeight), truncation: .middle, scale: scale)
        x += textWidth + 6
        chevron.draw(centredIn: CGRect(x: x, y: 0, width: chevron.layoutSize.width, height: rect.height), color: .piInkTertiary, scale: scale)
    }
    func toggleChoices() {
        if let popover, popover.isShown { popover.close(); return }
        guard window != nil else { return }
        let list = PiKit.ChoiceList(title: "Filter", selection: selection, choices: items.map { PiKit.Choice(id: $0.0, title: $0.1) },
                                    choose: { [weak self] value in
                                        guard let self else { return }
                                        self.popover?.close()
                                        guard self.items.contains(where: { $0.0 == value }) else { return }
                                        self.onSelect?(value)
                                    }, cancel: { [weak self] in self?.popover?.close() })
        self.list = list
        let popover = PiKit.popover(list)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        list.window?.makeFirstResponder(list)
    }
}

/// One session (chat) aggregate with an expander for its requests.
@MainActor final class ReportSessionRow: ReportRowButton {
    let summary: DashboardSessionSummary
    private let chevron = ExpandChevron()
    init(summary: DashboardSessionSummary, title: String?, workspace: String?, available: Bool, expanded: Bool, detailed: Bool,
         toggle: @escaping () -> Void, open: @escaping () -> Void) {
        self.summary = summary
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        let connectionCheck = !available && summary.sessionID.hasPrefix("connection-test-")
        let mono = PiKit.Font.monospacedDigits(PiKit.Font.caption)
        chevron.expanded = expanded
        let last = PiKit.TextLine(PiKit.Line(summary.last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()), font: mono, color: .piInkSecondary))
        let started = ShellStack(.horizontal, spacing: 6, [.view(chevron), .view(last)])
        let name: PiKit.Line
        if connectionCheck { name = PiKit.Line("Connection check", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piInk) }
        else if let title, !title.isEmpty { name = PiKit.Line(title, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piInk) }
        else { name = PiKit.Line(String(summary.sessionID.prefix(8)) + "…", font: PiKit.Font.mono, color: .piInkSecondary) }
        let nameLine = PiKit.TextLine(name); nameLine.truncation = .middle
        var nameItems: [ShellItem] = [.view(nameLine, .flexible)]
        if !available && !connectionCheck { nameItems.append(.view(PiKit.Badge(text: "chat unavailable", tone: .warning, icon: "exclamationmark.triangle"))) }
        let where_ = PiKit.TextLine(PiKit.Line((workspace ?? "unknown project") + " · " + summary.sessionID, font: PiKit.Font.caption, color: .piInkTertiary))
        where_.truncation = .middle
        let session = ShellStack(.vertical, spacing: 1, [.view(ShellStack(.horizontal, spacing: 6, nameItems), .fill), .view(where_, .fill)])
        session.toolTip = connectionCheck ? "Onboarding tested the selected model without creating a chat. Expand to inspect its request." : available ? "Session " + summary.sessionID : "This chat was deleted or was an unkept side conversation; its retained requests remain here."
        let requests = TextLines([PiKit.Line("\(summary.requests)", font: mono, color: .piInk),
                                  PiKit.Line("\(summary.completed) ok" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : "") + (summary.running > 0 ? " · \(summary.running) running" : ""),
                                             font: mono, color: summary.problems > 0 ? .piWarning : .piInkTertiary)])
        var costLines = [PiKit.Line(summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD), font: mono, color: .piInk)]
        if detailed { costLines.append(PiKit.Line("reasoning " + reportUSD(summary.gateway.reasoningCostUSD), font: mono, color: .piInkTertiary)) }
        let cost = TextLines(costLines)
        cost.toolTip = summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway)
        var tokenLines = [PiKit.Line(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—", font: mono, color: .piInk)]
        if summary.gateway.tokens?.reasoning != nil { tokenLines.append(PiKit.Line("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning", font: mono, color: .piInkTertiary)) }
        if detailed { tokenLines.append(PiKit.Line("cached \(reportTokens(summary.gateway.cacheReadTokens))", font: mono, color: .piInkTertiary)) }
        let tokens = TextLines(tokenLines)
        tokens.toolTip = summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway)
        let cache = ReportCacheCell(ratio: summary.gateway.cacheHitRatio)
        cache.toolTip = summary.gateway.cacheLabel
        let latency = PiKit.TextLine(PiKit.Line("ttft \(ms(summary.ttftP50)) · \(ms(summary.httpP50))", font: mono, color: .piInkSecondary))
        latency.toolTip = "Nearest-rank medians for this session: first token and whole request"
        let action: NSView
        if connectionCheck {
            action = PiKit.TextLine(PiKit.Line("Setup check", font: PiKit.Font.caption, color: .piInkTertiary))
        } else {
            let button = PiKit.Button("Open chat", symbol: "arrow.right.circle", style: .secondary, compact: true, action: open)
            button.isEnabled = available
            action = button
        }
        let actionRow = ShellStack(.horizontal, spacing: 4, [.spacer(0), .view(action)])
        let row = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 7, left: PiSpacing.md, bottom: 7, right: PiSpacing.md), [
            .view(started, .fixed(ReportColumns.started)),
            .view(session, .fill),
            .view(requests, .fixed(150)),
            .view(cost, .fixed(ReportColumns.cost)),
            .view(tokens, .fixed(ReportColumns.tokens)),
            .view(cache, .fixed(96)),
            .view(latency, .fixed(120)),
            .view(actionRow, .fixed(132)),
        ])
        super.init(row: row, action: toggle)
        setAccessibilityLabel((connectionCheck ? "Connection check" : "Session " + (title ?? summary.sessionID)) + ", \(summary.requests) requests")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

/// A 9-point chevron that turns to point down while its row is open.
@MainActor final class ExpandChevron: DashView {
    var expanded = false { didSet { if expanded != oldValue { turn(animated: window != nil) } } }
    private let symbol = PiKit.Symbol("chevron.right", size: 9, weight: .semibold)
    var color: NSColor = .piInkTertiary { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { symbol.layoutSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let turned = progress ?? (expanded ? 1 : 0)
        if turned > 0 {
            context.translateBy(x: bounds.midX, y: bounds.midY); context.rotate(by: .pi / 2 * turned); context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        symbol.draw(centredIn: bounds, color: color, scale: piScale)
        context.restoreGState()
    }
    private func turn(animated: Bool) { needsDisplay = true }
    /// The quarter turn drawn so far, 0 closed to 1 open, while it turns.
    private var progress: CGFloat?
    private var turning: Timer?
    /// Turns from `wasExpanded` to where it is now over 0.16 s, eased (`.easeInOut(duration: 0.16)`).
    /// The quarter turn drawn now: mid-turn while turning.
    var drawnTurn: CGFloat { progress ?? (expanded ? 1 : 0) }
    /// Turns from the angle `from` (0 closed, 1 open; another row's turn
    /// mid-way when interrupted) to where it is now.
    func turn(from: CGFloat) {
        let to: CGFloat = expanded ? 1 : 0
        guard from != to else { return }
        turning?.invalidate()
        let start = CACurrentMediaTime()
        progress = from
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                let t = min(1, (CACurrentMediaTime() - start) / 0.16)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                self.progress = from + (to - from) * CGFloat(eased)
                if t >= 1 { self.progress = nil; self.turning = nil }
                self.needsDisplay = true
                return t >= 1
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        turning = timer
        needsDisplay = true
    }
}
