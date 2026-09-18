import SwiftUI
import AppKit

struct WindowActivityGuard: NSViewRepresentable {
    @ObservedObject var model: WorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView(); view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }; return view
    }
    func updateNSView(_ view: HookView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }
    final class HookView: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
        override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); PerformanceProbe.shared.shellReady() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: WorkspaceModel
        // NSObject forwarding is nonisolated; AppKit installs/mutates delegates
        // on the main thread. Forwarding only reads this weak reference.
        nonisolated(unsafe) weak var previous: NSWindowDelegate?
        weak var window: NSWindow?
        init(_ model: WorkspaceModel) { self.model = model }
        func attach(_ window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            self.window = window; previous = window.delegate; window.delegate = self
        }
        func detach() { if window?.delegate === self { window?.delegate = previous } }
        nonisolated override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { previous }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let visible = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible && $0.sheetParent == nil }.count
            if model.hasActiveWork && visible <= 1 {
                let alert = NSAlert(); alert.messageText = "Work or an unkept side is still open."
                alert.informativeText = "Stop active runs and close or keep their sides before closing the last window. Quit offers an explicit stop-and-discard action."
                alert.addButton(withTitle: "Keep Window Open"); alert.runModal(); return false
            }
            return previous?.windowShouldClose?(sender) ?? true
        }
    }
}
