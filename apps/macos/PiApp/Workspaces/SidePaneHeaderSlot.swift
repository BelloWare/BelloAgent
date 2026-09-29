import SwiftUI

/// Another design of the side pane's header, in its place: how the screenshot
/// gallery shows proposed ways of switching between a chat's sides beside
/// the side itself (`PI_APP_UI_GALLERY_SIDES_ONLY`). The app never sets it,
/// so the header it draws is always its own.
struct SidePaneHeaderSlot {
    let make: @MainActor (SidePaneHeaderContext) -> AnyView
}

/// What the side pane's own header draws from, for a design put in its place.
struct SidePaneHeaderContext {
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    let side: SideRecord
    let actions: SideActions
    /// What the side shares of its chat, and the same in full for its help.
    let boundary: String
    let boundaryDetail: String
    let paneWidth: CGFloat
}

private struct SidePaneHeaderKey: EnvironmentKey {
    static var defaultValue: SidePaneHeaderSlot? { nil }
}

extension EnvironmentValues {
    var sidePaneHeader: SidePaneHeaderSlot? {
        get { self[SidePaneHeaderKey.self] }
        set { self[SidePaneHeaderKey.self] = newValue }
    }
}
