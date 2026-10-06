import AppKit

struct MonitorRatePoint: Identifiable, Equatable {
    var id: String { "\(bin):\(model)" }
    let bin: Int
    let date: Date
    let model: String
    let rate: Double
    let segment: Int
    let cumulative: Double
}

struct MonitorRateSeries: Equatable {
    let points: [MonitorRatePoint]
    let models: [String]
    /// At most 120 time columns × five series. Downsampling never runs SQL,
    /// reads transcripts, or connects through an unobserved bin.
    init(samples: [LiveRateSample], domain: ClosedRange<Date>, workspace: String?) {
        let width = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / 120)
        let scoped = samples.map { ($0, $0.models(workspace: workspace)) }
        var totals: [String: Double] = [:]
        for (sample, rates) in scoped where !sample.hasGap(workspace: workspace) {
            for (model, rate) in rates { totals[model, default: 0] += rate }
        }
        let sorted = totals.keys.sorted { totals[$0] == totals[$1] ? $0 < $1 : totals[$0]! > totals[$1]! }
        let leading = Array(sorted.prefix(4))
        models = leading + (sorted.count > 4 ? ["Other models"] : [])
        let groups = Dictionary(grouping: scoped) { Int($0.0.date.timeIntervalSince(domain.lowerBound) / width) }
        var result: [MonitorRatePoint] = [], segment = 0, previous: Int?
        for bin in groups.keys.sorted() {
            guard let values = groups[bin], !values.isEmpty else { continue }
            // A missing interval must not become a zero or a continuous area.
            guard values.allSatisfy({ !$0.0.hasGap(workspace: workspace) && !$0.1.isEmpty }) else { segment += 1; previous = nil; continue }
            if let previous, bin > previous + 1 { segment += 1 }
            previous = bin
            var rates: [String: Double] = [:]
            for (_, values) in values {
                for (model, rate) in values { rates[leading.contains(model) ? model : "Other models", default: 0] += rate }
            }
            let date = values[values.count / 2].0.date
            var cumulative = 0.0
            for model in models {
                cumulative += rates[model, default: 0] / Double(values.count)
                result.append(MonitorRatePoint(bin: bin, date: date, model: model, rate: rates[model, default: 0] / Double(values.count), segment: segment, cumulative: cumulative))
            }
        }
        points = result
    }
}

/// How many times a rate chart built its series and marks. A test seam: the
/// pointer moving over the plot must not rebuild either.
@MainActor enum MonitorChartRenderCount {
    private(set) static var builds = 0
    static func reset() { builds = 0 }
    static func built() { builds &+= 1 }
}

/// The request-average series: the app's settled decode rate of the
/// completed requests in each retained bucket, plotted at its middle.
enum MonitorRateAverage {
    static func rate(_ bucket: MenuBarBucket) -> Double? { bucket.gateway.settledThroughput.tokensPerSecond }
    static func middle(_ bucket: MenuBarBucket) -> Date { bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2) }
    static let explanation = "Output tokens after the first ÷ time from the first generated token to the last (hidden reasoning included), over the completed requests in each interval; replies under \(SettledThroughput.floorLabel) of generation are left out."
}

/// The output-rate chart of the monitor and the report: per model a stacked
/// area of its live rate, or the retained request averages as points; drag
/// across it to zoom, double-click or Escape to reset, the arrow keys to step
/// a reading across it. What follows the pointer (the rule and the caption)
/// redraws alone: the series and the marks are built only when the samples,
/// the scale or the metric change.
@MainActor final class MonitorRateChart: DashView, PiKit.WidthSizing {
    struct Inputs: Equatable {
        var samples: [LiveRateSample]
        var usage: MenuBarSnapshot?
        var workspace: String?
        var following: ClosedRange<Date>
        var zoom: MonitorChartZoom
        var metric: MonitorRateMetric
        var palette: MonitorModelPalette
        var showsMetricSelection = true
        var chartHeight: CGFloat = 124
    }
    /// The zoom the chart asks for (`@Binding var zoom`).
    var onZoom: ((MonitorChartZoom) -> Void)?
    var onSelectMetric: ((MonitorRateMetric) -> Void)?

