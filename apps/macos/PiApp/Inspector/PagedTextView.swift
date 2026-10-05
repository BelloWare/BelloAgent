import AppKit

/// A native, selectable retained text surface. Text is installed only when it
/// changes; scrolling or a progress publication never copies the payload.
@MainActor final class PagedTextView: NSScrollView {
    let editor = NSTextView()
    private var revision = 0
    var text: String {
        get { editor.string }
        set {
            guard editor.string != newValue else { return }
            editor.string = newValue
            revision += 1; let current = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == current else { return }
                self.editor.scrollToBeginningOfDocument(nil)
            }
        }
    }
    init(text: String, accessibilityLabel: String = "Read-only payload text") {
        super.init(frame: .zero)
        hasVerticalScroller = true; hasHorizontalScroller = false; borderType = .noBorder
        drawsBackground = false; autohidesScrollers = true
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.setAccessibilityLabel(accessibilityLabel); documentView = editor
        self.text = text
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
}

/// A flexible viewport with an intrinsic/explicit height when placed in a
/// page stack, and all remaining height when its enclosing sheet supplies it.
@MainActor final class PayloadViewport: DashView, PiKit.WidthSizing {
    let content: NSView
    let preferredHeight: CGFloat
    init(_ content: NSView, height: CGFloat = 300) {
        self.content = content; preferredHeight = height
        super.init(frame: .zero); addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { preferredHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }
    override func layout() { super.layout(); content.frame = bounds }
}

/// A page column in which explicit viewports take the spare height. Controls
/// above and below remain reachable when the reader scrolls a large payload.
@MainActor final class PayloadColumn: DashView, PiKit.WidthSizing {
    struct Item {
        let view: NSView
        var fixed: CGFloat? = nil
        var flexible = false
        static func view(_ view: NSView) -> Item { Item(view: view) }
        static func fixed(_ view: NSView, _ height: CGFloat) -> Item { Item(view: view, fixed: height) }
        static func flexible(_ view: NSView, ideal: CGFloat = 300) -> Item { Item(view: view, fixed: ideal, flexible: true) }
    }
    var spacing: CGFloat
    var padding: NSEdgeInsets
    var items: [Item] = [] {
        didSet {
            let keep = Set(items.map { ObjectIdentifier($0.view) })
            for item in oldValue where !keep.contains(ObjectIdentifier(item.view)) { item.view.removeFromSuperview() }
            for item in items where item.view.superview !== self { addSubview(item.view) }
            invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
        }
    }
    init(spacing: CGFloat = PiSpacing.sm, padding: NSEdgeInsets = NSEdgeInsets(), items: [Item] = []) {
        self.spacing = spacing; self.padding = padding; self.items = items
        super.init(frame: .zero); for item in items { addSubview(item.view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var shown: [Item] { items.filter { !$0.view.isHidden } }
    private func height(_ item: Item, width: CGFloat) -> CGFloat { item.fixed ?? max(0, PiKit.height(of: item.view, width: width)) }
    func height(forWidth width: CGFloat) -> CGFloat {
        let items = shown, inner = max(0, width - padding.left - padding.right)
        return padding.top + padding.bottom + items.reduce(0) { $0 + height($1, width: inner) } + CGFloat(max(0, items.count - 1)) * spacing
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }
    override func layout() {
        super.layout()
        let items = shown, width = max(0, bounds.width - padding.left - padding.right)
        let fixed = items.filter { !$0.flexible }.reduce(0) { $0 + height($1, width: width) }
        let count = items.filter(\.flexible).count
        let spare = max(0, bounds.height - padding.top - padding.bottom - fixed - CGFloat(max(0, items.count - 1)) * spacing)
        var y = padding.top
        for item in items {
            let height = item.flexible && count > 0 ? spare / CGFloat(count) : height(item, width: width)
            item.view.frame = CGRect(x: padding.left, y: y, width: width, height: height)
            y += height + spacing
        }
    }
}

/// A wrapping document inside a transparent native scroll view.
@MainActor final class PayloadScroll: NSScrollView {
    let content: NSView
    private let document = DashView()
    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        hasVerticalScroller = true; autohidesScrollers = true; drawsBackground = false; borderType = .noBorder
        document.addSubview(content); documentView = document
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() {
        super.layout()
        let width = contentView.bounds.width, height = max(contentView.bounds.height, PiKit.height(of: content, width: width))
        document.frame = CGRect(x: 0, y: 0, width: width, height: height)
        content.frame = document.bounds
    }
}

/// The inspector's resizable two columns, with the same list limits as the
/// original HSplitView and a stable divider position while content updates.
@MainActor final class PayloadSplit: NSSplitView, NSSplitViewDelegate {
    let minimum: CGFloat, ideal: CGFloat, maximum: CGFloat, trailingMinimum: CGFloat
    private var started = false
    init(leading: NSView, trailing: NSView, minimum: CGFloat, ideal: CGFloat, maximum: CGFloat, trailingMinimum: CGFloat) {
        // The original HSplitView put an eight-point gutter outside each
        // pane's width limit. Keep that gutter beside the native divider.
        let gutter = PiSpacing.sm
        self.minimum = minimum + gutter; self.ideal = ideal + gutter
        self.maximum = maximum + gutter; self.trailingMinimum = trailingMinimum + gutter
        super.init(frame: .zero); isVertical = true; dividerStyle = .thin; delegate = self
        addArrangedSubview(PayloadColumn(spacing: 0, padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: gutter), items: [.flexible(leading)]))
        addArrangedSubview(PayloadColumn(spacing: 0, padding: NSEdgeInsets(top: 0, left: gutter, bottom: 0, right: 0), items: [.flexible(trailing)]))
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() {
        super.layout()
        guard !started, bounds.width > 0 else { return }; started = true
        setPosition(min(ideal, max(minimum, bounds.width - trailingMinimum - dividerThickness)), ofDividerAt: 0)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimum }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(maximum, max(minimum, bounds.width - trailingMinimum - dividerThickness)) }
}

/// Selectable one-line text whose measurement obeys the same single-line
/// limit as its field, including middle-truncated source paths and digests.
@MainActor final class PayloadSingleLine: DashView, PiKit.WidthSizing {
    let field: PiKit.SelectableText
    private let line: PiKit.Line
    init(_ text: String, font: NSFont, color: NSColor) {
        field = PiKit.SelectableText(text, font: font, color: color)
        field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle
        line = PiKit.Line(text, font: font, color: color)
        super.init(frame: .zero); addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { line.lineHeight }
    override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
    override func layout() { super.layout(); field.frame = bounds.insetBy(dx: -PiKit.fieldInset, dy: 0) }
}
