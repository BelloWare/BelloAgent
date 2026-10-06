import AppKit

// Pieces the live monitor, the usage panel and the report share (0.1.120):
// SwiftUI's `DisclosureGroup` and `Divider` as macOS drew them, the monitor's
// range picker, and a figure with its caption.

/// `DisclosureGroup(title, isExpanded:)` as SwiftUI drew it on macOS: the
/// system's disclosure triangle, the title after it, and the content under
/// it, inset as the group inset it, while open.
@MainActor final class DisclosureGroupView: DashView, PiKit.WidthSizing {
    /// Measured against SwiftUI (`MonitorParityTests`): the title row is 22
    /// points tall, the title 12 points in, the content 21 points in,
    /// straight under the row.
    static var rowHeight: CGFloat = 22
    static var titleInset: CGFloat = 11.5
    static var contentIndent: CGFloat = 21
    static var contentGap: CGFloat = 0
    static var labelTrailing: CGFloat = 4
    /// The chevron's ink, as measured: a quarter black in light, white in dark.
    static let chevron = NSColor.piDynamic(light: NSColor(white: 0, alpha: 0.255), dark: .white)

    let content: NSView
    var isExpanded: Bool { didSet { if oldValue != isExpanded { changed() } } }
    var onToggle: ((Bool) -> Void)?
    private let header: Header

