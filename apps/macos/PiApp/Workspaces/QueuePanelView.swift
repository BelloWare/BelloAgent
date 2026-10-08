import AppKit
import Combine

// The queue panel over the composer: its header (fold, what the queue is
// waiting for, Resume), the list of waiting messages under their headings
// (drag follow-ups to reorder; each row has its detail, steer, edit and
// remove), and the detail of one message in a popover.

/// The panel in the pane, inset as the pane inset it
/// (`.padding(.horizontal, 16).padding(.bottom, 8)`). It starts over for
/// each chat.
@MainActor final class QueuePanelView: NSView, PiKit.WidthSizing {
    let model: WorkspaceModel
    let session: SessionDisplay
    /// The height the list may take (`QueuePanel.room`).
    var room: CGFloat = .infinity { didSet { if oldValue != room { refresh() } } }
    /// The window's disabled state, from the SwiftUI around the pane.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    var sizeChanged: (() -> Void)?

    private var observer: ShellObserver!
    private let fill = CALayer(), stroke = CALayer()
    let collapse = PiKit.IconButton(symbol: "chevron.down", label: "Hide waiting messages", size: 20)
    let status = ShellLabel("", symbol: "tray.full", font: PiKit.Font.micro, color: .piInkSecondary)
    private let hint = ShellText("Drag to reorder", font: PiKit.Font.micro, color: .piInkTertiary)
    let resume = PiKit.Button("Resume", symbol: "play.fill", style: .secondary, compact: true)
    private(set) var list: QueueListScrollView?
    private var header: QueueHeaderView!
    private var detail: NSPopover?

    static let insets = NSEdgeInsets(top: 0, left: PiSpacing.lg, bottom: PiSpacing.sm, right: PiSpacing.lg)
    static let padding: CGFloat = PiSpacing.md

    init(model: WorkspaceModel, session: SessionDisplay) {
        self.model = model; self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(fill); layer?.addSublayer(stroke)
        collapse.setAccessibilityIdentifier("queue-collapse")
        collapse.onPress = { [weak self] in self?.session.queueCollapsed.toggle() }
        status.setAccessibilityIdentifier("queue-status")
        resume.onPress = { [weak self] in guard let self else { return }; self.model.action("queue.resume", sessionID: self.session.id) }
        header = QueueHeaderView(collapse: collapse, status: status, hint: hint, resume: resume)
        addSubview(header)
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(session)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    // MARK: State

    private struct Shown: Equatable {
        var items: [QueuedMessage]
        var timing: QueueTiming
        var collapsed: Bool
        var canResume: Bool
        var paused: Bool
        var held: QueueEditHold?
        var editingID: String?
        var preparing: String?
        var resolving: Bool
        var cancelling: String?
        var busy: Bool
        var room: CGFloat
        var enabled: Bool
    }
    private var shown: Shown?

    private func refresh() {
        let new = Shown(items: QueuedMessage.from(session.queue), timing: QueueTiming(session), collapsed: session.queueCollapsed,
                        canResume: session.canResumeQueue, paused: session.queuePaused, held: session.queueEditHold,
                        editingID: session.queueEditingID, preparing: session.queueEditPreparing, resolving: session.queueEditResolving,
                        cancelling: session.queueEditCancelling, busy: session.busy, room: room, enabled: inheritedEnabled)
        presentDetail()
        guard new != shown else { return }
        let before = shown
        shown = new
        let followUps = new.items.filter { !$0.steering }
        collapse.symbol = new.collapsed ? "chevron.right" : "chevron.down"
        collapse.label = new.collapsed ? "Show waiting messages" : "Hide waiting messages"
        collapse.isEnabled = new.enabled
        status.text = new.timing.header(count: new.items.count)
        status.symbol = new.timing == .editing ? "pause.circle" : "tray.full"
        hint.isHidden = new.collapsed || followUps.count <= 1 || new.held != nil
        resume.isHidden = !new.canResume
        resume.title = new.paused ? "Resume" : "Send queued"
        resume.isEnabled = new.held == nil && new.enabled
        resume.toolTip = new.held != nil ? "Finish or cancel the queued edit first" : nil
        resume.setAccessibilityHelp(new.held != nil ? "Finish or cancel the queued edit first" : nil)
        header.needsLayout = true
        if new.collapsed {
            if let list {
                self.list = nil
                // `.transition(.opacity)` under `PiKit.Motion.quick`.
                if window != nil, !PiKit.Motion.reduced {
                    PiKit.Motion.layers(PiKit.Motion.quick) { list.layer?.opacity = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + PiKit.Motion.quick) { list.removeFromSuperview() }
                } else { list.removeFromSuperview() }
            }
        } else {
            let arriving = list == nil
            let list = self.list ?? QueueListScrollView(panel: self)
            if arriving { addSubview(list); self.list = list }
            list.table.update(items: new.items, timing: new.timing)
            if arriving, before != nil, window != nil, !PiKit.Motion.reduced {
                list.wantsLayer = true; list.layer?.opacity = 0
                PiKit.Motion.layers(PiKit.Motion.quick) { list.layer?.opacity = 1 }
            }
        }
        invalidateIntrinsicContentSize(); needsLayout = true
        sizeChanged?()
    }

    // MARK: Layout

    private var sections: Int {
        guard let shown else { return 0 }
        return (shown.items.contains(where: \.steering) ? 1 : 0) + (shown.items.contains { !$0.steering } ? 1 : 0)
    }
    private var listHeight: CGFloat {
        QueuePanel.listHeight(rows: shown?.items.count ?? 0, sections: sections, room: room)
    }
    /// The header's room: the panel's width inside its insets and padding.
    private func innerWidth(_ width: CGFloat) -> CGFloat { max(0, width - Self.insets.left - Self.insets.right - Self.padding * 2) }
    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = header.height(forWidth: innerWidth(width)) + (list != nil ? 6 + listHeight : 0)
        return Self.insets.top + Self.padding * 2 + inner + Self.insets.bottom
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func layout() {
        super.layout()
        let box = CGRect(x: Self.insets.left, y: Self.insets.top, width: max(0, bounds.width - Self.insets.left - Self.insets.right),
                         height: max(0, bounds.height - Self.insets.top - Self.insets.bottom))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = box; fill.cornerRadius = PiRadius.md; fill.cornerCurve = .continuous
        // `.overlay(shape.stroke(lineWidth: 1))`: centred on the edge.
        stroke.frame = box.insetBy(dx: -0.5, dy: -0.5); stroke.cornerRadius = PiRadius.md + 0.5; stroke.cornerCurve = .continuous; stroke.borderWidth = 1
        CATransaction.commit()
        let inner = box.insetBy(dx: Self.padding, dy: Self.padding)
        header.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: header.height(forWidth: inner.width))
        if let list {
            list.frame = CGRect(x: inner.minX, y: header.frame.maxY + 6, width: inner.width, height: listHeight)
            list.refreshScrolling(rows: shown?.items.count ?? 0, sections: sections)
        }
        presentDetail()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        fill.backgroundColor = piCGColor(.piSurfaceSunken)
        stroke.borderColor = piCGColor(.piHairline)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }

