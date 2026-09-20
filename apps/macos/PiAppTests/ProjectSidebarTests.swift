import XCTest
@testable import PiApp

final class ProjectSidebarTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("project-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor func testProjectDisclosureAndArchiveFiltersPersistIndependentlyWithoutStoppingWork() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let first = WorkspaceRecord(id: "first", path: "/project/first", trusted: true)
        let second = WorkspaceRecord(id: "second", path: "/project/empty", trusted: true)
        model.workspaces = [first, second]
        let record = ChatRecord(id: "chat", workspaceID: first.id, title: "Running", path: nil, profileID: "p")
        model.chats = [record]; model.selectedID = record.id; model.selectedWorkspaceID = first.id
        let display = SessionDisplay(id: record.id); display.state = "running"; display.queueCount = 1; display.draft = "Unsent"
        model.displays[record.id] = display; model.selected = display; model.opened.insert(record.id)
        XCTAssertTrue(model.projectIsExpanded(first.id)); XCTAssertTrue(model.projectIsExpanded(second.id))
        model.setProjectExpanded(first.id, expanded: false)
        model.setProjectArchiveFilter(second.id, archived: true)
        await model.flushProjectSidebarState()
        XCTAssertTrue(model.projectSidebarWrites.isEmpty); XCTAssertTrue(model.dirtyProjectSidebarStates.isEmpty)
        XCTAssertFalse(model.projectIsExpanded(first.id)); XCTAssertTrue(model.projectIsExpanded(second.id))
        XCTAssertFalse(model.projectShowsArchive(first.id)); XCTAssertTrue(model.projectShowsArchive(second.id))
        XCTAssertEqual(model.selectedID, record.id); XCTAssertTrue(model.selected === display)
        XCTAssertEqual(display.state, "running"); XCTAssertEqual(display.queueCount, 1); XCTAssertEqual(display.draft, "Unsent")
        XCTAssertTrue(model.opened.contains(record.id)); XCTAssertTrue(model.hosts.isEmpty)
        model.projectSidebarStates = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.projectIsExpanded(first.id)); XCTAssertTrue(model.projectShowsArchive(second.id))
        // Rapid alternating toggles settle to the latest durable state.
        for value in [true, false, true, false] { model.setProjectExpanded(first.id, expanded: value) }
        await model.flushProjectSidebarState()
        model.projectSidebarStates = [:]; try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.projectIsExpanded(first.id))
        display.state = "idle"; display.queueCount = 0; model.opened.remove(record.id)
        await model.store?.close()
    }

    @MainActor func testProjectPreferenceFailureIsReportedAndCannotHangShutdown() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "project", path: "/project", trusted: true)]
        await model.store?.close()
        model.setProjectExpanded("project", expanded: false)
        let immediate = await model.flushProjectSidebarState(timeout: 0)
        XCTAssertFalse(immediate)
        let start = ProcessInfo.processInfo.systemUptime
        let saved = await model.flushProjectSidebarState(timeout: 0.5)
        XCTAssertFalse(saved); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertTrue(model.projectSidebarWrites.isEmpty); XCTAssertEqual(model.dirtyProjectSidebarStates, ["project"])
        XCTAssertTrue(model.error?.contains("Project sidebar preferences could not be saved") == true)
    }

    @MainActor func testExplicitSelectionRevealsOnlyTargetProjectWhileRestoreKeepsDisclosure() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "first", path: "/first", trusted: true), WorkspaceRecord(id: "second", path: "/second", trusted: true)]
        var target = ChatRecord(id: "chat", workspaceID: "first", title: "Archived", path: nil, profileID: "p")
        target.archivedAt = Date(); model.chats = [target]
        try await model.store?.put(target, kind: "chat", id: target.id)
        model.setProjectExpanded("first", expanded: false); model.setProjectExpanded("second", expanded: false)
        await model.select(target.id, revealInSidebar: false)
        XCTAssertFalse(model.projectIsExpanded("first"), "Startup must keep the saved disclosure state")
        await model.select(target.id)
        XCTAssertTrue(model.projectIsExpanded("first")); XCTAssertTrue(model.projectShowsArchive("first"))
        XCTAssertFalse(model.projectIsExpanded("second")); XCTAssertTrue(model.record(target.id)?.isArchived == true)
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testDurableChildTreeHandlesCollapsedParentsPinArchiveAndCycles() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        func chat(_ id: String, parent: String? = nil, order: Int64) -> ChatRecord {
            ChatRecord(id: id, workspaceID: "w", title: id, path: nil, profileID: "p", sidebarOrder: order, parentSessionID: parent)
        }
        let parent = chat("parent", order: 1), child = chat("child", parent: "parent", order: 2)
        let grandchild = chat("grandchild", parent: "child", order: 3)
        var pinned = chat("pinned", parent: "parent", order: 4); pinned.pinnedAt = Date()
        var archived = chat("archived", parent: "parent", order: 5); archived.archivedAt = Date()
        model.chats = [parent, child, grandchild, pinned, archived]
        var rows = model.sidebarEntries(in: "w", archived: false, collapsed: [])
        XCTAssertEqual(rows.map(\.id), ["pinned", "parent", "child", "grandchild"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2])
        XCTAssertEqual(rows.map(\.hasChildren), [false, true, true, false])
        XCTAssertEqual(model.sidebarEntries(in: "w", archived: false, collapsed: ["parent"]).map(\.id), ["pinned", "parent"])
        XCTAssertEqual(model.sidebarEntries(in: "w", archived: true, collapsed: []).map(\.id), ["archived"])
        // Corrupted/self/cyclic references must remain inspectable exactly once.
        model.chats += [chat("cycle-a", parent: "cycle-b", order: 8), chat("cycle-b", parent: "cycle-a", order: 7), chat("self", parent: "self", order: 6)]
        rows = model.sidebarEntries(in: "w", archived: false, collapsed: [])
        XCTAssertEqual(Set(rows.map(\.id)).count, 7); XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.contains { $0.id == "self" && $0.depth == 0 })
    }

    @MainActor func testHistoryWithMissingProjectConfigurationStaysVisibleAndReadable() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("retained.jsonl")
        try Data((#"{"type":"session","version":3,"id":"orphan"}"# + "\n" + #"{"type":"message","id":"answer","parentId":null,"message":{"role":"assistant","content":"Retained answer"}}"# + "\n").utf8).write(to: path)
        let storage = MemoryVaultStorage()
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: storage))
        defer { model.shutdown() }
        let chat = ChatRecord(id: "orphan", workspaceID: "missing-project-id", title: "Retained", path: path.path, profileID: "missing-profile")
        model.chats = [chat]
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        XCTAssertTrue(model.workspaces.isEmpty)
        let group = try XCTUnwrap(model.sidebarProjects.first)
        XCTAssertEqual(group.id, chat.workspaceID); XCTAssertFalse(group.available); XCTAssertFalse(group.record.trusted)
        XCTAssertTrue(group.name.hasPrefix("Retained chats"))
        XCTAssertEqual(model.sidebarEntries(in: group.id, archived: false, collapsed: []).map(\.id), [chat.id])
        model.setProjectExpanded(group.id, expanded: false); await model.flushProjectSidebarState()
        model.projectSidebarStates = [:]; try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.projectIsExpanded(group.id), "Missing projects retain local disclosure preferences too")
        await model.select(chat.id)
        XCTAssertTrue(model.projectIsExpanded(group.id)); XCTAssertEqual(model.selected?.messages.first?.text, "Retained answer")
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.workspaces.isEmpty)
        model.newChat(in: group.id)
        XCTAssertEqual(model.chats.count, 1); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertNil(try storage.read(), "Reading orphan history must not recreate or rewrite the configuration vault")
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    /// Folded side chats and an opened page are sidebar state like the
    /// disclosure beside them: they go into the project's own record and come
    /// back with it on the next launch, without a store kind of their own.
    @MainActor func testFoldedSidesAndOpenedPagesSurviveARelaunchInTheProjectRecord() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let first = WorkspaceRecord(id: "first", path: "/project/first", trusted: true)
        let second = WorkspaceRecord(id: "second", path: "/project/second", trusted: true)
        model.workspaces = [first, second]
        model.topics = [TopicRecord(id: "topic", workspaceID: first.id, title: "Billing")]
        model.chats = [ChatRecord(id: "a", workspaceID: first.id, title: "A", path: nil, profileID: "p"),
                       ChatRecord(id: "b", workspaceID: first.id, title: "B", path: nil, profileID: "p"),
                       ChatRecord(id: "elsewhere", workspaceID: second.id, title: "Elsewhere", path: nil, profileID: "p")]

        model.setSidebarSideFolded("a", folded: true)
        model.setSidebarSideFolded("elsewhere", folded: true)
        model.setSidebarShownRoots("topic", to: 15, in: first.id)
        model.setSidebarShownRoots(second.id, to: 25, in: second.id)
        XCTAssertEqual(model.sidebarShownRoots("topic"), 15)
        XCTAssertEqual(model.sidebarShownRoots("nobody"), SidebarSessionPresentation.pageSize, "An untouched group is on its first page")
        let saved = await model.flushProjectSidebarState()
        XCTAssertTrue(saved)

        // Each project carries only its own folds; nothing crosses over.
        XCTAssertEqual(model.projectSidebarStates[first.id]?.collapsedSides, ["a"])
        XCTAssertEqual(model.projectSidebarStates[second.id]?.collapsedSides, ["elsewhere"])
        XCTAssertEqual(model.projectSidebarStates[first.id]?.shownRoots, ["topic": 15])

        // Relaunch.
        model.projectSidebarStates = [:]; model.collapsedSidebarSides = []; model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertEqual(model.collapsedSidebarSides, ["a", "elsewhere"])
        XCTAssertEqual(model.sidebarShownRoots("topic"), 15)
        XCTAssertEqual(model.sidebarShownRoots(second.id), 25)

        // Unfolding and going back to the first page are durable too.
        model.setSidebarSideFolded("a", folded: false)
        model.setSidebarShownRoots("topic", to: SidebarSessionPresentation.pageSize, in: first.id)
        let savedAgain = await model.flushProjectSidebarState()
        XCTAssertTrue(savedAgain)
        model.projectSidebarStates = [:]; model.collapsedSidebarSides = []; model.sidebarPageSizes = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertEqual(model.collapsedSidebarSides, ["elsewhere"])
        XCTAssertEqual(model.sidebarShownRoots("topic"), SidebarSessionPresentation.pageSize)
        await model.store?.close()
    }

    /// Nothing read back from the vault is trusted to be the size it was written.
    @MainActor func testAnOversizedSidebarRecordIsCutDownBeforeItReachesTheSidebar() throws {
        var hostile = ProjectSidebarState(id: "project")
        hostile.collapsedSides = (0..<(ProjectSidebarState.maximumPresentationEntries + 500)).map { "chat\($0)" } + ["", String(repeating: "x", count: 600)]
        hostile.shownRoots = ["good": 12, "": 5, "zero": 0, "huge": ProjectSidebarState.maximumShownRoots + 1,
                              String(repeating: "y", count: 600): 4]
        let clean = hostile.sanitized
        XCTAssertEqual(clean.collapsedSides?.count, ProjectSidebarState.maximumPresentationEntries)
        XCTAssertFalse(clean.collapsedSides?.contains("") ?? true)
        XCTAssertEqual(clean.shownRoots, ["good": 12])
        XCTAssertEqual(ProjectSidebarState(id: "project").sanitized, ProjectSidebarState(id: "project"))
    }

    @MainActor func testFocusedSideArchiveAndReselectionKeepItsProjectArchiveVisible() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        let parent = ChatRecord(id: "parent", workspaceID: "w", title: "Parent", path: nil, profileID: "p")
        let child = ChatRecord(id: "child", workspaceID: "w", title: "Child", path: nil, profileID: "p", toolMode: "read-only", parentSessionID: parent.id)
        model.chats = [parent, child]
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let parentView = SessionDisplay(id: parent.id), childView = SessionDisplay(id: child.id)
        model.displays[parent.id] = parentView; model.displays[child.id] = childView
        model.sides[parent.id] = SideRecord(id: child.id, parentID: parent.id, workspaceID: "w", profileID: "p", title: child.title, kept: true)
        model.selectedID = parent.id; model.selected = parentView; model.focusedSessionID = child.id
        try await model.setSessionArchived(child.id, archived: true)
        XCTAssertFalse(model.projectShowsArchive("w"), "Archiving never jumps the sidebar into the archive"); XCTAssertEqual(model.selectedID, parent.id); XCTAssertEqual(model.focusedSessionID, child.id)
        await model.selectSide(child.id)
        XCTAssertTrue(model.projectShowsArchive("w")); XCTAssertEqual(model.focusedSessionID, child.id)
        XCTAssertEqual(model.sidebarEntries(in: "w", archived: true, collapsed: []).map(\.id), [child.id])
        XCTAssertFalse(model.record(parent.id)?.isArchived ?? true); XCTAssertTrue(model.record(child.id)?.isArchived == true)
        await model.flushProjectSidebarState(); await model.store?.close()
    }
}
