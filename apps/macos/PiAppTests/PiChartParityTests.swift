import AppKit
import Charts
import SwiftUI
import XCTest
@testable import PiApp

/// The app's chart engine (`Charts/`) drawn next to the Swift Charts charts
/// it replaced, each with the configuration and data the app used, light and
/// dark: the same ticks, plot frame, marks and labels. The SwiftUI side is a
/// copy of the original chart's marks and modifiers (pointer overlays left
/// out); the AppKit side is the spec the app builds now.
///
/// Serial: the windows are on screen.
@MainActor final class PiChartParityTests: XCTestCase, SerialTestLane {
    /// Antialiasing of the same curve or edge, a fraction of a pixel apart:
    /// at most this share of a capture differs past the channel tolerance.
    static let allowedShare = 0.015
    /// Past this many channels a pixel is a real difference (a mark, a
    /// label or a gridline somewhere else): at most `strongShare` of them.
    static let strongChannel = 64
    static let strongShare = 0.0002
    /// Stacked columns and monotone curves with points: their edges fall
    /// up to half a pixel from Swift Charts' (the seams between a column's
    /// segments, a curve's stroke), never a visible move.
    static let subpixelShare = 0.007
    private var results: [PiKitParity.Result] = []

    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("CHARTPARITY " + result.description) }
    }

    /// What Swift Charts laid out: its plot frame, and where it put the
    /// ticks the engine chose (nil where it could not place a value).
    final class Layout {
        var plot: CGRect = .null
        var xTicks: [CGFloat?] = []
        var yTicks: [CGFloat?] = []
    }

    private func check<V: View>(_ name: String, size: CGSize, canvas: NSColor = .piContent, share: Double = PiChartParityTests.allowedShare,
                                strongShare: Double = PiChartParityTests.strongShare,
                                _ swiftUI: @autoclosure () -> V, _ spec: () -> PiChart.Spec,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let chart = PiChartView(spec: spec())
            chart.frame = CGRect(origin: .zero, size: size)
            let geometry = chart.resolved()
            let layout = Layout()
            let recorded = swiftUI().frame(width: size.width, height: size.height).chartOverlay { proxy in
                GeometryReader { reader in
                    let _ = {
                        layout.plot = proxy.plotFrame.map { reader[$0] } ?? .null
                        layout.xTicks = geometry.xTicks.map { tick in Self.position(proxy, x: tick.value, kind: chart.spec.x.kind) }
                        layout.yTicks = geometry.yTicks.map { tick in proxy.position(forY: tick.value) }
                    }()
                    Color.clear
                }
            }
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance, swiftUI: recorded,
                                                       appKit: SizedHost(chart, size: size), canvas: canvas)
            results.append(result)
            // The layout itself: the same plot, and every tick where Swift Charts puts it.
            XCTAssertEqual(layout.plot.minX, geometry.plot.minX, accuracy: 0.5, "\(result.name) plot left", file: file, line: line)
            XCTAssertEqual(layout.plot.maxX, geometry.plot.maxX, accuracy: 0.5, "\(result.name) plot right", file: file, line: line)
            XCTAssertEqual(layout.plot.minY, geometry.plot.minY, accuracy: 0.5, "\(result.name) plot top", file: file, line: line)
            XCTAssertEqual(layout.plot.maxY, geometry.plot.maxY, accuracy: 0.5, "\(result.name) plot bottom", file: file, line: line)
            for (tick, position) in zip(geometry.xTicks, layout.xTicks) {
                XCTAssertEqual((position ?? -999) + layout.plot.minX, tick.position, accuracy: 0.5, "\(result.name) x tick \(tick.value)", file: file, line: line)
            }
            for (tick, position) in zip(geometry.yTicks, layout.yTicks) {
                XCTAssertEqual((position ?? -999) + layout.plot.minY, tick.position, accuracy: 0.5, "\(result.name) y tick \(tick.value)", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: Self.strongChannel).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * strongShare, "\(result.name): \(strong) px differ past \(Self.strongChannel)", file: file, line: line)
            // Around the plot (labels, legend, annotations past it) no
            // allowance for mark edges applies: what is painted there is the same.
            let outside = Self.strongOutside(result, plot: geometry.plot.insetBy(dx: -3, dy: -3))
            XCTAssertLessThanOrEqual(Double(outside), Double(result.total) * Self.strongShare, "\(result.name): \(outside) px differ around the plot", file: file, line: line)
            print("CHARTPARITY \(result.name) strong=\(strong)")
        }
    }

    /// Pixels further apart than `strongChannel` outside `plot` (chart points).
    private static func strongOutside(_ result: PiKitParity.Result, plot: CGRect) -> Int {
        let a = result.swiftUIImage, b = result.appKitImage
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return a.pixelsWide * a.pixelsHigh }
        let scale = CGFloat(a.pixelsWide) / result.size.width
        let inner = CGRect(x: (plot.minX + PiKitParity.margin) * scale, y: (plot.minY + PiKitParity.margin) * scale, width: plot.width * scale, height: plot.height * scale)
        var count = 0
        var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where !inner.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
                if (0..<3).contains(where: { abs(p[$0] - q[$0]) > strongChannel }) { count += 1 }
            }
        }
        return count
    }

    /// Where Swift Charts puts an x value, of the chart's kind.
    private static func position(_ proxy: ChartProxy, x value: Double, kind: PiChart.Kind) -> CGFloat? {
        switch kind {
        case .date: return proxy.position(forX: Date(timeIntervalSinceReferenceDate: value))
        case .band: return proxy.position(forX: String(Int(value)))
        case .number: return proxy.position(forX: value)
        }
    }

    /// A chart at a fixed size, as the parity capture asks views for theirs.
    final class SizedHost: NSView {
        let size: CGSize
        init(_ view: NSView, size: CGSize) {
            self.size = size
            super.init(frame: CGRect(origin: .zero, size: size))
            view.frame = bounds; view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: NSSize { size }
        override var isFlipped: Bool { true }
    }

    // MARK: Fixtures

    /// A fixed afternoon, so the ticks fall the same on every run.
    static let until = Date(timeIntervalSince1970: 1_790_000_123)

    /// Three models over fifteen minutes with a gap, as the monitor records them.
    static func monitorSamples(until: Date, span: TimeInterval) -> [LiveRateSample] {
        let start = Int(until.timeIntervalSince1970 - span)
        var samples: [LiveRateSample] = []
        for second in stride(from: start, to: Int(until.timeIntervalSince1970), by: max(1, Int(span / 300))) {
            let t = Double(second - start)
            let gap = (t > span * 0.42 && t < span * 0.47)
            var rates: [LiveRateKey: Double] = [:]
            if !gap {
                rates[LiveRateKey(workspace: "p", model: "GPT-5.4 mini")] = 30 + 12 * sin(t / span * 9)
                rates[LiveRateKey(workspace: "p", model: "Claude Sonnet")] = 22 + 9 * cos(t / span * 7)
                if t > span * 0.3 { rates[LiveRateKey(workspace: "p", model: "GPT-5.4")] = 14 + 6 * sin(t / span * 13) }
            }
            samples.append(LiveRateSample(id: second, end: second + 1, rates: rates, active: 3, reported: gap ? 0 : 3, gap: gap))
        }
        return samples
    }

    static func palette(_ names: [String]) -> MonitorModelPalette {
        var palette = MonitorModelPalette(); palette.include(names); return palette
    }

    // MARK: The monitor's rate chart

    func testMonitorLiveRateChart() async throws {
        for span in [900.0, 120.0, 3_600.0] {
            let domain = Self.until.addingTimeInterval(-span)...Self.until
            let samples = Self.monitorSamples(until: Self.until, span: span)
            let series = MonitorRateSeries(samples: samples, domain: domain, workspace: nil)
            let palette = Self.palette(series.models)
            try await check("monitor-live-\(Int(span))", size: CGSize(width: 444, height: 124), canvas: .monitorCanvas,
                            MonitorRateChartReference(series: series, buckets: [], metric: .live, domain: domain, palette: palette)) {
                MonitorRateChartSpec.make(series: series, buckets: [], metric: .live, domain: domain, palette: palette)
            }
        }
    }

    func testMonitorAverageRateChart() async throws {
        let domain = Self.until.addingTimeInterval(-86_400)...Self.until
        let buckets: [MenuBarBucket] = (0..<24).map { hour in
            var gateway = GatewayTotals(requests: 3)
            gateway.decodeMilliseconds = 10_000 + Double(hour) * 900; gateway.decodeOutputTokens = 400 + Double(hour * 37 % 200); gateway.decodeSamples = 3
            let start = domain.lowerBound.addingTimeInterval(Double(hour) * 3_600)
            return MenuBarBucket(id: hour, start: start, end: start.addingTimeInterval(3_600), gateway: gateway)
        }
        let series = MonitorRateSeries(samples: [], domain: domain, workspace: nil)
        try await check("monitor-average", size: CGSize(width: 444, height: 180), canvas: .monitorCanvas,
                        MonitorRateChartReference(series: series, buckets: buckets, metric: .average, domain: domain, palette: MonitorModelPalette())) {
            MonitorRateChartSpec.make(series: series, buckets: buckets, metric: .average, domain: domain, palette: MonitorModelPalette())
        }
    }
    // MARK: Tick choices

    /// The ticks Swift Charts chose, as its axis label closures were called
    /// for them, for the axes the app draws with automatic ticks, against the
    /// engine's own choice, over each chart's spans and many phases.
    func testAutomaticTicksAreTheOnesSwiftChartsChooses() async throws {
        final class Recorder { var values: Set<Double> = [] }
        func recorded<V: View>(_ view: V, size: CGSize) async throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await eventually("the chart laid out", timeout: .seconds(5), poll: .milliseconds(20)) { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return host.fittingSize.width > 0 }
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        let offset = Date.timeIntervalBetween1970AndReferenceDate
        // Time axes: the monitor's (desired 4) and the default, over the spans the app shows.
        let spans: [Double] = [60, 300, 900, 3_600, 21_600, 86_400, 604_800, 2_592_000, 47, 133, 2_222, 40_000]
        for (index, span) in spans.enumerated() {
            let until = Self.until.addingTimeInterval(Double(index) * 977.3)
            let from = until.addingTimeInterval(-span)
            for desired in [4, nil] as [Int?] {
                let recorder = Recorder()
                try await recorded(Chart { PointMark(x: .value("t", from.addingTimeInterval(span / 2)), y: .value("y", 1.0)) }
                    .chartXScale(domain: from...until).chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: desired.map { .automatic(desiredCount: $0) } ?? .automatic) { value in
                            AxisValueLabel { let _ = recorder.values.insert((value.as(Date.self) ?? .distantPast).timeIntervalSince1970.rounded()); Text("x") }
                        }
                    }, size: CGSize(width: 444, height: 124))
                let engine = PiChartTicks.dates(from.timeIntervalSinceReferenceDate...until.timeIntervalSinceReferenceDate).map { ($0 + offset).rounded() }
                XCTAssertEqual(recorder.values.sorted(), engine, "span \(span) desired \(desired.map(String.init) ?? "-")")
            }
        }
        // Number axes from zero: the monitor's (desired 3) and the default.
        for top in [0.7, 3.3, 8.8, 14, 27, 55, 64, 130, 512, 999, 1_600, 8_000, 33_000, 250_000] {
            for desired in [3, nil] as [Int?] {
                let recorder = Recorder()
                try await recorded(Chart { PointMark(x: .value("x", 0.0), y: .value("y", 0.0)); PointMark(x: .value("x", 1.0), y: .value("y", top)) }
                    .chartXAxis(.hidden).chartYScale(domain: .automatic(includesZero: true))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: desired.map { .automatic(desiredCount: $0) } ?? .automatic) { value in
                            AxisValueLabel { let _ = recorder.values.insert(value.as(Double.self) ?? .nan); Text("x") }
                        }
                    }, size: CGSize(width: 300, height: 124))
                let (domain, step) = PiChartTicks.automaticDomain(0, top, desiredCount: desired)
                let engine = PiChartTicks.multiples(of: step, in: domain)
                XCTAssertEqual(recorder.values.sorted().count, engine.count, "top \(top) desired \(desired.map(String.init) ?? "-")")
                for (a, b) in zip(recorder.values.sorted(), engine) { XCTAssertEqual(a, b, accuracy: max(1e-9, abs(b) * 1e-9), "top \(top)") }
            }
        }
        // The cache ratio's fixed 0–100 axis.
        let recorder = Recorder()
        try await recorded(Chart { PointMark(x: .value("x", 0.0), y: .value("y", 40.0)) }.chartXAxis(.hidden).chartYScale(domain: 0.0...100.0)
            .chartYAxis { AxisMarks(position: .leading) { value in AxisValueLabel { let _ = recorder.values.insert(value.as(Double.self) ?? .nan); Text("x") } } },
                           size: CGSize(width: 300, height: 200))
        XCTAssertEqual(recorder.values.sorted(), PiChartTicks.numbers(0...100, desiredCount: nil))
    }

    // MARK: The usage panel's chart

    static func usageBuckets(hours: Int, until: Date) -> [MenuBarBucket] {
        let width = hours <= 24 ? 3_600.0 : 86_400.0
        let count = hours <= 24 ? hours : hours / 24
        return (0..<count).map { i in
            var gateway = GatewayTotals(requests: (i * 7 % 11) + (i % 3 == 0 ? 0 : 2), costSamples: 3, costUSD: Double(i * 13 % 17) * 0.0137)
            gateway.tokens = GatewayTokenTotals(input: Double(i * 3_100 % 41_000), output: Double(i * 900 % 7_000), total: Double(i * 4_000 % 48_000), inputSamples: 3, outputSamples: 3, samples: 3)
            gateway.decodeMilliseconds = 9_000 + Double(i) * 300; gateway.decodeOutputTokens = 300 + Double(i * 41 % 300); gateway.decodeSamples = 3
            let start = until.addingTimeInterval(-Double(count - i) * width)
            return MenuBarBucket(id: i, start: start, end: start.addingTimeInterval(width), gateway: gateway)
        }
    }

    func testMenuBarUsageChart() async throws {
        for (hours, metric) in [(24, MenuBarChartMetric.requests), (24, .tokens), (24 * 7, .cost), (24 * 7, .rate), (24 * 30, .requests)] {
            let buckets = Self.usageBuckets(hours: hours, until: Self.until)
            let domain = (buckets.first?.start ?? Self.until)...Self.until
            let selected = metric == .cost ? buckets[2] : nil
            try await check("usage-\(hours)-\(metric.rawValue)", size: CGSize(width: 420, height: 110),
                            MenuBarUsageChartReference(buckets: buckets, metric: metric, domain: domain, selected: selected)) {
                MenuBarUsageChartSpec.make(buckets: buckets, metric: metric, domain: domain, selected: selected)
            }
        }
    }

    // MARK: The report's retained chart

    static func reportBuckets(span: TimeInterval, count: Int, until: Date) -> [DashboardBucket] {
        let width = span / Double(count)
        return (0..<count).map { i in
            var bucket = DashboardBucket(id: i, start: until.addingTimeInterval(-span + Double(i) * width), end: until.addingTimeInterval(-span + Double(i + 1) * width))
            bucket.requests = (i * 5 % 9) + 1
            bucket.ttft = DashboardPercentiles(samples: 4, p50: 400 + Double(i * 97 % 600), p99: 1_200 + Double(i * 211 % 900))
            bucket.gateway = GatewayTotals(requests: bucket.requests, costSamples: bucket.requests, costUSD: Double(i * 7 % 10) * 0.21)
            bucket.gateway.cacheHits = i % 4; bucket.gateway.cacheMisses = 3 - i % 4
            return bucket
        }
    }

    func testReportRetainedChart() async throws {
        for (span, metric) in [(86_400.0, ReportChartMetric.requests), (86_400.0, .latency), (7 * 86_400.0, .cost), (3_600.0, .cacheRatio), (30 * 86_400.0, .requests)] {
            let buckets = Self.reportBuckets(span: span, count: 24, until: Self.until)
            let domain = Self.until.addingTimeInterval(-span)...Self.until
            try await check("report-\(Int(span))-\(metric)", size: CGSize(width: 560, height: 200), strongShare: metric == .latency ? Self.subpixelShare : Self.strongShare,
                            ReportChartReference(buckets: buckets, metric: metric, domain: domain)) {
                ReportChartSpec.make(buckets: buckets, metric: metric, latency: .firstToken, domain: domain)
            }
        }
    }
    // MARK: The Session Inspector's Overview charts

    func testSessionCharts() async throws {
        for count in [5, 18, 40, 120] {
            let history = SessionStatsFixture.session(requests: count)
            let inputs = SessionStatsFixture.inputs(history)
            let time = SessionTimeCharts(inputs: inputs, history: history)
            let tokens = SessionTokenCharts(inputs: inputs, history: history)
            if let timeline = time.timeline {
                let height = CGFloat(timeline.rows.count) * SessionStatsChartSpecs.timelinePitch(timeline.rows.count) + 20
                // Thin bars: many edges, each antialiased a fraction of a pixel apart.
                try await check("session-timeline-\(count)", size: CGSize(width: 436, height: height), canvas: .piSurface, share: 0.07,
                                SessionTimelineReference(timeline: timeline)) { SessionStatsChartSpecs.timeline(timeline) }
            }
            if let speed = time.speed {
                try await check("session-speed-\(count)", size: CGSize(width: 400, height: SessionSpeedSeries.plotHeight), canvas: .piSurface,
                                SessionSpeedReference(speed: speed)) { SessionStatsChartSpecs.speed(speed) }
            }
            if let bars = tokens.perRequest {
                try await check("session-tokens-\(count)", size: CGSize(width: 400, height: SessionTokenBars.plotHeight), canvas: .piSurface,
                                share: 0.05, strongShare: Self.subpixelShare,
                                SessionTokenBarsReference(bars: bars)) { SessionStatsChartSpecs.tokenBars(bars) }
            }
            if let cost = tokens.cost {
                try await check("session-cost-\(count)", size: CGSize(width: 400, height: SessionCostSeries.plotHeight), canvas: .piSurface,
                                SessionCostReference(cost: cost)) { SessionStatsChartSpecs.cost(cost) }
            }
        }
    }
}

