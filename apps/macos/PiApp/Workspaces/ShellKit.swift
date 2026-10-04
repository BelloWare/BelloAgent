import AppKit
import Combine

// Small pieces the workspace shell's AppKit views share and DesignKit does
// not have (yet): watching the app's `ObservableObject` models, and text that
// wraps to a limited number of lines with runs of more than one color.

/// Runs `update` once after any of the watched models changed. A model's
/// `objectWillChange` fires before the change lands, so the update waits for
/// the next turn of the main queue, and many changes in one turn update once.
/// Each view's update compares what it shows with what it would show and
/// touches only what differs.
@MainActor final class ShellObserver {
    private var subscriptions: [AnyCancellable] = []
    private var scheduled = false
    private let update: @MainActor () -> Void

    init(_ update: @escaping @MainActor () -> Void) { self.update = update }

    func observe<Object: ObservableObject>(_ object: Object) where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        subscriptions.append(object.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
    }
    /// Watches any publisher: the update follows each value it sends.
    func observe<P: Publisher>(publisher: P) where P.Failure == Never {
        subscriptions.append(publisher.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
    }
    /// Stops watching everything (another chat is shown, say).
    func reset() { subscriptions.removeAll(); scheduled = false }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }
    /// Runs a pending update now.
    func flush() {
        guard scheduled else { return }
        scheduled = false
        update()
    }
}

/// Where text breaks into lines as SwiftUI's `Text` breaks it: the text
/// system's standard strategy, which pushes a word down rather than leave
/// one alone on a paragraph's last line (Core Text's typesetter does not).
@MainActor enum ShellWrap {
    private static var cache: [String: [NSRange]] = [:]
    static func ranges(_ text: String, font: NSFont, width: CGFloat) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let key = "\(font.fontName)|\(font.pointSize)|\(width)|" + text
        if let known = cache[key] { return known }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .standard; paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            ranges.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        // A text that ends with a line break has an empty line after it, as
        // `Text` lays it out.
        if layout.extraLineFragmentRect.height > 0 { ranges.append(NSRange(location: (text as NSString).length, length: 0)) }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = ranges
        return ranges
    }
    static func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        CGFloat(max(1, ranges(text, font: font, width: width).count)) * PiKit.Line("Ag", font: font, color: .black).lineHeight
    }
}

/// Text that wraps as SwiftUI's `Text` wraps it, up to `maximumLines` lines
/// (the last cut with "…"), in one font with runs of different colors.
/// Optionally the reader can select and copy it.
@MainActor final class ShellText: NSView, PiKit.WidthSizing {
    struct Run: Equatable {
        var text: String
        var color: NSColor
    }
    var runs: [Run] { didSet { if oldValue != runs { changed() } } }
    var font: NSFont { didSet { if oldValue != font { changed() } } }
    var maximumLines: Int { didSet { if oldValue != maximumLines { changed() } } }
    /// How a single line that does not fit is cut.
    var truncation: CTLineTruncationType = .end { didSet { needsDisplay = true } }
    var text: String { runs.map(\.text).joined() }

