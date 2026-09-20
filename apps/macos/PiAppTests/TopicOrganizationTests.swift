import XCTest
@testable import PiApp

/// Topics change desktop organization only. These fixtures never send a model
/// request, open a real credential store, or edit a project's files.
final class TopicOrganizationTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("topic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor private func makeModel(_ root: URL) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true),
                            WorkspaceRecord(id: "other", path: root.appendingPathComponent("other").path, trusted: true)]
        return model
    }

    private func chat(_ id: String, topic: String? = nil, parent: String? = nil, project: String = "project", order: Int64 = 1) -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: project, title: id, path: nil, profileID: "fixture", sidebarOrder: order, parentSessionID: parent)
        value.topicID = topic
        return value
    }

    @MainActor private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Topic operation did not settle", file: file, line: line)
    }

    func testLegacyChatsDefaultToProjectRootAndTopicReferenceRoundTrips() throws {
        let legacy = Data(#"{"id":"old","workspaceID":"project","title":"Retained","path":"/retained/session.jsonl","profileID":"fixture","toolMode":"editing","imported":false}"#.utf8)
        var value = try JSONDecoder().decode(ChatRecord.self, from: legacy)
        XCTAssertNil(value.topicID)
        value.topicID = "topic"
        XCTAssertEqual(try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(value.path, "/retained/session.jsonl")
    }

    @MainActor func testCreateRenameDisclosureAndReloadKeepStableIdentity() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "  Release\n planning  ")
        XCTAssertEqual(topic.workspaceID, "project"); XCTAssertEqual(topic.title, "Release planning")
        XCTAssertTrue(topic.expanded); XCTAssertEqual(model.topics(in: "project").map(\.id), [topic.id])
        XCTAssertTrue(model.topics(in: "other").isEmpty)
        let creation = topic.createdAt

        try await model.renameTopic(topic.id, title: "  Launch notes 🌍  ")
        for expanded in [false, true, false, true, false] { model.setTopicExpanded(topic.id, expanded: expanded) }
        let saved = await model.flushTopicChanges()
        XCTAssertTrue(saved)
        model.topics = []; try await model.restoreTopics()
        let restored = try XCTUnwrap(model.topics(in: "project").first)
        XCTAssertEqual(restored.id, topic.id); XCTAssertEqual(restored.createdAt, creation)
        XCTAssertEqual(restored.title, "Launch notes 🌍"); XCTAssertFalse(restored.expanded)
        XCTAssertGreaterThan(restored.revision, topic.revision)

        do { try await model.renameTopic(topic.id, title: " \n\t "); XCTFail("Blank topic titles must be rejected") } catch { }
        do { _ = try await model.createTopic(in: "missing", title: "Orphan"); XCTFail("An unavailable project cannot gain a topic") } catch { }
        XCTAssertEqual(model.topics(in: "project").map(\.title), ["Launch notes 🌍"])
        XCTAssertEqual(model.topics.count, 1)
        await model.store?.close()
    }

    @MainActor func testMovingRunningSessionAndDescendantsPreservesWorkDraftUnreadAndJournal() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let origin = try await model.createTopic(in: "project", title: "Origin")
        let destination = try await model.createTopic(in: "project", title: "Destination")
        let journal = root.appendingPathComponent("running.jsonl"), original = Data("retained conversation bytes\n".utf8)
        try original.write(to: journal)
        var running = chat("running", topic: origin.id, order: 4); running.path = journal.path
        var pinnedChild = chat("child", topic: origin.id, parent: running.id, order: 3); pinnedChild.pinnedAt = Date(timeIntervalSince1970: 10)
        var archived = chat("grandchild", topic: origin.id, parent: pinnedChild.id, order: 2); archived.archivedAt = Date(timeIntervalSince1970: 20)
        let unrelated = chat("unrelated", topic: origin.id), foreign = chat("foreign", parent: running.id, project: "other")
        model.chats = [running, pinnedChild, archived, unrelated, foreign]
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }

        let display = SessionDisplay(id: running.id)
        display.state = "running"; display.queueCount = 1; display.draft = "Unsent thought"
        display.queue = [["id": .string("queued"), "text": .string("Keep working")]]
        model.displays[running.id] = display; model.selected = display
        model.selectedID = running.id; model.focusedSessionID = running.id; model.selectedWorkspaceID = "project"
        model.opened.insert(running.id)
        let unread = SessionReadState(id: running.id, observedAssistantCount: 2, latestAssistantID: "answer", unreadOutputs: 1, unreadTargetID: "answer")
        model.unreadStates[running.id] = unread
        try await model.store?.put(display.savedDraft, kind: "draft", id: running.id)

        try await model.moveSessions([running.id, pinnedChild.id, running.id], in: "project", toTopic: destination.id)
        XCTAssertEqual(Set(model.chats.filter { $0.topicID == destination.id }.map(\.id)), [running.id, pinnedChild.id, archived.id])
        XCTAssertEqual(model.record(unrelated.id)?.topicID, origin.id); XCTAssertNil(model.record(foreign.id)?.topicID)
        XCTAssertEqual(model.record(pinnedChild.id)?.parentSessionID, running.id); XCTAssertTrue(model.record(pinnedChild.id)?.isPinned == true)
        XCTAssertTrue(model.record(archived.id)?.isArchived == true)
        XCTAssertTrue(model.selected === display); XCTAssertTrue(model.displays[running.id] === display)
        XCTAssertEqual(model.selectedID, running.id); XCTAssertEqual(model.focusedSessionID, running.id)
        XCTAssertEqual(display.state, "running"); XCTAssertEqual(display.queueCount, 1)
        XCTAssertEqual(display.queue.first?["id"]?.string, "queued"); XCTAssertEqual(display.draft, "Unsent thought")
        XCTAssertEqual(model.unreadStates[running.id], unread); XCTAssertTrue(model.opened.contains(running.id)); XCTAssertTrue(model.hasActiveWork)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        for id in [running.id, pinnedChild.id, archived.id] {
            let retained = try await model.store?.get(ChatRecord.self, kind: "chat", id: id)
            XCTAssertEqual(retained?.topicID, destination.id)
        }
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: running.id)
        XCTAssertEqual(draft?.text, "Unsent thought")
        display.state = "idle"; display.queueCount = 0; model.opened.remove(running.id)
        await model.store?.close()
    }

    @MainActor func testMovingChildMaterializesPendingDraftWithoutMovingParentAndHandlesCycles() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Investigation")
        let parent = chat("parent"), child = chat("child", parent: parent.id), grandchild = chat("grandchild", parent: child.id)
        let firstCycle = chat("cycle-a", parent: "cycle-b"), secondCycle = chat("cycle-b", parent: "cycle-a")
        model.chats = [parent, child, grandchild, firstCycle, secondCycle]
        for item in model.chats where item.id != child.id { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.pendingChatIDs.insert(child.id)
        let display = SessionDisplay(id: child.id); display.draft = "Keep my pending draft"; model.displays[child.id] = display
        try await model.moveSessions([child.id, firstCycle.id], in: "project", toTopic: topic.id)
        XCTAssertNil(model.record(parent.id)?.topicID)
        XCTAssertEqual(Set(model.chats.filter { $0.topicID == topic.id }.map(\.id)), [child.id, grandchild.id, firstCycle.id, secondCycle.id])
        XCTAssertEqual(model.record(child.id)?.parentSessionID, parent.id)
        XCTAssertFalse(model.pendingChatIDs.contains(child.id))
        let storedChild = try await model.store?.get(ChatRecord.self, kind: "chat", id: child.id)
        let storedDraft = try await model.store?.get(DraftRecord.self, kind: "draft", id: child.id)
        XCTAssertEqual(storedChild?.topicID, topic.id); XCTAssertEqual(storedDraft?.text, display.draft)
        let entries = model.sidebarEntries(in: "project", topicID: topic.id, archived: false, collapsed: [])
        XCTAssertEqual(Set(entries.map(\.id)), [child.id, grandchild.id, firstCycle.id, secondCycle.id])
        XCTAssertEqual(entries.count, 4); XCTAssertEqual(entries.first(where: { $0.id == child.id })?.depth, 0)
        await model.store?.close()
    }

    @MainActor func testInvalidDropsRejectEntireBatchWithoutChangingMetadataOrFocus() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let local = try await model.createTopic(in: "project", title: "Local"), foreign = try await model.createTopic(in: "other", title: "Foreign")
        model.chats = [chat("local"), chat("foreign", project: "other")]
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.selectedID = "local"; model.focusedSessionID = "local"; model.selectedWorkspaceID = "project"
        let before = model.chats
        for (ids, target) in [(["local"], foreign.id), (["local", "foreign"], local.id), (["local", "missing"], local.id), (["local"], "missing")] {
            do { try await model.moveSessions(ids, in: "project", toTopic: target); XCTFail("Invalid drop must reject the whole batch: \(ids)") } catch { }
            XCTAssertEqual(model.chats, before)
            for item in before {
                let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: item.id)
                XCTAssertEqual(stored, item)
            }
        }
        XCTAssertEqual(model.selectedID, "local"); XCTAssertEqual(model.focusedSessionID, "local"); XCTAssertEqual(model.selectedWorkspaceID, "project")
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testDeletingTopicUngroupsSavedChatsButPreservesDraftsAndHistory() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Temporary")
        let retained = try await model.createTopic(in: "project", title: "Retained")
        let journal = root.appendingPathComponent("saved.jsonl"), bytes = Data("retained history\n".utf8)
        try bytes.write(to: journal)
        var parent = chat("parent", topic: topic.id); parent.path = journal.path
        let child = chat("child", topic: topic.id, parent: parent.id), other = chat("other", topic: retained.id)
        model.chats = [parent, child, other]
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        try await model.store?.put(DraftRecord(id: child.id, text: "Saved draft"), kind: "draft", id: child.id)
        let display = SessionDisplay(id: parent.id); display.draft = "In-memory draft"
        model.displays[parent.id] = display; model.selected = display; model.selectedID = parent.id; model.focusedSessionID = parent.id
        // A pending disclosure write must never resurrect a deleted topic.
        model.setTopicExpanded(topic.id, expanded: false)
        try await model.removeTopic(topic.id)
        let flushed = await model.flushTopicChanges(); XCTAssertTrue(flushed)
        XCTAssertEqual(model.chats.count, 3); XCTAssertNil(model.record(parent.id)?.topicID); XCTAssertNil(model.record(child.id)?.topicID)
        XCTAssertEqual(model.record(other.id)?.topicID, retained.id); XCTAssertEqual(model.record(child.id)?.parentSessionID, parent.id)
        XCTAssertTrue(model.selected === display); XCTAssertEqual(model.selectedID, parent.id); XCTAssertEqual(model.focusedSessionID, parent.id)
        XCTAssertEqual(display.draft, "In-memory draft"); XCTAssertEqual(try Data(contentsOf: journal), bytes)
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: child.id)
        XCTAssertEqual(draft?.text, "Saved draft")
        let saved = try await model.store?.loadChats() ?? []
        XCTAssertNil(saved.first(where: { $0.id == parent.id })?.topicID); XCTAssertNil(saved.first(where: { $0.id == child.id })?.topicID)
        model.topics = []; try await model.restoreTopics()
        XCTAssertEqual(model.topics(in: "project").map(\.id), [retained.id])
        await model.store?.close()
    }

    @MainActor func testScopedSidebarKeepsOrphansPinArchiveAndSplitChildrenVisibleExactlyOnce() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Research"), otherTopic = try await model.createTopic(in: "other", title: "Other project")
        let parent = chat("parent", topic: topic.id, order: 8), child = chat("child", topic: topic.id, parent: parent.id, order: 7)
        var pinned = chat("pin", topic: topic.id, parent: parent.id, order: 1); pinned.pinnedAt = Date(timeIntervalSince1970: 1)
        var archived = chat("archive", topic: topic.id, parent: parent.id, order: 9); archived.archivedAt = Date(timeIntervalSince1970: 1)
        let rootChild = chat("root-child", parent: parent.id, order: 4)
        let missing = chat("missing", topic: "deleted-topic", order: 3), mismatched = chat("mismatched", topic: otherTopic.id, order: 2)
        model.chats = [parent, child, pinned, archived, rootChild, missing, mismatched, chat("foreign", topic: otherTopic.id, project: "other")]
        XCTAssertNil(model.effectiveTopicID(for: missing)); XCTAssertNil(model.effectiveTopicID(for: mismatched))
        XCTAssertEqual(model.effectiveTopicID(for: parent), topic.id)
        let grouped = model.sidebarEntries(in: "project", topicID: topic.id, archived: false, collapsed: [])
        let ungrouped = model.sidebarEntries(in: "project", topicID: nil, archived: false, collapsed: [])
        XCTAssertEqual(grouped.map(\.id), [pinned.id, parent.id, child.id]); XCTAssertEqual(grouped.map(\.depth), [0, 0, 1])
        XCTAssertEqual(ungrouped.map(\.id), [rootChild.id, missing.id, mismatched.id]); XCTAssertTrue(ungrouped.allSatisfy { $0.depth == 0 })
        XCTAssertEqual(Set((grouped + ungrouped).map(\.id)).count, 6)
        XCTAssertEqual(model.sidebarEntries(in: "project", topicID: topic.id, archived: false, collapsed: [parent.id]).map(\.id), [pinned.id, parent.id])
        XCTAssertEqual(model.sidebarEntries(in: "project", topicID: topic.id, archived: true, collapsed: []).map(\.id), [archived.id])
        XCTAssertTrue(model.sidebarEntries(in: "project", topicID: nil, archived: true, collapsed: []).isEmpty)
        XCTAssertEqual(Set(model.sidebarEntries(in: "project", archived: false, collapsed: []).map(\.id)), Set((grouped + ungrouped).map(\.id)), "The compatibility overload still includes every active chat")
        await model.store?.close()
    }

    @MainActor func testTopicDisclosureAndKeyboardOrderMatchSidebarAndSelectionRevealsOnlyTarget() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let first = try await model.createTopic(in: "project", title: "First"), second = try await model.createTopic(in: "project", title: "Second")
        let firstChat = chat("first-chat", topic: first.id), secondChat = chat("second-chat", topic: second.id), rootChat = chat("root-chat")
        model.chats = [rootChat, secondChat, firstChat]
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        let byTopic = [first.id: firstChat.id, second.id: secondChat.id]
        let expected = model.topics(in: "project").compactMap { byTopic[$0.id] } + [rootChat.id]
        XCTAssertEqual(model.sidebarChatOrder, expected)
        model.setTopicExpanded(first.id, expanded: false)
        XCTAssertEqual(model.sidebarChatOrder, expected.filter { $0 != firstChat.id })
        model.setTopicExpanded(second.id, expanded: false)
        XCTAssertEqual(model.sidebarChatOrder, [rootChat.id])
        model.setProjectExpanded("project", expanded: false); model.setProjectExpanded("other", expanded: false)
        XCTAssertTrue(model.sidebarChatOrder.isEmpty)
        await model.select(firstChat.id, revealInSidebar: false)
        XCTAssertFalse(model.projectIsExpanded("project")); XCTAssertFalse(model.topics(in: "project").first(where: { $0.id == first.id })?.expanded ?? true)
        await model.select(firstChat.id)
        XCTAssertTrue(model.projectIsExpanded("project")); XCTAssertFalse(model.projectIsExpanded("other"))
        XCTAssertTrue(model.topics(in: "project").first(where: { $0.id == first.id })?.expanded == true)
        XCTAssertFalse(model.topics(in: "project").first(where: { $0.id == second.id })?.expanded ?? true)
        XCTAssertEqual(model.sidebarChatOrder, [firstChat.id, rootChat.id])
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testTopicDisclosureWriteFailureIsVisibleAndFlushIsBounded() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Unsaved collapse")
        await model.store?.close()
        model.setTopicExpanded(topic.id, expanded: false)
        let immediate = await model.flushTopicChanges(timeout: 0); XCTAssertFalse(immediate)
        let start = ProcessInfo.processInfo.systemUptime
        let saved = await model.flushTopicChanges(timeout: 0.5)
        XCTAssertFalse(saved); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertFalse(model.topics(in: "project").first?.expanded ?? true)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.error?.isEmpty ?? true)
    }

    @MainActor func testNewChatUsesFocusedTopicAndEmptyPendingReuseStaysInsideThatTopic() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "fixture"; profile.name = "Fixture"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile, project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [project]; $0.profiles = [VaultProfile(profile: savedProfile, apiKey: "synthetic-topic-test-key")] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault); defer { model.shutdown() }
        await model.restore(); model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        let first = try await model.createTopic(in: project.id, title: "First"), second = try await model.createTopic(in: project.id, title: "Second")
        model.newChat(in: project.id, topicID: first.id)
        try await settle { model.selectedID != nil && model.workspaceChangesInFlight.isEmpty }
        let initial = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.record(initial)?.topicID, first.id); XCTAssertTrue(model.pendingChatIDs.contains(initial))
        model.newChat()
        try await settle { model.workspaceChangesInFlight.isEmpty }
        XCTAssertEqual(model.selectedID, initial, "Default New Chat reuses the empty chat in its focused topic")

        model.newChat(in: project.id, topicID: second.id)
        try await settle { model.selectedID != initial && model.selectedID != nil && model.workspaceChangesInFlight.isEmpty }
        let inSecond = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.record(inSecond)?.topicID, second.id)
        XCTAssertFalse(model.chats.contains { $0.id == initial }, "The unused old pending chat can still be discarded")

        model.displays[inSecond]?.draft = "Keep this draft"
        model.newChat()
        try await settle { model.selectedID != inSecond && model.selectedID != nil && model.workspaceChangesInFlight.isEmpty }
        let inherited = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.record(inherited)?.topicID, second.id, "Default New Chat stays with its focused conversation")
        XCTAssertEqual(model.displays[inSecond]?.draft, "Keep this draft")

        model.newChat(in: project.id)
        try await settle { model.selectedID != inherited && model.selectedID != nil && model.workspaceChangesInFlight.isEmpty }
        let atRoot = try XCTUnwrap(model.selectedID)
        XCTAssertNil(model.record(atRoot)?.topicID, "The project's own New Chat button explicitly creates at project root")
        let stored = try await model.store?.list(ChatRecord.self, kind: "chat") ?? []
        XCTAssertTrue(stored.isEmpty, "Grouping a new draft does not eagerly create helper sessions or journal records")
        XCTAssertTrue(model.hosts.isEmpty)
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testPendingSideInheritsTopicAndSelectingItRevealsGroup() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Parent topic")
        let parent = chat("parent", topic: topic.id)
        model.chats = [parent]; model.selectedID = parent.id; model.focusedSessionID = parent.id
        let display = SessionDisplay(id: parent.id); model.displays[parent.id] = display; model.selected = display
        try await model.store?.put(parent, kind: "chat", id: parent.id)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id])
        XCTAssertTrue(side.pending); XCTAssertEqual(side.chat.topicID, topic.id)
        XCTAssertEqual(model.focusedSessionID, side.id); XCTAssertTrue(model.hosts.isEmpty)
        model.setTopicExpanded(topic.id, expanded: false)
        await model.selectSide(side.id)
        XCTAssertTrue(model.topics(in: "project").first?.expanded == true, "Selecting a pending side reveals the parent's topic too")
        model.closeSide(side.id)
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testSideOpenedDuringParentMoveFollowsTheCommittedDestination() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let original = try await model.createTopic(in: "project", title: "Original")
        let destination = try await model.createTopic(in: "project", title: "Destination")
        let parent = chat("parent", topic: original.id)
        let store = try XCTUnwrap(model.store)
        model.chats = [parent]; model.selectedID = parent.id; model.focusedSessionID = parent.id
        let display = SessionDisplay(id: parent.id); model.displays[parent.id] = display; model.selected = display
        try await store.put(parent, kind: "chat", id: parent.id)

        // Hold only the metadata actor, never the main actor. This guarantees
        // that the side opens after the move snapshots its branch but before
        // its durable transaction can return to the model.
        let gate = TopicMetadataWriteGate(); defer { gate.open() }
        let held = Task.detached { await store.waitForTopicOrganizationTest(gate) }
        try await settle { gate.isWaiting }
        let move = Task { try await model.moveSessions([parent.id], in: "project", toTopic: destination.id) }
        try await settle { model.topicOperationsInFlight > 0 }
        model.openSide(parentID: parent.id)
        let pending = try XCTUnwrap(model.sides[parent.id])
        XCTAssertTrue(pending.pending); XCTAssertEqual(pending.topicID, original.id)
        gate.open()
        try await move.value
        let releasedBeforeTimeout = await held.value
        XCTAssertTrue(releasedBeforeTimeout, "The fixture's bounded metadata gate must not time out")
        XCTAssertEqual(model.record(parent.id)?.topicID, destination.id)
        XCTAssertEqual(model.sides[parent.id]?.topicID, destination.id, "The side opened during the move must follow its current parent's committed topic")
        XCTAssertFalse(model.chats.contains { $0.id == pending.id }, "Moving the parent does not eagerly publish an empty side")
        XCTAssertEqual(model.focusedSessionID, pending.id); XCTAssertTrue(model.hosts.isEmpty)
        model.closeSide(pending.id)
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await store.close()
    }

    @MainActor func testProjectRemovalRequiresItsEmptyTopicsToBeRemovedFirst() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [project] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault); defer { model.shutdown() }
        await model.restore()
        let topic = try await model.createTopic(in: project.id, title: "Empty but intentional")
        XCTAssertTrue(model.chats.isEmpty)
        do {
            try await model.removeWorkspace(project.id)
            XCTFail("Removing a project must not strand its topics in a synthetic retained-history group")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("topics"))
        }
        XCTAssertEqual(model.workspaces.map(\.id), [project.id]); XCTAssertEqual(model.topics(in: project.id).map(\.id), [topic.id])
        XCTAssertTrue(model.sidebarProjects.first(where: { $0.id == project.id })?.available == true)
        try await model.removeTopic(topic.id)
        try await model.removeWorkspace(project.id)
        XCTAssertTrue(model.workspaces.isEmpty); XCTAssertTrue(model.topics.isEmpty)
        XCTAssertFalse(model.sidebarProjects.contains { $0.id == project.id })
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testCompletedDeleteWinsOverLateMoveReplyWithoutResurrectingArchivedChild() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root); defer { model.shutdown() }
        let destination = try await model.createTopic(in: "project", title: "Destination")
        let parent = chat("parent")
        var child = chat("archived-child", parent: parent.id); child.archivedAt = Date(timeIntervalSince1970: 1)
        let store = try XCTUnwrap(model.store)
        model.chats = [parent, child]
        for item in model.chats { try await store.put(item, kind: "chat", id: item.id) }
        let childID = child.id, destinationID = destination.id
        let display = SessionDisplay(id: childID)
        model.displays[childID] = display; model.selectedID = childID; model.selected = display; model.focusedSessionID = childID

        let gate = TopicMetadataWriteGate(); defer { gate.open() }
        let held = Task.detached { await store.waitForTopicOrganizationTest(gate) }
        try await settle { gate.isWaiting }
        let move = Task { try await model.moveSessions([parent.id], in: "project", toTopic: destinationID) }
        try await settle { model.topicOperationsInFlight > 0 }

        // Reproduce the deletion's successful metadata-removal phase, then its
        // MainActor removal, before delivering the earlier move's UI callback.
        // No confirmation dialog, Trash operation, or real history is involved.
        let deletionFinished = DispatchSemaphore(value: 0)
        let deletion = Task.detached { () throws -> Bool in
            defer { deletionFinished.signal() }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while ProcessInfo.processInfo.systemUptime < deadline {
                if try await store.get(ChatRecord.self, kind: "chat", id: childID)?.topicID == destinationID {
                    try await store.remove(kind: "chat", id: childID)
                    try await store.remove(kind: "draft", id: childID)
                    return true
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
        gate.open()
        // Briefly keep the move's ready MainActor continuation queued until
        // the independent metadata actor has completed the later deletion.
        XCTAssertEqual(deletionFinished.wait(timeout: .now() + 5), .success)
        model.chats.removeAll { $0.id == childID }; model.displays.removeValue(forKey: childID)
        model.selectedID = nil; model.selected = nil; model.focusedSessionID = nil
        let deletedAfterMoveCommitted = try await deletion.value
        XCTAssertTrue(deletedAfterMoveCommitted)
        try await move.value
        let releasedBeforeTimeout = await held.value
        XCTAssertTrue(releasedBeforeTimeout)
        XCTAssertFalse(model.chats.contains { $0.id == childID }, "An old topic-move reply must not resurrect a chat whose deletion completed")
        XCTAssertNil(model.displays[childID]); XCTAssertNil(model.selectedID); XCTAssertNil(model.focusedSessionID)
        XCTAssertEqual(model.record(parent.id)?.topicID, destinationID)
        let deletedRecord = try await store.get(ChatRecord.self, kind: "chat", id: childID)
        XCTAssertNil(deletedRecord)
        let saved = await model.flushTopicChanges(); XCTAssertTrue(saved)
        await model.flushProjectSidebarState(); await store.close()
    }
}

/// A bounded gate creates a real MainActor/metadata-actor suspension point
/// without sleeps whose ordering depends on machine speed or a live gateway.
private final class TopicMetadataWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var waiting = false
    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting
    }
    func hold() -> Bool {
        lock.lock(); waiting = true; lock.unlock()
        return released.wait(timeout: .now() + 5) == .success
    }
    func open() { released.signal() }
}

private extension MetadataStore {
    func waitForTopicOrganizationTest(_ gate: TopicMetadataWriteGate) -> Bool { gate.hold() }
}
