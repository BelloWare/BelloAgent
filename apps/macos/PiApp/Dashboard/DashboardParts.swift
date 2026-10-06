import AppKit

// Pieces the report, the background requests page and the Session Inspector
// share as AppKit views (0.1.120): SwiftUI's `LazyVGrid` with flexible or
// adaptive columns, a page scroll view whose document takes its width, a
// token share bar, the cache badge, and a few text forms.

/// `LazyVGrid`: `columns` equal flexible columns, or adaptive ones (as many
/// of at least `minimum` as fit, each at most `maximum`), rows as tall as
/// their tallest item, items at the top-leading of their cell.
@MainActor final class GridView: DashView, PiKit.WidthSizing {
    enum Columns: Equatable { case flexible(Int), adaptive(minimum: CGFloat, maximum: CGFloat) }
    var columns: Columns { didSet { if columns != oldValue { changed() } } }
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var items: [NSView] = [] {
        didSet {
            for view in oldValue where !items.contains(where: { $0 === view }) { view.removeFromSuperview() }
            for view in items where view.superview !== self { addSubview(view) }
            changed()
        }
    }
    init(columns: Columns, spacing: CGFloat, rowSpacing: CGFloat) {
        self.columns = columns; self.spacing = spacing; self.rowSpacing = rowSpacing
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func changed() { invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) }

    /// The number of columns and each one's width at `width`.
    func columnLayout(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        switch columns {
        case .flexible(let count):
            let n = max(1, count)
            return (n, max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n)))
        case .adaptive(let minimum, let maximum):
            let n = max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
            return (n, min(maximum, max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n))))
        }
    }
    private func frames(_ width: CGFloat) -> (CGFloat, [CGRect]) {
        let shown = items.filter { !$0.isHidden }
        let (count, column) = columnLayout(width)
        let scale = piScale
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var index = 0
        while index < shown.count {
            let row = shown[index..<min(shown.count, index + count)]
            let heights = row.map { PiKit.height(of: $0, width: column) }
            let height = heights.max() ?? 0
            for (offset, (_, h)) in zip(row, heights).enumerated() {
                let x = PiKit.round(CGFloat(offset) * (column + spacing), scale)
                frames.append(CGRect(x: x, y: PiKit.round(y, scale), width: PiKit.round(column, scale), height: h))
            }
            y += height + rowSpacing
            index += count
        }
        return (shown.isEmpty ? 0 : y - rowSpacing, frames)
    }
    func height(forWidth width: CGFloat) -> CGFloat { frames(width).0 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() {
        super.layout()
        for (view, frame) in zip(items.filter { !$0.isHidden }, frames(bounds.width).1) where view.frame != frame { view.frame = frame }
    }
}

/// A page's scroll view: a vertical scroller that hides when idle, no
/// background of its own, and a document that is as wide as the clip and as
/// tall as its column asks there.
@MainActor final class PageScrollView: NSScrollView {
    let column: NSView
    private let document = Document()
    /// The padded column's widest, padding included; wider pages centre it
    /// (`.padding(...).frame(maxWidth:).frame(maxWidth: .infinity)`).
    var maximumWidth: CGFloat = .greatestFiniteMagnitude
    /// The column's padding inside the scroll view.
    var insets = NSEdgeInsets()
    init(column: NSView) {
        self.column = column
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; autohidesScrollers = true
        horizontalScrollElasticity = .none
        document.addSubview(column)
        documentView = document
        contentView.postsBoundsChangedNotifications = false
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// The column's width in a clip `width` wide.
    func columnWidth(forWidth width: CGFloat) -> CGFloat { max(0, min(maximumWidth, width) - insets.left - insets.right) }
    /// Lays the column out at the clip's width now.
    func fit() {
        let width = contentSize.width
        let inner = columnWidth(forWidth: width)
        let height = PiKit.height(of: column, width: inner)
        let total = NSSize(width: width, height: max(height + insets.top + insets.bottom, contentSize.height))
        if document.frame.size != total { document.setFrameSize(total) }
        let x = PiKit.round((width - min(maximumWidth, width)) / 2, column.piScale) + insets.left
        let frame = CGRect(x: x, y: insets.top, width: inner, height: height)
        if column.frame != frame { column.frame = frame }
    }
    override func tile() { super.tile(); fit() }
    override func layout() { super.layout(); fit() }
    final class Document: DashView, PiKit.SizeObserver {
        func contentSizeChanged() { (enclosingScrollView as? PageScrollView)?.fit() }
    }
}

/// The text colours the turn report and its token bars use (`TranscriptPalette`).
enum DashPalette {
    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1) }
        return NSColor.piDynamic(light: rgb(light), dark: rgb(dark))
    }
    static let text = color(0x1d1b17, 0xeceae4)
    static let muted = color(0x6e6a61, 0xa9a59b)
    static let faint = color(0x9b968c, 0x78746b)
}

