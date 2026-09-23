import SwiftUI
import Charts

// The popovers behind the two session pills under the composer. Each page
// observes its session's store and nothing else; each chart takes its series
// by value and its pointer selection by reference without observing it, so a
// hover redraws a rule, a band and a caption — never the marks, never the page.

/// How many times the popovers built their pages and their charts' marks,
/// and how often the parts that follow the pointer drew. A test seam: a hover
/// must move only the last two.
@MainActor enum SessionStatsRenderCount {
    private(set) static var panels = 0
    private(set) static var marks = 0
    private(set) static var pointers = 0
    private(set) static var captions = 0
    static func reset() { panels = 0; marks = 0; pointers = 0; captions = 0 }
    static func panelBuilt() { panels &+= 1 }
    static func marksBuilt() { marks &+= 1 }
    static func pointerDrawn() { pointers &+= 1 }
    static func captionDrawn() { captions &+= 1 }
}

extension SessionStatsTickAnchor {
    /// Where the label's box meets its tick, under the axis.
    var unitPoint: UnitPoint {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

/// An item of a chart that names itself in the line under the chart.
protocol SessionStatsCaptioned { var caption: String { get } }
/// A point of a chart, where its marker goes.
protocol SessionStatsPlotted { var x: Double { get }; var y: Double { get } }
extension SessionRequestTimeline.Row: SessionStatsCaptioned {}
extension SessionTokenBars.Bar: SessionStatsCaptioned {}
extension SessionSpeedSeries.Point: SessionStatsCaptioned, SessionStatsPlotted { var y: Double { rate } }
extension SessionCostSeries.Point: SessionStatsCaptioned, SessionStatsPlotted { var y: Double { cumulative } }

extension Color {
    /// Where the time went: waiting blue, generating in the brand orange,
    /// tools purple — the same three on the bar and on the timeline.
    static func sessionTime(_ kind: SessionTimeSplit.Kind) -> Color {
        switch kind {
        case .waiting: .piInfo
        case .generating: .piBrandOrange
        case .tools: .monitorModel(2)
        }
    }
    /// The turn report's token colours: cached green, uncached orange,
    /// reasoning purple; a written cache blue; the rest of the output a
    /// quiet warm neutral; input whose cache went unreported a pale orange.
    static func sessionTokens(_ kind: SessionTokenComposition.Kind) -> Color {
        switch kind {
        case .cached: .piSuccess
        case .cacheWrite: .piInfo
        case .uncached: .piBrandOrange
        case .inputUnsplit: .piBrandOrange.opacity(0.42)
        case .reasoning: .monitorModel(2)
        case .output: .piInkTertiary
        }
    }
}

// MARK: - The page both popovers share

/// A popover page: its title and the ledger action on a fixed header, then
/// the figures and charts in a page that scrolls when the screen is short.
private struct SessionStatsPage<Content: View>: View {
    let symbol: String
    let title: String
    let identifier: String
    let openLedger: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInkTertiary)
                Text(title).font(PiFont.heading).foregroundStyle(Color.piInk)
                Spacer(minLength: PiSpacing.sm)
                Button("Per-request ledger…", action: openLedger)
                    .buttonStyle(.piSecondaryCompact)
                    .help("Open Session info at this session's per-request ledger")
                    .accessibilityIdentifier(identifier + "-ledger")
            }
            .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, 10)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, PiSpacing.lg).padding(.top, 14).padding(.bottom, PiSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .foregroundStyle(Color.piInk)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A row of figures; the numbers the pill promised, larger.
private struct SessionStatsFigures: View {
    let figures: [SessionStatsFigure]
    var large = false
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.md) {
            ForEach(figures) { figure in
                PiFigure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial, large: large)
                    .accessibilityIdentifier("session-stats-figure-" + figure.id)
            }
        }
    }
}

/// Before the history arrives: a quiet line where the charts will be.
private struct SessionStatsLoadingNote: View {
    let loading: Bool
    let failure: String?
    var body: some View {
        if let failure { PiNote(failure, tone: .warning) }
        else {
            Text(loading ? "Reading this session's requests…" : "No retained requests yet.")
                .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        }
    }
}

