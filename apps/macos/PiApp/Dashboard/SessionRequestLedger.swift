import AppKit

/// One retained request as the ledger writes it: what it was, where it went,
/// what it consumed and how fast it decoded. Every cell is a reported figure
/// or an explicit gap; nothing is averaged or inferred across requests.
struct SessionRequestLedgerRow: Identifiable, Equatable {
    let id: String
    /// 1 for the oldest request in the displayed history window.
    let number: Int
    let wall: Date
    let status: String
    let model: String
    /// Input as billed, with what of it was served from cache and what was new.
    let input: String
    let inputDetail: String?
    let output: String
    let outputDetail: String?
    let ttft: String
    /// Decode span: first generated token to last.
    let generation: String
    let throughput: String
    let cost: String
    /// True when this request has no decode speed — no completed span of at
    /// least 250 ms, or fewer than two output tokens — so it contributes
    /// nothing to the settled rate.
    let unmeasured: Bool

    init(number: Int, sample: SessionTimingSample) {
        id = sample.id; self.number = number; wall = sample.wall
        status = sample.outcome.isEmpty ? "unknown" : sample.outcome
        model = [sample.model, sample.api.isEmpty ? nil : sample.api].compactMap { $0 }.first ?? "Unreported"
        input = sample.inputTokens.map(MetricFormat.exactTokens) ?? "—"
        // "12,000 cached · 3,800 new" — the two halves of what was billed.
        var parts: [String] = []
        if let cached = sample.cacheReadTokens { parts.append(MetricFormat.exactTokens(cached) + " cached") }
        if let uncached = sample.uncachedInputTokens { parts.append(MetricFormat.exactTokens(uncached) + " new") }
        if let write = sample.cacheWriteTokens, write > 0 { parts.append(MetricFormat.exactTokens(write) + " written") }
        inputDetail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        output = sample.outputTokens.map(MetricFormat.exactTokens) ?? "—"
        outputDetail = sample.reasoningTokens.map { MetricFormat.exactTokens($0) + " reasoning" }
        ttft = sample.ttftMilliseconds.map(MetricFormat.latency) ?? "—"
        generation = sample.streamingMilliseconds.map(MetricFormat.latency) ?? "—"
        throughput = sample.settledTokensPerSecond.map(MetricFormat.throughput) ?? "—"
        cost = sample.costUSD.map { gatewayUSD($0).replacingOccurrences(of: " USD", with: "") } ?? "—"
        unmeasured = sample.settledTokensPerSecond == nil
    }

    /// One line of this row, for a copy action and for the row's accessibility.
    var line: String {
        "Request \(number) · \(status) · \(model) · in \(input) · out \(output) · TTFT \(ttft) · generation \(generation) · \(throughput) · \(cost)"
    }
}

/// The whole ledger, and what it has to say about its own coverage.
struct SessionRequestLedger: Equatable {
    let rows: [SessionRequestLedgerRow]
    let hasOlderRequests: Bool
    let throughput: SettledThroughput

    init(history: SessionTimingHistory) {
        let samples = history.ledgerSamples ?? history.samples
        rows = samples.enumerated().map { SessionRequestLedgerRow(number: $0.offset + 1, sample: $0.element) }
        hasOlderRequests = history.hasOlderLedgerRequests ?? history.hasOlderRequests
        var rate = SettledThroughput()
        for sample in samples {
            rate.add(decodeMilliseconds: sample.outcome == "completed" ? sample.streamingMilliseconds : nil, outputTokens: sample.outputTokens)
        }
        throughput = rate
    }

