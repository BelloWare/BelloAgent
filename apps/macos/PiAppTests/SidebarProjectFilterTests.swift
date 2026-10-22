import XCTest
import AppKit
@testable import PiApp

/// Flat's project filter (0.1.131, SIDEBAR-1): chips over the combined list
/// and the rows' project tags narrow it to one project. Isolated desktop
/// stores and generated chats only; no helper, real configuration or window
/// focus.
final class SidebarProjectFilterTests: XCTestCase {
    private let scratch = WorkspaceRecord.scratchID

    /// Four configured projects (one without chats), No project and a
    /// retained project. Newest activity per project: pi-app 95 (its side
    /// answered last), BelloBox 80, No project 70, retained 40, site 20.
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("project-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root)
        model.workspaces = [WorkspaceRecord(id: "app", path: root.appendingPathComponent("pi-app").path, trusted: true),
                            WorkspaceRecord(id: "box", path: root.appendingPathComponent("BelloBox").path, trusted: true),
                            WorkspaceRecord(id: "site", path: root.appendingPathComponent("belloware-site").path, trusted: true),
                            WorkspaceRecord(id: "empty", path: root.appendingPathComponent("quiet-project").path, trusted: true)]
        model.topics = [TopicRecord(id: "transcript", workspaceID: "app", title: "transcript")]
        model.chats = [chat("scroll", in: "app", order: 90, topic: "transcript"), chat("release", in: "app", order: 60),
                       chat("release-side", in: "app", order: 95, parent: "release"),
                       chat("save", in: "box", order: 80), chat("box-pinned", in: "box", order: 5, pinned: true),
                       chat("site-old", in: "site", order: 20), chat("loose", in: scratch, order: 70),
                       chat("retained", in: "gone", order: 40)]
        model.setSidebarFlat(true)
        model.setSidebarShownRoots(SidebarSessionPresentation.combinedFlatGroupID, to: 100, in: "")
        return model
    }
    private func chat(_ id: String, in project: String, order: Int64, topic: String? = nil, parent: String? = nil,
                      archived: Bool = false, pinned: Bool = false) -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: project, title: "Chat " + id, path: nil, profileID: "fixture",
                               sidebarOrder: order, parentSessionID: parent)
        value.topicID = topic
        if archived { value.archivedAt = Date() }
        if pinned { value.pinnedAt = Date() }
        return value
    }
    @MainActor private func build(_ model: WorkspaceModel, filter: String = "", width: CGFloat = 300) -> SidebarListContents {
        SidebarListContents.build(model: model, filter: filter, sidebarWidth: width, confirmingRemove: [], removing: [], dropTarget: nil)
    }
    @MainActor private func rows(_ contents: SidebarListContents) -> [SidebarGroupRow] {
        contents.entries.compactMap { if case .chat(let chat, let state, _) = $0 { return SidebarGroupRow(chat: chat, state: state) }; return nil }
    }
    @MainActor private func ids(_ model: WorkspaceModel, filter: String = "") -> [String] { rows(build(model, filter: filter)).map(\.id) }
    @MainActor private func listed(_ sidebar: WorkspaceSidebarView) -> [String] { rows(sidebar.list.contents).map(\.id) }
    @MainActor private func shownChips(_ bar: SidebarProjectFilterBar) -> [String] {
        bar.layoutSubtreeIfNeeded()
        return bar.placement.shown.map { bar.laidOut[$0].projectID }
    }
    @MainActor private func prepareNewChat(_ model: WorkspaceModel) {
        var profile = ProfileRecord(); profile.id = "fixture"; profile.api = LiteLLMConfiguration.supportedAPI
        model.profiles = [profile]; model.profileChoice = profile.id
    }
    @MainActor private func waitForNewChat(_ model: WorkspaceModel, after id: String?) async throws -> ChatRecord {
        try await eventually("New Chat opened a chat") { model.selectedID != id && model.workspaceChangesInFlight.isEmpty }
        return try XCTUnwrap(model.selectedID.flatMap(model.record))
    }

    // MARK: Filtering

    @MainActor func testChoosingAProjectListsOnlyItsChatsInFlatOrderAndAllGoesBack() throws {
        let model = try fixture()
        let all = ["box-pinned", "release", "scroll", "save", "loose", "retained", "site-old"]
        XCTAssertEqual(ids(model), all)
        model.setSidebarProjectFilter("box")
        XCTAssertEqual(ids(model), ["box-pinned", "save"], "Pinned first, then newest activity")
        XCTAssertEqual(model.sidebarChatOrder, ["box-pinned", "save"], "Keyboard order and Shift ranges follow the list")
        XCTAssertTrue(rows(build(model)).allSatisfy { $0.state.projectTag == "BelloBox" && !$0.state.draggable })
        model.setSidebarProjectFilter("app")
        XCTAssertEqual(ids(model), ["release", "scroll"], "A family is as new as its newest member, as in every Flat list")
        XCTAssertEqual(rows(build(model)).first { $0.id == "scroll" }?.state.topicTag, "transcript")
        model.setSidebarProjectFilter(scratch)
        XCTAssertEqual(ids(model), ["loose"])
        model.setSidebarProjectFilter("gone")
        XCTAssertEqual(ids(model), ["retained"])
        XCTAssertEqual(rows(build(model)).first?.state.projectTag, "Retained chats")
        model.setSidebarProjectFilter(nil)
        XCTAssertEqual(ids(model), all)
        XCTAssertEqual(model.sidebarChatOrder, all)
    }

    @MainActor func testArchiveSectionPagingAndEmptyStatesFollowTheChosenProject() throws {
        let model = try fixture()
        model.chats += [chat("box-old", in: "box", order: 300, archived: true), chat("app-old", in: "app", order: 200, archived: true)]
        model.setArchivedChatsShown(true)
        model.setSidebarProjectFilter("box")
        XCTAssertEqual(ids(model), ["box-pinned", "save", "box-old"])
        let headings = build(model).entries.compactMap { entry -> Int? in
            if case .archiveHeading(_, let count, _) = entry { return count }; return nil
        }
        XCTAssertEqual(headings, [1], "One archive section, counting only this project's archived chats")
        XCTAssertEqual(model.sidebarChatOrder, ["box-pinned", "save", "box-old"])
        model.setArchivedChatsShown(false)
        func pageLine() -> SidebarEntry? { build(model).entries.first { if case .pagination = $0 { return true }; return false } }
        XCTAssertNil(pageLine(), "Two chats under every project's raised count: no Show less that would hide nothing")
        model.setSidebarProjectFilter(nil)
        XCTAssertNotNil(pageLine(), "Every project's list keeps its Show less")
        model.setSidebarProjectFilter("box")

        model.chats += (0..<8).map { chat("box-\($0)", in: "box", order: Int64(100 + $0)) }
        guard case .pagination(_, _, 0, 100, _) = try XCTUnwrap(pageLine()) else { return XCTFail("Ten chats can be shown less") }
        model.setSidebarShownRoots(SidebarSessionPresentation.combinedFlatGroupID, to: SidebarSessionPresentation.pageSize, in: "")
        let paged = build(model)
        XCTAssertEqual(rows(paged).count, SidebarSessionPresentation.pageSize)
        let page = try XCTUnwrap(paged.entries.first { if case .pagination = $0 { return true }; return false })
        guard case .pagination(let group, _, let hidden, _, _) = page else { return XCTFail("No page line") }
        XCTAssertEqual(group, SidebarSessionPresentation.combinedFlatGroupID)
        XCTAssertEqual(hidden, 10 - SidebarSessionPresentation.pageSize, "Only this project's hidden chats are counted")

        model.setSidebarProjectFilter("empty")
        XCTAssertEqual(ids(model), [])
        XCTAssertTrue(build(model).entries.contains { if case .empty(_, "No chats yet", _) = $0 { return true }; return false })
        model.chats[model.chats.firstIndex { $0.id == "site-old" }!].archivedAt = Date()
        model.setSidebarProjectFilter("site")
        XCTAssertTrue(build(model).entries.contains { if case .empty(_, "No active chats", _) = $0 { return true }; return false })
    }

    @MainActor func testSelectionAndRowStatesStayAsFlatShowsThem() throws {
        let model = try fixture()
        model.selectedID = "save"; model.markedSessionIDs = ["box-pinned"]
        model.unreadStates["save"] = SessionReadState(id: "save", observedAssistantCount: 2, latestAssistantID: "m", unreadOutputs: 1)
        model.runHolds["box-pinned"] = RunHoldRecord(id: "box-pinned", state: "paused"); model.draftChatIDs.insert("save")
        let before = Dictionary(uniqueKeysWithValues: rows(build(model)).map { ($0.id, $0.state) })
        XCTAssertTrue(before.values.allSatisfy(\.choosesProject), "Every project's list: each tag narrows")
        model.setSidebarProjectFilter("box")
        for row in rows(build(model)) {
            var expected = try XCTUnwrap(before[row.id])
            expected.choosesProject = false
            XCTAssertEqual(row.state, expected, "\(row.id) keeps every row state; only its tag stops narrowing")
        }
    }

    // MARK: Chips

    @MainActor func testChipsListProjectsWithChatsNewestFirstAndKeepTheChosenOne() throws {
        let model = try fixture()
        XCTAssertEqual(model.sidebarProjectChips.map(\.projectID), ["app", "box", scratch, "gone", "site"])
        XCTAssertEqual(model.sidebarProjectChips.map(\.title), ["pi-app", "BelloBox", "No project", "Retained chats", "belloware-site"])
        XCTAssertEqual(model.sidebarProjectChips.first { $0.projectID == "gone" }?.fullName, "Retained chats · gone")
        XCTAssertTrue(model.sidebarProjectFilterOffersChoice)

        model.chats[model.chats.firstIndex { $0.id == "site-old" }!].sidebarOrder = 999
        XCTAssertEqual(model.sidebarProjectChips.first?.projectID, "site", "Activity reorders the chips as it reorders the rows")

        model.setSidebarProjectFilter("empty")
        XCTAssertEqual(model.sidebarProjectChips.last?.projectID, "empty", "The chosen project keeps its chip without chats")
        model.setSidebarProjectFilter(nil)
        XCTAssertFalse(model.sidebarProjectChips.contains { $0.projectID == "empty" })

        model.chats.append(chat("only-archived", in: "empty", order: 5_000, archived: true))
        XCTAssertFalse(model.sidebarProjectChips.contains { $0.projectID == "empty" }, "Archived chats count while they are listed")
        model.setArchivedChatsShown(true)
        XCTAssertEqual(model.sidebarProjectChips.first?.projectID, "empty")
        model.setArchivedChatsShown(false)

        model.chats.append(chat("retained-2", in: "gone-too", order: 1))
        XCTAssertEqual(Set(model.sidebarProjectChips.filter { $0.title.hasPrefix("Retained") }.map(\.title)),
                       ["Retained chats · gone", "Retained chats · gone-too"], "Several retained groups keep their ids apart")

        model.chats = [chat("solo", in: "app", order: 1)]
        XCTAssertEqual(model.sidebarProjectChips.map(\.projectID), ["app"])
        XCTAssertFalse(model.sidebarProjectFilterOffersChoice, "One project offers nothing to choose")
        let sidebar = makeSidebar(model, width: 300)
        XCTAssertTrue(sidebar.projectFilter.isHidden)
        XCTAssertFalse(try XCTUnwrap(sidebar.list.views["chat|solo"] as? SidebarChatRowView).body.projectTag.pressable)
    }

    @MainActor func testChipsAndTagsNarrowTheListAndTheBarShowsTheChoice() throws {
        let model = try fixture()
        let sidebar = makeSidebar(model, width: 300, height: 900)
        let bar = sidebar.projectFilter
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(sidebar.searchScope.isHidden)
        XCTAssertEqual(bar.frame.minY, sidebar.searchScope.frame.minY, "The chips take the search scope's place")
        XCTAssertEqual(bar.frame.height, sidebar.searchScope.frame.height)
        XCTAssertTrue(bar.all.chosen); XCTAssertTrue(bar.all.isAccessibilitySelected())
        XCTAssertEqual(bar.accessibilityRole(), .group); XCTAssertEqual(bar.accessibilityLabel(), "Project filter")
        XCTAssertEqual(shownChips(bar), ["app", "box"])

        try XCTUnwrap(bar.buttons["box"]).performClick(nil); sidebar.settle()
        XCTAssertEqual(model.sidebarProjectFilter, "box")
        XCTAssertEqual(listed(sidebar), ["box-pinned", "save"])
        XCTAssertTrue(try XCTUnwrap(bar.buttons["box"]).chosen); XCTAssertFalse(bar.all.chosen)
        XCTAssertTrue(try XCTUnwrap(bar.buttons["box"]).isAccessibilitySelected())

        bar.all.performClick(nil); sidebar.settle()
        XCTAssertNil(model.sidebarProjectFilter)
        XCTAssertEqual(listed(sidebar).count, 7)

        // A row's project tag picks its project's chip, without opening the row.
        let row = try XCTUnwrap(sidebar.list.views["chat|site-old"] as? SidebarChatRowView)
        XCTAssertTrue(row.body.projectTag.pressable)
        XCTAssertTrue(row.body.projectTag.isAccessibilityElement())
        XCTAssertEqual(row.body.projectTag.accessibilityLabel(), "belloware-site")
        XCTAssertEqual(row.body.projectTag.accessibilityHelp(), "Show only this project's chats")
        func hit(_ view: SidebarChatRowView) -> NSView? {
            let tag = view.body.projectTag
            return view.row.hitTest(tag.convert(CGPoint(x: tag.bounds.midX, y: tag.bounds.midY), to: view.row.superview))
        }
        XCTAssertTrue(hit(row) === row.body.projectTag, "The row leaves a pressable tag its own click")
        row.body.projectTag.performClick(nil); sidebar.settle()
        XCTAssertEqual(model.sidebarProjectFilter, "site")
        XCTAssertNil(model.selectedID, "Pressing the tag does not open the chat")
        XCTAssertEqual(listed(sidebar), ["site-old"])
        XCTAssertEqual(shownChips(bar).last, "site", "The chosen chip is shown even when it was in the overflow")
        let narrowed = try XCTUnwrap(sidebar.list.views["chat|site-old"] as? SidebarChatRowView)
        XCTAssertFalse(narrowed.body.projectTag.pressable, "The narrowed list's tags are labels again")
        XCTAssertFalse(narrowed.body.projectTag.isAccessibilityElement())
        XCTAssertTrue(hit(narrowed) === narrowed.row, "A label tag leaves its click to the row, which opens the chat")
    }

    @MainActor func testAChosenProjectIsShownFromTheTopOfItsList() throws {
        let model = try fixture()
        model.chats += (0..<30).map { chat("many-\($0)", in: "app", order: Int64(1_000 + $0)) }
        let sidebar = makeSidebar(model, width: 300, height: 500)
        let clip = sidebar.scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 900)); sidebar.scroll.reflectScrolledClipView(clip); sidebar.settle()
        XCTAssertGreaterThan(clip.bounds.minY, 0)
        try XCTUnwrap(sidebar.projectFilter.buttons["app"]).performClick(nil); sidebar.settle()
        XCTAssertEqual(listed(sidebar).count, 32)
        XCTAssertGreaterThan(sidebar.list.frame.height, clip.bounds.height, "The narrowed list still scrolls")
        XCTAssertEqual(clip.bounds.minY, 0, "A narrowed list starts at its top, newest first")
        // Back to every project, from its top too: the narrowed list's first
        // chat is second there, under another project's pinned chat.
        sidebar.projectFilter.all.performClick(nil); sidebar.settle()
        XCTAssertEqual(Array(listed(sidebar).prefix(2)), ["box-pinned", "many-29"])
        XCTAssertEqual(clip.bounds.minY, 0, "Every project's list starts at its top as well")
    }

    @MainActor func testSearchLooksAcrossEveryProjectWhileTheChipsGiveWayToItsScope() throws {
        let model = try fixture()
        let sidebar = makeSidebar(model, width: 300, height: 900)
        model.setSidebarProjectFilter("box"); sidebar.settle()
        XCTAssertEqual(listed(sidebar), ["box-pinned", "save"])
        sidebar.setFilter("Chat s"); sidebar.settle()
        XCTAssertEqual(Set(listed(sidebar)), ["save", "scroll", "site-old"], "A search lists every project's matches")
        XCTAssertEqual(Set(model.sidebarChatOrder), ["save", "scroll", "site-old"])
        XCTAssertTrue(sidebar.projectFilter.isHidden); XCTAssertFalse(sidebar.searchScope.isHidden)
        XCTAssertTrue(rows(sidebar.list.contents).allSatisfy { !$0.state.choosesProject }, "Tags only label rows during a search")
        XCTAssertEqual(model.sidebarProjectFilter, "box", "The choice waits for the search to end")
        sidebar.setFilter(""); sidebar.settle()
        XCTAssertFalse(sidebar.projectFilter.isHidden); XCTAssertTrue(sidebar.searchScope.isHidden)
        XCTAssertEqual(listed(sidebar), ["box-pinned", "save"])
        XCTAssertTrue(try XCTUnwrap(sidebar.projectFilter.buttons["box"]).chosen)
    }

    // MARK: Overflow

    @MainActor func testOverflowMenuListsHiddenProjectsAndChoosingOnePromotesItsChip() throws {
        let model = try fixture()
        let sidebar = makeSidebar(model, width: WindowChrome.minimumSidebarWidth, height: 900)
        let bar = sidebar.projectFilter
        XCTAssertEqual(shownChips(bar), ["app"])
        XCTAssertFalse(bar.more.isHidden)
        XCTAssertEqual(bar.more.count, 4)
        XCTAssertEqual(bar.more.accessibilityRole(), .menuButton)
        XCTAssertEqual(bar.more.accessibilityValue() as? String, "4 more projects")
        var placed: [NSView] = [bar.all, bar.more]
        placed += bar.placement.shown.compactMap { bar.buttons[bar.laidOut[$0].projectID] }
        for view in placed {
            XCTAssertGreaterThanOrEqual(view.frame.minX, 0); XCTAssertLessThanOrEqual(view.frame.maxX, bar.bounds.width + 0.5)
        }
        var shown: NSMenu?
        PiMenus.intercept = { menu, _ in shown = menu }
        defer { PiMenus.intercept = nil }
        bar.more.performClick(nil)
        let menu = try XCTUnwrap(shown)
        XCTAssertEqual(menu.items.map { $0.identifier?.rawValue ?? "" },
                       ["box", scratch, "gone", "site"].map { "sidebarProjectFilterMenu-" + $0 }, "Hidden projects, newest first")
        XCTAssertEqual(menu.items.map(\.title), ["BelloBox", "No project", "Retained chats", "belloware-site"])
        XCTAssertTrue(PiMenus.perform("sidebarProjectFilterMenu-site", in: menu)); sidebar.settle()
        XCTAssertEqual(model.sidebarProjectFilter, "site")
        XCTAssertEqual(listed(sidebar), ["site-old"])
        XCTAssertEqual(shownChips(bar), ["site"], "The chosen chip takes the last place that fits")
        XCTAssertEqual(bar.more.count, 4)
        let chosen = try XCTUnwrap(bar.buttons["site"])
        XCTAssertFalse(chosen.isHidden); XCTAssertTrue(chosen.chosen)
        XCTAssertLessThanOrEqual(bar.more.frame.maxX, bar.bounds.width + 0.5)
        shown = nil; bar.more.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(shown).items.map(\.title), ["pi-app", "BelloBox", "No project", "Retained chats"])

        sidebar.width = WindowChrome.sidebarWidth; sidebar.frame.size.width = WindowChrome.sidebarWidth; sidebar.settle()
        XCTAssertEqual(shownChips(bar), ["app", "site"], "Wider, the chips in order fill the room, the chosen one among them")
        XCTAssertEqual(bar.more.count, 3)
    }

    @MainActor func testEveryChipFitsWithoutAnOverflowWhenThereIsRoom() throws {
        let model = try fixture()
        model.chats.removeAll { !["app", "box"].contains($0.workspaceID) }
        let sidebar = makeSidebar(model, width: WindowChrome.sidebarWidth, height: 900)
        XCTAssertEqual(shownChips(sidebar.projectFilter), ["app", "box"])
        XCTAssertTrue(sidebar.projectFilter.more.isHidden)
    }

    @MainActor func testChipFitCutsOnlyAFirstChipShortAndAlwaysShowsTheChosenOne() {
        let more: (Int) -> CGFloat = { _ in 40 }
        func place(_ natural: [CGFloat], chosen: Int? = nil, available: CGFloat) -> SidebarChipFit.Placement {
            SidebarChipFit.place(natural: natural, chosen: chosen, available: available, leading: 40, spacing: 4, minimum: 50, more: more)
        }
        XCTAssertEqual(place([60, 60], available: 200), .init(shown: [0, 1], widths: [60, 60], hidden: []))
        XCTAssertEqual(place([60, 70, 60], available: 200), .init(shown: [0], widths: [60], hidden: [1, 2]),
                       "Whole chips only: the second is not cut to fill the room")
        XCTAssertEqual(place([200, 60], available: 200), .init(shown: [0], widths: [116], hidden: [1]),
                       "A first chip with no room to be whole is cut short")
        XCTAssertEqual(place([60, 70, 60], chosen: 2, available: 200), .init(shown: [2], widths: [60], hidden: [0, 1]))
        XCTAssertEqual(place([60, 60, 60, 60], available: 300).shown, [0, 1, 2, 3], "The last chip needs no room for \"+N\"")
        XCTAssertEqual(place([60, 60, 60, 60], chosen: 3, available: 240), .init(shown: [0, 3], widths: [60, 60], hidden: [1, 2]))
        XCTAssertEqual(place([60, 60, 60, 200], chosen: 3, available: 260).shown, [3], "A wide chosen chip goes first, cut short")
    }

    @MainActor func testChipOrderHoldsWhileThePointerIsOverTheBar() throws {
        let model = try fixture()
        let sidebar = makeSidebar(model, width: 300, height: 900)
        let bar = sidebar.projectFilter
        XCTAssertEqual(shownChips(bar), ["app", "box"])
        func pointer(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        bar.mouseEntered(with: try pointer(.mouseEntered))
        model.chats[model.chats.firstIndex { $0.id == "loose" }!].sidebarOrder = 999
        sidebar.settle()
        XCTAssertEqual(model.sidebarProjectChips.first?.projectID, scratch)
        XCTAssertEqual(shownChips(bar), ["app", "box"], "A chip does not move under the pointer")
        bar.mouseExited(with: try pointer(.mouseExited)); sidebar.settle()
        XCTAssertEqual(shownChips(bar), [scratch, "app"])
    }

    // MARK: Opening, new chats, persistence

    @MainActor func testOpeningAChatFromElsewhereInAnotherProjectListsEveryProjectAgain() async throws {
        let model = try fixture()
        let journal = try SearchJournal(model.root.appendingPathComponent("scroll.jsonl"), id: "scroll")
        try journal.message("reply", role: "assistant", "Scrolling answer")
        model.chats[model.chats.firstIndex { $0.id == "scroll" }!].path = journal.url.path
        model.setSidebarProjectFilter("box")
        model.revealProjectChat(try XCTUnwrap(model.record("save")))
        XCTAssertEqual(model.sidebarProjectFilter, "box", "A chat in the chosen project is already listed")
        await model.openFromSidebar("scroll")
        XCTAssertEqual(model.selectedID, "scroll")
        XCTAssertEqual(model.sidebarProjectFilter, "box", "A search result opened from the sidebar keeps the choice")
        await model.select("scroll")
        XCTAssertNil(model.sidebarProjectFilter, "Opening a chat of another project from elsewhere lists every project")
        XCTAssertEqual(ids(model).count, 7)
    }

    @MainActor func testNewChatInFlatStartsInTheChosenProject() async throws {
        let model = try fixture(); prepareNewChat(model)
        model.selectedID = "scroll"; model.selectedWorkspaceID = "app"
        model.setSidebarProjectFilter("box")
        model.newChat()
        let created = try await waitForNewChat(model, after: "scroll")
        XCTAssertEqual(created.workspaceID, "box")
        XCTAssertEqual(model.sidebarProjectFilter, "box", "The new chat is listed where the reader is looking")
        XCTAssertTrue(ids(model).contains(created.id))

        let other = try fixture(); prepareNewChat(other)
        other.selectedID = "scroll"; other.selectedWorkspaceID = "app"
        other.setSidebarProjectFilter(scratch)
        other.newChat()
        let elsewhere = try await waitForNewChat(other, after: "scroll")
        XCTAssertEqual(elsewhere.workspaceID, "app", "No project takes no new chats: the selected chat's project does")
        XCTAssertNil(other.sidebarProjectFilter, "The new chat's project is listed")
    }

    @MainActor func testTheChoiceIsNotSavedAndTopicsIgnoresIt() async throws {
        let model = try fixture()
        model.setSidebarFlat(false)
        let topics = build(model)
        model.setSidebarFlat(true)
        model.setSidebarProjectFilter("box")
        XCTAssertEqual(model.sidebarFlatProject, "box")
        model.setSidebarFlat(false)
        XCTAssertNil(model.sidebarFlatProject)
        XCTAssertEqual(build(model), topics, "Topics lists every project and topic as before")
        let sidebar = makeSidebar(model, width: 300)
        XCTAssertTrue(sidebar.projectFilter.isHidden, "Topics has no chips")
        model.setSidebarFlat(true); sidebar.settle()
        XCTAssertEqual(listed(sidebar), ["box-pinned", "save"], "Back in Flat, the choice holds for the session")
        XCTAssertFalse(sidebar.projectFilter.isHidden)

        // A relaunch: a new model starts with no choice, and the store holds none to restore.
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        let read = try await model.store?.get(SidebarViewState.self, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID)
        let stored = try XCTUnwrap(read)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("box"))
        let projectRecords = try await model.store?.list(ProjectSidebarState.self, kind: "project-sidebar") ?? []
        for record in projectRecords {
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("\"box\""))
        }
        model.sidebarProjectFilter = nil; model.sidebarViewState = SidebarViewState()
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(model.sidebarListsFlat, "Flat itself is remembered")
        XCTAssertNil(model.sidebarProjectFilter, "The chosen project is not")
        XCTAssertEqual(ids(model).count, 7)
    }

    @MainActor func testAProjectThatIsNoLongerListedFallsBackToAll() throws {
        let model = try fixture()
        let sidebar = makeSidebar(model, width: 300)
        model.setSidebarProjectFilter("gone"); sidebar.settle()
        XCTAssertEqual(listed(sidebar), ["retained"])
        model.chats.removeAll { $0.workspaceID == "gone" }; sidebar.settle()
        XCTAssertNil(model.sidebarFlatProject)
        XCTAssertEqual(listed(sidebar).count, 6)
        XCTAssertTrue(sidebar.projectFilter.all.chosen)
    }

    // MARK: Look

    /// At rest the pressable tag is drawn as the badge it replaces.
    @MainActor func testTheTagLooksAsTheBadgeDidUntilThePointerIsOverIt() throws {
        for (dark, text) in [(false, "BelloBox"), (true, "Retained chats")] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40)); window.contentView = host
            defer { window.contentView = nil; window.close() }
            let badge = PiKit.Badge(text: text); badge.compact = true
            let tag = SidebarProjectTag(); tag.text = text; tag.pressable = true
            for view in [badge, tag] as [NSView] { host.addSubview(view) }
            badge.frame = CGRect(origin: CGPoint(x: 10, y: 4), size: badge.intrinsicContentSize)
            tag.frame = CGRect(origin: CGPoint(x: 10, y: 22), size: tag.intrinsicContentSize)
            XCTAssertEqual(tag.intrinsicContentSize, badge.intrinsicContentSize)
            XCTAssertEqual(tag.naturalWidth, badge.naturalWidth)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            func pixels(_ view: NSView) throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap
            }
            let a = try pixels(badge), b = try pixels(tag)
            XCTAssertEqual(a.pixelsWide, b.pixelsWide); XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
            var differing = 0
            for x in 0..<min(a.pixelsWide, b.pixelsWide) { for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let channels = [(p.redComponent, q.redComponent), (p.greenComponent, q.greenComponent), (p.blueComponent, q.blueComponent), (p.alphaComponent, q.alphaComponent)]
                if channels.contains(where: { abs($0.0 - $0.1) * 255 > 8 }) { differing += 1 }
            } }
            XCTAssertLessThanOrEqual(Double(differing) / Double(a.pixelsWide * a.pixelsHigh), 0.02, "\(text): \(differing) pixels differ")
            tag.setHovering(true)
            XCTAssertEqual(tag.fill.backgroundColor, tag.piCGColor(.piFillStrong), "The pointer shades a pressable tag")
            tag.pressable = false
            XCTAssertEqual(tag.fill.backgroundColor, tag.piCGColor(.piFill), "A label tag stays quiet under the pointer")
        }
    }
}
