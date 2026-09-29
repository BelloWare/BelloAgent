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
    /// A summary request's heading: its first row, open, with its instruction.
    var summary: InspectorSummaryHeading? = nil

    /// Nothing yet: the outline waits, mounted, for its document.
    static let empty = InspectorOutlineContent(key: "", sections: [], items: [], shared: nil, marksNew: false, openLast: 0)

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.shared == b.shared && a.marksNew == b.marksNew && a.openLast == b.openLast
            && a.items.count == b.items.count && a.sections.count == b.sections.count && a.summary == b.summary
    }
}

/// What the reader asked to read whole.
enum InspectorOutlineTarget: Equatable {
    case item(Int)
    case section(RequestDocument.Section.Kind)
    /// A summary request's instruction.
    case instruction
}

/// Reads one item's or section's whole text on the capture worker.
typealias InspectorWholeText = @Sendable () throws -> String

/// A request's conversation, or a response's items, as a native outline:
/// fixed-height rows built only for what is scrolled into view, and each
/// item's prepared preview as its child lines. "Show all" opens the whole
/// text in place of the preview, laid out off the main thread
/// (`InspectorExpansion`) and selectable, and "Show less" folds it back.
/// Nothing here parses or formats: every string arrives ready in the document.
struct InspectorItemsOutline: NSViewRepresentable {
    let content: InspectorOutlineContent
    /// How to read a target's whole text; nil when it has none to read.
    let wholeText: (InspectorOutlineTarget) -> InspectorWholeText?

