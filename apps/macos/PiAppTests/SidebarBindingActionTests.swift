import AppKit
import XCTest
@testable import PiApp

@MainActor final class SidebarBindingActionTests: XCTestCase {
    private func model() -> WorkspaceModel {
        let root = scratchRoot("sidebar-binding-actions")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in model.shutdown(); try? FileManager.default.removeItem(at: root) }
        return model
    }
    private func chat(_ id: String) -> ChatRecord {
        ChatRecord(id: id, workspaceID: "project", title: id, path: nil, profileID: "fixture")
    }
    private func menuEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func end(_ menu: NSMenu) { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }

    func testChatRowRejectsOldEmbeddedMenuAndDragActionsAfterRebinding() throws {
        let model = model(), original = chat("original"), replacement = chat("replacement")
        model.chats = [original, replacement]
        let state = SidebarChatRowState(hasSide: true, draggable: true, available: 220)
        let row = SidebarChatRowView(model: model, chat: original, state: state, projectID: "project", glide: PiKit.SelectionGlide())
        let toggle = row.body.toggle, doubleClick = row.row.doubleClick
        let surface = try XCTUnwrap(row.subviews.compactMap { $0 as? TopicSessionDragSurfaceView }.first)
        let drag = surface.actions
        let archive = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.IconButton.self, in: row)
            .first { $0.accessibilityIdentifier() == "archiveChat" })
        let oldArchive = archive.onPress
        let keep = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.IconButton.self, in: row)
            .first { $0.accessibilityLabel() == "Keep chat" })
        let oldKeep = keep.onPress
        let confirmation = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.Button.self, in: row)
            .first { $0.accessibilityIdentifier() == "confirmArchive" })
        let menu = try XCTUnwrap(row.menu(for: menuEvent()))
        defer { end(menu); model.setSidebarOrderHold(.drag, false) }
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" }?.target as? PiMenuTarget)

        // A rebind alone invalidates actions; callers need not have prepared
        // the view first for its previous callbacks to become inert.
        row.apply(chat: replacement, state: state, projectID: "project", force: true)
        toggle(); doubleClick?(); drag.click(.command); drag.doubleClick(); drag.dragging(true); rename.run(nil)
        XCTAssertTrue(model.collapsedSidebarSides.isEmpty)
        XCTAssertTrue(model.markedSessionIDs.isEmpty)
        XCTAssertNil(model.renameTarget)
        XCTAssertFalse(model.sidebarOrderHolds.contains(.drag))
        XCTAssertNil(drag.item(), "A retained drag cannot vend the new chat's payload")
        XCTAssertNil(drag.image())
        oldArchive?()
        XCTAssertTrue(confirmation.isHidden, "A stale embedded button cannot change the replacement's confirmation")
        archive.onPress?()
        XCTAssertFalse(confirmation.isHidden, "The current binding remains interactive")
        oldKeep?()
        XCTAssertFalse(confirmation.isHidden, "A stale Keep press cannot dismiss a new binding's question")
        keep.onPress?()
        row.body.toggle()
        XCTAssertEqual(model.collapsedSidebarSides, [replacement.id])
    }

    func testPreparingAChatInvalidatesCallbacksBeforeItIsRebound() throws {
        let model = model(), original = chat("original")
        model.chats = [original]
        let row = SidebarChatRowView(model: model, chat: original, state: SidebarChatRowState(hasSide: true),
                                     projectID: "project", glide: PiKit.SelectionGlide())
        let toggle = row.body.toggle, rename = row.row.doubleClick
        row.prepareForReuse()
        toggle(); rename?()
        XCTAssertTrue(model.collapsedSidebarSides.isEmpty)
        XCTAssertNil(model.renameTarget)
    }

    func testSideRowRejectsOldMenuAndClickAfterReuse() async throws {
        let model = model()
        model.chats = [chat("original"), chat("replacement")]
        let row = SidebarSideRowView(model: model, state: SidebarSideRowState(id: "original", title: "Original", kept: true), glide: PiKit.SelectionGlide())
        let click = row.row.onPress
        let menu = try XCTUnwrap(row.menu(for: menuEvent()))
        defer { end(menu) }
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" }?.target as? PiMenuTarget)
        row.prepareForReuse()
        row.apply(SidebarSideRowState(id: "replacement", title: "Replacement", kept: true), force: true)
        // No saved records are needed to count a navigation attempt, and no
        // helper or provider needs to be opened by this fixture.
        model.chats = []
        click?(); rename.run(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(model.sidebarSearch.openings, 0)
        model.chats = [chat("original"), chat("replacement")]
        rename.run(nil)
        XCTAssertNil(model.renameTarget)
    }

    func testPanelRowRejectsOldClickAcrossReuseAndSameIDRebind() async {
        let model = model()
        let row = SidesPanelRowView(model: model, glide: PiKit.SelectionGlide())
        func content(_ id: String) -> SidesPanelRowView.Content {
            .init(entry: SidesPanelEntry(id: id, title: id, open: false, saved: true),
                  stats: ChatRowStats(totals: nil), unread: false, failed: false, enabled: true)
        }
        row.update(content("original"))
        let click = row.row.onPress
        row.prepareForReuse(); row.update(content("replacement"))
        click?()
        let sameIDClick = row.row.onPress
        row.prepareForReuse(); row.update(content("replacement"))
        sameIDClick?()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(model.sidebarSearch.openings, 0)
        row.row.onPress?()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(model.sidebarSearch.openings, 1, "Only a new action on the current binding can navigate")
    }
}
