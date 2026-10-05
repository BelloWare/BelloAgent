import AppKit
import Combine

enum MenuBarTab: String, CaseIterable { case live = "Live", usage = "Usage" }

/// The menu bar panel's size: always 480 points wide, as tall as the screen
/// under the status item leaves room for, up to 720.
@MainActor final class MenuBarPanelLayout {
    static let width: CGFloat = 480
    var height: CGFloat = 720
    static func height(available: CGFloat) -> CGFloat { max(1, min(720, available - 24)) }
}

/// The menu bar panel: the app's name and the live state, the live monitor
/// or the usage details, and the ways into the app. Its two tabs keep their
/// own scroll positions; the hidden one leaves the accessibility tree and the
/// key-view loop, and stops reading.
@MainActor final class MenuBarMetricsView: DashView {
    let controller: MenuBarMetricsController
    let monitor: MenuBarMetricsController
    let live: LiveActivityStore
    private let readProjects: () -> [MonitorProject]
    private(set) var tab: MenuBarTab
    private var visible = false
    private let openApp: () -> Void, openReport: () -> Void, quit: () -> Void
    private let openSettings: () -> Void
    /// The panel's height (`\.menuBarHeight`).
    var panelHeight: CGFloat = 720 { didSet { if panelHeight != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }

    private let icon = AppIcon()
    private let title = PiKit.TextLine(PiKit.Line("Bello Agent", font: PiKit.Font.title(18), color: .piInk))
    private lazy var freshness = MonitorFreshness(live: live)
    private let usageCaption = PiKit.TextLine(PiKit.Line("Usage", font: PiKit.Font.caption, color: .piInkSecondary))
    private let gearFace = GearFace()
    private lazy var options: PiKit.MenuControl = PiKit.MenuControl(label: "Monitor options", identifier: "monitorOptions", face: gearFace,
                                                                    onHover: { [weak self] in self?.gearFace.hovering = $0 }) { [weak self] in
        guard let self else { return [] }
        let tab = self.tab
        return [
            PiMenuEntry.button(tab == .live ? "Detailed usage" : "Live monitor") { [weak self] in self?.setTab(tab == .live ? .usage : .live) },
            PiMenuEntry.button("Refresh usage") { [weak self] in if tab == .live { self?.monitor.refresh() } else { self?.controller.refresh() } },
            PiMenuEntry.button("Settings…") { [weak self] in NSApp.activate(ignoringOtherApps: true); self?.openSettings() },
            PiMenuEntry.divider,
            PiMenuEntry.button("Quit Bello Agent") { [weak self] in self?.quit() },
        ]
    }
    private lazy var header = ShellStack(.horizontal, spacing: 10, padding: NSEdgeInsets(top: 13, left: 18, bottom: 13, right: 18),
                                         [.view(icon, .fixed(28)), .view(title), .view(freshness), .view(usageCaption), .spacer(4), .view(options, .fixed(26))])
    private let topRule = DividerView()
    private let liveScroll = NSScrollView()
    private let usageScroll = NSScrollView()
    let liveView: LiveMonitorView
    let usageView: MenuBarUsageView
    private lazy var back = PiKit.Button("Back to live monitor", style: .ghost) { [weak self] in self?.setTab(.live) }
    private lazy var usageColumn = ShellStack(.vertical, spacing: 14, padding: NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18),
                                              [.view(back), .view(usageView, .fill)])
    private lazy var livePadded = ShellStack(.vertical, spacing: 0, padding: NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18), [.view(liveView, .fill)])
    private let bottomRule = DividerView()
    private lazy var openAppButton = PiKit.Button("Open app", symbol: "arrow.up.forward.app", style: .secondary, compact: true) { [weak self] in self?.openApp() }
    private lazy var reportButton = PiKit.Button("Usage report", symbol: "chart.bar", style: .secondary, compact: true) { [weak self] in self?.openReport() }
    private let visibility = WindowVisibilityReader.VisibilityView()
    private var observer: ShellObserver!

    init(load: @escaping MenuBarMetricsLoader, scopedLoad: MenuBarScopedMetricsLoader? = nil, projects: @escaping () -> [MonitorProject] = { [] },
         activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil,
         activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, live: LiveActivityStore? = nil,
         monitorController: MenuBarMetricsController? = nil, usageController: MenuBarMetricsController? = nil, initialTab: MenuBarTab = .live,
         openApp: @escaping () -> Void, openReport: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in },
         openSettings: @escaping () -> Void = { MenuBarMetricsView.openAppSettings() },
         quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        controller = usageController ?? MenuBarMetricsController(load: load)
        monitor = monitorController ?? MenuBarMetricsController(load: load, scopedLoad: scopedLoad, period: .fifteenMinutes, activeSessions: activeSessions,
                                                               activity: activity, activityChanges: activityChanges)
        self.live = live ?? LiveActivityStore()
        tab = initialTab; readProjects = projects
        self.openApp = openApp; self.openReport = openReport; self.quit = quit; self.openSettings = openSettings
        liveView = LiveMonitorView(live: self.live, controller: monitor, openSession: openSession, openApp: openApp)
        usageView = MenuBarUsageView(controller: controller)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarPanelLayout.width, height: 720))
        wantsLayer = true
        for scroll in [liveScroll, usageScroll] {
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
            scroll.horizontalScrollElasticity = .none
        }
        liveScroll.documentView = FlippedDocument(livePadded)
        usageScroll.documentView = FlippedDocument(usageColumn)
        for view in [visibility, header, topRule, liveScroll, usageScroll, bottomRule, openAppButton, reportButton] as [NSView] { addSubview(view) }
        visibility.onChange = { [weak self] value in
            guard let self else { return }
            self.visible = value; self.updateVisibility()
            if value { self.liveView.projects = self.readProjects() }
        }
        setAccessibilityIdentifier("menu-bar-metrics")
        observer = ShellObserver { [weak self] in self?.layoutTabs() }
        applyTab(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: MenuBarPanelLayout.width, height: panelHeight) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.monitorCanvas) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Gone from its window (`.onDisappear`): nothing it shows is read.
        if window == nil { visible = false; updateVisibility() }
    }

    /// The app's Settings, through the app menu's own Settings… item (the
    /// SwiftUI scene answers it; the legacy `showSettingsWindow:` no longer does).
    static func openAppSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: index)
    }

    func setTab(_ value: MenuBarTab) {
        guard tab != value else { return }
        tab = value
        applyTab(animated: true)
        updateVisibility()
    }
    private func applyTab(animated: Bool) {
        freshness.isHidden = tab != .live
        usageCaption.isHidden = tab == .live
        header.relayoutAll()
        // Both stay laid out; the hidden one fades out, takes no clicks, and
        // leaves the accessibility tree and the key-view loop.
        for (scroll, shown) in [(liveScroll, tab == .live), (usageScroll, tab == .usage)] {
            let document = scroll.documentView as? FlippedDocument
            document?.shown = shown
            if animated && !PiKit.Motion.reduced {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = PiKit.Motion.quick
                    context.timingFunction = PiKit.Motion.timing(.easeOut)
                    scroll.animator().alphaValue = shown ? 1 : 0
                }, completionHandler: { document?.finishHiding() })
            } else {
                scroll.alphaValue = shown ? 1 : 0
                document?.finishHiding()
            }
        }
        needsLayout = true
    }
    private func updateVisibility() {
        controller.setVisible(visible && tab == .usage)
        monitor.setVisible(visible && tab == .live)
        live.setVisible(visible && tab == .live)
    }
    private func layoutTabs() { needsLayout = true }

    override func layout() {
        super.layout()
        let width = bounds.width
        visibility.frame = .zero
        let headerHeight = header.height(forWidth: width)
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        topRule.frame = CGRect(x: 0, y: headerHeight, width: width, height: DividerView.thickness)
        let buttonHeight = max(openAppButton.intrinsicContentSize.height, reportButton.intrinsicContentSize.height)
        let footer = buttonHeight + 28
        let contentTop = headerHeight + DividerView.thickness
        let contentHeight = max(0, bounds.height - contentTop - footer - DividerView.thickness)
        for scroll in [liveScroll, usageScroll] {
            scroll.frame = CGRect(x: 0, y: contentTop, width: width, height: contentHeight)
            (scroll.documentView as? FlippedDocument)?.fit(width: scroll.contentSize.width)
        }
        bottomRule.frame = CGRect(x: 0, y: contentTop + contentHeight, width: width, height: DividerView.thickness)
        let half = (width - 28 - 12) / 2
        let y = contentTop + contentHeight + DividerView.thickness + 14
        openAppButton.frame = CGRect(x: 14, y: y, width: half, height: buttonHeight)
        reportButton.frame = CGRect(x: 14 + half + 12, y: y, width: half, height: buttonHeight)
    }

    /// A scroll view's document: one column, as tall as it needs at the
    /// scroll view's width. Hidden, it leaves the accessibility tree and the
    /// key-view loop.
    final class FlippedDocument: DashView {
        let content: NSView
        var shown = true {
            didSet {
                guard shown != oldValue else { return }
                // The hidden tab leaves the key-view loop: its views are hidden
                // (after the fade, so the fade still shows them), and the keys
                // move off it.
                if shown { content.isHidden = false }
                else if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { window?.makeFirstResponder(nil) }
                needsLayout = true
            }
        }
        func finishHiding() { if !shown { content.isHidden = true } }
        init(_ content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override func accessibilityChildren() -> [Any]? { shown ? super.accessibilityChildren() : [] }
        override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }
        override var canBecomeKeyView: Bool { false }
        func fit(width: CGFloat) {
            let height = PiKit.height(of: content, width: width)
            let size = NSSize(width: width, height: max(height, superview?.bounds.height ?? 0))
            if frame.size != size { setFrameSize(size) }
            content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
        override func layout() { super.layout(); fit(width: bounds.width) }
    }

    /// The app's icon at 28 points (`Image(nsImage:).resizable().frame(28, 28)`).
    final class AppIcon: DashView {
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
        override func isAccessibilityElement() -> Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            NSApplication.shared.applicationIconImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        }
    }

    /// The options gear: a 17-point gear, inked and on a circle under the pointer.
    final class GearFace: DashView {
        var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
        override var fittingSize: NSSize { NSSize(width: 26, height: 26) }
        override func draw(_ dirtyRect: NSRect) {
            if hovering { NSColor.piFillStrong.setFill(); NSBezierPath(ovalIn: bounds).fill() }
            PiKit.Symbol("gearshape", size: 17).draw(centredIn: bounds, color: hovering ? .piInk : .piInkSecondary, scale: piScale)
        }
    }
}

