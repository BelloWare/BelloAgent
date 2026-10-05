import AppKit

/// A vertical list in a scroll view that makes only the rows in view, as a
/// `LazyVStack` in a `ScrollView` did: rows `spacing` apart inside `insets`,
/// each as tall as its source says for the width. Rows that stay keep their
/// views when the list is given new rows; a row scrolled far out of view
/// gives its view back.
@MainActor final class LazyStackView: NSScrollView {
    /// What the list shows.
    struct Source {
        var count: Int
        var key: @MainActor (Int) -> AnyHashable
        var height: @MainActor (Int, CGFloat) -> CGFloat
        /// The row's view: `existing` is the one it had, to update or replace.
        var view: @MainActor (Int, NSView?) -> NSView
    }
    var spacing: CGFloat = 0 { didSet { invalidateRows() } }
    var insets = NSEdgeInsets() { didSet { invalidateRows() } }
    /// How far beyond the visible part rows are kept made.
    var overscan: CGFloat = 240
    private var source = Source(count: 0, key: { $0 }, height: { _, _ in 0 }, view: { _, _ in NSView() })
    private let document = Document()
    private var offsets: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var measuredWidth: CGFloat = -1
    private var made: [AnyHashable: NSView] = [:]

    final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true; drawsBackground = false; borderType = .noBorder
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// New rows: heights measured again, views kept by key.
    func reload(_ source: Source) {
        self.source = source
        invalidateRows()
    }
    /// The same rows, their heights unchanged, shown in a new state: only the
    /// rows in view are updated.
    func update(_ source: Source) {
        guard source.count == heights.count else { reload(source); return }
        self.source = source
        tileRows()
    }
    private func invalidateRows() {
        measuredWidth = -1
        needsLayout = true
        tileRows()
    }
    /// The rows' total height at `width`, insets included.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = width - insets.left - insets.right
        var height = insets.top + insets.bottom
        for index in 0..<source.count { height += source.height(index, inner) + (index > 0 ? spacing : 0) }
        return height
    }
    @objc private func scrolled() { tileRows() }
    override func layout() { super.layout(); tileRows() }

    private func measure(width: CGFloat) {
        guard width != measuredWidth || heights.count != source.count else { return }
        measuredWidth = width
        let inner = width - insets.left - insets.right
        heights = (0..<source.count).map { source.height($0, inner) }
        offsets = []
        var y = insets.top
        for (index, height) in heights.enumerated() { offsets.append(y); y += height + (index < heights.count - 1 ? spacing : 0) }
        rowsHeight = y + insets.bottom
    }
    private var rowsHeight: CGFloat = 0
    /// The document as tall as the rows, or the view when they are shorter.
    private func sizeDocument(width: CGFloat) {
        let documentHeight = max(rowsHeight, contentView.bounds.height)
        if document.frame.size != CGSize(width: width, height: documentHeight) {
            document.frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)
        }
    }

    /// Makes the rows in view, places them, and lets go of the rest.
    private func tileRows() {
        let width = contentView.bounds.width
        guard width > 0 else { return }
        measure(width: width)
        sizeDocument(width: width)
        let visible = contentView.bounds.insetBy(dx: 0, dy: -overscan)
        var keep: [AnyHashable: NSView] = [:]
        let inner = width - insets.left - insets.right
        if !offsets.isEmpty {
            // The first row reaching into view, by binary search.
            var low = 0, high = offsets.count - 1
            while low < high { let middle = (low + high) / 2; if offsets[middle] + heights[middle] < visible.minY { low = middle + 1 } else { high = middle } }
            var index = low
            while index < offsets.count, offsets[index] <= visible.maxY {
                let key = source.key(index)
                let existing = made[key]
                let view = source.view(index, existing)
                if view !== existing { existing?.removeFromSuperview() }
                if view.superview !== document { document.addSubview(view) }
                let frame = CGRect(x: insets.left, y: offsets[index], width: inner, height: heights[index])
                if view.frame != frame { view.frame = frame }
                keep[key] = view
                index += 1
            }
        }
        for (key, view) in made where keep[key] == nil || keep[key] !== view { view.removeFromSuperview() }
        made = keep
    }

    /// The view made for a row, if it is in view.
    func madeView(for key: AnyHashable) -> NSView? { made[key] }
    /// Scrolls the least needed to show the row at `index`.
    func scrollToRow(_ index: Int) {
        measure(width: contentView.bounds.width)
        guard index < offsets.count else { return }
        let rect = CGRect(x: 0, y: offsets[index], width: 1, height: heights[index])
        let clip = contentView.bounds
        var y = clip.minY
        if rect.minY < clip.minY { y = rect.minY } else if rect.maxY > clip.maxY { y = rect.maxY - clip.height }
        guard y != clip.minY else { return }
        contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        reflectScrolledClipView(contentView)
    }
    /// Scrolls the row at `index` to the middle of the view (`scrollTo(_:anchor: .center)`), as far as the list allows.
    func scrollToRowCentred(_ index: Int) {
        measure(width: contentView.bounds.width)
        guard index < offsets.count else { return }
        let clip = contentView.bounds
        let y = min(max(0, offsets[index] + heights[index] / 2 - clip.height / 2), max(0, (documentView?.frame.height ?? 0) - clip.height))
        guard y != clip.minY else { return }
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
    /// Back to the top.
    func scrollToTop() {
        guard contentView.bounds.minY != 0 else { return }
        contentView.scroll(to: .zero); reflectScrolledClipView(contentView)
    }
}