    // MARK: The detail of one message

    /// On the panel, not the row: a message that leaves while its detail is
    /// open takes no popover with it; the detail says it left. Closing is
    /// written after the update that asked for it.
    private func presentDetail() {
        let id = session.queueDetailID
        if let id, window != nil {
            if let detail, let view = detail.contentViewController?.view as? QueuedMessageDetailView {
                if view.turnID != id { view.show(turnID: id) }
                return
            }
            let view = QueuedMessageDetailView(model: model, session: session, turnID: id)
            let controller = NSViewController(); controller.view = view
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.contentSize = view.fittingSize
            view.sizeChanged = { [weak popover, weak view] in if let view { popover?.contentSize = view.fittingSize } }
            popover.delegate = closer
            detail = popover
            closer.closed = { [weak self, weak view] in
                guard let self else { return }
                self.detail = nil
                view?.stop()
                DispatchQueue.main.async { [session = self.session] in session.queueDetailID = nil }
            }
            let anchor = CGRect(x: Self.insets.left, y: Self.insets.top, width: max(1, bounds.width - Self.insets.left - Self.insets.right), height: 1)
            popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
        } else if id == nil, let detail {
            self.detail = nil
            closer.closed = nil
            (detail.contentViewController?.view as? QueuedMessageDetailView)?.stop()
            detail.close()
        }
    }
    private let closer = QueueDetailCloser()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let detail {
            self.detail = nil; closer.closed = nil
            (detail.contentViewController?.view as? QueuedMessageDetailView)?.stop()
            detail.close()
        } else { presentDetail() }
    }

    // MARK: Row actions

    func act(_ action: QueueRowAction, on item: QueuedMessage) {
        let id = session.id
        switch action {
        case .detail: session.queueDetailID = item.id
        case .steer: model.action("queue.steer", params: ["turnId": .string(item.id)], sessionID: id)
        case .edit: model.editQueued(item.id, sessionID: id)
        case .resumeEdit: if let hold = session.queueEditHold { model.editQueued(item.id, sessionID: id, resuming: hold.editID) }
        case .cancelEdit: model.cancelHeldQueueEdit(sessionID: id)
        case .remove:
            // The message being rewritten goes with its hold, in one step.
            if session.queueEditingID == item.id { model.removeQueuedEdit(sessionID: id) }
            else { model.action("queue.remove", params: ["turnId": .string(item.id)], sessionID: id) }
        }
    }
    /// What a row shows for its message now.
    func rowState(_ item: QueuedMessage, index: Int?) -> QueueRowView.State {
        let editing = session.queueEditingID == item.id
        let heldElsewhere = !editing && session.queueEditHold?.turnID == item.id
        return QueueRowView.State(item: item, index: index, editing: editing, heldElsewhere: heldElsewhere,
                                  canSteer: !item.steering && session.busy && session.queueEditHold == nil,
                                  preparing: session.queueEditPreparing == item.id, held: session.queueEditHold != nil,
                                  resumeEditEnabled: session.queueEditHold.map { session.queueEditCancelling != $0.editID } ?? false,
                                  removeEnabled: !((session.queueEditResolving && editing) || heldElsewhere), enabled: inheritedEnabled)
    }
    /// Follow-ups move only while no message is being edited.
    var reorders: Bool { session.queueEditHold == nil && inheritedEnabled }
    func reorder(_ order: [String]) { model.reorderQueued(order, sessionID: session.id) }
}

