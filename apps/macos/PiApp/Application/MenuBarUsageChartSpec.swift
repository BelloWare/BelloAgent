import AppKit

/// The usage panel's chart as a chart value, as Swift Charts drew it:
/// requests or cost as rounded columns over each slice, tokens as plain
/// columns, the decode rate as points, and the selected slice's rule.
enum MenuBarUsageChartSpec {
    static func make(buckets: [MenuBarBucket], metric: MenuBarChartMetric, domain: ClosedRange<Date>, selected: MenuBarBucket?) -> PiChart.Spec {
        var marks: [PiChart.Mark] = []
        var accessible: [PiChart.AccessibleMark] = []
        for bucket in buckets {
            let x0 = bucket.start.timeIntervalSinceReferenceDate, x1 = bucket.end.timeIntervalSinceReferenceDate
            switch metric {
            case .requests:
                marks.append(.rect(x0: x0, x1: x1, y0: 0, y1: Double(bucket.requests), color: .piBrandOrange, cornerRadius: 2))
                accessible.append(.init(label: bucket.start.formatted(), value: "\(bucket.requests) requests", x: x0, y: Double(bucket.requests)))
            case .tokens:
                if let tokens = bucket.gateway.tokens?.total {
                    marks.append(.rect(x0: x0, x1: x1, y0: 0, y1: tokens, color: .piAccent, cornerRadius: 0))
                    accessible.append(.init(label: bucket.start.formatted(), value: menuBarTokens(tokens) + " tokens", x: x0, y: tokens))
                }
            case .cost:
                if let cost = bucket.gateway.costUSD {
                    marks.append(.rect(x0: x0, x1: x1, y0: 0, y1: cost, color: .piBrandOrange, cornerRadius: 2))
                    accessible.append(.init(label: bucket.start.formatted(), value: bucket.gateway.costLabel, x: x0, y: cost))
                }
            case .rate:
                if let rate = MenuBarRateText.rate(bucket) {
                    marks.append(.point(x: x0, y: rate, color: .piAccent, size: 22))
                    accessible.append(.init(label: bucket.start.formatted(), value: MenuBarRateText.point(bucket), x: x0, y: rate))
                }
            }
        }
        if let selected { marks.append(.rule(x: selected.start.timeIntervalSinceReferenceDate, y: nil, color: .piInkTertiary, width: 2, dash: [])) }
        let day = domain.upperBound.timeIntervalSince(domain.lowerBound) <= 36 * 3600
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .date, domain: .fixed(domain.lowerBound.timeIntervalSinceReferenceDate...domain.upperBound.timeIntervalSinceReferenceDate))
        spec.y = PiChart.Scale(kind: .number, domain: .automatic(includesZero: true))
        spec.marks = marks
        spec.accessibleMarks = accessible
        spec.accessibleAxes = ("Time", metric.title)
        spec.xAxis = PiChart.Axis(position: .bottom, gridline: .time(.piHairline),
                                  labels: PiChart.Labels(color: .piInkTertiary, format: .date(day ? .dateTime.hour() : .dateTime.month(.abbreviated).day()), anchor: .after))
        spec.yAxis = PiChart.Axis(position: .leading, gridline: PiChart.Gridline(color: .piHairline),
                                  labels: PiChart.Labels(color: .piInkTertiary, format: metric == .cost ? .usd : .number))
        return spec
    }
}
