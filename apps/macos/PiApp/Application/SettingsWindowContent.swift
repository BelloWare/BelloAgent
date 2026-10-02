import AppKit
import SwiftUI

/// The Settings window. SwiftUI keeps it after it closes, to show it again,
/// and the form left in it went on redrawing with every change to the model,
/// for the rest of the launch. The form is taken down while the window is
/// closed and put back when it opens; its edits wait in the controller kept
/// here, so a closed window still opens on what the reader left unsaved.
struct SettingsWindowContent: View {
    let model: WorkspaceModel
    @StateObject private var controller: ConnectionSettingsController
    @State private var open = true
    init(model: WorkspaceModel) {
        self.model = model
        _controller = StateObject(wrappedValue: ConnectionSettingsController(model: model))
    }
    var body: some View {
        ZStack { if open { ProfileSettings(model: model, controller: controller, windowChrome: true) } }
            .frame(width: 880, height: 780)
            .background(WindowOpenReader { open = $0 })
            // Outside the form, which is taken down while the window is closed.
            .background(SettingsCloseGuard(controller: controller))
    }
}

/// The Settings window's close button and ⌘W: unsaved edits ask Save All,
/// Discard Changes or Keep Editing first, and a save under way keeps the
/// window open. The window's own delegate (SwiftUI's) still decides after.
@MainActor struct SettingsCloseGuard: NSViewRepresentable {
    let controller: ConnectionSettingsController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView(); view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }; return view
    }
    func updateNSView(_ view: HookView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }
    final class HookView: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let controller: ConnectionSettingsController
        // AppKit sets and reads delegates on the main thread; forwarding only reads this.
        nonisolated(unsafe) weak var previous: NSWindowDelegate?
        weak var window: NSWindow?
        /// The one close this guard has already agreed to, for that window.
        private weak var approved: NSWindow?
        init(_ controller: ConnectionSettingsController) { self.controller = controller }
        func attach(_ window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            detach()
            self.window = window; previous = window.delegate; window.delegate = self
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            window = nil; previous = nil
        }
        nonisolated override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { previous }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approved === sender { approved = nil; return previous?.windowShouldClose?(sender) ?? true }
            // Clean and idle: close as before, without a turn of the run loop.
            if !controller.saving, !controller.deciding, !controller.isDirty { return previous?.windowShouldClose?(sender) ?? true }
            // AppKit is inside its close decision: refuse now, ask on a sheet,
            // and close again once the reader has chosen.
            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender, await self.controller.requestClose(), sender.isVisible else { return }
                self.approved = sender
                sender.performClose(nil)
            }
            return false
        }
    }
}

/// Whether the window this view sits in is open: false once it closes, true
/// again when it is shown. Covered or minimised, a window is still open.
@MainActor struct WindowOpenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> OpenView { let view = OpenView(); view.onChange = onChange; return view }
    func updateNSView(_ view: OpenView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: OpenView, coordinator: ()) { view.onChange = nil; NotificationCenter.default.removeObserver(view) }

    @MainActor final class OpenView: NSView {
        var onChange: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(shown), name: name, object: window)
            }
        }
        // The state is written on the next turn: these arrive inside AppKit's
        // own window handling, and SwiftUI may be mid-update.
        @objc private func closing() { let onChange = onChange; DispatchQueue.main.async { onChange?(false) } }
        @objc private func shown() {
            guard window?.isVisible == true else { return }
            let onChange = onChange; DispatchQueue.main.async { onChange?(true) }
        }
    }
}
