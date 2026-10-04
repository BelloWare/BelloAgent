import SwiftUI

// TEMPORARY: the SwiftUI pieces the sides panel (still SwiftUI until its own
// batch) and the dashboard's background requests page (another workstream)
// read. The sidebar itself is AppKit; delete this file when both are.

/// A small accent dot marks a chat with replies the user has not viewed.
struct UnreadDot: View {
    /// A run that failed while you were away: marked, but never counted in the Dock badge.
    var failure = false
    var body: some View {
        Circle().fill(failure ? Color.piDanger : Color.piBrandOrange).frame(width: 7, height: 7)
            .accessibilityLabel(failure ? "Run failed" : "Unread replies").help(failure ? "The last run failed while you were away" : "New replies you have not viewed")
    }
}

/// The minute "3m ago" stamps are worked out against, from one clock around a list.
private struct SidebarMinuteKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var sidebarMinute: Date? {
        get { self[SidebarMinuteKey.self] }
        set { self[SidebarMinuteKey.self] = newValue }
    }
}
struct SidebarMinuteClock: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.everyMinute) { context in content.environment(\.sidebarMinute, context.date) }
    }
}
