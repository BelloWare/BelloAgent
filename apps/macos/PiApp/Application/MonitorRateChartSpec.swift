import AppKit

/// The monitor's rate chart as a chart value (`PiChart.Spec`), as Swift
/// Charts drew it: per model a stacked area at 60 per cent and its
/// cumulative outline, points where there are too few observations for an
/// area, or the request averages as points; the time axis with four
/// labelled gridlines and the rate axis with three.
enum MonitorRateChartSpec {
    static func make(series: MonitorRateSeries, buckets: [MenuBarBucket], metric: MonitorRateMetric,
                     domain: ClosedRange<Date>, palette: MonitorModelPalette) -> PiChart.Spec {
        var marks: [PiChart.Mark] = []
        var accessible: [PiChart.AccessibleMark] = []
        if metric == .live {
            accessible = series.points.map { .init(series: $0.model, label: $0.date.formatted(date: .omitted, time: .standard), value: menuBarRate($0.rate) + " tok/s", x: $0.date.timeIntervalSinceReferenceDate, y: $0.rate) }
            // Swift Charts draws each series where it first appears: the
            // area, then its outline, model after model.
            var order: [String] = []
            var groups: [String: [MonitorRatePoint]] = [:]
            for point in series.points {
                let key = "\(point.model):\(point.segment)"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(point)
            }
            let pointSize: CGFloat = series.points.count <= series.models.count ? 20 : 0
            for key in order {
                guard let points = groups[key], let first = points.first else { continue }
                let color = NSColor.monitorModel(palette.index(first.model))
                let x = points.map { $0.date.timeIntervalSinceReferenceDate }
                marks.append(.area(x: x, lower: points.map { $0.cumulative - $0.rate }, upper: points.map(\.cumulative),
                                   color: color.piOpacity(0.6), interpolation: .linear))
                marks.append(.line(x: x, y: points.map(\.cumulative), color: color, width: 1.4, round: false, interpolation: .linear))
            }
            if pointSize > 0 {
                for point in series.points {
                    marks.append(.point(x: point.date.timeIntervalSinceReferenceDate, y: point.rate,
                                        color: .monitorModel(palette.index(point.model)), size: pointSize))
                }
            }
        } else {
            for bucket in buckets {
                guard let rate = MonitorRateAverage.rate(bucket) else { continue }
                marks.append(.point(x: MonitorRateAverage.middle(bucket).timeIntervalSinceReferenceDate, y: rate, color: .piBrandOrange, size: 30))
                accessible.append(.init(label: MonitorRateAverage.middle(bucket).formatted(date: .omitted, time: .shortened), value: menuBarRate(rate) + " tok/s decode",
                                        x: MonitorRateAverage.middle(bucket).timeIntervalSinceReferenceDate, y: rate))
            }
        }
        let short = domain.upperBound.timeIntervalSince(domain.lowerBound) < 180
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .date, domain: .fixed(domain.lowerBound.timeIntervalSinceReferenceDate...domain.upperBound.timeIntervalSinceReferenceDate))
        spec.y = PiChart.Scale(kind: .number, domain: .automatic(includesZero: true))
        spec.marks = marks
        spec.accessibleMarks = accessible
        spec.accessibleAxes = ("Time", "Output tokens per second")
        spec.accessibleContinuous = metric == .live
        spec.xAxis = PiChart.Axis(position: .bottom, ticks: .automatic(desiredCount: 4), gridline: .time(.piHairline),
                                  labels: PiChart.Labels(color: .piInkSecondary,
                                                         format: .date(short ? .dateTime.minute().second() : .dateTime.hour().minute()), anchor: .after))
        spec.yAxis = PiChart.Axis(position: .leading, ticks: .automatic(desiredCount: 3), gridline: PiChart.Gridline(color: .piHairline),
                                  labels: PiChart.Labels(color: .piInkSecondary))
        return spec
    }
}

extension NSColor {
    /// The monitor's canvas (`Color.monitorCanvas`).
    static let monitorCanvas = piDynamic(light: NSColor(srgbRed: 0.985, green: 0.980, blue: 0.965, alpha: 1),
                                         dark: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1))
    /// A model's colour in the monitor's charts (`Color.monitorModel`).
    static func monitorModel(_ index: Int) -> NSColor {
        if index == 6 { return .piInkSecondary }
        return monitorPalette[max(0, min(5, index))]
    }
    /// Made once: a dynamic colour made anew never equals the last.
    private static let monitorPalette: [NSColor] = [
        .piBrandOrange,
        .piDynamic(light: NSColor(srgbRed: 0.08, green: 0.48, blue: 0.37, alpha: 1), dark: NSColor(srgbRed: 0.48, green: 0.80, blue: 0.69, alpha: 1)),
        .piPurple, .piInfo, .piWarning, .piDanger,
    ]
}