/// The panel's header row (`HStack(spacing: 8)`): the fold button, the
/// status, the drag hint, a spacer and Resume. Room is shared as SwiftUI's
/// stack shares it: the least flexible child first, each offered an equal
/// part of what is left, the spacer included; the status and hint wrap in
/// what they get. (SwiftUI also wrapped Resume's own words in a pane too
/// narrow for it; this button keeps its width.)
@MainActor final class QueueHeaderView: NSView {
    private let collapse: NSView, status: ShellLabel, hint: ShellText, resume: NSView
    init(collapse: NSView, status: ShellLabel, hint: ShellText, resume: NSView) {
        self.collapse = collapse; self.status = status; self.hint = hint; self.resume = resume
        super.init(frame: .zero)
        for view in [collapse, status, hint, resume] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private static let spacing: CGFloat = PiSpacing.sm
    private static let spacerMinimum: CGFloat = 8

    /// Each shown child's width, in order: collapse, status, hint, spacer, resume.
    private func widths(_ width: CGFloat) -> (collapse: CGFloat, status: CGFloat, hint: CGFloat?, spacer: CGFloat, resume: CGFloat?) {
        let collapseWidth = collapse.intrinsicContentSize.width
        let resumeWidth: CGFloat? = resume.isHidden ? nil : resume.intrinsicContentSize.width
        let hintShown = !hint.isHidden
        let count = 3 + (hintShown ? 1 : 0) + (resumeWidth == nil ? 0 : 1)
        // The spacer keeps only its minimum until the words have theirs: an
        // equal share for it wrapped "Paused · 1" mid-word in a narrow pane.
        var room = width - collapseWidth - (resumeWidth ?? 0) - Self.spacing * CGFloat(count - 1) - Self.spacerMinimum
        // Least flexible first: the hint, then the status; the spacer takes what is left.
        var flexible: [(key: String, ideal: CGFloat)] = [("status", status.naturalWidth)]
        if hintShown { flexible.append(("hint", hint.naturalWidth)) }
        flexible.sort { $0.ideal < $1.ideal }
        var given: [String: CGFloat] = [:]
        var remaining = flexible.count
        for child in flexible {
            let share = max(0, room) / CGFloat(remaining)
            let taken = min(child.ideal, share)
            given[child.key] = taken; room -= taken; remaining -= 1
        }
        let spacer = Self.spacerMinimum + max(0, room)
        return (collapseWidth, given["status"] ?? 0, hintShown ? given["hint"] : nil, spacer, resumeWidth)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let w = widths(width)
        var height = max(collapse.intrinsicContentSize.height, status.height(forWidth: w.status))
        if let hintWidth = w.hint { height = max(height, hint.height(forWidth: hintWidth)) }
        if w.resume != nil { height = max(height, resume.intrinsicContentSize.height) }
        return height
    }
    override func layout() {
        super.layout()
        let w = widths(bounds.width), h = bounds.height, scale = piScale
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = CGRect(x: x, y: PiKit.round((h - height) / 2, scale), width: width, height: height)
        }
        var x: CGFloat = 0
        place(collapse, x: x, width: w.collapse, height: collapse.intrinsicContentSize.height); x += w.collapse + Self.spacing
        place(status, x: x, width: w.status, height: status.height(forWidth: w.status)); x += w.status + Self.spacing
        if let hintWidth = w.hint { place(hint, x: x, width: hintWidth, height: hint.height(forWidth: hintWidth)); x += hintWidth + Self.spacing }
        x += w.spacer
        if let resumeWidth = w.resume { place(resume, x: x + Self.spacing, width: resumeWidth, height: resume.intrinsicContentSize.height) }
    }
}

