import AppKit
import Combine

/// Counters for bounded Overview work. Pointer movement changes only the
/// overlay and caption; it never builds the page or chart marks again.
@MainActor enum SessionStatsRenderCount {
    private(set) static var panels = 0, marks = 0, ledgerRows = 0, pointers = 0, captions = 0
    static func reset() { panels = 0; marks = 0; ledgerRows = 0; pointers = 0; captions = 0 }
    static func panelBuilt() { panels &+= 1 }
    static func marksBuilt() { marks &+= 1 }
    static func ledgerRowBuilt() { ledgerRows &+= 1 }
    static func pointerDrawn() { pointers &+= 1 }
    static func captionDrawn() { captions &+= 1 }
}

/// The original eight-point statistics column, measured at its actual width.
@MainActor class SessionStatsColumn: DashView, PiKit.WidthSizing {
    let column = ShellStack(.vertical, spacing: 8)
    override init(frame: NSRect) { super.init(frame: frame); addSubview(column) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func setItems(_ views: [NSView]) { column.items = views.map { .view($0, .fill) } }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() { super.layout(); column.frame = bounds }
}

@MainActor final class SessionStatsLoadingNote: SessionStatsColumn {
    init(loading: Bool, failure: String?) {
        super.init(frame: .zero)
        setItems([failure.map { PiKit.Note($0, tone: .warning) as NSView }
                  ?? SessionStatsEmptyLine(loading ? "Reading this session's requests…" : "No retained requests yet.")])
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionStatsEmptyLine: DashView {
    let text: String
    let color: NSColor
    init(_ text: String, color: NSColor = .piInkTertiary) {
        self.text = text; self.color = color; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 60) }
    override func draw(_ dirtyRect: NSRect) {
        let line = PiKit.Line(text, font: PiKit.Font.caption, color: color), size = line.size(scale: piScale)
        line.draw(in: CGRect(x: PiKit.round(max(0, (bounds.width - size.width) / 2), piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                             width: min(bounds.width, size.width), height: size.height), scale: piScale)
    }
}

/// The segmented bar grows from its leading edge once on first appearance.
@MainActor private final class SessionStatsRevealedBar: DashView {
    let bar: PiKit.SegmentedBar
    private var revealed = false
    init(_ bar: PiKit.SegmentedBar) { self.bar = bar; super.init(frame: .zero); addSubview(bar) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { bar.intrinsicContentSize }
    override func layout() {
        super.layout(); bar.frame = bounds
        if !revealed, window != nil, !bounds.isEmpty {
            revealed = true
            if !piReducesMotion { PiKit.reveal(bar, horizontal: true, delay: 0.04) }
        }
    }
}

@MainActor final class SessionStatsNotes: SessionStatsColumn {
    init(notes: [String]) {
        super.init(frame: .zero); column.spacing = 5
        setItems(notes.map { ShellText($0, font: PiKit.Font.micro, color: .piInkTertiary) })
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(notes.joined(separator: ", ")); setAccessibilityIdentifier("session-stats-notes")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

/// Two reserved lines: a hover changes the text drawing without moving the page.
@MainActor private final class SessionStatsCaption: DashView, PiKit.WidthSizing {
    private let captions: [String], latest: String
    private var text: String
    private var observation: AnyCancellable?
    private static var font: NSFont { PiKit.Font.monospacedDigits(PiKit.Font.caption) }
    init(selection: PiChartSelection, captions: [String], latest: String) {
        self.captions = captions; self.latest = latest
        text = selection.index.flatMap { captions.indices.contains($0) ? captions[$0] : nil } ?? latest
        super.init(frame: .zero); setAccessibilityElement(false)
        observation = selection.$index.dropFirst().sink { [weak self] index in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.text = index.flatMap { self.captions.indices.contains($0) ? self.captions[$0] : nil } ?? self.latest
                self.needsDisplay = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { 2 * PiKit.Line("Ag", font: Self.font, color: .piInkSecondary).lineHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func draw(_ dirtyRect: NSRect) {
        SessionStatsRenderCount.captionDrawn()
        PiKit.drawWrapped(text, font: Self.font, color: .piInkSecondary, in: bounds, maximumLines: 2)
    }
}

@MainActor private final class SessionStatsKey: DashView, ShellBaselined {
    let color: NSColor, text: String, line: Bool
    init(color: NSColor, title: String, line: Bool = false) {
        self.color = color; text = title; self.line = line; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var label: PiKit.Line { PiKit.Line(text, font: PiKit.Font.micro, color: .piInkSecondary) }
    var firstBaseline: CGFloat { label.baseline(scale: piScale) }
    override var firstBaselineOffsetFromTop: CGFloat { firstBaseline }
    override var intrinsicContentSize: NSSize { NSSize(width: (line ? 9 : 7) + 4 + label.size(scale: piScale).width, height: label.lineHeight) }
    override func draw(_ dirtyRect: NSRect) {
        let size = CGSize(width: line ? 9 : 7, height: line ? 2 : 7)
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height),
                     xRadius: line ? 1 : 1.5, yRadius: line ? 1 : 1.5).fill()
        label.draw(in: CGRect(x: size.width + 4, y: 0, width: max(0, bounds.width - size.width - 4), height: label.lineHeight), scale: piScale)
    }
}

/// Pointer and keyboard target over a native chart. The marks and their
/// VoiceOver graph remain in PiChartView; selection draws in its overlay.
@MainActor final class SessionStatsChartSurface: DashView {
    enum Marker { case timeline(Int), columns(Int), point([(Double, Double)]) }
    let chart: PiChartView, selection: PiChartSelection
    let requestIDs: [String], marker: Marker, plotHeight: CGFloat
    var open: ((String) -> Void)?
    private let nearest: (PiChartGeometry, CGPoint) -> Int?
    private var observation: AnyCancellable?, tracking: NSTrackingArea?
    private let horizontal: Bool, delay: Double
    private var revealed = false
    init(spec: PiChart.Spec, height: CGFloat, selection: PiChartSelection, requestIDs: [String], marker: Marker,
         horizontal: Bool, delay: Double, open: ((String) -> Void)?, nearest: @escaping (PiChartGeometry, CGPoint) -> Int?) {
        chart = PiChartView(spec: spec); plotHeight = height; self.selection = selection; self.requestIDs = requestIDs
        self.marker = marker; self.horizontal = horizontal; self.delay = delay; self.open = open; self.nearest = nearest
        super.init(frame: .zero); addSubview(chart); SessionStatsRenderCount.marksBuilt()
        chart.overlay.draw = { [weak self] geometry, context in self?.drawPointer(geometry, context: context) }
        observation = selection.$index.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.chart.overlay.needsDisplay = true }
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: plotHeight) }
    override var acceptsFirstResponder: Bool { open != nil && !requestIDs.isEmpty }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func layout() {
        super.layout(); chart.frame = bounds
        if !revealed, window != nil, !bounds.isEmpty {
            revealed = true
            if !piReducesMotion { PiKit.reveal(chart, horizontal: horizontal, delay: delay) }
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    /// Flipped local coordinates; also a deterministic test seam.
    func select(at point: CGPoint) {
        let geometry = chart.resolved()
        selection.select(geometry.plot.contains(point) ? nearest(geometry, point) : nil)
    }
    override func mouseMoved(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { selection.select(nil) }
    override func mouseDown(with event: NSEvent) {
        select(at: convert(event.locationInWindow, from: nil)); window?.makeFirstResponder(self); openSelection()
    }
    func openSelection() {
        guard let index = selection.index, requestIDs.indices.contains(index) else { return }
        open?(requestIDs[index])
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: if !requestIDs.isEmpty { selection.select(max(0, (selection.index ?? requestIDs.count) - 1)) }
        case 124, 125: if !requestIDs.isEmpty { selection.select(min(requestIDs.count - 1, (selection.index ?? -1) + 1)) }
        case 36, 49: openSelection()
        case 53: selection.select(nil)
        default: super.keyDown(with: event)
        }
    }
    override func resetCursorRects() { super.resetCursorRects(); if open != nil { addCursorRect(chart.resolved().plot, cursor: .pointingHand) } }
    private func drawPointer(_ geometry: PiChartGeometry, context: CGContext) {
        SessionStatsRenderCount.pointerDrawn()
        guard let index = selection.index, requestIDs.indices.contains(index) else { return }
        let plot = geometry.plot
        switch marker {
        case .timeline(let count):
            guard count > 0 else { return }
            let pitch = plot.height / CGFloat(count)
            context.setFillColor(piCGColor(NSColor.piInk.piOpacity(0.07)))
            context.addPath(CGPath(roundedRect: CGRect(x: plot.minX - 4, y: plot.minY + CGFloat(index) * pitch, width: plot.width + 8, height: pitch), cornerWidth: 3, cornerHeight: 3, transform: nil)); context.fillPath()
        case .columns(let count):
            guard count > 0 else { return }
            let width = max(4, plot.width / CGFloat(count)), x = geometry.x.position(Double(index))
            context.setFillColor(piCGColor(NSColor.piInk.piOpacity(0.07)))
            context.addPath(CGPath(roundedRect: CGRect(x: x - width / 2 - 1, y: plot.minY, width: width + 2, height: plot.height), cornerWidth: 2, cornerHeight: 2, transform: nil)); context.fillPath()
        case .point(let points):
            guard points.indices.contains(index) else { return }
            let point = geometry.point(points[index].0, points[index].1)
            context.setStrokeColor(piCGColor(NSColor.piInkTertiary.piOpacity(0.45))); context.setLineWidth(1)
            context.move(to: CGPoint(x: point.x, y: plot.minY)); context.addLine(to: CGPoint(x: point.x, y: plot.maxY)); context.strokePath()
            context.setStrokeColor(piCGColor(NSColor.piInk.piOpacity(0.7))); context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11))
        }
    }
}

@MainActor final class SessionTimeSplitView: SessionStatsColumn {
    let split: SessionTimeSplit
    init(split: SessionTimeSplit) {
        self.split = split; super.init(frame: .zero)
        let bar = PiKit.SegmentedBar(segments: split.parts.map { .init(id: $0.id.rawValue, fraction: $0.fraction) }, height: 12) {
            SessionTimeSplit.Kind(rawValue: $0).map(NSColor.sessionTime) ?? .piInkTertiary
        }
        let legends = ShellStack(.vertical, spacing: 4, split.parts.map { .view(PiKit.LegendRow(color: .sessionTime($0.id), title: $0.title, value: $0.value, share: $0.share), .fill) })
        var views: [NSView] = [PiKit.ChartHeader("Where the time went", subtitle: split.total + " in all, from the helper's clocks"), SessionStatsRevealedBar(bar), legends]
        if let note = split.note { views.append(ShellText(note, font: PiKit.Font.micro, color: .piInkTertiary)) }
        setItems(views); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(split.accessibility); setAccessibilityIdentifier("session-stats-time-split")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionTimelineChart: SessionStatsColumn {
    let timeline: SessionRequestTimeline, selection: PiChartSelection, surface: SessionStatsChartSurface
    init(timeline: SessionRequestTimeline, selection: PiChartSelection, open: ((String) -> Void)? = nil) {
        self.timeline = timeline; self.selection = selection
        let count = timeline.rows.count
        surface = SessionStatsChartSurface(spec: SessionStatsChartSpecs.timeline(timeline), height: CGFloat(count) * SessionStatsChartSpecs.timelinePitch(count) + 20,
            selection: selection, requestIDs: timeline.rows.map(\.id), marker: .timeline(count), horizontal: true, delay: 0.06, open: open) { geometry, point in
            let index = count - 1 - Int(geometry.y.value(at: point.y).rounded()); return timeline.rows.indices.contains(index) ? index : nil
        }
        super.init(frame: .zero)
        var keys: [NSView] = [SessionStatsKey(color: .sessionTime(.waiting), title: "Waiting for first token"), SessionStatsKey(color: .sessionTime(.generating), title: "Generating")]
        if timeline.hasUnsplit { keys.append(SessionStatsKey(color: NSColor.piInkTertiary.piOpacity(0.6), title: "Not split")) }
        if timeline.hasFailures { keys.append(SessionStatsKey(color: NSColor.piDanger.piOpacity(0.75), title: "Failed attempt")) }
        var views: [NSView] = [PiKit.ChartHeader("Request timeline", subtitle: timeline.subtitle), ShellStack(.horizontal, spacing: 12, keys.map { .view($0, .flexible) }), surface]
        if let highlights = timeline.highlights { views.append(ShellText(highlights, font: PiKit.Font.micro, color: .piInkTertiary)) }
        views.append(SessionStatsCaption(selection: selection, captions: timeline.rows.map(\.caption), latest: timeline.latestCaption))
        setItems(views); nameChart(surface.chart, "Request timeline", value: timeline.accessibility, id: "session-stats-timeline")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionSpeedChart: SessionStatsColumn {
    let speed: SessionSpeedSeries, selection: PiChartSelection, surface: SessionStatsChartSurface
    init(speed: SessionSpeedSeries, selection: PiChartSelection, open: ((String) -> Void)? = nil) {
        self.speed = speed; self.selection = selection
        surface = SessionStatsChartSurface(spec: SessionStatsChartSpecs.speed(speed), height: SessionSpeedSeries.plotHeight,
            selection: selection, requestIDs: speed.points.map(\.id), marker: .point(speed.points.map { ($0.x, $0.rate) }), horizontal: false, delay: 0.08, open: open) { geometry, point in speed.nearest(to: geometry.x.value(at: point.x)) }
        super.init(frame: .zero)
        let key = speed.averageLabel.map { SessionStatsKey(color: .piInkSecondary, title: $0, line: true) }
        var ends: [ShellItem] = []
        if let first = speed.points.first { ends.append(.view(statsMicro("#\(Int(first.x.rounded()))"))) }
        ends.append(.spacer(0)); ends += speed.models.map { .view(SessionStatsKey(color: .monitorModel($0.colorIndex), title: $0.id), .flexible) }; ends.append(.spacer(0))
        if let last = speed.points.last { ends.append(.view(statsMicro("#\(Int(last.x.rounded()))"))) }
        setItems([PiKit.ChartHeader("Speed per request", subtitle: speed.subtitle, accessory: key), surface, ShellStack(.horizontal, spacing: 10, ends),
                  SessionStatsCaption(selection: selection, captions: speed.points.map(\.caption), latest: speed.latestCaption)])
        nameChart(surface.chart, "Speed per request", value: speed.accessibility, id: "session-stats-speed")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionRequestEnds: DashView {
    let first: Int, last: Int
    init(first: Int, last: Int) { self.first = first; self.last = last; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: PiKit.Line("Ag", font: PiKit.Font.micro, color: .piInkTertiary).lineHeight) }
    override func draw(_ dirtyRect: NSRect) {
        let a = PiKit.Line("#\(first)", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary)
        let b = PiKit.Line("#\(last)", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary)
        a.draw(at: .zero, scale: piScale); b.draw(at: CGPoint(x: bounds.width - b.size(scale: piScale).width, y: 0), scale: piScale)
    }
}

@MainActor final class SessionCompositionView: SessionStatsColumn {
    let composition: SessionTokenComposition
    init(composition: SessionTokenComposition) {
        self.composition = composition; super.init(frame: .zero)
        let bar = PiKit.SegmentedBar(segments: composition.parts.map { .init(id: $0.id.rawValue, fraction: $0.fraction) }, height: 12) {
            SessionTokenComposition.Kind(rawValue: $0).map(NSColor.sessionTokens) ?? .piInkTertiary
        }
        let legends = ShellStack(.vertical, spacing: 4, composition.parts.map { .view(PiKit.LegendRow(color: .sessionTokens($0.id), title: $0.title, value: $0.value, share: $0.share, detail: $0.detail), .fill) })
        setItems([PiKit.ChartHeader("Composition", subtitle: composition.subtitle), SessionStatsRevealedBar(bar), legends])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(composition.accessibility); setAccessibilityIdentifier("session-stats-composition")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionTokenBarsChart: SessionStatsColumn {
    let bars: SessionTokenBars, selection: PiChartSelection, surface: SessionStatsChartSurface
    init(bars: SessionTokenBars, selection: PiChartSelection, open: ((String) -> Void)? = nil) {
        self.bars = bars; self.selection = selection
        surface = SessionStatsChartSurface(spec: SessionStatsChartSpecs.tokenBars(bars), height: SessionTokenBars.plotHeight,
            selection: selection, requestIDs: bars.bars.map(\.id), marker: .columns(bars.bars.count), horizontal: false, delay: 0.08, open: open) { geometry, point in
            let index = Int(geometry.x.value(at: point.x)); return bars.bars.indices.contains(index) ? index : nil
        }
        super.init(frame: .zero)
        let keys = ShellStack(.horizontal, spacing: 10, bars.kinds.map { .view(SessionStatsKey(color: .sessionTokens($0), title: Self.keyTitle($0, reasoning: bars.kinds.contains(.reasoning))), .flexible) })
        var views: [NSView] = [PiKit.ChartHeader(bars.binSize > 1 ? "Per request, averaged" : "Per request", subtitle: bars.subtitle), keys, surface,
                               SessionRequestEnds(first: bars.requests.lowerBound, last: bars.requests.upperBound)]
        if let summary = bars.summary { views.append(ShellText(summary, font: PiKit.Font.micro, color: .piInkTertiary)) }
        views.append(SessionStatsCaption(selection: selection, captions: bars.bars.map(\.caption), latest: bars.latestCaption))
        setItems(views); nameChart(surface.chart, bars.binSize > 1 ? "Tokens per request, averaged in bins" : "Tokens per request", value: bars.accessibility, id: "session-stats-token-bars")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    static func keyTitle(_ kind: SessionTokenComposition.Kind, reasoning: Bool) -> String {
        switch kind {
        case .cached: "Cached input"
        case .cacheWrite, .uncached: "Uncached input"
        case .inputUnsplit: "Input, cache unreported"
        case .reasoning: "Reasoning"
        case .output: reasoning ? "Other output" : "Output"
        }
    }
}

@MainActor final class SessionCostChart: SessionStatsColumn {
    let cost: SessionCostSeries, selection: PiChartSelection, surface: SessionStatsChartSurface
    init(cost: SessionCostSeries, selection: PiChartSelection, open: ((String) -> Void)? = nil) {
        self.cost = cost; self.selection = selection
        surface = SessionStatsChartSurface(spec: SessionStatsChartSpecs.cost(cost), height: SessionCostSeries.plotHeight,
            selection: selection, requestIDs: cost.points.map(\.id), marker: .point(cost.points.map { ($0.x, $0.cumulative) }), horizontal: true, delay: 0.1, open: open) { geometry, point in cost.nearest(to: geometry.x.value(at: point.x)) }
        super.init(frame: .zero)
        var views: [NSView] = [PiKit.ChartHeader("Cumulative cost", subtitle: cost.subtitle), surface]
        if let first = cost.points.first, let last = cost.points.last { views.append(SessionRequestEnds(first: Int(first.x.rounded()), last: Int(last.x.rounded()))) }
        views.append(SessionStatsCaption(selection: selection, captions: cost.points.map(\.caption), latest: cost.latestCaption))
        setItems(views); nameChart(surface.chart, "Cumulative cost", value: cost.accessibility, id: "session-stats-cost")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor private func statsMicro(_ text: String) -> PiKit.TextLine {
    PiKit.TextLine(PiKit.Line(text, font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary))
}
@MainActor private func nameChart(_ chart: PiChartView, _ title: String, value: String, id: String) {
    chart.setAccessibilityLabel(title); chart.setAccessibilityValue(value); chart.setAccessibilityIdentifier(id)
}

@MainActor final class SessionModelTimeTable: SessionStatsColumn {
    let rows: [SessionModelTimeRow]
    init(rows: [SessionModelTimeRow]) {
        self.rows = rows; super.init(frame: .zero)
        var views: [NSView] = [PiKit.ChartHeader("By model", subtitle: "\(rows.count) models in this session · each with its own speed and first token"),
                               SessionStatsTableHeader([("Model", nil), ("Requests", 86), ("Speed", 92), ("First token", 80)])]
        for row in rows {
            views.append(FixedHeight(HairlineView(), height: 1, fills: true))
            let requests = SessionStatsShareCell(value: row.requests, share: row.requestShare, caption: row.requestShareLabel, color: .monitorModel(row.colorIndex))
            let speed = TextLines([PiKit.Line(row.speed, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk), PiKit.Line(row.speedCaption, font: PiKit.Font.micro, color: .piInkTertiary)], spacing: 2)
            let first = TextLines([PiKit.Line(row.firstToken, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk), PiKit.Line(row.firstTokenCaption, font: PiKit.Font.micro, color: .piInkTertiary)], spacing: 2)
            let cells = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .top, [.view(SessionStatsModelCell(row.id, color: .monitorModel(row.colorIndex)), .fill), .view(requests, .fixed(86)), .view(speed, .fixed(92)), .view(first, .fixed(80))])
            cells.setAccessibilityElement(true); cells.setAccessibilityRole(.group)
            cells.setAccessibilityLabel("\(row.id): \(row.requests) requests, \(row.requestShareLabel); \(row.speed), \(row.speedCaption); first token \(row.firstToken), \(row.firstTokenCaption)")
            views.append(cells)
        }
        setItems(views); setAccessibilityIdentifier("session-stats-time-models")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionModelTokenTable: SessionStatsColumn {
    let rows: [SessionModelTokenRow]
    init(rows: [SessionModelTokenRow]) {
        self.rows = rows; super.init(frame: .zero)
        var views: [NSView] = [PiKit.ChartHeader("By model", subtitle: "\(rows.count) models in this session · their share of the tokens and of the cost"),
                               SessionStatsTableHeader([("Model", nil), ("Tokens", 112), ("Cost", 112)])]
        for row in rows {
            views.append(FixedHeight(HairlineView(), height: 1, fills: true))
            let cells = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .top, [.view(SessionStatsModelCell(row.id, color: .monitorModel(row.colorIndex)), .fill),
                .view(SessionStatsShareCell(value: row.tokens, share: row.tokenShare, caption: row.tokenShareLabel, color: .monitorModel(row.colorIndex)), .fixed(112)),
                .view(SessionStatsShareCell(value: row.cost, share: row.costShare ?? 0, caption: row.costShareLabel, color: .monitorModel(row.colorIndex)), .fixed(112))])
            cells.setAccessibilityElement(true); cells.setAccessibilityRole(.group)
            cells.setAccessibilityLabel("\(row.id): \(row.tokens) tokens, \(row.tokenShareLabel); cost \(row.cost), \(row.costShareLabel)")
            views.append(cells)
        }
        setItems(views); setAccessibilityIdentifier("session-stats-token-models")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

@MainActor final class SessionStatsTableHeader: DashView {
    let columns: [(String, CGFloat?)]
    init(_ columns: [(String, CGFloat?)]) { self.columns = columns; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: PiKit.Line("Ag", font: PiKit.Font.micro, color: .piInkTertiary).lineHeight) }
    static func widths(_ columns: [(String, CGFloat?)], total: CGFloat) -> [CGFloat] {
        let fixed = columns.compactMap(\.1).reduce(0, +), count = columns.filter { $0.1 == nil }.count
        let room = max(0, total - fixed - PiSpacing.sm * CGFloat(max(0, columns.count - 1)))
        return columns.map { $0.1 ?? (count > 0 ? room / CGFloat(count) : 0) }
    }
    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for (column, width) in zip(columns, Self.widths(columns, total: bounds.width)) {
            PiKit.Line(column.0, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true)
                .draw(in: CGRect(x: x, y: 0, width: width, height: bounds.height), scale: piScale)
            x += width + PiSpacing.sm
        }
    }
}

@MainActor private final class SessionStatsModelCell: DashView {
    let text: String, color: NSColor
    init(_ text: String, color: NSColor) { self.text = text; self.color = color; super.init(frame: .zero); toolTip = text }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var line: PiKit.Line { PiKit.Line(text, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piInk) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: line.lineHeight) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); NSBezierPath(ovalIn: CGRect(x: 0, y: line.baseline(scale: piScale) - 7, width: 7, height: 7)).fill()
        line.draw(in: CGRect(x: 13, y: 0, width: max(0, bounds.width - 13), height: line.lineHeight), truncation: .middle, scale: piScale)
    }
}

@MainActor private final class SessionStatsShareCell: DashView {
    let value: String, caption: String
    private let bar: PiKit.ShareBar
    init(value: String, share: Double, caption: String, color: NSColor) {
        self.value = value; self.caption = caption; bar = PiKit.ShareBar(fraction: share, tone: color); super.init(frame: .zero); addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var reading: PiKit.Line { PiKit.Line(value, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk) }
    private var label: PiKit.Line { PiKit.Line(caption, font: PiKit.Font.micro, color: .piInkTertiary) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: reading.lineHeight + 3 + 4 + 3 + label.lineHeight) }
    override func layout() { super.layout(); bar.frame = CGRect(x: 0, y: reading.lineHeight + 3, width: bounds.width, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        reading.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: reading.lineHeight), scale: piScale)
        label.draw(in: CGRect(x: 0, y: reading.lineHeight + 3 + 4 + 3, width: bounds.width, height: label.lineHeight), scale: piScale)
    }
}