/// The marks and axes of the SwiftUI `MonitorRateChart` (0.1.119), without
/// its pointer overlay.
private struct MonitorRateChartReference: View {
    let series: MonitorRateSeries
    let buckets: [MenuBarBucket]
    let metric: MonitorRateMetric
    let domain: ClosedRange<Date>
    let palette: MonitorModelPalette
    var body: some View {
        Chart {
            if metric == .live {
                ForEach(series.points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("tok/s", point.rate), series: .value("Segment", "\(point.model):\(point.segment)"))
                        .foregroundStyle(Color(nsColor: .monitorModel(palette.index(point.model))).opacity(0.60)).interpolationMethod(.linear)
                    LineMark(x: .value("Time", point.date), y: .value("Cumulative tok/s", point.cumulative), series: .value("Outline", "\(point.model):\(point.segment)"))
                        .foregroundStyle(Color(nsColor: .monitorModel(palette.index(point.model)))).lineStyle(StrokeStyle(lineWidth: 1.4))
                    PointMark(x: .value("Time", point.date), y: .value("Model tok/s", point.rate))
                        .foregroundStyle(Color(nsColor: .monitorModel(palette.index(point.model)))).symbolSize(series.points.count <= series.models.count ? 20 : 0)
                }
            } else {
                ForEach(buckets) { bucket in
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
    }
}

/// The SwiftUI usage panel's chart (0.1.119), without its selection gesture.
private struct MenuBarUsageChartReference: View {
    let buckets: [MenuBarBucket]
    let metric: MenuBarChartMetric
    let domain: ClosedRange<Date>
    let selected: MenuBarBucket?
    var body: some View {
        let axisFormat: Date.FormatStyle = domain.upperBound.timeIntervalSince(domain.lowerBound) <= 36 * 3600 ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
        Chart {
            ForEach(buckets) { bucket in
                switch metric {
                case .requests:
                    RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Count", 0), yEnd: .value("Count", bucket.requests))
                        .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                case .tokens:
                    if let tokens = bucket.gateway.tokens?.total {
                        RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Tokens", 0), yEnd: .value("Tokens", tokens)).foregroundStyle(Color.piAccent)
                    }
                case .cost:
                    if let cost = bucket.gateway.costUSD {
                        RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("USD", 0), yEnd: .value("USD", cost))
                            .foregroundStyle(Color.piBrandOrange).cornerRadius(2)
                    }
                case .rate:
                    if let rate = MenuBarRateText.rate(bucket) {
                        PointMark(x: .value("Time", bucket.start), y: .value("tok/s", rate)).foregroundStyle(Color.piAccent).symbolSize(22)
                    }
                }
            }
            if let selected { RuleMark(x: .value("Selected", selected.start)).foregroundStyle(Color.piInkTertiary) }
        }
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.piHairline)
                if metric == .cost, let usd = value.as(Double.self) {
                    AxisValueLabel { Text(compactGatewayUSD(usd)) }.foregroundStyle(Color.piInkTertiary)
                } else {
                    AxisValueLabel().foregroundStyle(Color.piInkTertiary)
                }
            }
        }
        .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat).foregroundStyle(Color.piInkTertiary) } }
    }
}

