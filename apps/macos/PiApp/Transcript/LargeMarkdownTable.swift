import AppKit
import SwiftUI

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
    private var window: NSWindow!

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
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
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
        let detailScroll = NSScrollView(); detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false; detailScroll.borderType = .noBorder
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false; detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 8, height: 8); detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        show(Self.placeholder, placeholder: true)
        window.contentView = NSHostingView(rootView: MarkdownTableWindowView(rows: rows.count, grid: scroll, detail: detailScroll,
                                                                             copy: { [weak self] in self?.copyTable() }))
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
    @objc private func copyTable() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownTablePresentation.tsv(header: header, rows: rows), forType: .string)
    }
    func windowWillClose(_ notification: Notification) {
        table.delegate = nil; table.dataSource = nil; window.delegate = nil
        Self.windows[id] = nil
    }
}

/// The window's layout: its bar, the grid on a Pi surface, and the chosen
/// cell's whole text under it.
private struct MarkdownTableWindowView: View {
    let rows: Int
    let grid: NSView, detail: NSView
    let copy: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                PiWindowBar()
                HStack(spacing: PiSpacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Table").font(PiFont.title(14)).foregroundStyle(Color.piInk)
                        Text("\(rows.formatted()) rows").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }.allowsHitTesting(false)
                    Spacer(minLength: 8)
                    Button("Copy full table as TSV", action: copy).buttonStyle(.piSecondaryCompact)
                        .accessibilityIdentifier("table-window-copy")
                }
                .padding(.leading, PiWindowBar.trafficLightInset).padding(.trailing, PiSpacing.md)
            }
            .frame(height: 48)
            MarkdownTableHostedView(view: grid)
                .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).strokeBorder(Color.piHairline))
                .padding(.horizontal, PiSpacing.md)
            MarkdownTableHostedView(view: detail)
                .frame(height: 120)
                .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).strokeBorder(Color.piHairline))
                .padding(PiSpacing.md)
        }
        .background(Color.piWindow)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The window's own AppKit views, kept as they are: nothing here makes,
/// reloads or focuses them again.
private struct MarkdownTableHostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
