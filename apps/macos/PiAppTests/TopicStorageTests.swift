import XCTest
@testable import PiApp

final class TopicStorageTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("topics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func chat(_ id: String, workspaceID: String = "project", topicID: String? = nil) -> ChatRecord {
        ChatRecord(id: id, workspaceID: workspaceID, title: id, path: nil, profileID: "profile", sidebarOrder: 12, topicID: topicID)
    }

    private func reject(_ expected: StoreError = .invalidRecord, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("The invalid operation must not succeed") }
        catch { XCTAssertEqual(error as? StoreError, expected) }
    }

    func testLegacyRecordsDefaultToUngroupedAndTopicsSurviveReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        let legacy = Data(#"{"id":"legacy","workspaceID":"project","title":"Saved before topics","profileID":"profile","toolMode":"editing","imported":false}"#.utf8)
        let old = try JSONDecoder().decode(ChatRecord.self, from: legacy)
        XCTAssertNil(old.topicID)
        try await store.put(old, kind: "chat", id: old.id)
        let proposed = TopicRecord(id: "release", workspaceID: "project", title: "  Release\n preparation  ", createdAt: Date(timeIntervalSince1970: 42))
        let topic = try await store.createTopic(proposed)
        XCTAssertEqual(topic.title, "Release preparation"); XCTAssertTrue(topic.expanded); XCTAssertGreaterThan(topic.revision, 0)
        let moved = try await store.moveChatsToTopic(ids: [old.id], workspaceID: old.workspaceID, topicID: topic.id)
        XCTAssertEqual(moved.map(\.topicID), [topic.id]); XCTAssertEqual(moved.first?.organizationRevision, 1)
        await store.close()
        let reopened = MetadataStore(url: url)
        let topics = try await reopened.listTopics(), chats = try await reopened.loadChats()
        XCTAssertEqual(topics, [topic]); XCTAssertEqual(chats.first?.topicID, topic.id)
        XCTAssertEqual(chats.first?.title, old.title)
        await reopened.close()
    }

    /// One chat row this build cannot decode used to fail every drag into a
    /// topic and every topic deletion, for every project, forever: the row is
    /// not listed in the sidebar either, so the user could never reach it.
    func testAnUnreadableChatRecordDoesNotDisableGroupingOrTopicDeletion() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "release", workspaceID: "project", title: "Release"))
        let readable = chat("session")
        try await store.put(readable, kind: "chat", id: readable.id)
        // A record written by another version: stored under kind "chat", but
        // missing the fields this build's ChatRecord requires.
        try await store.put(WireValue.object(["id": .string("from-another-build"), "title": .string("Newer shape")]),
                            kind: "chat", id: "from-another-build")
        let listed = try await store.loadChats()
        XCTAssertEqual(listed.map(\.id), [readable.id], "the unreadable row is already skipped by the sidebar")

        let moved = try await store.moveChatsToTopic(ids: [readable.id], workspaceID: "project", topicID: topic.id)
        XCTAssertEqual(moved.map(\.id), [readable.id])
        let grouped = try await store.loadChats()
        XCTAssertEqual(grouped.first?.topicID, topic.id)
        let released = try await store.removeTopic(id: topic.id)
        XCTAssertEqual(released.map(\.id), [readable.id])
        let ungrouped = try await store.loadChats(), remaining = try await store.listTopics()
        XCTAssertNil(ungrouped.first?.topicID)
        XCTAssertTrue(remaining.isEmpty)
        await store.close()
    }

    func testLatePathAndModelWritesCannotUndoMoveOrRemoval() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        var stale = chat("session")
        try await store.put(stale, kind: "chat", id: stale.id)
        let moved = try await store.moveChatsToTopic(ids: [stale.id], workspaceID: "project", topicID: topic.id)
        stale.path = "/retained/conversation.jsonl"; stale.model = "catalog-model"
        try await store.put(stale, kind: "chat", id: stale.id)
        let afterMove = try await store.get(ChatRecord.self, kind: "chat", id: stale.id)
        XCTAssertEqual(afterMove?.topicID, topic.id); XCTAssertEqual(afterMove?.organizationRevision, 1)
        XCTAssertEqual(afterMove?.path, stale.path); XCTAssertEqual(afterMove?.model, stale.model)
        var staleMember = try XCTUnwrap(moved.first)
        staleMember.path = stale.path; staleMember.model = "later-model"
        let removed = try await store.removeTopic(id: topic.id)
        XCTAssertEqual(removed.first?.organizationRevision, 2)
        try await store.put(staleMember, kind: "chat", id: staleMember.id)
        let afterRemoval = try await store.get(ChatRecord.self, kind: "chat", id: stale.id)
        XCTAssertNil(afterRemoval?.topicID); XCTAssertEqual(afterRemoval?.organizationRevision, 2)
        XCTAssertEqual(afterRemoval?.model, "later-model"); XCTAssertEqual(afterRemoval?.sidebarOrder, 12)
        await store.close()
    }

    func testMixedProjectOrUnknownDragSelectionChangesNoMembers() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "destination", workspaceID: "project", title: "Destination"))
        _ = try await store.createTopic(TopicRecord(id: "foreign", workspaceID: "other", title: "Other project"))
        let first = chat("a-local"), other = chat("z-foreign", workspaceID: "other")
        for chat in [first, other] { try await store.put(chat, kind: "chat", id: chat.id) }
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id, other.id], workspaceID: "project", topicID: "destination") }
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id, "missing"], workspaceID: "project", topicID: "destination") }
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id], workspaceID: "project", topicID: "foreign") }
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id], workspaceID: "project", topicID: "missing") }
        await reject { _ = try await store.moveChatsToTopic(ids: [], workspaceID: "project", topicID: "destination") }
        let savedFirst = try await store.get(ChatRecord.self, kind: "chat", id: first.id)
        let savedOther = try await store.get(ChatRecord.self, kind: "chat", id: other.id)
        XCTAssertEqual(savedFirst, first); XCTAssertEqual(savedOther, other)
        await store.close()
    }

    func testMovingOutOfTopicKeepsProjectAndExistingOrganization() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        var record = chat("session", topicID: "topic")
        record.pinnedAt = Date(timeIntervalSince1970: 100); record.archivedAt = Date(timeIntervalSince1970: 120)
        record.parentSessionID = "parent"; record.titleWasEdited = true
        try await store.put(record, kind: "chat", id: record.id)
        let result = try await store.moveChatsToTopic(ids: [record.id], workspaceID: "project", topicID: nil)
        let saved = try XCTUnwrap(result.first)
        XCTAssertNil(saved.topicID); XCTAssertEqual(saved.workspaceID, record.workspaceID)
        XCTAssertEqual(saved.pinnedAt, record.pinnedAt); XCTAssertEqual(saved.archivedAt, record.archivedAt)
        XCTAssertEqual(saved.parentSessionID, record.parentSessionID); XCTAssertEqual(saved.title, record.title)
        XCTAssertEqual(saved.sidebarOrder, record.sidebarOrder); XCTAssertEqual(saved.organizationRevision, 1)
        await store.close()
    }

    func testDeletingTopicKeepsJournalsDraftsCommandsAndArchivedChildren() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        _ = try await store.createTopic(TopicRecord(id: "other", workspaceID: "project", title: "Other"))
        let journal = root.appendingPathComponent("retained.jsonl"), content = Data("{\"type\":\"message\",\"text\":\"retained history\"}\n".utf8)
        try content.write(to: journal)
        var record = chat("session", topicID: "topic")
        record.path = journal.path; record.archivedAt = Date(timeIntervalSince1970: 5); record.pinnedAt = Date(timeIntervalSince1970: 3)
        var child = chat("child", topicID: "topic"); child.parentSessionID = record.id
        let unrelated = chat("unrelated", topicID: "other")
        for chat in [record, child, unrelated] { try await store.put(chat, kind: "chat", id: chat.id) }
        let draft = DraftRecord(id: record.id, text: "Still editing")
        let command = CommandIntent(id: "pending", sessionID: record.id, turnID: "turn", text: "Queued follow-up", state: "queued")
        try await store.put(draft, kind: "draft", id: record.id)
        try await store.put(command, kind: "pending:\(record.id)", id: command.id)
        let removed = try await store.removeTopic(id: "topic")
        XCTAssertEqual(Set(removed.map(\.id)), [record.id, child.id]); XCTAssertTrue(removed.allSatisfy { $0.topicID == nil })
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: record.id)
        let savedChild = try await store.get(ChatRecord.self, kind: "chat", id: child.id)
        let other = try await store.get(ChatRecord.self, kind: "chat", id: unrelated.id)
        let savedDraft = try await store.get(DraftRecord.self, kind: "draft", id: record.id)
        let savedCommand = try await store.get(CommandIntent.self, kind: "pending:\(record.id)", id: command.id)
        let topics = try await store.listTopics()
        XCTAssertTrue(saved?.isArchived == true); XCTAssertTrue(saved?.isPinned == true); XCTAssertEqual(saved?.path, journal.path)
        XCTAssertEqual(savedChild?.parentSessionID, record.id); XCTAssertEqual(other, unrelated)
        XCTAssertEqual(savedDraft?.text, draft.text); XCTAssertEqual(savedCommand, command)
        XCTAssertEqual(try Data(contentsOf: journal), content); XCTAssertEqual(topics.map(\.id), ["other"])
        await store.close()
    }

    func testRenameAndDisclosureUseLatestRecordAndMonotonicPersistedRevisions() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        let initial = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Original"))
        async let rename = store.renameTopic(id: initial.id, title: "  Current\n title  ")
        async let collapse = store.setTopicExpanded(id: initial.id, expanded: false)
        let (renamed, collapsed) = try await (rename, collapse)
        let saved = try await store.get(TopicRecord.self, kind: TopicRecord.recordKind, id: initial.id)
        XCTAssertEqual(saved?.title, "Current title"); XCTAssertFalse(saved?.expanded ?? true)
        XCTAssertGreaterThan(renamed.revision, initial.revision); XCTAssertGreaterThan(collapsed.revision, initial.revision)
        XCTAssertNotEqual(renamed.revision, collapsed.revision)
        await reject(.staleRevision) { try await store.put(initial, kind: TopicRecord.recordKind, id: initial.id) }
        await store.close()
        let reopened = MetadataStore(url: url)
        let expanded = try await reopened.setTopicExpanded(id: initial.id, expanded: true)
        XCTAssertGreaterThan(expanded.revision, try XCTUnwrap(saved).revision); XCTAssertEqual(expanded.title, "Current title")
        let longTitle = try await reopened.renameTopic(id: initial.id, title: String(repeating: "🌍", count: 130))
        XCTAssertEqual(longTitle.title.count, 120); XCTAssertGreaterThan(longTitle.revision, expanded.revision)
        await reopened.close()
    }

    func testDeletedTopicCannotBeRecreatedByDelayedSnapshotAfterRestart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("desktop.sqlite"), store = MetadataStore(url: url)
        let proposed = TopicRecord(id: "topic", workspaceID: "project", title: "Removed")
        let saved = try await store.createTopic(proposed)
        _ = try await store.removeTopic(id: saved.id)
        await store.close()
        let reopened = MetadataStore(url: url)
        await reject { _ = try await reopened.createTopic(proposed) }
        await reject { try await reopened.put(saved, kind: TopicRecord.recordKind, id: saved.id) }
        await reject { _ = try await reopened.renameTopic(id: saved.id, title: "Resurrected") }
        await reject { _ = try await reopened.setTopicExpanded(id: saved.id, expanded: false) }
        let topics = try await reopened.listTopics()
        XCTAssertTrue(topics.isEmpty)
        await reopened.close()
    }

    func testPendingChatWritesNormalizeRemovedAndForeignGroupsWithoutLosingHistoryPath() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "foreign", workspaceID: "other", title: "Other"))
        for group in ["deleted", "foreign"] {
            var pending = chat(group, topicID: group); pending.path = root.appendingPathComponent(group + ".jsonl").path
            try await store.put(pending, kind: "chat", id: pending.id)
            let saved = try await store.get(ChatRecord.self, kind: "chat", id: pending.id)
            XCTAssertNil(saved?.topicID); XCTAssertEqual(saved?.path, pending.path)
        }
        await store.close()
    }

    func testInvalidTitlesIdentifiersBackgroundAndScratchMovesAreRejected() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        for (id, workspace) in [("", "project"), ("invalid id", "project"), ("topic", ""), ("topic", WorkspaceRecord.scratchID)] {
            await reject { _ = try await store.createTopic(TopicRecord(id: id, workspaceID: workspace, title: "Invalid")) }
        }
        do { _ = try await store.createTopic(TopicRecord(id: "blank", workspaceID: "project", title: " \n \t ")); XCTFail("Blank title must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("topic")) }
        let topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Valid"))
        do { _ = try await store.renameTopic(id: topic.id, title: " \t "); XCTFail("Blank rename must fail") } catch { }
        var background = chat("background"); background.backgroundTask = "session-title"
        var connection = chat("connection"); connection.connectionTest = true
        let scratch = chat("scratch", workspaceID: WorkspaceRecord.scratchID)
        for chat in [background, connection, scratch] {
            try await store.put(chat, kind: "chat", id: chat.id)
            await reject { _ = try await store.moveChatsToTopic(ids: [chat.id], workspaceID: chat.workspaceID, topicID: nil) }
        }
        let saved = try await store.get(TopicRecord.self, kind: TopicRecord.recordKind, id: topic.id)
        XCTAssertEqual(saved, topic)
        await store.close()
    }

    func testOrganizationOverflowRollsBackEntireMoveAndDeletion() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        let first = chat("a-first", topicID: topic.id)
        var overflow = chat("z-overflow", topicID: topic.id); overflow.organizationRevision = Int64.max
        for chat in [first, overflow] { try await store.put(chat, kind: "chat", id: chat.id) }
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id, overflow.id], workspaceID: "project", topicID: nil) }
        await reject { _ = try await store.removeTopic(id: topic.id) }
        await reject { _ = try await store.updateChatOrganization(id: overflow.id, change: .pinned(true)) }
        let savedFirst = try await store.get(ChatRecord.self, kind: "chat", id: first.id)
        let savedOverflow = try await store.get(ChatRecord.self, kind: "chat", id: overflow.id)
        let topics = try await store.listTopics()
        XCTAssertEqual(savedFirst, first); XCTAssertEqual(savedOverflow, overflow); XCTAssertEqual(topics, [topic])
        await store.close()
    }

    func testTopicRevisionOverflowFailsWithoutChangingOrDeletingRecord() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        var topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        topic.revision = Int64.max
        try await store.put(topic, kind: TopicRecord.recordKind, id: topic.id, revision: topic.revision)
        await reject { _ = try await store.renameTopic(id: topic.id, title: "Overflow") }
        await reject { _ = try await store.setTopicExpanded(id: topic.id, expanded: false) }
        await reject { _ = try await store.removeTopic(id: topic.id) }
        let topics = try await store.listTopics()
        XCTAssertEqual(topics, [topic])
        await store.close()
    }

    func testFailureAfterFirstMemberWriteRollsBackMoveAndTopicDeletion() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Topic"))
        let first = chat("a-first", topicID: topic.id), last = chat("z-last", topicID: topic.id)
        try await store.put(first, kind: "chat", id: first.id)
        // Metadata revision exhaustion is reached by the second write, after
        // a-first has already been changed within the SQLite transaction.
        try await store.put(last, kind: "chat", id: last.id, revision: Int64.max)
        await reject { _ = try await store.moveChatsToTopic(ids: [first.id, last.id], workspaceID: "project", topicID: nil) }
        await reject { _ = try await store.removeTopic(id: topic.id) }
        let savedFirst = try await store.get(ChatRecord.self, kind: "chat", id: first.id)
        let savedLast = try await store.get(ChatRecord.self, kind: "chat", id: last.id)
        let topics = try await store.listTopics()
        let tombstone = try await store.get(Int64.self, kind: TopicRecord.deletedRecordKind, id: topic.id)
        XCTAssertEqual(savedFirst, first); XCTAssertEqual(savedLast, last)
        XCTAssertEqual(topics, [topic]); XCTAssertNil(tombstone)
        await store.close()
    }

    func testClosedStoreCannotAppearToSaveOrRemoveTopic() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let topic = try await store.createTopic(TopicRecord(id: "topic", workspaceID: "project", title: "Saved"))
        await store.close()
        await reject(.unavailable) { _ = try await store.listTopics() }
        await reject(.unavailable) { _ = try await store.createTopic(TopicRecord(id: "new", workspaceID: "project", title: "New")) }
        await reject(.unavailable) { _ = try await store.renameTopic(id: topic.id, title: "Unsaved") }
        await reject(.unavailable) { _ = try await store.setTopicExpanded(id: topic.id, expanded: false) }
        await reject(.unavailable) { _ = try await store.moveChatsToTopic(ids: ["chat"], workspaceID: "project", topicID: topic.id) }
        await reject(.unavailable) { _ = try await store.removeTopic(id: topic.id) }
    }

    func testParentMoveAndFirstKeptSideCommitAgreeInEitherOrder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "before", workspaceID: "project", title: "Before"))
        _ = try await store.createTopic(TopicRecord(id: "after", workspaceID: "project", title: "After"))
        for keepFirst in [true, false] {
            let suffix = keepFirst ? "keep-first" : "move-first"
            let parent = chat("parent-" + suffix, topicID: "before")
            var side = chat("side-" + suffix, topicID: "before"); side.parentSessionID = parent.id
            side.path = root.appendingPathComponent(side.id + ".jsonl").path
            let draft = DraftRecord(id: side.id, text: "Preserved side draft")
            try await store.put(parent, kind: "chat", id: parent.id)
            if keepFirst {
                let kept = try await store.commitKeptSide(side, draft: draft)
                XCTAssertEqual(kept.topicID, "before")
                // Only the parent is supplied: the side is durable but its row
                // has not yet been published to the caller's sidebar snapshot.
                let moved = try await store.moveChatsToTopic(ids: [parent.id], workspaceID: "project", topicID: "after")
                XCTAssertEqual(Set(moved.map(\.id)), [parent.id, side.id])
            } else {
                _ = try await store.moveChatsToTopic(ids: [parent.id], workspaceID: "project", topicID: "after")
                let kept = try await store.commitKeptSide(side, draft: draft)
                XCTAssertEqual(kept.topicID, "after", "The returned row must use the current persisted parent, not its captured topic")
            }
            let savedParent = try await store.get(ChatRecord.self, kind: "chat", id: parent.id)
            let savedSide = try await store.get(ChatRecord.self, kind: "chat", id: side.id)
            let savedDraft = try await store.get(DraftRecord.self, kind: "draft", id: side.id)
            XCTAssertEqual(savedParent?.topicID, "after"); XCTAssertEqual(savedSide?.topicID, "after")
            XCTAssertEqual(savedSide?.parentSessionID, parent.id); XCTAssertEqual(savedSide?.path, side.path)
            XCTAssertEqual(savedDraft?.text, draft.text)
        }
        await store.close()
    }

    func testKeepReplayPreservesIndependentChildOrganizationAndForkKeepsCapturedTopic() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        for id in ["original", "parent-group", "child-group"] {
            _ = try await store.createTopic(TopicRecord(id: id, workspaceID: "project", title: id))
        }
        let parent = chat("parent", topicID: "original")
        var capturedSide = chat("side", topicID: "original"); capturedSide.parentSessionID = parent.id
        let draft = DraftRecord(id: capturedSide.id, text: "Kept draft")
        try await store.put(parent, kind: "chat", id: parent.id)
        _ = try await store.commitKeptSide(capturedSide, draft: draft)
        _ = try await store.moveChatsToTopic(ids: [parent.id], workspaceID: "project", topicID: "parent-group")
        _ = try await store.moveChatsToTopic(ids: [capturedSide.id], workspaceID: "project", topicID: "child-group")
        _ = try await store.updateChatOrganization(id: capturedSide.id, change: .title("Independently named side"))
        let organized = try await store.updateChatOrganization(id: capturedSide.id, change: .pinned(true))
        capturedSide.path = root.appendingPathComponent("retained-side.jsonl").path
        let replayed = try await store.commitKeptSide(capturedSide, draft: draft)
        XCTAssertEqual(replayed.topicID, "child-group"); XCTAssertEqual(replayed.organizationRevision, organized.organizationRevision)
        XCTAssertEqual(replayed.title, organized.title); XCTAssertEqual(replayed.pinnedAt, organized.pinnedAt)
        XCTAssertEqual(replayed.path, capturedSide.path)
        // A fork is independent: even if the source moved while it was being
        // retained, its explicitly captured topic remains its initial group.
        let fork = chat("fork", topicID: "original")
        let keptFork = try await store.commitKeptSide(fork, draft: DraftRecord(id: fork.id, text: "Fork draft"))
        XCTAssertNil(keptFork.parentSessionID); XCTAssertEqual(keptFork.topicID, "original")
        await store.close()
    }

    func testMoveDiscoversDurableDescendantsWithoutCrossingProjectsOrLoopingCycles() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        _ = try await store.createTopic(TopicRecord(id: "before", workspaceID: "project", title: "Before"))
        _ = try await store.createTopic(TopicRecord(id: "after", workspaceID: "project", title: "After"))
        var parent = chat("parent", topicID: "before"); parent.parentSessionID = "grandchild"
        var child = chat("child", topicID: "before"); child.parentSessionID = parent.id
        var grandchild = chat("grandchild", topicID: "before"); grandchild.parentSessionID = child.id
        var foreign = chat("foreign", workspaceID: "other"); foreign.parentSessionID = parent.id
        var acrossForeign = chat("across-foreign", topicID: "before"); acrossForeign.parentSessionID = foreign.id
        var utility = chat("utility"); utility.parentSessionID = parent.id; utility.backgroundTask = "session-title"
        let fork = chat("fork", topicID: "before")
        for record in [parent, child, grandchild, foreign, acrossForeign, utility, fork] {
            try await store.put(record, kind: "chat", id: record.id)
        }
        let moved = try await store.moveChatsToTopic(ids: [parent.id], workspaceID: "project", topicID: "after")
        XCTAssertEqual(Set(moved.map(\.id)), [parent.id, child.id, grandchild.id])
        XCTAssertTrue(moved.allSatisfy { $0.topicID == "after" && $0.organizationRevision == 1 })
        for untouched in [foreign, acrossForeign, utility, fork] {
            let saved = try await store.get(ChatRecord.self, kind: "chat", id: untouched.id)
            XCTAssertEqual(saved, untouched)
        }
        await store.close()
    }
}
