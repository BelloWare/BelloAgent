import AppKit
import Combine

// The strip of tabs over the pane beside the chat, and over each window:
// the chat's side first in the pane, then the tabs. A click shows a tab; its
// close button, a middle click or ⌘W closes it; its menu opens it in a window
// or moves it to the pane. A tab dragged along the strip moves there, onto
// another strip moves there, and let go of anywhere else pops out into a
// window of its own where it was let go of.

/// The chat's side, as the pane's strip shows it.
struct SideTabItem: Equatable {
    let title: String
    let help: String
}

/// What a tab does with the pointer: shown on a click, closed by a middle
/// click, its menu on a secondary click, and dragged.
struct TabItemEvents {
    var select: () -> Void
    var close: (() -> Void)? = nil
    var menu: (() -> [PiMenuEntry])? = nil
    /// What a drag carries: the tab's id; nil for a tab that stays put.
    var drag: (() -> String)? = nil
    /// Let go of outside every strip: a window of its own, there.
    var poppedOut: ((NSPoint) -> Void)? = nil
}

/// The pasteboard type a dragged tab travels as: its id.
extension NSPasteboard.PasteboardType {
    static let belloTab = NSPasteboard.PasteboardType("com.belloware.bello-agent.tab")
}

extension TabHost {
    func tab(withID id: String) -> HostedTab? { allTabs.first { $0.id.uuidString == id } }
}

@MainActor final class TabStripView: NSView {
    let host: TabHost
    let container: TabContainer
    /// The chat's side, in the pane when the chat has one.
    var side: SideTabItem? { didSet { if side != oldValue { refresh() } } }
    /// Room before the first tab: a window's buttons.
    let leadingInset: CGFloat
    static let height: CGFloat = 36
    static let spacing: CGFloat = 3
    private static let sideID = "side"

    private let scroll = NSScrollView()
    private let document = TabStripDocument()
    private let hairline = CALayer()
    private var items: [String: TabStripItemView] = [:]
    private var order: [String] = []
    private var marks: [TabInsertionMarkView] = []
    private var insertion: Int? { didSet { if insertion != oldValue { relayoutItems() } } }
    private var watches: [AnyCancellable] = []
    private var tabWatches: [ObjectIdentifier: AnyCancellable] = [:]
    private var scheduled = false
    private var shownID: String?
    /// The window's disabled state: no tab is chosen, closed or dragged.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { for item in items.values { item.enabled = inheritedEnabled } } } }
    /// What the row was last laid out from, so a change that moves nothing lays out nothing.
    private var laidOut: [String]?