private struct SessionStatsNotes: View {
    let notes: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-stats-notes")
    }
}

/// The line under a chart: the item under the pointer, else the latest. Two
/// lines tall whether it needs them or not, so a hover never moves the page.
private struct SessionStatsCaption<Item: SessionStatsCaptioned>: View {
    @ObservedObject var selection: PiChartSelection
    /// The chart's own items, whose captions were written when they were built.
    let items: [Item]
    let latest: String
    var body: some View {
        let _ = SessionStatsRenderCount.captionDrawn()
        let text = selection.index.flatMap { items.indices.contains($0) ? items[$0].caption : nil } ?? latest
        Text(text)
            .font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: - Session statistics

/// Behind "turns · steps · tok/s": how much work the session did, how fast,
/// and where its time went.
struct SessionTimePopover: View {
    @ObservedObject var store: SessionStatsStore
    let openLedger: () -> Void

    var body: some View {
        let _ = SessionStatsRenderCount.panelBuilt()
        let charts = store.time
        SessionStatsPage(symbol: "gauge.with.dots.needle.67percent", title: "Session statistics",
                         identifier: "session-stats-time-dialog", openLedger: openLedger) {
            VStack(alignment: .leading, spacing: 14) {
                SessionStatsFigures(figures: charts.hero, large: true)
                SessionStatsFigures(figures: charts.details)
            }.piStaggered(0)
            if let split = charts.split {
                SessionTimeSplitView(split: split).equatable().sessionStatsSection().piStaggered(1)
            }
            if charts.historyLoaded {
                if let timeline = charts.timeline {
                    SessionTimelineChart(timeline: timeline, selection: store.timelineSelection).equatable().sessionStatsSection().piStaggered(2)
                }
                if let speed = charts.speed {
                    SessionSpeedChart(speed: speed, selection: store.speedSelection).equatable().sessionStatsSection().piStaggered(3)
                }
                if !charts.models.isEmpty {
                    SessionModelTimeTable(rows: charts.models).equatable().sessionStatsSection().piStaggered(3)
                }
            } else {
                SessionStatsLoadingNote(loading: store.loading, failure: store.failure)
            }
            SessionStatsNotes(notes: charts.notes).sessionStatsSection()
        }
    }
}

private struct SessionTimeSplitView: View, Equatable {
    let split: SessionTimeSplit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("Where the time went", subtitle: split.total + " in all, from the helper's clocks")
            PiSegmentedBar(segments: split.parts.map { PiBarSegment(id: $0.id.rawValue, fraction: $0.fraction) },
                           color: { SessionTimeSplit.Kind(rawValue: $0).map(Color.sessionTime) ?? .piInkTertiary }, height: 12)
                .piChartReveal(.horizontal, delay: 0.04)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(split.parts) { part in
                    PiLegendRow(color: .sessionTime(part.id), title: part.title, value: part.value, share: part.share)
                }
            }
            if let note = split.note {
                Text(note).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(split.accessibility)
        .accessibilityIdentifier("session-stats-time-split")
    }
}

/// One thin bar per request, oldest at the top.
private struct SessionTimelineChart: View, Equatable {
    let timeline: SessionRequestTimeline
    let selection: PiChartSelection
    nonisolated static func == (a: Self, b: Self) -> Bool { a.timeline == b.timeline && a.selection === b.selection }

    /// Rows get thinner as they get more numerous, and the chart taller up to a point.
    private var pitch: CGFloat {
        let count = timeline.rows.count
        return count <= 6 ? 16 : count <= 12 ? 12 : count <= 20 ? 9 : 6
    }

