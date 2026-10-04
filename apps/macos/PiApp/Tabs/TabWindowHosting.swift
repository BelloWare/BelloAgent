import AppKit
import SwiftUI

// TEMPORARY: a tab window's AppKit root inside a SwiftUI hosting root. The
// tabs' own content is still SwiftUI (files, changes: other workstreams), and
// its focus (`@FocusState`, a file's find field) is only applied in a window
// whose root is a hosting view while that window is not key. It goes when
// the kinds' content is AppKit.

enum TabWindowRootHosting {
    @MainActor static func make(host: TabHost, container: TabContainer) -> NSView {
        NSHostingView(rootView: Root(host: host, container: container).ignoresSafeArea())
    }
    private struct Root: NSViewRepresentable {
        let host: TabHost
        let container: TabContainer
        func makeNSView(context: Context) -> TabWindowRootView { TabWindowRootView(host: host, container: container) }
        func updateNSView(_ view: TabWindowRootView, context: Context) {}
    }
}