    init(_ text: String, font: NSFont, color: NSColor, maximumLines: Int = .max) {
        runs = [Run(text: text, color: color)]; self.font = font; self.maximumLines = maximumLines
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    init(runs: [Run], font: NSFont, maximumLines: Int = .max) {
        self.runs = runs; self.font = font; self.maximumLines = maximumLines
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(runs.map(\.text).joined())
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sets one run's text in its color.
    func set(_ text: String, color: NSColor) { runs = [Run(text: text, color: color)] }

    private func changed() {
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize(); needsDisplay = true
        PiKit.sizeChanged(self)
    }
    private var attributed: NSAttributedString {
        let string = NSMutableAttributedString()
        for run in runs {
            string.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: run.color,
                                                                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): run.color.cgColor]))
        }
        return string
    }
    private var lineHeight: CGFloat { PiKit.Line("Ag", font: font, color: .black).lineHeight }
    private func lineCount(width: CGFloat) -> Int {
        guard !runs.isEmpty, !text.isEmpty else { return 1 }
        return max(1, min(maximumLines, ShellWrap.ranges(text, font: font, width: width).count))
    }
    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(lineCount(width: width)) * lineHeight }
    /// One line's natural width: the widest the text asks for.
    var naturalWidth: CGFloat {
        let widths = text.components(separatedBy: "\n").map { PiKit.Line($0, font: font, color: .black).size(scale: piScale).width }
        return widths.max() ?? 0
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidth, height: height(forWidth: bounds.width > 0 ? bounds.width : 10_000))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        let scale = piScale
        let string = attributed
        let ranges = ShellWrap.ranges(text, font: font, width: bounds.width)
        let baseline = NSLayoutManager().defaultBaselineOffset(for: font)
        let height = lineHeight
        for (index, range) in ranges.prefix(maximumLines).enumerated() {
            let last = index == maximumLines - 1 && ranges.count > maximumLines
            var lineRange = range
            if last {
                // The rest of the text from here, to its first line break, cut.
                let rest = NSRange(location: range.location, length: string.length - range.location)
                let paragraph = (string.string as NSString).range(of: "\n", range: rest)
                lineRange = paragraph.location == NSNotFound ? rest : NSRange(location: range.location, length: paragraph.location - range.location)
            }
            var piece = string.attributedSubstring(from: lineRange)
            // Trailing spaces and the line break take no room, as `Text` lays lines out.
            while let last = piece.string.last, last == " " || last == "\n" {
                piece = piece.attributedSubstring(from: NSRange(location: 0, length: piece.length - 1))
            }
            if last && lineRange.length < string.length - range.location {
                let more = NSMutableAttributedString(attributedString: piece)
                more.append(NSAttributedString(string: "…", attributes: piece.length > 0 ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : [.font: font]))
                piece = more
            }
            var line = CTLineCreateWithAttributedString(piece)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if width > bounds.width + 0.01 {
                let attributes = piece.length > 0 ? piece.attributes(at: max(0, piece.length - 1), effectiveRange: nil) : [:]
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                guard let cut = CTLineCreateTruncatedLine(line, Double(bounds.width), (ranges.count == 1 ? truncation : .end), ellipsis) else { continue }
                line = cut
            }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: 0, y: CGFloat(index) * height + baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        _ = scale
    }
}

extension NSView {
    /// Adds `views` that are not yet subviews; a view already here stays.
    func shellAdd(_ views: [NSView]) {
        for view in views where view.superview !== self { addSubview(view) }
    }
}

// MARK: - Stacks

/// One child of a `ShellStack`, and how it takes room along the stack.
@MainActor struct ShellItem {
    enum Size: Equatable {
        /// Its own size, never less: a symbol, a button, a fixed label.
        case natural
        /// Its own size or less: text that truncates or wraps.
        case flexible
        /// Exactly this much.
        case fixed(CGFloat)
        /// At least this much, and whatever the others leave.
        case spacer(CGFloat)
        /// Whatever the others leave (across a column: the full width).
        case fill
    }
    var view: NSView?
    var size: Size
    /// Room goes to higher priorities first, as `.layoutPriority`.
    var priority: Double = 0
    /// Its own padding, as `.padding(...)` on it.
    var insets = NSEdgeInsets()

    static func view(_ view: NSView, _ size: Size = .natural, priority: Double = 0, insets: NSEdgeInsets = NSEdgeInsets()) -> ShellItem {
        ShellItem(view: view, size: size, priority: priority, insets: insets)
    }
    static func spacer(_ minimum: CGFloat = 8) -> ShellItem { ShellItem(view: nil, size: .spacer(minimum)) }
    var shown: Bool { view.map { !$0.isHidden } ?? true }
}

/// The natural size of a view as a stack sees it: its intrinsic size, or
/// its fitting size when it has none.
@MainActor func shellNaturalSize(_ view: NSView) -> CGSize {
    let intrinsic = view.intrinsicContentSize
    if intrinsic.width != NSView.noIntrinsicMetric, intrinsic.height != NSView.noIntrinsicMetric { return intrinsic }
    let fitting = view.fittingSize
    return CGSize(width: intrinsic.width != NSView.noIntrinsicMetric ? intrinsic.width : fitting.width,
                  height: intrinsic.height != NSView.noIntrinsicMetric ? intrinsic.height : fitting.height)
}

