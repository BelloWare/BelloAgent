import SwiftUI

// TEMPORARY: the AppKit sidebar inside the still-SwiftUI workspace view, and
// the resize handle beside it. Both go when `WorkspaceView` is AppKit.

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
