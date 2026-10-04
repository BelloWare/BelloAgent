import AppKit
import Combine

// The sides panel: the open chat's sides at the window's right edge, beside
// the side pane where a side is shown, so switching between them does not
// take the pointer across the window to the sidebar. The sidebar still lists
// every side.
//
// It hides until the pointer rests at the window's right edge, then slides
// in over the conversation as an overlay, so nothing under it moves; it
// slides away once the pointer has left it for the middle of the window.
// Pinned, it stands as a column of its own, docked at the right as the
// sidebar is at the left. docs/Sides-Panel.md.

enum SidesPanelMetrics {
    static let width: CGFloat = 248
    /// The strip of the window's right edge the pointer rests on to bring the
    /// panel. Narrow, so a pointer on the side pane's scroll bar is not on it.
    static let edgeWidth: CGFloat = 3
    /// How long the pointer rests at the edge before the panel comes.
    static let dwell: Duration = .milliseconds(200)
    /// How long the panel stays once the pointer has left it, so crossing
    /// the edge on the way somewhere else does not flicker it.
    static let grace: Duration = .milliseconds(400)
}

/// One row of the panel: a side of the open chat.
struct SidesPanelEntry: Identifiable, Equatable {
    let id: String
    let title: String
    /// Shown in the side pane now.
    let open: Bool
    /// Saved as a chat of its own, with a record and accounting.
    let saved: Bool
}

/// What the handle carries while the panel is hidden: whether a side other
/// than the one on screen is working, has a new reply, or failed.
struct SidesPanelActivity: Equatable {
    var sides = 0
    var working = false
    var unread = false
    var failed = false
}

// MARK: - Coming and going

/// Whether the panel is out, while it is not pinned. The pointer resting at
/// the window's right edge for `dwell` brings it, never while a mouse button
/// is down. While it is out, where the pointer is gets checked every tenth
/// of a second, not left to enter and exit events, which AppKit does not
/// send for a panel that appears under a pointer already there: once the
/// pointer has been off the panel and off the edge for `grace`, it goes.
@MainActor final class SidesPanelReveal: ObservableObject {
    @Published private(set) var shown = false
    var dwell = SidesPanelMetrics.dwell
    var grace = SidesPanelMetrics.grace
    /// How often the pointer is looked for while the panel is out.
    var poll: Duration = .milliseconds(100)
    /// Whether the pointer is on the window's right edge, and on the panel.
    var pointerAtEdge: () -> Bool = { false }
    var pointerOnPanel: () -> Bool = { false }
    /// Whether a mouse button is down: dragging the side pane's scroll bar
    /// to the edge must not bring the panel.
    var buttonsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    private var arriving: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    /// The pointer came to the window's right edge or the handle, or left
    /// one. Leaving one for the other, where they meet, keeps its rest.
    func edge(_ inside: Bool) {
        guard !shown else { return }
        guard inside || pointerAtEdge() else { arriving?.cancel(); arriving = nil; return }
        guard arriving == nil, !buttonsDown() else { return }
        let dwell = dwell
        arriving = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard let self, !Task.isCancelled else { return }
            self.arriving = nil
            if self.pointerAtEdge() && !self.buttonsDown() { self.show() }
        }
    }

    /// Out at once, as when the panel is unpinned under the pointer; it goes
    /// once the pointer has left it, or, `untilHidden`, when `hide` says.
    func show(untilHidden: Bool = false) {
        arriving?.cancel(); arriving = nil
        watching?.cancel(); watching = nil
        if !shown { shown = true }
        if !untilHidden { watch() }
    }
    /// Away at once, as when the panel is pinned.
    func hide() {
        arriving?.cancel(); arriving = nil
        watching?.cancel(); watching = nil
        if shown { shown = false }
    }

    private func watch() {
        watching?.cancel()
        let poll = poll, grace = grace
        watching = Task { [weak self] in
            var away: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard let self, !Task.isCancelled, self.shown else { return }
                if self.pointerOnPanel() || self.pointerAtEdge() { away = nil; continue }
                let now = ContinuousClock.now
                guard let since = away else { away = now; continue }
                if now - since >= grace {
                    self.watching = nil
                    self.shown = false
                    return
                }
            }
        }
    }
}