    init(host: TabHost, container: TabContainer, side: SideTabItem?, leadingInset: CGFloat = PiSpacing.sm) {
        self.host = host; self.container = container; self.side = side; self.leadingInset = leadingInset
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        // Under a window's title bar: no inset for it, the strip is its row.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.documentView = document
        addSubview(scroll)
        layer?.addSublayer(hairline)
        registerForDraggedTypes([.belloTab])
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(container.isPane ? "Tabs beside the chat" : "Tabs")
        watches = [host.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } },
                   container.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }]
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }
    func flush() { guard scheduled else { return }; scheduled = false; refresh() }

    private func refresh() {
        let tabs = container.tabs
        let shownTab = container.shownTab(sideAvailable: side != nil)
        let shown = shownTab.map { $0.id.uuidString } ?? (side != nil ? Self.sideID : nil)
        var wanted: [String] = []
        if let side {
            let item = items[Self.sideID] ?? TabStripItemView(closable: false)
            items[Self.sideID] = item
            item.enabled = inheritedEnabled
            item.apply(title: side.title, symbol: "arrow.triangle.branch", help: side.help, selected: shown == Self.sideID)
            item.events = TabItemEvents(select: { [weak host] in host?.showSide() })
            wanted.append(Self.sideID)
        }
        for tab in tabs {
            let id = tab.id.uuidString
            let item = items[id] ?? TabStripItemView(closable: true)
            items[id] = item
            item.enabled = inheritedEnabled
            item.apply(title: tab.title, symbol: tab.symbol, help: tab.help, selected: shown == id)
            item.events = events(for: tab)
            wanted.append(id)
            // The tab's own title and symbol change under it.
            if tabWatches[ObjectIdentifier(tab)] == nil {
                tabWatches[ObjectIdentifier(tab)] = tab.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
            }
        }
        let live = Set(tabs.map(ObjectIdentifier.init))
        for key in tabWatches.keys where !live.contains(key) { tabWatches[key] = nil }
        for (id, item) in items where !wanted.contains(id) { item.removeFromSuperview(); items[id] = nil }
        for id in wanted where items[id]?.superview !== document { document.addSubview(items[id]!) }
        order = wanted
        relayoutItems()
        if shown != shownID {
            shownID = shown
            if let shown { pendingReveal = shown; needsLayout = true }
        }
    }

    private func events(for tab: HostedTab) -> TabItemEvents {
        let host = self.host
        return TabItemEvents(select: { [weak host] in host?.activate(tab) }, close: { [weak host] in host?.close(tab) }, menu: { [weak host] in
            guard let host else { return [] }
            var entries: [PiMenuEntry] = [.button("Close Tab", identifier: "tab-close") { host.close(tab) }]
            if tab.container?.tabs.count ?? 0 > 1 { entries.append(.button("Close Other Tabs", identifier: "tab-close-others") { host.closeOthers(than: tab) }) }
            entries.append(.separator)
            if tab.container?.isPane == true { entries.append(.button("Open in Window", identifier: "tab-pop-out") { host.popOut(tab) }) }
            else { entries.append(.button("Move to Pane", identifier: "tab-to-pane") { host.moveToPane(tab) }) }
            let own = tab.menuEntries()
            if !own.isEmpty { entries.append(.separator); entries.append(contentsOf: own) }
            return entries
        }, drag: { tab.id.uuidString }, poppedOut: { [weak host] point in host?.popOut(tab, at: point) })
    }

    // MARK: Layout

    /// `HStack(spacing: 3)` with the leading inset and eight points after,
    /// the insertion mark (`Capsule` 2 × 20) where a dragged tab would go.
    private func relayoutItems() {
        let key = order.map { id in "\(id):\(items[id]?.preferredWidth ?? 0)" } + ["\(insertion ?? -1)", "\(scroll.bounds.width)", "\(piScale)"]
        guard key != laidOut else { return }
        laidOut = key
        for mark in marks { mark.removeFromSuperview() }
        marks = []
        let scale = piScale
        var x = leadingInset
        let tabsStart = side != nil ? 1 : 0
        for (index, id) in order.enumerated() {
            guard let item = items[id] else { continue }
            if let insertion, index - tabsStart == insertion, index >= tabsStart {
                x = place(mark: x, scale: scale)
            }
            let width = item.preferredWidth
            item.frame = CGRect(x: x, y: PiKit.round((Self.height - TabStripItemView.height) / 2, scale), width: width, height: TabStripItemView.height)
            x += width + Self.spacing
        }
        if let insertion, insertion == order.count - tabsStart { x = place(mark: x, scale: scale) }
        let content = max(0, x - Self.spacing) + PiSpacing.sm
        document.frame = CGRect(x: 0, y: 0, width: max(content, scroll.bounds.width), height: Self.height)
    }
    private func place(mark x: CGFloat, scale: CGFloat) -> CGFloat {
        let mark = TabInsertionMarkView()
        mark.frame = CGRect(x: x, y: PiKit.round((Self.height - 20) / 2, scale), width: 2, height: 20)
        document.addSubview(mark); marks.append(mark)
        return x + 2 + Self.spacing
    }
    private var pendingReveal: String?
    override func layout() {
        flush()
        super.layout()
        scroll.frame = bounds
        relayoutItems()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
        if let reveal = pendingReveal, bounds.width > 0 { pendingReveal = nil; scrollToItem(reveal) }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override func hitTest(_ point: NSPoint) -> NSView? { inheritedEnabled ? super.hitTest(point) : nil }
    /// The shown tab in view (`ScrollViewReader.scrollTo`), as little as it takes.
    private func scrollToItem(_ id: String) {
        guard let item = items[id] else { return }
        let visible = scroll.contentView.bounds
        var origin = visible.origin
        if item.frame.minX < visible.minX { origin.x = item.frame.minX }
        else if item.frame.maxX > visible.maxX { origin.x = item.frame.maxX - visible.width }
        else { return }
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piContent)
        hairline.backgroundColor = piCGColor(.piHairline)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let shownID { pendingReveal = shownID; needsLayout = true }
    }

    // MARK: Taking a dragged tab

    /// Where a tab dropped at a point along the strip goes: before the first
    /// tab whose middle is right of it.
    func index(atWindowX x: CGFloat) -> Int {
        for (index, tab) in container.tabs.enumerated() {
            if let item = items[tab.id.uuidString], x < item.convert(item.bounds, to: nil).midX { return index }
        }
        return container.tabs.count
    }
    private func draggedID(_ sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .belloTab).flatMap { host.tab(withID: $0) != nil ? $0 : nil }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard inheritedEnabled, draggedID(sender) != nil else { insertion = nil; return [] }
        insertion = index(atWindowX: sender.draggingLocation.x)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertion = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { insertion = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertion = nil
        guard inheritedEnabled, let id = draggedID(sender), let tab = host.tab(withID: id) else { return false }
        host.move(tab, to: container, at: index(atWindowX: sender.draggingLocation.x))
        return true
    }
}

