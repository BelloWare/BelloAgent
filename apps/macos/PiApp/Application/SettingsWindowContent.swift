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