    var body: some View {
        let rows = timeline.rows, count = rows.count, pitch = pitch
        let thickness = max(3, pitch - (pitch >= 12 ? 5 : 2))
        // Two points of surface between the wait and the generation.
        let gap = timeline.domain * 0.005
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("Request timeline", subtitle: timeline.subtitle)
            HStack(spacing: 12) {
                SessionStatsKey(color: .sessionTime(.waiting), title: "Waiting for first token")
                SessionStatsKey(color: .sessionTime(.generating), title: "Generating")
                if timeline.hasUnsplit { SessionStatsKey(color: .piInkTertiary.opacity(0.6), title: "Not split") }
                if timeline.hasFailures { SessionStatsKey(color: .piDanger.opacity(0.75), title: "Failed attempt") }
            }
            Chart {
                let _ = SessionStatsRenderCount.marksBuilt()
                ForEach(rows) { row in
                    let y = Double(count - 1 - row.index)
                    if row.band {
                        RectangleMark(xStart: .value("From", 0.0), xEnd: .value("To", timeline.domain),
                                      yStart: .value("Top", y - 0.5), yEnd: .value("Bottom", y + 0.5))
                            .foregroundStyle(Color.piInk.opacity(0.035))
                    }
                    if row.failed {
                        BarMark(xStart: .value("Start", 0.0), xEnd: .value("Failed", max(row.unsplit, timeline.domain * 0.004)),
                                y: .value("Request", y), height: .fixed(thickness))
                            .foregroundStyle(Color.piDanger.opacity(0.75)).cornerRadius(1.5)
                            .accessibilityLabel(Text(row.label)).accessibilityValue(Text(row.value))
                    } else if row.unsplit > 0 {
                        BarMark(xStart: .value("Start", 0.0), xEnd: .value("Request", row.unsplit), y: .value("Request", y), height: .fixed(thickness))
                            .foregroundStyle(Color.piInkTertiary.opacity(0.6)).cornerRadius(1.5)
                            .accessibilityLabel(Text(row.label)).accessibilityValue(Text(row.value))
                    } else {
                        if row.waiting > 0 {
                            BarMark(xStart: .value("Start", 0.0), xEnd: .value("First token", row.waiting), y: .value("Request", y), height: .fixed(thickness))
                                .foregroundStyle(Color.sessionTime(.waiting)).cornerRadius(1.5)
                                .accessibilityHidden(row.generating > 0)
                                .accessibilityLabel(Text(row.label)).accessibilityValue(Text(row.value))
                        }
                        if row.generating > 0 {
                            BarMark(xStart: .value("Generating from", row.waiting > 0 ? row.waiting + gap : 0),
                                    xEnd: .value("Complete", max(row.waiting + gap * 2, row.waiting + row.generating)),
                                    y: .value("Request", y), height: .fixed(thickness))
                                .foregroundStyle(Color.sessionTime(.generating)).cornerRadius(1.5)
                                .accessibilityLabel(Text(row.label)).accessibilityValue(Text(row.value))
                        }
                    }
                    // The rows the highlights line names, named at their ends.
                    if let marker = row.marker {
                        PointMark(x: .value("End", row.end), y: .value("Request", y))
                            .symbolSize(0)
                            .annotation(position: .trailing, alignment: .leading, spacing: SessionStatsFormat.markerSpacing,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text(marker).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                            }
                            .accessibilityHidden(true)
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
                    // The labels at the axis's two ends hang inward, so the
                    // last one reads whole at the chart's edge.
                    AxisValueLabel(anchor: timeline.anchor(forTick: milliseconds).unitPoint, collisionResolution: .disabled) {
                        Text(timeline.label(forTick: milliseconds)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let value = proxy.value(atY: location.y - plot.minY, as: Double.self) else { selection.select(nil); return }
                                    let index = count - 1 - Int(value.rounded())
                                    selection.select(rows.indices.contains(index) ? index : nil)
                                case .ended: selection.select(nil)
                                }
                            }
                        SessionTimelineBand(selection: selection, plot: plot, count: count)
                    }
                }
            }
            .frame(height: CGFloat(count) * pitch + 20)
            .piChartReveal(.horizontal, delay: 0.06)
            .accessibilityLabel("Request timeline")
            .accessibilityValue(timeline.accessibility)
            .accessibilityIdentifier("session-stats-timeline")
            if let highlights = timeline.highlights {
                Text(highlights).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            SessionStatsCaption(selection: selection, items: rows, latest: timeline.latestCaption)
        }
    }
}

/// The row under the pointer, lifted with a faint band. It and the caption
/// are the only parts of the timeline that watch the pointer.
private struct SessionTimelineBand: View {
    @ObservedObject var selection: PiChartSelection
    let plot: CGRect
    let count: Int
    var body: some View {
        let _ = SessionStatsRenderCount.pointerDrawn()
        if let index = selection.index, count > 0, plot.height > 0 {
            let pitch = plot.height / CGFloat(count)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.piInk.opacity(0.07))
                .frame(width: plot.width + 8, height: pitch)
                .offset(x: plot.minX - 4, y: plot.minY + CGFloat(index) * pitch)
                .allowsHitTesting(false)
        }
    }
}