/// Tells the panel when its detail popover closed on its own (a click outside).
@MainActor final class QueueDetailCloser: NSObject, NSPopoverDelegate {
    var closed: (() -> Void)?
    func popoverDidClose(_ notification: Notification) { let closed = self.closed; self.closed = nil; closed?() }
}

enum QueueRowAction { case detail, steer, edit, resumeEdit, cancelEdit, remove }

// MARK: - The list

/// The panel's list: a plain table of headings and rows on the panel's own
/// background; it scrolls only when its rows don't fit.
@MainActor final class QueueListScrollView: NSScrollView {
    let table: QueueTableView
    init(panel: QueuePanelView) {
        table = QueueTableView(panel: panel)
        super.init(frame: .zero)
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = table
        contentView.drawsBackground = false
        setAccessibilityIdentifier("queue-follow-ups")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// `.scrollDisabled` while everything fits, as the panel measured it
    /// (rows and 22-point headings, though a heading row is 24).
    private var fits = true
    func refreshScrolling(rows: Int, sections: Int) {
        fits = bounds.height >= CGFloat(rows) * QueuePanel.rowHeight + CGFloat(sections) * QueuePanel.sectionHeaderHeight
        // Disabled, SwiftUI's list showed no scroller either.
        if hasVerticalScroller == fits { hasVerticalScroller = !fits }
    }
    override func scrollWheel(with event: NSEvent) {
        if fits { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// One line of the list: a heading or a message.
enum QueueLine: Equatable {
    case heading(String)
    case message(QueuedMessage, index: Int?)
    var id: String {
        switch self {
        case .heading(let title): return "heading|" + (title.hasPrefix("Steering") ? "steering" : "follow-ups")
        case .message(let item, _): return item.id
        }
    }
}

@MainActor final class QueueTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private weak var panel: QueuePanelView?
    private(set) var lines: [QueueLine] = []
    static let dragType = NSPasteboard.PasteboardType("app.bello.agent.queued-follow-up")
    static let orderType = NSPasteboard.PasteboardType("app.bello.agent.queued-follow-up-order")
    /// Where SwiftUI's plain list put a row's content in its table.
    static let cellInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 9)

    init(panel: QueuePanelView) {
        self.panel = panel
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        style = .plain
        backgroundColor = .clear
        intercellSpacing = .zero
        gridStyleMask = []
        selectionHighlightStyle = .none
        allowsEmptySelection = true
        columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        usesAutomaticRowHeights = false
        focusRingType = .none
        dataSource = self; delegate = self
        registerForDraggedTypes([Self.dragType])
        draggingDestinationFeedbackStyle = .gap
        setDraggingSourceOperationMask(.move, forLocal: true)
        verticalMotionCanBeginDrag = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    var contentHeight: CGFloat { lines.reduce(0) { $0 + height(of: $1) } }
    /// A heading row is 24 points in the table SwiftUI's list made (its
    /// rows are never shorter), though the panel's measures count 22.
    static let headingRowHeight: CGFloat = 24
    private func height(of line: QueueLine) -> CGFloat {
        if case .heading = line { return Self.headingRowHeight }
        return QueuePanel.rowHeight
    }

    func update(items: [QueuedMessage], timing: QueueTiming) {
        var new: [QueueLine] = []
        let steering = items.filter(\.steering), followUps = items.filter { !$0.steering }
        if !steering.isEmpty {
            new.append(.heading(timing.steering))
            new += steering.map { .message($0, index: nil) }
        }
        if !followUps.isEmpty {
            new.append(.heading(timing.followUps))
            new += followUps.enumerated().map { .message($1, index: $0 + 1) }
        }
        if new.map(\.id) != lines.map(\.id) {
            lines = new
            reloadData()
        } else {
            lines = new
            // The same rows: each takes its new values in place.
            for row in 0..<numberOfRows { refreshRow(row) }
        }
    }
    private func refreshRow(_ row: Int) {
        guard row < lines.count, let panel else { return }
        switch lines[row] {
        case .heading(let title): (view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueHeadingView)?.title = title
        case .message(let item, let index): (view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueRowView)?.apply(panel.rowState(item, index: index))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: lines[row]) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let panel else { return nil }
        switch lines[row] {
        case .heading(let title):
            let view = (makeView(withIdentifier: QueueHeadingView.identifier, owner: nil) as? QueueHeadingView) ?? QueueHeadingView()
            view.title = title
            return view
        case .message(let item, let index):
            let view = (makeView(withIdentifier: QueueRowView.identifier, owner: nil) as? QueueRowView) ?? QueueRowView()
            view.act = { [weak panel] action, item in panel?.act(action, on: item) }
            view.apply(panel.rowState(item, index: index))
            return view
        }
    }

    // MARK: Reordering follow-ups

    private var followUpIDs: [String] {
        followUpRows.compactMap { if case .message(let item, _) = lines[$0] { return item.id }; return nil }
    }
    private var followUpRows: [Int] {
        lines.indices.filter { if case .message(let item, _) = lines[$0] { return !item.steering }; return false }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard panel?.reorders == true, followUpRows.count > 1, case .message(let item, _) = lines[row], !item.steering else { return nil }
        let entry = NSPasteboardItem()
        entry.setString(item.id, forType: Self.dragType)
        // The order the drag began with: a queue that changes meanwhile is
        // refused by the helper rather than reordered from what is left.
        entry.setString(followUpIDs.joined(separator: "\n"), forType: Self.orderType)
        return entry
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === self, panel?.reorders == true else { return [] }
        let rows = followUpRows
        guard let first = rows.first, let last = rows.last else { return [] }
        // Only between follow-ups: above any of them, or below the last.
        let target = min(max(row, first), last + 1)
        if operation != .above || target != row { setDropRow(target, dropOperation: .above) }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.dragType), let panel, panel.reorders else { return false }
        let rows = followUpRows, current = followUpIDs
        guard let first = rows.first else { return false }
        // Where it lands, named by the row it goes before, in the order the
        // drag began with (`onMove` moved within the list it was shown).
        let began = info.draggingPasteboard.string(forType: Self.orderType)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? current
        let landing = max(0, min(current.count, row - first))
        let destination = landing < current.count ? (began.firstIndex(of: current[landing]) ?? began.count) : began.count
        guard let source = began.firstIndex(of: id) else { return false }
        let order = QueuePanel.reordered(began, moving: IndexSet(integer: source), to: destination)
        guard order != began else { return false }
        panel.reorder(order)
        return true
    }
}

/// A heading: the timing words over its rows, bottom-left in the panel.
@MainActor final class QueueHeadingView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("queue-heading")
    static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
    private let line = PiKit.TextLine()
    var title: String = "" {
        didSet {
            line.line = PiKit.Line(title, font: .systemFont(ofSize: 10.5, weight: .semibold), color: .piInkTertiary)
            setAccessibilityLabel(title); needsLayout = true
        }
    }
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(line)
        // `.accessibilityAddTraits(.isHeader)`: a heading, as SwiftUI reports one.
        setAccessibilityElement(true); setAccessibilityRole(QueueHeadingView.headingRole)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // `.frame(minHeight: 18, alignment: .bottomLeading)` inside the row's two-point insets.
        let size = line.intrinsicContentSize
        line.frame = CGRect(x: QueueTableView.cellInsets.left, y: bounds.height - 3 - size.height,
                            width: min(size.width, max(0, bounds.width - QueueTableView.cellInsets.left - QueueTableView.cellInsets.right)), height: size.height)
    }
}

