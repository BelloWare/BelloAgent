import SwiftUI

// The pane beside the chat: the chat's side and the window's tabs, in one
// place whatever is shown. The side is mounted where it always is, under the
// tab shown over it, so its transcript, draft and running reply are there
// when its tab is chosen again; its native views are hidden while covered
// (`ConversationPageVisibility`). With no tabs, the pane is the side alone,
// as it always was.

struct RightPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var host: TabHost
    @ObservedObject var pane: TabContainer
    /// The chat's side, if it has one shown.
    let side: (info: SideRecord, session: SessionDisplay)?
    let width: CGFloat

    var body: some View {
        let shown = pane.shownTab(sideAvailable: side != nil)
        VStack(spacing: 0) {
            if !pane.tabs.isEmpty {
                TabStrip(host: host, container: pane, side: side.map { sideItem($0.info) })
            }
            ZStack {
                if let side {
                    SidePane(model: model, session: side.session, info: side.info, paneWidth: width).id(side.info.id)
                        .opacity(shown == nil ? 1 : 0)
                        .allowsHitTesting(shown == nil)
                        .accessibilityHidden(shown != nil)
                }
                if let shown {
                    TabContentHost(tab: shown, owner: pane, placement: shown.placement).id(shown.id)
                }
            }
        }
        .background(Color.piContent)
    }
    private func sideItem(_ info: SideRecord) -> SideTabItem {
        SideTabItem(title: info.kept ? (model.record(info.id)?.title ?? info.title) : "Side conversation",
                    help: info.kept ? "The saved side conversation" : "The side conversation")
    }
}
