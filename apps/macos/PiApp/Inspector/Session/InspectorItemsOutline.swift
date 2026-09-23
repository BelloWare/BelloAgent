import AppKit
import SwiftUI

/// What the outline shows: a document's sections and items, prepared off the
/// main actor, and how the delta groups them.
struct InspectorOutlineContent: Equatable {
    /// The document's identity; a new key is a different body.
    var key: String
    var sections: [RequestDocument.Section]
    var items: [RequestDocument.Item]
    /// Items before this index are the unchanged "Earlier context", folded
    /// into one row; the rest are new. Nil when no delta groups them.
    var shared: Int?
    /// Mark items at or after `shared` NEW.
    var marksNew: Bool
    /// How many of the last items open by themselves.
    var openLast: Int

    /// Nothing yet: the outline waits, mounted, for its document.
    static let empty = InspectorOutlineContent(key: "", sections: [], items: [], shared: nil, marksNew: false, openLast: 0)

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.shared == b.shared && a.marksNew == b.marksNew && a.openLast == b.openLast
            && a.items.count == b.items.count && a.sections.count == b.sections.count
    }
}

/// What the reader asked to read whole.
enum InspectorOutlineTarget: Equatable {
    case item(Int)
    case section(RequestDocument.Section.Kind)
}

/// A request's conversation, or a response's items, as a native outline:
/// fixed-height rows built only for what is scrolled into view, each item's
/// prepared preview as its child lines, and the whole text one click away in
/// the pane under it. Nothing here parses or formats: every string arrives
/// ready in the document.
struct InspectorItemsOutline: NSViewRepresentable {
    let content: InspectorOutlineContent
    let open: (InspectorOutlineTarget, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let outline = InspectorOutlineView()
        outline.headerView = nil; outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 16
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.action = #selector(Coordinator.clicked(_:))
        outline.coordinator = context.coordinator
        outline.setAccessibilityLabel("Request items")
        outline.setAccessibilityIdentifier("inspector-items-outline")
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.show(content)
        return scroll
    }

