import AppKit

/// The curves a chart draws through its points, in view coordinates.
enum PiChartPaths {
    /// A polyline, or Swift Charts' `.monotone` curve: a cubic through every
    /// point that never overshoots between two of them (the monotone cubic
    /// of Steffen, as `d3.curveMonotoneX` draws it).
    static func add(_ points: [CGPoint], to path: CGMutablePath, interpolation: PiChart.Interpolation, moveFirst: Bool = true) {
        guard let first = points.first else { return }
        if moveFirst { path.move(to: first) } else { path.addLine(to: first) }
        guard points.count > 1 else { return }
        guard interpolation == .monotone, points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return
        }
        let tangents = monotoneTangents(points)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let third = (b.x - a.x) / 3
            path.addCurve(to: b, control1: CGPoint(x: a.x + third, y: a.y + third * tangents[index - 1]),
                          control2: CGPoint(x: b.x - third, y: b.y - third * tangents[index]))
        }
    }

    /// The slope at each point (d3's `slope3` inside, `slope2` at the ends).
    static func monotoneTangents(_ points: [CGPoint]) -> [CGFloat] {
        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n)
        func sign(_ x: CGFloat) -> CGFloat { x < 0 ? -1 : 1 }
        func secant(_ i: Int) -> CGFloat {
            let h = points[i + 1].x - points[i].x
            return h == 0 ? 0 : (points[i + 1].y - points[i].y) / h
        }
        for i in 1..<(n - 1) {
            let h0 = points[i].x - points[i - 1].x, h1 = points[i + 1].x - points[i].x
            let s0 = secant(i - 1), s1 = secant(i)
            let p = (h0 + h1) == 0 ? 0 : (s0 * h1 + s1 * h0) / (h0 + h1)
            slopes[i] = (sign(s0) + sign(s1)) * min(abs(s0), abs(s1), 0.5 * abs(p))
            if !slopes[i].isFinite { slopes[i] = 0 }
        }
        func end(_ i: Int, _ t: CGFloat, _ h: CGFloat, _ s: CGFloat) -> CGFloat { h == 0 ? t : (3 * s - t) / 2 }
        slopes[0] = end(0, slopes[1], points[1].x - points[0].x, secant(0))
        slopes[n - 1] = end(n - 1, slopes[n - 2], points[n - 1].x - points[n - 2].x, secant(n - 2))
        return slopes
    }

    /// A rectangle with rounded corners, the radius kept within half its
    /// shorter side as SwiftUI keeps it.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return r > 0 ? CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: rect, transform: nil)
    }
}
