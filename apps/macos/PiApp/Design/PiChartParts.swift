import SwiftUI

// The small pieces the chart popovers are built from. None of them formats a
// figure or walks data: every string and fraction arrives precomputed, so a
// redraw costs only the drawing.

/// The item under the pointer in one chart, held by the chart without being
/// observed by it. Only the parts that follow the pointer — a rule, a band,
/// the caption under the chart — observe it, so a hover never rebuilds the
/// chart's marks or the panel around them.
@MainActor final class PiChartSelection: ObservableObject {
    @Published private(set) var index: Int?
    /// Every pointer event lands here; a step within the same item publishes nothing.
    func select(_ index: Int?) { if self.index != index { self.index = index } }
}

/// A figure at the top of a panel: the reading, what it is, and a quieter line
/// under it. Partial coverage reads in warning ink, as in the stat dialogs.
struct PiFigure: View {
    let value: String
    let title: String
    var caption: String? = nil
    var partial = false
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: large ? 21 : 15, weight: .semibold))
                .foregroundStyle(Color.piInk).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
            if let caption {
                Text(caption).font(PiFont.micro).foregroundStyle(partial ? Color.piWarning : Color.piInkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The heading of one chart in a panel: what it shows, and in a quieter line
/// how much of the session it covers.
struct PiChartHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
                if let subtitle {
                    Text(subtitle).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One part of a whole, as a stacked bar draws it.
struct PiBarSegment: Identifiable, Equatable, Sendable {
    let id: String
    let fraction: Double
}

/// A single stacked bar of shares: each part a flat fill, two points of
/// surface between neighbours, rounded only at the bar's two ends. A part
/// too small to see keeps a sliver, so a reported figure never vanishes.
struct PiSegmentedBar: View {
    let segments: [PiBarSegment]
    let color: (String) -> Color
    var height: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let visible = segments.filter { $0.fraction > 0 }
            guard !visible.isEmpty, size.width > 0 else { return }
            let gap: CGFloat = 2, sliver: CGFloat = 3
            let room = max(0, size.width - gap * CGFloat(visible.count - 1))
            // Slivers first, then the rest shares what is left.
            let small = visible.filter { $0.fraction * room < sliver }
            let rest = max(0, room - sliver * CGFloat(small.count))
            let restFraction = visible.filter { $0.fraction * room >= sliver }.reduce(0) { $0 + $1.fraction }
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2, style: .continuous))
            var x: CGFloat = 0
            for segment in visible {
                let width = segment.fraction * room < sliver ? sliver : (restFraction > 0 ? rest * segment.fraction / restFraction : 0)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(color(segment.id)))
                x += width + gap
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A legend line for a part of a whole or a series: its swatch, its name, the
/// exact figure and its share. Values stay in ink; the swatch carries identity.
struct PiLegendRow: View {
    let color: Color
    let title: String
    let value: String
    var share: String? = nil
    var detail: String? = nil
    /// A line key for a line or a rule rather than a filled swatch.
    var line = false

    var body: some View {
        // The detail follows the title on its line when there is room, and
        // takes a line of its own under it when there is not: never cut.
        ViewThatFits(in: .horizontal) {
            row(fixed: true) { HStack(alignment: .firstTextBaseline, spacing: 7) { titleText; detailText } }
            row(fixed: false) { VStack(alignment: .leading, spacing: 1) { titleText; detailText } }
        }
        .accessibilityElement(children: .combine)
    }
    private var titleText: some View {
        Text(title).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).fixedSize()
    }
    @ViewBuilder private var detailText: some View {
        if let detail { Text(detail).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true) }
    }
    /// A fixed label keeps its one-line width, which is what lets the first
    /// arrangement decline a row too narrow for it; the second wraps.
    private func row<Label: View>(fixed: Bool, @ViewBuilder _ label: () -> Label) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Group {
                if line { Capsule().fill(color).frame(width: 10, height: 2) }
                else { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 9) }
            }
            .frame(width: 10).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            label().fixedSize(horizontal: fixed, vertical: false)
            Spacer(minLength: PiSpacing.sm)
            Text(value).font(PiFont.caption.weight(.medium)).monospacedDigit().foregroundStyle(Color.piInk).lineLimit(1).fixedSize()
            if let share {
                Text(share).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

/// A chart's first appearance: it grows out of its baseline in one short,
/// eased step. Nothing moves under the app's reduced-motion policy, and the
/// motion is a mask over the finished drawing — the marks are built once.
struct PiChartReveal: ViewModifier {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.piReduceMotion) private var reduceMotion

    /// Axis labels and the figures written beside marks may hang past the
    /// chart's frame; the mask reaches well past it, so the finished chart
    /// is never cut.
    private let overhang: CGFloat = 32

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { geometry in
                    let open = shown || reduceMotion
                    let width = geometry.size.width + overhang * 2, height = geometry.size.height + overhang * 2
                    Rectangle()
                        .frame(width: axis == .horizontal && !open ? 0 : width, height: axis == .vertical && !open ? 0 : height)
                        .frame(width: width, height: height, alignment: axis == .horizontal ? .leading : .bottom)
                        .offset(x: -overhang, y: -overhang)
                }
            }
            .animation(PiMotion.honouring(PiMotion.slow.delay(delay), reduceMotion: reduceMotion), value: shown)
            .onAppear { shown = true }
    }
}

extension View {
    func piChartReveal(_ axis: PiChartReveal.Axis, delay: Double = 0) -> some View { modifier(PiChartReveal(axis: axis, delay: delay)) }
}
