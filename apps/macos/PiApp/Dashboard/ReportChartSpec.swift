import AppKit

/// The report's retained chart as a chart value, as Swift Charts drew it:
/// requests or cost as rounded columns over each slice, latency p50 and p99
/// as curves with points and a legend, the cache hit ratio as a curve on a
/// fixed 0–100 scale; the time axis labelled under its ticks, kept inside the
/// chart, with eight points of room after the plot.
enum ReportChartSpec {
    static func make(buckets: [DashboardBucket], metric: ReportChartMetric, latency: ReportLatencyMetric, domain: ClosedRange<Date>) -> PiChart.Spec {
        var marks: [PiChart.Mark] = []
        var accessible: [PiChart.AccessibleMark] = []
        func time(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
        switch metric {
        case .latency:
            let values = buckets.map { latency == .firstToken ? $0.ttft : latency == .streaming ? $0.streaming : $0.http }
            for (bucket, value) in zip(buckets, values) {
                if let p50 = value.p50 { accessible.append(.init(series: "p50", label: "p50 at " + bucket.start.formatted(), value: "\(p50) milliseconds, \(value.samples) samples", x: time(bucket.start), y: p50)) }
                if let p99 = value.p99 { accessible.append(.init(series: "p99", label: "p99 at " + bucket.start.formatted(), value: "\(p99) milliseconds, \(value.samples) samples", x: time(bucket.start), y: p99)) }
            }
            for (_, color, read) in [("p50", NSColor.piAccent, { (v: DashboardPercentiles) in v.p50 }), ("p99", .piInfo, { (v: DashboardPercentiles) in v.p99 })] {
                let points = zip(buckets, values).compactMap { bucket, value in read(value).map { (time(bucket.start), $0) } }
                if !points.isEmpty {
                    marks.append(.line(x: points.map(\.0), y: points.map(\.1), color: color, width: 2, round: true, interpolation: .monotone))
                }
                for point in points { marks.append(.point(x: point.0, y: point.1, color: color, size: 26)) }
            }
        case .cacheRatio:
            let points = buckets.compactMap { bucket in bucket.gateway.cacheHitRatio.map { (time(bucket.start), $0 * 100) } }
            for bucket in buckets {
                if let ratio = bucket.gateway.cacheHitRatio {
                    accessible.append(.init(label: bucket.start.formatted(), value: String(format: "%.0f%% of %d reported", ratio * 100, bucket.gateway.cacheHits + bucket.gateway.cacheMisses), x: time(bucket.start), y: ratio * 100))
                }
            }
            if !points.isEmpty { marks.append(.line(x: points.map(\.0), y: points.map(\.1), color: .piSuccess, width: 2, round: true, interpolation: .monotone)) }
            for point in points { marks.append(.point(x: point.0, y: point.1, color: .piSuccess, size: 26)) }
        case .cost:
            for bucket in buckets {
                if let cost = bucket.gateway.costUSD {
                    marks.append(.rect(x0: time(bucket.start), x1: time(bucket.end), y0: 0, y1: cost, color: .piBrandOrange, cornerRadius: 3))
                    accessible.append(.init(label: bucket.start.formatted(), value: bucket.gateway.costLabel, x: time(bucket.start), y: cost))
                }
            }
        case .requests, .outputRate:
            for bucket in buckets {
                marks.append(.rect(x0: time(bucket.start), x1: time(bucket.end), y0: 0, y1: Double(bucket.requests), color: .piBrandOrange, cornerRadius: 3))
                accessible.append(.init(label: bucket.start.formatted(), value: "\(bucket.requests) requests", x: time(bucket.start), y: Double(bucket.requests)))
            }
        }
        // A bare hour reads as a day of the month; keep the date on every tick.
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let format: Date.FormatStyle = span <= 3600 ? .dateTime.hour().minute()
            : span <= 36 * 3600 ? .dateTime.month(.abbreviated).day().hour() : .dateTime.month(.abbreviated).day()
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .date, domain: .fixed(time(domain.lowerBound)...time(domain.upperBound)))
        spec.y = PiChart.Scale(kind: .number, domain: metric == .cacheRatio ? .fixed(0...100) : .automatic(includesZero: true))
        spec.marks = marks
        spec.accessibleMarks = accessible
        spec.accessibleAxes = ("Time", metric == .latency ? "Milliseconds" : metric == .cost ? "US dollars" : metric == .cacheRatio ? "Hit ratio, per cent" : "Requests")
        spec.accessibleContinuous = metric == .latency || metric == .cacheRatio
        spec.xAxis = PiChart.Axis(position: .bottom, gridline: .time(.piHairline),
                                  labels: PiChart.Labels(color: .piInkTertiary, format: .date(format), anchor: .center))
        spec.yAxis = PiChart.Axis(position: .leading, gridline: PiChart.Gridline(color: .piHairline),
                                  labels: PiChart.Labels(color: .piInkTertiary, format: metric == .cost ? .usd : .number))
        spec.plotTrailingPadding = PiSpacing.sm
        if metric == .latency { spec.legend = [PiChart.LegendItem(title: "p50", color: .piAccent), PiChart.LegendItem(title: "p99", color: .piInfo)] }
        return spec
    }
}
