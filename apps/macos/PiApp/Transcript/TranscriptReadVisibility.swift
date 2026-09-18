import Foundation

/// When a reply on screen may count as read: only in the active app's key,
/// visible, unoccluded window, with the page itself visible and no sheet up.
enum TranscriptReadVisibility {
    /// Posted when the conversation's native views come back after the report closes.
    static let didRestoreNativeView = Notification.Name("PiTranscriptDidRestoreNativeView")
    static func permits(appActive: Bool, keyWindow: Bool, windowVisible: Bool, occluded: Bool, minimized: Bool, viewHidden: Bool, sheetOpen: Bool) -> Bool {
        appActive && keyWindow && windowVisible && !occluded && !minimized && !viewHidden && !sheetOpen
    }
}
