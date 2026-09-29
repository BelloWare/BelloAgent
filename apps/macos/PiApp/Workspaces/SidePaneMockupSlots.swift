import SwiftUI

/// Other designs for parts of the side pane, put in their place: how the
/// screenshot gallery shows proposed ways of switching between a chat's sides
/// beside the side itself (`PI_APP_UI_GALLERY_SIDES_ONLY`). The app never
/// sets them, so the pane it draws is always its own.
struct SidePaneMockupSlots {
    /// The side's header: given what it draws from and the header the app
    /// draws, which a design may keep and add to.
    var header: (@MainActor (SidePaneHeaderContext, AnyView) -> AnyView)?
    /// Drawn right above the side's composer.
    var aboveComposer: (@MainActor (SidePaneHeaderContext) -> AnyView)?
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

private struct SidePaneMockupSlotsKey: EnvironmentKey {
    static var defaultValue: SidePaneMockupSlots? { nil }
}

extension EnvironmentValues {
    var sidePaneMockupSlots: SidePaneMockupSlots? {
        get { self[SidePaneMockupSlotsKey.self] }
        set { self[SidePaneMockupSlotsKey.self] = newValue }
    }
}