/// The SwiftUI report's retained chart (0.1.119), without its brush.
private struct ReportChartReference: View {
    let buckets: [DashboardBucket]
    let metric: ReportChartMetric
    let domain: ClosedRange<Date>
    var body: some View {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let axisFormat: Date.FormatStyle = span <= 3600 ? .dateTime.hour().minute()
            : span <= 36 * 3600 ? .dateTime.month(.abbreviated).day().hour() : .dateTime.month(.abbreviated).day()
        Chart(buckets) { bucket in
            if metric == .latency {
                let values = bucket.ttft
                if let p50 = values.p50 {
                    LineMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p50), series: .value("Percentile", "p50")).foregroundStyle(by: .value("Percentile", "p50")).interpolationMethod(.monotone)
                    PointMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p50)).foregroundStyle(by: .value("Percentile", "p50")).symbolSize(26)
                }
                if let p99 = values.p99 {
                    LineMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p99), series: .value("Percentile", "p99")).foregroundStyle(by: .value("Percentile", "p99")).interpolationMethod(.monotone)
                    PointMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p99)).foregroundStyle(by: .value("Percentile", "p99")).symbolSize(26)
                }
            } else if metric == .cacheRatio {
                if let ratio = bucket.gateway.cacheHitRatio {
                    LineMark(x: .value("Time", bucket.start), y: .value("Hit ratio", ratio * 100)).foregroundStyle(Color.piSuccess).interpolationMethod(.monotone)
                    PointMark(x: .value("Time", bucket.start), y: .value("Hit ratio", ratio * 100)).foregroundStyle(Color.piSuccess).symbolSize(26)
                }
            } else if metric == .cost {
                if let cost = bucket.gateway.costUSD {
                    RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("USD", 0), yEnd: .value("USD", cost))
                        .foregroundStyle(Color.piBrandOrange).cornerRadius(3)
                }
            } else {
                RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Count", 0), yEnd: .value("Count", bucket.requests))
                    .foregroundStyle(Color.piBrandOrange).cornerRadius(3)
            }
        }
        .chartXScale(domain: domain)
        .chartPercentScale(metric == .cacheRatio)
        .chartForegroundStyleScale(["p50": Color.piAccent, "p99": Color.piInfo])
        .chartLegend(metric == .latency ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.piHairline)
                if metric == .cost, let usd = value.as(Double.self) {
                    AxisValueLabel { Text(compactGatewayUSD(usd)) }.foregroundStyle(Color.piInkTertiary)
                } else {
                    AxisValueLabel().foregroundStyle(Color.piInkTertiary)
                }
            }
        }
        .chartXAxis { AxisMarks(preset: .aligned) { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat, centered: false, anchor: .top).foregroundStyle(Color.piInkTertiary) } }
        .chartPlotStyle { $0.padding(.trailing, PiSpacing.sm) }
    }
}

