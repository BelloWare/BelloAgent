import SwiftUI
import Charts

/// Hover is a preview; clicking pins it open for keyboard and chart interaction.
/// A short close delay lets the pointer cross the gap into the native popover.
@MainActor final class SessionTimingHover: ObservableObject {
    @Published private(set) var presented = false
    private(set) var pinned = false
    private var triggerInside = false
    private var panelInside = false
    private var transition: Task<Void, Never>?
    private let openDelay: Duration
    private let closeDelay: Duration

    init(openDelay: Duration = .milliseconds(220), closeDelay: Duration = .milliseconds(250)) {
        self.openDelay = openDelay; self.closeDelay = closeDelay
    }
    func triggerHover(_ inside: Bool) { triggerInside = inside; update() }
    func panelHover(_ inside: Bool) { panelInside = inside; update() }
    func togglePinned() {
        transition?.cancel(); transition = nil
        if presented && pinned { dismiss() }
        else { pinned = true; presented = true }
    }
    func dismiss() {
        transition?.cancel(); transition = nil
        presented = false; pinned = false; panelInside = false
    }
    func stop() { triggerInside = false; dismiss() }
    private func update() {
        transition?.cancel(); transition = nil
        guard !pinned else { return }
        let show = triggerInside || panelInside
        guard show != presented else { return }
        transition = Task { [weak self, delay = show ? openDelay : closeDelay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, !pinned, show == (triggerInside || panelInside) else { return }
            presented = show
        }
    }
}

/// One stable sidebar slot. No per-second clock or streamed-byte measurement
/// participates; a local fade happens only when completed usage changes.
struct SidebarReportedRate: View {
    let history: SessionTimingHistory
    let sessionTitle: String
    @StateObject private var hover = SessionTimingHover()
    private var presentation: SessionRatePresentation { SessionRatePresentation(history: history) }
    var body: some View {
        Button(action: hover.togglePinned) {
            Text(presentation.label)
                .font(PiFont.caption.monospacedDigit()).lineLimit(1)
                .frame(width: 108, alignment: .leading)
                .foregroundStyle(presentation.latest == nil ? Color.piInkTertiary : Color.piInkSecondary)
                .contentTransition(.opacity).piAnimation(PiMotion.quick, value: presentation.label)
        }
        .buttonStyle(.plain).piPointer()
        .help(SessionRatePresentation.explanation)
        .accessibilityLabel("Latest completed output rate")
        .accessibilityValue(presentation.label)
        .accessibilityHint("Show session timing history and average")
        .accessibilityIdentifier("sidebar-reported-rate")
        .onHover(perform: hover.triggerHover)
        .popover(isPresented: Binding(get: { hover.presented }, set: { if !$0 { hover.dismiss() } }), arrowEdge: .trailing) {
            SessionTimingHistoryView(history: history, sessionTitle: sessionTitle, close: hover.dismiss)
                .onHover(perform: hover.panelHover)
        }
        .onDisappear { hover.stop() }
        .piStableLayout()
    }
}

struct SessionTimingHistoryView: View {
    let history: SessionTimingHistory
    let sessionTitle: String
    let close: () -> Void
    /// Held, not observed: the charts' rules and the request line watch it,
    /// so a hover never redraws the popover or rebuilds a chart's marks.
    @State private var selection = SessionTimingSelection()
    /// The charts' points and accessibility strings. The popover is rebuilt
    /// whenever its chat row redraws; they are formatted once per history.
    @State private var charts = SessionTimingSeriesMemo(metrics: SessionTimingMetric.footerMetrics)
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Response timing").font(PiFont.heading)
                    Text(sessionTitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
                }
                Spacer()
                PiIconButton(symbol: "xmark", label: "Close timing history", size: 22, action: close)
            }
            if history.samples.isEmpty {
                PiNote("No completed requests with retained metrics yet.")
            } else {
                HStack(spacing: PiSpacing.md) {
                    latest(.ttft)
                    latest(.rate)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Session average").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                        Text(SessionTimingMetric.rate.label(history.settledThroughput.tokensPerSecond))
                            .font(PiFont.body.weight(.semibold)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Average: \(history.settledThroughput.samples)/\(history.samples.count) listed requests measured.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                ForEach(charts.series(for: history), id: \.metric.rawValue) {
                    SessionTimingChart(series: $0, selection: selection)
                }
                SessionTimingSelectedRequest(history: history, selection: selection)
            }
            Text(history.hasOlderRequests ? "Most recent \(history.samples.count) completed requests in this session." : "\(history.samples.count) completed requests in this session.")
                .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            Text(SettledThroughput.explanation + " The session figure divides the summed tokens after each request's first by their summed generation time; gaps indicate missing measurements.")
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(PiSpacing.lg).frame(width: 430).foregroundStyle(Color.piInk)
        .accessibilityIdentifier("session-timing-history")
        .onChange(of: history) { _, _ in selection.select(nil) }
    }

    private func latest(_ metric: SessionTimingMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric == .ttft ? "Latest TTFT" : "Latest output rate").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            Text(metric.label(history.latest.flatMap { metric.value(in: $0) })).font(PiFont.body.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The popover's line for the request under the pointer, else the latest.
private struct SessionTimingSelectedRequest: View {
    let history: SessionTimingHistory
    @ObservedObject var selection: SessionTimingSelection
    var body: some View {
        let _ = SessionTimingRenderCount.captionDrawn()
        let index = selection.request.flatMap { history.samples.indices.contains($0 - 1) ? $0 : nil }
        if let sample = index.map({ history.samples[$0 - 1] }) ?? history.latest {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                HStack(spacing: 5) {
                    Text(index.map { "Request \($0)" } ?? "Latest")
                    Text("· " + sample.wall.formatted(date: .abbreviated, time: .standard))
                    Spacer(minLength: 0)
                }.font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                // The request's settled rate, as the tile and the chart
                // above quote it: never output over the whole round trip.
                Text(SessionTimingMetric.ttft.label(sample.ttftMilliseconds) + " TTFT · " + SessionTimingMetric.rate.label(SessionTimingMetric.rate.value(in: sample)))
                    .font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInk)
            }
        }
    }
}

/// The request the pointer is on in a set of timing charts. The charts only
/// write it; each chart's rule and the request caption are the views that
/// observe it, so a hover never rebuilds the marks or the page around them.
@MainActor final class SessionTimingSelection: ObservableObject {
    @Published var request: Int?
    /// Every pointer event lands here: a step within the same request is not
    /// a change and publishes nothing.
    func select(_ request: Int?) { if self.request != request { self.request = request } }
}

/// A metric's plotted points and their accessibility strings, formatted once
/// per history: moving the pointer never formats a date or a figure again.
struct SessionTimingSeries: Equatable {
    struct Point: Identifiable, Equatable {
        let id: String
        let index: Int
        let segment: Int
        let value: Double
        /// When the request ran, and its figure, as VoiceOver reads them.
        let wall: String
        let figure: String
    }
    let metric: SessionTimingMetric
    let points: [Point]
    /// Every listed request, observed or not: the x axis spans them all.
    let requests: Int
    init(history: SessionTimingHistory, metric: SessionTimingMetric) {
        self.metric = metric; requests = history.samples.count
        points = history.points(for: metric).map {
            Point(id: $0.id, index: $0.index, segment: $0.segment, value: $0.value,
                  wall: $0.wall.formatted(date: .abbreviated, time: .standard), figure: metric.label($0.value))
        }
    }
    static func all(_ history: SessionTimingHistory, metrics: [SessionTimingMetric] = SessionTimingMetric.allCases) -> [SessionTimingSeries] {
        metrics.map { SessionTimingSeries(history: history, metric: $0) }
    }
}

/// The series of the last history a view drew, rebuilt only when the history
/// changes: comparing two histories is far cheaper than formatting them.
@MainActor final class SessionTimingSeriesMemo {
    let metrics: [SessionTimingMetric]
    private var history: SessionTimingHistory?
    private var series: [SessionTimingSeries] = []
    init(metrics: [SessionTimingMetric]) { self.metrics = metrics }
    func series(for history: SessionTimingHistory) -> [SessionTimingSeries] {
        if history != self.history { self.history = history; series = SessionTimingSeries.all(history, metrics: metrics) }
        return series
    }
}

/// One metric of a session's retained completed requests, oldest to newest.
/// Hovering selects a request. The chart only writes the selection: its rule
/// and the caption of the selected request are the views that watch it, so a
/// pointer step never rebuilds the marks or their accessibility strings.
struct SessionTimingChart: View {
    let series: SessionTimingSeries
    let selection: SessionTimingSelection
    var height: CGFloat = 92
    var body: some View {
        let metric = series.metric, points = series.points, requests = series.requests
        let tint: Color = switch metric { case .ttft: .piInfo; case .rate: .piAccent; case .output: .piBrandOrange; case .cost: .piSuccess }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.title).font(PiFont.caption)
                Spacer()
                Text("\(points.count)/\(requests) observed").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }
            if points.isEmpty {
                Text("Unavailable").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart {
                    let _ = SessionTimingRenderCount.markBuilt()
                    ForEach(points) { point in
                        if metric == .output || metric == .cost {
                            BarMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value), width: .ratio(0.6))
                                .foregroundStyle(tint).cornerRadius(2)
                                .accessibilityLabel(Text(point.wall))
                                .accessibilityValue(Text(point.figure))
                        } else {
                            LineMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value), series: .value("Observed run", point.segment))
                                .foregroundStyle(tint).interpolationMethod(.linear)
                            PointMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value))
                                .foregroundStyle(tint).symbolSize(14)
                                .accessibilityLabel(Text(point.wall))
                                .accessibilityValue(Text(point.figure))
                        }
                    }
                }
                .chartXScale(domain: 0.5...(Double(requests) + 0.5))
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    switch phase {
                                    case .active(let location):
                                        let frame = geometry[plotFrame]
                                        if frame.contains(location), let value = proxy.value(atX: location.x - frame.minX, as: Double.self) {
                                            selection.select(max(1, min(requests, Int(value.rounded()))))
                                        } else { selection.select(nil) }
                                    case .ended: selection.select(nil)
                                    }
                                }
                            SessionTimingHoverRule(selection: selection, proxy: proxy, plot: proxy.plotFrame.map { geometry[$0] } ?? .zero)
                        }
                    }
                }
                .frame(height: height)
                .accessibilityLabel(metric.title + " for this session, ordered oldest to newest")
            }
            HStack {
                Text("Older")
                Spacer()
                Text("Latest")
            }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
        }
    }
}

/// The selected request's rule, placed by the chart's own x scale over its
/// plot. With the request caption, the only part of a timing chart that
/// watches the pointer.
private struct SessionTimingHoverRule: View {
    @ObservedObject var selection: SessionTimingSelection
    let proxy: ChartProxy
    let plot: CGRect
    var body: some View {
        let _ = SessionTimingRenderCount.ruleDrawn()
        if let request = selection.request, let x = proxy.position(forX: Double(request)) {
            Path { path in
                path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
            }
            .stroke(Color.piInkTertiary.opacity(0.4), lineWidth: 1)
            .allowsHitTesting(false)
        }
    }
}

/// How many times the timing charts built their marks, and how many times the
/// parts that follow the pointer — each chart's rule, the selected request's
/// caption — drew. A test seam: a hover must redraw only the latter.
@MainActor enum SessionTimingRenderCount {
    private(set) static var marks = 0
    private(set) static var rules = 0
    private(set) static var captions = 0
    static func reset() { marks = 0; rules = 0; captions = 0 }
    static func markBuilt() { marks &+= 1 }
    static func ruleDrawn() { rules &+= 1 }
    static func captionDrawn() { captions &+= 1 }
}
