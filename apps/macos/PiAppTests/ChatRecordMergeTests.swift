import XCTest
@testable import PiApp

/// What the store keeps when a chat record is written over the one it holds
/// (`ChatRecord.merged(over:)` and `fitting(topic:)`): one test per rule, and
/// one that the store's own writes apply them.
final class ChatRecordMergeTests: XCTestCase {
    private func chat(_ id: String = "chat", workspace: String = "project") -> ChatRecord {
        ChatRecord(id: id, workspaceID: workspace, title: "Chat", path: nil, profileID: "profile")
    }

    func testACopyOlderThanTheChatsOrganizationTakesItBack() {
        var held = chat(); held.organizationRevision = 5
        held.pinnedAt = Date(timeIntervalSince1970: 100); held.archivedAt = Date(timeIntervalSince1970: 200)
        held.topicID = "topic"; held.titleWasEdited = true; held.title = "Renamed"
        var stale = chat(); stale.organizationRevision = 4; stale.path = "/journal.jsonl"
        let written = stale.merged(over: held)
        XCTAssertEqual(written.path, "/journal.jsonl", "The copy's own update is written")
        XCTAssertEqual(written.pinnedAt, held.pinnedAt); XCTAssertEqual(written.archivedAt, held.archivedAt)
        XCTAssertEqual(written.topicID, "topic")
        XCTAssertEqual(written.titleWasEdited, true); XCTAssertEqual(written.title, "Renamed")
        XCTAssertEqual(written.organizationRevision, 5)

        // A copy as new as the organization, or newer, is the organization.
        var current = chat(); current.organizationRevision = 5; current.pinnedAt = nil; current.title = "Chat"
        XCTAssertNil(current.merged(over: held).pinnedAt)
        XCTAssertEqual(current.merged(over: held).title, "Chat")
    }

    func testACopyOlderThanTheChatsConnectionChangeTakesItBack() {
        var held = chat(); held.connectionRevision = 9; held.profileID = "second"; held.model = "second-model"
        held.thinkingLevel = "high"; held.contextWindow = 64_000; held.maxOutputTokens = 4_000; held.modelOutputLimit = 8_000
        held.journalRebind = true
        var stale = chat(); stale.connectionRevision = 8; stale.path = "/journal.jsonl"; stale.title = "Titled"
        let written = stale.merged(over: held)
        XCTAssertEqual(written.path, "/journal.jsonl"); XCTAssertEqual(written.title, "Titled", "The copy's own update is written")
        XCTAssertEqual(written.profileID, "second"); XCTAssertEqual(written.model, "second-model"); XCTAssertEqual(written.thinkingLevel, "high")
        XCTAssertEqual(written.contextWindow, 64_000); XCTAssertEqual(written.maxOutputTokens, 4_000); XCTAssertEqual(written.modelOutputLimit, 8_000)
        XCTAssertEqual(written.journalRebind, true, "A journal still to move stays marked")
        XCTAssertEqual(written.connectionRevision, 9)
        // A copy as new as the change, or newer, is the change.
        var current = chat(); current.connectionRevision = 10
        XCTAssertEqual(current.merged(over: held).profileID, "profile"); XCTAssertNil(current.merged(over: held).journalRebind)
    }

    func testACopyWithNoSidebarOrderOrParentKeepsTheOnesHeld() {
        var held = chat(); held.sidebarOrder = 42; held.parentSessionID = "parent"
        var copy = chat(); copy.sidebarOrder = nil; copy.parentSessionID = nil
        XCTAssertEqual(copy.merged(over: held).sidebarOrder, 42)
        XCTAssertEqual(copy.merged(over: held).parentSessionID, "parent")
        copy.sidebarOrder = 7; copy.parentSessionID = "other"
        XCTAssertEqual(copy.merged(over: held).sidebarOrder, 7, "A copy's own order is written")
        XCTAssertEqual(copy.merged(over: held).parentSessionID, "other")
    }

    /// The last activity only moves forward: a copy read before a reply or a
    /// send landed does not move the chat back down the sidebar (0.1.122).
    func testACopyCannotTakeTheChatsLastActivityBack() {
        var held = chat(); held.lastActivityAt = 500
        var copy = chat(); copy.lastActivityAt = nil
        XCTAssertEqual(copy.merged(over: held).lastActivityAt, 500)
        copy.lastActivityAt = 300
        XCTAssertEqual(copy.merged(over: held).lastActivityAt, 500)
        copy.lastActivityAt = 900
        XCTAssertEqual(copy.merged(over: held).lastActivityAt, 900, "A newer activity is written")
    }

