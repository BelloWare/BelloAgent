import AppKit

/// Large tables have a deliberately bounded inline preview. The full table is
/// backed by NSTableView's visible-row reuse; source/copy never depend on views.
enum MarkdownTablePresentation {
    static let previewRows = 20
    static let previewColumns = 8
    static func isLarge(header: [AttributedString], rows: [[AttributedString]]) -> Bool {
        rows.count > 40 || header.count > previewColumns || rows.contains { $0.count > previewColumns }
    }
    static func plain(_ row: [AttributedString]) -> [String] { row.map { String($0.characters) } }
    static func tsv(header: [String], rows: [[String]]) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        return ([header] + rows).map { $0.map(field).joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// The full table in a window of the app's own: its title bar and canvas,
/// the Copy action as a Pi button, and the grid and the chosen cell's whole
/// text on Pi surfaces. The grid stays an `NSTableView`, so only the rows on
/// screen have views, and the cell's text stays an `NSTextView` to select and
/// copy from.
@MainActor final class MarkdownTableWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var windows: [UUID: MarkdownTableWindow] = [:]
    static let placeholder = "Select a cell to read and copy its full contents. Rows are compact; no data is omitted."
    private let id = UUID()
    private let header: [String]
    private let rows: [[String]]
    private let table = NSTableView()
    private let detail = NSTextView()
    /// The grid's and the cell text's scroll views, as the window lays them out.
    let gridScroll = NSScrollView(), detailScroll = NSScrollView()
    private(set) var window: NSWindow!
    /// The table windows open now.
    static var open: [NSWindow] { windows.values.map(\.window) }
    static func controller(of window: NSWindow) -> MarkdownTableWindow? { windows.values.first { $0.window === window } }

    static func open(header: [AttributedString], rows: [[AttributedString]]) {
        let controller = MarkdownTableWindow(header: plain(header), rows: rows.map { MarkdownTablePresentation.plain($0) })
        windows[controller.id] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }
    private static func plain(_ row: [AttributedString]) -> [String] { MarkdownTablePresentation.plain(row) }
    private init(header: [String], rows: [[String]]) {
        self.header = header; self.rows = rows
        super.init()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // The title stays for the Window menu; the window draws its own bar.
        window.title = "Table · \(rows.count.formatted()) rows"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 440, height: 300)
        window.applyPiWindowChrome()
        window.center()
        let scroll = gridScroll; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.style = .plain; table.rowHeight = 26; table.usesAlternatingRowBackgroundColors = false; table.allowsMultipleSelection = false
        table.backgroundColor = .piSurface; table.gridColor = .piHairline; table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.headerView = MarkdownTableHeaderView(); table.cornerView = MarkdownTableCornerView()
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(selectCell)
        table.setAccessibilityLabel("Full table; select a cell to read its complete contents")
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        for index in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = header.indices.contains(index) ? header[index] : "Column \(index + 1)"
            column.headerCell = MarkdownTableHeaderCell(textCell: column.title)
            // A bounded sample sets stable columns. Offscreen content never
            // changes their widths as the reader scrolls.
            let length = ([column.title] + rows.prefix(40).compactMap { $0.indices.contains(index) ? $0[index] : nil }).map { $0.prefix(60).count }.max() ?? 12
            column.width = CGFloat(max(120, min(420, length * 7 + 24))); column.minWidth = 60
            table.addTableColumn(column)
        }
        detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false; detailScroll.borderType = .noBorder
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false; detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 8, height: 8); detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        show(Self.placeholder, placeholder: true)
        window.contentView = MarkdownTableWindowContent(rows: rows.count, grid: scroll, detail: detailScroll,
                                                        copy: { [weak self] in self?.copyTable() })
        window.initialFirstResponder = table
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let index = Int(column.identifier.rawValue), rows.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? MarkdownTableCell ?? MarkdownTableCell(identifier: column.identifier)
        cell.label.stringValue = rows[row].indices.contains(index) ? rows[row][index] : ""
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: MarkdownTableRowView.reuse, owner: self) as? MarkdownTableRowView ?? MarkdownTableRowView()
    }
    @objc private func selectCell() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        let column = table.clickedColumn
        guard rows.indices.contains(row) else { return }
        show(rows[row].indices.contains(column) ? rows[row][column] : rows[row].joined(separator: "\t"), placeholder: false)
    }
    /// The chosen cell's whole text in ink; the hint before any in the quieter ink.
    private func show(_ text: String, placeholder: Bool) {
        detail.string = text
        detail.textColor = placeholder ? .piInkSecondary : .piInk
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectCell() }
    @objc func copyTable() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownTablePresentation.tsv(header: header, rows: rows), forType: .string)
    }
    func windowWillClose(_ notification: Notification) {
        table.delegate = nil; table.dataSource = nil; window.delegate = nil
        Self.windows[id] = nil
    }
}

