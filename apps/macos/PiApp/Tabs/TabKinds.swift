import AppKit

// The kinds of tab the app has, each brought back after a relaunch by its
// own code: a line a kind. A kind of tab is added here and nowhere else in
// the host.

extension TabHost {
    static let registeredKinds: [HostedTab.Type] = [
        FileTab.self,
    ]

    /// ⌘W, and nothing else.
    static func isCloseTabKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "w"
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }
}
