import AppKit
import SwiftUI

/// Reports whether the window this view sits in is actually on screen.
///
/// A panel, sheet or window that is hidden, minimised or fully covered has
/// nothing to show, and nothing that polls for it should keep running: an
/// `NSPopover` retains its SwiftUI content after hiding its panel, a sheet
/// stays mounted over a window the user has sent behind another app, and both
/// used to keep querying SQLite and the helper once a second for a view
/// nobody could see.
@MainActor struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { let view = VisibilityView(); view.onChange = onChange; return view }
    func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }
    /// A torn-down reader is not on screen, and whatever it drives has to be
    /// told so: the popover keeps its controller alive across a hide. The
    /// telling waits for the next turn of the run loop: SwiftUI calls this
    /// from inside its own teardown, and writing the `@State` it is holding
    /// from there is a simultaneous access to that storage — "Fatal access
    /// conflict detected", and the app aborts. Closing the request inspector
    /// did exactly that.
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        let onChange = view.onChange
        view.onChange = nil
        view.stopObserving()
        DispatchQueue.main.async { onChange?(false) }
    }

    @MainActor final class VisibilityView: NSView {
        static let events: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        var onChange: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            if let window {
                for name in Self.events { NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window) }
                // A sheet's own window is what this view sits in; its
                // visibility follows the window it is attached to.
                if let parent = window.sheetParent {
                    for name in Self.events { NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: parent) }
                }
            }
            reportVisibility()
        }
        func stopObserving() { NotificationCenter.default.removeObserver(self) }
        @objc private func windowChanged(_ notification: Notification) { reportVisibility() }
        static func isVisible(_ window: NSWindow?) -> Bool {
            guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
            guard let parent = window.sheetParent else { return true }
            return parent.isVisible && !parent.isMiniaturized
        }
        private func reportVisibility() {
            // Occlusion and miniaturisation are reported before the window
            // settles into the new state; read it on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange?(Self.isVisible(self.window))
            }
        }
    }
}

extension View {
    /// Calls `onChange` whenever this view's window becomes visible or stops
    /// being visible, and with `false` when the view goes away.
    func piWindowVisibility(_ onChange: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: onChange).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
