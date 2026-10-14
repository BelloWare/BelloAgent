import XCTest
import AppKit
@testable import PiApp

/// Global Topics / Flat, on isolated desktop stores; no real configuration or helper.
final class SidebarFlatTopicsTests: XCTestCase {
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("flat-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.appendingPathComponent("project").path, trusted: true),
                            WorkspaceRecord(id: "other", path: root.appendingPathComponent("other").path, trusted: true)]
        model.topics = [TopicRecord(id: "billing", workspaceID: "project", title: "Billing"),
                        TopicRecord(id: "research", workspaceID: "project", title: "Research"),
                        TopicRecord(id: "elsewhere", workspaceID: "other", title: "Elsewhere")]
        model.chats = [chat("a", order: 50, topic: "billing"), chat("b", order: 40),
                       chat("b-side", order: 70, topic: "research", parent: "b"), chat("c", order: 60, topic: "research"),
                       chat("d", order: 10, topic: "billing"), chat("pinned", order: 1, pinned: true),
                       chat("o1", in: "other", order: 65, topic: "elsewhere"), chat("o2", in: "other", order: 20)]
        return model
    }
    private func chat(_ id: String, in project: String = "project", order: Int64, topic: String? = nil,
                      parent: String? = nil, archived: Bool = false, pinned: Bool = false) -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: project, title: "Chat " + id, path: nil, profileID: "fixture",
                               sidebarOrder: order, parentSessionID: parent)
        value.topicID = topic
        if archived { value.archivedAt = Date() }
        if pinned { value.pinnedAt = Date() }
        return value
    }
    @MainActor private func flat(_ model: WorkspaceModel, _ enabled: Bool = true) {
        model.setSidebarFlat(enabled)
        if enabled { model.setSidebarShownRoots("flat:all", to: 100, in: "") }
    }
    @MainActor private func isFlat(_ model: WorkspaceModel) -> Bool { model.sidebarListsFlat }
    @MainActor private func build(_ model: WorkspaceModel, filter: String = "", width: CGFloat = 300) -> SidebarListContents {
        SidebarListContents.build(model: model, filter: filter, sidebarWidth: width, confirmingRemove: [], removing: [], dropTarget: nil)
    }
    @MainActor private func rows(_ contents: SidebarListContents) -> [SidebarGroupRow] {
        contents.entries.compactMap { if case .chat(let chat, let state, _) = $0 { return SidebarGroupRow(chat: chat, state: state) }; return nil }
    }
    @MainActor private func ids(_ model: WorkspaceModel, filter: String = "") -> [String] { rows(build(model, filter: filter)).map(\.id) }
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor private func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        for entry in menu.items {
            if entry.identifier?.rawValue == id { return entry }
            if let nested = entry.submenu, let found = item(id, in: nested) { return found }
        }
        return nil
    }
    @MainActor private func headerMenu(_ model: WorkspaceModel) throws -> NSMenu {
        let sidebar = makeSidebar(model, width: 300, height: 900)
        let button = try XCTUnwrap(views(PiKit.MenuControl.self, in: sidebar).first { $0.accessibilityIdentifier() == "sidebarMenu" })
        return PiMenus.menu(button.entries())
    }

    @MainActor func testCombinedOrderingIncludesScratchAndRetainedProjectsWithoutHeaders() throws {
        let model = try fixture()
        model.chats += [chat("loose", in: WorkspaceRecord.scratchID, order: 55), chat("retained", in: "missing", order: 80)]
        model.setProjectExpanded("other", expanded: false)
        flat(model)
        let contents = build(model)
        XCTAssertEqual(rows(contents).map(\.id), ["pinned", "retained", "b", "b-side", "o1", "c", "loose", "a", "o2", "d"])
        XCTAssertFalse(contents.entries.contains { if case .projectHeader = $0 { return true }; if case .topicHeader = $0 { return true }; return false })
        XCTAssertEqual(zip(contents.entries, contents.owners).compactMap { entry, owner in
            if case .chat(let chat, _, let project) = entry { return chat.workspaceID == owner.project && project == owner.project && owner.topic == nil }; return nil
        }, Array(repeating: true, count: 10))
        model.chats[model.chats.firstIndex { $0.id == "o2" }!].sidebarOrder = 95
        XCTAssertEqual(Array(ids(model).prefix(3)), ["pinned", "o2", "retained"], "Activity crosses project boundaries")
    }

    @MainActor func testEveryRowHasItsProjectAndOwnTopicEvenWhenItsParentSharesThem() throws {
        let model = try fixture()
        model.chats += [chat("same-topic-side", order: 30, topic: "billing", parent: "a"),
                        chat("loose", in: WorkspaceRecord.scratchID, order: 25), chat("retained", in: "missing", order: 15)]
        flat(model)
        let sidebar = makeSidebar(model, width: 340, height: 1400)
        for row in rows(build(model)) {
            let view = try XCTUnwrap(sidebar.list.views["chat|" + row.id] as? SidebarChatRowView)
            let name = try XCTUnwrap(model.sidebarProjects.first { $0.id == row.chat.workspaceID }?.name)
            XCTAssertTrue(view.row.accessibilityLabel()?.contains("project " + name) == true, row.id)
        }
        let tagged = Dictionary(uniqueKeysWithValues: rows(build(model)).map { ($0.id, $0.state.topicTag) })
        XCTAssertEqual(tagged["same-topic-side"], "Billing")
        XCTAssertEqual(tagged["o1"], "Elsewhere")
        XCTAssertEqual(tagged["b-side"], "Research")
        XCTAssertNil(tagged["loose"]!)
    }

    @MainActor func testGlobalChoicePersistsBothWaysAndDoesNotRewriteProjectPreferences() async throws {
        let model = try fixture()
        flat(model)
        XCTAssertTrue(isFlat(model))
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        XCTAssertNil(model.projectSidebarStates["project"], "The global choice is not a project preference")
        model.sidebarViewState = SidebarViewState()
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(isFlat(model))
        flat(model, false)
        let savedAgain = await model.flushProjectSidebarState(); XCTAssertTrue(savedAgain)
        model.sidebarViewState = SidebarViewState(flat: true)
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(isFlat(model))
    }

    @MainActor func testMigrationReadsAnyOldProjectIncludingAnUnlistedOneAndOnlyRunsOnce() async throws {
        let model = try fixture()
        let old = ProjectSidebarState(id: "removed-project", revision: 7, flatTopics: true)
        try await model.store?.put(old, kind: "project-sidebar", id: old.id, revision: old.revision)
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(isFlat(model), "Migration includes records filtered out of today's listed projects")
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        flat(model, false)
        let savedAgain = await model.flushProjectSidebarState(); XCTAssertTrue(savedAgain)
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(isFlat(model), "An explicit Topics choice wins over legacy Flat forever")
        let retained = try await model.store?.get(ProjectSidebarState.self, kind: "project-sidebar", id: old.id)
        XCTAssertEqual(retained, old)
    }

    @MainActor func testMigrationDefaultsToTopicsAndOldRecordsStillDecode() async throws {
        let old = Data(#"{"id":"project","expanded":true,"archived":false,"revision":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectSidebarState.self, from: old)
        XCTAssertNil(decoded.flatTopics)
        var legacy = decoded; legacy.flatTopics = true
        XCTAssertEqual(try JSONDecoder().decode(ProjectSidebarState.self, from: JSONEncoder().encode(legacy)), legacy)
        let model = try fixture()
        try await model.store?.put(decoded, kind: "project-sidebar", id: decoded.id, revision: decoded.revision)
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(isFlat(model))
    }

    @MainActor func testCombinedPaginationPersistsIndependentlyOfProjectPages() async throws {
        let model = try fixture()
        flat(model); model.setSidebarShownRoots("flat:all", to: SidebarSessionPresentation.pageSize, in: "")
        XCTAssertEqual(rows(build(model)).filter { $0.state.indent == 0 }.count, SidebarSessionPresentation.pageSize)
        let page = try XCTUnwrap(build(model).entries.first { if case .pagination = $0 { return true }; return false })
        guard case .pagination(let group, let project, let hidden, _, _) = page else { return }
        XCTAssertEqual(group, "flat:all"); XCTAssertEqual(hidden, 2)
        model.setSidebarShownRoots(group, to: 15, in: project)
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        model.sidebarPageSizes = [:]; try await model.restoreProjectSidebarStates()
        XCTAssertEqual(model.sidebarShownRoots(group), 15)
        XCTAssertEqual(ids(model).count, 8)
        XCTAssertTrue(model.projectSidebarStates.values.allSatisfy { $0.shownRoots?[group] == nil })
    }

    @MainActor func testSidesAndManagedChildrenStayUnderTheirParentAndKeepFolds() throws {
        let model = try fixture()
        var child = chat("agent", order: 100, topic: "research", parent: "b")
        child.delegation = SubagentLink(delegationID: "d", childSessionID: "agent", budgetOwnerSessionID: "b",
                                       call: .init(parentSessionID: "b", assistantMessageID: "m", toolCallID: "call"), parentTurnID: "t", parentExecutionID: "e")
        model.chats.append(child)
        model.sides["b"] = SideRecord(id: "unsaved", parentID: "b", workspaceID: "project", profileID: "fixture", title: "Side", kept: false)
        flat(model)
        XCTAssertFalse(ids(model).contains("agent"))
        model.setSubagentGroupExpanded("b", expanded: true)
        let contents = build(model)
        XCTAssertEqual(Array(rows(contents).map(\.id).prefix(4)), ["pinned", "b", "agent", "b-side"])
        let family = contents.entries.map(\.id)
        XCTAssertLessThan(try XCTUnwrap(family.firstIndex(of: "subagents|b")), try XCTUnwrap(family.firstIndex(of: "chat|agent")))
        XCTAssertLessThan(try XCTUnwrap(family.firstIndex(of: "chat|agent")), try XCTUnwrap(family.firstIndex(of: "side|unsaved")))
        let transient = try XCTUnwrap(contents.entries.compactMap { if case .side(let state) = $0 { return state }; return nil }.first)
        XCTAssertEqual(transient.projectTag, "project")
        XCTAssertEqual(rows(contents).first { $0.id == "agent" }?.state.projectTag, "project")
        XCTAssertEqual(rows(contents).first { $0.id == "agent" }?.state.topicTag, "Research")
        model.setSidebarSideFolded("b", folded: true)
        XCTAssertFalse(ids(model).contains("b-side")); XCTAssertTrue(ids(model).contains("agent"))
        XCTAssertFalse(build(model).entries.contains { $0.id == "side|unsaved" })
        XCTAssertEqual(ids(model, filter: "b-side"), ["b", "b-side"])
    }

    @MainActor func testInvalidCrossProjectParentDoesNotReparentAChat() throws {
        let model = try fixture()
        model.chats[model.chats.firstIndex { $0.id == "o1" }!].parentSessionID = "b"
        flat(model)
        let listed = rows(build(model))
        XCTAssertEqual(listed.first { $0.id == "o1" }?.state.indent, listed.first { $0.id == "b" }?.state.indent)
    }

    @MainActor func testRowStatesAndTopicsRoundTripStayUnchanged() throws {
        let model = try fixture()
        model.chats[2].topicID = nil
        model.selectedID = "c"; model.selectedWorkspaceID = "project"; model.markedSessionIDs = ["a"]
        model.unreadStates["a"] = SessionReadState(id: "a", observedAssistantCount: 2, latestAssistantID: "m", unreadOutputs: 1)
        model.runHolds["b"] = RunHoldRecord(id: "b", state: "paused"); model.draftChatIDs.insert("a")
        model.noteOpened("a"); model.noteOpened("c"); model.collapsedSidebarSides.insert("b")
        let before = build(model)
        flat(model)
        let after = Dictionary(uniqueKeysWithValues: rows(build(model)).map { ($0.id, $0.state) })
        XCTAssertEqual(after["a"]?.unreadCount, 1); XCTAssertEqual(after["a"]?.marked, true)
        XCTAssertEqual(after["a"]?.hasDraft, true); XCTAssertEqual(after["b"]?.heldRun, "paused")
        XCTAssertEqual(after["c"]?.recency, 0); XCTAssertEqual(after["c"]?.selected, true)
        XCTAssertNil(after["b-side"]); XCTAssertTrue(after.values.allSatisfy { !$0.draggable })
        flat(model, false)
        XCTAssertEqual(build(model), before, "All Topics entries, gaps and owners are unchanged")
    }

    @MainActor func testArchivedAndSearchAcrossProjectsKeepTagsAndAncestors() throws {
        let model = try fixture()
        model.chats += [chat("old-a", order: 200, topic: "billing", archived: true),
                        chat("old-o", in: "other", order: 300, topic: "elsewhere", archived: true)]
        flat(model)
        XCTAssertFalse(ids(model).contains("old-a"))
        model.setArchivedChatsShown(true)
        XCTAssertEqual(Array(ids(model).suffix(2)), ["old-o", "old-a"])
        XCTAssertEqual(build(model).entries.filter { if case .archiveHeading = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(ids(model, filter: "billing"), ["a", "d", "old-a"])
        XCTAssertEqual(ids(model, filter: "other"), ["o1", "o2", "old-o"])
        XCTAssertEqual(ids(model, filter: "b-side"), ["b", "b-side"])
        XCTAssertEqual(ids(model, filter: "no matching text"), [])
        model.sidebarFilter = "elsewhere"
        XCTAssertEqual(model.sidebarChatOrder, ["o1", "old-o"])
        XCTAssertEqual(rows(build(model, filter: "elsewhere")).map(\.state.topicTag), ["Elsewhere", "Elsewhere"])
    }

    @MainActor func testKeyboardOrderAndRangeSelectionUseTheCombinedOrder() throws {
        let model = try fixture(); flat(model)
        XCTAssertEqual(model.sidebarChatOrder, ids(model))
        model.sidebarFilter = "Chat o"
        XCTAssertEqual(model.sidebarChatOrder, ["o1", "o2"])
    }

    @MainActor func testFlatHasNoDragSourcesOrDropTargets() throws {
        let model = try fixture(); flat(model)
        let sidebar = makeSidebar(model, width: 300, height: 1000)
        XCTAssertTrue(rows(sidebar.list.contents).allSatisfy { !$0.state.draggable })
        for id in ["chat|a", "chat|b-side", "chat|o1"] {
            let frame = try XCTUnwrap(sidebar.list.frame(of: id))
            XCTAssertNil(sidebar.list.dropTarget(at: CGPoint(x: frame.midX, y: frame.midY)))
            XCTAssertNil(sidebar.list.dropTarget(at: CGPoint(x: 10, y: frame.maxY + 1)))
        }
    }

    @MainActor func testHeaderMenuSwitchesGloballyAndProjectMenusHaveNoViewChoice() throws {
        let model = try fixture()
        let project = PiMenus.menu(ProjectSidebarActions.entries(model: model, state: ProjectHeaderState(projectID: "project"), expand: nil))
        XCTAssertFalse(project.items.contains { ["Topics", "Flat", "Show Chats"].contains($0.title) })
        var menu = try headerMenu(model)
        XCTAssertEqual(item("sidebarView-topics", in: menu)?.state, .on)
        XCTAssertEqual(item("sidebarView-flat", in: menu)?.state, .off)
        XCTAssertTrue(PiMenus.perform("sidebarView-flat", in: menu)); XCTAssertTrue(isFlat(model))
        menu = try headerMenu(model)
        XCTAssertEqual(item("sidebarView-flat", in: menu)?.state, .on)
        XCTAssertTrue(PiMenus.perform("sidebarView-topics", in: menu)); XCTAssertFalse(isFlat(model))
    }

    @MainActor func testProjectsSubmenuKeepsActionsAndAvailability() async throws {
        let model = try fixture(); flat(model)
        model.workspaces.append(WorkspaceRecord(id: "untrusted", path: "/untrusted", trusted: false))
        model.chats.append(chat("retained", in: "missing", order: 3))
        model.chats.append(chat("loose", in: WorkspaceRecord.scratchID, order: 2))
        let menu = try headerMenu(model)
        let projects = try XCTUnwrap(item("sidebarProjects", in: menu)?.submenu)
        XCTAssertEqual(projects.items.count, model.sidebarProjects.count)
        XCTAssertEqual(item("sidebarProjects-project-newChat", in: menu)?.isEnabled, true)
        XCTAssertEqual(item("sidebarProjects-untrusted-newChat", in: menu)?.isEnabled, false)
        XCTAssertEqual(item("sidebarProjects-missing-newChat", in: menu)?.isEnabled, false)
        XCTAssertEqual(item("sidebarProjects-missing-changes", in: menu)?.isEnabled, false)
        XCTAssertTrue(PiMenus.perform("sidebarProjects-other-changes", in: menu))
        XCTAssertEqual(model.tabs.pane.tabs.last?.key, "other")
        prepareNewChat(model)
        let previous = model.selectedID
        XCTAssertTrue(PiMenus.perform("sidebarProjects-other-newChat", in: menu))
        let created = try await waitForNewChat(model, after: previous)
        XCTAssertEqual(created.workspaceID, "other")
        XCTAssertTrue(PiMenus.perform("sidebarProjects-other-newTopic", in: menu))
        XCTAssertEqual(model.topicEditor?.projectID, "other"); model.topicEditor = nil
        XCTAssertTrue(PiMenus.perform("sidebarProjects-other-manage", in: menu))
        XCTAssertEqual(model.selectedWorkspaceID, "other"); XCTAssertTrue(model.showWorkspaceManager)
        XCTAssertFalse(projects.items.flatMap { $0.submenu?.items ?? [] }.contains { $0.title.contains("Expand") || $0.title.contains("Collapse") })
    }

    @MainActor private func prepareNewChat(_ model: WorkspaceModel) {
        var profile = ProfileRecord(); profile.id = "fixture"; profile.api = LiteLLMConfiguration.supportedAPI
        model.profiles = [profile]; model.profileChoice = profile.id
    }
    @MainActor private func waitForNewChat(_ model: WorkspaceModel, after id: String?) async throws -> ChatRecord {
        for _ in 0..<300 where model.selectedID == id || !model.workspaceChangesInFlight.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(model.selectedID.flatMap(model.record))
    }
    @MainActor func testNewChatUsesSelectedChatsProjectBeforeSelectedWorkspace() async throws {
        let model = try fixture(); prepareNewChat(model); flat(model)
        model.selectedID = "o1"; model.selectedWorkspaceID = "project"
        let sidebar = makeSidebar(model)
        XCTAssertTrue(sidebar.newChat.isEnabled); sidebar.newChat.performClick(nil)
        let created = try await waitForNewChat(model, after: "o1")
        XCTAssertEqual(created.workspaceID, "other"); XCTAssertNil(created.topicID, "Top New Chat in Flat starts at the project root")
    }
    @MainActor func testNewChatFallsBackFromScratchAndUnavailableToSelectedThenRememberedThenFirstTrusted() async throws {
        for fallback in ["selected", "remembered", "first"] {
            let model = try fixture(); prepareNewChat(model); flat(model)
            model.workspaces.insert(WorkspaceRecord(id: "untrusted", path: "/untrusted", trusted: false), at: 0)
            model.chats.append(chat("retained", in: "missing", order: 100))
            model.selectedID = "retained"; model.selectedWorkspaceID = fallback == "selected" ? "other" : "missing"
            if fallback == "remembered" { model.selectionMemory.remembered = RememberedSelection(projectID: "other") }
            model.newChat()
            let created = try await waitForNewChat(model, after: "retained")
            XCTAssertEqual(created.workspaceID, fallback == "first" ? "project" : "other", fallback)
        }
        let model = try fixture(); prepareNewChat(model); flat(model)
        model.chats.append(chat("loose", in: WorkspaceRecord.scratchID, order: 99))
        model.selectedID = "loose"; model.selectedWorkspaceID = "other"; model.newChat()
        let scratchCreated = try await waitForNewChat(model, after: "loose")
        XCTAssertEqual(scratchCreated.workspaceID, "other")
    }
    @MainActor func testNewChatNeverUsesUntrustedUnavailableOrScratchProjects() throws {
        let model = try fixture(); prepareNewChat(model); flat(model)
        model.workspaces = [WorkspaceRecord(id: "untrusted", path: "/untrusted", trusted: false)]
        model.chats.append(chat("unsafe", in: "untrusted", order: 100))
        model.selectedID = "unsafe"; model.selectedWorkspaceID = "missing"
        model.selectionMemory.remembered = RememberedSelection(projectID: "project")
        let count = model.chats.count
        XCTAssertFalse(makeSidebar(model).newChat.isEnabled)
        model.newChat(); XCTAssertEqual(model.chats.count, count); XCTAssertTrue(model.workspaceChangesInFlight.isEmpty)
    }

    @MainActor func testTagsFitAtMinimumWidthAndTopicsPixelsSurviveTheRoundTrip() throws {
        let model = try fixture(); model.topics[0].title = "Billing and invoicing for the enterprise plan"
        for (width, dark) in [(CGFloat(300), false), (WindowChrome.minimumSidebarWidth, true)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let sidebar = makeSidebar(model, width: width, height: 1000); window.contentView = sidebar
            defer { window.contentView = nil; window.close() }
            func picture() throws -> Data {
                sidebar.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
                return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            }
            let before = try picture(); flat(model); sidebar.settle()
            let row = try XCTUnwrap(sidebar.list.views["chat|a"] as? SidebarChatRowView)
            row.layoutSubtreeIfNeeded()
            XCTAssertFalse(row.body.topicTag.isHidden)
            XCTAssertFalse(row.body.projectTag.isHidden)
            XCTAssertEqual(row.body.projectTag.text, "project")
            let projectFrame = row.body.projectTag.convert(row.body.projectTag.bounds, to: row.body)
            XCTAssertLessThanOrEqual(projectFrame.maxX, row.body.bounds.width + 0.5)
            let tagFrame = row.body.topicTag.convert(row.body.topicTag.bounds, to: row.body)
            XCTAssertLessThanOrEqual(tagFrame.maxX, row.body.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(tagFrame.maxY, row.body.bounds.height + 0.5)
            XCTAssertTrue(row.row.accessibilityLabel()?.contains("project project") == true)
            let archive = try XCTUnwrap(views(PiKit.ButtonBase.self, in: row.body).first { $0.accessibilityIdentifier() == "archiveChat" })
            archive.performClick(nil); row.layoutSubtreeIfNeeded()
            XCTAssertFalse(row.body.topicTag.isHidden, "Both tags remain while Archive asks")
            for button in views(PiKit.ButtonBase.self, in: row.body) where !button.isHidden {
                XCTAssertLessThanOrEqual(button.convert(button.bounds, to: row.body).maxX, row.body.bounds.width + 0.5)
            }
            let keep = try XCTUnwrap(views(PiKit.IconButton.self, in: row.body).first { $0.label == "Keep chat" }); keep.performClick(nil)
            flat(model, false); sidebar.settle(); XCTAssertEqual(try picture(), before)
        }
    }

    @MainActor func testNoListedProjectsKeepsTheExistingAddProjectEmptyState() throws {
        let model = try fixture(); model.chats = []; model.workspaces = []; model.topics = []
        flat(model)
        XCTAssertTrue(build(model).entries.isEmpty, "The centered Add a project empty state owns this screen")
    }

    @MainActor func testEmptyCombinedListInvalidatesAndRepeatedBuildsReuseTheIndex() throws {
        let model = try fixture(); model.chats = []; flat(model)
        XCTAssertEqual(ids(model), [])
        XCTAssertTrue(build(model).entries.contains {
            if case .empty(_, "No chats yet", _) = $0 { return true }; return false
        }, "Configured projects with no chats still explain their empty list")
        model.chats = [chat("first", in: "other", order: 1)]
        XCTAssertEqual(ids(model), ["first"])
        let before = model.sidebarIndex.computations
        for _ in 0..<20 { _ = build(model); _ = model.sidebarChatOrder }
        XCTAssertLessThanOrEqual(model.sidebarIndex.computations - before, 2)
        model.chats = []; XCTAssertEqual(ids(model), [])
        model.chats = [chat("second", in: "missing", order: 2)]
        XCTAssertEqual(ids(model), ["second"])
    }
    @MainActor func testMessageSearchIncludesSnippetsAcrossProjectsAndArchivedSwitch() async throws {
        let model = try fixture(); flat(model)
        model.chats = []
        for (id, project, archived, order) in [("content-a", "project", false, 10), ("content-b", "other", false, 20), ("content-old", "other", true, 30)] {
            let journal = try SearchJournal(model.root.appendingPathComponent(id + ".jsonl"), id: id)
            try journal.message("answer-" + id, role: "assistant", "The marmalade migration is ready.")
            var item = chat(id, in: project, order: Int64(order), archived: archived); item.path = journal.url.path
            model.chats.append(item)
        }
        let sidebar = makeSidebar(model)
        await model.sidebarSearch.reconcileNow()
        sidebar.setFilter("marmalade"); await model.sidebarSearch.settleQuery(); sidebar.settle()
        XCTAssertEqual(rows(sidebar.list.contents).map(\.id), ["content-b", "content-a"])
        func snippets() -> [String] { sidebar.list.contents.entries.compactMap { if case .searchSnippet(let state) = $0 { return state.chatID }; return nil } }
        XCTAssertEqual(snippets(), ["content-b", "content-a"])
        model.setArchivedChatsShown(true); sidebar.settle()
        XCTAssertEqual(snippets(), ["content-b", "content-a", "content-old"])
        XCTAssertEqual(model.sidebarChatOrder, ["content-b", "content-a", "content-old"])
    }

    @MainActor func testMovingToTopicFromRowMenuRetagsWithoutReordering() async throws {
        let model = try fixture(); flat(model)
        for topic in model.topics { _ = try await model.store?.createTopic(topic) }
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let before = ids(model)
        let row = try XCTUnwrap(rows(build(model)).first { $0.id == "c" })
        let menu = PiMenus.menu(SidebarChatRowView.entries(model: model, chat: row.chat, state: row.state))
        XCTAssertTrue(PiMenus.perform("moveSessionToTopic-c-billing", in: menu))
        for _ in 0..<200 where model.record("c")?.topicID != "billing" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ids(model), before)
        XCTAssertEqual(rows(build(model)).first { $0.id == "c" }?.state.topicTag, "Billing")
        XCTAssertEqual(rows(build(model)).first { $0.id == "c" }?.state.projectTag, "project")
        XCTAssertTrue(model.sidebarListsFlat)
    }

    @MainActor func testUnkeptFocusedSideUsesItsSelectedParentsProjectAndUntrustedSelectionFallsBack() async throws {
        let model = try fixture(); prepareNewChat(model); flat(model)
        model.selectedID = "o1"; model.focusedSessionID = "unsaved-side"; model.selectedWorkspaceID = "project"
        model.newChat()
        let created = try await waitForNewChat(model, after: "o1")
        XCTAssertEqual(created.workspaceID, "other")
        model.workspaces[1].trusted = false
        model.selectedID = "o1"; model.focusedSessionID = "o1"; model.selectedWorkspaceID = "other"
        model.newChat()
        let fallback = try await waitForNewChat(model, after: "o1")
        XCTAssertEqual(fallback.workspaceID, "project")
    }

    @MainActor func testRetainedChatStillOpensHistoryWithoutAHelper() async throws {
        let model = try fixture(); flat(model)
        let journal = try SearchJournal(model.root.appendingPathComponent("retained.jsonl"), id: "retained")
        try journal.message("reply", role: "assistant", "Retained answer")
        var retained = chat("retained", in: "missing", order: 99); retained.path = journal.url.path
        model.chats.append(retained); try await model.store?.put(retained, kind: "chat", id: retained.id)
        await model.openFromSidebar(retained.id)
        XCTAssertEqual(model.selectedID, "retained")
        XCTAssertEqual(model.selected?.messages.first?.text, "Retained answer")
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(rows(build(model)).first { $0.id == "retained" }?.state.projectTag, "Retained chats · missing")
    }

}

private final class FlatStoreGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
}
private extension MetadataStore {
    func holdFlatReads(_ gate: FlatStoreGate, held: @Sendable () -> Void) { held(); gate.release.wait() }
}

extension SidebarFlatTopicsTests {
    @MainActor func testAChoiceAndPageMadeDuringRestoreWinOverTheLateRead() async throws {
        let model = try fixture(); model.sidebarPageSizes = [:]
        let store = try XCTUnwrap(model.store), gate = FlatStoreGate()
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            Task.detached { await store.holdFlatReads(gate) { held.resume() } }
        }
        let started = expectation(description: "restore reached its store read")
        let restoring = Task { started.fulfill(); try await model.restoreProjectSidebarStates() }
        await fulfillment(of: [started], timeout: 2)
        model.setSidebarFlat(true)
        model.setSidebarShownRoots("flat:all", to: 15, in: "")
        gate.release.signal()
        try await restoring.value
        XCTAssertTrue(model.sidebarListsFlat)
        XCTAssertEqual(model.sidebarShownRoots("flat:all"), 15)
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        model.sidebarViewState = SidebarViewState(); model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(model.sidebarListsFlat); XCTAssertEqual(model.sidebarShownRoots("flat:all"), 15)
    }

    @MainActor func testNewChatRechecksTrustAfterItsAsynchronousDefaultsRead() async throws {
        let model = try fixture(); prepareNewChat(model); flat(model)
        let saved = await model.flushProjectSidebarState(); XCTAssertTrue(saved)
        let store = try XCTUnwrap(model.store), gate = FlatStoreGate()
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            Task.detached { await store.holdFlatReads(gate) { held.resume() } }
        }
        model.selectedID = "o1"; model.selectedWorkspaceID = "other"; model.newChat()
        XCTAssertTrue(model.workspaceChangesInFlight.contains("other"))
        model.workspaces.removeAll { $0.id == "other" }
        gate.release.signal()
        for _ in 0..<200 where !model.workspaceChangesInFlight.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedID, "o1")
        XCTAssertTrue(model.pendingChatIDs.isEmpty)
    }

    @MainActor func testChoiceBeforeRestorePreservesStoredPagesAndTheirRevisionFloor() async throws {
        let model = try fixture()
        let saved = SidebarViewState(flat: false, shownRoots: ["flat:all": 25], revision: Int64(Date().timeIntervalSince1970 * 1_000_000) + 1_000_000_000)
        try await model.store?.put(saved, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID, revision: saved.revision)
        model.setSidebarFlat(true)
        let flushed = await model.flushProjectSidebarState(); XCTAssertTrue(flushed)
        model.sidebarViewState = SidebarViewState(); model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(model.sidebarListsFlat)
        XCTAssertEqual(model.sidebarShownRoots("flat:all"), 25)
        XCTAssertGreaterThan(model.sidebarViewState.revision, saved.revision)
    }

    @MainActor func testEditsDuringAWriteKeepTheLatestModeAndBothPageCounts() async throws {
        let model = try fixture(); let store = try XCTUnwrap(model.store)
        let archive = SidebarSessionPresentation.archiveGroupID("flat:all")
        let saved = SidebarViewState(flat: false, shownRoots: ["flat:all": 25, archive: 15], revision: 4)
        try await store.put(saved, kind: SidebarViewState.recordKind, id: SidebarViewState.recordID, revision: saved.revision)
        try await model.restoreProjectSidebarStates()
        let gate = FlatStoreGate()
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            Task.detached { await store.holdFlatReads(gate) { held.resume() } }
        }
        model.setSidebarFlat(true); model.setSidebarShownRoots("flat:all", to: 35, in: "")
        model.setSidebarShownRoots(archive, to: 25, in: "")
        await Task.yield()
        model.setSidebarFlat(false); model.setSidebarShownRoots("flat:all", to: 5, in: "")
        model.setSidebarShownRoots(archive, to: 45, in: "")
        gate.release.signal()
        let flushed = await model.flushProjectSidebarState(); XCTAssertTrue(flushed)
        model.sidebarViewState = SidebarViewState(); model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.sidebarListsFlat)
        XCTAssertNil(model.sidebarViewState.shownRoots["flat:all"])
        XCTAssertEqual(model.sidebarShownRoots("flat:all"), 5); XCTAssertEqual(model.sidebarShownRoots(archive), 45)
    }

    @MainActor func testGlobalWriteFailureIsReportedAndIncludedInTheQuitFlush() async throws {
        let model = try fixture(); await model.store?.close()
        flat(model)
        let saved = await model.flushProjectSidebarState(timeout: 0.2)
        XCTAssertFalse(saved); XCTAssertTrue(model.dirtySidebarViewState)
        XCTAssertTrue(model.error?.contains("Sidebar preferences could not be saved") == true)
    }
}
