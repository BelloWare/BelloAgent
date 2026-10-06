import AppKit
import SwiftUI
@testable import PiApp

/// The pane inside the still-SwiftUI workspace, side and tab panes (TEMPORARY).
struct ConversationPane: View {
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    /// How wide this pane is; the AppKit pane reads its own width.
    let paneWidth: CGFloat
    var side: SideRecord? = nil
    var sideActions: SideActions? = nil
    @MainActor static func coversTranscript(_ session: SessionDisplay) -> Bool { ConversationPaneView.coversTranscript(session) }
    static var coverDelay: Duration { ConversationPaneView.coverDelay }
    var body: some View {
        // Under the title bar, as the SwiftUI pane was: its transcript starts
        // beside the window's controls.
        Host(model: model, session: session, chat: chat, side: side, sideActions: sideActions)
            .ignoresSafeArea(.container, edges: .top)
    }
    private struct Host: NSViewRepresentable {
        let model: WorkspaceModel
        let session: SessionDisplay
        let chat: ChatRecord
        var side: SideRecord?
        var sideActions: SideActions?
        func makeNSView(context: Context) -> ConversationPaneView {
            let view = ConversationPaneView(model: model)
            view.show(session: session, chat: chat, side: side, sideActions: sideActions)
            return view
        }
        func updateNSView(_ view: ConversationPaneView, context: Context) {
            view.inheritedEnabled = context.environment.isEnabled
            view.show(session: session, chat: chat, side: side, sideActions: sideActions)
        }

    }
}

extension View { func piShellBridged() -> some View { buttonStyle(.piSecondary).toggleStyle(.piSwitch).ignoresSafeArea(.container, edges: .top) } }