    init(_ title: String, font: NSFont, color: NSColor, content: NSView, isExpanded: Bool = false) {
        self.content = content; self.isExpanded = isExpanded
        header = Header(title: title, font: font, color: color)
        super.init(frame: .zero)
        addSubview(header); addSubview(content)
        header.onPress = { [weak self] in self?.toggle() }
        header.expanded = isExpanded
        content.isHidden = !isExpanded
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    var title: String {
        get { header.line.text }
        set { guard header.line.text != newValue else { return }; header.line.text = newValue; header.setAccessibilityLabel(newValue); header.invalidateIntrinsicContentSize(); header.redrawContent(); changed() }
    }
    var titleColor: NSColor {
        get { header.line.color }
        set { header.line.color = newValue; header.redrawContent() }
    }
    /// The header's button, for tests and the key-view loop.
    var button: NSButton { header }
    /// A figure at the label's trailing edge (a label `HStack` with a
    /// `Spacer` before it): the header then takes the whole width, its
    /// title cut in the middle.
    var trailing: String? {
        get { header.trailing?.text }
        set { header.trailing = newValue.map { PiKit.Line($0, font: PiKit.Font.monospacedDigits(header.line.font), color: header.line.color) }; header.redrawContent(); needsLayout = true }
    }

    private func toggle() {
        isExpanded.toggle()
        onToggle?(isExpanded)
    }
    private func changed() {
        header.expanded = isExpanded
        content.isHidden = !isExpanded
        invalidateIntrinsicContentSize(); needsLayout = true
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let top = header.intrinsicContentSize.height
        guard isExpanded else { return top }
        return top + Self.contentGap + PiKit.height(of: content, width: max(0, width - Self.contentIndent))
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() {
        super.layout()
        let top = header.intrinsicContentSize
        header.frame = CGRect(x: 0, y: 0, width: header.trailing == nil ? min(bounds.width, top.width) : bounds.width, height: top.height)
        if isExpanded {
            let width = max(0, bounds.width - Self.contentIndent)
            content.frame = CGRect(x: Self.contentIndent, y: top.height + Self.contentGap, width: width, height: PiKit.height(of: content, width: width))
        }
    }

    /// The triangle and the title, one button.
    final class Header: PiKit.ButtonBase {
        var line: PiKit.Line
        var trailing: PiKit.Line?
        var expanded = false {
            didSet {
                guard expanded != oldValue else { return }
                redrawContent()
                setAccessibilityExpanded(expanded)
            }
        }
        init(title: String, font: NSFont, color: NSColor) {
            line = PiKit.Line(title, font: font, color: color)
            super.init(frame: .zero)
            pressScales = false
            showsPointer = false
            setAccessibilityRole(.disclosureTriangle)
            setAccessibilityLabel(title)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize {
            let text = line.size(scale: piScale)
            return NSSize(width: DisclosureGroupView.titleInset + text.width, height: DisclosureGroupView.rowHeight)
        }
        override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            // The system's chevron, light (tertiary ink): pointing right while
            // closed, down while open, centred where SwiftUI centres it.
            let path = CGMutablePath()
            if expanded {
                let c = CGPoint(x: 2.75, y: rect.midY + 0.25)
                path.move(to: CGPoint(x: c.x - 3.4, y: c.y - 1.6)); path.addLine(to: CGPoint(x: c.x, y: c.y + 1.6)); path.addLine(to: CGPoint(x: c.x + 3.4, y: c.y - 1.6))
            } else {
                let c = CGPoint(x: 3.75, y: rect.midY - 0.5)
                path.move(to: CGPoint(x: c.x - 1.6, y: c.y - 3.4)); path.addLine(to: CGPoint(x: c.x + 1.6, y: c.y)); path.addLine(to: CGPoint(x: c.x - 1.6, y: c.y + 3.4))
            }
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setStrokeColor(DisclosureGroupView.chevron.cgColor)
                context.setLineWidth(1.4); context.setLineCap(.butt); context.setLineJoin(.miter)
                context.addPath(path); context.strokePath()
                context.restoreGState()
            }
            let text = line.size(scale: piScale)
            let x = DisclosureGroupView.titleInset, y = PiKit.round((rect.height - text.height) / 2, piScale)
            if let trailing {
                let figure = trailing.size(scale: piScale)
                // Measured: SwiftUI leaves the label four points short of the group's end.
                trailing.draw(at: CGPoint(x: rect.width - DisclosureGroupView.labelTrailing - figure.width, y: y), scale: piScale)
                line.draw(in: CGRect(x: x, y: y, width: max(0, min(text.width, rect.width - DisclosureGroupView.labelTrailing - figure.width - 8 - x)), height: text.height), truncation: .middle, scale: piScale)
            } else {
                line.draw(at: CGPoint(x: x, y: y), scale: piScale)
            }
        }
        override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    }
}

/// SwiftUI's `Divider()` in a vertical stack: a one-pixel separator line
/// across the stack.
@MainActor final class DividerView: FillView {
    static var thickness: CGFloat = 1
    init() { super.init(.separatorColor) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A figure and what it is, in a column that takes its share of a row: the
/// monitor's totals.
@MainActor final class MonitorFigure: DashView {
    let value = PiKit.TextLine(PiKit.Line("—", font: PiKit.Font.monospacedDigits(PiKit.Font.title(22)), color: .labelColor))
    let title: PiKit.TextLine
    init(title: String) {
        self.title = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.caption, color: .piInkSecondary))
        super.init(frame: .zero)
        addSubview(value); addSubview(self.title)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func set(_ text: String) { value.line.text = text; needsLayout = true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: value.intrinsicContentSize.height + 4 + title.intrinsicContentSize.height)
    }
    override func layout() {
        super.layout()
        let size = value.intrinsicContentSize
        value.frame = CGRect(x: 0, y: 0, width: min(bounds.width, size.width), height: size.height)
        title.frame = CGRect(x: 0, y: size.height + 4, width: min(bounds.width, title.intrinsicContentSize.width), height: title.intrinsicContentSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {}
}


/// A view at least `minimum` tall (`.frame(minHeight:)`), its content at the top.
@MainActor final class MinimumHeight: DashView, PiKit.WidthSizing {
    let content: NSView
    let minimum: CGFloat
    init(_ content: NSView, minimum: CGFloat) {
        self.content = content; self.minimum = minimum
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { max(minimum, PiKit.height(of: content, width: width)) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func layout() { super.layout(); content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PiKit.height(of: content, width: bounds.width)) }
}

/// A view in a slot of a fixed height (`.frame(height:)`), its content
/// centred in it vertically, at its own width or across the slot.
@MainActor final class FixedHeight: DashView, PiKit.WidthSizing {
    let content: NSView
    let height: CGFloat
    let fills: Bool
    init(_ content: NSView, height: CGFloat, fills: Bool = false) {
        self.content = content; self.height = height; self.fills = fills
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { height }
    override var intrinsicContentSize: NSSize { NSSize(width: fills ? NSView.noIntrinsicMetric : content.intrinsicContentSize.width, height: height) }
    override func layout() {
        super.layout()
        if fills { content.frame = bounds; return }
        let size = content.intrinsicContentSize
        content.frame = CGRect(x: 0, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: min(bounds.width, size.width), height: size.height)
    }
}
