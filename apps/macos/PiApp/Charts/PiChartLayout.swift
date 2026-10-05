import AppKit

/// A chart laid out at one size: where the plot is, how values map to points,
/// and where each tick and label goes. Made by `PiChartLayout.resolve`.
struct PiChartGeometry {
    struct Mapping {
        let kind: PiChart.Kind
        let domain: ClosedRange<Double>
        /// The plot's extent along this axis, in view points.
        let range: ClosedRange<CGFloat>
        /// True for y: larger values sit higher (smaller view y).
        let inverted: Bool
        /// Band scales: the width of one band, and the width a column takes.
        var band: CGFloat = 0
        var step: CGFloat = 0
        var paddingOuter: CGFloat = 0

        func position(_ value: Double) -> CGFloat {
            if case .band = kind {
                return range.lowerBound + paddingOuter * step + CGFloat(value) * step + step / 2
            }
            let span = domain.upperBound - domain.lowerBound
            guard span != 0 else { return inverted ? range.upperBound : range.lowerBound }
            let t = CGFloat((value - domain.lowerBound) / span)
            let length = range.upperBound - range.lowerBound
            return inverted ? range.upperBound - t * length : range.lowerBound + t * length
        }
        func value(at point: CGFloat) -> Double {
            if case .band(let count) = kind {
                guard step > 0 else { return 0 }
                let index = ((point - range.lowerBound) / step - paddingOuter).rounded(.down)
                return Double(max(0, min(CGFloat(count - 1), index)))
            }
            let length = range.upperBound - range.lowerBound
            guard length != 0 else { return domain.lowerBound }
            let t = Double(inverted ? (range.upperBound - point) / length : (point - range.lowerBound) / length)
            return domain.lowerBound + t * (domain.upperBound - domain.lowerBound)
        }
    }

    struct Tick {
        let value: Double
        /// Where its gridline goes along its axis.
        let position: CGFloat
        let label: PiKit.Line?
        /// Where its label is drawn (top-left), nil when it is hidden.
        let labelOrigin: CGPoint?
        /// The room a label has before the chart's end, when it has less
        /// than it needs: Swift Charts cuts it there with "…".
        var labelRoom: CGFloat? = nil
    }

    let size: CGSize
    let plot: CGRect
    let x: Mapping
    let y: Mapping
    let xTicks: [Tick]
    let yTicks: [Tick]
    /// Legend entries and where each is drawn.
    let legend: [(item: PiChart.LegendItem, origin: CGPoint)]

    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: self.x.position(x), y: self.y.position(y)) }
}

/// How a chart is laid out, as Swift Charts lays it out.
@MainActor enum PiChartLayout {
    /// Room between the leading axis's labels and the plot.
    static var yLabelGap: CGFloat = 5
    /// Room between a leading label's end and the plot.
    static var yLabelInset: CGFloat = 4
    /// How far after its tick a time label starts.
    static var afterTick: CGFloat = 4
    /// Room between the plot and the bottom axis's labels.
    static var xLabelGap: CGFloat = 4
    /// Room between the axis labels and the legend.
    static var legendGap: CGFloat = 4
    /// The corner a `BarMark` has without `.cornerRadius`.
    static var barCornerRadius: CGFloat = 1
    /// A legend entry's text after its dot, and the room before the next.
    static var legendText: CGFloat = 13
    static var legendSpacing: CGFloat = 8