    private(set) var inputs: Inputs?
    private var series = MonitorRateSeries(samples: [], domain: Date.distantPast...Date.distantPast, workspace: nil)
    private var hover: Date? { didSet { if hover != oldValue { chart.overlay.needsDisplay = true; refreshCaption() } } }

    private let title = PiKit.TextLine(PiKit.Line("Output tok/s", font: PiKit.Font.micro, color: .piInkSecondary))
    private lazy var tabs = PiKit.Tabs(selection: MonitorRateMetric.live, items: MonitorRateMetric.allCases.map { ($0, $0.rawValue) }) { [weak self] in self?.onSelectMetric?($0) }
    private lazy var header = ShellStack(.horizontal, spacing: 8, [.view(title), .spacer(0), .view(tabs)])
    let chart = PiChartView()
    let surface = MonitorChartInteraction.Surface()
    private let empty = EmptyNote()
    private let caption = ShellText("", font: PiKit.Font.micro, color: .piInkSecondary)
    private let dragHint = PiKit.TextLine(PiKit.Line("Drag to zoom", font: PiKit.Font.micro, color: .piInkSecondary))
    private lazy var resetZoom: PlainTextButton = {
        let button = PlainTextButton("Reset zoom", font: PiKit.Font.micro, color: .piAccent) { [weak self] in self?.resetTheZoom() }
        button.setAccessibilityIdentifier("monitor-reset-zoom")
        return button
    }()
    private lazy var zoomRow = ShellStack(.horizontal, spacing: 8, [.view(dragHint), .spacer(8), .view(resetZoom)])
    private let legend = MonitorLegend()
    private lazy var column = ShellStack(.vertical, spacing: 8, [.view(header, .fill), .view(chartBox, .fill), .view(MinimumHeight(caption, minimum: 14), .fill), .view(zoomRow, .fill), .view(legend, .fill)])
    private let chartBox = ChartBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        chartBox.chart = chart; chartBox.surface = surface; chartBox.empty = empty
        chartBox.addSubview(chart); chartBox.addSubview(surface); chartBox.addSubview(empty)
        addSubview(column)
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityIdentifier("monitor-rate-chart")
        chart.overlay.draw = { [weak self] geometry, context in self?.drawPointer(geometry, context) }
        surface.hover = { [weak self] in self?.hover = $0 }
        surface.drag = { [weak self] start, end, width, held in
            guard let self, var zoom = self.inputs?.zoom else { return }
            zoom.update(startX: start, x: end, width: width, domain: held)
            self.setZoom(zoom)
        }
        surface.finish = { [weak self] horizontal, vertical in
            guard let self, var zoom = self.inputs?.zoom else { return }
            _ = zoom.finish(horizontal: horizontal, vertical: vertical)
            self.setZoom(zoom)
        }
        surface.reset = { [weak self] in self?.resetTheZoom() }
        surface.step = { [weak self] in self?.step($0) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// The chart's time scale: the zoom's drag or range, else the following window.
    var domain: ClosedRange<Date> { inputs.map { $0.zoom.domain(following: $0.following) } ?? Date.distantPast...Date.distantFuture }

    func update(_ next: Inputs) {
        let previous = inputs
        guard next != previous else { return }
        inputs = next
        if let previous, previous.metric != next.metric {
            // A new metric starts without a pointer reading or a drag.
            hover = nil
            if next.zoom.brush != nil { var zoom = next.zoom; zoom.cancel(); inputs?.zoom = zoom; onZoom?(zoom) }
        }
        let domain = self.domain
        let sameSeries = previous.map { $0.samples == next.samples && $0.workspace == next.workspace && $0.zoom.domain(following: $0.following) == domain } ?? false
        if !sameSeries || previous?.metric != next.metric || previous?.usage != next.usage || previous?.palette != next.palette {
            if !sameSeries { series = MonitorRateSeries(samples: next.samples, domain: domain, workspace: next.workspace) }
            MonitorChartRenderCount.built()
            chart.spec = MonitorRateChartSpec.make(series: series, buckets: next.usage?.buckets ?? [], metric: next.metric, domain: domain, palette: next.palette)
        }
        tabs.selection = next.metric
        tabs.isHidden = !next.showsMetricSelection
        resetZoom.isHidden = next.zoom.range == nil
        legend.update(models: next.metric == .live ? series.models : [], palette: next.palette)
        let empty = next.metric == .live ? series.points.isEmpty
            : !(next.usage?.buckets ?? []).contains(where: { MonitorRateAverage.rate($0) != nil && domain.contains(MonitorRateAverage.middle($0)) })
        self.empty.isHidden = !empty
        self.empty.text = next.metric == .live ? "Awaiting live usage counters" : "No timed requests in this interval"
        surface.setAccessibilityLabel(next.metric.rawValue + " chart. Drag horizontally to zoom, double-click or press Escape to reset. Arrow keys inspect samples; plus zooms the middle half.")
        chartBox.chartHeight = next.chartHeight
        chart.overlay.needsDisplay = true
        refreshCaption()
        column.relayoutAll()
        needsLayout = true
        PiKit.sizeChanged(self)
    }

    private func setZoom(_ zoom: MonitorChartZoom) {
        guard var inputs, inputs.zoom != zoom else { return }
        inputs.zoom = zoom
        onZoom?(zoom)
        update(inputs)
    }
    private func resetTheZoom() {
        guard var zoom = inputs?.zoom else { return }
        zoom.reset(); hover = nil
        setZoom(zoom)
    }
    private func step(_ direction: Int) {
        let domain = self.domain
        let step = domain.upperBound.timeIntervalSince(domain.lowerBound) / 24
        let value = (hover ?? domain.upperBound).addingTimeInterval(Double(direction) * step)
        hover = min(domain.upperBound.addingTimeInterval(-0.001), max(domain.lowerBound, value))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Gone from the window: a drag in progress is dropped (`onDisappear`).
        if window == nil, let zoom = inputs?.zoom, zoom.brush != nil { var cancelled = zoom; cancelled.cancel(); setZoom(cancelled) }
    }

    // MARK: Pointer

    /// The brush and the dashed rule at the pointer, over the marks.
    private func drawPointer(_ geometry: PiChartGeometry, _ context: CGContext) {
        guard let inputs else { return }
        let plot = geometry.plot, domain = self.domain
        if let brush = inputs.zoom.brush {
            let a = geometry.x.position(brush.lowerBound.timeIntervalSinceReferenceDate)
            let b = geometry.x.position(brush.upperBound.timeIntervalSinceReferenceDate)
            let rect = CGRect(x: a, y: plot.minY, width: max(1, b - a), height: plot.height)
            context.setFillColor(NSColor.piAccent.piOpacity(0.16).cgColor); context.fill(rect)
            context.setStrokeColor(NSColor.piAccent.cgColor); context.setLineWidth(1); context.stroke(rect)
        }
        if let date = hover, domain.contains(date), domain.upperBound > domain.lowerBound {
            let x = plot.minX + plot.width * date.timeIntervalSince(domain.lowerBound) / domain.upperBound.timeIntervalSince(domain.lowerBound)
            context.saveGState()
            context.setStrokeColor(NSColor.piInkSecondary.piOpacity(0.7).cgColor)
            context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: x, y: plot.minY)); context.addLine(to: CGPoint(x: x, y: plot.maxY)); context.strokePath()
            context.restoreGState()
        }
    }

    private func refreshCaption() {
        guard let inputs else { return }
        let text = Self.caption(hover: hover, series: series, buckets: inputs.usage?.buckets ?? [], metric: inputs.metric, domain: domain, brush: inputs.zoom.brush)
        if caption.text != text { caption.set(text, color: .piInkSecondary); PiKit.sizeChanged(caption) }
        // The reading the keyboard steps to is the chart's value too.
        surface.setAccessibilityValue(text)
    }

    /// The line under the chart: the brush, the reading under the pointer, or what the chart shows.
    static func caption(hover: Date?, series: MonitorRateSeries, buckets: [MenuBarBucket], metric: MonitorRateMetric, domain: ClosedRange<Date>, brush: ClosedRange<Date>?) -> String {
        if let brush {
            return "\(brush.lowerBound.formatted(date: .omitted, time: .standard)) – \(brush.upperBound.formatted(date: .omitted, time: .standard)) · release to zoom"
        }
        if let hover {
            if metric == .average, let bucket = buckets.first(where: { hover >= $0.start && hover < $0.end }) {
                let rate = bucket.gateway.settledThroughput
                return "\(hover.formatted(date: .omitted, time: .shortened)) · \(menuBarRate(rate.tokensPerSecond)) tok/s decode · \(rate.samples) measured requests"
            }
            if metric == .live, let point = series.points.min(by: { abs($0.date.timeIntervalSince(hover)) < abs($1.date.timeIntervalSince(hover)) }),
               abs(point.date.timeIntervalSince(hover)) <= max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / 120) {
                let rate = series.points.filter { $0.bin == point.bin }.reduce(0) { $0 + $1.rate }
                return "\(point.date.formatted(date: .omitted, time: .standard)) · \(menuBarRate(rate)) observed tok/s across reporting requests"
            }
            return "\(hover.formatted(date: .omitted, time: .standard)) · no reported observation"
        }
        return metric == .live ? "Reported intervals · gaps stay empty · history since launch" : MonitorRateAverage.explanation
    }

    // MARK: Layout

    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() {
        super.layout()
        column.frame = bounds
    }

    /// The chart, the surface over it and the empty note centred on it, one chart's height tall.
    final class ChartBox: DashView, PiKit.WidthSizing {
        var chart: PiChartView!
        var surface: MonitorChartInteraction.Surface!
        var empty: EmptyNote!
        var chartHeight: CGFloat = 124 { didSet { if chartHeight != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
        override var isFlipped: Bool { true }
        func height(forWidth width: CGFloat) -> CGFloat { chartHeight }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: chartHeight) }
        override func layout() {
            super.layout()
            chart.frame = bounds
            surface.frame = bounds
            surface.plot = chart.resolved().plot
            surface.domain = Date(timeIntervalSinceReferenceDate: chart.resolved().x.domain.lowerBound)...Date(timeIntervalSinceReferenceDate: chart.resolved().x.domain.upperBound)
            let size = empty.intrinsicContentSize
            empty.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                                 width: size.width, height: size.height)
        }
    }

    /// "Awaiting live usage counters": caption type on the monitor's canvas,
    /// in a rounded box over the plot.
    final class EmptyNote: DashView {
        var text = "" { didSet { if oldValue != text { invalidateIntrinsicContentSize(); needsDisplay = true; needsLayout = true; superview?.needsLayout = true } } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.caption, color: .piInkSecondary) }
        override var intrinsicContentSize: NSSize { let size = line.size(scale: piScale); return NSSize(width: size.width + 16, height: size.height + 16) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.monitorCanvas.piOpacity(0.95).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            line.draw(at: CGPoint(x: 8, y: 8), scale: piScale)
        }
    }
}

