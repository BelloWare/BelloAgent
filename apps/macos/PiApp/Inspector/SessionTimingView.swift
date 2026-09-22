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
    @State private var selectedRequest: Int?
    private var selectedSample: SessionTimingSample? {
        guard let selectedRequest, history.samples.indices.contains(selectedRequest - 1) else { return history.latest }
        return history.samples[selectedRequest - 1]
    }
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
                Text("Average: \(history.settledThroughput.samples)/\(history.samples.count) listed requests reported both a decode span and their output tokens.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                ForEach(SessionTimingMetric.footerMetrics, id: \.rawValue) { SessionTimingChart(history: history, metric: $0, selectedRequest: $selectedRequest) }
                if let sample = selectedSample {
                    HStack(spacing: 5) {
                        Text(selectedRequest.map { "Request \($0)" } ?? "Latest")
                        Text("· " + sample.wall.formatted(date: .abbreviated, time: .standard))
                        Spacer(minLength: 0)
                    }.font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    Text(SessionTimingMetric.ttft.label(sample.ttftMilliseconds) + " TTFT · " + SessionTimingMetric.rate.label(sample.outputTokensPerSecond))
                        .font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInk)
                }
            }
            Text(history.hasOlderRequests ? "Most recent \(history.samples.count) completed requests in this session." : "\(history.samples.count) completed requests in this session.")
                .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            Text(SettledThroughput.explanation + " The session figure divides summed output by summed decode time; gaps indicate missing measurements.")
                .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(PiSpacing.lg).frame(width: 430).foregroundStyle(Color.piInk)
        .accessibilityIdentifier("session-timing-history")
        .onChange(of: history) { _, _ in selectedRequest = nil }
    }

    private func latest(_ metric: SessionTimingMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric == .ttft ? "Latest TTFT" : "Latest output rate").font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            Text(metric.label(history.latest.flatMap { metric.value(in: $0) })).font(PiFont.body.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// One metric of a session's retained completed requests, oldest to newest.
/// Hovering selects a request; the parent shows its figures.
struct SessionTimingChart: View {
    let history: SessionTimingHistory
    let metric: SessionTimingMetric
    @Binding var selectedRequest: Int?
    var height: CGFloat = 92
    var body: some View {
        let points = history.points(for: metric)
        let tint: Color = switch metric { case .ttft: .piInfo; case .rate: .piAccent; case .output: .piBrandOrange; case .cost: .piSuccess }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.title).font(PiFont.caption)
                Spacer()
                Text("\(points.count)/\(history.samples.count) observed").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }
            if points.isEmpty {
                Text("Unavailable").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart {
                    ForEach(points) { point in
                        if metric == .output || metric == .cost {
                            BarMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value), width: .ratio(0.6))
                                .foregroundStyle(tint).cornerRadius(2)
                                .accessibilityLabel(Text(point.wall.formatted(date: .abbreviated, time: .standard)))
                                .accessibilityValue(Text(metric.label(point.value)))
                        } else {
                            LineMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value), series: .value("Observed run", point.segment))
                                .foregroundStyle(tint).interpolationMethod(.linear)
                            PointMark(x: .value("Request", Double(point.index)), y: .value(metric.unit, point.value))
                                .foregroundStyle(tint).symbolSize(14)
                                .accessibilityLabel(Text(point.wall.formatted(date: .abbreviated, time: .standard)))
                                .accessibilityValue(Text(metric.label(point.value)))
                        }
                    }
                    if let selectedRequest {
                        RuleMark(x: .value("Selected request", Double(selectedRequest))).foregroundStyle(Color.piInkTertiary.opacity(0.4))
                    }
                }
                .chartXScale(domain: 0.5...(Double(history.samples.count) + 0.5))
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard let plotFrame = proxy.plotFrame else { return }
                                switch phase {
                                case .active(let location):
                                    let frame = geometry[plotFrame]
                                    if frame.contains(location), let value = proxy.value(atX: location.x - frame.minX, as: Double.self) {
                                        selectedRequest = max(1, min(history.samples.count, Int(value.rounded())))
                                    } else { selectedRequest = nil }
                                case .ended: selectedRequest = nil
                                }
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
