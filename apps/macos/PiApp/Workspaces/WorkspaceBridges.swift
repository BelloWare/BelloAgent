import SwiftUI

// TEMPORARY: the AppKit sidebar and right pane inside the still-SwiftUI
// workspace view, the resize handle beside the sidebar, and the side pane
// inside the AppKit right pane. They go when `WorkspaceView` and the side
// pane are AppKit.

/// The hairline between sidebar and content doubles as a drag handle, and
/// wears the shared grip so it looks like one.
struct SidebarResizeHandle: View {
    let width: CGFloat
    @Binding var dragging: CGFloat?
    let commit: (CGFloat) -> Void
    @State private var startWidth: CGFloat?
    var body: some View {
        PiResizeHandle(orientation: .vertical, label: "Resize sidebar",
                       hint: "Drag left or right, or press Control-Command-Left and Control-Command-Right",
                       dragging: dragging != nil,
                       changed: { translation in
                           let base = startWidth ?? width
                           if startWidth == nil { startWidth = width }
                           dragging = WindowChrome.clampSidebarWidth(base + translation)
                       },
                       ended: { translation in
                           let landed = WindowChrome.clampSidebarWidth((startWidth ?? width) + translation)
                           startWidth = nil; dragging = nil; commit(landed)
                       })
    }
}

/// `WorkspaceSidebarView` where SwiftUI still lays the window out.
struct WorkspaceSidebar: NSViewRepresentable {
    let model: WorkspaceModel
    var width: CGFloat = WindowChrome.sidebarWidth
    func makeNSView(context: Context) -> WorkspaceSidebarView {
        let view = WorkspaceSidebarView(model: model, width: width)
        view.inheritedEnabled = context.environment.isEnabled
        return view
    }
    func updateNSView(_ view: WorkspaceSidebarView, context: Context) {
        view.width = width
        view.inheritedEnabled = context.environment.isEnabled
    }
}

/// `RightPaneView` where SwiftUI still lays the window out.
struct RightPane: NSViewRepresentable {
    let model: WorkspaceModel
    let host: TabHost
    let pane: TabContainer
    let side: (info: SideRecord, session: SessionDisplay)?
    let width: CGFloat
    /// What the pane shows, read when the workspace view is: a change makes
    /// SwiftUI update the pane in the same pass that decides what it covers
    /// (`ConversationPageVisibility`), so the tab is there for focus to go to.
    private let shown: [String]
    init(model: WorkspaceModel, host: TabHost, pane: TabContainer, side: (info: SideRecord, session: SessionDisplay)?, width: CGFloat) {
        self.model = model; self.host = host; self.pane = pane; self.side = side; self.width = width
        shown = pane.tabs.map(\.id.uuidString) + [pane.shownTab(sideAvailable: side != nil)?.id.uuidString ?? "side"]
    }
    func makeNSView(context: Context) -> RightPaneView {
        let view = RightPaneView(model: model, host: host, pane: pane)
        install(view, enabled: context.environment.isEnabled)
        view.update(side: side, width: width)
        return view
    }
    func updateNSView(_ view: RightPaneView, context: Context) {
        let enabled = context.environment.isEnabled
        let changed = view.inheritedEnabled != enabled
        install(view, enabled: enabled)
        view.update(side: side, width: width, force: changed)
        _ = shown
    }
    /// The side's view made and updated with the window's enabled state now.
    private func install(_ view: RightPaneView, enabled: Bool) {
        view.inheritedEnabled = enabled
        view.makeSideView = { [model] info, session, width in
            let side = SidePaneView(model: model, session: session, info: info, paneWidth: width)
            side.inheritedEnabled = enabled
            return side
        }
        view.updateSideView = { view, info, _, width in
            guard let side = view as? SidePaneView else { return }
            side.update(info: info, paneWidth: width)
            side.inheritedEnabled = enabled
        }
    }
}

/// The sheets the workspace view presents (`piSheetWindow`), now AppKit.
struct RenameChatSheet: View {
    let model: WorkspaceModel
    let chatID: String
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { RenameChatSheetView(model: model, chatID: chatID, dismiss: { dismiss() }) }
            .frame(width: RenameChatSheetView.size.width, height: RenameChatSheetView.size.height)
    }
}
struct TopicSheet: View {
    let model: WorkspaceModel
    let target: TopicEditorTarget
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { TopicSheetView(model: model, target: target, dismiss: { dismiss() }) }
            .frame(width: TopicSheetView.size.width, height: TopicSheetView.size.height)
    }
}
/// An AppKit sheet's view, made once, in a sheet SwiftUI presents.
struct AppKitSheet<Sheet: NSView>: NSViewRepresentable {
    let make: () -> Sheet
    func makeNSView(context: Context) -> Sheet {
        let view = make()
        (view as? InheritsEnabled)?.inheritedEnabled = context.environment.isEnabled
        return view
    }
    func updateNSView(_ view: Sheet, context: Context) { (view as? InheritsEnabled)?.inheritedEnabled = context.environment.isEnabled }
}
struct WebhookPreviewSheet: View {
    let model: WorkspaceModel
    let chatID: String
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { WebhookPreviewSheetView(model: model, chatID: chatID, dismiss: { dismiss() }) }
            .frame(width: WebhookPreviewSheetView.size.width, height: WebhookPreviewSheetView.size.height)
    }
}

/// Presents an AppKit sheet's view in the app's sheet window, which still
/// takes SwiftUI content (`PiSheetWindow`, Application/).
@MainActor enum AppKitSheets {
    static func present(on parent: NSWindow, size: NSSize, enabled: Bool = true, make: @escaping (_ dismiss: @escaping () -> Void) -> NSView) -> PiSheetWindow {
        weak var shown: PiSheetWindow?
        let close: @MainActor () -> Void = { shown?.end(animated: true, requested: true) }
        let sheet = PiSheetWindow(content: AnyView(AppKitSheet { make(close) }.frame(width: size.width, height: size.height)),
                                  inherited: PiSheetWindowInherited(reduceMotion: PiKit.Motion.reduced, enabled: enabled), close: close)
        shown = sheet
        sheet.present(on: parent)
        return sheet
    }
}