/// The models of the live chart, each with its colour, in a row that
/// scrolls sideways (its scroller hidden) when they do not fit.
@MainActor final class MonitorLegend: DashView, PiKit.WidthSizing {
    private let scroll = NSScrollView()
    private let row = ShellStack(.horizontal, spacing: 12, alignment: .center)
    private var shown: [String] = []
    private var palette = MonitorModelPalette()
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(models: [String], palette: MonitorModelPalette) {
        guard models != shown || palette != self.palette else { return }
        shown = models; self.palette = palette
        row.items = models.map { model in
            let item = MonitorLegendItem(model: model, color: .monitorModel(palette.index(model)))
            return .view(item)
        }
        isHidden = models.isEmpty
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { shown.isEmpty ? 0 : 17 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: shown.isEmpty ? 0 : 17) }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = row.naturalWidth
        row.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

/// A model in the legend: its dot and its name, the full name in the help.
@MainActor final class MonitorLegendItem: DashView {
    let model: String
    let color: NSColor
    static let dot: CGFloat = 7
    /// Between the dot and the name, as `Label` sets its icon apart.
    static var spacing: CGFloat = 8
    init(model: String, color: NSColor) {
        self.model = model; self.color = color
        super.init(frame: .zero)
        toolTip = model
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(model)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var line: PiKit.Line { PiKit.Line(model, font: PiKit.Font.micro, color: .labelColor) }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale)
        return NSSize(width: Self.dot + Self.spacing + text.width, height: text.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let text = line.size(scale: piScale)
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 0, y: PiKit.round((bounds.height - Self.dot) / 2, piScale), width: Self.dot, height: Self.dot)).fill()
        line.draw(at: CGPoint(x: Self.dot + Self.spacing, y: PiKit.round((bounds.height - text.height) / 2, piScale)), scale: piScale)
    }
}