/// Where a view's first text baseline sits below its top, as SwiftUI's
/// `.firstTextBaseline` reads it; a view without text answers its bottom.
@MainActor func shellBaseline(_ view: NSView, height: CGFloat) -> CGFloat {
    if let line = view as? PiKit.TextLine { return line.line.baseline(scale: view.piScale) }
    if let text = view as? ShellText { return NSLayoutManager().defaultBaselineOffset(for: text.font) }
    if let symbol = view as? PiKit.SymbolView { return shellSymbolBaseline(symbol.symbol, height: height) }
    if let custom = view as? ShellBaselined { return custom.firstBaseline }
    return height
}
/// A view that knows where its first text baseline is.
@MainActor protocol ShellBaselined: AnyObject { var firstBaseline: CGFloat { get } }
/// A symbol's baseline below the top of its layout box: the image's
/// alignment rectangle stands on the baseline.
@MainActor func shellSymbolBaseline(_ symbol: PiKit.Symbol, height: CGFloat) -> CGFloat {
    guard let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbol.size, weight: symbol.weight)) else { return height }
    let box = symbol.layoutSize
    // The drawn image is centred on the box; its alignment rect's bottom is the baseline.
    let top = (box.height - image.size.height) / 2
    return top + image.size.height - image.alignmentRect.minY
}

/// A row or a column of views, laid out as SwiftUI's `HStack` and `VStack`
/// lay theirs out, with frames: spacing between shown children only, room
/// to the most important and least flexible first, children placed on the
/// pixel grid.
@MainActor final class ShellStack: NSView, PiKit.WidthSizing {
    enum Axis { case horizontal, vertical }
    enum Alignment { case leading, center, trailing, top, bottom, firstBaseline }
    let axis: Axis
    var spacing: CGFloat { didSet { changed() } }
    var alignment: Alignment { didSet { changed() } }
    var padding: NSEdgeInsets { didSet { changed() } }
    var items: [ShellItem] = [] {
        didSet {
            let old = Set(oldValue.compactMap { $0.view.map(ObjectIdentifier.init) })
            let new = Set(items.compactMap { $0.view.map(ObjectIdentifier.init) })
            for item in oldValue { if let view = item.view, !new.contains(ObjectIdentifier(view)) { view.removeFromSuperview() } }
            for item in items { if let view = item.view, !old.contains(ObjectIdentifier(view)) || view.superview !== self { addSubview(view) } }
            changed()
        }
    }

    init(_ axis: Axis, spacing: CGFloat = 8, alignment: Alignment? = nil, padding: NSEdgeInsets = NSEdgeInsets(), _ items: [ShellItem] = []) {
        self.axis = axis; self.spacing = spacing; self.padding = padding
        self.alignment = alignment ?? (axis == .horizontal ? .center : .leading)
        super.init(frame: .zero)
        // Observers do not run inside the initializer.
        self.items = items
        for item in items { if let view = item.view { addSubview(view) } }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    /// A child changed size: the stack lays out again, and tells its own container.
    func changed() { invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) }
    /// Children were shown or hidden somewhere inside: this stack and every
    /// stack in it measure and lay out again.
    func relayoutAll() {
        invalidateIntrinsicContentSize(); needsLayout = true
        for item in items { (item.view as? ShellStack)?.relayoutAll(); if let view = item.view, !(view is ShellStack) { Self.relayout(inside: view) } }
    }
    private static func relayout(inside view: NSView) {
        for child in view.subviews {
            if let stack = child as? ShellStack { stack.relayoutAll() } else { relayout(inside: child) }
        }
        view.needsLayout = true; view.invalidateIntrinsicContentSize()
    }

    private var shownItems: [ShellItem] { items.filter(\.shown) }

    // MARK: Row