    var subtitle: String {
        let count = "\(rows.count) request\(rows.count == 1 ? "" : "s")"
        return hasOlderRequests ? "Most recent \(count)" : count
    }
    /// Named, not counted away: the requests with no decode speed are listed
    /// but excluded from the rate.
    var coverageNote: String {
        let missing = rows.filter(\.unmeasured).count
        let rate = throughput.label ?? "unavailable"
        if missing == 0 {
            return "Session throughput \(rate) — every listed request was measured: output tokens after the first over first to last token."
        }
        let subject = missing == 1 ? "1 request has" : "\(missing) requests have"
        let verb = missing == 1 ? "is" : "are"
        return "Session throughput \(rate) over \(throughput.samples) of \(rows.count) listed requests. \(subject) no decode speed — no completed span of \(SettledThroughput.floorLabel) or more, or fewer than two output tokens — and \(verb) excluded from the rate rather than counted as zero."
    }
    var copyText: String {
        (["#\tStatus\tModel\tInput\tOutput\tTTFT\tGeneration\tThroughput\tCost"]
         + rows.map { [String($0.number), $0.status, $0.model, $0.input, $0.output, $0.ttft, $0.generation, $0.throughput, $0.cost].joined(separator: "\t") }
         + [coverageNote]).joined(separator: "\n")
    }
}

/// Every retained request, oldest first. Row views are created only where
/// this ledger meets its page's viewport, preserving the lazy Overview.
@MainActor final class SessionRequestLedgerView: DashView, PiKit.WidthSizing {
    private(set) var ledger: SessionRequestLedger
    let open: ((String) -> Void)?
    let limit: Int?
    let rows: SessionLedgerRows
    private let content: ShellStack
    private let box: PiKit.Box
    private let heading: DashSectionHeader
    private let coverage: ShellText
    init(ledger: SessionRequestLedger, open: ((String) -> Void)? = nil, limit: Int? = nil) {
        self.ledger = ledger; self.open = open; self.limit = limit
        let shown = Array(limit.map { ledger.rows.suffix(max(0, $0)) } ?? ledger.rows[...])
        rows = SessionLedgerRows(rows: shown, open: open)
        let content = ShellStack(.vertical, spacing: PiSpacing.sm)
        self.content = content
        box = PiKit.card(content, padding: PiSpacing.md)
        let copy = PiKit.Button("Copy", symbol: "doc.on.doc", style: .secondary, compact: true)
        copy.setAccessibilityIdentifier("session-ledger-copy")
        let subtitle = shown.count < ledger.rows.count ? "Latest \(shown.count) of \(ledger.rows.count) · every request is in the list on the left" : ledger.subtitle
        heading = DashSectionHeader("Requests", subtitle: subtitle, accessory: copy)
        coverage = ShellText(ledger.coverageNote, font: PiKit.Font.micro, color: .piInkTertiary)
        super.init(frame: .zero); addSubview(box)
        copy.onPress = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.ledger.copyText, forType: .string)
        }
        var items: [ShellItem] = [.view(heading, .fill)]
        if shown.isEmpty { items.append(.view(SessionStatsEmptyLine("No requests with retained metrics yet.", color: .piInkSecondary), .fill)) }
        else { items += [.view(SessionStatsTableHeader(SessionLedgerRows.columns), .fill), .view(rows, .fill)] }
        coverage.setAccessibilityIdentifier("session-ledger-coverage")
        items.append(.view(coverage, .fill)); content.items = items
        setAccessibilityIdentifier("session-request-ledger")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// A settled request updates values without replacing the scroll document.
    func update(ledger: SessionRequestLedger) {
        guard self.ledger != ledger else { return }
        self.ledger = ledger
        let shown = Array(limit.map { ledger.rows.suffix(max(0, $0)) } ?? ledger.rows[...])
        rows.reload(shown)
        heading.setSubtitle(shown.count < ledger.rows.count ? "Latest \(shown.count) of \(ledger.rows.count) · every request is in the list on the left" : ledger.subtitle)
        coverage.set(ledger.coverageNote, color: .piInkTertiary)
        if shown.isEmpty {
            content.items = [.view(heading, .fill), .view(SessionStatsEmptyLine("No requests with retained metrics yet.", color: .piInkSecondary), .fill), .view(coverage, .fill)]
        } else if !content.items.contains(where: { $0.view === rows }) {
            content.items = [.view(heading, .fill), .view(SessionStatsTableHeader(SessionLedgerRows.columns), .fill), .view(rows, .fill), .view(coverage, .fill)]
        }
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { box.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 1_080)) }
    override func layout() { super.layout(); box.frame = bounds }
}

