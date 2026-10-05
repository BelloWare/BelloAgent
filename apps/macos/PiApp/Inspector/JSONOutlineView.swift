import AppKit

// The captured body's JSON as a native outline: its nodes, the commands a
// reader gives it, and the AppKit outline view that shows them.

@MainActor final class JSONOutlineNode {
    private let baseKey: String
    /// The node's name in its parent, independent of whether an event frame
    /// has been decoded yet: a path of these finds the same node in a newer
    /// document of the same body.
    var pathKey: String { baseKey }
    let value: Any
    var prepared: CapturedEventContent?
    var key: String {
        guard let frame = value as? CapturedEventFrame else { return baseKey }
        return prepared.map { "\(frame.number) · " + frame.name($0) } ?? frame.initialLabel
    }
    func releasePreparation() { prepared = nil; children.removeAll() }
    let formattedDetail: String?
    private var children: [Int: JSONOutlineNode] = [:]
    private lazy var keys = (value as? [String: Any])?.keys.sorted() ?? []
    init(key: String, value: Any, formattedDetail: String? = nil) {
        self.baseKey = key; self.value = value; self.formattedDetail = formattedDetail
        if let frame = value as? CapturedEventFrame { prepared = frame.storage.cached(frame.number) }
    }
    var count: Int { (value as? CapturedEventFrame).map { prepared == nil ? 0 : $0.count } ?? (value as? [String: Any])?.count ?? (value as? [Any])?.count ?? 0 }
    var cachedChildren: Int { children.count }
    /// The child named `key`, without building every sibling of a long array.
    func childIndex(forPathKey key: String) -> Int? {
        if value is [String: Any] {
            // Keys are sorted; a binary search keeps a wide object cheap.
            var low = 0, high = keys.count
            while low < high { let middle = (low + high) / 2; if keys[middle] < key { low = middle + 1 } else { high = middle } }
            return low < keys.count && keys[low] == key ? low : nil
        }
        if let list = value as? [Any] {
            let position = key.hasPrefix("[") && key.hasSuffix("]") ? Int(key.dropFirst().dropLast())
                : Int(key.prefix { $0.isNumber }).map { $0 - 1 }
            guard let position, list.indices.contains(position), child(position).pathKey == key else { return nil }
            return position
        }
        return (0..<count).first { child($0).pathKey == key }
    }
    func child(_ index: Int) -> JSONOutlineNode {
        if let result = children[index] { return result }
        let result: JSONOutlineNode
        if let frame = value as? CapturedEventFrame {
            let (key, value) = frame.entry(index, prepared: prepared)
            result = JSONOutlineNode(key: key, value: value)
        } else if let values = value as? [String: Any] { result = JSONOutlineNode(key: keys[index], value: values[keys[index]] ?? NSNull()) }
        else {
            let list = value as? [Any] ?? []
            let value: Any = list.indices.contains(index) ? list[index] : NSNull()
            result = JSONOutlineNode(key: (value as? CapturedEventFrame)?.initialLabel ?? "[\(index)]", value: value)
        }
        children[index] = result
        return result
    }
    var summary: String {
        if let frame = value as? CapturedEventFrame { return prepared.map { frame.summary($0) } ?? "" }
        if value is [String: Any] { return "{ \(count) \(count == 1 ? "key" : "keys") }" }
        if value is [Any] { return "[ \(count) \(count == 1 ? "item" : "items") ]" }
        if let string = value as? String {
            let preview = String(string.prefix(251))
            return "\"" + String(preview.prefix(250)).replacingOccurrences(of: "\n", with: "\\n") + (preview.count > 250 ? "…" : "") + "\""
        }
        return detail
    }
    var detail: String {
        if let formattedDetail { return formattedDetail }
        if let frame = value as? CapturedEventFrame { return frame.formatted }
        // Custom event values are not Foundation JSON containers. This
        // fallback also protects roots constructed outside the live viewer;
        // the viewer supplies its already formatted root to avoid this work.
        if let frames = value as? [CapturedEventFrame], !frames.isEmpty {
            return "Server-sent events · formatted view of retained frames\n\n" + frames.map(\.formatted).joined(separator: "\n\n")
        }
        if let string = value as? String { return string }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct JSONOutlineCommand: Equatable {
    enum Action { case collapseSection, top }
    let id = UUID()
    let action: Action
}

@MainActor final class JSONOutlineView: NSScrollView {
    let coordinator: Coordinator
    let outline = NSOutlineView()
    private var preferredColumnWidth: CGFloat = 0
    var onSelection: ((String) -> Void)? {
        didSet { coordinator.onSelection = onSelection }
    }
    var selection: String { coordinator.selection }

    init(json: CapturedJSON, selection: String = "", expandRevision: Int = 0, expandAll: Bool = false,
         command: JSONOutlineCommand? = nil, stateKey: String = "", onSelection: ((String) -> Void)? = nil) {
        coordinator = Coordinator(selection: selection, onSelection: onSelection)
        self.onSelection = onSelection
        super.init(frame: .zero)
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; drawsBackground = false
        outline.headerView = nil; outline.backgroundColor = .clear
        outline.rowHeight = 24; outline.intercellSpacing = NSSize(width: 10, height: 2); outline.indentationPerLevel = 14
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")); key.width = 240; key.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")); value.width = 420; value.minWidth = 120
        outline.addTableColumn(key); outline.addTableColumn(value); outline.outlineTableColumn = key
        preferredColumnWidth = outline.tableColumns.reduce(0) { $0 + $1.width }
            + outline.intercellSpacing.width * CGFloat(outline.tableColumns.count)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = coordinator; outline.delegate = coordinator
        outline.setAccessibilityLabel("Expandable captured JSON")
        documentView = outline
        coordinator.observeViewport(contentView, outline: outline)
        update(json: json, selection: selection, expandRevision: expandRevision, expandAll: expandAll, command: command, stateKey: stateKey)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    override func layout() {
        super.layout()
        // A native retained outline is populated before its viewport has a
        // size. Fit its document once the clip view has room, retaining
        // horizontal scrolling when the columns cannot fit a narrow reader.
        let width = max(preferredColumnWidth, contentView.bounds.width)
        if outline.frame.width != width {
            outline.setFrameSize(NSSize(width: width, height: outline.frame.height))
            outline.sizeLastColumnToFit()
            reflectScrolledClipView(contentView)
        }
    }

    /// An immutable document is rebuilt only after a new read. The same
    /// body's newer document carries disclosure, selection and scroll state.
    func update(json: CapturedJSON, selection: String? = nil, expandRevision: Int = 0, expandAll: Bool = false,
                command: JSONOutlineCommand? = nil, stateKey: String = "") {
        if let selection { coordinator.selection = selection }
        if coordinator.documentID != json.id {
            let carried = !stateKey.isEmpty && coordinator.stateKey == stateKey ? coordinator.capture(outline) : nil
            coordinator.cancelPendingSelection()
            coordinator.documentID = json.id; coordinator.stateKey = stateKey
            coordinator.root = JSONOutlineNode(key: json.rootLabel, value: json.value, formattedDetail: json.eagerFormatted)
            coordinator.revision = expandRevision
            coordinator.commandID = command?.id
            outline.reloadData(); outline.expandItem(coordinator.root)
            if let carried { coordinator.restore(carried, in: outline) }
            else if expandAll { coordinator.expandEverything = true; coordinator.expandAll(in: outline) }
        }
        if coordinator.revision != expandRevision {
            coordinator.revision = expandRevision
            coordinator.expandEverything = expandAll
            if expandAll { coordinator.expandAll(in: outline) }
            else { coordinator.collapseAll(in: outline) }
        }
        if let command, coordinator.commandID != command.id {
            coordinator.commandID = command.id
            switch command.action {
            case .collapseSection: coordinator.collapseSection(in: outline)
            case .top: coordinator.scrollToTop(in: outline)
            }
        }
    }
    func stop() {
        coordinator.stopObserving()
        outline.delegate = nil; outline.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: JSONOutlineNode?
        var documentID: UUID?
        var stateKey = ""
        /// What the reader had open, selected and scrolled to, by node path.
        struct Carried {
            var expanded: [[String]] = []
            var selected: [String]?
            var anchor: [String]?
            var offset: CGFloat = 0
            var everything = false
        }
        private func path(_ node: JSONOutlineNode, in outline: NSOutlineView) -> [String] {
            var keys: [String] = [], item: Any? = node
            while let current = item as? JSONOutlineNode { keys.append(current.pathKey); item = outline.parent(forItem: current) }
            return keys.reversed()
        }
        private func node(at path: [String]) -> JSONOutlineNode? {
            guard var node = root, path.first == node.pathKey else { return nil }
            for key in path.dropFirst() {
                guard let index = node.childIndex(forPathKey: key) else { return nil }
                node = node.child(index)
            }
            return node
        }
        func capture(_ outline: NSOutlineView) -> Carried? {
            guard root != nil else { return nil }
            var state = Carried(everything: expandEverything)
            if !expandEverything {
                for row in 0..<outline.numberOfRows {
                    guard let node = outline.item(atRow: row) as? JSONOutlineNode, node !== root, outline.isItemExpanded(node) else { continue }
                    state.expanded.append(path(node, in: outline))
                }
            }
            if let node = outline.item(atRow: outline.selectedRow) as? JSONOutlineNode { state.selected = path(node, in: outline) }
            let visible = outline.rows(in: outline.visibleRect)
            if visible.length > 0, let node = outline.item(atRow: visible.location) as? JSONOutlineNode {
                state.anchor = path(node, in: outline)
                state.offset = outline.visibleRect.minY - outline.rect(ofRow: visible.location).minY
            }
            return state
        }
        func restore(_ state: Carried, in outline: NSOutlineView) {
            if state.everything { expandEverything = true; expandAll(in: outline) }
            // Parents are listed before their children, so each path's parent is already open.
            else { for path in state.expanded { if let node = node(at: path) { outline.expandItem(node) } } }
            if let selected = state.selected, let node = node(at: selected), outline.row(forItem: node) >= 0 {
                outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
            }
            if let anchor = state.anchor, let node = node(at: anchor), let scroll = outline.enclosingScrollView, outline.row(forItem: node) >= 0 {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: outline.rect(ofRow: outline.row(forItem: node)).minY + state.offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        var revision = 0
        var commandID: UUID?
        var selection: String
        var onSelection: ((String) -> Void)?
        private var selectionRevision = 0
        var expandEverything = false
        private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var preparedNodes: [ObjectIdentifier: JSONOutlineNode] = [:]
        private var requestedExpansion: Set<ObjectIdentifier> = []
        private var detailTask: Task<Void, Never>?
        private var expansionTask: Task<Void, Never>?
        nonisolated(unsafe) private var viewportObserver: NSObjectProtocol?
        deinit { if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
        func observeViewport(_ clip: NSClipView, outline: NSOutlineView) {
            clip.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak outline] _ in
                MainActor.assumeIsolated { if let outline { self?.trimPreparedFrames(outline) } }
            }
        }
        func stopObserving() {
            cancelPendingSelection()
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver); self.viewportObserver = nil }
        }
        private func trimPreparedFrames(_ outline: NSOutlineView) {
            let visible = outline.rows(in: outline.visibleRect)
            for (id, node) in preparedNodes {
                let row = outline.row(forItem: node)
                if !NSLocationInRange(row, visible), !outline.isItemExpanded(node) {
                    node.releasePreparation(); preparedNodes[id] = nil
                }
            }
        }
        private func prepare(_ node: JSONOutlineNode, outline: NSOutlineView) {
            guard expansionTask == nil, node.prepared == nil, let frame = node.value as? CapturedEventFrame else { return }
            let key = ObjectIdentifier(node), document = documentID
            guard pending[key] == nil else { return }
            pending[key] = Task { [weak self, weak outline, weak node] in
                defer { if self?.documentID == document { self?.pending[key] = nil } }
                guard let content = try? await CapturedBodyWorker.shared.run({ frame.content }), !Task.isCancelled,
                      let self, let outline, let node, self.documentID == document, outline.delegate === self else { return }
                node.prepared = content; self.preparedNodes[key] = node
                outline.reloadItem(node, reloadChildren: true)
                if self.expandEverything || self.requestedExpansion.contains(key) { outline.expandItem(node, expandChildren: true) }
                self.trimPreparedFrames(outline)
            }
        }
        /// Expand all also includes offscreen events. One bounded worker job at
        /// a time replaces a task per frame, and each publication preserves the
        /// visible outline item while rows are inserted above it.
        func expandAll(in outline: NSOutlineView) {
            cancelExpansion()
            guard let root, let frames = root.value as? [CapturedEventFrame] else {
                outline.expandItem(nil, expandChildren: true); return
            }
            pending.values.forEach { $0.cancel() }; pending.removeAll()
            let document = documentID, revision = revision
            expansionTask = Task { [weak self, weak outline] in
                defer { if self?.documentID == document, self?.revision == revision { self?.expansionTask = nil } }
                for start in stride(from: 0, to: frames.count, by: 8) {
                    let end = min(start + 8, frames.count)
                    let batch = Array(frames[start..<end])
                    guard let contents = try? await CapturedBodyWorker.shared.run({ try batch.map { frame in try Task.checkCancellation(); return frame.content } }),
                          !Task.isCancelled, let self, let outline, self.documentID == document,
                          self.revision == revision, self.expandEverything, outline.delegate === self else { return }
                    let visible = outline.rows(in: outline.visibleRect)
                    let anchor = visible.length > 0 ? outline.item(atRow: visible.location) : nil
                    let offset = visible.length > 0 ? outline.visibleRect.minY - outline.rect(ofRow: visible.location).minY : 0
                    for (index, content) in zip(start..<end, contents) {
                        let node = root.child(index)
                        node.prepared = content; self.preparedNodes[ObjectIdentifier(node)] = node
                        outline.reloadItem(node, reloadChildren: true)
                        outline.expandItem(node, expandChildren: true)
                    }
                    if let anchor, let clip = outline.enclosingScrollView?.contentView {
                        let row = outline.row(forItem: anchor)
                        if row >= 0 { clip.scroll(to: NSPoint(x: clip.bounds.minX, y: outline.rect(ofRow: row).minY + offset)) }
                    }
                }
            }
        }
        func cancelExpansion() { expansionTask?.cancel(); expansionTask = nil }
        private func stopAutomaticExpansion() {
            cancelExpansion(); expandEverything = false; requestedExpansion.removeAll()
            pending.values.forEach { $0.cancel() }; pending.removeAll()
        }
        func scrollToTop(in outline: NSOutlineView) {
            guard let scroll = outline.enclosingScrollView else { return }
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        func collapseAll(in outline: NSOutlineView) {
            stopAutomaticExpansion()
            outline.deselectAll(nil)
            outline.collapseItem(nil, collapseChildren: true); outline.expandItem(root)
            scrollToTop(in: outline)
        }
        func collapseSection(in outline: NSOutlineView) {
            let visible = outline.rows(in: outline.visibleRect)
            guard visible.length > 0 else { return }
            // A selected item above the viewport must not send the reader to
            // an unrelated section. Prefer their current visible position.
            let row = NSLocationInRange(outline.selectedRow, visible) ? outline.selectedRow : visible.location
            var item = outline.item(atRow: row)
            while let node = item {
                if outline.isExpandable(node), outline.isItemExpanded(node) {
                    if (node as? JSONOutlineNode) === root { collapseAll(in: outline); return }
                    stopAutomaticExpansion()
                    outline.collapseItem(node, collapseChildren: true)
                    let parentRow = outline.row(forItem: node)
                    if parentRow >= 0 {
                        outline.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                        outline.scrollRowToVisible(parentRow)
                    }
                    return
                }
                item = outline.parent(forItem: node)
            }
        }
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView, let node = notification.userInfo?["NSObject"] as? JSONOutlineNode else { return }
            requestedExpansion.insert(ObjectIdentifier(node)); prepare(node, outline: outline)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? JSONOutlineNode else { return }
            // A late event-frame decode must not reopen a section the reader
            // just closed, including during an asynchronous Expand all.
            stopAutomaticExpansion()
            requestedExpansion.remove(ObjectIdentifier(node))
        }
        init(selection: String = "", onSelection: ((String) -> Void)? = nil) { self.selection = selection; self.onSelection = onSelection }
        private func publishSelection(_ value: String) {
            guard selection != value else { return }; selection = value; onSelection?(value)
        }
        func cancelPendingSelection() {
            selectionRevision += 1; detailTask?.cancel(); detailTask = nil
            cancelExpansion()
            pending.values.forEach { $0.cancel() }; pending.removeAll(); preparedNodes.removeAll(); requestedExpansion.removeAll(); expandEverything = false
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? JSONOutlineNode)?.count ?? (root == nil ? 0 : 1) }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? JSONOutlineNode)?.child(index) ?? root ?? JSONOutlineNode(key: "", value: [String: Any]()) }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (((item as? JSONOutlineNode)?.value as? CapturedEventFrame)?.count ?? (item as? JSONOutlineNode)?.count ?? 0) > 0 }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? JSONOutlineNode else { return nil }
            prepare(node, outline: outlineView)
            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("value")
            let field = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = identifier; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            field.stringValue = identifier.rawValue == "key" ? node.key : node.summary
            field.textColor = identifier.rawValue == "key" ? .labelColor : .secondaryLabelColor
            return field
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView else { return }
            // Reload and collapse post this synchronously. Publish the
            // final selection on the next turn, after the update has settled.
            // Read only the final selection, and discard work from a replaced body
            // or a dismantled outline before it can repopulate the cleared detail.
            selectionRevision += 1
            let revision = selectionRevision, documentID = documentID, root = root
            DispatchQueue.main.async { [weak self, weak outline] in
                guard let self, let outline, outline.delegate === self,
                      self.selectionRevision == revision, self.documentID == documentID,
                      self.root === root else { return }
                self.detailTask?.cancel()
                guard let node = outline.item(atRow: outline.selectedRow) as? JSONOutlineNode,
                      node.count == 0 || node === root || node.value is CapturedEventFrame else {
                    self.publishSelection(""); return
                }
                let value = CapturedOutlineDetail(value: node.value, formatted: node.formattedDetail)
                self.detailTask = Task { [weak self, weak outline] in
                    guard let detail = try? await CapturedBodyWorker.shared.run({ try value.render() }), !Task.isCancelled,
                          let self, let outline, outline.delegate === self, self.selectionRevision == revision,
                          self.documentID == documentID else { return }
                    self.publishSelection(detail)
                }
            }
        }
    }
}

/// Immutable Foundation data crosses to the bounded worker, never outline nodes.
private struct CapturedOutlineDetail: @unchecked Sendable {
    let value: Any
    let formatted: String?
    func render() throws -> String {
        if let formatted { return formatted }
        if let frame = value as? CapturedEventFrame { return frame.formatted }
        if let frames = value as? [CapturedEventFrame] { return try CapturedJSON(frames: frames).render() }
        if let string = value as? String { return string }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }
}