/// A strip that says when the pointer enters and leaves it, and where the
/// pointer is, without ever taking a click: presses go to whatever is under
/// it, the side pane's scroll bar included.
@MainActor final class SidesPanelPointerView: NSView {
    var changed: @MainActor (Bool) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
    var containsPointer: Bool {
        guard let window, window.isVisible else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

// MARK: - At the edge, while not pinned

/// Where the pointer is, as the edge view's strips answer it.
@MainActor final class SidesPanelProbes {
    var edge: (() -> Bool)?
    var handle: (() -> Bool)?
    var panel: (() -> Bool)?
}

// MARK: - At the edge, while not pinned

/// The panel while it is not pinned: a faint handle at the window's right
/// edge, the strip that brings the panel, and the panel itself when it is
/// out, laid over the conversation. It covers the content column and takes
/// clicks only on the panel.
@MainActor final class SidesPanelEdgeView: NSView {
    let model: WorkspaceModel
    let reveal: SidesPanelReveal
    private(set) var parentID: String
    private let probes = SidesPanelProbes()
    private let edge = SidesPanelPointerView()
    private let handle = SidesPanelHandleView()
    private let handleArea = SidesPanelPointerView()
    private var panel: SidesPanelView?
    private let panelBox = SidesPanelShadowBox()
    private let panelArea = SidesPanelPointerView()
    private var activity = SidesPanelActivity()
    private var shown = false
    private var watching: Set<AnyCancellable> = []
    /// Motion as the window has it.
    var reducesMotion: () -> Bool = { PiKit.Motion.reduced }
    /// The window's disabled state, handed to the panel.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { panel?.inheritedEnabled = inheritedEnabled } } }
    /// Reduced motion as the window has it, handed to the handle and the panel.
    var motionReduced = false {
        didSet { guard oldValue != motionReduced else { return }; handle.motionReduced = motionReduced; panel?.motionReduced = motionReduced }
    }

    init(model: WorkspaceModel, parentID: String, reveal: SidesPanelReveal) {
        self.model = model; self.parentID = parentID; self.reveal = reveal
        super.init(frame: .zero)
        // The strips are in the tree only while what they watch is there.
        for view in [panelBox, edge] as [NSView] { addSubview(view) }
        panelBox.isHidden = true
        edge.changed = { [weak reveal] inside in reveal?.edge(inside) }
        handleArea.changed = { [weak self] inside in self?.handle.hovered = inside; self?.reveal.edge(inside) }
        probes.edge = { [weak edge] in edge?.containsPointer ?? false }
        probes.handle = { [weak self] in guard let self, self.handleArea.superview != nil else { return false }; return self.handleArea.containsPointer }
        probes.panel = { [weak self] in guard let self, self.shown else { return false }; return self.panelArea.containsPointer }
        // `.onAppear`: the reveal asks these strips where the pointer is.
        reveal.pointerAtEdge = { [probes] in probes.edge?() == true || probes.handle?() == true }
        reveal.pointerOnPanel = { [probes] in probes.panel?() == true }
        activity = model.sidesPanelActivity(of: parentID)
        reveal.$shown.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.apply(animated: true) }.store(in: &watching)
        model.activityChanged.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.activityChanged() }.store(in: &watching)
        setAccessibilityElement(false)
        apply(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    /// Clicks reach the panel; everything else goes through to what is under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, !panelBox.isHidden else { return nil }
        let local = convert(point, from: superview)
        return panelBox.frame.contains(local) ? panelBox.hitTest(convert(local, to: panelBox.superview)) : nil
    }

    /// Another chat beside the edge (`.onChange(of: parentID)`).
    func show(parentID: String) {
        guard parentID != self.parentID else { return }
        self.parentID = parentID
        activity = model.sidesPanelActivity(of: parentID)
        panel?.parentID = parentID
        apply(animated: false)
    }
    private func activityChanged() {
        let next = model.sidesPanelActivity(of: parentID)
        guard next != activity else { return }
        activity = next
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        handle.activity = activity
        let wantsPanel = reveal.shown
        let showsHandle = !wantsPanel && activity.sides > 0
        if (handle.superview != nil) != showsHandle {
            if showsHandle {
                addSubview(handle, positioned: .below, relativeTo: panelBox); addSubview(handleArea, positioned: .below, relativeTo: panelBox)
                if animated, !reducesMotion() { PiKit.fadeIn(handle, duration: PiKit.Motion.quick) }
            } else { handle.removeFromSuperview(); handleArea.removeFromSuperview(); handle.hovered = false }
        }
        guard wantsPanel != shown else { needsLayout = true; return }
        shown = wantsPanel
        if wantsPanel {
            if panel == nil {
                let view = SidesPanelView(model: model, parentID: parentID, pinned: false)
                view.inheritedEnabled = inheritedEnabled
                view.motionReduced = motionReduced
                panelBox.addSubview(panelArea)
                panelBox.addSubview(view)
                panel = view
            }
            panel?.parentID = parentID
            panelBox.isHidden = false
            layoutSubtreeIfNeeded()
            slide(in: true, animated: animated)
        } else {
            slide(in: false, animated: animated)
        }
        needsLayout = true
    }
    /// In from the trailing edge and back out (`.transition(.move(edge: .trailing))`, `PiMotion.glide`).
    private func slide(in arriving: Bool, animated: Bool) {
        guard let layer = panelBox.layer else { panelBox.isHidden = !arriving; return }
        let width = panelBox.frame.width + 40
        guard animated, window != nil, !reducesMotion() else {
            layer.removeAnimation(forKey: "slide")
            panelBox.isHidden = !arriving
            if !arriving { dropPanel() }
            return
        }
        let move = PiKit.Motion.glide("transform.translation.x")
        move.fromValue = arriving ? width : 0; move.toValue = arriving ? 0 : width
        move.fillMode = .both; move.isRemovedOnCompletion = arriving
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !arriving, !self.shown else { return }
            self.panelBox.isHidden = true; self.panelBox.layer?.removeAnimation(forKey: "slide"); self.dropPanel()
        }
        layer.add(move, forKey: "slide")
        CATransaction.commit()
    }
    /// The panel goes once it has left (`if reveal.shown { … }`): made again when it next comes.
    private func dropPanel() { panel?.removeFromSuperview(); panel = nil; panelArea.removeFromSuperview() }