    /// Each shown child's width in a row `width` wide (inside the padding).
    private func rowWidths(_ width: CGFloat) -> [CGFloat] {
        let shown = shownItems
        guard !shown.isEmpty else { return [] }
        let gaps = spacing * CGFloat(shown.count - 1)
        var room = width - gaps
        var widths = Array(repeating: CGFloat(0), count: shown.count)
        var natural: [CGFloat] = shown.map { item in
            let inset = item.insets.left + item.insets.right
            switch item.size {
            case .natural, .flexible: return (item.view.map { shellNaturalSize($0).width } ?? 0) + inset
            case .fixed(let value): return value + inset
            case .spacer(let minimum): return minimum
            case .fill: return 0
            }
        }
        // Fixed and natural children take their size.
        for (index, item) in shown.enumerated() {
            switch item.size {
            case .natural, .fixed: widths[index] = natural[index]; room -= natural[index]
            case .spacer(let minimum): room -= minimum
            default: break
            }
        }
        // Flexible children: highest priority first, then the least flexible,
        // each offered an equal share of what is left.
        var flexible = shown.indices.filter { shown[$0].size == .flexible }
        flexible.sort { a, b in shown[a].priority != shown[b].priority ? shown[a].priority > shown[b].priority : natural[a] < natural[b] }
        var remaining = flexible.count
        var index = 0
        while index < flexible.count {
            let priority = shown[flexible[index]].priority
            let group = flexible[index...].prefix { shown[$0].priority == priority }
            // Lower priorities keep nothing back for themselves: SwiftUI
            // offers the higher ones everything but the others' minimum (0).
            var groupRemaining = group.count
            for child in group {
                let share = max(0, room) / CGFloat(groupRemaining)
                let taken = min(natural[child], share)
                widths[child] = taken; room -= taken; groupRemaining -= 1
            }
            remaining -= group.count; index += group.count
        }
        _ = remaining
        // Spacers and fills share what is left.
        let sharers = shown.indices.filter { if case .spacer = shown[$0].size { return true }; return shown[$0].size == .fill }
        if !sharers.isEmpty {
            let extra = max(0, room) / CGFloat(sharers.count)
            for child in sharers {
                if case .spacer(let minimum) = shown[child].size { widths[child] = minimum + extra } else { widths[child] = extra }
            }
        }
        natural.removeAll()
        return widths
    }
    private func childHeight(_ item: ShellItem, width: CGFloat) -> CGFloat {
        guard let view = item.view else { return 0 }
        let inner = max(0, width - item.insets.left - item.insets.right)
        let height: CGFloat
        if view is PiKit.WidthSizing { height = PiKit.height(of: view, width: inner) } else { height = shellNaturalSize(view).height }
        return height + item.insets.top + item.insets.bottom
    }
    /// The row's height and each child's frame in it; `height`, when given,
    /// is the height the row has, which it aligns its children within.
    private func layoutRow(width: CGFloat, height assigned: CGFloat? = nil) -> (CGFloat, [CGRect]) {
        let shown = shownItems
        let inner = width - padding.left - padding.right
        let widths = rowWidths(inner)
        let heights = zip(shown, widths).map { childHeight($0, width: $1) }
        let scale = piScale
        var height: CGFloat = heights.max() ?? 0
        var baselines: [CGFloat] = []
        var baseline: CGFloat = 0
        if alignment == .firstBaseline {
            baselines = zip(shown, heights).map { item, h in item.view.map { shellBaseline($0, height: h - item.insets.top - item.insets.bottom) + item.insets.top } ?? 0 }
            baseline = baselines.max() ?? 0
            height = zip(heights, baselines).map { $0 - $1 }.max().map { $0 + baseline } ?? 0
        }
        let natural = height
        if let assigned { height = max(height, assigned - padding.top - padding.bottom) }
        var frames: [CGRect] = []
        var x = padding.left
        for (index, item) in shown.enumerated() {
            let h = heights[index]
            let y: CGFloat
            switch alignment {
            case .top, .leading: y = 0
            case .bottom, .trailing: y = height - h
            case .center: y = PiKit.round((height - h) / 2, scale)
            case .firstBaseline: y = PiKit.round(baseline - baselines[index] + (height - natural) / 2, scale)
            }
            frames.append(CGRect(x: x + item.insets.left, y: padding.top + y + item.insets.top,
                                 width: max(0, widths[index] - item.insets.left - item.insets.right),
                                 height: max(0, h - item.insets.top - item.insets.bottom)))
            x += widths[index] + spacing
        }
        return (natural + padding.top + padding.bottom, frames)
    }

