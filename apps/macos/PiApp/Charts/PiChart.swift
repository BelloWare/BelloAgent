import AppKit

// The app's own chart engine (0.1.120: no SwiftUI, so no Swift Charts). It
// draws what the app's charts draw — areas, lines, points, rectangles, bars,
// rules and annotations over gridlines and axis labels — the way Swift
// Charts drew them: its automatic ticks and domains, its plot frame, its
// label placement (`PiChartTicks`, `PiChartLayout`, calibrated against Swift
// Charts in `PiChartParityTests`). A chart is a value (`PiChart.Spec`); the
// view (`PiChartView`) lays it out once per size and draws only what is in
// the dirty rectangle. What follows the pointer is drawn by an overlay of its
// own, so a hover never draws the marks again.

enum PiChart {
    /// How an axis maps its values: numbers, dates (seconds since the
    /// reference date, so the ticks fall on the calendar), or categories
    /// (indices `0..<count`, each a band).
    enum Kind: Equatable { case number, date, band(count: Int) }

    /// What an axis's domain is.
    enum Domain: Equatable {
        /// Exactly this range.
        case fixed(ClosedRange<Double>)
        /// The marks' extent, with zero when asked, widened to the axis's
        /// ticks as Swift Charts widens `.automatic(includesZero:)`.
        case automatic(includesZero: Bool)
    }

    /// Which values get a gridline and a label.
    enum Ticks: Equatable {
        /// Swift Charts' `.automatic(desiredCount:)`; nil is its default.
        case automatic(desiredCount: Int?)
        case values([Double])
    }

    /// Where a label hangs from its tick, as `AxisValueLabel(anchor:)`.
    enum Anchor: Equatable { case leading, center, trailing
        /// After its tick, as Swift Charts places a time axis's labels.
        case after }

    struct Gridline: Equatable {
        var color: NSColor = .piHairline
        /// Swift Charts' `AxisGridLine()`: half a point, where the value falls
        /// (not on the pixel grid).
        var width: CGFloat = 0.5
        var dash: [CGFloat] = []
        /// The dashed vertical gridline Swift Charts draws for a time axis.
        static func time(_ color: NSColor) -> Gridline { Gridline(color: color, width: 0.5, dash: [3, 3]) }
    }

    struct Labels: Equatable {
        var font: NSFont = PiChart.defaultLabelFont
        var color: NSColor = .secondaryLabelColor
        /// The text for a tick's value.
        var format: Format = .number
        /// Where a label hangs from its tick (bottom axis): centred under it
        /// by default, or as each tick's value says.
        var anchor: Anchor = .center
        var anchors: [Double: Anchor] = [:]
        /// Swift Charts drops a label that would overlap the one before it;
        /// `collisionResolution: .disabled` keeps them all.
        var hidesCollisions = true
        func anchor(_ value: Double) -> Anchor { anchors[value] ?? anchor }
    }

    /// How a tick's value reads.
    enum Format: Equatable {
        /// Swift Charts' default for numbers.
        case number
        /// A date in this style (`Date.FormatStyle`), as the caller gave Swift Charts.
        case date(Date.FormatStyle)
        /// An amount in dollars, as every amount reads (`compactGatewayUSD`).
        case usd
        /// Each tick's own text, worked out with the ticks.
        case table([Double: String])

        func text(_ value: Double) -> String {
            switch self {
            case .number: return PiChartTicks.numberLabel(value)
            case .date(let style): return Date(timeIntervalSinceReferenceDate: value).formatted(style)
            case .usd: return compactGatewayUSD(value)
            case .table(let texts): return texts[value] ?? ""
            }
        }
    }

    enum Position: Equatable { case leading, bottom, hidden }

    struct Axis: Equatable {
        var position: Position
        var ticks: Ticks = .automatic(desiredCount: nil)
        var gridline: Gridline? = Gridline()
        var labels: Labels? = Labels()
        /// `AxisMarks(preset: .aligned)`: the first and last labels stay
        /// inside the chart's width.
        var aligned = false
        static var hidden: Axis { Axis(position: .hidden, gridline: nil, labels: nil) }
    }

    struct Scale: Equatable {
        var kind: Kind = .number
        var domain: Domain = .automatic(includesZero: true)
    }

    enum Interpolation: Equatable { case linear, monotone }
    enum BarWidth: Equatable { case fixed(CGFloat), ratio(CGFloat) }
    /// Where an annotation sits around its point.
    enum AnnotationPosition: Equatable { case top, leading, trailing }

