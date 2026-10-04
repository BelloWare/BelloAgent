import AppKit

// The kinds of tab with AppKit content subclassed this while the tab host
// took SwiftUI. It does take an NSView now (`HostedTab.makeAppKitContent`);
// the name stays for the kinds until their owners rename it.
typealias AppKitHostedTab = HostedTab