/// One waiting message: its number (or the steering mark), its text, and
/// its detail, steer, edit and remove controls.
@MainActor final class QueueRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("queue-row")
    struct State: Equatable {
        var item: QueuedMessage
        var index: Int?
        var editing: Bool
        var heldElsewhere: Bool
        var canSteer: Bool
        var preparing: Bool
        var held: Bool
        var resumeEditEnabled: Bool
        var removeEnabled: Bool
        var enabled: Bool
    }
    private(set) var state: State?
    var act: ((QueueRowAction, QueuedMessage) -> Void)?

    private let steerMark = PiKit.SymbolView(PiKit.Symbol("arrow.turn.up.right", size: 10, weight: .semibold), color: .piAccent)
    private let number = PiKit.TextLine()
    private let title = PiKit.TextLine()
    let detail = PiKit.IconButton(symbol: "info.circle", label: "Show the whole message and its model choices", size: 22)
    private let editingLabel = ShellLabel("Editing in the composer", symbol: "pencil.line", font: PiKit.Font.caption, color: .piAccent)
    private let heldLabel = ShellLabel("Edit open", symbol: "pause.circle", font: PiKit.Font.caption, color: .piAccent)
    let resumeEdit = PiKit.Button("Resume Edit", style: .ghost)
    let cancelEdit = PiKit.Button("Cancel Edit", style: .ghost)
    let steer = PiKit.IconButton(symbol: "arrow.turn.up.right", label: "Steer the current run with this message", size: 22)
    private let spinner = PiKit.spinner(controlSize: .mini)
    let edit = PiKit.IconButton(symbol: "pencil", label: "Edit queued message", size: 22)
    let remove = PiKit.IconButton(symbol: "xmark", label: "Remove", size: 22)
    private let lead = QueueLeadView()
    private var stack: ShellStack!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        lead.addSubview(steerMark); lead.addSubview(number)
        steerMark.setAccessibilityElement(false); number.setAccessibilityElement(false)
        title.truncation = .end
        spinner.toolTip = "Pausing the queue and reading the whole message"
        steer.toolTip = "Deliver after the current tool batch instead of after the run"
        stack = ShellStack(.horizontal, spacing: PiSpacing.sm, [
            .view(lead, .fixed(14)), .view(title, .flexible), .spacer(8), .view(detail), .view(editingLabel), .view(heldLabel),
            .view(resumeEdit), .view(cancelEdit), .view(steer), .view(spinner, .fixed(22)), .view(edit), .view(remove),
        ])
        addSubview(stack)
        for (button, action) in [(detail, QueueRowAction.detail), (steer, .steer), (edit, .edit), (remove, .remove)] as [(PiKit.ButtonBase, QueueRowAction)] {
            button.onPress = { [weak self] in guard let self, let item = self.state?.item else { return }; self.act?(action, item) }
        }
        resumeEdit.onPress = { [weak self] in guard let self, let item = self.state?.item else { return }; self.act?(.resumeEdit, item) }
        cancelEdit.onPress = { [weak self] in guard let self, let item = self.state?.item else { return }; self.act?(.cancelEdit, item) }
        // The message's text is its own element in the row; the group only
        // says which message it is.
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ new: State) {
        guard new != state else { return }
        state = new
        let item = new.item
        let spoken = item.steering ? "steering message" : "follow-up \(new.index ?? 0)"
        steerMark.isHidden = !item.steering
        number.isHidden = item.steering
        number.line = PiKit.Line(new.index.map(String.init) ?? "", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkTertiary)
        title.line = PiKit.Line(item.title, font: PiKit.Font.body, color: new.editing ? .piInkTertiary : .piInk)
        detail.spokenLabel = "Show the whole " + spoken + " and its model choices"
        detail.setAccessibilityIdentifier("queue-detail-" + item.id)
        editingLabel.isHidden = !new.editing
        editingLabel.setAccessibilityIdentifier("queue-editing-" + item.id)
        let held = new.heldElsewhere
        heldLabel.isHidden = !held; resumeEdit.isHidden = !held; cancelEdit.isHidden = !held
        resumeEdit.setAccessibilityIdentifier("queue-resume-edit-" + item.id)
        cancelEdit.setAccessibilityIdentifier("queue-cancel-edit-" + item.id)
        let plain = !new.editing && !held
        steer.isHidden = !(plain && new.canSteer)
        steer.spokenLabel = "Steer the current run with " + spoken
        spinner.isHidden = !(plain && new.preparing)
        edit.isHidden = !(plain && !new.preparing)
        edit.spokenLabel = "Edit " + spoken
        remove.spokenLabel = "Remove " + spoken
        detail.isEnabled = new.enabled
        steer.isEnabled = new.enabled
        edit.isEnabled = !new.held && new.enabled
        resumeEdit.isEnabled = new.resumeEditEnabled && new.enabled
        cancelEdit.isEnabled = new.enabled
        remove.isEnabled = new.removeEnabled && new.enabled
        setAccessibilityLabel(item.steering ? "Steering message" : "Follow-up \(new.index ?? 0)")
        setAccessibilityIdentifier("queue-item-" + item.id)
        stack.relayoutAll(); needsLayout = true
    }
    override func layout() {
        super.layout()
        // `.listRowInsets(top: 2, bottom: 2)` around `.frame(minHeight: 26)`.
        let insets = QueueTableView.cellInsets
        stack.frame = CGRect(x: insets.left, y: 2, width: max(0, bounds.width - insets.left - insets.right), height: max(0, bounds.height - 4))
    }
}

