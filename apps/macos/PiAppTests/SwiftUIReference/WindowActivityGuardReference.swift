import SwiftUI
import AppKit
@testable import PiApp

struct WindowActivityGuardReference: NSViewRepresentable {
    let model: WorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView(); view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }; return view
    }
    func updateNSView(_ view: HookView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }
    typealias HookView = PiApp.WindowActivityGuard.HookView
    typealias Coordinator = PiApp.WindowActivityGuard.Coordinator
}
