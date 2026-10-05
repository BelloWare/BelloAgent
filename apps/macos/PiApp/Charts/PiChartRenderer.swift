import AppKit

/// Draws a laid-out chart: gridlines, then the marks in their order, then the
/// labels and the legend. The marks are turned into paths once per layout
/// (`prepare`), each with its bounds, so a repaint draws only what meets its
/// dirty rectangle and never walks a series again.
@MainActor enum PiChartRenderer {
    /// One thing to draw, in view coordinates.
    enum Item {
        case fill(CGPath, NSColor)
        case stroke(CGPath, NSColor, width: CGFloat, round: Bool, dash: [CGFloat])
        case ellipse(CGRect, NSColor)
        case text(PiKit.Line, CGPoint)
    }
    struct Prepared {
        let item: Item
        /// What the item can touch, its stroke included.
        let bounds: CGRect
    }

    /// The marks of `spec` as paths in `geometry`, in drawing order.
    static func prepare(_ spec: PiChart.Spec, _ g: PiChartGeometry, scale: CGFloat) -> [Prepared] {
        var items: [Prepared] = []
        for mark in spec.marks { prepare(mark, g, scale: scale, into: &items) }
        return items
    }

    static func draw(_ geometry: PiChartGeometry, spec: PiChart.Spec, marks: [Prepared], in context: CGContext, dirty: CGRect, scale: CGFloat) {
        let plot = geometry.plot
        // Gridlines: across the plot at each tick.
        if let grid = spec.yAxis.gridline {
            for tick in geometry.yTicks {
                stroke(context, from: CGPoint(x: plot.minX, y: tick.position), to: CGPoint(x: plot.maxX, y: tick.position), grid: grid, dirty: dirty)
            }
        }
        if let grid = spec.xAxis.gridline {
            for tick in geometry.xTicks {
                stroke(context, from: CGPoint(x: tick.position, y: plot.minY), to: CGPoint(x: tick.position, y: plot.maxY), grid: grid, dirty: dirty)
            }
        }
        for prepared in marks where prepared.bounds.intersects(dirty) { draw(prepared.item, context, scale: scale) }
        for tick in geometry.yTicks {
            guard let label = tick.label, let origin = tick.labelOrigin else { continue }
            guard CGRect(origin: origin, size: label.size(scale: scale)).intersects(dirty) else { continue }
            label.draw(at: origin, scale: scale)
        }
        // The time axis's labels are cut at the chart's sides, as Swift
        // Charts cuts them; the leading axis's are not.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: -10_000, width: geometry.size.width, height: 20_000))
        for tick in geometry.xTicks {
            guard let label = tick.label, let origin = tick.labelOrigin else { continue }
            guard CGRect(origin: origin, size: label.size(scale: scale)).intersects(dirty) else { continue }
            if let room = tick.labelRoom {
                var first = label
                first.text = String(label.text.prefix(1)) + "…"
                if first.width <= room + 0.01 {
                    label.draw(in: CGRect(x: origin.x, y: origin.y, width: room, height: label.lineHeight), truncation: .end, scale: scale)
                } else {
                    // Too little room for one letter and "…": the ellipsis
                    // alone where it fits, else the first letter, cut at the
                    // chart's end (both measured in Swift Charts).
                    first.text = "…"
                    if first.width > room + 0.01 { first.text = String(label.text.prefix(1)) }
                    first.draw(at: origin, scale: scale)
                }
            } else {
                label.draw(at: origin, scale: scale)
            }
        }
        context.restoreGState()
        for entry in geometry.legend {
            let line = PiKit.Line(entry.item.title, font: PiChart.defaultLabelFont, color: .secondaryLabelColor)
            let height = line.lineHeight
            context.setFillColor(entry.item.color.cgColor)
            context.fillEllipse(in: CGRect(x: entry.origin.x, y: entry.origin.y + (height - 8) / 2, width: 8, height: 8))
            line.draw(at: CGPoint(x: entry.origin.x + PiChartLayout.legendText, y: entry.origin.y), scale: scale)
        }
    }

    private static func draw(_ item: Item, _ context: CGContext, scale: CGFloat) {
        switch item {
        case let .fill(path, color):
            context.addPath(path); context.setFillColor(color.cgColor); context.fillPath()
        case let .stroke(path, color, width, round, dash):
            context.saveGState()
            context.setLineWidth(width)
            context.setLineCap(round ? .round : .butt); context.setLineJoin(round ? .round : .miter)
            if !dash.isEmpty { context.setLineDash(phase: 0, lengths: dash) }
            context.setStrokeColor(color.cgColor)
            context.addPath(path); context.strokePath()
            context.restoreGState()
        case let .ellipse(rect, color):
            context.setFillColor(color.cgColor); context.fillEllipse(in: rect)
        case let .text(line, origin):
            line.draw(at: origin, scale: scale)
        }
    }

