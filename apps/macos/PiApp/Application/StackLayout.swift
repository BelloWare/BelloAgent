import AppKit

// SwiftUI's stack layout, for the screens ported from it (0.1.120): a row's
// children share its width as an `HStack` shares it, so a ported row places
// its parts, truncates its text and gives up its room in the same order as
// before. Frames, not Auto Layout: each screen lays its rows out in
// `layout()` and asks them their height for a width.

@MainActor enum StackLayout {
    /// A stack's spacing when none is given (`HStack { … }`): 8 points
    /// between views, none beside a spacer, which keeps its own 8 at least.
    static let system: CGFloat = -8
    /// The gap after each child but the last.
    static func gaps(_ items: [Item], spacing: CGFloat) -> [CGFloat] {
        guard items.count > 1 else { return [] }
        return (0..<items.count - 1).map { index in
            spacing >= 0 ? spacing : (items[index].isSpacer || items[index + 1].isSpacer ? 0 : -spacing)
        }
    }
    /// How one child of a row takes the width it is offered.
    struct Sizing {
        /// The width it takes when offered `proposal` (`.infinity`: its ideal).
        var width: @MainActor (CGFloat) -> CGFloat
        /// Its height at the width it took.
        var height: @MainActor (CGFloat) -> CGFloat
        /// `layoutPriority`: a higher one is offered its width first.
        var priority: Double = 0
        /// Its first text baseline below its top, at the width it took; nil
        /// for a view with no text, whose bottom edge is its baseline.
        var baseline: (@MainActor (CGFloat) -> CGFloat)? = nil

        /// Its own size whatever it is offered (`.fixedSize()`, a symbol, a button).
        static func fixed(_ size: CGSize) -> Sizing { Sizing(width: { _ in size.width }, height: { _ in size.height }) }
        /// A view's intrinsic size, whatever it is offered.
        static func intrinsic(_ view: NSView) -> Sizing {
            Sizing(width: { _ in view.intrinsicContentSize.width }, height: { _ in view.intrinsicContentSize.height })
        }
        /// One line of text cut to what it is offered (`lineLimit(1)`).
        static func line(_ view: PiKit.TextLine, priority: Double = 0) -> Sizing {
            Sizing(width: { proposal in min(view.intrinsicContentSize.width, max(0, proposal)) },
                   height: { _ in view.intrinsicContentSize.height }, priority: priority)
        }
        /// Text that wraps to the width it is offered, up to its ideal width.
        static func wrapping(_ view: NSView & PiKit.WidthSizing, ideal: @escaping @MainActor () -> CGFloat, priority: Double = 0) -> Sizing {
            Sizing(width: { proposal in min(ideal(), max(0, proposal)) }, height: { width in view.height(forWidth: width) }, priority: priority)
        }
        /// Takes what it is offered between `min` and `max` (a field, a flexible frame).
        static func flexible(min: CGFloat = 0, max: CGFloat = .infinity, height: @escaping @MainActor (CGFloat) -> CGFloat) -> Sizing {
            Sizing(width: { proposal in Swift.min(max, Swift.max(min, proposal.isFinite ? proposal : max.isFinite ? max : min)) }, height: height)
        }
        /// A nested row, sized as SwiftUI sizes a stack inside a stack.
        static func row(_ items: [Item], spacing: CGFloat, priority: Double = 0) -> Sizing {
            Sizing(width: { proposal in StackLayout.width(items, spacing: spacing, proposal: proposal) },
                   height: { width in StackLayout.height(items, spacing: spacing, width: width) }, priority: priority)
        }
    }

    /// A child of a row: a view and how it sizes, or a spacer.
    struct Item {
        var view: NSView?
        var sizing: Sizing
        var isSpacer: Bool { view == nil && minLength != nil }
        var minLength: CGFloat?
        /// Children of a nested row: placed with it.
        var children: [Item]?
        var childSpacing: CGFloat = 0

        static func view(_ view: NSView, _ sizing: Sizing) -> Item { Item(view: view, sizing: sizing) }
        static func fixed(_ view: NSView) -> Item { Item(view: view, sizing: .intrinsic(view)) }
        static func line(_ view: PiKit.TextLine, priority: Double = 0) -> Item { Item(view: view, sizing: .line(view, priority: priority)) }
        static func spacer(_ minLength: CGFloat = 8) -> Item {
            Item(view: nil, sizing: Sizing(width: { proposal in Swift.max(minLength, proposal) }, height: { _ in 0 }), minLength: minLength)
        }
        static func row(_ children: [Item], spacing: CGFloat, priority: Double = 0) -> Item {
            Item(view: nil, sizing: .row(children, spacing: spacing, priority: priority), children: children, childSpacing: spacing)
        }
    }