/// A small key for a chart's series: a swatch and its name.
private struct SessionStatsKey: View {
    let color: Color
    let title: String
    var line = false
    var body: some View {
        HStack(spacing: 4) {
            if line { Capsule().fill(color).frame(width: 9, height: 2) }
            else { RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).frame(width: 7, height: 7) }
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).lineLimit(1)
        }
    }
}

/// Each measured request's decode rate against the session's average.
private struct SessionSpeedChart: View, Equatable {
    let speed: SessionSpeedSeries
    let selection: PiChartSelection
    nonisolated static func == (a: Self, b: Self) -> Bool { a.speed == b.speed && a.selection === b.selection }

    var body: some View {
        let points = speed.points
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("Speed per request", subtitle: speed.subtitle) {
                if let label = speed.averageLabel { SessionStatsKey(color: .piInkSecondary, title: label, line: true) }
            }
            Chart {
                let _ = SessionStatsRenderCount.marksBuilt()
                if let average = speed.average {
                    RuleMark(y: .value("Session average", average))
                        .foregroundStyle(Color.piInkSecondary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityLabel(Text("Session average")).accessibilityValue(Text(speed.averageLabel ?? ""))
                }
                ForEach(points) { point in
                    PointMark(x: .value("Request", point.x), y: .value("tok/s", point.rate))
                        .foregroundStyle(speed.models.isEmpty ? Color.piBrandOrange : Color.monitorModel(point.colorIndex))
                        .symbolSize(points.count > 80 ? 16 : 34)
                        .accessibilityLabel(Text(point.label)).accessibilityValue(Text(point.value))
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
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let x = proxy.value(atX: location.x - plot.minX, as: Double.self) else { selection.select(nil); return }
                                    selection.select(speed.nearest(to: x))
                                case .ended: selection.select(nil)
                                }
                            }
                        SessionPointMarker(selection: selection, points: points, proxy: proxy, plot: plot)
                    }
                }
            }
            .frame(height: SessionSpeedSeries.plotHeight)
            .piChartReveal(.vertical, delay: 0.08)
            .accessibilityLabel("Speed per request")
            .accessibilityValue(speed.accessibility)
            .accessibilityIdentifier("session-stats-speed")
            HStack(spacing: 10) {
                if let first = points.first { Text("#\(Int(first.x.rounded()))") }
                Spacer(minLength: 0)
                ForEach(speed.models) { model in SessionStatsKey(color: .monitorModel(model.colorIndex), title: model.id) }
                Spacer(minLength: 0)
                if let last = points.last { Text("#\(Int(last.x.rounded()))") }
            }
            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
            SessionStatsCaption(selection: selection, items: points, latest: speed.latestCaption)
        }
    }
}

