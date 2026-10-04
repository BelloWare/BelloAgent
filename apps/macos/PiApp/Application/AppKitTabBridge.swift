import AppKit
import SwiftUI

// Temporary (0.1.120): a tab's content is still taken as SwiftUI by the tab
// host (`HostedTab.makeContent`), which the workspace-shell port replaces.
// Until then a kind with AppKit content subclasses this, and its view is
// hosted as it is. Delete this file when `HostedTab` takes an `NSView`.

@MainActor class AppKitHostedTab: HostedTab {
    /// The tab's content, made once, when it is first shown.
    func makeAppKitContent() -> NSView { NSView() }
    override func makeContent() -> AnyView { AnyView(AppKitTabContent(view: makeAppKitContent())) }
}

/// An AppKit view kept by its tab, filling what SwiftUI gives it.
private struct AppKitTabContent: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