    private static func stroke(_ context: CGContext, from a: CGPoint, to b: CGPoint, grid: PiChart.Gridline, dirty: CGRect) {
        guard CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -grid.width, dy: -grid.width).intersects(dirty) else { return }
        let path = CGMutablePath(); path.move(to: a); path.addLine(to: b)
        draw(.stroke(path, grid.color, width: grid.width, round: false, dash: grid.dash), context, scale: 2)
    }

    /// What a stroke touches, its joins' miter tips and its caps included.
    private static func strokeBounds(_ path: CGPath, width: CGFloat, round: Bool) -> CGRect {
        path.copy(strokingWithWidth: width, lineCap: round ? .round : .butt, lineJoin: round ? .round : .miter, miterLimit: 10)
            .boundingBoxOfPath.insetBy(dx: -1, dy: -1)
    }

    private static func prepare(_ mark: PiChart.Mark, _ g: PiChartGeometry, scale: CGFloat, into items: inout [Prepared]) {
        switch mark {
        case let .area(x, lower, upper, color, interpolation):
            guard x.count == lower.count, x.count == upper.count, !x.isEmpty else { return }
            let top = zip(x, upper).map { g.point($0, $1) }
            let bottom = Array(zip(x, lower).map { g.point($0, $1) }.reversed())
            let path = CGMutablePath()
            PiChartPaths.add(top, to: path, interpolation: interpolation)
            PiChartPaths.add(bottom, to: path, interpolation: interpolation, moveFirst: false)
            path.closeSubpath()
            items.append(Prepared(item: .fill(path, color), bounds: path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)))
        case let .line(x, y, color, width, round, interpolation):
            guard x.count == y.count, !x.isEmpty else { return }
            let path = CGMutablePath()
            PiChartPaths.add(zip(x, y).map { g.point($0, $1) }, to: path, interpolation: interpolation)
            items.append(Prepared(item: .stroke(path, color, width: width, round: round, dash: []), bounds: strokeBounds(path, width: width, round: round)))
        case let .point(x, y, color, size):
            guard size > 0 else { return }
            // `symbolSize` is the circle's area.
            let centre = g.point(x, y), diameter = 2 * sqrt(size / .pi)
            let rect = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
            items.append(Prepared(item: .ellipse(rect, color), bounds: rect.insetBy(dx: -1, dy: -1)))
        case let .rect(x0, x1, y0, y1, color, radius):
            let a = g.point(x0, y0), b = g.point(x1, y1)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            items.append(Prepared(item: .fill(PiChartPaths.roundedRect(rect, radius: radius), color), bounds: rect.insetBy(dx: -1, dy: -1)))
        case let .bar(x0, x1, y, height, color, radius):
            let a = g.point(x0, y), b = g.point(x1, y)
            let rect = CGRect(x: min(a.x, b.x), y: a.y - height / 2, width: abs(b.x - a.x), height: height)
            items.append(Prepared(item: .fill(PiChartPaths.roundedRect(rect, radius: radius), color), bounds: rect.insetBy(dx: -1, dy: -1)))
        case let .column(category, y0, y1, width, color):
            let centre = g.x.position(Double(category))
            let w: CGFloat
            switch width {
            case .fixed(let points): w = points
            case .ratio(let ratio): w = g.x.step * ratio
            }
            let top = g.y.position(max(y0, y1)), bottom = g.y.position(min(y0, y1))
            let rect = CGRect(x: centre - w / 2, y: top, width: w, height: bottom - top)
            // Measured: Swift Charts rounds a bar's corners a little by default.
            items.append(Prepared(item: .fill(PiChartPaths.roundedRect(rect, radius: PiChartLayout.barCornerRadius), color), bounds: rect.insetBy(dx: -1, dy: -1)))
        case let .rule(x, y, color, width, dash):
            let path = CGMutablePath()
            if let x {
                let position = g.x.position(x)
                path.move(to: CGPoint(x: position, y: g.plot.minY)); path.addLine(to: CGPoint(x: position, y: g.plot.maxY))
            }
            if let y {
                let position = g.y.position(y)
                path.move(to: CGPoint(x: g.plot.minX, y: position)); path.addLine(to: CGPoint(x: g.plot.maxX, y: position))
            }
            items.append(Prepared(item: .stroke(path, color, width: width, round: false, dash: dash), bounds: strokeBounds(path, width: width, round: false)))
        case let .annotation(x, y, text, font, color, position, spacing, fitsVertically):
            let line = PiKit.Line(text, font: font, color: color)
            let size = line.size(scale: scale), anchor = g.point(x, y)
            var origin: CGPoint
            switch position {
            case .top: origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - spacing - size.height)
            case .leading: origin = CGPoint(x: anchor.x - spacing - size.width, y: anchor.y - size.height / 2)
            case .trailing: origin = CGPoint(x: anchor.x + spacing, y: anchor.y - size.height / 2)
            }
            // Kept inside the chart, as `overflowResolution: .fit(to: .chart)`.
            origin.x = min(max(origin.x, 0), g.size.width - size.width)
            if fitsVertically { origin.y = min(max(origin.y, 0), g.size.height - size.height) }
            items.append(Prepared(item: .text(line, origin), bounds: CGRect(origin: origin, size: size).insetBy(dx: -1, dy: -1)))
        }
    }
}
