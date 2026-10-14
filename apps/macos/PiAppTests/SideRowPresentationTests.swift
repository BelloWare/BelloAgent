import AppKit
import XCTest
@testable import PiApp

@MainActor final class SideRowPresentationTests: XCTestCase {
    func testUnsavedSideAnnouncesUnreadAndLivePausedState() throws {
        let root = scratchRoot("side-row-accessibility")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let display = SessionDisplay(id: "ephemeral-side")
        display.state = "paused"
        model.displays[display.id] = display
        var state = SidebarSideRowState(id: display.id, title: "Side conversation", unreadCount: 1,
                                        liveIdentity: ObjectIdentifier(display))
        let view = SidebarSideRowView(model: model, state: state, glide: PiKit.SelectionGlide())
        XCTAssertEqual(view.row.accessibilityLabel(), "Side conversation, paused, unread")

        // A live publication must refresh the same row's name too.
        display.state = "idle"
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.row.accessibilityLabel(), "Side conversation, unread")
        display.state = "paused"
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.row.accessibilityLabel(), "Side conversation, paused, unread")
        state.unreadCount = 0
        view.apply(state)
        XCTAssertEqual(view.row.accessibilityLabel(), "Side conversation, paused")
        XCTAssertTrue(model.chats.isEmpty, "Drawing an unsaved side must not persist it")
    }

    func testSidesPanelUsesSidebarStateWordsAndKeepsItsBusyIndicator() {
        let entry = SidesPanelEntry(id: "side", title: "Side conversation", open: true, saved: false)
        for (state, loading, expected) in [("running", false, nil), ("tool", false, nil),
                                          ("queued", false, "Waiting"), ("stopping", false, "Stopping"),
                                          ("paused", false, "Paused"), ("running", true, "Opening")] as [(String, Bool, String?)] {
            var stats = ChatRowStats(totals: nil)
            stats.state = state; stats.loading = loading
            stats.busy = ["running", "tool", "queued", "stopping"].contains(state)
            let content = SidesPanelRowView.Content(entry: entry, stats: stats, unread: false, failed: false, enabled: true)
            XCTAssertEqual(content.lead, expected, state)
            XCTAssertFalse(content.spoken.contains("Working"), state)
            XCTAssertEqual(content.working, stats.busy || loading, "The spinner stays")
        }
    }
}
