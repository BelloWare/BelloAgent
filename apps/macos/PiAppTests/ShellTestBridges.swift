import AppKit
import SwiftUI
@testable import PiApp

// The shell's AppKit views inside SwiftUI test fixtures that compose them
// with still-SwiftUI parts (the transcript, the metrics footer).

/// The composer card for `session`, as tall as it asks to be.
struct ComposerInputBridge: NSViewRepresentable {
    let model: WorkspaceModel
    let session: SessionDisplay
    var paneWidth: CGFloat = 900
    func makeNSView(context: Context) -> ComposerInputView {
        let view = ComposerInputView(model: model)
        view.paneWidth = paneWidth; view.show(session)
        return view
    }
    func updateNSView(_ view: ComposerInputView, context: Context) { view.paneWidth = paneWidth; view.show(session) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerInputView, context: Context) -> CGSize? {
        let width = proposal.width ?? paneWidth
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// The starter card over an empty chat, at most 560 points wide.
struct StarterPanelBridge: NSViewRepresentable {
    let model: WorkspaceModel
    let chat: ChatRecord
    let sessionID: String
    func makeNSView(context: Context) -> StarterPanelView {
        let view = StarterPanelView()
        view.update(model: model, chat: chat, sessionID: sessionID)
        return view
    }
    func updateNSView(_ view: StarterPanelView, context: Context) { view.update(model: model, chat: chat, sessionID: sessionID) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StarterPanelView, context: Context) -> CGSize? {
        let width = min(StarterPanelView.maximumWidth, proposal.width ?? StarterPanelView.maximumWidth)
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// The sidebar as a test hosts it: the AppKit column for `model`, its
/// filter already typed, every change applied before it returns.
@MainActor func makeSidebar(_ model: WorkspaceModel, width: CGFloat = 280, height: CGFloat = 900, filter: String = "") -> WorkspaceSidebarView {
    let sidebar = WorkspaceSidebarView(model: model, width: width)
    sidebar.frame = CGRect(x: 0, y: 0, width: width, height: height)
    if !filter.isEmpty { sidebar.setFilter(filter) }
    sidebar.settle()
    return sidebar
}

/// A pasteboard holding `items`, as a drag's own pasteboard holds what the
/// dragged rows wrote.
@MainActor func dragPasteboard(_ items: [NSPasteboardItem?]) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("bello-test-drag-" + UUID().uuidString))
    pasteboard.clearContents()
    pasteboard.writeObjects(items.compactMap { $0 })
    return pasteboard
}

/// The terminal panel where a fixture hosts SwiftUI.
struct TerminalPanelBridge: NSViewRepresentable {
    let model: WorkspaceModel
    let workspace: WorkspaceRecord
    func makeNSView(context: Context) -> TerminalPanelView { TerminalPanelView(model: model, workspace: workspace) }
    func updateNSView(_ view: TerminalPanelView, context: Context) { view.workspace = workspace }
}

/// A terminal panel at a fixed height, for a picture of it.
@MainActor final class TerminalParityHolder: NSView, PiKit.WidthSizing {
    let panel: TerminalPanelView
    init(_ panel: TerminalPanelView) { self.panel = panel; super.init(frame: .zero); addSubview(panel) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { 200 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 200) }
    override func layout() { super.layout(); panel.frame = bounds }
}

/// A window of tabs where a fixture hosts SwiftUI.
struct TabWindowRootBridge: NSViewRepresentable {
    let host: TabHost
    let container: TabContainer
    func makeNSView(context: Context) -> TabWindowRootView { TabWindowRootView(host: host, container: container) }
    func updateNSView(_ view: TabWindowRootView, context: Context) {}
}