/// One of a turn's token shares (`TurnTokenBar`): its title and total, a
/// four-point track split into its two shares, and a legend line for each.
/// Read out as one element.
@MainActor final class TokenShareBar: DashView {
    let partition: TurnTokenPartition
    private var primary: NSColor { partition.title == "Input" ? .piSuccess : .monitorModel(2) }
    private static var reading: NSFont { PiKit.Font.monospacedDigits(.systemFont(ofSize: 11, weight: .medium)) }
    private static var legend: NSFont { PiKit.Font.monospacedDigits(.systemFont(ofSize: 9.5)) }
    init(partition: TurnTokenPartition) {
        self.partition = partition
        super.init(frame: .zero)
        toolTip = partition.help
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(partition.help)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var title: PiKit.Line { PiKit.Line(partition.title, font: Self.reading, color: DashPalette.faint) }
    private var total: PiKit.Line { PiKit.Line(partition.totalLabel, font: Self.reading, color: DashPalette.text) }
    private func legendLine(_ part: Bool) -> PiKit.Line { PiKit.Line(partition.label(part: part), font: Self.legend, color: DashPalette.muted) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: title.lineHeight + 3 + 4 + 3 + legendLine(true).lineHeight + 2 + legendLine(false).lineHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        let scale = piScale
        let titleSize = title.size(scale: scale)
        title.draw(in: CGRect(x: 0, y: 0, width: min(titleSize.width, bounds.width), height: titleSize.height), scale: scale)
        let x = titleSize.width + 5
        total.draw(in: CGRect(x: x, y: 0, width: max(0, bounds.width - x), height: total.lineHeight), scale: scale)
        let track = CGRect(x: 0, y: title.lineHeight + 3, width: bounds.width, height: 4)
        let shape = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.piFillStrong.setFill(); shape.fill()
        let secondary = NSColor.piAccent.piOpacity(0.75)
        switch partition.fill {
        case .empty: break
        case .reported: secondary.setFill(); shape.fill()
        case .split(let fraction):
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            secondary.setFill(); track.fill()
            primary.setFill(); CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        var y = track.maxY + 3
        for (part, color) in [(true, primary), (false, NSColor.piAccent)] {
            let line = legendLine(part)
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 0, y: y + (line.lineHeight - 4) / 2, width: 4, height: 4)).fill()
            line.draw(at: CGPoint(x: 7, y: y), scale: scale)
            y += line.lineHeight + 2
        }
    }
}

/// A request's LiteLLM response-cache state, as a badge.
@MainActor func dashboardCacheBadge(_ status: String) -> PiKit.Badge {
    let tone: PiTone
    switch status {
    case "hit": tone = .success
    case "miss": tone = .neutral
    case "unreported": tone = .warning
    default: tone = .danger
    }
    return PiKit.Badge(text: status, tone: tone, dot: true)
}