/// A row's leading column: the message's number, or the steering mark,
/// centred in fourteen points (`.frame(width: 14)`).
@MainActor final class QueueLeadView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 26) }
    override func layout() {
        super.layout()
        for view in subviews {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                                width: size.width, height: size.height)
        }
    }
}

// MARK: - The detail

/// A waiting message, whole, with the model choices it was queued with.
/// Reading it takes no hold and leaves the composer alone.
@MainActor final class QueuedMessageDetailView: NSView, PiKit.WidthSizing {
    static let goneText = "This message is no longer waiting."
    static let width: CGFloat = 340
    let model: WorkspaceModel
    let session: SessionDisplay
    private(set) var turnID: String
    var sizeChanged: (() -> Void)?

    private var observer: ShellObserver!
    private let kind = PiKit.TextLine()
    let text = ShellSelectableText("", font: PiKit.Font.body, color: .piInk)
    private let scroll = NSScrollView()
    private let note = PiKit.TextLine()
    private let divider = NSView()
    private var rows: [QueueDetailRow] = []
    /// What the detail shows, compared before anything is redrawn.
    private struct Shown: Equatable {
        var steering: Bool
        var text: String
        var note: String?
        var pairs: [[String]]
    }
    private var shownDetail: Shown??
    private let gone = PiKit.TextLine(PiKit.Line(QueuedMessageDetailView.goneText, font: PiKit.Font.body, color: .piInkSecondary))
    private var whole: String?
    private var readFailed = false
    private var reading: Task<Void, Never>?
    private var readKey: String?
    private var shown: String?

