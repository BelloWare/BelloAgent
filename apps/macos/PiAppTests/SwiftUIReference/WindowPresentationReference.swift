import AppKit
import SwiftUI
@testable import PiApp

/// The sidebar reserves this row for native traffic lights and window dragging.
/// Conversation/report headers start at the window top alongside it, avoiding
/// an empty full-width strip above the chat title.
struct WindowChromeReference: NSViewRepresentable {
    static let height: CGFloat = 36
    /// Default and bounds of the user-adjustable sidebar.
    static let sidebarWidth: CGFloat = 300
    static let minimumSidebarWidth: CGFloat = 200
    static let maximumSidebarWidth: CGFloat = 420
    static func clampSidebarWidth(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return sidebarWidth }
        return min(maximumSidebarWidth, max(minimumSidebarWidth, value))
    }
    var sidebarWidth: CGFloat = WindowChrome.sidebarWidth
    /// The chat whose composer should receive typing that lands nowhere.
    var focusedSessionID: String? = nil
    /// ⌥← and ⌥→ outside text: a step through an edited message's versions
    /// in that chat. True when the chat had one to step through.
    var stepVersion: (@MainActor (String?, Int) -> Bool)? = nil
    /// ⌘W: closes the tab the window's pane shows, if it shows one. True
    /// when it closed one.
    var closeTab: (@MainActor () -> Bool)? = nil
    /// A key for ⌘P's list while it is up, before anything else: true when
    /// the list took it.
    var quickOpenKey: (@MainActor (NSEvent) -> Bool)? = nil
    func makeCoordinator() -> WindowPresentationController { WindowPresentationController(defaults: .standard) }
    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.controller = context.coordinator
        view.sidebarWidth = sidebarWidth
        return view
    }
    func updateNSView(_ view: WindowChromeView, context: Context) {
        if view.sidebarWidth != sidebarWidth { view.sidebarWidth = sidebarWidth; view.needsDisplay = true }
        context.coordinator.focusedSessionID = focusedSessionID
        context.coordinator.stepVersion = stepVersion
        context.coordinator.closeTab = closeTab
        context.coordinator.quickOpenKey = quickOpenKey
        context.coordinator.attach(view.window, chrome: view)
    }
    static func dismantleNSView(_ view: WindowChromeView, coordinator: WindowPresentationController) { coordinator.detach() }
}


/// Every window of the app wears its own chrome instead of the system title
/// bar. Dropping a `PiWindowBar` into a window's content hides that bar and
/// stands in for it: the strip drags the window, a double click zooms it, and
/// `trafficLightInset` keeps the content clear of the close/minimise/zoom
/// buttons, which stay native. A sheet has no title bar to replace, so the
/// bar leaves sheet windows untouched.
struct PiWindowBarReference: NSViewRepresentable {
    /// Leading room for the native window buttons.
    static let trafficLightInset: CGFloat = 78
    func makeNSView(context: Context) -> PiWindowBarView { PiWindowBarView(frame: .zero) }
    func updateNSView(_ view: PiWindowBarView, context: Context) {}
}