    func makeCoordinator() -> Coordinator { Coordinator(wholeText: wholeText) }

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
        context.coordinator.wholeText = wholeText
        context.coordinator.schedule(content)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.closeAll()
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        outline.delegate = nil; outline.dataSource = nil; outline.target = nil
    }

    // MARK: - Rows

    @MainActor final class Node {
        enum Kind {
            /// A summary request: what it summarizes, its instruction under it.
            case summary(InspectorSummaryHeading)
            case section(RequestDocument.Section)
            case entry(RequestDocument.Entry, mono: Bool)
            case earlier(count: Int, characters: Int)
            /// A page of a long list of items, `range` of the content's items.
            case group(Range<Int>, characters: Int, new: Bool)
            case item(RequestDocument.Item, new: Bool)
            case line(String, mono: Bool)
            /// "Show all": the whole text in place of the preview.
            case more(InspectorOutlineTarget, String)
            /// The whole text, in place.
            case text(InspectorOutlineTarget)
            /// A text longer than a step: how much is shown, and the next step.
            case reveal(InspectorOutlineTarget)
            /// "Show less": back to the preview.
            case less(InspectorOutlineTarget)
        }
        let kind: Kind
        let path: String
        var built: [Node]?
        init(_ kind: Kind, path: String) { self.kind = kind; self.path = path }
        var expandable: Bool {
            switch kind {
            case .summary, .section, .earlier, .group: return true
            case .item(let item, _): return !item.lines.isEmpty || item.truncated
            default: return false
            }
        }
        /// The row's height; the whole text's is its layout's.
        var height: CGFloat {
            switch kind {
            case .summary, .section, .earlier, .group, .item: return 32
            case .entry, .more, .reveal, .less: return 22
            case .line, .text: return 18
            }
        }
        var isLink: Bool {
            switch kind {
            case .more, .reveal, .less: return true
            default: return false
            }
        }
        var isText: Bool { if case .text = kind { return true } else { return false } }
        /// The item or section this row reads whole, when it is one.
        var target: InspectorOutlineTarget? {
            switch kind {
            case .item(let item, _): return .item(item.id)
            case .section(let section): return .section(section.id)
            case .summary: return .instruction
            default: return nil
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        /// A list longer than this is shown a page at a time: an outline asks
        /// about every one of its top rows when it loads, and a request of
        /// thousands of items would keep the main thread for as long.
        static let pagingThreshold = 300
        static let pageSize = 200
        var wholeText: (InspectorOutlineTarget) -> InspectorWholeText?
        weak var outline: NSOutlineView?
        private(set) var content: InspectorOutlineContent?
        private var pending: InspectorOutlineContent?
        private var roots: [Node] = []
        /// Every item and section row built, by path: an expansion finds its
        /// row through these when its text lands.
        private var owners: [String: Node] = [:]
        /// The texts shown whole, by their item's or section's path.
        private(set) var expansions: [String: InspectorExpansion] = [:]
        /// A "Show all" pressed from the keyboard: its "Show less" is selected
        /// once the text is in place.
        private var keyboardPath: String?
        /// Test seam: how many row heights the outline has asked for.
        private(set) var heightQueries = 0
        init(wholeText: @escaping (InspectorOutlineTarget) -> InspectorWholeText?) { self.wholeText = wholeText }

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
        /// open, and the texts shown whole, over to a newer grouping of the
        /// same body.
        func show(_ next: InspectorOutlineContent) {
            guard let outline else { content = next; return }
            let sameBody = content?.key == next.key
            let regrouped = content?.shared != next.shared || content?.marksNew != next.marksNew
            let carried: Set<String> = sameBody ? Set((0..<outline.numberOfRows).compactMap { row in
                (outline.item(atRow: row) as? Node).flatMap { outline.isItemExpanded($0) ? $0.path : nil }
            }) : []
            if !sameBody { closeAll() }
            content = next
            owners = [:]
            var roots = next.summary.map { [owner(.summary($0), path: Self.path(of: .instruction))] } ?? []
            roots += next.sections.map { owner(.section($0), path: "section:" + $0.id.rawValue) }
            let shared = min(next.shared ?? 0, next.items.count)
            if shared > 0 {
                let earlier = next.items[..<shared]
                roots.append(Node(.earlier(count: earlier.count, characters: earlier.reduce(0) { $0 + $1.characters }), path: "earlier"))
            }
            roots += nodes(for: shared..<next.items.count, new: next.marksNew, prefix: "items")
            self.roots = roots
            outline.reloadData()
            if sameBody, !carried.isEmpty { expand(matching: carried, in: roots, outline: outline) }
            // A summary request's instruction is the first thing to read.
            if !sameBody, let first = roots.first, case .summary = first.kind { outline.expandItem(first) }
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

        /// An item or section row, remembered by its path.
        private func owner(_ kind: Node.Kind, path: String) -> Node {
            let node = Node(kind, path: path)
            owners[path] = node
            return node
        }

        func children(of node: Node) -> [Node] {
            if let built = node.built { return built }
            var result: [Node] = []
            switch node.kind {
            case .summary(let heading):
                if let expansion = shownExpansion(node.path) {
                    result = whole(node, target: .instruction, expansion)
                } else {
                    result = heading.info.lines.enumerated().map { Node(.line($0.element, mono: true), path: node.path + ":\($0.offset)") }
                    result.append(Node(.more(.instruction, "Show the whole instruction"), path: node.path + ":more"))
                }
            case .section(let section):
                if let expansion = shownExpansion(node.path) {
                    result = whole(node, target: .section(section.id), expansion)
                } else if section.id == .system {
                    result = section.lines.enumerated().map { Node(.line($0.element, mono: false), path: node.path + ":\($0.offset)") }
                    result.append(Node(.more(.section(.system), "Show the whole system prompt"), path: node.path + ":more"))
                } else {
                    result = section.entries.map { Node(.entry($0, mono: section.id == .settings), path: node.path + ":\($0.id)") }
                    result.append(Node(.more(.section(section.id), section.id == .tools ? "Show every tool's schema" : "Show the settings as JSON"), path: node.path + ":more"))
                }
            case .earlier:
                result = nodes(for: 0..<min(content?.shared ?? 0, content?.items.count ?? 0), new: false, prefix: "earlier")
            case .group(let range, _, let new):
                result = (content?.items[range] ?? []).map { owner(.item($0, new: new), path: "item:\($0.id)") }
            case .item(let item, _):
                if let expansion = shownExpansion(node.path) {
                    result = whole(node, target: .item(item.id), expansion)
                } else {
                    result = item.lines.enumerated().map { Node(.line($0.element, mono: item.monospaced), path: node.path + ":\($0.offset)") }
                    if item.truncated || item.lines.count >= RequestDocument.lineLimit {
                        let label = "Show all " + TranscriptActivity.grouped(Double(item.characters)) + " characters"
                        result.append(Node(.more(.item(item.id), label), path: node.path + ":more"))
                    }
                }
            default: break
            }
            node.built = result
            return result
        }

        /// A text shown whole: the text, how much of it is shown when not all
        /// of it, and "Show less".
        private func whole(_ node: Node, target: InspectorOutlineTarget, _ expansion: InspectorExpansion) -> [Node] {
            var rows = [Node(.text(target), path: node.path + ":text")]
            if expansion.capped { rows.append(Node(.reveal(target), path: node.path + ":reveal")) }
            rows.append(Node(.less(target), path: node.path + ":less"))
            return rows
        }

        /// The items in `range` as rows, or as pages of rows when there are many.
        private func nodes(for range: Range<Int>, new: Bool, prefix: String) -> [Node] {
            guard let items = content?.items, !range.isEmpty else { return [] }
            if range.count <= Self.pagingThreshold { return items[range].map { owner(.item($0, new: new), path: "item:\($0.id)") } }
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
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            heightQueries &+= 1
            guard let node = item as? Node else { return 18 }
            if case .text(let target) = node.kind {
                return (expansions[Self.path(of: target)]?.layout?.height ?? InspectorTextStyle.lineHeight) + InspectorFullTextCell.bottom
            }
            return node.height
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            // The whole text's row draws nothing: it can be taller than any
            // layer, and its text view draws what shows.
            if (item as? Node)?.isText == true {
                let identifier = NSUserInterfaceItemIdentifier("inspector-text-row")
                let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? InspectorTextRowView ?? InspectorTextRowView()
                row.identifier = identifier
                return row
            }
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
            case .text(let target):
                let cell = outlineView.makeView(withIdentifier: InspectorFullTextCell.identifier, owner: self) as? InspectorFullTextCell ?? InspectorFullTextCell()
                cell.show(expansions[Self.path(of: target)])
                return cell
            default:
                let cell = outlineView.makeView(withIdentifier: InspectorRowCell.identifier, owner: self) as? InspectorRowCell ?? InspectorRowCell()
                cell.configure(node, expanded: outlineView.isItemExpanded(node), link: link(for: node))
                cell.press = node.isLink ? { [weak self, weak node, weak outlineView] in
                    guard let self, let node, let outlineView else { return }
                    self.activate(node, in: outlineView)
                } : nil
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

        /// A click opens or closes a row, or shows a text whole or folds it.
        @objc func clicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? Node else { return }
            activate(node, in: sender)
        }
        func activate(_ node: Node, in outline: NSOutlineView, keyboard: Bool = false) {
            switch node.kind {
            case .more:
                if let owner = owner(of: node, in: outline) { showWhole(owner, keyboard: keyboard) }
            case .less:
                if let owner = owner(of: node, in: outline) { showLess(owner, from: node, keyboard: keyboard) }
            case .reveal:
                guard let owner = owner(of: node, in: outline), let expansion = expansions[owner.path] else { return }
                expansion.reveal()
                refreshLinks(of: owner)
            case .text(let target):
                // Return on the text gives it the keyboard: arrows and ⇧ select, ⌘C copies.
                if let view = expansions[Self.path(of: target)]?.textView, view.window === outline.window { outline.window?.makeFirstResponder(view) }
            default:
                guard node.expandable else { return }
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            }
        }
        func title(for target: InspectorOutlineTarget) -> String {
            switch target {
            case .item(let index): return content?.items.first { $0.id == index }.map { "\(index + 1). " + $0.title } ?? "Item"
            case .section(let kind): return content?.sections.first { $0.id == kind }?.title ?? "Section"
            case .instruction: return "Summary instruction"
            }
        }

        // MARK: Whole texts

        static func path(of target: InspectorOutlineTarget) -> String {
            switch target {
            case .item(let id): return "item:\(id)"
            case .section(let kind): return "section:" + kind.rawValue
            case .instruction: return "summary"
            }
        }

        /// The item or section a row belongs to: itself, or its parent.
        func owner(of node: Node, in outline: NSOutlineView) -> Node? {
            if node.target != nil { return node }
            return outline.parent(forItem: node) as? Node
        }

        /// The expansion of an item or section whose text is in place.
        private func shownExpansion(_ path: String) -> InspectorExpansion? {
            guard let expansion = expansions[path], expansion.layout != nil else { return nil }
            return expansion
        }

        /// The expansion of a target, for tests and the pages.
        func expansion(for target: InspectorOutlineTarget) -> InspectorExpansion? { expansions[Self.path(of: target)] }

        /// "Show all": the item's or section's whole text, read and laid out
        /// off the main thread, then put in place of its preview. The rows
        /// above stay where they are, and so does the scroll position.
        func showWhole(_ owner: Node, keyboard: Bool = false) {
            guard let outline, let target = owner.target else { return }
            if let existing = expansions[owner.path] {
                // Reading or shown already; a read that failed is tried again.
                guard case .failed = existing.phase, existing.layout == nil else { return }
                existing.cancel(); expansions[owner.path] = nil
            }
            guard let read = wholeText(target) else { return }
            let path = owner.path
            let expansion = InspectorExpansion(title: title(for: target), style: InspectorTextStyle(monospaced: monospaced(owner)))
            expansion.changed = { [weak self] previous in self?.expansionChanged(path, previous: previous) }
            expansion.showLess = { [weak self] in self?.showLess(path: path) }
            expansions[path] = expansion
            keyboardPath = keyboard ? path : nil
            if owner.expandable, !outline.isItemExpanded(owner) { outline.expandItem(owner) }
            refreshLinks(of: owner)
            expansion.load(render: read)
            expansion.offer(width: textWidth(under: owner, in: outline))
        }
        /// "Show all" for a target, as the row's link or its menu would.
        func showWhole(_ target: InspectorOutlineTarget) {
            if let owner = owners[Self.path(of: target)] { showWhole(owner) }
        }

        /// "Show less": the preview again. An item whose top has scrolled
        /// away keeps its end where the reader clicked, so the reader stays on
        /// it; otherwise nothing moves but the rows below.
        func showLess(_ owner: Node, from anchor: Node? = nil, keyboard: Bool = false) {
            guard let outline, let expansion = expansions.removeValue(forKey: owner.path) else { return }
            if keyboardPath == owner.path { keyboardPath = nil }
            var offset: CGFloat?
            if let clip = outline.enclosingScrollView?.contentView {
                let header = outline.row(forItem: owner)
                if header >= 0, outline.rect(ofRow: header).minY < clip.bounds.minY {
                    let row = anchor.map { outline.row(forItem: $0) } ?? -1
                    let place = row >= 0 ? outline.rect(ofRow: row).minY - clip.bounds.minY : 0
                    offset = min(max(0, place), max(0, clip.bounds.height - 22))
                }
            }
            expansion.cancel()
            rebuild(owner, in: outline)
            if let offset, let end = owner.built?.last {
                let row = outline.row(forItem: end)
                if row >= 0 { scroll(outline, to: outline.rect(ofRow: row).minY - offset) }
            }
            if keyboard { select(owner, link: { if case .more = $0.kind { return true } else { return false } }, in: outline) }
        }
        func showLess(_ target: InspectorOutlineTarget) {
            if let owner = owners[Self.path(of: target)] { showLess(owner) }
        }
        private func showLess(path: String) {
            if let owner = owners[path] { showLess(owner) }
        }

        /// Every expansion stopped, its text view let go: a new body, or the
        /// outline leaving the page.
        func closeAll() {
            for expansion in expansions.values { expansion.cancel() }
            expansions = [:]
            keyboardPath = nil
        }

        private func monospaced(_ owner: Node) -> Bool {
            switch owner.kind {
            case .item(let item, _): return item.monospaced
            case .section(let section): return section.id != .system
            case .summary: return true
            default: return false
            }
        }

        /// The width a child row of `owner` has for its text.
        private func textWidth(under owner: Node, in outline: NSOutlineView) -> CGFloat {
            let row = outline.row(forItem: owner)
            let cell = row >= 0 ? outline.frameOfCell(atColumn: 0, row: row) : outline.bounds
            return cell.width - outline.indentationPerLevel - InspectorFullTextCell.leading - InspectorFullTextCell.trailing
        }

        /// A text was read, laid out, laid out again, or could not be read.
        private func expansionChanged(_ path: String, previous: InspectorLaidOutText?) {
            guard let outline, let expansion = expansions[path], let owner = owners[path] else { return }
            guard expansion.layout != nil else { refreshLinks(of: owner); return }
            let built = owner.built ?? []
            let placed = built.contains(where: { $0.isText })
            let revealing = built.contains { if case .reveal = $0.kind { return true } else { return false } }
            // The line at the top of the view stays at the top when the text
            // under it is laid out again.
            let anchor = previous.flatMap { readingAnchor(owner, previous: $0, in: outline) }
            if !placed || revealing != expansion.capped {
                rebuild(owner, in: outline)
            } else if let row = built.first(where: { $0.isText }).map({ outline.row(forItem: $0) }), row >= 0 {
                if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? InspectorFullTextCell { cell.show(expansion) }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }
            }
            if let anchor { restore(anchor, owner: owner, in: outline) }
            refreshLinks(of: owner)
            if keyboardPath == path, !placed {
                keyboardPath = nil
                select(owner, link: { if case .less = $0.kind { return true } else { return false } }, in: outline)
            }
        }

        /// A new set of rows for an item or section, the scroll position kept.
        private func rebuild(_ owner: Node, in outline: NSOutlineView) {
            owner.built = nil
            guard outline.row(forItem: owner) >= 0 else { return }
            let origin = outline.enclosingScrollView?.contentView.bounds.origin
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                outline.reloadItem(owner, reloadChildren: true)
            }
            if let origin, let clip = outline.enclosingScrollView?.contentView, clip.bounds.origin != origin { scroll(outline, to: origin.y) }
        }

        /// The character at the top of the view, when the top of the view is
        /// inside the text, and how far into its line.
        private func readingAnchor(_ owner: Node, previous: InspectorLaidOutText, in outline: NSOutlineView) -> (character: Int, offset: CGFloat)? {
            guard let node = owner.built?.first(where: { $0.isText }), let clip = outline.enclosingScrollView?.contentView, previous.characters > 0 else { return nil }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return nil }
            let top = clip.bounds.minY - outline.rect(ofRow: row).minY
            guard top > 0, top < previous.height else { return nil }
            let glyph = previous.manager.glyphIndex(for: NSPoint(x: 0, y: top), in: previous.container)
            let line = previous.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (previous.manager.characterIndexForGlyph(at: glyph), top - line.minY)
        }
        private func restore(_ anchor: (character: Int, offset: CGFloat), owner: Node, in outline: NSOutlineView) {
            guard let layout = expansions[owner.path]?.layout, layout.characters > 0, let node = owner.built?.first(where: { $0.isText }) else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            let glyph = layout.manager.glyphIndexForCharacter(at: min(anchor.character, layout.characters - 1))
            let line = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            scroll(outline, to: outline.rect(ofRow: row).minY + line.minY + min(anchor.offset, line.height))
        }

        private func scroll(_ outline: NSOutlineView, to y: CGFloat) {
            guard let scroll = outline.enclosingScrollView else { return }
            let clip = scroll.contentView
            let end = max(0, outline.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), end)))
            scroll.reflectScrolledClipView(clip)
        }

        private func select(_ owner: Node, link matches: (Node) -> Bool, in outline: NSOutlineView) {
            guard let node = owner.built?.first(where: matches) else { return }
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }

        /// The owner's link rows drawn again: reading, laying out, failed.
        private func refreshLinks(of owner: Node) {
            guard let outline, let built = owner.built else { return }
            let rows = built.filter({ $0.isLink }).map { outline.row(forItem: $0) }.filter { $0 >= 0 }
            guard !rows.isEmpty else { return }
            outline.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: IndexSet(integer: 0))
        }

        /// What a link row says now.
        func link(for node: Node) -> InspectorLink? {
            func count(_ value: Int) -> String { MetricFormat.tokens(Double(value)) }
            switch node.kind {
            case .more(let target, let label):
                guard let expansion = expansions[Self.path(of: target)] else { return InspectorLink(symbol: "arrow.up.left.and.arrow.down.right", title: label) }
                if case .failed(let message) = expansion.phase {
                    return InspectorLink(symbol: "exclamationmark.circle", title: "The whole text could not be read · Try again", detail: message, tone: .warning)
                }
                return InspectorLink(symbol: "hourglass", title: expansion.loaded ? "Laying out the whole text…" : "Reading the whole text…", tone: .quiet)
            case .reveal(let target):
                guard let expansion = expansions[Self.path(of: target)] else { return nil }
                if expansion.laying { return InspectorLink(symbol: "hourglass", title: "Laying out \(count(expansion.nextStep)) more characters…", tone: .quiet) }
                return InspectorLink(symbol: "arrow.down.to.line", title: "Show \(count(expansion.nextStep)) more characters",
                                     detail: "Showing the first \(count(expansion.shown)) of \(count(expansion.length)) characters")
            case .less(let target):
                let length = expansions[Self.path(of: target)]?.length ?? 0
                return InspectorLink(symbol: "arrow.down.right.and.arrow.up.left", title: "Show less", size: length > 0 ? RequestDocument.charactersLabel(length) : "")
            default: return nil
            }
        }

        // MARK: Menu and copy

        /// The row's words, for Copy on a right click: an item or section
        /// shown whole copies all of it.
        func copyText(_ node: Node) -> String {
            switch node.kind {
            case .line(let text, _): return text
            case .entry(let entry, _): return entry.name + ": " + entry.value
            case .item(let item, _): return loadedText(node.path) ?? item.preview
            case .section(let section): return loadedText(node.path) ?? section.lines.joined(separator: "\n")
            case .summary(let heading): return loadedText(node.path) ?? heading.info.instruction
            case .earlier(let count, _): return "Earlier context · \(count) items"
            case .group(let range, _, _): return "Items \(range.lowerBound + 1)–\(range.upperBound)"
            case .more(_, let label): return label
            case .text(let target), .reveal(let target), .less(let target): return loadedText(Self.path(of: target)) ?? ""
            }
        }
        private func loadedText(_ path: String) -> String? {
            guard let expansion = expansions[path], expansion.loaded else { return nil }
            return expansion.text
        }

        /// Copy, and Show All or Show Less for the item or section the row
        /// belongs to. Built when it opens.
        func menuEntries(for node: Node) -> [PiMenuEntry] {
            var entries: [PiMenuEntry] = [.button("Copy", identifier: "inspector-copy") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.copyText(node), forType: .string)
            }]
            guard let outline, let owner = owner(of: node, in: outline), let target = owner.target else { return entries }
            if expansions[owner.path] != nil {
                entries.append(.button("Show Less", identifier: "inspector-show-less") { [weak self] in self?.showLess(owner) })
            } else if hasText(owner), wholeText(target) != nil {
                entries.append(.button("Show All", identifier: "inspector-show-all") { [weak self] in self?.showWhole(owner) })
            }
            return entries
        }
        func menu(for node: Node) -> NSMenu { PiMenus.menu(menuEntries(for: node)) }
        private func hasText(_ owner: Node) -> Bool {
            if case .item(let item, _) = owner.kind { return item.characters > 0 }
            return true
        }
    }
}

/// What a link row says: "Show all 12,431 characters", "Show less", the next
/// step of a long text, or why the text could not be read.
struct InspectorLink: Equatable {
    enum Tone { case accent, quiet, warning }
    var symbol: String
    var title: String
    var detail: String = ""
    var size: String = ""
    var tone: Tone = .accent
}