    /// The widths a row's children take in `width`, as `HStack` gives them
    /// out: the spacing first, then, by priority, the least flexible child
    /// first, each offered an equal share of what is left.
    static func widths(_ items: [Item], spacing: CGFloat, proposal: CGFloat) -> [CGFloat] {
        guard !items.isEmpty else { return [] }
        // Unbounded: each at its ideal width, a spacer at its least.
        if !proposal.isFinite { return items.map { item in let ideal = item.sizing.width(.infinity); return ideal.isFinite ? ideal : item.sizing.width(0) } }
        let minimums = items.map { $0.sizing.width(0) }
        let flexibility = items.indices.map { items[$0].sizing.width(.infinity) - minimums[$0] }
        var widths = Array(repeating: CGFloat(0), count: items.count)
        // Spacers keep their least length aside and share what the others
        // leave, as `HStack` gives a `Spacer` its room last.
        let spacers = items.indices.filter { items[$0].isSpacer }
        var remaining = proposal - gaps(items, spacing: spacing).reduce(0, +) - spacers.reduce(0) { $0 + minimums[$1] }
        let priorities = Set(items.indices.filter { !items[$0].isSpacer }.map { items[$0].sizing.priority }).sorted(by: >)
        for priority in priorities {
            let group = items.indices.filter { !items[$0].isSpacer && items[$0].sizing.priority == priority }.sorted { flexibility[$0] < flexibility[$1] }
            // What lower priorities need at the least is kept for them.
            let reserved = items.indices.filter { !items[$0].isSpacer && items[$0].sizing.priority < priority }.reduce(0) { $0 + minimums[$1] }
            var available = remaining - reserved
            for (offset, index) in group.enumerated() {
                let share = max(0, available / CGFloat(group.count - offset))
                let taken = items[index].sizing.width(share)
                widths[index] = taken
                available -= taken
                remaining -= taken
            }
        }
        for (offset, index) in spacers.enumerated() {
            let share = max(0, remaining / CGFloat(spacers.count - offset))
            widths[index] = minimums[index] + share
            remaining -= share
        }
        return widths
    }

    /// The row's width when offered `proposal`.
    static func width(_ items: [Item], spacing: CGFloat, proposal: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return widths(items, spacing: spacing, proposal: proposal).reduce(0, +) + gaps(items, spacing: spacing).reduce(0, +)
    }
    /// The row's height in `width`: its tallest child.
    static func height(_ items: [Item], spacing: CGFloat, width: CGFloat) -> CGFloat {
        let widths = widths(items, spacing: spacing, proposal: width)
        return zip(items, widths).map { $0.sizing.height($1) }.max() ?? 0
    }

    /// A row aligned on its children's first text baselines
    /// (`alignment: .firstTextBaseline`): its height in `width`.
    static func baselineHeight(_ items: [Item], spacing: CGFloat, width: CGFloat) -> CGFloat {
        let widths = widths(items, spacing: spacing, proposal: width)
        let metrics = zip(items, widths).map { item, width -> (CGFloat, CGFloat) in
            let height = item.sizing.height(width)
            return (item.sizing.baseline?(width) ?? height, height)
        }
        let above = metrics.map(\.0).max() ?? 0
        return metrics.map { above - $0.0 + $0.1 }.max() ?? 0
    }
    /// Places a row's children with their first baselines on one line.
    static func placeOnBaseline(_ items: [Item], spacing: CGFloat, in rect: CGRect, scale: CGFloat) {
        let widths = widths(items, spacing: spacing, proposal: rect.width)
        let baselines = zip(items, widths).map { item, width in item.sizing.baseline?(width) ?? item.sizing.height(width) }
        let above = baselines.max() ?? 0
        let gaps = gaps(items, spacing: spacing) + [0]
        var x = rect.minX
        for (index, item) in items.enumerated() {
            let width = widths[index], height = item.sizing.height(width)
            let frame = CGRect(x: PiKit.round(x, scale), y: PiKit.round(rect.minY + above - baselines[index], scale), width: width, height: height)
            if let view = item.view { view.frame = frame }
            if let children = item.children { place(children, spacing: item.childSpacing, in: frame, scale: scale) }
            x += width + gaps[index]
        }
    }

    /// Places a row's children in `rect`, each centred on the row's middle
    /// (`alignment: .center`) and on the pixel grid.
    @discardableResult
    static func place(_ items: [Item], spacing: CGFloat, in rect: CGRect, scale: CGFloat) -> [CGRect] {
        let widths = widths(items, spacing: spacing, proposal: rect.width)
        let gaps = gaps(items, spacing: spacing) + [0]
        var x = rect.minX
        var frames: [CGRect] = []
        for (index, (item, width)) in zip(items, widths).enumerated() {
            let height = item.sizing.height(width)
            let frame = CGRect(x: PiKit.round(x, scale), y: PiKit.round(rect.minY + (rect.height - height) / 2, scale), width: width, height: height)
            frames.append(frame)
            if let view = item.view { view.frame = frame }
            if let children = item.children { place(children, spacing: item.childSpacing, in: frame, scale: scale) }
            x += width + gaps[index]
        }
        return frames
    }
}
