import SwiftUI
import AppKit

struct WindowActivityGuard: NSViewRepresentable {
    let model: WorkspaceModel
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
        /// True while the explanation below is on screen, so a second close
        /// attempt does not stack another copy of it.
        private var explaining = false
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let visible = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible && $0.sheetParent == nil }.count
            if model.hasActiveWork && visible <= 1 { explain(on: sender); return false }
            return previous?.windowShouldClose?(sender) ?? true
        }
        /// AppKit is inside its own close decision here. A modal run loop would
        /// re-enter window and application callbacks from within this one, so
        /// the refusal is immediate and the reason arrives as a sheet.
        private func explain(on window: NSWindow) {
            guard !explaining, window.attachedSheet == nil else { return }
            explaining = true
            let alert = NSAlert(); alert.messageText = "Work or an unkept side is still open."
            alert.informativeText = "Stop active runs and close or keep their sides before closing the last window. Quit offers an explicit stop-and-discard action."
            alert.addButton(withTitle: "Keep Window Open")
            alert.beginSheetModal(for: window) { [weak self] _ in self?.explaining = false }
        }
    }
}
