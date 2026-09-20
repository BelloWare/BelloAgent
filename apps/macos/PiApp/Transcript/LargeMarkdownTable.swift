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

@MainActor final class MarkdownTableWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var windows: [UUID: MarkdownTableWindow] = [:]
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
        window.title = "Table · \(rows.count.formatted()) rows"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 440, height: 300); window.center()
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        table.rowHeight = 26; table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(selectCell)
        table.setAccessibilityLabel("Full table; select a cell to read its complete contents")
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        for index in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = header.indices.contains(index) ? header[index] : "Column \(index + 1)"
            // A bounded sample sets stable columns. Offscreen content never
            // changes their widths as the reader scrolls.
            let length = ([column.title] + rows.prefix(40).compactMap { $0.indices.contains(index) ? $0[index] : nil }).map { $0.prefix(60).count }.max() ?? 12
            column.width = CGFloat(max(120, min(420, length * 7 + 24))); column.minWidth = 60
            table.addTableColumn(column)
        }
        let detailScroll = NSScrollView(); detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        detail.isEditable = false; detail.isSelectable = true; detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 8, height: 8); detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.string = "Select a cell to read and copy its full contents. Rows are compact; no data is omitted."
        let copy = NSButton(title: "Copy full table as TSV", target: self, action: #selector(copyTable))
        for view in [scroll, detailScroll, copy] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            copy.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), copy.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), detailScroll.heightAnchor.constraint(equalToConstant: 120),
            detailScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), detailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), detailScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let index = Int(column.identifier.rawValue), rows.indices.contains(row) else { return nil }
        let field = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier; field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        field.stringValue = rows[row].indices.contains(index) ? rows[row][index] : ""
        return field
    }
    @objc private func selectCell() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        let column = table.clickedColumn
        guard rows.indices.contains(row) else { return }
        detail.string = rows[row].indices.contains(column) ? rows[row][column] : rows[row].joined(separator: "\t")
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
