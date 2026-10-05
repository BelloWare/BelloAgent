import Accessibility
import AppKit

/// A chart (`PiChart.Spec`) as an AppKit view. It lays its spec out once per
/// size (`PiChartGeometry`) and draws gridlines, marks and labels into its
/// own layer, only where the dirty rectangle asks. A pointer overlay
/// (`overlay`) lies on top: whatever follows the pointer draws there, so a
/// hover never draws the marks again.
@MainActor final class PiChartView: DashView, @preconcurrency AXChart {
    var spec: PiChart.Spec {
        didSet { guard spec != oldValue else { return }; invalidate() }
    }
    /// What follows the pointer: drawn on top, in the same coordinates, with
    /// the geometry the marks were drawn with.
    let overlay = Overlay()
    /// How many times the marks were drawn: a test seam (a hover must not).
    private(set) var markDraws = 0
    private(set) var geometry: PiChartGeometry?
    /// The marks as paths for `geometry`, and the scale they were laid out at.
    private var prepared: [PiChartRenderer.Prepared] = []
    private var preparedScale: CGFloat = 0

    init(spec: PiChart.Spec = PiChart.Spec()) {
        self.spec = spec
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.chart = self
        addSubview(overlay)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The chart's geometry at its current size and scale.
    func resolved() -> PiChartGeometry {
        if let geometry, geometry.size == bounds.size, preparedScale == piScale { return geometry }
        let made = PiChartLayout.resolve(spec, size: bounds.size, scale: piScale)
        geometry = made
        prepared = PiChartRenderer.prepare(spec, made, scale: piScale)
        preparedScale = piScale
        accessibleElements = nil
        // Whoever asked first, the layer shows the new layout.
        needsDisplay = true; overlay.needsDisplay = true
        return made
    }
    private func invalidate() {
        geometry = nil; accessibleElements = nil
        needsLayout = true; needsDisplay = true; overlay.needsDisplay = true
    }

    override func layout() {
        super.layout()
        if geometry?.size != bounds.size { invalidate() }
        overlay.frame = bounds
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if preparedScale != piScale { invalidate() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true; overlay.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }
        markDraws &+= 1
        let geometry = resolved()
        PiChartRenderer.draw(geometry, spec: spec, marks: prepared, in: context, dirty: dirtyRect, scale: piScale)
    }

    // MARK: Accessibility

    /// One element per accessible mark, in the chart's own order, placed
    /// where the mark is; and an audio graph of them.
    override func accessibilityChildren() -> [Any]? {
        guard !spec.accessibleMarks.isEmpty else { return super.accessibilityChildren() }
        if let elements = accessibleElements, elements.count == spec.accessibleMarks.count { return elements }
        let geometry = resolved()
        let made: [NSAccessibilityElement] = spec.accessibleMarks.map { mark in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(mark.label)
            element.setAccessibilityValue(mark.value)
            element.setAccessibilityParent(self)
            let point = geometry.point(mark.x, mark.y)
            element.setAccessibilityFrameInParentSpace(NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            return element
        }
        accessibleElements = made
        return made
    }
    private var accessibleElements: [NSAccessibilityElement]?

    var accessibilityChartDescriptor: AXChartDescriptor? {
        get {
            let marks = spec.accessibleMarks
            guard !marks.isEmpty else { return nil }
            let geometry = resolved()
            func axis(_ kind: PiChart.Kind, _ mapping: PiChartGeometry.Mapping, _ ticks: [PiChartGeometry.Tick], title: String) -> AXNumericDataAxisDescriptor {
                let describe: (Double) -> String
                switch kind {
                case .date: describe = { Date(timeIntervalSinceReferenceDate: $0).formatted(date: .abbreviated, time: .shortened) }
                case .band:
                    let categories = spec.accessibleCategories
                    describe = { value in
                        let index = Int(value.rounded())
                        return categories.indices.contains(index) ? categories[index] : String(index + 1)
                    }
                case .number: describe = { $0.formatted(.number.precision(.significantDigits(1...6))) }
                }
                return AXNumericDataAxisDescriptor(title: title, range: mapping.domain.lowerBound...mapping.domain.upperBound,
                                                   gridlinePositions: ticks.map(\.value), valueDescriptionProvider: describe)
            }
            let x = axis(spec.x.kind, geometry.x, geometry.xTicks, title: spec.accessibleAxes.x)
            let y = axis(spec.y.kind, geometry.y, geometry.yTicks, title: spec.accessibleAxes.y)
            var order: [String] = []
            var points: [String: [AXDataPoint]] = [:]
            for mark in marks {
                if points[mark.series] == nil { order.append(mark.series) }
                points[mark.series, default: []].append(AXDataPoint(x: mark.x, y: mark.y, additionalValues: [], label: mark.label + ", " + mark.value))
            }
            let series = order.map { AXDataSeriesDescriptor(name: $0, isContinuous: spec.accessibleContinuous, dataPoints: points[$0] ?? []) }
            return AXChartDescriptor(title: accessibilityLabel(), summary: accessibilityValue() as? String, xAxis: x, yAxis: y, additionalAxes: [], series: series)
        }
        set {}
    }

    /// The pointer's layer of a chart: draws with `draw`, after the marks.
    @MainActor final class Overlay: DashView {
        weak var chart: PiChartView?
        var draw: ((PiChartGeometry, CGContext) -> Void)? { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let draw, let chart, let context = NSGraphicsContext.current?.cgContext else { return }
            draw(chart.resolved(), context)
        }
    }
}
