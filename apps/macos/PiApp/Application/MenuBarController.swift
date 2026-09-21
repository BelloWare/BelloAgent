import AppKit
import SwiftUI

/// One native status item for production and UI fixtures. Mouse-up actions open
/// immediately for either button; the popover never creates a workspace window.
@MainActor final class MenuBarController: NSObject, ObservableObject {
    static let clickEvents: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let layout = MenuBarPanelLayout()
    var onOpen: (() -> Void)?
    var isShown: Bool { popover.isShown }

    func install<Content: View>(title: String? = nil, accessibilityLabel: String = "Bello Agent activity and usage", @ViewBuilder content: () -> Content) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let title { item.button?.title = title }
        else {
            item.button?.image = NSImage(systemSymbolName: "b.circle", accessibilityDescription: "Bello Agent")
            item.button?.image?.isTemplate = true
        }
        item.button?.setAccessibilityLabel(accessibilityLabel)
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.sendAction(on: Self.clickEvents)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelFrame(layout: layout, content: content()))
        popover.contentSize = NSSize(width: MenuBarPanelLayout.width, height: 720)
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown { close() }
        else {
            layout.height = MenuBarPanelLayout.height(available: button.window?.screen?.visibleFrame.height ?? 744)
            popover.contentSize = NSSize(width: MenuBarPanelLayout.width, height: layout.height)
            onOpen?()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func close() { popover.performClose(nil) }
    /// Same NSStatusBarButton target/action, also used by the fixture toolbar.
    func pressButton() { item?.button?.performClick(nil) }
    func remove() {
        popover.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}