/// The selected point, ringed, with a hairline down to the axis. Placed by
/// the chart's own scales; with the caption, all that follows the pointer.
private struct SessionPointMarker<Point: SessionStatsPlotted>: View {
    @ObservedObject var selection: PiChartSelection
    let points: [Point]
    let proxy: ChartProxy
    let plot: CGRect
    var body: some View {
        let _ = SessionStatsRenderCount.pointerDrawn()
        if let index = selection.index, points.indices.contains(index),
           let x = proxy.position(forX: points[index].x), let y = proxy.position(forY: points[index].y) {
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                    path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                }
                .stroke(Color.piInkTertiary.opacity(0.45), lineWidth: 1)
                Circle().stroke(Color.piInk.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                    .position(x: plot.minX + x, y: plot.minY + y)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct SessionModelTimeTable: View, Equatable {
    let rows: [SessionModelTimeRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("By model", subtitle: "\(rows.count) models in this session · each with its own speed and first token")
            HStack(spacing: PiSpacing.sm) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Requests").frame(width: 86, alignment: .leading)
                Text("Speed").frame(width: 92, alignment: .leading)
                Text("First token").frame(width: 80, alignment: .leading)
            }
            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            ForEach(rows) { row in
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(alignment: .top, spacing: PiSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Color.monitorModel(row.colorIndex)).frame(width: 7, height: 7)
                        Text(row.id).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk)
                            .lineLimit(1).truncationMode(.middle).help(row.id)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.requests).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk)
                        UsageShareBar(fraction: row.requestShare, tone: .monitorModel(row.colorIndex)).frame(height: 4)
                        Text(row.requestShareLabel).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                    }.frame(width: 86, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.speed).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
                        Text(row.speedCaption).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                    }.frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.firstToken).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
                        Text(row.firstTokenCaption).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                    }.frame(width: 80, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.id): \(row.requests) requests, \(row.requestShareLabel); \(row.speed), \(row.speedCaption); first token \(row.firstToken), \(row.firstTokenCaption)")
            }
        }
        .accessibilityIdentifier("session-stats-time-models")
    }
}

// MARK: - Token usage

/// Behind "tokens · cache · cost": what the session consumed, how the cache
/// served it, and what it cost.
struct SessionTokenPopover: View {
    @ObservedObject var store: SessionStatsStore
    let openLedger: () -> Void

    var body: some View {
        let _ = SessionStatsRenderCount.panelBuilt()
        let charts = store.tokens
        SessionStatsPage(symbol: "cylinder.split.1x2", title: "Token usage",
                         identifier: "session-stats-usage-dialog", openLedger: openLedger) {
            VStack(alignment: .leading, spacing: 8) {
                SessionStatsFigures(figures: charts.hero, large: true)
                if let coverage = charts.coverage {
                    Text(coverage).font(PiFont.micro).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("session-stats-usage-coverage")
                }
            }.piStaggered(0)
            if charts.historyLoaded {
                if let composition = charts.composition {
                    SessionCompositionView(composition: composition).equatable().sessionStatsSection().piStaggered(1)
                }
                if let bars = charts.perRequest {
                    SessionTokenBarsChart(bars: bars, selection: store.tokenSelection).equatable().sessionStatsSection().piStaggered(2)
                }
                if let cost = charts.cost {
                    SessionCostChart(cost: cost, selection: store.costSelection).equatable().sessionStatsSection().piStaggered(3)
                }
                if !charts.models.isEmpty {
                    SessionModelTokenTable(rows: charts.models).equatable().sessionStatsSection().piStaggered(3)
                }
            } else {
                SessionStatsLoadingNote(loading: store.loading, failure: store.failure)
            }
            SessionStatsNotes(notes: charts.notes).sessionStatsSection()
        }
    }
}

/// The first and last request a chart spans, under its two ends.
private struct SessionRequestEnds: View {
    let first: Int
    let last: Int
    var body: some View {
        HStack {
            Text("#\(first)")
            Spacer(minLength: 0)
            Text("#\(last)")
        }
        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
        .accessibilityHidden(true)
    }
}

private struct SessionStatsSection: ViewModifier {
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(Color.piHairline).frame(height: 1)
            content
        }
    }
}
private extension View {
    /// A section of a popover page, set off from the one above by a hairline.
    func sessionStatsSection() -> some View { modifier(SessionStatsSection()) }
}