/// A lazy column inside the outer scroll document, without another scroll
/// view. Sizes are cheap values; the actual rows are retained only in view.
@MainActor final class SessionLedgerRows: DashView, PiKit.WidthSizing {
    static let columns: [(String, CGFloat?)] = [("#", 30), ("Status", 88), ("Model", nil), ("Input", 122), ("Output", 108), ("TTFT", 64), ("Generation", 82), ("Throughput", 86), ("Cost", 92)]
    private(set) var rows: [SessionRequestLedgerRow]
    let open: ((String) -> Void)?
    private var measuredWidth: CGFloat = -1
    private var offsets: [CGFloat] = [], heights: [CGFloat] = []
    private var totalHeight: CGFloat = 0
    private(set) var made: [Int: SessionLedgerRowView] = [:]
    private var boundsObserver: NSObjectProtocol?
    private weak var observedClip: NSClipView?
    private var accessible: [NSAccessibilityElement]?
    init(rows: [SessionRequestLedgerRow], open: ((String) -> Void)?) {
        self.rows = rows; self.open = open; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel("Requests")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    func reload(_ rows: [SessionRequestLedgerRow]) {
        guard self.rows != rows else { return }
        let old = Dictionary(uniqueKeysWithValues: made.values.map { ($0.row.id, $0) })
        var next: [Int: SessionLedgerRowView] = [:]
        for (index, row) in rows.enumerated() {
            if let view = old[row.id], view.row == row { next[index] = view }
        }
        for view in made.values where !next.values.contains(where: { $0 === view }) { view.removeFromSuperview() }
        made = next; self.rows = rows; measuredWidth = -1; accessible = nil
        invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
        tileRows()
    }
    private func measure(_ width: CGFloat) {
        guard width != measuredWidth else { return }
        measuredWidth = width; offsets = []; heights = []; var y: CGFloat = 0
        for row in rows {
            let height = 1 + PiSpacing.sm + SessionLedgerRowView.height(row)
            offsets.append(y); heights.append(height); y += height + PiSpacing.sm
        }
        totalHeight = rows.isEmpty ? 0 : y - PiSpacing.sm
    }
    func height(forWidth width: CGFloat) -> CGFloat { measure(width); return totalHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeClip(); tileRows() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeClip() }
    private func observeClip() {
        let clip = enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }; boundsObserver = nil; observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tileRows() }
            }
        }
    }
    override func layout() { super.layout(); observeClip(); tileRows() }
    func tileRows() {
        guard window != nil, bounds.width > 0 else { return }
        measure(bounds.width)
        let visible = visibleRect
        var keep: Set<Int> = []
        if !visible.isEmpty {
            let extent = visible.insetBy(dx: 0, dy: -80)
            for index in rows.indices where offsets[index] <= extent.maxY && offsets[index] + heights[index] >= extent.minY {
                let view = made[index] ?? SessionLedgerRowView(row: rows[index], open: open)
                if made[index] == nil { made[index] = view; addSubview(view) }
                view.frame = CGRect(x: 0, y: offsets[index], width: bounds.width, height: heights[index]); keep.insert(index)
            }
        }
        // Keep a focused row until focus leaves it; resize/scroll must not drop the keyboard.
        if let focused = window?.firstResponder as? NSView {
            for (index, view) in made where focused === view || focused.isDescendant(of: view) { keep.insert(index) }
        }
        for (index, view) in made where !keep.contains(index) { view.removeFromSuperview(); made[index] = nil }
    }
    override func accessibilityChildren() -> [Any]? {
        if let accessible { return accessible }
        let elements: [NSAccessibilityElement] = rows.indices.map { index in
            let row = SessionLedgerAccessibleRow(owner: self, index: index)
            row.setAccessibilityRole(open == nil ? .group : .button)
            row.setAccessibilityLabel(rows[index].line); row.setAccessibilityParent(self)
            measure(bounds.width)
            row.setAccessibilityFrameInParentSpace(CGRect(x: 0, y: offsets[index], width: bounds.width, height: heights[index]))
            return row
        }
        accessible = elements; return elements
    }
}