/// "Live", "Idle" or "Disconnected", with its dot; the freshness in the help.
@MainActor final class MonitorFreshness: DashView {
    let live: LiveActivityStore
    private var observer: ShellObserver!
    private var state: (color: NSColor, text: String, ink: NSColor) = (.piInkSecondary, "Idle", .piInkSecondary)
    init(live: LiveActivityStore) {
        self.live = live
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(live)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func refresh() {
        let snapshot = live.snapshot
        let next: (NSColor, String, NSColor) = (snapshot.disconnected ? .piWarning : snapshot.counts.total > 0 ? .piSuccess : .piInkSecondary,
                                                snapshot.disconnected ? "Disconnected" : snapshot.counts.total > 0 ? "Live" : "Idle",
                                                snapshot.counts.total > 0 ? .piSuccess : .piInkSecondary)
        toolTip = snapshot.freshnessLabel + ". Local observations, not a gateway health check."
        guard next.1 != state.text || next.0 != state.color || next.2 != state.ink else { return }
        state = next
        setAccessibilityLabel(next.1)
        invalidateIntrinsicContentSize(); needsDisplay = true; PiKit.sizeChanged(self)
    }
    private var line: PiKit.Line { PiKit.Line(state.text, font: PiKit.Font.caption, color: state.ink) }
    override var intrinsicContentSize: NSSize { let text = line.size(scale: piScale); return NSSize(width: 7 + 5 + text.width, height: text.height) }
    override func draw(_ dirtyRect: NSRect) {
        let text = line.size(scale: piScale)
        state.color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 0, y: PiKit.round((bounds.height - 7) / 2, piScale), width: 7, height: 7)).fill()
        line.draw(at: CGPoint(x: 12, y: PiKit.round((bounds.height - text.height) / 2, piScale)), scale: piScale)
    }
}