    /// One thing drawn in the plot, in data values.
    enum Mark: Equatable {
        /// A filled band from `lower` to `upper` at each x (a stacked area).
        case area(x: [Double], lower: [Double], upper: [Double], color: NSColor, interpolation: Interpolation)
        case line(x: [Double], y: [Double], color: NSColor, width: CGFloat, round: Bool, interpolation: Interpolation)
        /// A filled circle; `size` is Swift Charts' symbol size (its area in points).
        case point(x: Double, y: Double, color: NSColor, size: CGFloat)
        case rect(x0: Double, x1: Double, y0: Double, y1: Double, color: NSColor, cornerRadius: CGFloat)
        /// A horizontal bar from `x0` to `x1`, `height` points tall, centred on `y`.
        case bar(x0: Double, x1: Double, y: Double, height: CGFloat, color: NSColor, cornerRadius: CGFloat)
        /// A column of a band axis from `y0` to `y1`.
        case column(category: Int, y0: Double, y1: Double, width: BarWidth, color: NSColor)
        /// A rule across the plot at an x or at a y.
        case rule(x: Double?, y: Double?, color: NSColor, width: CGFloat, dash: [CGFloat])
        case annotation(x: Double, y: Double, text: String, font: NSFont, color: NSColor,
                        position: AnnotationPosition, spacing: CGFloat, fitsVertically: Bool)
    }

    /// A key under the chart, as Swift Charts' default legend draws it.
    struct LegendItem: Equatable { var title: String; var color: NSColor }

    struct Spec: Equatable {
        var x = Scale()
        var y = Scale()
        var marks: [Mark] = []
        var xAxis = Axis(position: .bottom)
        var yAxis = Axis(position: .leading)
        /// `.chartPlotStyle { $0.padding(.trailing, …) }`.
        var plotTrailingPadding: CGFloat = 0
        var legend: [LegendItem] = []
        /// What VoiceOver reads of the marks, as Swift Charts read their
        /// `accessibilityLabel` / `accessibilityValue`: one element each,
        /// in the order the chart lists them.
        var accessibleMarks: [AccessibleMark] = []
        /// What the audio graph calls its axes, and whether its series are lines.
        var accessibleAxes: (x: String, y: String) = ("", "")
        var accessibleContinuous = false
        /// What each band of a band axis is, for the audio graph ("Requests 1–2").
        var accessibleCategories: [String] = []

        static func == (a: Spec, b: Spec) -> Bool {
            a.x == b.x && a.y == b.y && a.marks == b.marks && a.xAxis == b.xAxis && a.yAxis == b.yAxis
                && a.plotTrailingPadding == b.plotTrailingPadding && a.legend == b.legend && a.accessibleMarks == b.accessibleMarks
                && a.accessibleAxes == b.accessibleAxes && a.accessibleContinuous == b.accessibleContinuous && a.accessibleCategories == b.accessibleCategories
        }
    }

    /// A mark VoiceOver can reach: what it is, its figure, and where it is.
    struct AccessibleMark: Equatable {
        /// The audio graph's series it belongs to.
        var series: String = ""
        var label: String
        var value: String
        var x: Double
        var y: Double
    }

    /// Swift Charts. axis label font on macOS (measured: 11 points).
    static var defaultLabelFont: NSFont { .systemFont(ofSize: 11) }
}

extension NSColor {
    private struct OpacityKey: Hashable { let color: ObjectIdentifier; let alpha: CGFloat }
    /// Each entry holds its base colour, so the identity in its key is never reused.
    nonisolated(unsafe) private static var opacities: [OpacityKey: (base: NSColor, made: NSColor)] = [:]
    private static let opacityLock = NSLock()
    /// This colour at `alpha`, the same object every time it is asked for:
    /// a dynamic colour made anew never equals the last one, and a chart's
    /// spec would never compare equal to the one it replaces.
    func piOpacity(_ alpha: CGFloat) -> NSColor {
        Self.opacityLock.lock(); defer { Self.opacityLock.unlock() }
        let key = OpacityKey(color: ObjectIdentifier(self), alpha: alpha)
        if let known = Self.opacities[key] { return known.made }
        let made = withAlphaComponent(alpha)
        Self.opacities[key] = (self, made)
        return made
    }
}

/// A flipped view that lays out again whenever its size changes: the base
/// of the ported dashboard and monitor views, which place their children in
/// `layout()` by frame.
@MainActor class DashView: NSView {
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
}