    /// A new document is shown on the turn after SwiftUI's update: the
    /// outline's reload and its first rows are a step of their own, never
    /// inside the transaction that laid the page out.
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.open = open
        context.coordinator.schedule(content)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        outline.delegate = nil; outline.dataSource = nil; outline.target = nil
    }

    // MARK: - Rows

    @MainActor final class Node {
        enum Kind {
            case section(RequestDocument.Section)
            case entry(RequestDocument.Entry, mono: Bool)
            case earlier(count: Int, characters: Int)
            /// A page of a long list of items, `range` of the content's items.
            case group(Range<Int>, characters: Int, new: Bool)
            case item(RequestDocument.Item, new: Bool)
            case line(String, mono: Bool)
            case more(InspectorOutlineTarget, String)
        }
        let kind: Kind
        let path: String
        var built: [Node]?
        init(_ kind: Kind, path: String) { self.kind = kind; self.path = path }
        var expandable: Bool {
            switch kind {
            case .section, .earlier, .group: return true
            case .item(let item, _): return !item.lines.isEmpty || item.truncated
            default: return false
            }
        }
        var height: CGFloat {
            switch kind {
            case .section, .earlier, .group, .item: return 32
            case .entry, .more: return 22
            case .line: return 18
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        /// A list longer than this is shown a page at a time: an outline asks
        /// about every one of its top rows when it loads, and a request of
        /// thousands of items would keep the main thread for as long.
        static let pagingThreshold = 300
        static let pageSize = 200
        var open: (InspectorOutlineTarget, String) -> Void
        weak var outline: NSOutlineView?
        private(set) var content: InspectorOutlineContent?
        private var pending: InspectorOutlineContent?
        private var roots: [Node] = []
        init(open: @escaping (InspectorOutlineTarget, String) -> Void) { self.open = open }

        func schedule(_ next: InspectorOutlineContent) {
            guard next != (pending ?? content) else { return }
            let waiting = pending != nil
            pending = next
            guard !waiting else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let next = self.pending else { return }
                self.pending = nil
                if next != self.content { self.show(next) }
            }
        }

        /// Builds the top rows for a document, carrying what the reader had
        /// open over to a newer grouping of the same body.
        func show(_ next: InspectorOutlineContent) {
            guard let outline else { content = next; return }
            let sameBody = content?.key == next.key
            let regrouped = content?.shared != next.shared || content?.marksNew != next.marksNew
            let carried: Set<String> = sameBody ? Set((0..<outline.numberOfRows).compactMap { row in
                (outline.item(atRow: row) as? Node).flatMap { outline.isItemExpanded($0) ? $0.path : nil }
            }) : []
            content = next
            var roots = next.sections.map { Node(.section($0), path: "section:" + $0.id.rawValue) }
            let shared = min(next.shared ?? 0, next.items.count)
            if shared > 0 {
                let earlier = next.items[..<shared]
                roots.append(Node(.earlier(count: earlier.count, characters: earlier.reduce(0) { $0 + $1.characters }), path: "earlier"))
            }
            roots += nodes(for: shared..<next.items.count, new: next.marksNew, prefix: "items")
            self.roots = roots
            outline.reloadData()
            if sameBody, !carried.isEmpty { expand(matching: carried, in: roots, outline: outline) }
            if !sameBody || regrouped {
                // New items open by themselves, the last ones first, the last
                // page of a long list with them.
                var remaining = max(0, next.openLast)
                for node in roots.reversed() where remaining > 0 {
                    switch node.kind {
                    case .item:
                        guard node.expandable else { continue }
                        if !outline.isItemExpanded(node) { outline.expandItem(node) }
                        remaining -= 1
                    case .group:
                        if !outline.isItemExpanded(node) { outline.expandItem(node) }
                        for child in children(of: node).reversed() where remaining > 0 && child.expandable {
                            if !outline.isItemExpanded(child) { outline.expandItem(child) }
                            remaining -= 1
                        }
                    default: remaining = 0
                    }
                }
            }
        }

        private func expand(matching paths: Set<String>, in nodes: [Node], outline: NSOutlineView) {
            for node in nodes where paths.contains(node.path) && node.expandable {
                outline.expandItem(node)
                expand(matching: paths, in: children(of: node), outline: outline)
            }
        }

        func children(of node: Node) -> [Node] {
            if let built = node.built { return built }
            var result: [Node] = []
            switch node.kind {
            case .section(let section):
                if section.id == .system {
                    result = section.lines.enumerated().map { Node(.line($0.element, mono: false), path: node.path + ":\($0.offset)") }
                    result.append(Node(.more(.section(.system), "Show the whole system prompt"), path: node.path + ":more"))
                } else {
                    result = section.entries.map { Node(.entry($0, mono: section.id == .settings), path: node.path + ":\($0.id)") }
                    result.append(Node(.more(.section(section.id), section.id == .tools ? "Show every tool's schema" : "Show the settings as JSON"), path: node.path + ":more"))
                }
            case .earlier:
                result = nodes(for: 0..<min(content?.shared ?? 0, content?.items.count ?? 0), new: false, prefix: "earlier")
            case .group(let range, _, let new):
                result = (content?.items[range] ?? []).map { Node(.item($0, new: new), path: "item:\($0.id)") }
            case .item(let item, _):
                result = item.lines.enumerated().map { Node(.line($0.element, mono: item.monospaced), path: node.path + ":\($0.offset)") }
                if item.truncated || item.lines.count >= RequestDocument.lineLimit {
                    let label = "Show all " + TranscriptActivity.grouped(Double(item.characters)) + " characters"
                    result.append(Node(.more(.item(item.id), label), path: node.path + ":more"))
                }
            default: break
            }
            node.built = result
            return result
        }

        /// The items in `range` as rows, or as pages of rows when there are many.
        private func nodes(for range: Range<Int>, new: Bool, prefix: String) -> [Node] {
            guard let items = content?.items, !range.isEmpty else { return [] }
            if range.count <= Self.pagingThreshold { return items[range].map { Node(.item($0, new: new), path: "item:\($0.id)") } }
            return stride(from: range.lowerBound, to: range.upperBound, by: Self.pageSize).map { start in
                let page = start..<min(start + Self.pageSize, range.upperBound)
                return Node(.group(page, characters: items[page].reduce(0) { $0 + $1.characters }, new: new), path: prefix + ":\(start)")
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return children(of: node).count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return children(of: node)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.expandable ?? false }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? Node)?.height ?? 18 }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("inspector-row")
            let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? InspectorOutlineRowView ?? InspectorOutlineRowView()
            row.identifier = identifier
            row.hoverable = (item as? Node).map { if case .line = $0.kind { return false } else { return true } } ?? false
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            switch node.kind {
            case .line(let text, let mono):
                let cell = outlineView.makeView(withIdentifier: InspectorLineCell.identifier, owner: self) as? InspectorLineCell ?? InspectorLineCell()
                cell.configure(text: text, mono: mono)
                return cell
            default:
                let cell = outlineView.makeView(withIdentifier: InspectorRowCell.identifier, owner: self) as? InspectorRowCell ?? InspectorRowCell()
                cell.configure(node, expanded: outlineView.isItemExpanded(node))
                return cell
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { refreshChevron(notification) }
        func outlineViewItemDidCollapse(_ notification: Notification) { refreshChevron(notification) }
        private func refreshChevron(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView, let node = notification.userInfo?["NSObject"] as? Node else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? InspectorRowCell else { return }
            cell.setExpanded(outline.isItemExpanded(node))
        }

        /// A click opens or closes a row, or reads the whole text.
        @objc func clicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? Node else { return }
            activate(node, in: sender)
        }
        func activate(_ node: Node, in outline: NSOutlineView) {
            switch node.kind {
            case .more(let target, _): open(target, title(for: target))
            default:
                guard node.expandable else { return }
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            }
        }
        func title(for target: InspectorOutlineTarget) -> String {
            switch target {
            case .item(let index): return content?.items.first { $0.id == index }.map { "\(index + 1). " + $0.title } ?? "Item"
            case .section(let kind): return content?.sections.first { $0.id == kind }?.title ?? "Section"
            }
        }
        /// The row's words, for Copy on a right click.
        func copyText(_ node: Node) -> String {
            switch node.kind {
            case .line(let text, _): return text
            case .entry(let entry, _): return entry.name + ": " + entry.value
            case .item(let item, _): return item.preview
            case .section(let section): return section.lines.joined(separator: "\n")
            case .earlier(let count, _): return "Earlier context · \(count) items"
            case .group(let range, _, _): return "Items \(range.lowerBound + 1)–\(range.upperBound)"
            case .more(_, let label): return label
            }
        }
        func menu(for node: Node) -> NSMenu {
            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy", action: #selector(copyRow(_:)), keyEquivalent: "")
            copy.target = self; copy.representedObject = node
            menu.addItem(copy)
            let target: InspectorOutlineTarget? = {
                switch node.kind {
                case .item(let item, _): return .item(item.id)
                case .section(let section): return .section(section.id)
                case .more(let target, _): return target
                default: return nil
                }
            }()
            if let target {
                let full = NSMenuItem(title: "Show All", action: #selector(showAll(_:)), keyEquivalent: "")
                full.target = self; full.representedObject = Box(target)
                menu.addItem(full)
            }
            return menu
        }
        @objc private func copyRow(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyText(node), forType: .string)
        }
        @objc private func showAll(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? Box else { return }
            open(box.target, title(for: box.target))
        }
        final class Box: NSObject { let target: InspectorOutlineTarget; init(_ target: InspectorOutlineTarget) { self.target = target } }
    }
}

