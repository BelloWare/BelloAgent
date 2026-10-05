import AppKit
import SwiftUI
@testable import PiApp

/// The workspace window's content, where the SwiftUI scene asks for it.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    init(model: WorkspaceModel) { self.model = model }
    var body: some View {
        Root(model: model)
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 920, minHeight: 600)
    }
    private struct Root: NSViewRepresentable {
        let model: WorkspaceModel
        func makeNSView(context: Context) -> WorkspaceRootView {
            let view = WorkspaceRootView(model: model)
            view.inheritedEnabled = context.environment.isEnabled
            view.inheritedReduceMotion = context.environment.piReduceMotion
            return view
        }
        func updateNSView(_ view: WorkspaceRootView, context: Context) {
            view.inheritedEnabled = context.environment.isEnabled
            view.inheritedReduceMotion = context.environment.piReduceMotion
        }
    }
}

