import AppKit

/// A virtualized AppKit tree with host-provided colours. It uses the native
/// table's keyboard selection and accessibility rows, with custom cells and
/// highlights so the host's design system supplies the entire visible face.
@MainActor public final class FolderTreeView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public struct Style {
        public var background: NSColor = .controlBackgroundColor
        public var ink: NSColor = .labelColor
        public var secondary: NSColor = .secondaryLabelColor
        public var selection: NSColor = .selectedContentBackgroundColor
        public var font: NSFont = .systemFont(ofSize: 12)
        public init() {}
    }
    public var style = Style() { didSet { table.backgroundColor = style.background; table.reloadData() } }
    public let browser: FolderBrowser
    public let table: NSTableView
    private let scroll = NSScrollView()
    private var rows: [FolderBrowser.Row] = []
    private var syncing = false
    private var lastSelection: URL?
    private var pendingReveal: URL?
    public init(browser: FolderBrowser) {
        self.browser = browser
        let table = FolderTable(); self.table = table
        super.init(frame: .zero)
        table.owner = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.headerView = nil; table.rowHeight = 26; table.intercellSpacing = .zero
        table.style = .plain; table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Folder tree")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; addSubview(scroll)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout(); scroll.frame = bounds
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
    public func reload() {
        syncing = true; defer { syncing = false }
        if lastSelection != browser.selectedURL {
            lastSelection = browser.selectedURL; pendingReveal = browser.selectedURL
        }
        let updated = browser.rows
        if updated != rows { rows = updated; table.reloadData() }
        if let index = rows.firstIndex(where: { $0.kind == .entry && $0.url == browser.selectedURL }) {
            // Do not reselect a row inside AppKit's own selection callback:
            // that clears clickedRow before the single-click action arrives.
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            if pendingReveal == browser.selectedURL {
                table.scrollRowToVisible(index); pendingReveal = nil
            }
        } else if table.selectedRow != -1 { table.deselectAll(nil) }
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = FolderCell(); let row = rows[row]
        let title: String, icon: String
        switch row.kind {
        case .entry:
            title = row.entry?.name ?? ""; icon = row.entry?.isDirectory == true ? "folder" : "doc.text"
        case .more(let count): title = "Show \(count) more"; icon = "ellipsis"
        case .loading: title = "Loading…"; icon = "hourglass"
        case .message(let message): title = message; icon = "info.circle"
        }
        cell.title.stringValue = title; cell.title.font = style.font
        cell.title.textColor = row.entry?.isDimmed == true || row.entry == nil ? style.secondary : style.ink
        cell.title.toolTip = row.entry == nil ? title : row.url.path
        cell.icon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        cell.icon.contentTintColor = row.entry?.isDimmed == true ? style.secondary : style.ink
        cell.depth = row.depth
        if row.entry?.isDirectory == true { cell.chevron.image = NSImage(systemSymbolName: browser.expanded.contains(row.url) ? "chevron.down" : "chevron.right", accessibilityDescription: nil) }
        cell.chevron.contentTintColor = style.secondary
        let actionable: Bool
        if case .more = row.kind { actionable = true } else { actionable = row.entry != nil }
        cell.setAccessibilityElement(true); cell.setAccessibilityRole(actionable ? .button : .staticText)
        cell.setAccessibilityLabel(title + (row.entry?.isDirectory == true ? (browser.expanded.contains(row.url) ? ", folder, expanded" : ", folder, collapsed") : ""))
        cell.setAccessibilityHelp(row.url.path)
        cell.press = actionable ? { [weak self] in self?.activate(row) } : nil
        return cell
    }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FolderRow(); view.fill = style.selection
        return view
    }
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, rows.indices.contains(table.selectedRow), rows[table.selectedRow].kind == .entry else { return }
        browser.select(rows[table.selectedRow].url)
    }
    fileprivate func press(row: Int) {
        guard rows.indices.contains(row) else { return }
        activate(rows[row])
    }
    private func activate(_ row: FolderBrowser.Row) {
        if let entry = row.entry { browser.activate(entry) }
        else if case .more = row.kind { browser.showMore(in: row.url) }
    }
    /// Returns whether the tree consumed this navigation key. Public so
    /// hosts can test the actual keyboard path without posting global input.
    @discardableResult public func navigate(keyCode: UInt16) -> Bool {
        guard rows.indices.contains(table.selectedRow) else { return false }
        let row = rows[table.selectedRow]
        switch keyCode {
        case 36, 76: activate(row)
        case 124:
            guard row.entry?.isDirectory == true else { return true }
            if browser.expanded.contains(row.url), rows.indices.contains(table.selectedRow + 1) {
                table.selectRowIndexes(IndexSet(integer: table.selectedRow + 1), byExtendingSelection: false)
            } else { browser.expand(row.url) }
        case 123:
            if row.entry?.isDirectory == true, browser.expanded.contains(row.url) { browser.collapse(row.url) }
            else {
                let parent = FileBreadcrumb.normalized(row.url.deletingLastPathComponent())
                if rows.contains(where: { $0.kind == .entry && $0.url == parent }) { browser.select(parent) }
            }
        default: return false
        }
        return true
    }
}

@MainActor private final class FolderTable: NSTableView {
    weak var owner: FolderTreeView?
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { super.mouseDown(with: event); return }
        // A viewer row opens on a single press. Capture its identity before
        // selection callbacks reload rows or another tab takes the content.
        window?.makeFirstResponder(self)
        owner?.press(row: index)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if owner?.navigate(keyCode: event.keyCode) != true { super.keyDown(with: event) }
    }
}
@MainActor private final class FolderRow: NSTableRowView {
    var fill: NSColor = .selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) { fill.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill() }
    override func drawBackground(in dirtyRect: NSRect) { if isSelected { drawSelection(in: dirtyRect) } }
}
@MainActor private final class FolderCell: NSView {
    let title = NSTextField(labelWithString: ""), icon = NSImageView(), chevron = NSImageView()
    var depth = 0
    var press: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingMiddle
        for view in [title, icon, chevron] { addSubview(view); view.setAccessibilityElement(false) }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // Keep a usable name even in a deep tree in a narrow pane.
        let indent = min(CGFloat(depth) * 14, max(0, bounds.width - 110))
        chevron.frame = NSRect(x: 8 + indent, y: 9, width: 8, height: 8)
        icon.frame = NSRect(x: 22 + indent, y: 6, width: 14, height: 14)
        title.frame = NSRect(x: 42 + indent, y: 4, width: max(0, bounds.width - 48 - indent), height: 19)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return press != nil }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}