@MainActor private final class SessionLedgerAccessibleRow: NSAccessibilityElement {
    weak var owner: SessionLedgerRows?
    let index: Int
    init(owner: SessionLedgerRows, index: Int) { self.owner = owner; self.index = index; super.init() }
    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let owner, let open = owner.open, owner.rows.indices.contains(index) else { return false }
            open(owner.rows[index].id); return true
        }
    }
}

/// One row's whole press target, with a separator above it. The figures are
/// drawn as text rather than 20 cells; only the pointer fill is a layer.
@MainActor final class SessionLedgerRowView: PiKit.ButtonBase {
    let row: SessionRequestLedgerRow
    init(row: SessionRequestLedgerRow, open: ((String) -> Void)?) {
        self.row = row; super.init(frame: .zero)
        SessionStatsRenderCount.ledgerRowBuilt(); pressScales = false; showsPointer = open != nil
        onPress = { open?(row.id) }; isEnabled = true
        setAccessibilityRole(open == nil ? .group : .button); setAccessibilityLabel(row.line)
        toolTip = open == nil ? row.model : "Open request \(row.number)"
        refreshFace(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { showsPointer && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { showsPointer && super.canBecomeKeyView }
    override func cornerRadius(for size: CGSize) -> CGFloat { 6 }
    override func styleFace() { fill.backgroundColor = showsPointer && (hovering || isPressedDown) ? piCGColor(.piFill) : CGColor.clear; stroke.borderColor = CGColor.clear }
    override func layout() {
        super.layout()
        // The separator and its eight-point gap are outside the row's hover fill.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 1 + PiSpacing.sm, width: bounds.width, height: max(0, bounds.height - 1 - PiSpacing.sm))
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.y >= 1 + PiSpacing.sm ? super.hitTest(point) : nil
    }
    static func height(_ row: SessionRequestLedgerRow) -> CGFloat {
        let font = PiKit.Font.monospacedDigits(PiKit.Font.micro)
        func cell(_ detail: String?, _ width: CGFloat) -> CGFloat {
            let caption = PiKit.Line("Ag", font: PiKit.Font.caption, color: .piInk).lineHeight
            return caption + (detail.map { 1 + CGFloat(min(2, ShellWrap.ranges($0, font: font, width: width).count)) * PiKit.Line("Ag", font: font, color: .piInk).lineHeight } ?? 0)
        }
        return max(cell(row.wall.formatted(date: .omitted, time: .standard), 88), cell(row.inputDetail, 122), cell(row.outputDetail, 108), cell(row.unmeasured ? "not measured" : nil, 86)) + 10
    }
    override func drawContent(in rect: CGRect) {
        NSColor.piHairline.setFill(); CGRect(x: 0, y: 0, width: rect.width, height: 1).fill()
        let widths = SessionStatsTableHeader.widths(SessionLedgerRows.columns, total: rect.width)
        let texts = [String(row.number), row.status, row.model, row.input, row.output, row.ttft, row.generation, row.throughput, row.cost]
        let details: [String?] = [nil, row.wall.formatted(date: .omitted, time: .standard), nil, row.inputDetail, row.outputDetail, nil, nil, row.unmeasured ? "not measured" : nil, nil]
        var x: CGFloat = 0; let y: CGFloat = 1 + PiSpacing.sm + 5
        for index in texts.indices {
            let font = index == 1 || index == 2 ? PiKit.Font.caption : PiKit.Font.monospacedDigits(PiKit.Font.caption)
            let tone: NSColor = index == 0 ? .piInkTertiary : (index == 1 && row.status != "completed" ? .piWarning : .piInk)
            let line = PiKit.Line(texts[index], font: font, color: tone)
            line.draw(in: CGRect(x: x, y: y, width: widths[index], height: line.lineHeight), truncation: index == 2 ? .middle : .end, scale: piScale)
            if let detail = details[index] {
                let font = PiKit.Font.monospacedDigits(PiKit.Font.micro)
                PiKit.drawWrapped(detail, font: font, color: .piInkTertiary, in: CGRect(x: x, y: y + line.lineHeight + 1, width: widths[index], height: 100), maximumLines: index == 1 ? 1 : 2)
            }
            x += widths[index] + PiSpacing.sm
        }
    }
}