/// The SwiftUI session timeline's chart (0.1.119), without its pointer overlay.
private struct SessionTimelineReference: View {
    let timeline: SessionRequestTimeline
    var body: some View {
        let rows = timeline.rows, count = rows.count, pitch = SessionStatsChartSpecs.timelinePitch(count)
        let thickness = max(3, pitch - (pitch >= 12 ? 5 : 2))
        let gap = timeline.domain * 0.005
        Chart {
            ForEach(rows) { row in
                let y = Double(count - 1 - row.index)
                if row.band {
                    RectangleMark(xStart: .value("From", 0.0), xEnd: .value("To", timeline.domain), yStart: .value("Top", y - 0.5), yEnd: .value("Bottom", y + 0.5))
                        .foregroundStyle(Color.piInk.opacity(0.035))
                }
                if row.failed {
                    BarMark(xStart: .value("Start", 0.0), xEnd: .value("Failed", max(row.unsplit, timeline.domain * 0.004)), y: .value("Request", y), height: .fixed(thickness))
                        .foregroundStyle(Color.piDanger.opacity(0.75)).cornerRadius(1.5)
                } else if row.unsplit > 0 {
                    BarMark(xStart: .value("Start", 0.0), xEnd: .value("Request", row.unsplit), y: .value("Request", y), height: .fixed(thickness))
                        .foregroundStyle(Color.piInkTertiary.opacity(0.6)).cornerRadius(1.5)
                } else {
                    if row.waiting > 0 {
                        BarMark(xStart: .value("Start", 0.0), xEnd: .value("First token", row.waiting), y: .value("Request", y), height: .fixed(thickness))
                            .foregroundStyle(Color(nsColor: .sessionTime(.waiting))).cornerRadius(1.5)
                    }
                    if row.generating > 0 {
                        BarMark(xStart: .value("Generating from", row.waiting > 0 ? row.waiting + gap : 0),
                                xEnd: .value("Complete", max(row.waiting + gap * 2, row.waiting + row.generating)), y: .value("Request", y), height: .fixed(thickness))
                            .foregroundStyle(Color(nsColor: .sessionTime(.generating))).cornerRadius(1.5)
                    }
                }
                if let marker = row.marker {
                    PointMark(x: .value("End", row.end), y: .value("Request", y)).symbolSize(0)
                        .annotation(position: .trailing, alignment: .leading, spacing: SessionStatsFormat.markerSpacing,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(marker).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                        }
                }
            }
        }
        .chartXScale(domain: 0...timeline.domain)
        .chartYScale(domain: -0.5...(Double(count) - 0.5))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: timeline.ticks) { value in
                let milliseconds = value.as(Double.self) ?? 0
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.piHairline)
                AxisValueLabel(anchor: timeline.anchor(forTick: milliseconds).unitPoint, collisionResolution: .disabled) {
                    Text(timeline.label(forTick: milliseconds)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                }
            }
        }
    }
}

