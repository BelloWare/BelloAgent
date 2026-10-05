import AppKit
import SwiftUI
@testable import PiApp

// Temporary (0.1.120): ⌘P's list is placed over the window by the SwiftUI
// workspace view (`WorkspaceView`), which the workspace-shell port replaces.
// Its content is AppKit (`QuickOpenOverlay`). Delete this file when the
// window's AppKit root places the overlay itself.

/// Puts the list over the window the list took the keys from.
struct QuickOpenLayer: NSViewRepresentable {
    @ObservedObject var quickOpen: QuickOpen
    /// Opens a row's file, or the chosen one's without one.
    let open: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QuickOpenAnchor { QuickOpenAnchor() }
    func updateNSView(_ view: QuickOpenAnchor, context: Context) { context.coordinator.show(quickOpen, open: open) }
    static func dismantleNSView(_ view: QuickOpenAnchor, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var cover: QuickOpenOverlay?
        func show(_ quickOpen: QuickOpen, open: @escaping (String?) -> Void) {
            guard let target = quickOpen.presentationWindow, let content = target.contentView else { close(); return }
            guard window !== target || cover?.superview !== content else { return }
            close()
            let overlay = QuickOpenOverlay(quickOpen: quickOpen, open: open)
            overlay.frame = content.bounds
            overlay.autoresizingMask = [.width, .height]
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
            window = target; cover = overlay
        }
        func close() { cover?.removeFromSuperview(); cover = nil; window = nil }
    }
}

/// The workspace's anchor never takes mouse events from the main window.
final class QuickOpenAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