    static func resolve(_ spec: PiChart.Spec, size: CGSize, scale: CGFloat) -> PiChartGeometry {
        let (xDomain, xStep) = domain(spec.x, axis: spec.xAxis, values: xValues(spec))
        let (yDomain, yStep) = domain(spec.y, axis: spec.yAxis, values: yValues(spec))
        let xTickValues = tickValues(spec.xAxis, kind: spec.x.kind, domain: xDomain, step: xStep)
        let yTickValues = tickValues(spec.yAxis, kind: spec.y.kind, domain: yDomain, step: yStep)
        let yLabels: [PiKit.Line?] = yTickValues.map { value in
            guard spec.yAxis.position != .hidden, let labels = spec.yAxis.labels else { return nil }
            return PiKit.Line(labels.format.text(value), font: labels.font, color: labels.color)
        }
        let xLabels: [PiKit.Line?] = xTickValues.map { value in
            guard spec.xAxis.position != .hidden, let labels = spec.xAxis.labels else { return nil }
            return PiKit.Line(labels.format.text(value), font: labels.font, color: labels.color)
        }
        let yLabelWidth = yLabels.compactMap { $0?.width }.max() ?? 0
        let xLabelHeight = xLabels.compactMap { $0?.lineHeight }.max() ?? 0
        let legendHeight: CGFloat = spec.legend.isEmpty ? 0 : PiKit.Line("Ag", font: PiChart.defaultLabelFont, color: .labelColor).lineHeight + legendGap
        // Measured: the plot starts five points past the widest label's whole points.
        let left = yLabelWidth > 0 ? floor(yLabelWidth) + yLabelGap : 0
        let bottom = (xLabelHeight > 0 ? xLabelHeight + xLabelGap : 0) + legendHeight
        let plot = CGRect(x: left, y: 0, width: max(0, size.width - left - spec.plotTrailingPadding), height: max(0, size.height - bottom))
        var xMap = PiChartGeometry.Mapping(kind: spec.x.kind, domain: xDomain, range: plot.minX...plot.maxX, inverted: false)
        if case .band(let count) = spec.x.kind {
            // Measured: the bands fill the plot, no padding at either end.
            let step = plot.width / max(1, CGFloat(count))
            xMap.step = step; xMap.band = step; xMap.paddingOuter = 0
        }
        let yMap = PiChartGeometry.Mapping(kind: spec.y.kind, domain: yDomain, range: plot.minY...plot.maxY, inverted: true)
        var yTicks: [PiChartGeometry.Tick] = []
        for (value, label) in zip(yTickValues, yLabels) {
            let position = yMap.position(value)
            let origin = label.map { line -> CGPoint in
                let labelSize = line.size(scale: scale)
                return CGPoint(x: left - yLabelInset - labelSize.width, y: position - labelSize.height / 2)
            }
            yTicks.append(.init(value: value, position: position, label: label, labelOrigin: origin))
        }
        var xTicks: [PiChartGeometry.Tick] = []
        var lastRight = -CGFloat.infinity
        for (value, label) in zip(xTickValues, xLabels) {
            let position = xMap.position(value)
            var origin: CGPoint?
            var room: CGFloat?
            if let label, let labels = spec.xAxis.labels {
                let labelSize = label.size(scale: scale)
                var x: CGFloat
                switch labels.anchor(value) {
                case .center: x = position - labelSize.width / 2
                // Measured: a label hung from its tick keeps four points from it.
                case .leading: x = position + afterTick
                case .trailing: x = position - afterTick - labelSize.width
                case .after: x = position + afterTick
                }
                if spec.xAxis.aligned { x = min(max(0, x), size.width - labelSize.width) }
                if !labels.hidesCollisions || x >= lastRight {
                    // Text sits on the pixel grid, as SwiftUI's `Text` does.
                    // Measured: over a legend the labels sit half a point lower.
                    origin = CGPoint(x: x, y: PiKit.round(plot.maxY + xLabelGap + (spec.legend.isEmpty ? 0 : 0.5), scale))
                    lastRight = x + labelSize.width
                    // A label after its tick is cut with "…" at the chart's end; a
                    // centred one is only clipped there.
                    if labels.anchor(value) == .after, x + label.width > size.width + 0.01 { room = max(0, size.width - x) }
                }
            }
            xTicks.append(.init(value: value, position: position, label: label, labelOrigin: origin, labelRoom: room))
        }
        var legend: [(item: PiChart.LegendItem, origin: CGPoint)] = []
        var legendX: CGFloat = 0
        for item in spec.legend {
            legend.append((item, CGPoint(x: legendX, y: size.height - legendHeight + legendGap)))
            legendX += legendText + PiKit.Line(item.title, font: PiChart.defaultLabelFont, color: .labelColor).size(scale: scale).width + legendSpacing
        }
        return PiChartGeometry(size: size, plot: plot, x: xMap, y: yMap, xTicks: xTicks, yTicks: yTicks, legend: legend)
    }

    // MARK: Domains and ticks

    /// The axis's domain, and the step of its automatic ticks when the
    /// domain was widened to them.
    private static func domain(_ scale: PiChart.Scale, axis: PiChart.Axis, values: [Double]) -> (ClosedRange<Double>, Double?) {
        if case .band(let count) = scale.kind { return (0...Double(max(0, count - 1)), nil) }
        switch scale.domain {
        case .fixed(let range): return (range, nil)
        case .automatic(let includesZero):
            var lower = values.min() ?? 0, upper = values.max() ?? 1
            if includesZero { lower = min(lower, 0); upper = max(upper, 0) }
            if scale.kind == .date { return (lower...max(upper, lower + 1), nil) }
            let made = PiChartTicks.automaticDomain(lower, upper, desiredCount: desired(axis), includesZero: includesZero)
            return (made.domain, made.step)
        }
    }
    private static func desired(_ axis: PiChart.Axis) -> Int? {
        if case .automatic(let desired) = axis.ticks { return desired }
        return nil
    }
    private static func tickValues(_ axis: PiChart.Axis, kind: PiChart.Kind, domain: ClosedRange<Double>, step: Double?) -> [Double] {
        guard axis.position != .hidden || axis.gridline != nil else { return [] }
        switch axis.ticks {
        case .values(let values): return values
        case .automatic(let desired):
            if kind == .date { return PiChartTicks.dates(domain) }
            if case .band = kind { return [] }
            if let step { return PiChartTicks.multiples(of: step, in: domain) }
            return PiChartTicks.numbers(domain, desiredCount: desired)
        }
    }

    private static func xValues(_ spec: PiChart.Spec) -> [Double] {
        spec.marks.flatMap { mark -> [Double] in
            switch mark {
            case .area(let x, _, _, _, _), .line(let x, _, _, _, _, _): return x
            case .point(let x, _, _, _): return [x]
            case .rect(let x0, let x1, _, _, _, _), .bar(let x0, let x1, _, _, _, _): return [x0, x1]
            case .column(let category, _, _, _, _): return [Double(category)]
            case .rule(let x, _, _, _, _): return x.map { [$0] } ?? []
            case .annotation(let x, _, _, _, _, _, _, _): return [x]
            }
        }
    }
    private static func yValues(_ spec: PiChart.Spec) -> [Double] {
        spec.marks.flatMap { mark -> [Double] in
            switch mark {
            case .area(_, let lower, let upper, _, _): return lower + upper
            case .line(_, let y, _, _, _, _): return y
            case .point(_, let y, _, _): return [y]
            case .rect(_, _, let y0, let y1, _, _), .column(_, let y0, let y1, _, _): return [y0, y1]
            case .bar(_, _, let y, _, _, _): return [y]
            case .rule(_, let y, _, _, _): return y.map { [$0] } ?? []
            case .annotation(_, let y, _, _, _, _, _, _): return [y]
            }
        }
    }
}