/// The outline without the system disclosure triangle: each row draws its own
/// chevron, and a right click builds its menu on the spot.
final class InspectorOutlineView: NSOutlineView {
    weak var coordinator: InspectorItemsOutline.Coordinator?
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let node = item(atRow: row) as? InspectorItemsOutline.Node, let coordinator else { return nil }
        return coordinator.menu(for: node)
    }
    override func keyDown(with event: NSEvent) {
        // Return and space open or close the row under the selection.
        if [36, 49].contains(event.keyCode), selectedRow >= 0, let node = item(atRow: selectedRow) as? InspectorItemsOutline.Node {
            coordinator?.activate(node, in: self); return
        }
        super.keyDown(with: event)
    }
}

/// A row's background: a soft rounded fill under the pointer.
final class InspectorOutlineRowView: NSTableRowView {
    var hoverable = true
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = hoverable }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func prepareForReuse() { super.prepareForReuse(); hovering = false }
    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.piFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// A heading row: a section, the earlier context, a page of items, an item or
/// a "Show all" link. It draws itself: no subviews and no constraints, so a
/// page of new rows costs the main thread almost nothing to lay out.
final class InspectorRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("inspector-row-cell")
    private var expandable = false
    private var expanded = false
    private var leadingInset: CGFloat = 6
    private var showsChevron = true
    private var symbol: String?
    private var tint: NSColor = .piInkTertiary
    private var title = ""
    private var titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var titleColor: NSColor = .piInk
    private var detail = ""
    private var detailFont = NSFont.systemFont(ofSize: 12)
    private var detailColor: NSColor = .piInkSecondary
    private var size = ""
    private var new = false
    /// The detail repeats the first line: an open row, whose lines follow, leaves it out.
    private var detailRepeatsLines = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // The cell draws its words, so it says them itself.
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded; needsDisplay = true
    }

    func configure(_ node: InspectorItemsOutline.Node, expanded: Bool) {
        expandable = node.expandable; self.expanded = expanded; detailRepeatsLines = false
        leadingInset = 6; showsChevron = true; new = false; symbol = nil; tint = .piInkTertiary
        title = ""; titleFont = .systemFont(ofSize: 13, weight: .medium); titleColor = .piInk
        detail = ""; detailFont = .systemFont(ofSize: 12); detailColor = .piInkSecondary; size = ""
        switch node.kind {
        case .section(let section):
            symbol = section.id == .system ? "text.alignleft" : section.id == .tools ? "hammer" : "slider.horizontal.3"
            title = section.title; titleColor = .piInkSecondary
            detail = section.summary; detailColor = .piInkTertiary
            size = RequestDocument.byteLabel(section.size)
            setAccessibilityLabel(section.title + ", " + section.summary)
        case .earlier(let count, let characters):
            symbol = "clock.arrow.circlepath"
            title = "Earlier context"; titleColor = .piInkSecondary
            detail = "\(count) item" + (count == 1 ? "" : "s") + " sent before, unchanged"; detailColor = .piInkTertiary
            size = RequestDocument.charactersLabel(characters)
            setAccessibilityLabel("Earlier context, \(count) items")
        case .group(let range, let characters, let isNew):
            symbol = "square.stack"
            title = "Items \(range.lowerBound + 1)–\(range.upperBound)"
            detail = "\(range.count) items"; detailColor = .piInkTertiary
            new = isNew
            size = RequestDocument.charactersLabel(characters)
            setAccessibilityLabel("Items \(range.lowerBound + 1) to \(range.upperBound)" + (isNew ? ", new" : ""))
        case .item(let item, let isNew):
            let (name, color) = Self.symbol(item.kind)
            symbol = name; tint = color
            if item.kind == .toolCall {
                title = item.title + "(" + (item.detail ?? "") + ")"
                titleFont = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
            } else {
                title = item.title
                detail = item.detail ?? Self.firstLine(item)
                detailRepeatsLines = item.detail == nil
            }
            new = isNew
            size = RequestDocument.charactersLabel(item.characters)
            setAccessibilityLabel(item.title + (isNew ? ", new" : "") + ", " + (item.detail ?? ""))
        case .entry(let entry, let mono):
            showsChevron = false; leadingInset = 30
            title = entry.name
            titleFont = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12.5, weight: .medium)
            titleColor = mono ? .piInkSecondary : .piInk
            detail = entry.value; detailColor = mono ? .piInk : .piInkSecondary
            detailFont = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            size = entry.detail ?? ""
            setAccessibilityLabel(entry.name + ": " + entry.value)
        case .more(_, let label):
            showsChevron = false; leadingInset = 26
            symbol = "arrow.up.left.and.arrow.down.right"; tint = .piAccent
            title = label; titleColor = .piAccent; titleFont = .systemFont(ofSize: 12, weight: .medium)
            setAccessibilityLabel(label)
        case .line:
            break
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x = leadingInset
        if showsChevron {
            if expandable { Self.drawSymbol(expanded ? "chevron.down" : "chevron.right", pointSize: 9, weight: .semibold, color: .piInkTertiary, center: NSPoint(x: x + 5, y: mid)) }
            x += 16
        }
        if let symbol { Self.drawSymbol(symbol, pointSize: 12, weight: .medium, color: tint, center: NSPoint(x: x + 9, y: mid)); x += 24 }
        var right = bounds.maxX - 12
        if !size.isEmpty {
            let width = Self.width(size, font: Self.sizeFont)
            Self.drawLine(size, font: Self.sizeFont, color: .piInkTertiary, in: NSRect(x: right - width, y: mid, width: width + 1, height: 0))
            right -= width + 12
        }
        guard right > x else { return }
        x += Self.drawLine(title, font: titleFont, color: titleColor, in: NSRect(x: x, y: mid, width: right - x, height: 0)) + 8
        if new, x + 36 < right {
            x = Self.drawBadge(at: NSPoint(x: x, y: mid)) + 8
        }
        if !detail.isEmpty, !(expanded && detailRepeatsLines), right - x > 24 {
            Self.drawLine(detail, font: detailFont, color: detailColor, in: NSRect(x: x, y: mid, width: right - x, height: 0))
        }
    }

    /// One line of text, vertically centred on `rect.minY`, cut with an
    /// ellipsis at `rect.width`: a Core Text line, much cheaper to make and
    /// draw than laying the string out through the text system. Returns the
    /// width drawn.
    @discardableResult
    static func drawLine(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) -> CGFloat {
        guard !text.isEmpty, rect.width > 4, let context = NSGraphicsContext.current?.cgContext else { return 0 }
        // A row shows a line at most: nothing past this many characters could fit.
        let string = text.utf16.count > 400 ? String(text.prefix(400)) : text
        let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        if width > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            if let cut = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) {
                line = cut; width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        context.saveGState()
        // The row is flipped; Core Text draws upright in an unflipped text space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: rect.minX, y: (rect.minY + (ascent - descent) / 2).rounded())
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
    /// A line's width, measured the way `drawLine` draws it.
    static func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = text.utf16.count > 400 ? String(text.prefix(400)) : text
        return ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font])), nil, nil, nil)))
    }

    /// Symbol images by name, size, weight, colour and appearance: a page of
    /// rows shares a handful, and looking one up is not free.
    @MainActor private static var symbols: [String: NSImage] = [:]
    static func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, center: NSPoint) {
        let appearance = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(ObjectIdentifier(color).hashValue)|\(appearance)"
        let image: NSImage
        if let cached = symbols[key] { image = cached }
        else {
            // The colour resolved now, for this appearance: the cached image never changes with it.
            var resolved = color
            NSAppearance.currentDrawing().performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [resolved]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            if symbols.count > 256 { symbols.removeAll() }
            symbols[key] = made; image = made
        }
        let size = image.size
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    static let badgeWidth = width("NEW", font: badgeFont) + 13

    /// The NEW mark: small bold letters in the accent on a soft accent capsule. Returns its right edge.
    static func drawBadge(at origin: NSPoint) -> CGFloat {
        let capsule = NSRect(x: origin.x, y: origin.y - 8, width: badgeWidth, height: 16)
        NSColor.piAccentSoft.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 8, yRadius: 8).fill()
        drawLine("NEW", font: badgeFont, color: .piAccent, in: NSRect(x: capsule.minX + 6.5, y: capsule.midY, width: badgeWidth, height: 0))
        return capsule.maxX
    }

    static func symbol(_ kind: RequestDocument.Item.Kind) -> (String, NSColor) {
        switch kind {
        case .user: return ("person.crop.circle", .piInfo)
        case .assistant: return ("sparkle", .piAccent)
        case .system, .developer: return ("text.alignleft", .piInkSecondary)
        case .toolCall: return ("arrow.right.circle", .piWarning)
        case .toolResult: return ("arrow.left.circle", .piSuccess)
        case .reasoning: return ("brain", .piPurple)
        case .image: return ("photo", .piInkSecondary)
        case .other: return ("curlybraces", .piInkTertiary)
        }
    }
    private static func firstLine(_ item: RequestDocument.Item) -> String {
        item.lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

/// One line of an item's text, drawn. Copy is on the row's right-click menu,
/// and the whole text, selectable, is one click away.
final class InspectorLineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("inspector-line-cell")
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let textFont = NSFont.systemFont(ofSize: 12.5)
    private var text = ""
    private var mono = false
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func configure(text: String, mono: Bool) {
        self.text = text; self.mono = mono
        setAccessibilityValue(text)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        InspectorRowCell.drawLine(text, font: mono ? Self.monoFont : Self.textFont, color: mono ? .piInkSecondary : .piInk,
                                  in: NSRect(x: 30, y: bounds.midY, width: bounds.width - 42, height: 0))
    }
}
