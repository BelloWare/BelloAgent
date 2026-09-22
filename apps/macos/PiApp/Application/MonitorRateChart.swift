import SwiftUI
import Charts

struct MonitorRatePoint: Identifiable, Equatable {
    var id: String { "\(bin):\(model)" }
    let bin: Int
    let date: Date
    let model: String
    let rate: Double
    let segment: Int
    let cumulative: Double
}

struct MonitorRateSeries {
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

@MainActor struct MonitorRateChart: View {
    let samples: [LiveRateSample]
    let usage: MenuBarSnapshot?
    let workspace: String?
    let following: ClosedRange<Date>
    @Binding var zoom: MonitorChartZoom
    let metric: MonitorRateMetric
    let palette: MonitorModelPalette
    let selectMetric: (MonitorRateMetric) -> Void
    var showsMetricSelection = true
    var chartHeight: CGFloat = 124
    @Environment(\.colorScheme) private var colorScheme
    @State private var hover: Date?
    private var domain: ClosedRange<Date> { zoom.domain(following: following) }
    private var series: MonitorRateSeries { MonitorRateSeries(samples: samples, domain: domain, workspace: workspace) }
    private var bucket: MenuBarBucket? {
        guard let hover else { return nil }
        return usage?.buckets.first { hover >= $0.start && hover < $0.end }
    }
    var body: some View {
        let series = series
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Output tok/s").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                Spacer(minLength: 0)
                if showsMetricSelection {
                    PiTabs(selection: Binding(get: { metric }, set: { selectMetric($0) }), items: MonitorRateMetric.allCases.map { ($0, $0.rawValue) })
                }
            }
            Chart {
                if metric == .live {
                    ForEach(series.points) { point in
                        AreaMark(x: .value("Time", point.date), y: .value("tok/s", point.rate), series: .value("Segment", "\(point.model):\(point.segment)"))
                            .foregroundStyle(Color.monitorModel(palette.index(point.model)).opacity(0.60)).interpolationMethod(.linear)
                        LineMark(x: .value("Time", point.date), y: .value("Cumulative tok/s", point.cumulative), series: .value("Outline", "\(point.model):\(point.segment)"))
                            .foregroundStyle(Color.monitorModel(palette.index(point.model))).lineStyle(StrokeStyle(lineWidth: 1.4))
                        // A single observation still has a visible mark.
                        PointMark(x: .value("Time", point.date), y: .value("Model tok/s", point.rate))
                            .foregroundStyle(Color.monitorModel(palette.index(point.model))).symbolSize(series.points.count <= series.models.count ? 20 : 0)
                    }
                } else {
                    ForEach(usage?.buckets ?? []) { bucket in
                        if let rate = bucket.historicalRate.tokensPerSecond {
                            PointMark(x: .value("Time", bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)), y: .value("tok/s", rate))
                                .foregroundStyle(Color.piBrandOrange).symbolSize(30)
                        }
                    }
                }
                if let hover {
                    RuleMark(x: .value("Selected", hover)).foregroundStyle(Color.piInkSecondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: true))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color.piHairline)
                    AxisValueLabel(format: domain.upperBound.timeIntervalSince(domain.lowerBound) < 180 ? .dateTime.minute().second() : .dateTime.hour().minute()).foregroundStyle(Color.piInkSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(Color.piHairline)
                    AxisValueLabel().foregroundStyle(Color.piInkSecondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        ZStack(alignment: .topLeading) {
                            if let brush = zoom.brush,
                               let a = proxy.position(forX: brush.lowerBound), let b = proxy.position(forX: brush.upperBound) {
                                Rectangle().fill(Color.piAccent.opacity(0.16))
                                    .overlay(Rectangle().stroke(Color.piAccent, lineWidth: 1))
                                    .frame(width: max(1, b - a), height: frame.height)
                                    .offset(x: frame.minX + a, y: frame.minY).allowsHitTesting(false)
                            }
                            MonitorChartInteraction(plot: frame, domain: plotDomain(proxy, width: frame.width),
                                hover: { hover = $0 },
                                drag: { start, end, width, held in zoom.update(startX: start, x: end, width: width, domain: held) },
                                finish: { horizontal, vertical in _ = zoom.finish(horizontal: horizontal, vertical: vertical) },
                                reset: { zoom.reset(); hover = nil }, step: move)
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            // Rebuild the renderer on an intentional zoom/theme change. Swift
            // Charts can otherwise retain its former plot scale and resolved
            // dynamic colors while the surrounding labels have already changed.
            .id("\(colorScheme):\(metric.rawValue):\(zoom.range?.lowerBound.timeIntervalSince1970 ?? -1):\(zoom.range?.upperBound.timeIntervalSince1970 ?? -1)")
            .overlay {
                if metric == .live ? series.points.isEmpty : usage?.buckets.contains(where: { $0.historicalRate.tokensPerSecond != nil }) != true {
                    Text(metric == .live ? "Awaiting live usage counters" : "No timed requests in this interval")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .padding(8).background(Color.monitorCanvas.opacity(0.95), in: RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false)
                }
            }
            .focusable().onMoveCommand { direction in move(direction == .left ? -1 : direction == .right ? 1 : 0) }
            .onExitCommand { if zoom.brush != nil { zoom.cancel() } else { zoom.reset(); hover = nil } }
            .accessibilityLabel(metric.rawValue + " chart. Drag horizontally to zoom, double-click or press Escape to reset. Arrow keys inspect samples; plus zooms the middle half.")
            .accessibilityIdentifier("monitor-rate-chart")
            Text(caption(series)).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Drag to zoom").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                Spacer()
                if zoom.range != nil {
                    Button("Reset zoom") { zoom.reset() }.buttonStyle(.plain).font(PiFont.micro).foregroundStyle(Color.piAccent).accessibilityIdentifier("monitor-reset-zoom")
                }
            }
            if metric == .live, !series.models.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(series.models, id: \.self) { model in
                            Label { Text(model).lineLimit(1) } icon: { Circle().fill(Color.monitorModel(palette.index(model))).frame(width: 7, height: 7) }
                                .font(PiFont.micro).help(model)
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: 17)
            }
        }.onChange(of: metric) { _, _ in hover = nil; zoom.cancel() }
            .onDisappear { zoom.cancel() }
    }
    private func plotDomain(_ proxy: ChartProxy, width: CGFloat) -> ClosedRange<Date> {
        guard let from = proxy.value(atX: 0, as: Date.self), let until = proxy.value(atX: width, as: Date.self), from < until else { return domain }
        return from...until
    }
    private func move(_ direction: Int) {
        let step = domain.upperBound.timeIntervalSince(domain.lowerBound) / 24
        let value = (hover ?? domain.upperBound).addingTimeInterval(Double(direction) * step)
        hover = min(domain.upperBound.addingTimeInterval(-0.001), max(domain.lowerBound, value))
    }
    private func caption(_ series: MonitorRateSeries) -> String {
        if let brush = zoom.brush {
            return "\(brush.lowerBound.formatted(date: .omitted, time: .standard)) – \(brush.upperBound.formatted(date: .omitted, time: .standard)) · release to zoom"
        }
        if let hover {
            if metric == .average, let bucket {
                return "\(hover.formatted(date: .omitted, time: .shortened)) · \(menuBarRate(bucket.historicalRate.tokensPerSecond)) tok/s · \(bucket.historicalRate.samples) completed requests"
            }
            if metric == .live, let point = series.points.min(by: { abs($0.date.timeIntervalSince(hover)) < abs($1.date.timeIntervalSince(hover)) }),
               abs(point.date.timeIntervalSince(hover)) <= max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / 120) {
                let rate = series.points.filter { $0.bin == point.bin }.reduce(0) { $0 + $1.rate }
                return "\(point.date.formatted(date: .omitted, time: .standard)) · \(menuBarRate(rate)) observed tok/s across reporting requests"
            }
            return "\(hover.formatted(date: .omitted, time: .standard)) · no reported observation"
        }
        return metric == .live
            ? "Reported intervals · gaps stay empty · history since launch"
            : "Output ÷ request duration, including reasoning and first-token wait."
    }
}