private struct SessionCompositionView: View, Equatable {
    let composition: SessionTokenComposition
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("Composition", subtitle: composition.subtitle)
            PiSegmentedBar(segments: composition.parts.map { PiBarSegment(id: $0.id.rawValue, fraction: $0.fraction) },
                           color: { SessionTokenComposition.Kind(rawValue: $0).map(Color.sessionTokens) ?? .piInkTertiary }, height: 12)
                .piChartReveal(.horizontal, delay: 0.04)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(composition.parts) { part in
                    PiLegendRow(color: .sessionTokens(part.id), title: part.title, value: part.value, share: part.share, detail: part.detail)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(composition.accessibility)
        .accessibilityIdentifier("session-stats-composition")
    }
}

/// Each request's input — cached, then not — and its output, stacked.
private struct SessionTokenBarsChart: View, Equatable {
    let bars: SessionTokenBars
    let selection: PiChartSelection
    nonisolated static func == (a: Self, b: Self) -> Bool { a.bars == b.bars && a.selection === b.selection }

    var body: some View {
        let items = bars.bars
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader(bars.binSize > 1 ? "Per request, averaged" : "Per request", subtitle: bars.subtitle)
            HStack(spacing: 10) {
                ForEach(bars.kinds, id: \.self) { kind in
                    SessionStatsKey(color: .sessionTokens(kind), title: Self.keyTitle(kind, reasoning: bars.kinds.contains(.reasoning)))
                }
            }
            Chart {
                let _ = SessionStatsRenderCount.marksBuilt()
                ForEach(items) { bar in
                    let stack = bars.stacks[bar.index], category = bars.categories[bar.index]
                    ForEach(stack.indices, id: \.self) { offset in
                        BarMark(x: .value("Request", category), yStart: .value("From", stack[offset].from), yEnd: .value("To", stack[offset].to),
                                width: items.count <= 14 ? .fixed(18) : .ratio(items.count > 48 ? 0.8 : 0.66))
                            .foregroundStyle(Color.sessionTokens(stack[offset].kind))
                            .accessibilityHidden(offset != stack.count - 1)
                            .accessibilityLabel(Text(bar.label)).accessibilityValue(Text(bar.value))
                    }
                }
                // The latest bar's size, over it: where the context stands now.
                if let last = items.last, let label = bars.endLabel {
                    PointMark(x: .value("Request", bars.categories[last.index]), y: .value("Tokens", last.total))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: SessionStatsFormat.endLabelSpacing,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            Text(label).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                        }
                        .accessibilityHidden(true)
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
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let category = proxy.value(atX: location.x - plot.minX, as: String.self),
                                          let index = Int(category) else { selection.select(nil); return }
                                    selection.select(items.indices.contains(index) ? index : nil)
                                case .ended: selection.select(nil)
                                }
                            }
                        SessionColumnMarker(selection: selection, count: items.count, proxy: proxy, plot: plot)
                    }
                }
            }
            .frame(height: SessionTokenBars.plotHeight)
            .piChartReveal(.vertical, delay: 0.08)
            .accessibilityLabel(bars.binSize > 1 ? "Tokens per request, averaged in bins" : "Tokens per request")
            .accessibilityValue(bars.accessibility)
            .accessibilityIdentifier("session-stats-token-bars")
            SessionRequestEnds(first: bars.requests.lowerBound, last: bars.requests.upperBound)
            if let summary = bars.summary {
                Text(summary).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            SessionStatsCaption(selection: selection, items: items, latest: bars.latestCaption)
        }
    }

    static func keyTitle(_ kind: SessionTokenComposition.Kind, reasoning: Bool) -> String {
        switch kind {
        case .cached: "Cached input"
        case .cacheWrite, .uncached: "Uncached input"
        case .inputUnsplit: "Input, cache unreported"
        case .reasoning: "Reasoning"
        case .output: reasoning ? "Other output" : "Output"
        }
    }
}

