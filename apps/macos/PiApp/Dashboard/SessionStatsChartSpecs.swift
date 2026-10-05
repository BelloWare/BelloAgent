import AppKit

extension NSColor {
    /// Where the time went: waiting blue, generating in the brand orange,
    /// tools purple — the same three on the bar and on the timeline.
    static func sessionTime(_ kind: SessionTimeSplit.Kind) -> NSColor {
        switch kind {
        case .waiting: .piInfo
        case .generating: .piBrandOrange
        case .tools: .monitorModel(2)
        }
    }
    /// The turn report's token colours: cached green, uncached orange,
    /// reasoning purple; a written cache blue; the rest of the output a
    /// quiet warm neutral; input whose cache went unreported a pale orange.
    static func sessionTokens(_ kind: SessionTokenComposition.Kind) -> NSColor {
        switch kind {
        case .cached: .piSuccess
        case .cacheWrite: .piInfo
        case .uncached: .piBrandOrange
        case .inputUnsplit: NSColor.piBrandOrange.piOpacity(0.42)
        case .reasoning: .monitorModel(2)
        case .output: .piInkTertiary
        }
    }
}

/// The Session Inspector's Overview charts as chart values, as Swift Charts
/// drew them (`PiChartParityTests`).
enum SessionStatsChartSpecs {
    /// The popovers' micro type on an axis.
    static var micro: NSFont { PiKit.Font.micro }

