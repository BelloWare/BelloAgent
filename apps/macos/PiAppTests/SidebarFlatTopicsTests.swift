import XCTest
import AppKit
@testable import PiApp

/// A project can list its chats flat (owner, 2026-10-13): no topic folders,
/// every chat of the project in one list, newest activity first, each with
/// its topic as a small tag. The choice is the project's own, kept in its
/// sidebar record. These fixtures never send a request or start a helper.
final class SidebarFlatTopicsTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("flat-topics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func chat(_ id: String, in project: String = "project", order: Int64, topic: String? = nil, parent: String? = nil,
                      archived: Bool = false, pinned: Bool = false) -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: project, title: "Chat " + id, path: nil, profileID: "fixture", sidebarOrder: order,
                               parentSessionID: parent)
        value.topicID = topic
        if archived { value.archivedAt = Date() }
        if pinned { value.pinnedAt = Date() }
        return value
    }

    /// Two topics and a project root, with activity spread across them so
    /// that the grouped and the flat orders differ; a kept side filed in
    /// another topic than its parent; a pinned chat. A second project keeps
    /// its topic folders throughout.
    @MainActor private func makeModel(_ root: URL) -> WorkspaceModel {
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "project", path: root.appendingPathComponent("project").path, trusted: true),
                            WorkspaceRecord(id: "other", path: root.appendingPathComponent("other").path, trusted: true)]
        model.topics = [TopicRecord(id: "billing", workspaceID: "project", title: "Billing"),
                        TopicRecord(id: "research", workspaceID: "project", title: "Research"),
                        TopicRecord(id: "elsewhere", workspaceID: "other", title: "Elsewhere")]
        model.chats = [chat("a", order: 50, topic: "billing"),
                       chat("b", order: 40),
                       chat("b-side", order: 70, topic: "research", parent: "b"),
                       chat("c", order: 60, topic: "research"),
                       chat("d", order: 10, topic: "billing"),
                       chat("pinned", order: 1, pinned: true),
                       chat("o1", in: "other", order: 30, topic: "elsewhere"),
                       chat("o2", in: "other", order: 20)]
        return model
    }

    @MainActor private func build(_ model: WorkspaceModel, filter: String = "", width: CGFloat = 300) -> SidebarListContents {
        SidebarListContents.build(model: model, filter: filter, sidebarWidth: width, confirmingRemove: [], removing: [], dropTarget: nil)
    }
    /// The chat rows of one project, in list order, with their tags.
    @MainActor private func rows(_ contents: SidebarListContents, in project: String) -> [(id: String, tag: String?, state: SidebarChatRowState)] {
        zip(contents.entries, contents.owners).compactMap { entry, owner in
            guard owner.project == project, case .chat(let chat, let state, _) = entry else { return nil }
            return (chat.id, state.topicTag, state)
        }
    }

    // MARK: Order and tags

    @MainActor func testFlatListsEveryChatOfTheProjectNewestFirstWithItsTopicAsATag() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        // Grouped (the default): topic folders, and no tags anywhere.
        let grouped = build(model)
        XCTAssertFalse(model.projectListsFlat("project"))
        XCTAssertTrue(grouped.entries.contains { if case .topicHeader(let header) = $0 { return header.topicID == "billing" }; return false })
        XCTAssertTrue(rows(grouped, in: "project").allSatisfy { $0.tag == nil }, "The Topics view shows no tags")

        model.setProjectListsFlat("project", flat: true)
        XCTAssertTrue(model.projectListsFlat("project"))
        let flat = build(model)
        let listed = rows(flat, in: "project")
        // Pinned on top, as everywhere; then newest activity first, a family
        // as recent as its newest member, its side under it.
        XCTAssertEqual(listed.map(\.id), ["pinned", "b", "b-side", "c", "a", "d"])
        XCTAssertEqual(listed.map(\.tag), [nil, nil, "Research", "Research", "Billing", "Billing"],
                       "Each row carries its topic; a chat outside every topic carries none")
        XCTAssertFalse(zip(flat.entries, flat.owners).contains { entry, owner in
            guard owner.project == "project" else { return false }
            if case .topicHeader = entry { return true }
            return false
        }, "No topic folders in the flat view")
        XCTAssertTrue(flat.owners.filter { $0.project == "project" }.allSatisfy { $0.topic == nil })
        XCTAssertEqual(listed.first { $0.id == "b-side" }?.state.indent, (listed.first { $0.id == "b" }?.state.indent ?? 0) + 14,
                       "The side sits under its parent")
        // The other project keeps its folders and shows no tags.
        XCTAssertFalse(model.projectListsFlat("other"))
        XCTAssertTrue(flat.entries.contains { if case .topicHeader(let header) = $0 { return header.topicID == "elsewhere" }; return false })
        XCTAssertTrue(rows(flat, in: "other").allSatisfy { $0.tag == nil })

        // New activity moves a chat to the top, whichever topic it is in.
        if let index = model.chats.firstIndex(where: { $0.id == "d" }) { model.chats[index].sidebarOrder = 90 }
        XCTAssertEqual(rows(build(model), in: "project").map(\.id), ["pinned", "d", "b", "b-side", "c", "a"])

        // A side filed in its parent's topic says nothing its parent's tag does not.
        if let index = model.chats.firstIndex(where: { $0.id == "b-side" }) { model.chats[index].topicID = nil }
        XCTAssertNil(rows(build(model), in: "project").first { $0.id == "b-side" }?.tag)

        // Back to Topics: the folders return and the tags go.
        model.setProjectListsFlat("project", flat: false)
        let back = build(model)
        XCTAssertTrue(rows(back, in: "project").allSatisfy { $0.tag == nil })
        XCTAssertTrue(back.entries.contains { if case .topicHeader(let header) = $0 { return header.topicID == "billing" }; return false })
    }

    /// The scratch area has no topics to flatten.
    @MainActor func testNoProjectCannotBeFlattened() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.chats.append(chat("loose", in: WorkspaceRecord.scratchID, order: 5))
        model.setProjectListsFlat(WorkspaceRecord.scratchID, flat: true)
        XCTAssertFalse(model.projectListsFlat(WorkspaceRecord.scratchID))
        XCTAssertNil(model.projectSidebarStates[WorkspaceRecord.scratchID])
    }

    // MARK: Persistence

    @MainActor func testTheChoiceIsTheProjectsOwnAndSurvivesARelaunch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.setProjectListsFlat("project", flat: true)
        let saved = await model.flushProjectSidebarState()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.projectSidebarStates["project"]?.flatTopics, true)
        XCTAssertNil(model.projectSidebarStates["other"], "Another project's view is its own")

        // Relaunch: the project record comes back with the view in it.
        model.projectSidebarStates = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(model.projectListsFlat("project"))
        XCTAssertFalse(model.projectListsFlat("other"))
        XCTAssertEqual(rows(build(model), in: "project").map(\.id), ["pinned", "b", "b-side", "c", "a", "d"])

        // Back to Topics is durable too, and leaves no key behind.
        model.setProjectListsFlat("project", flat: false)
        let savedAgain = await model.flushProjectSidebarState()
        XCTAssertTrue(savedAgain)
        model.projectSidebarStates = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.projectListsFlat("project"))
        XCTAssertNil(model.projectSidebarStates["project"]?.flatTopics)
        await model.store?.close()
    }

    /// Records written before the flat view decode as grouped, and a flat
    /// record round-trips.
    func testOlderSidebarRecordsDecodeAsGrouped() throws {
        let old = Data(#"{"id":"project","expanded":true,"archived":false,"revision":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectSidebarState.self, from: old)
        XCTAssertNil(decoded.flatTopics)
        var flat = decoded; flat.flatTopics = true
        XCTAssertEqual(try JSONDecoder().decode(ProjectSidebarState.self, from: JSONEncoder().encode(flat)).flatTopics, true)
    }

    /// The flat list pages like any group, and its page is kept with the project.
    @MainActor func testTheFlatListPagesAndKeepsItsPageWithTheProject() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.chats += (0..<8).map { chat("many-\($0)", order: Int64(100 + $0), topic: $0.isMultiple(of: 2) ? "billing" : nil) }
        model.setProjectListsFlat("project", flat: true)
        let group = SidebarSessionPresentation.flatGroupID("project")
        let contents = build(model)
        XCTAssertTrue(contents.entries.contains { if case .pagination(let id, _, let hidden, _, _) = $0 { return id == group && hidden > 0 }; return false })
        XCTAssertEqual(rows(contents, in: "project").filter { $0.state.indent == 14 }.count, SidebarSessionPresentation.pageSize)
        model.setSidebarShownRoots(group, to: 15, in: "project")
        let saved = await model.flushProjectSidebarState()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.projectSidebarStates["project"]?.shownRoots, [group: 15])
        model.projectSidebarStates = [:]; model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertEqual(model.sidebarShownRoots(group), 15)
        await model.store?.close()
    }

    // MARK: Rows

    /// Everything a row shows apart from where it sits is the same in both
    /// views: selection, marks, unread, paused, the draft, the recency wash,
    /// the fold.
    @MainActor func testARowShowsTheSameStatesInBothViews() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        // The side filed with its parent, so the family is the same in both views.
        if let index = model.chats.firstIndex(where: { $0.id == "b-side" }) { model.chats[index].topicID = nil }
        model.selectedID = "c"; model.selectedWorkspaceID = "project"
        model.markedSessionIDs = ["a", "d"]
        model.unreadStates["a"] = SessionReadState(id: "a", observedAssistantCount: 2, latestAssistantID: "m2", unreadOutputs: 1)
        model.unreadStates["d"] = SessionReadState(id: "d", observedAssistantCount: 0, latestAssistantID: nil, markedUnread: true)
        model.runHolds["b"] = RunHoldRecord(id: "b", state: "paused")
        model.draftChatIDs.insert("a")
        model.noteOpened("a"); model.noteOpened("c")
        model.collapsedSidebarSides.insert("b")
        func normalized(_ state: SidebarChatRowState) -> SidebarChatRowState {
            var value = state
            value.topicTag = nil; value.indent = 0; value.available = 0; value.draggable = false
            return value
        }
        let grouped = Dictionary(uniqueKeysWithValues: rows(build(model), in: "project").map { ($0.id, $0.state) })
        model.setProjectListsFlat("project", flat: true)
        let flat = rows(build(model), in: "project")
        XCTAssertFalse(flat.contains { $0.id == "b-side" }, "A folded side stays folded")
        for row in flat {
            let before = try XCTUnwrap(grouped[row.id], row.id)
            XCTAssertEqual(normalized(row.state), normalized(before), row.id)
        }
        let byID = Dictionary(uniqueKeysWithValues: flat.map { ($0.id, $0.state) })
        XCTAssertEqual(byID["c"]?.selected, true); XCTAssertEqual(byID["a"]?.unreadCount, 1); XCTAssertEqual(byID["d"]?.markedUnreadOnly, true)
        XCTAssertEqual(byID["b"]?.heldRun, "paused"); XCTAssertEqual(byID["a"]?.hasDraft, true); XCTAssertEqual(byID["c"]?.recency, 0)
        XCTAssertEqual(byID["a"]?.marked, true); XCTAssertEqual(byID["b"]?.expanded, false)
        // There is no folder to drag a row to: flat rows are not drag sources.
        XCTAssertTrue(flat.allSatisfy { !$0.state.draggable })
        XCTAssertTrue(rows(build(model), in: "other").contains { $0.state.draggable }, "Grouped projects keep their drag")
    }

    /// The archive switch lists a flat project's archived chats after its
    /// active ones, under one heading, tagged as well.
    @MainActor func testArchivedChatsFollowTheActiveOnesInTheFlatList() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.chats += [chat("old-billing", order: 200, topic: "billing", archived: true), chat("old-root", order: 5, archived: true)]
        model.setProjectListsFlat("project", flat: true)
        XCTAssertFalse(rows(build(model), in: "project").contains { $0.id.hasPrefix("old") })
        model.setArchivedChatsShown(true)
        let contents = build(model)
        let ids = zip(contents.entries, contents.owners).compactMap { entry, owner -> String? in
            guard owner.project == "project" else { return nil }
            switch entry {
            case .chat(let chat, _, _): return chat.id
            case .archiveHeading(let group, let count, _): return "heading:\(group):\(count)"
            default: return nil
            }
        }
        let heading = "heading:" + SidebarSessionPresentation.archiveGroupID(SidebarSessionPresentation.flatGroupID("project")) + ":2"
        XCTAssertEqual(ids, ["pinned", "b", "b-side", "c", "a", "d", heading, "old-billing", "old-root"])
        XCTAssertEqual(rows(contents, in: "project").first { $0.id == "old-billing" }?.tag, "Billing")
    }

    // MARK: Search and keyboard

    @MainActor func testSearchInTheFlatViewMatchesTitlesAndTopicTags() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.setProjectListsFlat("project", flat: true)
        // A topic's name lists its chats, as a matching folder did.
        XCTAssertEqual(rows(build(model, filter: "billing"), in: "project").map(\.id), ["a", "d"])
        // A side's title keeps its parent listed above it.
        XCTAssertEqual(rows(build(model, filter: "b-side"), in: "project").map(\.id), ["b", "b-side"])
        XCTAssertEqual(rows(build(model, filter: "nothing like this"), in: "project").map(\.id), [])
        // The keyboard and Return follow what the filter left listed.
        model.sidebarFilter = "research"
        XCTAssertEqual(model.sidebarChatOrder.filter { model.record($0)?.workspaceID == "project" }, ["b", "b-side", "c"])
        model.sidebarFilter = ""
    }

    @MainActor func testKeyboardStepsThroughTheFlatOrder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.setProjectListsFlat("project", flat: true)
        let order = model.sidebarChatOrder
        XCTAssertEqual(Array(order.prefix(6)), rows(build(model), in: "project").map(\.id), "Next and Previous Chat follow the list")
        XCTAssertEqual(Array(order.dropFirst(6)), ["o1", "o2"], "then the grouped project's folders")
        await model.select("c")
        model.selectAdjacentChat(1)
        for _ in 0..<200 where model.selectedID != "a" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedID, "a", "Down from c is a, the next newest, though it is in another topic")
        model.selectAdjacentChat(-1)
        for _ in 0..<200 where model.selectedID != "c" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedID, "c")
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    // MARK: Moving and dropping

    /// Move to Topic in a row's menu works in the flat view: the row stays
    /// where its activity puts it and takes its new tag.
    @MainActor func testMovingAChatToATopicFromItsMenuRetagsItsRow() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        // The store knows the topics as it knows the chats.
        for topic in model.topics { _ = try await model.store?.createTopic(topic) }
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.setProjectListsFlat("project", flat: true)
        let row = try XCTUnwrap(rows(build(model), in: "project").first { $0.id == "c" })
        let record = try XCTUnwrap(model.record("c"))
        let menu = PiMenus.menu(SidebarChatRowView.entries(model: model, chat: record, state: row.state))
        XCTAssertTrue(PiMenus.perform("moveSessionToTopic-c-billing", in: menu))
        for _ in 0..<200 where model.record("c")?.topicID != "billing" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.record("c")?.topicID, "billing")
        let after = rows(build(model), in: "project")
        XCTAssertEqual(after.map(\.id), ["pinned", "b", "b-side", "c", "a", "d"], "Moving is not activity")
        XCTAssertEqual(after.first { $0.id == "c" }?.tag, "Billing")
        XCTAssertTrue(model.projectListsFlat("project"), "and the project stays flat")
        // And out of every topic: the tag goes.
        let again = PiMenus.menu(SidebarChatRowView.entries(model: model, chat: try XCTUnwrap(model.record("c")), state: row.state))
        XCTAssertTrue(PiMenus.perform("moveSessionToTopic-c-root", in: again))
        for _ in 0..<200 where model.record("c")?.topicID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(rows(build(model), in: "project").first { $0.id == "c" }?.tag)
        _ = await model.flushTopicChanges(); await model.flushProjectSidebarState(); await model.store?.close()
    }

    /// A flat project has no folders to drop on: a drag over it offers
    /// nothing, where a grouped project still takes it.
    @MainActor func testAFlatProjectOffersNoDropTarget() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        model.setProjectListsFlat("project", flat: true)
        let sidebar = makeSidebar(model, width: 300, height: 900)
        let list = sidebar.list
        for id in ["chat|a", "chat|c", "project|project"] {
            let frame = try XCTUnwrap(list.frame(of: id), id)
            XCTAssertNil(list.dropTarget(at: CGPoint(x: frame.midX, y: frame.midY)), id)
        }
        let other = try XCTUnwrap(list.frame(of: "chat|o1"))
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: other.midX, y: other.midY)), .group(projectID: "other", topicID: "elsewhere"))
        // Nor does the gap between its rows.
        XCTAssertNil(list.dropTarget(at: CGPoint(x: 10, y: (list.frame(of: "chat|d")?.maxY ?? 0) + 1)))
    }

    // MARK: The control

    /// The project's "…" menu and its right-click menu switch between the two
    /// views, with the current one checked.
    @MainActor func testTheProjectMenuSwitchesBetweenTopicsAndFlat() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let sidebar = makeSidebar(model, width: 300, height: 900)
        func header() throws -> ProjectHeaderView {
            let entry = try XCTUnwrap(sidebar.list.views["project|project"] as? ProjectHeaderEntry)
            return entry.header
        }
        func item(_ identifier: String, in menu: NSMenu) -> NSMenuItem? {
            menu.items.first { $0.identifier?.rawValue == identifier }
        }
        var menu = PiMenus.menu(ProjectSidebarActions.entries(model: model, state: try header().state, expand: nil))
        XCTAssertEqual(item("projectTopicView-topics-project", in: menu)?.state, .on)
        XCTAssertEqual(item("projectTopicView-flat-project", in: menu)?.state, .off)
        XCTAssertTrue(PiMenus.perform("projectTopicView-flat-project", in: menu))
        sidebar.settle()
        XCTAssertTrue(model.projectListsFlat("project"))
        XCTAssertNil(sidebar.list.views["topic|billing"], "The folders are gone from the list")
        XCTAssertNotNil(sidebar.list.views["chat|a"])
        menu = PiMenus.menu(ProjectSidebarActions.entries(model: model, state: try header().state, expand: nil))
        XCTAssertEqual(item("projectTopicView-flat-project", in: menu)?.state, .on)
        XCTAssertTrue(PiMenus.perform("projectTopicView-topics-project", in: menu))
        sidebar.settle()
        XCTAssertFalse(model.projectListsFlat("project"))
        XCTAssertNotNil(sidebar.list.views["topic|billing"])
        // The scratch area has no topics, and no such choice.
        model.chats.append(chat("loose", in: WorkspaceRecord.scratchID, order: 5)); sidebar.settle()
        let scratchMenu = PiMenus.menu(ProjectSidebarActions.entries(model: model, state: ProjectHeaderState(projectID: WorkspaceRecord.scratchID, scratch: true), expand: nil))
        XCTAssertNil(item("projectTopicView-flat-" + WorkspaceRecord.scratchID, in: scratchMenu))
    }

    // MARK: Look

    /// The tag rides in the title line without making the row any taller,
    /// cuts itself short rather than the title in a narrow sidebar, and the
    /// Topics view draws exactly what it drew before the switch was used.
    @MainActor func testTheTagFitsTheRowAndTheTopicsViewIsUnchanged() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        if let index = model.topics.firstIndex(where: { $0.id == "billing" }) {
            model.topics[index].title = "Billing and invoicing for the enterprise plan"
        }
        for (width, dark) in [(CGFloat(300), false), (220, true)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let sidebar = makeSidebar(model, width: width, height: 700)
            window.contentView = sidebar
            defer { window.contentView = nil; window.close() }
            func frame() throws -> Data {
                sidebar.needsLayout = true; sidebar.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                return try XCTUnwrap(image.representation(using: .png, properties: [:]))
            }
            let groupedPicture = try frame()
            let groupedRow = try XCTUnwrap(sidebar.list.views["chat|a"] as? SidebarChatRowView)
            XCTAssertTrue(groupedRow.body.topicTag.isHidden, "No tag in the Topics view")
            let groupedHeight = groupedRow.frame.height

            model.setProjectListsFlat("project", flat: true); sidebar.settle()
            let row = try XCTUnwrap(sidebar.list.views["chat|a"] as? SidebarChatRowView)
            row.layoutSubtreeIfNeeded()
            let tag = row.body.topicTag
            XCTAssertFalse(tag.isHidden)
            XCTAssertEqual(tag.text, "Billing and invoicing for the enterprise plan")
            XCTAssertEqual(row.frame.height, groupedHeight, "The tag does not make the row taller (\(width))")
            let inBody = tag.convert(tag.bounds, to: row.body)
            XCTAssertGreaterThanOrEqual(inBody.minY, 0); XCTAssertLessThanOrEqual(inBody.maxY, row.body.bounds.height)
            XCTAssertLessThanOrEqual(inBody.maxX, row.body.bounds.width + 0.5, "The tag stays inside the row")
            XCTAssertLessThan(tag.frame.width, tag.naturalWidth, "A long topic is cut short (\(width))")
            XCTAssertLessThanOrEqual(tag.frame.width, ceil(row.body.bounds.width * 0.4) + 1, "and leaves the title most of the line")
            XCTAssertTrue(row.row.accessibilityLabel()?.contains("topic Billing and invoicing") == true, row.row.accessibilityLabel() ?? "")
            XCTAssertEqual((sidebar.list.views["chat|b"] as? SidebarChatRowView)?.body.topicTag.isHidden, true,
                           "A chat outside every topic has no tag")

            model.setProjectListsFlat("project", flat: false); sidebar.settle()
            XCTAssertEqual(try frame(), groupedPicture, "Back to Topics draws what it drew before (\(width))")
        }
    }
}