    override func layout() {
        super.layout()
        edge.frame = CGRect(x: bounds.width - SidesPanelMetrics.edgeWidth, y: 0, width: SidesPanelMetrics.edgeWidth, height: bounds.height)
        let size = handle.intrinsicContentSize
        let inset = SidesPanelHandleView.inset
        handle.frame = CGRect(x: bounds.width - inset - size.width, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
        handleArea.frame = handle.frame.insetBy(dx: -4, dy: -4)
        panelBox.frame = CGRect(x: bounds.width - SidesPanelMetrics.width, y: 0, width: SidesPanelMetrics.width, height: bounds.height)
        panelArea.frame = panelBox.bounds
        panel?.frame = panelBox.bounds
    }
}

/// The panel's lift over the conversation: a strong hairline at its leading
/// edge, a close shadow and a wide one.
@MainActor final class SidesPanelShadowBox: NSView {
    private let line = CALayer()
    private let near = CALayer(), far = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [far, near] { layer?.addSublayer(shadow) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); if let layer { layer.addSublayer(line); line.zPosition = 10 } }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        for (shadow, radius, x) in [(near, CGFloat(2), CGFloat(-1)), (far, CGFloat(24), CGFloat(-8))] {
            shadow.frame = bounds
            shadow.shadowPath = CGPath(rect: bounds, transform: nil)
            shadow.shadowRadius = radius / 2 * 2; shadow.shadowOffset = CGSize(width: x, height: 0); shadow.shadowOpacity = 1
        }
        CATransaction.commit()
        apply()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }
    private func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.backgroundColor = NSColor.piHairlineStrong.cgColor
            near.shadowColor = NSColor.piShadow.cgColor; far.shadowColor = NSColor.piShadow.cgColor
        }
    }
}