    /// One thin bar per request, oldest at the top; the gaps between rows'
    /// pitch, and the explicit time ticks hanging inward at the ends.
    static func timeline(_ timeline: SessionRequestTimeline) -> PiChart.Spec {
        let rows = timeline.rows, count = rows.count
        let pitch = timelinePitch(count)
        let thickness = max(3, pitch - (pitch >= 12 ? 5 : 2))
        let gap = timeline.domain * 0.005
        var marks: [PiChart.Mark] = []
        var annotations: [PiChart.Mark] = []
        var accessible: [PiChart.AccessibleMark] = []
        for row in rows {
            let y = Double(count - 1 - row.index)
            if row.failed || row.unsplit > 0 || row.waiting > 0 || row.generating > 0 {
                accessible.append(.init(label: row.label, value: row.value, x: row.end, y: y))
            }
            if row.band {
                marks.append(.rect(x0: 0, x1: timeline.domain, y0: y - 0.5, y1: y + 0.5, color: NSColor.piInk.piOpacity(0.035), cornerRadius: 0))
            }
            if row.failed {
                marks.append(.bar(x0: 0, x1: max(row.unsplit, timeline.domain * 0.004), y: y, height: thickness, color: NSColor.piDanger.piOpacity(0.75), cornerRadius: 1.5))
            } else if row.unsplit > 0 {
                marks.append(.bar(x0: 0, x1: row.unsplit, y: y, height: thickness, color: NSColor.piInkTertiary.piOpacity(0.6), cornerRadius: 1.5))
            } else {
                if row.waiting > 0 {
                    marks.append(.bar(x0: 0, x1: row.waiting, y: y, height: thickness, color: .sessionTime(.waiting), cornerRadius: 1.5))
                }
                if row.generating > 0 {
                    marks.append(.bar(x0: row.waiting > 0 ? row.waiting + gap : 0, x1: max(row.waiting + gap * 2, row.waiting + row.generating),
                                      y: y, height: thickness, color: .sessionTime(.generating), cornerRadius: 1.5))
                }
            }
            if let marker = row.marker {
                annotations.append(.annotation(x: row.end, y: y, text: marker, font: PiKit.Font.monospacedDigits(micro), color: .piInkSecondary,
                                               position: .trailing, spacing: SessionStatsFormat.markerSpacing, fitsVertically: false))
            }
        }
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .number, domain: .fixed(0...timeline.domain))
        spec.y = PiChart.Scale(kind: .number, domain: .fixed(-0.5...(Double(count) - 0.5)))
        spec.marks = marks + annotations
        spec.accessibleMarks = accessible
        spec.accessibleAxes = ("Time from the request's start", "Requests, oldest at the top")
        var anchors: [Double: PiChart.Anchor] = [:]
        for tick in timeline.ticks {
            switch timeline.anchor(forTick: tick) {
            case .leading: anchors[tick] = .leading
            case .center: anchors[tick] = .center
            case .trailing: anchors[tick] = .trailing
            }
        }
        spec.xAxis = PiChart.Axis(position: .bottom, ticks: .values(timeline.ticks), gridline: PiChart.Gridline(color: .piHairline, width: 1),
                                  labels: PiChart.Labels(font: micro, color: .piInkTertiary, format: .table(Dictionary(timeline.ticks.map { ($0, timeline.label(forTick: $0)) }, uniquingKeysWith: { a, _ in a })),
                                                         anchors: anchors, hidesCollisions: false))
        spec.yAxis = .hidden
        return spec
    }
    /// Rows get thinner as they get more numerous.
    static func timelinePitch(_ count: Int) -> CGFloat { count <= 6 ? 16 : count <= 12 ? 12 : count <= 20 ? 9 : 6 }

    /// Each measured request's decode rate against the session's average.
    static func speed(_ speed: SessionSpeedSeries) -> PiChart.Spec {
        var marks: [PiChart.Mark] = []
        if let average = speed.average {
            marks.append(.rule(x: nil, y: average, color: NSColor.piInkSecondary.piOpacity(0.55), width: 1, dash: []))
        }
        var accessible: [PiChart.AccessibleMark] = []
        if let average = speed.average { accessible.append(.init(series: "Session average", label: "Session average", value: speed.averageLabel ?? "", x: speed.xDomain.lowerBound, y: average)) }
        accessible += speed.points.map { .init(series: "Requests", label: $0.label, value: $0.value, x: $0.x, y: $0.rate) }
        let size: CGFloat = speed.points.count > 80 ? 16 : 34
        for point in speed.points {
            marks.append(.point(x: point.x, y: point.rate, color: speed.models.isEmpty ? .piBrandOrange : .monitorModel(point.colorIndex), size: size))
        }
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .number, domain: .fixed(speed.xDomain))
        spec.y = PiChart.Scale(kind: .number, domain: .fixed(0...speed.yMaximum))
        spec.marks = marks
        spec.xAxis = .hidden
        spec.yAxis = leadingTicks(speed.ticks) { speed.label(forTick: $0) }
        spec.accessibleMarks = accessible
        spec.accessibleAxes = ("Request", "Output tokens per second")
        return spec
    }

    /// Each request's input — cached, then not — and its output, stacked.
    static func tokenBars(_ bars: SessionTokenBars) -> PiChart.Spec {
        let items = bars.bars
        let width: PiChart.BarWidth = items.count <= 14 ? .fixed(18) : .ratio(items.count > 48 ? 0.8 : 0.66)
        var marks: [PiChart.Mark] = []
        for bar in items {
            for segment in bars.stacks[bar.index] {
                marks.append(.column(category: bar.index, y0: segment.from, y1: segment.to, width: width, color: .sessionTokens(segment.kind)))
            }
        }
        if let last = items.last, let label = bars.endLabel {
            marks.append(.annotation(x: Double(last.index), y: last.total, text: label, font: PiKit.Font.monospacedDigits(micro), color: .piInkSecondary,
                                     position: .top, spacing: SessionStatsFormat.endLabelSpacing, fitsVertically: true))
        }
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .band(count: bars.categories.count), domain: .automatic(includesZero: false))
        spec.y = PiChart.Scale(kind: .number, domain: .fixed(0...bars.yMaximum))
        spec.marks = marks
        spec.xAxis = .hidden
        spec.yAxis = leadingTicks(bars.ticks) { bars.label(forTick: $0) }
        spec.accessibleMarks = items.map { .init(label: $0.label, value: $0.value, x: Double($0.index), y: $0.total) }
        spec.accessibleAxes = ("Request", "Tokens")
        spec.accessibleCategories = items.map(\.label)
        return spec
    }

    /// What the session has cost so far, request by request.
    static func cost(_ cost: SessionCostSeries) -> PiChart.Spec {
        let points = cost.points
        var marks: [PiChart.Mark] = []
        if !points.isEmpty {
            marks.append(.area(x: points.map(\.x), lower: points.map { _ in 0 }, upper: points.map(\.cumulative),
                               color: NSColor.piBrandOrange.piOpacity(0.12), interpolation: .linear))
            marks.append(.line(x: points.map(\.x), y: points.map(\.cumulative), color: .piBrandOrange, width: 2, round: true, interpolation: .linear))
        }
        if let last = points.last, let label = cost.endLabel {
            marks.append(.point(x: last.x, y: last.cumulative, color: .piBrandOrange, size: 28))
            marks.append(.annotation(x: last.x, y: last.cumulative, text: label,
                                     font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 10.5, weight: .semibold)), color: .piInk,
                                     position: .leading, spacing: 6 + sqrt(28 / .pi), fitsVertically: true))  // from the point's edge
        }
        var spec = PiChart.Spec()
        spec.x = PiChart.Scale(kind: .number, domain: .fixed(cost.xDomain))
        spec.y = PiChart.Scale(kind: .number, domain: .fixed(0...cost.yMaximum))
        spec.marks = marks
        spec.xAxis = .hidden
        spec.yAxis = leadingTicks(cost.ticks) { cost.label(forTick: $0) }
        spec.accessibleMarks = points.map { .init(label: $0.label, value: $0.value, x: $0.x, y: $0.cumulative) }
        spec.accessibleAxes = ("Request", "US dollars so far")
        spec.accessibleContinuous = true
        return spec
    }

    private static func leadingTicks(_ ticks: [Double], label: (Double) -> String) -> PiChart.Axis {
        PiChart.Axis(position: .leading, ticks: .values(ticks), gridline: PiChart.Gridline(color: .piHairline, width: 1),
                     labels: PiChart.Labels(font: micro, color: .piInkTertiary, format: .table(Dictionary(ticks.map { ($0, label($0)) }, uniquingKeysWith: { a, _ in a }))))
    }
}