private struct SessionSpeedReference: View {
    let speed: SessionSpeedSeries
    var body: some View {
        let points = speed.points
        Chart {
            if let average = speed.average {
                RuleMark(y: .value("Session average", average)).foregroundStyle(Color.piInkSecondary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(points) { point in
                PointMark(x: .value("Request", point.x), y: .value("tok/s", point.rate))
                    .foregroundStyle(speed.models.isEmpty ? Color.piBrandOrange : Color(nsColor: .monitorModel(point.colorIndex)))
                    .symbolSize(points.count > 80 ? 16 : 34)
            }
        }
        .chartXScale(domain: speed.xDomain)
        .chartYScale(domain: 0...speed.yMaximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: speed.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.piHairline)
                AxisValueLabel {
                    if let rate = value.as(Double.self) { Text(speed.label(forTick: rate)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
            }
        }
    }
}

private struct SessionTokenBarsReference: View {
    let bars: SessionTokenBars
    var body: some View {
        let items = bars.bars
        Chart {
            ForEach(items) { bar in
                let stack = bars.stacks[bar.index], category = bars.categories[bar.index]
                ForEach(stack.indices, id: \.self) { offset in
                    BarMark(x: .value("Request", category), yStart: .value("From", stack[offset].from), yEnd: .value("To", stack[offset].to),
                            width: items.count <= 14 ? .fixed(18) : .ratio(items.count > 48 ? 0.8 : 0.66))
                        .foregroundStyle(Color(nsColor: .sessionTokens(stack[offset].kind)))
                }
            }
            if let last = items.last, let label = bars.endLabel {
                PointMark(x: .value("Request", bars.categories[last.index]), y: .value("Tokens", last.total)).symbolSize(0)
                    .annotation(position: .top, spacing: SessionStatsFormat.endLabelSpacing, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(label).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    }
            }
        }
        .chartXScale(domain: bars.categories)
        .chartYScale(domain: 0...bars.yMaximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: bars.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.piHairline)
                AxisValueLabel {
                    if let tokens = value.as(Double.self) { Text(bars.label(forTick: tokens)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
            }
        }
    }
}

private struct SessionCostReference: View {
    let cost: SessionCostSeries
    var body: some View {
        let points = cost.points
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Request", point.x), y: .value("USD", point.cumulative)).foregroundStyle(Color.piBrandOrange.opacity(0.12)).interpolationMethod(.linear)
                LineMark(x: .value("Request", point.x), y: .value("USD", point.cumulative))
                    .foregroundStyle(Color.piBrandOrange).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).interpolationMethod(.linear)
            }
            if let last = points.last, let label = cost.endLabel {
                PointMark(x: .value("Request", last.x), y: .value("USD", last.cumulative)).foregroundStyle(Color.piBrandOrange).symbolSize(28)
                    .annotation(position: .leading, alignment: .trailing, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(label).font(PiFont.micro.weight(.semibold)).foregroundStyle(Color.piInk).monospacedDigit()
                    }
            }
        }
        .chartXScale(domain: cost.xDomain)
        .chartYScale(domain: 0...cost.yMaximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: cost.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.piHairline)
                AxisValueLabel {
                    if let usd = value.as(Double.self) { Text(cost.label(forTick: usd)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
            }
        }
    }
}

extension View {
    /// The report chart's fixed 0–100 % y-scale for ratio series (Dashboard/DashboardCharts.swift at 9ca27dc8).
    @ViewBuilder func chartPercentScale(_ percent: Bool) -> some View {
        if percent { chartYScale(domain: 0.0...100.0) } else { self }
    }
}
