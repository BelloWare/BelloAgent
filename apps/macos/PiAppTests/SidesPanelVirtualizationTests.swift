import AppKit
import XCTest
@testable import PiApp

@MainActor final class SidesPanelVirtualizationTests: XCTestCase {
    func testPinnedPanelWithoutAChatShowsOnlyTheEmptyStateFromItsFirstLayout() throws {
        let root = scratchRoot("sides-panel-empty-visibility")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.chats = [ChatRecord(id: "parent", workspaceID: "project", title: "Parent", path: nil, profileID: "fixture")]
        let panel = SidesPanelView(model: model, parentID: nil, pinned: true)
        panel.frame = CGRect(x: 0, y: 0, width: 260, height: 450)
        panel.layoutSubtreeIfNeeded()
        let empty = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.TextLine.self, in: panel)
            .first { $0.line.text == "Open a chat to see its sides." })
        XCTAssertFalse(empty.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(empty.frame.height, 0)
        XCTAssertTrue(panel.newSide.isHiddenOrHasHiddenAncestor, "The first empty update must hide New side")

        panel.parentID = "parent"
        panel.layoutSubtreeIfNeeded()
        XCTAssertTrue(empty.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(panel.newSide.isHiddenOrHasHiddenAncestor)

        panel.parentID = nil
        panel.layoutSubtreeIfNeeded()
        XCTAssertFalse(empty.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(panel.newSide.isHiddenOrHasHiddenAncestor)
    }

    func testRecycledPanelRowsCannotStartASelectionGlide() throws {
        let root = scratchRoot("sides-panel-selection-reuse")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let reduced = PiKit.Motion.reducedOverride
        PiKit.Motion.reducedOverride = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 260, height: 450))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close(); PiKit.Motion.reducedOverride = reduced }
        let newSide = PiKit.TextLine(PiKit.Line("New side", font: PiKit.Font.body, color: .piInk))
        let document = SidesPanelListDocument(model: model, newSide: newSide, empty: NSView(), glide: PiKit.SelectionGlide())
        func content(_ entry: SidesPanelEntry) -> SidesPanelRowView.Content {
            .init(entry: entry, stats: ChatRowStats(totals: nil), unread: false, failed: false, enabled: true)
        }
        document.content = { content($0) }
        let entries = (0..<100).map { SidesPanelEntry(id: "side-\($0)", title: "Side \($0)", open: $0 == 0, saved: true) }
        document.update(entries.map { .init(entry: $0, unread: false) }, hasParent: true)
        scroll.documentView = document
        document.frame = CGRect(x: 0, y: 0, width: 260, height: document.height(forWidth: 260))
        document.refreshVisible()
        let recycled = try XCTUnwrap(document.rows["side-0"])
        XCTAssertTrue(recycled.row.selected)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height / 2))
        document.viewportChanged()
        XCTAssertNil(document.rows["side-0"])
        XCTAssertTrue(document.rows.values.contains { $0 === recycled }, "The selected control must actually acquire another binding")
        XCTAssertNotEqual(recycled.content?.entry.id, "side-0")
        XCTAssertFalse(recycled.row.selected)
        let next = try XCTUnwrap(document.rows.values.first { $0 !== recycled })
        let entry = try XCTUnwrap(next.content?.entry)
        XCTAssertTrue(next.row.window === window)
        next.update(content(SidesPanelEntry(id: entry.id, title: entry.title, open: true, saved: entry.saved)))
        XCTAssertNil(next.row.fill.animation(forKey: "glide"), "A recycled side cannot supply the previous selection's highlight position")

        let selected = try XCTUnwrap(next.content)
        next.prepareForReuse()
        next.update(selected)
        XCTAssertTrue(next.row.selected, "Returning to the same side must restore its selection even when its content is unchanged")
        next.row.selected = false
        recycled.row.selected = true
        XCTAssertNotNil(recycled.row.fill.animation(forKey: "glide"), "The rebound selection must remain a glide source for a live row")
    }

    func testALargeSideListMountsOnlyNearbyRowsAndKeepsEverySideReachable() async throws {
        let root = scratchRoot("sides-panel-virtualization")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.chats = [ChatRecord(id: "parent", workspaceID: "project", title: "Parent", path: nil, profileID: "fixture")]
        model.chats += (0..<1_000).map { i in
            var chat = ChatRecord(id: "side-\(i)", workspaceID: "project", title: "Side \(i)", path: nil, profileID: "fixture")
            chat.parentSessionID = "parent"
            return chat
        }
        let panel = SidesPanelView(model: model, parentID: "parent", pinned: false)
        panel.frame = CGRect(x: 0, y: 0, width: 260, height: 450)
        panel.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(InspectorExpandFixture.descendants(NSScrollView.self, in: panel).first)
        let document = try XCTUnwrap(scroll.documentView)
        func rows() -> [SidesPanelRowView] { InspectorExpandFixture.descendants(SidesPanelRowView.self, in: panel) }
        print("SCROLL-15 mounted side rows: \(rows().count) / 1000")
        XCTAssertLessThan(rows().count, 40)
        XCTAssertGreaterThan(document.frame.height, 40_000, "The scroller still spans all sides")
        let entries = model.sidesPanelEntries(of: "parent")
        XCTAssertTrue(rows().contains { $0.content?.entry.id == entries.first?.id })
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        panel.layoutSubtreeIfNeeded()
        XCTAssertLessThan(rows().count, 40)
        XCTAssertTrue(rows().contains { $0.content?.entry.id == entries.last?.id })

        // Newly visible rows read their current state, even if it changed offscreen.
        let first = try XCTUnwrap(entries.first?.id)
        let list = try XCTUnwrap(document as? SidesPanelListDocument)
        let measured = list.heightMeasurements
        model.unreadStates[first] = SessionReadState(id: first, observedAssistantCount: 1, latestAssistantID: "reply", unreadOutputs: 1)
        panel.refresh()
        panel.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(list.heightMeasurements - measured, 1, "Only the title whose weight changed needs measurement")
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(rows().first { $0.content?.entry.id == first }?.content?.unread, true)
        let display = SessionDisplay(id: first)
        model.displays[first] = display
        panel.refresh()
        display.state = "paused"
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(rows().first { $0.content?.entry.id == first }?.content?.lead, "Paused", "Visible rows keep live observations")
    }
}