/// The window's layout: its bar (the title, the row count and the Copy), the
/// grid on a Pi surface, and the chosen cell's whole text under it, on the
/// window's canvas from its very top.
@MainActor final class MarkdownTableWindowContent: NSView {
    static let barHeight: CGFloat = 48
    static let detailHeight: CGFloat = 120
    private let bar = PiWindowBarView(frame: .zero)
    private let title = PiKit.TextLine(PiKit.Line("Table", font: PiKit.Font.title(14), color: .piInk))
    private let count: PiKit.TextLine
    let copy: PiKit.Button
    private let gridFrame = MarkdownTableFrame(surface: false), detailFrame = MarkdownTableFrame(surface: true)
    override var isFlipped: Bool { true }
    init(rows: Int, grid: NSView, detail: NSView, copy action: @escaping () -> Void) {
        count = PiKit.TextLine(PiKit.Line("\(rows.formatted()) rows", font: PiKit.Font.caption, color: .piInkSecondary))
        copy = PiKit.Button("Copy full table as TSV", style: .secondary, compact: true, action: action)
        super.init(frame: .zero)
        wantsLayer = true
        copy.setAccessibilityIdentifier("table-window-copy")
        // The bar is the window's drag area behind the words and the Copy,
        // which stand over it.
        addSubview(bar)
        for view in [title, count] { view.setAccessibilityElement(false); addSubview(view) }
        addSubview(copy)
        gridFrame.content = grid; detailFrame.content = detail
        addSubview(gridFrame); addSubview(detailFrame)
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        // The title over the count, one point apart, beside the Copy, centred
        // on the bar's line.
        let titleSize = title.intrinsicContentSize, countSize = count.intrinsicContentSize
        let text = CGSize(width: max(titleSize.width, countSize.width), height: titleSize.height + 1 + countSize.height)
        let button = copy.intrinsicContentSize
        let right = bounds.width - PiSpacing.md
        copy.frame = CGRect(x: right - button.width, y: PiKit.round((Self.barHeight - button.height) / 2, scale), width: button.width, height: button.height)
        let top = PiKit.round((Self.barHeight - text.height) / 2, scale)
        let room = max(0, copy.frame.minX - PiSpacing.sm - 8 - PiWindowBar.trafficLightInset)
        title.frame = CGRect(x: PiWindowBar.trafficLightInset, y: top, width: min(titleSize.width, room), height: titleSize.height)
        count.frame = CGRect(x: PiWindowBar.trafficLightInset, y: PiKit.round(top + titleSize.height + 1, scale), width: min(countSize.width, room), height: countSize.height)
        let detailTop = bounds.height - PiSpacing.md - Self.detailHeight
        gridFrame.frame = CGRect(x: PiSpacing.md, y: Self.barHeight, width: max(0, bounds.width - PiSpacing.md * 2),
                                 height: max(0, detailTop - PiSpacing.md - Self.barHeight))
        detailFrame.frame = CGRect(x: PiSpacing.md, y: detailTop, width: max(0, bounds.width - PiSpacing.md * 2), height: Self.detailHeight)
    }
}

/// A rounded Pi frame around one of the window's AppKit views: the view
/// clipped to it, a hairline just inside its edge, and the surface behind it
/// when asked.
@MainActor final class MarkdownTableFrame: NSView {
    private let clip = NSView()
    private let border = Border()
    /// The hairline: drawn over the content, never in the way of a click.
    private final class Border: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    private let surface: Bool
    var content: NSView? { didSet { oldValue?.removeFromSuperview(); if let content { clip.addSubview(content) } } }
    init(surface: Bool) {
        self.surface = surface
        super.init(frame: .zero)
        for view in [clip, border] {
            view.wantsLayer = true
            view.layer?.cornerRadius = PiRadius.md; view.layer?.cornerCurve = .continuous
            addSubview(view)
        }
        clip.layer?.masksToBounds = true
        border.layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        clip.frame = bounds; border.frame = bounds
        content?.frame = clip.bounds
        updateColors()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            clip.layer?.backgroundColor = surface ? NSColor.piSurface.cgColor : nil
            border.layer?.borderColor = NSColor.piHairline.cgColor
        }
    }
}

/// A cell: its text in body ink, 8 points in from either edge and centred in
/// the row, cut with "…" where the column is narrower.
private final class MarkdownTableCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 13); label.textColor = .piInk
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        addSubview(label); textField = label
    }
    required init?(coder: NSCoder) { return nil }
    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 8, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - 16), height: height)
    }
}

/// A selected row in the accent's soft fill, its text keeping its ink.
private final class MarkdownTableRowView: NSTableRowView {
    static let reuse = NSUserInterfaceItemIdentifier("markdown-table-row")
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); identifier = Self.reuse }
    required init?(coder: NSCoder) { return nil }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.piAccentSoft.setFill(); bounds.fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The column titles on the sunken surface, in caption ink, with a hairline
/// under them and between them. Every column is drawn here, so no stock
/// header paint shows beside or behind them.
private final class MarkdownTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.piSurfaceSunken.setFill(); dirtyRect.fill()
        guard let table = tableView else { return }
        for index in table.tableColumns.indices {
            var frame = headerRect(ofColumn: index)
            if index == draggedColumn { frame.origin.x += draggedDistance }
            guard frame.intersects(dirtyRect) else { continue }
            table.tableColumns[index].headerCell.draw(withFrame: frame, in: self)
        }
        NSColor.piHairline.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
    }
}

private final class MarkdownTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.piSurfaceSunken.setFill(); cellFrame.fill()
        NSColor.piHairline.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5, width: 1, height: max(0, cellFrame.height - 10)).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.piInkSecondary, .paragraphStyle: paragraph])
        let height = ceil(title.size().height)
        title.draw(with: NSRect(x: cellFrame.minX + 8, y: cellFrame.minY + floor((cellFrame.height - height) / 2), width: max(0, cellFrame.width - 16), height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Above the vertical scroller: the header's surface and hairline.
private final class MarkdownTableCornerView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.piSurfaceSunken.setFill(); bounds.fill()
        NSColor.piHairline.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
