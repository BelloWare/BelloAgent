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

/// How many times a rate chart built its series and marks. A test seam: the
/// pointer moving over the plot must not rebuild either.
@MainActor enum MonitorChartRenderCount {
    private(set) static var builds = 0
    static func reset() { builds = 0 }
    static func built() { builds &+= 1 }
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
    /// Held, not observed: only the rule and the caption watch the pointer,
    /// so a mouse move never rebuilds the series or the marks.
    @State private var hover = MonitorChartHover()
    private var domain: ClosedRange<Date> { zoom.domain(following: following) }
    var body: some View {
        let domain = domain
        let series = MonitorRateSeries(samples: samples, domain: domain, workspace: workspace)
        let _ = MonitorChartRenderCount.built()
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
                        if let rate = MonitorRateAverage.rate(bucket) {
                            PointMark(x: .value("Time", MonitorRateAverage.middle(bucket)), y: .value("tok/s", rate))
                                .foregroundStyle(Color.piBrandOrange).symbolSize(30)
                        }
                    }
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
                            MonitorHoverRule(hover: hover, domain: domain, plot: frame)
                            MonitorChartInteraction(plot: frame, domain: plotDomain(proxy, width: frame.width),
                                hover: { [hover] in hover.date = $0 },
                                drag: { start, end, width, held in zoom.update(startX: start, x: end, width: width, domain: held) },
                                finish: { horizontal, vertical in _ = zoom.finish(horizontal: horizontal, vertical: vertical) },
                                reset: { [hover] in zoom.reset(); hover.date = nil }, step: { [hover] in Self.move(hover, $0, domain: domain) })
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
                // Only what falls inside the plotted interval counts: retained
                // buckets outside it are not "timed requests in this interval".
                if metric == .live ? series.points.isEmpty : !(usage?.buckets ?? []).contains(where: { MonitorRateAverage.rate($0) != nil && domain.contains(MonitorRateAverage.middle($0)) }) {
                    Text(metric == .live ? "Awaiting live usage counters" : "No timed requests in this interval")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .padding(8).background(Color.monitorCanvas.opacity(0.95), in: RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false)
                }
            }
            .focusable().onMoveCommand { direction in Self.move(hover, direction == .left ? -1 : direction == .right ? 1 : 0, domain: domain) }
            .onExitCommand { if zoom.brush != nil { zoom.cancel() } else { zoom.reset(); hover.date = nil } }
            .accessibilityLabel(metric.rawValue + " chart. Drag horizontally to zoom, double-click or press Escape to reset. Arrow keys inspect samples; plus zooms the middle half.")
            .accessibilityIdentifier("monitor-rate-chart")
            MonitorChartCaption(hover: hover, series: series, buckets: usage?.buckets ?? [], metric: metric, domain: domain, brush: zoom.brush)
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
        }.onChange(of: metric) { _, _ in hover.date = nil; zoom.cancel() }
            .onDisappear { zoom.cancel() }
    }
    private func plotDomain(_ proxy: ChartProxy, width: CGFloat) -> ClosedRange<Date> {
        guard let from = proxy.value(atX: 0, as: Date.self), let until = proxy.value(atX: width, as: Date.self), from < until else { return domain }
        return from...until
    }
    private static func move(_ hover: MonitorChartHover, _ direction: Int, domain: ClosedRange<Date>) {
        let step = domain.upperBound.timeIntervalSince(domain.lowerBound) / 24
        let value = (hover.date ?? domain.upperBound).addingTimeInterval(Double(direction) * step)
        hover.date = min(domain.upperBound.addingTimeInterval(-0.001), max(domain.lowerBound, value))
    }
}

/// Where the pointer is over a rate chart. Only the rule and the caption
/// observe it; the chart that owns it holds it without observing it.
@MainActor final class MonitorChartHover: ObservableObject {
    @Published var date: Date?
}

/// The request-average series: the app's settled decode rate of the
/// completed requests in each retained bucket, plotted at its middle.
enum MonitorRateAverage {
    static func rate(_ bucket: MenuBarBucket) -> Double? { bucket.gateway.settledThroughput.tokensPerSecond }
    static func middle(_ bucket: MenuBarBucket) -> Date { bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2) }
    static let explanation = "Provider output ÷ decode time (first token to completion) of the completed requests in each interval."
}

private struct MonitorHoverRule: View {
    @ObservedObject var hover: MonitorChartHover
    let domain: ClosedRange<Date>
    let plot: CGRect
    var body: some View {
        if let date = hover.date, domain.contains(date), domain.upperBound > domain.lowerBound {
            let x = plot.minX + plot.width * date.timeIntervalSince(domain.lowerBound) / domain.upperBound.timeIntervalSince(domain.lowerBound)
            Path { path in path.move(to: CGPoint(x: x, y: plot.minY)); path.addLine(to: CGPoint(x: x, y: plot.maxY)) }
                .stroke(Color.piInkSecondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)
        }
    }
}

private struct MonitorChartCaption: View {
    @ObservedObject var hover: MonitorChartHover
    let series: MonitorRateSeries
    let buckets: [MenuBarBucket]
    let metric: MonitorRateMetric
    let domain: ClosedRange<Date>
    let brush: ClosedRange<Date>?
    var body: some View {
        Text(caption).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
    }
    private var caption: String {
        if let brush {
            return "\(brush.lowerBound.formatted(date: .omitted, time: .standard)) – \(brush.upperBound.formatted(date: .omitted, time: .standard)) · release to zoom"
        }
        if let hover = hover.date {
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
}
