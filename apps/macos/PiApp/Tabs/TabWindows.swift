import AppKit
import Combine

// A window tabs were popped out into: its tab strip across the top, beside
// the window's buttons, over the tab shown. ⌘W closes the tab shown, and the
// window with its last tab; the window's own close button closes it and its
// tabs. It is where it was after a relaunch.

@MainActor final class TabWindowController: NSWindowController, NSWindowDelegate {
    let container: TabContainer
    private weak var host: TabHost?
    private var closingForHost = false
    static let defaultSize = NSSize(width: 820, height: 640)

    init(container: TabContainer, host: TabHost, frame: NSRect?, initialSize: NSSize = TabWindowController.defaultSize) {
        self.container = container; self.host = host
        let window = TabWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 280)
        window.backgroundColor = NSColor.piSurfaceSunken
        super.init(window: window)
        window.delegate = self
        window.closeTab = { [weak self] in
            guard let self, let host = self.host else { return false }
            return host.closeShownTab(in: self.container, sideAvailable: false)
        }
        window.contentView = TabWindowRootView(host: host, container: container)
        if let frame { window.setFrame(Self.onScreen(frame), display: false) } else { window.center() }
    }
    required init?(coder: NSCoder) { nil }

    func bringForward() { window?.makeKeyAndOrderFront(nil) }
    func move(topLeftTo point: NSPoint) { window?.setFrameTopLeftPoint(point) }
    /// The host closed the window's last tab: the window goes, and closes no tabs.
    func closeWithoutClosingTabs() {
        closingForHost = true
        window?.close()
    }
    /// A window's frame, its top left where a drag let go of a tab.
    static func frame(topLeft point: NSPoint, size: NSSize = defaultSize) -> NSRect {
        NSRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
    }
    /// A frame kept on a screen: on the screen that shows most of it (else
    /// the main one), no bigger than it, and moved inside it.
    static func onScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        func shown(_ screen: NSRect) -> CGFloat { let part = screen.intersection(frame); return part.isNull ? 0 : part.width * part.height }
        guard let screen = screens.max(by: { shown($0) < shown($1) }).flatMap({ shown($0) > 0 ? $0 : nil }) ?? NSScreen.main?.visibleFrame ?? screens.first else { return frame }
        var fitted = frame
        fitted.size.width = min(max(fitted.width, 420), screen.width)
        fitted.size.height = min(max(fitted.height, 280), screen.height)
        fitted.origin.x = min(max(fitted.minX, screen.minX), screen.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, screen.minY), screen.maxY - fitted.height)
        return fitted
    }

    func windowDidMove(_ notification: Notification) { host?.windowMoved() }
    func windowDidEndLiveResize(_ notification: Notification) { host?.windowMoved() }
    func windowWillClose(_ notification: Notification) {
        guard !closingForHost else { return }
        host?.windowClosed(container)
    }
}

/// ⌘W in a tab window closes the tab it shows, and with its last tab the
/// window; its close button, and the menu's Close, close the window and its
/// tabs, as closing a window does.
final class TabWindow: NSWindow {
    var closeTab: (() -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The tab with focus has its own keys first (a file's ⌘F).
        if TabHost.tabKey(event, in: self) { return true }
        if TabHost.isCloseTabKey(event), closeTab?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A tab window's content: its strip in the title bar's row, beside the
/// window's buttons, over the tab shown.
@MainActor final class TabWindowRootView: NSView {
    let host: TabHost
    let container: TabContainer
    let strip: TabStripView
    private let content = TabContentContainer()
    private var watch: AnyCancellable?
    private var scheduled = false
    init(host: TabHost, container: TabContainer) {
        self.host = host; self.container = container
        strip = TabStripView(host: host, container: container, side: nil, leadingInset: 78)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content); addSubview(strip)
        watch = container.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }
    private func flush() { guard scheduled else { return }; scheduled = false; refresh() }
    private func refresh() {
        if let shown = container.activeTab { content.show(shown, for: container) } else { content.letGo() }
    }
    override func layout() {
        flush()
        super.layout()
        // Under the title bar's row (`.ignoresSafeArea(.container, edges: .top)`).
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabStripView.height)
        content.frame = CGRect(x: 0, y: TabStripView.height, width: bounds.width, height: max(0, bounds.height - TabStripView.height))
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
}

/// Holds a tab's content where it is shown: the report page hides these
/// with the conversations under it (`ConversationPageVisibility`).
final class TabContentContainer: NSView {
    /// Posted, with the window, when a tab's content comes into a window:
    /// what covers native views looks again (`ConversationPageVisibility`).
    static let didAttach = Notification.Name("TabContentContainer.didAttach")
    private weak var shown: HostedTab?
    /// Holding nothing, it takes no clicks: what is under it (the side) does.
    override func hitTest(_ point: NSPoint) -> NSView? { subviews.isEmpty ? nil : super.hitTest(point) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, !subviews.isEmpty { NotificationCenter.default.post(name: Self.didAttach, object: window) }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let window { NotificationCenter.default.post(name: Self.didAttach, object: window) }
    }
    /// Takes a tab's content in, if the tab is the owner's, keeping keyboard
    /// focus in it if it had it where it was.
    @MainActor func show(_ tab: HostedTab, for owner: TabContainer) {
        shown = tab
        guard tab.container === owner else { return }
        let content = tab.contentView
        guard content.superview !== self else { return }
        let hadFocus = tab.takeFocusAfterMove() || (content.window?.firstResponder as? NSView).map { $0 === content || $0.isDescendant(of: content) } == true
        content.removeFromSuperview()
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // Only the tab shown here: one moved in from elsewhere replaces it.
        for other in subviews where other !== content { other.removeFromSuperview() }
        if hadFocus {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // Not into content something has covered since (the report).
                    guard let self, let window = self.window, content.superview === self, !content.isHiddenOrHasHiddenAncestor else { return }
                    window.makeFirstResponder(tab.focusView ?? content)
                }
            }
        }
    }
    /// Lets go of what it holds, if it still holds it.
    @MainActor func letGo() {
        for subview in subviews { subview.removeFromSuperview() }
        shown = nil
    }
}
