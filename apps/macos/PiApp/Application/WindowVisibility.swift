import AppKit

/// Reports whether a native window and its sheet parent are visible.
@MainActor final class WindowVisibilityView: NSView {
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