/// A section's heading over a wrapped quieter line, an accessory at the
/// title's trailing edge (`PiSectionHeader` with a subtitle that wraps).
@MainActor final class DashSectionHeader: DashView, PiKit.WidthSizing {
    private let title: PiKit.TextLine
    let subtitle: ShellText?
    let accessory: NSView?
    init(_ title: String, subtitle: String? = nil, accessory: NSView? = nil) {
        self.title = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.heading, color: .piInk))
        self.subtitle = subtitle.map { ShellText($0, font: PiKit.Font.caption, color: .piInkSecondary) }
        self.accessory = accessory
        super.init(frame: .zero)
        for view in [self.title, self.subtitle, accessory].compactMap({ $0 }) { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func setTitle(_ text: String) { title.line.text = text; needsLayout = true }
    func setSubtitle(_ text: String) { guard let subtitle, subtitle.text != text else { return }; subtitle.set(text, color: .piInkSecondary); PiKit.sizeChanged(self) }
    private var accessorySize: CGSize { accessory.map { $0.isHidden ? .zero : shellNaturalSize($0) } ?? .zero }
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - (accessorySize.width > 0 ? accessorySize.width + PiSpacing.sm : 0)) }
    /// The title and the accessory on one first baseline, as the `HStack(alignment: .firstTextBaseline)`.
    private func placement(_ width: CGFloat) -> (title: CGFloat, accessory: CGFloat, height: CGFloat) {
        let scale = piScale
        let textHeight = title.intrinsicContentSize.height + (subtitle.map { 2 + $0.height(forWidth: textWidth(width)) } ?? 0)
        guard let view = accessory, !view.isHidden else { return (0, 0, textHeight) }
        let size = accessorySize
        let titleBaseline = title.line.baseline(scale: scale)
        let accessoryBaseline = shellBaseline(view, height: size.height)
        let baseline = max(titleBaseline, accessoryBaseline)
        let titleTop = PiKit.round(baseline - titleBaseline, scale), accessoryTop = PiKit.round(baseline - accessoryBaseline, scale)
        return (titleTop, accessoryTop, max(titleTop + textHeight, accessoryTop + size.height))
    }
    func height(forWidth width: CGFloat) -> CGFloat { placement(width).height }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600)) }
    override func layout() {
        super.layout()
        let size = title.intrinsicContentSize
        let width = textWidth(bounds.width)
        let place = placement(bounds.width)
        title.frame = CGRect(x: 0, y: place.title, width: min(size.width, width), height: size.height)
        subtitle?.frame = CGRect(x: 0, y: place.title + size.height + 2, width: width, height: subtitle?.height(forWidth: width) ?? 0)
        if let view = accessory, !view.isHidden {
            let accessory = accessorySize
            view.frame = CGRect(x: bounds.width - accessory.width, y: place.accessory, width: accessory.width, height: accessory.height)
        }
    }
}

/// Shared Pi tile, including wrapped captions and scaled values.
@MainActor func dashStatTile(title: String, value: String, caption: String? = nil, symbol: String? = nil, tone: PiTone = .accent) -> PiKit.Box {
    PiKit.statTile(title: title, value: value, caption: caption, symbol: symbol, tone: tone)
}

/// The report's disclosure motion: SwiftUI's `.easeOut(duration: 0.2)` over a
/// section coming or going and the page reflowing around it.
@MainActor enum DashMotion {
    static let duration: CFTimeInterval = 0.2
    /// An image of `view` as it is drawn now, at its place, for its leaving
    /// (a section that stays in the column, hidden: the filters, the chips,
    /// the details, each a bounded height).
    static func snapshot(_ view: NSView) -> NSImageView? {
        guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
        let shown = NSImageView(frame: view.frame)
        shown.image = image; shown.imageScaling = .scaleNone; shown.wantsLayer = true
        shown.setAccessibilityElement(false)
        return shown
    }
    /// `view` (a snapshot, or the leaving view itself, out of its stack)
    /// fades as it moves up by its height, at `frame` in `superview`, then goes.
    static func leave(_ leaving: NSView, in superview: NSView, at frame: CGRect) {
        // In a gate that takes no clicks or VoiceOver: on its way out it is not the page.
        let view = HitGate(frame: frame)
        view.passes = false
        leaving.removeFromSuperview()
        // Nor the keyboard: its controls are drawn as they were, and are never focused again.
        for control in PiKit.controls(in: leaving) { control.refusesFirstResponder = true }
        leaving.frame = view.bounds
        view.addSubview(leaving)
        superview.addSubview(view, positioned: .above, relativeTo: nil)
        view.wantsLayer = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
            var moved = frame
            moved.origin.y += superview.isFlipped ? -frame.height : frame.height
            view.animator().frame = moved
        }, completionHandler: { MainActor.assumeIsolated {
            view.removeFromSuperview()
            leaving.removeFromSuperview()
        } })
    }
    /// Fades `view` in where it now is.
    static func fadeIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        fade.duration = duration; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
    }
    /// Lays out with frame changes animated.
    static func reflow(duration: CFTimeInterval = DashMotion.duration, timing: CAMediaTimingFunctionName = .easeOut, _ layout: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration; context.timingFunction = CAMediaTimingFunction(name: timing)
            context.allowsImplicitAnimation = true
            layout()
        }
    }
}

/// A view that lets the pointer (and VoiceOver) through to its content only while `passes`.
@MainActor final class HitGate: DashView {
    var passes = true
    override func hitTest(_ point: NSPoint) -> NSView? { passes ? super.hitTest(point) : nil }
    override func accessibilityChildren() -> [Any]? { passes ? super.accessibilityChildren() : [] }
}