    func testTheTitleClaimIsDroppedOnlyOnPurpose() {
        var held = chat(); held.titleTaskSessionID = "title-task"
        let copy = chat()
        XCTAssertEqual(copy.merged(over: held).titleTaskSessionID, "title-task", "A copy without the claim keeps the running request's")
        XCTAssertNil(copy.merged(over: held, releasingTitleClaim: true).titleTaskSessionID)
        var claimed = chat(); claimed.titleTaskSessionID = "newer"
        XCTAssertEqual(claimed.merged(over: held).titleTaskSessionID, "newer")
    }

    func testABackgroundRequestsIdentityAndEndAreWrittenOnce() {
        var held = chat("request", workspace: WorkspaceRecord.scratchID)
        held.title = "Title suggestions"; held.backgroundTask = "title-suggestions"; held.sourceSessionID = "source"
        held.backgroundTaskStartedAt = Date(timeIntervalSince1970: 1); held.backgroundTaskEndedAt = Date(timeIntervalSince1970: 2)
        held.backgroundTaskOutcome = "completed"; held.backgroundTaskResult = "One\nTwo\nThree"; held.backgroundTaskNotice = "Done"
        // A copy read before the request ended: its path update is written,
        // and nothing about how the request ended is taken back.
        var copy = chat("request", workspace: WorkspaceRecord.scratchID)
        copy.title = "Something else"; copy.path = "/request.jsonl"
        let written = copy.merged(over: held)
        XCTAssertEqual(written.path, "/request.jsonl")
        XCTAssertEqual(written.title, "Title suggestions"); XCTAssertEqual(written.backgroundTask, "title-suggestions")
        XCTAssertEqual(written.sourceSessionID, "source")
        XCTAssertEqual(written.backgroundTaskStartedAt, held.backgroundTaskStartedAt); XCTAssertEqual(written.backgroundTaskEndedAt, held.backgroundTaskEndedAt)
        XCTAssertEqual(written.backgroundTaskOutcome, "completed"); XCTAssertEqual(written.backgroundTaskResult, "One\nTwo\nThree")
        XCTAssertEqual(written.backgroundTaskNotice, "Done")
        // An ordinary chat keeps no such fields from what was held.
        var ordinary = chat(); ordinary.backgroundTaskOutcome = "completed"
        XCTAssertNil(chat().merged(over: ordinary).backgroundTaskOutcome)
    }

    func testATopicIsKeptOnlyWhileItStillFitsTheChat() {
        let topic = TopicRecord(id: "topic", workspaceID: "project", title: "Topic", revision: 1)
        var grouped = chat(); grouped.topicID = "topic"
        XCTAssertEqual(grouped.fitting(topic: topic).topicID, "topic")
        XCTAssertNil(grouped.fitting(topic: nil).topicID, "The topic was removed")
        XCTAssertNil(grouped.fitting(topic: TopicRecord(id: "topic", workspaceID: "elsewhere", title: "Topic", revision: 1)).topicID, "Another project's topic")
        XCTAssertNil(grouped.fitting(topic: TopicRecord(id: "topic", workspaceID: "project", title: "  ", revision: 1)).topicID, "An invalid topic")
        var request = grouped; request.backgroundTask = "session-title"
        XCTAssertNil(request.fitting(topic: topic).topicID, "A background request is never in a topic")
        var test = grouped; test.connectionTest = true
        XCTAssertNil(test.fitting(topic: topic).topicID, "A connection test is never in a topic")
        var scratch = chat(workspace: WorkspaceRecord.scratchID); scratch.topicID = "topic"
        XCTAssertNil(scratch.fitting(topic: TopicRecord(id: "topic", workspaceID: WorkspaceRecord.scratchID, title: "Topic", revision: 1)).topicID)
    }

    /// The store's writes apply the rules: an older copy's path update keeps
    /// the rename and the running title claim.
    func testTheStoresWritesApplyTheRules() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("chat-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        try await store.open()
        var held = chat(); held.organizationRevision = 2; held.title = "Renamed"; held.titleWasEdited = true; held.titleTaskSessionID = "title-task"
        try await store.put(held, kind: "chat", id: held.id)
        var stale = chat(); stale.organizationRevision = 1; stale.path = "/journal.jsonl"
        try await store.put(stale, kind: "chat", id: stale.id)
        let written = try await store.get(ChatRecord.self, kind: "chat", id: "chat")
        XCTAssertEqual(written?.path, "/journal.jsonl")
        XCTAssertEqual(written?.title, "Renamed")
        XCTAssertEqual(written?.titleTaskSessionID, "title-task")
        await store.close()
    }
}