    // MARK: Column

    private func layoutColumn(width: CGFloat, height assigned: CGFloat? = nil) -> (CGFloat, [CGRect]) {
        let shown = shownItems
        let inner = width - padding.left - padding.right
        // Spare height, when the column has more than it needs, goes to its spacers.
        var spare: CGFloat = 0
        let spacers = shown.filter { if case .spacer = $0.size { return true }; return false }.count
        if let assigned, spacers > 0 {
            let natural = layoutColumn(width: width).0
            spare = max(0, assigned - natural) / CGFloat(spacers)
        }
        var y = padding.top
        var frames: [CGRect] = []
        let scale = piScale
        for item in shown {
            var childWidth = inner
            if let view = item.view, item.size == .natural {
                childWidth = min(inner, shellNaturalSize(view).width + item.insets.left + item.insets.right)
            } else if case .fixed(let value) = item.size, item.view != nil { childWidth = min(inner, value) }
            var h: CGFloat
            switch item.size {
            case .spacer(let minimum): h = minimum + spare
            default: h = childHeight(item, width: childWidth)
            }
            let x: CGFloat
            switch alignment {
            case .center: x = PiKit.round((inner - childWidth) / 2, scale)
            case .trailing, .bottom: x = inner - childWidth
            default: x = 0
            }
            if item.view == nil { h = max(0, h) }
            frames.append(CGRect(x: padding.left + x + item.insets.left, y: y + item.insets.top,
                                 width: max(0, childWidth - item.insets.left - item.insets.right),
                                 height: max(0, h - item.insets.top - item.insets.bottom)))
            y += h + spacing
        }
        if !shown.isEmpty { y -= spacing }
        return (y + padding.bottom, frames)
    }

    // MARK: Sizing

    func height(forWidth width: CGFloat) -> CGFloat {
        axis == .horizontal ? layoutRow(width: width).0 : layoutColumn(width: width).0
    }
    /// The natural width: every child at its own size.
    var naturalWidth: CGFloat {
        let shown = shownItems
        if axis == .horizontal {
            let widths = shown.map { item -> CGFloat in
                let inset = item.insets.left + item.insets.right
                switch item.size {
                case .natural, .flexible: return (item.view.map { shellNaturalSize($0).width } ?? 0) + inset
                case .fixed(let value): return value + inset
                case .spacer(let minimum): return minimum
                case .fill: return 0
                }
            }
            return widths.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1)) + padding.left + padding.right
        }
        let widest = shown.map { item -> CGFloat in
            let inset = item.insets.left + item.insets.right
            if case .fixed(let value) = item.size { return value + inset }
            if let view = item.view {
                if let text = view as? ShellText { return text.naturalWidth + inset }
                if let stack = view as? ShellStack { return stack.naturalWidth + inset }
                return shellNaturalSize(view).width + inset
            }
            return 0
        }.max() ?? 0
        return widest + padding.left + padding.right
    }
    override var intrinsicContentSize: NSSize {
        let width = naturalWidth
        return NSSize(width: width, height: height(forWidth: bounds.width > 0 ? bounds.width : width))
    }
    override func layout() {
        super.layout()
        let frames = axis == .horizontal ? layoutRow(width: bounds.width, height: bounds.height).1
            : layoutColumn(width: bounds.width, height: bounds.height).1
        for (item, frame) in zip(shownItems, frames) { if let view = item.view, view.frame != frame { view.frame = frame } }
    }
}