/// The strip's scrolling row.
@MainActor final class TabStripDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Where a dragged tab would go.
@MainActor final class TabInsertionMarkView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piAccent); layer?.cornerRadius = 1 }
}

/// One tab: its symbol and title, and for a hosted tab a close button that
/// shows while it is chosen or under the pointer; chosen, it sits on the
/// surface in a strong hairline, under the pointer on a quiet fill.
@MainActor final class TabStripItemView: NSView, NSDraggingSource {
    static let height: CGFloat = 26
    static let maximumWidth: CGFloat = 240
    let closable: Bool
    var events: TabItemEvents?
    /// The window's disabled state: no selection, close or drag, even to VoiceOver.
    var enabled = true { didSet { close.isEnabled = enabled; label.enabled = enabled } }
    private(set) var title = ""
    private var symbol = "doc"
    private(set) var selected = false
    private var hovering = false { didSet { if oldValue != hovering { refreshFace() } } }
    private let fill = CALayer(), stroke = CALayer()
    private let label = TabItemLabelView()
    let close = TabCloseButton()
    private var tracking: NSTrackingArea?
    private var down: NSEvent?

    init(closable: Bool) {
        self.closable = closable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(fill); layer?.addSublayer(stroke)
        addSubview(label)
        if closable {
            addSubview(close)
            close.onPress = { [weak self] in self?.events?.close?() }
            close.toolTip = "Close Tab (⌘W)"
        }
        label.press = { [weak self] in self?.events?.select() }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(title: String, symbol: String, help: String, selected: Bool) {
        let changed = title != self.title || symbol != self.symbol || selected != self.selected
        self.title = title; self.symbol = symbol; self.selected = selected
        toolTip = help.isEmpty ? nil : help
        label.set(title: title, symbol: symbol, selected: selected)
        close.setAccessibilityLabel("Close " + title)
        if changed { measure(); needsLayout = true; refreshFace() }
    }
    private var labelPadding: (leading: CGFloat, trailing: CGFloat) { (10, closable ? 4 : 10) }
    /// Its own width, up to 240 points (`.frame(maxWidth: 240)`), measured
    /// when its title, symbol or weight changes.
    private(set) var preferredWidth: CGFloat = 0
    private func measure() {
        let natural = labelPadding.leading + label.naturalWidth + labelPadding.trailing + (closable ? 16 + 6 : 0)
        preferredWidth = min(Self.maximumWidth, natural)
    }
    override func layout() {
        super.layout()
        let closeRoom: CGFloat = closable ? 16 + 6 : 0
        label.frame = CGRect(x: labelPadding.leading, y: 0, width: max(0, bounds.width - closeRoom - labelPadding.leading - labelPadding.trailing), height: bounds.height)
        if closable { close.frame = CGRect(x: bounds.width - 6 - 16, y: PiKit.round((bounds.height - 16) / 2, piScale), width: 16, height: 16) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds; fill.cornerRadius = 7; fill.cornerCurve = .continuous
        stroke.frame = bounds.insetBy(dx: -0.5, dy: -0.5); stroke.cornerRadius = 7.5; stroke.cornerCurve = .continuous; stroke.borderWidth = 1
        CATransaction.commit()
        refreshFace(animated: false)
    }
    private func refreshFace(animated: Bool = true) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            PiKit.Motion.layers(PiKit.Motion.quick, animated: animated && window != nil) {
                fill.backgroundColor = selected ? NSColor.piSurface.cgColor : hovering ? NSColor.piFill.cgColor : CGColor.clear
                stroke.borderColor = selected ? NSColor.piHairlineStrong.cgColor : CGColor.clear
                close.layer?.opacity = selected || hovering ? 1 : 0
            }
        }
        close.isRevealed = selected || hovering
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshFace(animated: false) }
    /// Widths are rounded to the display's pixels: another display, another width.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        measure()
        var ancestor = superview
        while let view = ancestor, !(view is TabStripView) { ancestor = view.superview }
        ancestor?.needsLayout = true
        label.needsDisplay = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        down = event
        events?.select()
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, let down, let drag = events?.drag else { return }
        let from = down.locationInWindow, to = event.locationInWindow
        guard hypot(to.x - from.x, to.y - from.y) > 4 else { return }
        self.down = nil
        let item = NSPasteboardItem()
        item.setString(drag(), forType: .belloTab)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = Self.image(title: title)
        let at = convert(from, from: nil)
        dragging.setDraggingFrame(NSRect(x: at.x - 12, y: at.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { if enabled { events?.close?() } } else { super.otherMouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard enabled, let entries = events?.menu?(), !entries.isEmpty else { return nil }
        return PiMenus.menu(entries)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Let go of where no strip took it: a window of its own, there. A
        // drag given up with Escape ends with the button still held: it
        // stays where it was.
        if operation == [], NSEvent.pressedMouseButtons & 1 == 0 { events?.poppedOut?(screenPoint) }
    }
    /// What a dragged tab looks like: its title on a raised tab.
    static func image(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.piInk])
        let size = NSSize(width: min(240, ceil(text.size().width) + 24), height: 26)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.piSurface.setFill(); path.fill()
            NSColor.piHairlineStrong.setStroke(); path.stroke()
            text.draw(with: NSRect(x: 12, y: (rect.height - text.size().height) / 2, width: rect.width - 24, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}

/// A tab's symbol and title (`HStack(spacing: 6)`), its title cut in the
/// middle; to VoiceOver a button named by the title, selected while chosen.
@MainActor final class TabItemLabelView: NSView {
    private var title = "", symbol = "doc", selected = false
    var press: (() -> Void)?
    var enabled = true
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var glyph: PiKit.Symbol { PiKit.Symbol(symbol, size: 11, weight: .medium) }
    private var line: PiKit.Line {
        PiKit.Line(title, font: .systemFont(ofSize: 12.5, weight: selected ? .medium : .regular), color: selected ? .piInk : .piInkSecondary)
    }
    func set(title: String, symbol: String, selected: Bool) {
        guard title != self.title || symbol != self.symbol || selected != self.selected else { return }
        self.title = title; self.symbol = symbol; self.selected = selected
        needsDisplay = true
    }
    var naturalWidth: CGFloat { glyph.layoutSize.width + 6 + line.size(scale: piScale).width }
    override func draw(_ dirtyRect: NSRect) {
        let scale = piScale, icon = glyph.layoutSize
        glyph.drawPlaced(centredIn: CGRect(x: 0, y: 0, width: icon.width, height: bounds.height), color: selected ? .piAccent : .piInkTertiary, scale: scale)
        let x = icon.width + 6, size = line.size(scale: scale)
        // Cut in the middle by Core Text, which keeps a letter or so less than `Text` did.
        line.draw(in: CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, scale), width: max(0, bounds.width - x), height: size.height),
                  truncation: .middle, scale: scale)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func isAccessibilitySelected() -> Bool { selected }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; press?(); return true }
}

/// A tab's close button: an `xmark` on a circle that fills under the
/// pointer; a button to the keyboard and VoiceOver, taking clicks only while
/// it shows (the tab chosen or under the pointer).
@MainActor final class TabCloseButton: PiKit.ButtonBase {
    var isRevealed = false
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        pressScales = false
        circularCorners = true
        hitsShapeOnly = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func hitTest(_ point: NSPoint) -> NSView? { isRevealed ? super.hitTest(point) : nil }
    override func drawContent(in rect: CGRect) {
        PiKit.Symbol("xmark", size: 8.5, weight: .bold).drawPlaced(centredIn: rect, color: hovering ? .piInk : .piInkTertiary, scale: piScale)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(hovering ? .piFillStrong : .clear)
        stroke.borderColor = CGColor.clear
    }
    override func setHovering(_ value: Bool) { super.setHovering(value); redrawContent() }
}
