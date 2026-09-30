import AppKit
import SwiftUI

// A window tabs were popped out into: its tab strip across the top, beside
// the window's buttons, over the tab shown. ⌘W closes the tab shown, and the
// window with its last tab; the window's own close button closes it and its
// tabs. It is where it was after a relaunch.

@MainActor final class TabWindowController: NSWindowController, NSWindowDelegate {
    let container: TabContainer
    private weak var host: TabHost?
    private var closingForHost = false
    static let defaultSize = NSSize(width: 820, height: 640)

    init(container: TabContainer, host: TabHost, frame: NSRect?) {
        self.container = container; self.host = host
        let window = TabWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
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
        window.contentView = NSHostingView(rootView: TabWindowRoot(host: host, container: container).piTabRoot())
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
    static func frame(topLeft point: NSPoint) -> NSRect {
        NSRect(x: point.x, y: point.y - defaultSize.height, width: defaultSize.width, height: defaultSize.height)
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
struct TabWindowRoot: View {
    @ObservedObject var host: TabHost
    @ObservedObject var container: TabContainer
    var body: some View {
        VStack(spacing: 0) {
            TabStrip(host: host, container: container, side: nil, leadingInset: 78)
            if let shown = container.activeTab {
                TabContentHost(tab: shown, owner: container, placement: shown.placement).id(shown.id)
            } else {
                Color.piContent
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.piContent)
    }
}

/// A tab's kept content, in a container of this representable's own, for
/// the pane or window that holds the tab (`owner`): moved in when shown there,
/// and only while the tab is still that pane's or window's, so the pane and a
/// window showing the same tab during a move never take it from each other.
struct TabContentHost: NSViewRepresentable {
    let tab: HostedTab
    let owner: TabContainer
    /// The tab's placement: a move away and back is a change, so the view
    /// SwiftUI kept for it takes the content in again.
    let placement: Int
    func makeNSView(context: Context) -> TabContentContainer {
        let container = TabContentContainer()
        container.show(tab, for: owner)
        return container
    }
    func updateNSView(_ container: TabContentContainer, context: Context) { container.show(tab, for: owner) }
    static func dismantleNSView(_ container: TabContentContainer, coordinator: ()) { container.letGo() }
}

/// Holds a tab's content where it is shown: the report page hides these
/// with the conversations under it (`ConversationPageVisibility`).
final class TabContentContainer: NSView {
    /// Posted, with the window, when a tab's content comes into a window:
    /// what covers native views looks again (`ConversationPageVisibility`).
    static let didAttach = Notification.Name("TabContentContainer.didAttach")
    private weak var shown: HostedTab?
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