/// A thin grip at the window's right edge while the panel is hidden,
/// carrying the ring of a side that is working or the dot of a new reply.
/// Resting the pointer on it brings the panel, as resting it on the edge
/// does; it takes no clicks, so nothing under it stops working.
@MainActor final class SidesPanelHandleView: NSView {
    var activity = SidesPanelActivity() { didSet { if oldValue != activity { apply() } } }
    var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            PiKit.Motion.layers(PiKit.Motion.quick, .easeInOut, animated: window != nil && !motionReduced) { grip.opacity = hovered ? 0.8 : 0.45 }
        }
    }
    /// Reduced motion as the window has it: the ring stands still.
    var motionReduced = false { didSet { if oldValue != motionReduced { spinner?.configure(lineWidth: 1.4, turning: !(motionReduced || PiKit.Motion.reduced)) } } }
    /// Clear of the side pane's scroll bar when the system shows scroll bars
    /// all the time; against the edge when they only show while scrolling.
    static var inset: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 3 : 3
    }
    private let grip = CALayer()
    private var spinner: PiSpinnerView?
    private let dot = UnreadDotView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(grip)
        grip.cornerRadius = 2; grip.cornerCurve = .continuous; grip.opacity = 0.45
        addSubview(dot)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("sidesPanelHandle")
        dot.setAccessibilityElement(false)
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var markSize: CGSize? {
        if activity.working { return CGSize(width: 9, height: 9) }
        if activity.failed || activity.unread { return CGSize(width: UnreadDotView.size, height: UnreadDotView.size) }
        return nil
    }
    override var intrinsicContentSize: NSSize {
        let mark = markSize
        return NSSize(width: max(4, mark?.width ?? 0), height: 34 + (mark.map { $0.height + 6 } ?? 0))
    }
    private func apply() {
        if activity.working, spinner == nil {
            let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
            view.configure(lineWidth: 1.4, turning: !(motionReduced || PiKit.Motion.reduced))
            view.setAccessibilityElement(false)
            addSubview(view); spinner = view
        } else if !activity.working, let spinner { spinner.removeFromSuperview(); self.spinner = nil }
        dot.isHidden = activity.working || !(activity.failed || activity.unread)
        dot.failure = activity.failed
        setAccessibilityLabel(label)
        invalidateIntrinsicContentSize(); needsLayout = true
        superview?.needsLayout = true
    }
    private var label: String {
        let count = "\(activity.sides) side\(activity.sides == 1 ? "" : "s")"
        if activity.working { return count + ", one working. Rest the pointer on the window's right edge to show them." }
        if activity.unread { return count + ", one with a new reply. Rest the pointer on the window's right edge to show them." }
        return count + ". Rest the pointer on the window's right edge to show them."
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let mark = markSize {
            let frame = CGRect(x: PiKit.round((bounds.width - mark.width) / 2, piScale), y: 0, width: mark.width, height: mark.height)
            spinner?.frame = frame; dot.frame = frame
            y = mark.height + 6
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grip.frame = CGRect(x: PiKit.round((bounds.width - 4) / 2, piScale), y: y, width: 4, height: 34)
        CATransaction.commit()
        updateLayer()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { grip.backgroundColor = piCGColor(.piInkTertiary) }
}

// MARK: - The panel

/// The open chat's sides: New side first, then each side with its mark, its
/// title and what it last did, the one in the side pane highlighted. Pinned,
/// it is a column of the window; otherwise it lies over the conversation.
@MainActor final class SidesPanelView: NSView {
    let model: WorkspaceModel
    var parentID: String? { didSet { if oldValue != parentID { refresh() } } }
    let pinned: Bool
    private let heading = PiKit.TextLine(PiKit.Line("Sides", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.5, uppercased: true))
    private let count = PiKit.TextLine()
    let pin: PiKit.IconButton
    private let header: ShellStack
    private let subtitle = PiKit.TextLine()
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    private let column = ShellStack(.vertical, spacing: 2, padding: NSEdgeInsets(top: 0, left: PiSpacing.sm, bottom: PiSpacing.md, right: PiSpacing.sm))
    private let glide = PiKit.SelectionGlide()
    let newSide: PiKit.SelectableRow
    private let empty = PiKit.TextLine(PiKit.Line("Open a chat to see its sides.", font: PiKit.Font.caption, color: .piInkTertiary))
    private lazy var emptyRow = ShellStack(.vertical, padding: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10), [.view(empty, .flexible)])
    private var rows: [String: SidesPanelRowView] = [:]
    private var observer: ShellObserver!
    private var watched: [ObjectIdentifier] = []
    private var shown: [SidesPanelRowView.Content]?
    private var shownParent: String??
    private var clipWatcher: ShellClipWatcher?
    /// Reduced motion as the window has it: the rows' rings stand still.
    var motionReduced = false {
        didSet { guard oldValue != motionReduced else { return }; for row in rows.values { row.motionReduced = motionReduced } }
    }
    /// The window's disabled state: the pin, New side and the rows go quiet with it.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { shownParent = nil; refresh() } } }

    init(model: WorkspaceModel, parentID: String?, pinned: Bool) {
        self.model = model; self.parentID = parentID; self.pinned = pinned
        pin = PiKit.IconButton(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin the sides panel" : "Pin the sides panel open",
                               tone: pinned ? .accent : .neutral, size: 24, filled: pinned)
        header = ShellStack(.horizontal, spacing: 4, padding: NSEdgeInsets(top: 10, left: PiSpacing.lg, bottom: 0, right: PiSpacing.sm),
                            [.view(heading), .view(count), .spacer(8), .view(pin)])
        let plus = PiKit.SymbolView(PiKit.Symbol("plus", size: 11, weight: .semibold), color: .piAccent)
        let words = PiKit.TextLine(PiKit.Line("New side", font: .systemFont(ofSize: 13, weight: .medium), color: .piAccent))
        newSide = PiKit.SelectableRow(content: ShellStack(.horizontal, spacing: 9, [.view(plus, .fixed(16)), .view(words, .flexible), .spacer(0)]))
        super.init(frame: .zero)
        wantsLayer = true
        pin.setAccessibilityIdentifier("sidesPanelPin")
        pin.onPress = { [weak self] in guard let self else { return }; self.model.setSidesPanelPinned(!self.pinned) }
        newSide.toolTip = "Open a new side conversation beside this chat"
        newSide.setAccessibilityIdentifier("sidesPanelNewSide")
        newSide.onPress = { [weak self] in guard let self, let parentID = self.parentID else { return }; self.model.openSideFromSidesPanel(parentID: parentID) }
        count.line = PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary)
        subtitle.truncation = .end
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        clipWatcher = ShellClipWatcher(scroll, owner: self)
        document.addSubview(column)
        for view in [header, subtitle, scroll] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Sides"); setAccessibilityIdentifier("sidesPanel")
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model)
        observer.observe(publisher: SidebarMinute.shared.$tick.dropFirst())
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }

    func refresh() {
        let entries = parentID.map { model.sidesPanelEntries(of: $0) } ?? []
        count.isHidden = entries.isEmpty
        count.line = PiKit.Line("\(entries.count)", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary)
        if let title = parentID.flatMap({ model.record($0)?.title }) {
            subtitle.isHidden = false
            subtitle.line = PiKit.Line("of “\(title)”", font: PiKit.Font.caption, color: .piInkTertiary)
            subtitle.toolTip = title
        } else { subtitle.isHidden = true }
        newSide.isEnabled = inheritedEnabled && (parentID.map { model.canOpenSide($0) && !model.installPreparing } ?? false)
        pin.isEnabled = inheritedEnabled
        // Each live side's page and figures are watched while it is listed.
        let now = SidebarMinute.shared.now
        var contents: [SidesPanelRowView.Content] = []
        var objects: [ObjectIdentifier] = []
        var watch: [() -> Void] = []
        for entry in entries {
            let unread = model.unreadOutputCount(sessionID: entry.id) > 0, failed = model.unreadFailure(sessionID: entry.id)
            var stats: ChatRowStats
            if let display = model.displays[entry.id] {
                let footer = display.footer
                stats = ChatRowStats(totals: footer.gateway, timing: footer.timing, now: now)
                stats.updateActivity(state: display.state, loading: display.loading, activity: display.activity)
                if let at = display.messages.last(where: { $0.at != nil })?.at { stats.noteActivity(max(stats.lastActivity ?? 0, at / 1_000), now: now) }
                objects += [ObjectIdentifier(display), ObjectIdentifier(footer)]
                watch.append { [weak self] in self?.observer.observe(display); self?.observer.observe(footer) }
            } else {
                let accounting = model.chatAccounting.row(for: entry.id)
                stats = ChatRowStats(totals: accounting.totals, now: now)
                objects.append(ObjectIdentifier(accounting))
                watch.append { [weak self] in self?.observer.observe(accounting) }
            }
            contents.append(SidesPanelRowView.Content(entry: entry, stats: stats, unread: unread, failed: failed, enabled: inheritedEnabled))
        }
        if objects != watched {
            watched = objects
            observer.reset()
            observer.observe(model)
            observer.observe(publisher: SidebarMinute.shared.$tick.dropFirst())
            for start in watch { start() }
        }
        guard contents != shown || shownParent != .some(parentID) else { return }
        shown = contents; shownParent = .some(parentID)
        var items: [ShellItem] = []
        if parentID != nil {
            items.append(.view(newSide, .fill))
            let ids = Set(contents.map(\.entry.id))
            for id in rows.keys where !ids.contains(id) { rows[id] = nil }
            for content in contents {
                let row = rows[content.entry.id] ?? SidesPanelRowView(model: model, glide: glide)
                rows[content.entry.id] = row
                row.motionReduced = motionReduced
                row.update(content)
                items.append(.view(row, .fill))
            }
        } else {
            rows.removeAll()
            items.append(.view(emptyRow, .fill))
        }
        column.items = items
        column.relayoutAll(); header.relayoutAll()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let headerHeight = header.height(forWidth: bounds.width)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        var y = headerHeight
        if !subtitle.isHidden {
            let size = subtitle.intrinsicContentSize
            // `.padding(.horizontal, lg).padding(.top, 1).padding(.bottom, sm)`
            subtitle.frame = CGRect(x: PiSpacing.lg, y: y + 1, width: min(size.width, bounds.width - 2 * PiSpacing.lg), height: size.height)
            y += 1 + size.height + PiSpacing.sm
        }
        scroll.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        scroll.shellFit(document) { column.height(forWidth: $0) }
        column.frame = document.bounds
    }
}