enum LivePopupSection: CaseIterable { case working, attention, unread }
struct LivePopupRowOrder {
    private(set) var rows: [MenuBarActivityRow] = []
    private(set) var sections: [String: LivePopupSection] = [:]
    mutating func reconcile(_ snapshot: MenuBarActivitySnapshot, held: Set<String>) {
        let candidates = Array(snapshot.runningRows.prefix(12)) + Array(snapshot.attentionRows.prefix(12)) + Array(snapshot.unreadRows.prefix(12))
        let fresh = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        var next: [MenuBarActivityRow] = []
        var locations: [String: LivePopupSection] = [:]
        for old in rows {
            if let row = fresh[old.id] {
                next.append(row); locations[row.id] = held.contains(row.id) ? sections[row.id] : Self.section(row)
            } else if held.contains(old.id) {
                var row = MenuBarActivityRow(id: old.id, title: old.title, workspace: old.workspace, phase: "idle", model: old.model, resolvedModel: old.resolvedModel, tools: [], followUps: 0, steering: 0, unread: 0)
                row.actionable = false
                next.append(row); locations[row.id] = sections[row.id]
            }
        }
        for row in candidates where locations[row.id] == nil { next.append(row); locations[row.id] = Self.section(row) }
        rows = []; sections = [:]
        for section in LivePopupSection.allCases {
            let group = next.filter { locations[$0.id] == section }
            // Keep interacted rows even when new attention arrives; overflow
            // never changes execution admission or hides the navigation action.
            let remaining = max(0, 12 - group.filter { held.contains($0.id) }.count)
            let retained = Set(group.filter { !held.contains($0.id) }.prefix(remaining).map(\.id)).union(held)
            for row in group where retained.contains(row.id) {
                rows.append(row); sections[row.id] = section
            }
        }
    }
    func rows(in section: LivePopupSection) -> [MenuBarActivityRow] { rows.filter { sections[$0.id] == section } }
    private static func section(_ row: MenuBarActivityRow) -> LivePopupSection { row.running ? .working : row.needsAttention ? .attention : .unread }
}
