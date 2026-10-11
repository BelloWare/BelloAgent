import AppKit
import Combine

/// One native status item for production and UI fixtures. Mouse-up actions open
/// immediately for either button; the popover never creates a workspace window.
@MainActor final class MenuBarController: NSObject, ObservableObject {
    static let clickEvents: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let layout = MenuBarPanelLayout()
    private var panel: MenuBarMetricsView?
    /// Builds the panel the first time it opens: nothing it shows is read
    /// until then, and launch does not pay for views no one has looked at.
    private var makePanel: (() -> MenuBarMetricsView)?
    var onOpen: (() -> Void)?
    var isShown: Bool { popover.isShown }
    var isInstalled: Bool { item != nil }

    func install(title: String? = nil, accessibilityLabel: String = "Bello Agent activity and usage", content: @escaping () -> MenuBarMetricsView) {
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
        makePanel = content
    }
    private func preparedPanel() -> MenuBarMetricsView? {
        if panel == nil, let makePanel {
            let panel = makePanel()
            self.panel = panel; self.makePanel = nil
            let controller = NSViewController()
            controller.view = panel
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: MenuBarPanelLayout.width, height: 720)
        }
        return panel
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown { close() }
        else {
            let panel = preparedPanel()
            layout.height = MenuBarPanelLayout.height(available: button.window?.screen?.visibleFrame.height ?? 744)
            panel?.panelHeight = layout.height
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