/// One side: its mark (a ring while it works, the orange dot of a new reply,
/// the red one of a failure, else a quiet dot), its title, and what it is
/// doing or when it last did anything.
@MainActor final class SidesPanelRowView: NSView, PiKit.WidthSizing {
    /// What a row shows, and only that: a change elsewhere in the side's
    /// figures leaves the row alone.
    struct Content: Equatable {
        var entry: SidesPanelEntry
        var unread: Bool
        var failed: Bool
        var working: Bool
        var lead: String?
        var leadColor: NSColor?
        var recency: String?
        var enabled: Bool
        @MainActor init(entry: SidesPanelEntry, stats: ChatRowStats, unread: Bool, failed: Bool, enabled: Bool) {
            self.entry = entry; self.unread = unread; self.failed = failed; self.enabled = enabled
            working = stats.busy || stats.loading
            let lead = SidesPanelRowWords.lead(stats: stats, working: working, unread: unread, failed: failed)
            self.lead = lead?.text; leadColor = lead?.color
            recency = stats.recencyLabel
        }
        /// What VoiceOver reads for the row.
        var spoken: String {
            [entry.title, lead, recency ?? (lead == nil ? (entry.saved ? "Saved" : "Not saved yet") : nil)].compactMap { $0 }.joined(separator: ", ")
        }
    }
    let model: WorkspaceModel
    let row: PiKit.SelectableRow
    private let words = SidesPanelRowWords()
    private(set) var content: Content?
    var motionReduced: Bool { get { words.motionReduced } set { words.motionReduced = newValue } }
    init(model: WorkspaceModel, glide: PiKit.SelectionGlide) {
        self.model = model
        row = PiKit.SelectableRow(content: words, glide: glide)
        super.init(frame: .zero)
        addSubview(row)
        row.setAccessibilityIdentifier("sidesPanelRow")
        row.onPress = { [weak self] in
            guard let self, let id = self.content?.entry.id else { return }
            let model = self.model
            Task { await model.openFromSidesPanel(id) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(_ new: Content) {
        guard new != content else { return }
        content = new
        words.update(new)
        row.selected = new.entry.open
        row.toolTip = new.entry.title
        row.setAccessibilityLabel(new.spoken)
        if row.isEnabled != new.enabled { row.isEnabled = new.enabled }
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 232)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); row.frame = bounds }
}

/// A side row's mark and words (`HStack(alignment: .top, spacing: 9)`).
@MainActor final class SidesPanelRowWords: NSView, PiKit.WidthSizing {
    private var spinner: PiSpinnerView?
    private let dot = UnreadDotView()
    private let quiet = CALayer()
    private let title = ShellText("", font: .systemFont(ofSize: 13), color: .piInk, maximumLines: 2)
    private let detail = ShellText("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkTertiary, maximumLines: 1)
    private var content: SidesPanelRowView.Content?
    /// Reduced motion as the window has it: the ring stands still.
    var motionReduced = false { didSet { if oldValue != motionReduced { spinner?.configure(lineWidth: 1.6, turning: !(motionReduced || PiKit.Motion.reduced)) } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(quiet)
        quiet.cornerRadius = 3
        addSubview(dot); addSubview(title); addSubview(detail)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ content: SidesPanelRowView.Content) {
        self.content = content
        if content.working, spinner == nil {
            let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
            view.configure(lineWidth: 1.6, turning: !(motionReduced || PiKit.Motion.reduced))
            view.setAccessibilityElement(false)
            addSubview(view); spinner = view
        } else if !content.working, let spinner { spinner.removeFromSuperview(); self.spinner = nil }
        dot.isHidden = content.working || !(content.failed || content.unread)
        dot.failure = content.failed
        quiet.isHidden = content.working || content.failed || content.unread
        title.font = .systemFont(ofSize: 13, weight: content.entry.open || content.unread ? .semibold : .regular)
        title.set(content.entry.title, color: .piInk)
        var runs: [ShellText.Run] = []
        if let lead = content.lead { runs.append(ShellText.Run(text: lead, color: content.leadColor ?? .piInkTertiary, weight: .medium)) }
        if let recency = content.recency { runs.append(ShellText.Run(text: (content.lead == nil ? "" : " · ") + recency, color: .piInkTertiary)) }
        else if content.lead == nil { runs.append(ShellText.Run(text: content.entry.saved ? "Saved" : "Not saved yet", color: .piInkTertiary)) }
        detail.runs = runs
        needsLayout = true; updateLayer()
    }
    /// What the side is doing, in the sidebar's words, then how long ago it last did anything.
    static func lead(stats: ChatRowStats, working: Bool, unread: Bool, failed: Bool) -> (text: String, color: NSColor)? {
        if working { return (PiSessionState.label(stats.state, loading: stats.loading), .piWarning) }
        if RunState(rawValue: stats.state).isStopped {
            return (PiSessionState.label(stats.state, costLimited: stats.costLimited),
                    RunState(rawValue: stats.state) == .paused ? .piInfo : stats.costLimited ? .piWarning : .piDanger)
        }
        if failed { return ("Failed", .piDanger) }
        if unread { return ("New reply", .piAccent) }
        return nil
    }
    /// The mark, the stack's gap, the words, and the gap before the
    /// `Spacer(minLength: 0)` that ends the row.
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 16 - 9 - 9) }
    func height(forWidth width: CGFloat) -> CGFloat {
        let text = title.height(forWidth: textWidth(width)) + 2 + detail.height(forWidth: textWidth(width))
        return max(17, text)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 212)) }
    override var fittingSize: NSSize { NSSize(width: bounds.width, height: height(forWidth: bounds.width > 0 ? bounds.width : 212)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        // The mark in a 16-point square, a point down.
        let box = CGRect(x: 0, y: 1, width: 16, height: 16)
        spinner?.frame = CGRect(x: box.midX - 5.5, y: box.midY - 5.5, width: 11, height: 11)
        dot.frame = CGRect(x: box.midX - UnreadDotView.size / 2, y: box.midY - UnreadDotView.size / 2, width: UnreadDotView.size, height: UnreadDotView.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        quiet.frame = CGRect(x: box.midX - 3, y: box.midY - 3, width: 6, height: 6)
        CATransaction.commit()
        let width = textWidth(bounds.width)
        let titleHeight = title.height(forWidth: width)
        title.frame = CGRect(x: 16 + 9, y: 0, width: width, height: titleHeight)
        detail.frame = CGRect(x: 16 + 9, y: titleHeight + 2, width: width, height: detail.height(forWidth: width))
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { quiet.backgroundColor = piCGColor(NSColor.piInkTertiary.withAlphaComponent(0.5)) }
}


// MARK: - What the panel lists, and what it does

extension WorkspaceModel {
    /// The open chat's sides as the panel lists them, in the sidebar's order:
    /// its saved sides, and the one beside it first while it is not saved yet.
    func sidesPanelEntries(of parentID: String) -> [SidesPanelEntry] {
        let shown = sides[parentID]
        var entries = chats
            .filter { $0.parentSessionID == parentID && !$0.isBackgroundTask && (!$0.isArchived || $0.id == shown?.id) }
            .sorted(by: ChatRecord.sidebarPrecedes)
            .map { SidesPanelEntry(id: $0.id, title: $0.title, open: $0.id == shown?.id, saved: true) }
        if let shown, !entries.contains(where: { $0.id == shown.id }) {
            entries.insert(SidesPanelEntry(id: shown.id, title: shown.pending ? "New side" : "Side conversation", open: true, saved: false), at: 0)
        }
        return entries
    }

    /// Whether the panel has anything to offer beside this chat: sides of
    /// its own, or a new one.
    func sidesPanelAvailable(for parentID: String) -> Bool {
        canOpenSide(parentID) || !sidesPanelEntries(of: parentID).isEmpty
    }

    /// What the handle carries: the sides other than the one on screen that
    /// are working, have a new reply, or failed.
    func sidesPanelActivity(of parentID: String) -> SidesPanelActivity {
        let entries = sidesPanelEntries(of: parentID)
        var activity = SidesPanelActivity(sides: entries.count)
        for entry in entries where !entry.open {
            if let display = displays[entry.id], display.busy || display.loading { activity.working = true }
            if unreadOutputCount(sessionID: entry.id) > 0 { activity.unread = true }
            if unreadFailure(sessionID: entry.id) { activity.failed = true }
        }
        return activity
    }

    /// A side chosen in the panel. It opens in the side pane, as one chosen
    /// in the sidebar does, and nothing in the sidebar unfolds for it.
    func openFromSidesPanel(_ id: String) async {
        await openFromSidebar(id)
    }

    /// New side, from the panel. Pinned, the panel stays beside the Usage
    /// Report and Background Requests too; the side opens on the chats page,
    /// as a side chosen in the panel does, not behind the page on screen.
    func openSideFromSidesPanel(parentID: String) {
        if page != .chats { page = .chats }
        openSide(parentID: parentID)
    }

    /// Pinned, the panel is a column of the window; unpinned under the
    /// pointer, it stays out over the conversation until the pointer leaves.
    func setSidesPanelPinned(_ pinned: Bool) {
        guard sidesPanelPinned != pinned else { return }
        sidesPanelPinned = pinned
        if pinned { sidesPanelReveal.hide() } else { sidesPanelReveal.show() }
    }
}
