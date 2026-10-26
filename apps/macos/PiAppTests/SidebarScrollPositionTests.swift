import AppKit
import QuartzCore
import XCTest
@testable import PiApp

/// SIDEBAR-2: content updates must distinguish reading the top from reading
/// a row farther down. Real documents, clip views and offscreen windows only.
@MainActor final class SidebarScrollPositionTests: XCTestCase {
    private func fixture(flat: Bool = true, chips: Bool = false, selected: String? = nil) throws -> WorkspaceSidebarView {
        let root = scratchRoot("sidebar-scroll-position")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "app", path: root.appendingPathComponent("BelloAgent").path, trusted: true)]
        if chips { model.workspaces.append(WorkspaceRecord(id: "box", path: root.appendingPathComponent("BelloBox").path, trusted: true)) }
        model.chats = (0..<40).map {
            ChatRecord(id: "c\($0)", workspaceID: chips && $0 >= 30 ? "box" : "app", title: "Chat \($0)",
                       path: nil, profileID: "fixture", sidebarOrder: Int64(100 - $0))
        }
        model.selectedID = selected
        model.setSidebarFlat(flat)
        model.setSidebarShownRoots(SidebarSessionPresentation.combinedFlatGroupID, to: 100, in: "")
        for project in model.workspaces { model.setSidebarShownRoots(project.id, to: 100, in: project.id) }
        let sidebar = WorkspaceSidebarView(model: model, width: 300)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 420), styleMask: [], backing: .buffered, defer: false)
        let reduced = PiKit.Motion.reducedOverride
        PiKit.Motion.reducedOverride = false
        window.isReleasedWhenClosed = false; window.contentView = sidebar
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close(); PiKit.Motion.reducedOverride = reduced
        }
        sidebar.settle()
        scroll(sidebar, to: 0)
        return sidebar
    }

    private func scroll(_ sidebar: WorkspaceSidebarView, to y: CGFloat) {
        sidebar.scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        sidebar.scroll.reflectScrolledClipView(sidebar.scroll.contentView)
        sidebar.list.materialize()
    }
    private func frame(_ sidebar: WorkspaceSidebarView, _ id: String) throws -> CGRect {
        try XCTUnwrap(sidebar.list.frame(of: "chat|" + id))
    }
    private func assertVisible(_ sidebar: WorkspaceSidebarView, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try frame(sidebar, id), clip = sidebar.scroll.contentView.bounds
        XCTAssertGreaterThanOrEqual(row.minY, clip.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxY, clip.maxY, file: file, line: line)
        XCTAssertNotNil(sidebar.list.views["chat|" + id], file: file, line: line)
    }
    private func glideStart(_ view: NSView, in sidebar: WorkspaceSidebarView) -> CGFloat {
        let animation = view.layer?.animation(forKey: "glide") as? CABasicAnimation
        let translation = (animation?.fromValue as? NSNumber)?.doubleValue ?? 0
        return view.frame.minY + CGFloat(translation) - sidebar.scroll.contentView.bounds.minY
    }
    private func activity(_ sidebar: WorkspaceSidebarView, _ id: String, stamp: Int, animated: Bool) {
        sidebar.model.noteChatActivity(id, at: Date(timeIntervalSince1970: Double(stamp)))
        sidebar.refresh(animated: animated)
    }

    func testRepeatedActivityAtTopShowsTheNewestChatInEveryMode() throws {
        for (flat, chips) in [(true, false), (true, true), (false, false)] {
            for animated in [false, true] {
                let sidebar = try fixture(flat: flat, chips: chips)
                XCTAssertEqual(sidebar.projectFilter.isHidden, !chips)
                for index in 1...3 {
                    let id = "c\(index)", old = try XCTUnwrap(sidebar.list.views["chat|" + id])
                    let before = old.frame.minY - sidebar.scroll.contentView.bounds.minY
                    activity(sidebar, id, stamp: index, animated: animated)
                    print("SIDEBAR-2 top flat=\(flat) chips=\(chips) animated=\(animated) update=\(index): \(sidebar.scroll.contentView.bounds.minY) pt")
                    XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
                    try assertVisible(sidebar, id)
                    if animated {
                        XCTAssertNotNil(old.layer?.animation(forKey: "glide"))
                        XCTAssertEqual(glideStart(old, in: sidebar), before, accuracy: 0.01)
                    }
                }
            }
        }
    }

    func testSelectedChatMovingToTopStaysVisible() throws {
        for flat in [false, true] {
            let sidebar = try fixture(flat: flat, chips: flat, selected: "c2")
            try assertVisible(sidebar, "c2")
            activity(sidebar, "c2", stamp: 1, animated: true)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
            try assertVisible(sidebar, "c2")
            XCTAssertTrue(try XCTUnwrap(sidebar.list.views["chat|c2"] as? SidebarChatRowView).row.selected)
        }
    }

    func testVisibleSelectionMovingAboveTheViewportStopsAtTheTopEdge() throws {
        try assertSelectionFollows(above: true)
    }

    func testVisibleSelectionMovingBelowTheViewportStopsAtTheBottomEdge() throws {
        try assertSelectionFollows(above: false)
    }

    private func assertSelectionFollows(above: Bool) throws {
        for flat in [false, true] {
            for animated in [false, true] {
                let sidebar = try fixture(flat: flat, chips: flat, selected: "c13")
                scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
                try assertVisible(sidebar, "c13")
                let selected = try XCTUnwrap(sidebar.list.views["chat|c13"])
                let before = selected.frame.minY - sidebar.scroll.contentView.bounds.minY
                if above { activity(sidebar, "c13", stamp: 1, animated: animated) }
                else {
                    sidebar.model.chats[13].sidebarOrder = -1
                    sidebar.refresh(animated: animated)
                }
                let row = try frame(sidebar, "c13"), clip = sidebar.scroll.contentView.bounds
                let expected = above ? row.minY : row.maxY - clip.height
                print("SIDEBAR-2 selection above=\(above) flat=\(flat) animated=\(animated): clip \(clip.minY), nearest edge \(expected)")
                XCTAssertEqual(clip.minY, expected, accuracy: 0.01, "Only the scroll needed to show the row at the nearer edge")
                try assertVisible(sidebar, "c13")
                XCTAssertTrue(sidebar.list.views["chat|c13"] === selected)
                if animated {
                    XCTAssertNotNil(selected.layer?.animation(forKey: "glide"))
                    XCTAssertEqual(glideStart(selected, in: sidebar), before, accuracy: 0.01)
                }
            }
        }
    }

    func testAnOffscreenSelectionDoesNotFollowItsReorder() throws {
        for id in ["c0", "c25"] {
            for animated in [false, true] {
                let sidebar = try fixture(selected: id)
                scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
                XCTAssertFalse(try frame(sidebar, id).intersects(sidebar.scroll.contentView.bounds))
                let before = try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY
                if id == "c25" { activity(sidebar, id, stamp: 1, animated: animated) }
                else {
                    sidebar.model.chats[0].sidebarOrder = -1
                    sidebar.refresh(animated: animated)
                }
                XCTAssertEqual(try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
                XCTAssertFalse(try frame(sidebar, id).intersects(sidebar.scroll.contentView.bounds))
            }
        }
    }

    func testAPartlyVisibleSelectionCountsButOneStillShowingDoesNotMoveTheReader() throws {
        for animated in [false, true] {
            let sidebar = try fixture(selected: "c15")
            let row = try frame(sidebar, "c15")
            scroll(sidebar, to: row.minY + 5 - sidebar.scroll.contentView.bounds.height)
            let before = sidebar.scroll.contentView.bounds.minY
            XCTAssertTrue(row.intersects(sidebar.scroll.contentView.bounds))
            XCTAssertGreaterThan(row.maxY, sidebar.scroll.contentView.bounds.maxY)
            sidebar.model.chats[15].title = "Still partly visible"
            sidebar.refresh(animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
            activity(sidebar, "c15", stamp: 1, animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, try frame(sidebar, "c15").minY, accuracy: 0.01)
            try assertVisible(sidebar, "c15")
        }
    }

    func testBulkMarksFollowOnlyThePrimarySelection() throws {
        for animated in [false, true] {
            let sidebar = try fixture(selected: "c13")
            sidebar.model.markedSessionIDs = ["c13", "c14", "c15"]
            sidebar.settle()
            scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
            let before = try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY
            activity(sidebar, "c14", stamp: 1, animated: animated)
            XCTAssertEqual(try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01,
                           "A marked row is not the primary selection")
            try assertVisible(sidebar, "c13")
            activity(sidebar, "c13", stamp: 2, animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, try frame(sidebar, "c13").minY, accuracy: 0.01)
            try assertVisible(sidebar, "c13")
            XCTAssertEqual(sidebar.model.markedSessionIDs, ["c13", "c14", "c15"])
        }
    }

    func testSelectionFollowingWaitsForThePointerHoldAndDoesNotOverrideTheTop() throws {
        for animated in [false, true] {
            let sidebar = try fixture(selected: "c13")
            scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
            let before = sidebar.scroll.contentView.bounds.minY
            sidebar.model.setSidebarOrderHold(.pointer, true)
            activity(sidebar, "c13", stamp: 1, animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
            sidebar.model.setSidebarOrderHold(.pointer, false)
            sidebar.refresh(animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
            try assertVisible(sidebar, "c13")
            // The now-visible selection can leave again, but the top wins.
            sidebar.model.chats[13].lastActivityAt = nil
            sidebar.model.chats[13].sidebarOrder = -1
            sidebar.refresh(animated: animated)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        }
    }

    func testSelectionCorrectionRebasesRemountedAndDepartingRows() throws {
        let sidebar = try fixture(selected: "c13")
        scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
        let before = sidebar.scroll.contentView.bounds.minY
        XCTAssertNil(sidebar.list.views["chat|c0"])
        let incoming = try frame(sidebar, "c0").minY - before
        let leaving = try XCTUnwrap(sidebar.list.views["chat|c14"])
        let leavingBefore = leaving.frame.minY - before
        sidebar.model.chats.removeAll { $0.id == "c14" }
        activity(sidebar, "c13", stamp: 1, animated: true)
        XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        let mounted = try XCTUnwrap(sidebar.list.views["chat|c0"])
        XCTAssertEqual(glideStart(mounted, in: sidebar), incoming, accuracy: 0.01)
        XCTAssertNotNil(leaving.layer?.animation(forKey: "reveal"))
        XCTAssertEqual(leaving.frame.minY - sidebar.scroll.contentView.bounds.minY, leavingBefore, accuracy: 0.01)
    }

    func testASelectionChangeDoesNotFollowTheOldPrimary() throws {
        let sidebar = try fixture(selected: "c13")
        scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
        let before = try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY
        sidebar.model.selectedID = "c0"
        activity(sidebar, "c13", stamp: 1, animated: true)
        XCTAssertEqual(try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
    }

    func testRemovingTheReadingRowStillKeepsTheVisibleSelection() throws {
        let sidebar = try fixture(selected: "c13")
        scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
        sidebar.model.chats.removeAll { $0.id == "c12" }
        activity(sidebar, "c13", stamp: 1, animated: true)
        XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        try assertVisible(sidebar, "c13")
    }

    func testInsertedRowsAndGroupsAtTopStayVisible() throws {
        for flat in [false, true] {
            for animated in [false, true] {
                let sidebar = try fixture(flat: flat)
                let model = sidebar.model
                if !flat {
                    model.workspaces.insert(WorkspaceRecord(id: "new", path: "/generated/new-project", trusted: true), at: 0)
                    model.topics = [TopicRecord(id: "new-topic", workspaceID: "new", title: "New topic")]
                }
                var chat = ChatRecord(id: "new", workspaceID: flat ? "app" : "new", title: "New activity", path: nil, profileID: "fixture", sidebarOrder: 1_000)
                if !flat { chat.topicID = "new-topic" }
                model.chats.append(chat)
                sidebar.refresh(animated: animated)
                XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
                try assertVisible(sidebar, "new")
                if !flat { XCTAssertEqual(sidebar.list.contents.entries.first?.id, "project|new") }
                if animated { XCTAssertNotNil(sidebar.list.views["chat|new"]?.layer?.animation(forKey: "reveal")) }
            }
        }
    }

    func testTopToleranceUsesTheContentInsetAndDoesNotCatchAReaderBelowIt() throws {
        for inset: CGFloat in [0, 12] {
            for distance: CGFloat in [0, 0.5, 1, 1.5] {
                let sidebar = try fixture()
                sidebar.scroll.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 7, right: 0)
                scroll(sidebar, to: -inset + distance)
                let before = sidebar.scroll.contentView.bounds.minY
                XCTAssertEqual(before, -inset + distance, accuracy: 0.01)
                let old = try frame(sidebar, "c0").minY
                activity(sidebar, "c2", stamp: 1, animated: false)
                let moved = try frame(sidebar, "c0").minY - old
                let expected = distance <= 1 ? -inset : before + moved
                XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, expected, accuracy: 0.01,
                               "inset \(inset), distance from top \(distance)")
            }
        }
    }

    func testScrolledDownReaderAndVisibleSelectionStayPutWhenActivityArrivesAbove() throws {
        for flat in [false, true] {
            for animated in [false, true] {
                let sidebar = try fixture(flat: flat, selected: "c13")
                scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
                let before = try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY
                let selected = try frame(sidebar, "c13").minY - sidebar.scroll.contentView.bounds.minY
                activity(sidebar, "c25", stamp: 1, animated: animated)
                XCTAssertEqual(try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
                XCTAssertEqual(try frame(sidebar, "c13").minY - sidebar.scroll.contentView.bounds.minY, selected, accuracy: 0.01)
                try assertVisible(sidebar, "c13")
                if animated {
                    XCTAssertEqual(glideStart(try XCTUnwrap(sidebar.list.views["chat|c13"]), in: sidebar), selected, accuracy: 0.01)
                }
            }
        }
    }

    func testPointerHoldReleaseKeepsTopOrReadingPosition() throws {
        for down in [false, true] {
            let sidebar = try fixture(chips: true)
            if down { scroll(sidebar, to: try frame(sidebar, "c12").minY + 9) }
            let before = sidebar.scroll.contentView.bounds.minY
            let anchor = try frame(sidebar, "c12").minY - before
            sidebar.model.setSidebarOrderHold(.pointer, true)
            activity(sidebar, "c25", stamp: 1, animated: true)
            XCTAssertEqual(sidebar.list.contents.entries.first?.id, "chat|c0")
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
            sidebar.model.setSidebarOrderHold(.pointer, false)
            sidebar.refresh(animated: true)
            XCTAssertEqual(sidebar.list.contents.entries.first?.id, "chat|c25")
            if down {
                XCTAssertEqual(try frame(sidebar, "c12").minY - sidebar.scroll.contentView.bounds.minY, anchor, accuracy: 0.01)
            } else {
                XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
                try assertVisible(sidebar, "c25")
            }
        }
    }

    func testHeightChangesKeepTopAndTheScrolledDownReadingOffset() throws {
        for down in [false, true] {
            let sidebar = try fixture(selected: "c4")
            if down { scroll(sidebar, to: try frame(sidebar, "c3").minY + 9) }
            let clip = sidebar.scroll.contentView.bounds.minY
            let anchor = try frame(sidebar, "c3").minY - clip
            let row = try XCTUnwrap(sidebar.list.views["chat|c1"] as? SidebarChatRowView)
            let original = row.frame.height
            let display = SessionDisplay(id: "c1")
            display.footer.gateway = GatewayTotals(requests: 1, costSamples: 1, costUSD: 12.34)
            display.footer.timing = SessionTimingHistory(samples: [
                SessionTimingSample(id: "r", wall: Date(), ttftMilliseconds: 200, streamingMilliseconds: 800,
                                    outputTokens: 100, requestMilliseconds: 1_000)
            ])
            sidebar.model.displays["c1"] = display
            let originalState = row.state
            var state = row.state
            state.available = 60; state.liveIdentity = ObjectIdentifier(display)
            row.apply(chat: row.chat, state: state, projectID: row.projectID)
            XCTAssertGreaterThan(row.frame.height, original, "Exercise the entryChangedHeight callback")
            if down {
                XCTAssertEqual(try frame(sidebar, "c3").minY - sidebar.scroll.contentView.bounds.minY, anchor, accuracy: 0.01)
                try assertVisible(sidebar, "c4")
            } else { XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01) }
            sidebar.model.displays["c1"] = nil
            row.apply(chat: row.chat, state: originalState, projectID: row.projectID)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, clip, accuracy: 0.01)
        }
    }

    func testTopUpdateKeepsDepartingRowAtItsScreenOrigin() throws {
        let sidebar = try fixture()
        let leaving = try XCTUnwrap(sidebar.list.views["chat|c2"])
        let before = leaving.frame.minY
        sidebar.model.chats.removeAll { $0.id == "c2" }
        activity(sidebar, "c3", stamp: 1, animated: true)
        XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        XCTAssertNil(sidebar.list.views["chat|c2"])
        XCTAssertNotNil(leaving.layer?.animation(forKey: "reveal"))
        XCTAssertEqual(leaving.frame.minY - sidebar.scroll.contentView.bounds.minY, before, accuracy: 0.01)
        try assertVisible(sidebar, "c3")
    }

    func testStatusBriefAndWidthChangesDoNotScrollAwayFromTheTop() throws {
        let sidebar = try fixture(chips: true, selected: "c2")
        sidebar.model.unreadStates["c1"] = SessionReadState(id: "c1", observedAssistantCount: 1, latestAssistantID: "reply", unreadOutputs: 1)
        sidebar.model.runHolds["c2"] = RunHoldRecord(id: "c2", state: "paused")
        sidebar.model.chats[0].brief = ChatBrief(text: "The latest summary", keywords: ["sidebar"], through: "reply", at: Date(), activity: 100)
        let display = SessionDisplay(id: "c3"); display.state = "running"
        sidebar.model.displays["c3"] = display
        for width: CGFloat in [200, 300] {
            sidebar.window?.setContentSize(NSSize(width: width, height: 420))
            sidebar.settle()
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
            try assertVisible(sidebar, "c2")
        }
    }

    func testSearchResultsUpdatingAtTopShowTheNewMatch() async throws {
        for flat in [false, true] {
            let sidebar = try fixture(flat: flat)
            sidebar.setFilter("Chat")
            activity(sidebar, "c2", stamp: 1, animated: false)
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
            try assertVisible(sidebar, "c2")

            // A full-text result arrives asynchronously above an existing hit.
            let root = scratchRoot("sidebar-scroll-search")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let second = try SearchJournal(root.appendingPathComponent("second.jsonl"), id: "c2")
            for index in [0, 1, 3, 4, 5, 6, 7, 8] {
                let journal = try SearchJournal(root.appendingPathComponent("c\(index).jsonl"), id: "c\(index)")
                try journal.message("match", role: "user", "the marmalade checklist")
                sidebar.model.chats[index].path = journal.url.path
            }
            try second.message("other", role: "user", "something else")
            sidebar.model.chats[2].path = second.url.path
            sidebar.model.sidebarSearch.setScope(.fullChats)
            await sidebar.model.sidebarSearch.reconcileNow()
            sidebar.setFilter("marmalade")
            await sidebar.model.sidebarSearch.settleQuery(); sidebar.settle()
            scroll(sidebar, to: 0)
            XCTAssertGreaterThan(sidebar.list.frame.height, sidebar.scroll.contentView.bounds.height)
            try second.message("new-match", role: "assistant", "found the marmalade")
            await sidebar.model.sidebarSearch.reconcileNow()
            await sidebar.model.sidebarSearch.settleQuery(); sidebar.settle()
            XCTAssertNotNil(sidebar.list.frame(of: "snippet|c2"))
            XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
            try assertVisible(sidebar, "c2")
        }
    }

    func testActivityUpdateGallery() async throws {
        guard let path = testEnvironment("PI_APP_SIDEBAR_SCROLL_GALLERY") else {
            throw XCTSkip("Set PI_APP_SIDEBAR_SCROLL_GALLERY for these scenes")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (mode, flat, chips) in [("flat", true, false), ("chips", true, true), ("groups", false, false)] {
            for width: CGFloat in [300, 200] {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let sidebar = try fixture(flat: flat, chips: chips, selected: "c2")
                    let window = try XCTUnwrap(sidebar.window)
                    window.setContentSize(NSSize(width: width, height: 640))
                    window.appearance = NSAppearance(named: appearance)
                    sidebar.model.chats[2].title = "Updated chat stays at the top"
                    sidebar.settle(); scroll(sidebar, to: 0)
                    activity(sidebar, "c2", stamp: 1, animated: true)
                    sidebar.settle(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, accuracy: 0.01)
                    try assertVisible(sidebar, "c2")
                    let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                    sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("updated-\(mode)-\(Int(width))-\(theme).png"))
                }
            }
        }
    }

    func testSelectionFollowingGallery() async throws {
        guard let path = testEnvironment("PI_APP_SIDEBAR_SCROLL_GALLERY") else {
            throw XCTSkip("Set PI_APP_SIDEBAR_SCROLL_GALLERY for these scenes")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (mode, flat, chips) in [("flat", true, false), ("chips", true, true), ("groups", false, false)] {
            for above in [false, true] {
                for width: CGFloat in [300, 200] {
                    for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        let sidebar = try fixture(flat: flat, chips: chips, selected: "c13")
                        let window = try XCTUnwrap(sidebar.window)
                        window.setContentSize(NSSize(width: width, height: 640))
                        window.appearance = NSAppearance(named: appearance)
                        sidebar.model.chats[13].title = "Selected chat stays visible"
                        sidebar.settle()
                        scroll(sidebar, to: try frame(sidebar, "c12").minY + 9)
                        if above { activity(sidebar, "c13", stamp: 1, animated: true) }
                        else { sidebar.model.chats[13].sidebarOrder = -1; sidebar.refresh(animated: true) }
                        sidebar.settle(); window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(250))
                        try assertVisible(sidebar, "c13")
                        let row = try frame(sidebar, "c13"), clip = sidebar.scroll.contentView.bounds
                        XCTAssertEqual(clip.minY, above ? row.minY : row.maxY - clip.height, accuracy: 0.01)
                        let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                        sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                        let name = "selected-\(above ? "top" : "bottom")-\(mode)-\(Int(width))-\(theme).png"
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