    init(model: WorkspaceModel, session: SessionDisplay, turnID: String) {
        self.model = model; self.session = session; self.turnID = turnID
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        text.setAccessibilityIdentifier("queue-detail-text")
        gone.setAccessibilityIdentifier("queue-detail-gone")
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = FlippedDocument(); document.addSubview(text)
        scroll.documentView = document
        divider.wantsLayer = true
        for view in [kind, scroll, note, divider, gone] as [NSView] { addSubview(view) }
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(session)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { reading?.cancel() }
    override var isFlipped: Bool { true }

    func show(turnID: String) { self.turnID = turnID; readKey = nil; refresh() }
    /// Closed (`.onDisappear`): it reads and shows nothing more.
    func stop() {
        observer.reset(); reading?.cancel(); reading = nil
        session.queueDetailShowing = nil
    }

    private var item: QueuedMessage? { QueuedMessage.from(session.queue).first { $0.id == turnID } }

    private func refresh() {
        let item = self.item
        // Keyed by what the row now says: a rewrite saved while the detail is
        // open reads the message again, and an older read is dropped.
        if item?.contentKey != readKey {
            readKey = item?.contentKey
            reading?.cancel(); whole = nil; readFailed = false
            if let item, item.truncated {
                let key = item.contentKey, turnID = self.turnID, model = self.model, session = self.session
                reading = Task { [weak self] in
                    do {
                        let text = try await model.queuedMessageText(turnID: turnID, sessionID: session.id)
                        guard !Task.isCancelled, let self, self.item?.contentKey == key else { return }
                        self.whole = text; self.apply()
                    } catch {
                        guard !Task.isCancelled, let self else { return }
                        self.readFailed = true; self.apply()
                    }
                }
            }
        }
        apply()
    }
    private func apply() {
        let item = self.item
        // What the detail shows, for the chat to read back (tests, and the
        // row's own label): the message, or that it is no longer waiting.
        let showing = item.map { whole ?? $0.text } ?? Self.goneText
        if session.queueDetailShowing != showing { session.queueDetailShowing = showing }
        let new: Shown? = item.map { item in
            var pairs = [["Model", item.model ?? "Connection default"],
                         ["Reasoning", item.thinkingLevel.map { $0 == "default" ? "Model default" : $0.capitalized } ?? "Connection default"]]
            if let window = item.contextWindow { pairs.append(["Context", "\(window.formatted()) tokens"]) }
            if let output = item.maxOutputTokens { pairs.append(["Output budget", "\(output.formatted()) tokens"]) }
            return Shown(steering: item.steering, text: whole ?? item.text,
                         note: item.truncated && whole == nil ? (readFailed ? "Only the start of the message could be read." : "Reading the whole message…") : nil,
                         pairs: pairs)
        }
        guard shownDetail != .some(new) else { return }
        shownDetail = .some(new)
        gone.isHidden = new != nil
        for view in [kind, scroll, divider] as [NSView] { view.isHidden = new == nil }
        note.isHidden = new?.note == nil
        if let new {
            kind.line = PiKit.Line(new.steering ? "Steering message" : "Follow-up", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInkSecondary)
            text.text = new.text
            if let words = new.note { note.line = PiKit.Line(words, font: PiKit.Font.caption, color: .piInkTertiary) }
            // The rows stay; only their words change.
            while rows.count > new.pairs.count { rows.removeLast().removeFromSuperview() }
            while rows.count < new.pairs.count { let row = QueueDetailRow(); addSubview(row); rows.append(row) }
            for (row, pair) in zip(rows, new.pairs) { row.set(label: pair[0], value: pair[1]) }
        } else {
            for row in rows { row.removeFromSuperview() }
            rows = []
        }
        needsLayout = true
        let size = CGSize(width: Self.width, height: height(forWidth: Self.width))
        if frame.size != size { setFrameSize(size); sizeChanged?() }
    }
    override var fittingSize: NSSize { NSSize(width: Self.width, height: height(forWidth: Self.width)) }

    private var inner: CGFloat { Self.width - PiSpacing.md * 2 }
    private var textHeight: CGFloat { min(220, text.height(forWidth: inner)) }
    func height(forWidth width: CGFloat) -> CGFloat {
        guard item != nil else { return PiSpacing.md * 2 + gone.intrinsicContentSize.height }
        var height = kind.intrinsicContentSize.height + PiSpacing.sm + textHeight
        if !note.isHidden { height += PiSpacing.sm + note.intrinsicContentSize.height }
        height += PiSpacing.sm + 1
        for row in rows { height += PiSpacing.sm + row.height(forWidth: inner) }
        return PiSpacing.md * 2 + height
    }
    override func layout() {
        super.layout()
        let x = PiSpacing.md, width = inner
        var y = PiSpacing.md
        if item == nil {
            gone.frame = CGRect(origin: CGPoint(x: x, y: y), size: gone.intrinsicContentSize)
            return
        }
        kind.frame = CGRect(origin: CGPoint(x: x, y: y), size: kind.intrinsicContentSize); y = kind.frame.maxY + PiSpacing.sm
        scroll.frame = CGRect(x: x, y: y, width: width, height: textHeight)
        // The clip's own width: a legacy scroller takes its share of it, and
        // comes or goes with the text's height; settled in a pass or two.
        var clip = width
        for _ in 0..<3 {
            let full = text.height(forWidth: clip)
            scroll.documentView?.frame = CGRect(x: 0, y: 0, width: clip, height: full)
            text.frame = CGRect(x: 0, y: 0, width: clip, height: full)
            scroll.tile()
            let now = scroll.contentSize.width > 0 ? scroll.contentSize.width : width
            if now == clip { break }
            clip = now
        }
        y = scroll.frame.maxY
        if !note.isHidden { y += PiSpacing.sm; note.frame = CGRect(origin: CGPoint(x: x, y: y), size: note.intrinsicContentSize); y = note.frame.maxY }
        y += PiSpacing.sm
        divider.frame = CGRect(x: x, y: y, width: width, height: 1); y += 1
        for row in rows {
            y += PiSpacing.sm
            let h = row.height(forWidth: width)
            row.frame = CGRect(x: x, y: y, width: width, height: h)
            y += h
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { divider.layer?.backgroundColor = piCGColor(.separatorColor) }

}

/// One of the detail's choices: its name, and what it was queued with at
/// the trailing edge (`HStack { name; Spacer(); value }`), the value
/// wrapping when it is long; one element to VoiceOver (`.combine`).
@MainActor final class QueueDetailRow: NSView, PiKit.WidthSizing {
    private let label = PiKit.TextLine()
    private let value = ShellText("", font: PiKit.Font.caption, color: .piInk)
    init() {
        super.init(frame: .zero)
        label.setAccessibilityElement(false); value.setAccessibilityElement(false)
        addSubview(label); addSubview(value)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func set(label text: String, value words: String) {
        label.line = PiKit.Line(text, font: PiKit.Font.caption, color: .piInkSecondary)
        value.set(words, color: .piInk)
        setAccessibilityLabel(text + ", " + words)
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    /// The name keeps its width; a long value has the rest past the gap
    /// SwiftUI's stack left around its spacer (fourteen points, measured).
    static let gap: CGFloat = 14
    /// The name's own width, unrounded, as SwiftUI's stack measured it.
    private var labelWidth: CGFloat {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: label.line.text, attributes: [.font: label.line.font])), nil, nil, nil)
    }
    private func valueWidth(_ width: CGFloat) -> CGFloat { min(value.naturalWidth, max(0, width - labelWidth - Self.gap)) }
    /// SwiftUI's text kept a line that overran its room by a few hundredths of a point.
    static let slack: CGFloat = 0.25
    func height(forWidth width: CGFloat) -> CGFloat {
        max(label.intrinsicContentSize.height, value.height(forWidth: valueWidth(width) + Self.slack))
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 10_000)) }
    override func layout() {
        super.layout()
        let l = label.intrinsicContentSize, w = valueWidth(bounds.width), h = value.height(forWidth: w + Self.slack), scale = piScale
        label.frame = CGRect(x: 0, y: PiKit.round((bounds.height - l.height) / 2, scale), width: l.width, height: l.height)
        value.frame = CGRect(x: PiKit.round(bounds.width - w, scale), y: PiKit.round((bounds.height - h) / 2, scale), width: w + Self.slack, height: h)
    }
}

/// A flipped document for a scroll view, so its text starts at the top.
@MainActor final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
