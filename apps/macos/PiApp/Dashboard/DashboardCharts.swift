import SwiftUI
import Charts

/// Drag-to-select overlay for the dashboard charts. The plot area is resolved
/// through the chart proxy so the brushed dates match the axis exactly; the
/// selection is drawn above the marks without touching the chart's scales.
struct DashboardBrushOverlay: ViewModifier {
    @Namespace private var chartCoordinates
    let filter: DashboardFilter
    @Binding var preview: DashboardBrush?
    let committed: DashboardBrush?
    let commit: (DashboardBrush?) -> Void

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                let frame = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
                ZStack(alignment: .topLeading) {
                    if let span = preview ?? committed, let x0 = proxy.position(forX: span.from), let x1 = proxy.position(forX: span.until) {
                        Rectangle().fill(Color.piAccent.opacity(preview == nil ? 0.12 : 0.18))
                            .overlay(alignment: .leading) { Rectangle().fill(Color.piAccent).frame(width: 1) }
                            .overlay(alignment: .trailing) { Rectangle().fill(Color.piAccent).frame(width: 1) }
                            .frame(width: max(1, x1 - x0), height: frame.height)
                            .offset(x: frame.minX + x0, y: frame.minY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(chartCoordinates))
                            .onChanged { value in preview = brush(value, plot: frame, proxy: proxy) }
                            .onEnded { value in
                                let result = brush(value, plot: frame, proxy: proxy)
                                preview = nil
                                commit(result)
                            })
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: chartCoordinates)
                .animation(.easeOut(duration: 0.16), value: committed)
            }
        }
    }

    private func brush(_ value: DragGesture.Value, plot: CGRect, proxy: ChartProxy) -> DashboardBrush? {
        guard let a = proxy.value(atX: min(plot.width, max(0, value.startLocation.x - plot.minX)), as: Date.self),
              let b = proxy.value(atX: min(plot.width, max(0, value.location.x - plot.minX)), as: Date.self) else { return nil }
        return DashboardBrush(a, b, in: filter)
    }
}

extension View {
    /// Fixed 0–100 % y-scale for ratio series; automatic otherwise.
    @ViewBuilder func chartPercentScale(_ percent: Bool) -> some View {
        if percent { chartYScale(domain: 0.0...100.0) } else { self }
    }
    func dashboardBrush(filter: DashboardFilter, preview: Binding<DashboardBrush?>, committed: DashboardBrush?, commit: @escaping (DashboardBrush?) -> Void) -> some View {
        modifier(DashboardBrushOverlay(filter: filter, preview: preview, committed: committed, commit: commit))
    }
}

/// Badge for a request's LiteLLM response-cache state.
struct DashboardCacheBadge: View {
    let status: String
    private var tone: PiTone {
        switch status {
        case "hit": .success
        case "miss": .neutral
        case "unreported": .warning
        default: .danger
        }
    }
    var body: some View { PiBadge(text: status, tone: tone, dot: true) }
}