/// Text the reader can select and copy (`.textSelection(.enabled)`): wrapped,
/// or on one line cut as `truncation` says. Its text field sits two points
/// out on each side, where its cell insets the text, so the words land
/// where SwiftUI's `Text` put them.
@MainActor final class ShellSelectableText: NSView, PiKit.WidthSizing, ShellBaselined {
    let field: NSTextField
    let font: NSFont
    let singleLine: Bool
    var text: String { didSet { if oldValue != text { apply(); invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) } } }
    var color: NSColor { didSet { apply() } }

    init(_ text: String, font: NSFont, color: NSColor, singleLine: Bool = false, truncation: NSLineBreakMode = .byTruncatingTail) {
        self.text = text; self.font = font; self.color = color; self.singleLine = singleLine
        field = NSTextField(frame: .zero)
        super.init(frame: .zero)
        field.isEditable = false; field.isSelectable = true; field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.font = font
        if singleLine {
            field.maximumNumberOfLines = 1; field.usesSingleLineMode = true
            field.cell?.wraps = false; field.cell?.isScrollable = false
            field.lineBreakMode = truncation; field.cell?.truncatesLastVisibleLine = true
        } else {
            field.lineBreakMode = .byWordWrapping; field.cell?.wraps = true; field.cell?.isScrollable = false
            field.maximumNumberOfLines = 0
        }
        addSubview(field)
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var lineHeight: CGFloat { PiKit.Line("Ag", font: font, color: .black).lineHeight }
    private func apply() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = singleLine ? field.lineBreakMode : .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    var naturalWidth: CGFloat {
        text.components(separatedBy: "\n").map { PiKit.Line($0, font: font, color: .black).size(scale: piScale).width }.max() ?? 0
    }
    var firstBaseline: CGFloat { NSLayoutManager().defaultBaselineOffset(for: font) }
    func height(forWidth width: CGFloat) -> CGFloat {
        singleLine ? lineHeight : ShellWrap.height(text, font: font, width: width)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidth, height: height(forWidth: bounds.width > 0 ? bounds.width : naturalWidth))
    }
    override func layout() {
        super.layout()
        field.preferredMaxLayoutWidth = bounds.width
        field.frame = CGRect(x: -PiKit.fieldInset, y: 0, width: bounds.width + PiKit.fieldInset * 2, height: bounds.height)
    }
}

/// `PiKit.Note` with its text wrapped as SwiftUI wraps it (`ShellWrap`): a
/// small tone symbol and caption text; danger reads in its tone.
/// (PiKit.Note's text field breaks lines without the standard strategy, so
/// a last word can end up alone where `PiNote` kept two.)
@MainActor final class ShellNote: NSView, PiKit.WidthSizing {
    var text: String { didSet { guard oldValue != text else { return }; label.text = text; invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) } }
    let tone: PiTone
    private let icon: PiKit.SymbolView
    private let label: ShellSelectableText
    init(_ text: String, tone: PiTone = .neutral) {
        self.text = text; self.tone = tone
        let name = tone == .danger ? "exclamationmark.triangle.fill" : tone == .warning ? "exclamationmark.circle" : "info.circle"
        icon = PiKit.SymbolView(PiKit.Symbol(name, size: 11), color: tone == .neutral ? .piInkTertiary : tone.nsColor)
        label = ShellSelectableText(text, font: PiKit.Font.caption, color: tone == .danger ? tone.nsColor : .piInkSecondary)
        super.init(frame: .zero)
        addSubview(icon); addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var iconWidth: CGFloat { icon.symbol.layoutSize.width }
    var naturalWidth: CGFloat { iconWidth + 6 + label.naturalWidth }
    func height(forWidth width: CGFloat) -> CGFloat {
        max(label.height(forWidth: width - iconWidth - 6), 1 + icon.symbol.layoutSize.height)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidth, height: height(forWidth: bounds.width > 0 ? bounds.width : naturalWidth))
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let box = icon.symbol.layoutSize
        icon.frame = CGRect(x: 0, y: 1, width: box.width, height: box.height)
        let width = max(0, bounds.width - box.width - 6)
        label.frame = CGRect(x: box.width + 6, y: 0, width: width, height: label.height(forWidth: width))
    }
}