/// The column under the pointer, lifted with a faint band behind it.
private struct SessionColumnMarker: View {
    @ObservedObject var selection: PiChartSelection
    let count: Int
    let proxy: ChartProxy
    let plot: CGRect
    var body: some View {
        let _ = SessionStatsRenderCount.pointerDrawn()
        if let index = selection.index, count > 0, let x = proxy.position(forX: String(index)) {
            let width = max(4, plot.width / CGFloat(count))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.piInk.opacity(0.07))
                .frame(width: width + 2, height: plot.height)
                .offset(x: plot.minX + x - width / 2 - 1, y: plot.minY)
                .allowsHitTesting(false)
        }
    }
}

/// What the session has cost so far, request by request.
private struct SessionCostChart: View, Equatable {
    let cost: SessionCostSeries
    let selection: PiChartSelection
    nonisolated static func == (a: Self, b: Self) -> Bool { a.cost == b.cost && a.selection === b.selection }

    var body: some View {
        let points = cost.points
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("Cumulative cost", subtitle: cost.subtitle)
            Chart {
                let _ = SessionStatsRenderCount.marksBuilt()
                ForEach(points) { point in
                    AreaMark(x: .value("Request", point.x), y: .value("USD", point.cumulative))
                        .foregroundStyle(Color.piBrandOrange.opacity(0.12)).interpolationMethod(.linear)
                        .accessibilityHidden(true)
                    LineMark(x: .value("Request", point.x), y: .value("USD", point.cumulative))
                        .foregroundStyle(Color.piBrandOrange).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                        .accessibilityLabel(Text(point.label)).accessibilityValue(Text(point.value))
                }
                // The line ends on the session's cost so far, and says it.
                if let last = points.last, let label = cost.endLabel {
                    PointMark(x: .value("Request", last.x), y: .value("USD", last.cumulative))
                        .foregroundStyle(Color.piBrandOrange).symbolSize(28)
                        .annotation(position: .leading, alignment: .trailing, spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            Text(label).font(PiFont.micro.weight(.semibold)).foregroundStyle(Color.piInk).monospacedDigit()
                        }
                        .accessibilityHidden(true)
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
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let x = proxy.value(atX: location.x - plot.minX, as: Double.self) else { selection.select(nil); return }
                                    selection.select(cost.nearest(to: x))
                                case .ended: selection.select(nil)
                                }
                            }
                        SessionPointMarker(selection: selection, points: points, proxy: proxy, plot: plot)
                    }
                }
            }
            .frame(height: SessionCostSeries.plotHeight)
            .piChartReveal(.horizontal, delay: 0.1)
            .accessibilityLabel("Cumulative cost")
            .accessibilityValue(cost.accessibility)
            .accessibilityIdentifier("session-stats-cost")
            if let first = points.first, let last = points.last {
                SessionRequestEnds(first: Int(first.x.rounded()), last: Int(last.x.rounded()))
            }
            SessionStatsCaption(selection: selection, items: points, latest: cost.latestCaption)
        }
    }
}

private struct SessionModelTokenTable: View, Equatable {
    let rows: [SessionModelTokenRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiChartHeader("By model", subtitle: "\(rows.count) models in this session · their share of the tokens and of the cost")
            HStack(spacing: PiSpacing.sm) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 112, alignment: .leading)
                Text("Cost").frame(width: 112, alignment: .leading)
            }
            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            ForEach(rows) { row in
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(alignment: .top, spacing: PiSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Color.monitorModel(row.colorIndex)).frame(width: 7, height: 7)
                        Text(row.id).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk)
                            .lineLimit(1).truncationMode(.middle).help(row.id)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    shareCell(row.tokens, share: row.tokenShare, label: row.tokenShareLabel, tone: .monitorModel(row.colorIndex))
                    shareCell(row.cost, share: row.costShare, label: row.costShareLabel, tone: .monitorModel(row.colorIndex))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.id): \(row.tokens) tokens, \(row.tokenShareLabel); cost \(row.cost), \(row.costShareLabel)")
            }
        }
        .accessibilityIdentifier("session-stats-token-models")
    }
    private func shareCell(_ value: String, share: Double?, label: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            UsageShareBar(fraction: share ?? 0, tone: tone).frame(height: 4)
            Text(label).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        }.frame(width: 112, alignment: .leading)
    }
}
