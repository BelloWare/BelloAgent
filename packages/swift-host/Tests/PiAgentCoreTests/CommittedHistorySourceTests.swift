import XCTest
@testable import PiAgentCore

final class CommittedHistorySourceTests: HelperTestCase {
    private func session(_ root: URL, seed: [ChatMessage]? = nil) throws -> AgentSession {
        try AgentSession(id: "history", profile: fixtureProfile(), apiKey: "generated", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: seed, autoCompaction: false)
    }
    func testSourceIsMetadataOnlyAndAppendsKeepAnEarlierBoundaryValid() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root); addTeardownBlock { await session.close() }
        var row = ChatMessage(role: "user", content: [textBlock("Private body stays in journal")]); row.id = "u"
        try await session.append(row)
        let described = try await session.committedHistorySource(), source = try XCTUnwrap(described)
        XCTAssertEqual(source.total, 1); XCTAssertNil(source.liveTail)
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path)); defer { try? file.close() }
        try source.verify(file)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(source), as: UTF8.self).contains("Private body"))
        row.id = "u2"; try await session.append(row)
        let appended = try await session.committedHistorySource(), current = try XCTUnwrap(appended)
        XCTAssertGreaterThan(current.committedBytes, source.committedBytes)
        XCTAssertTrue(current.validates(source, through: 1)); try source.verify(file)
        var edited = current; edited.lineage = "branch"
        XCTAssertFalse(edited.validates(source, through: 1))
        var replaced = current; replaced.inode += 1
        XCTAssertFalse(replaced.validates(source, through: 1))
        var updated = current; updated.presentationRevision += 1
        XCTAssertFalse(updated.validates(source, through: 1))
    }
    func testEphemeralClosedAndLiveTailBoundaries() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let memory = try session(root, seed: [ChatMessage(role: "user", content: [textBlock("Ephemeral")])])
        let absent = try await memory.committedHistorySource(); XCTAssertNil(absent)
        let memoryPage = try await memory.historyWindow([:])
        XCTAssertEqual(memoryPage["messages"].list.first?["text"].text, "Ephemeral")
        await memory.close()
        let saved = try session(root); addTeardownBlock { await saved.close() }
        for id in ["old", "live", "call"] {
            var row = ChatMessage(role: id == "call" ? "assistant" : "user", content: [textBlock(id)]); row.id = id
            try await saved.append(row)
        }
        await saved.historyLiveFixture()
        let described = try await saved.committedHistorySource(), source = try XCTUnwrap(described)
        XCTAssertEqual(source.liveTail, .init(entry: "live", position: 1))
        XCTAssertTrue(source.validates(source, through: 1)); XCTAssertFalse(source.validates(source, through: 2))
        await saved.close()
        let closed = try await saved.committedHistorySource(); XCTAssertNil(closed)
    }
    func testPromotionAndSamePathReplacementRevokeTheDescriptor() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root); addTeardownBlock { await session.close() }
        let described = try await session.committedHistorySource(), source = try XCTUnwrap(described)
        try await session.promoteHistoryFixture()
        let promoted = try await session.committedHistorySource(), current = try XCTUnwrap(promoted)
        XCTAssertFalse(current.sameJournal(as: source)); XCTAssertNotEqual(current.marker, source.marker)
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path)); defer { try? file.close() }
        XCTAssertThrowsError(try source.verify(file)); try current.verify(file)
        let copy = root.appendingPathComponent("replacement.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: copy)
        XCTAssertEqual(rename(copy.path, source.path), 0)
        let replaced = try await session.committedHistorySource(); XCTAssertNil(replaced, "A writer must not describe another inode at its path")
    }
    func testUnpersistedPresentationDefinesTheTailWithoutRevokingOlderRows() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root); addTeardownBlock { await session.close() }
        for id in ["old", "input", "ledger"] {
            var row = ChatMessage(role: id == "ledger" ? "system" : "user", content: [textBlock(id)]); row.id = id
            if id == "ledger" { row.kind = "requestLedger" }
            try await session.append(row)
        }
        let initial = try await session.committedHistorySource(), before = try XCTUnwrap(initial)
        try await session.updateHistoryLedgerFixture(persist: false)
        let changed = try await session.committedHistorySource(), live = try XCTUnwrap(changed)
        XCTAssertEqual(live.liveTail, .init(entry: "ledger", position: 2), "A failed or unfinished durable update still belongs to the helper")
        XCTAssertTrue(live.validates(before, through: 1), "A live overlay beyond the page must not reject useful older history")
        XCTAssertFalse(live.validates(before, through: 3))
        try await session.updateHistoryLedgerFixture(persist: true)
        let saved = try await session.committedHistorySource(), durable = try XCTUnwrap(saved)
        XCTAssertNil(durable.liveTail)
        XCTAssertFalse(durable.validates(before, through: 3), "An appended update to an existing row revokes that older projection")
    }
    func testAbsentUsageDoesNotCreateAnEmptyReplyAnnotationOnReplay() throws {
        let row = try ChatMessage(id: "answer", pi: ["role": "assistant", "content": "A retained answer"])
        XCTAssertTrue(row.view()["reply"].isNull)
    }
    func testLegacyAcceptedPlanNavigationKeepsTheHelperSource() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root); addTeardownBlock { await session.close() }
        let origin = subagentFixtureOrigin(parent: "history")
        XCTAssertNil(origin.taskName)
        try await session.installAdmissionFixturePlan(SubagentPlan(origin: origin, task: "Legacy task", resultMessageID: "result"))
        var call = ChatMessage(role: "assistant", content: [["type": "toolCall", "id": "call", "name": "subagent", "arguments": [:]]]); call.id = "reply"
        try await session.append(call)
        var result = ChatMessage(role: "toolResult", content: [textBlock("Retained result")]); result.id = "result"; result.toolCallId = "call"; result.toolName = "subagent"
        try await session.append(result)
        let source = try await session.committedHistorySource(); XCTAssertNil(source)
        let page = try await session.historyWindow([:])
        XCTAssertFalse(page["messages"].list.first?["tools"].list.first?["subagent"].isNull ?? true,
                       "Legacy navigation synthesized from an accepted plan must remain visible")
    }
}

private extension AgentSession {
    func historyLiveFixture() {
        beginPresentedTask("live"); toolStateOwners["tool"] = "call"
    }
    func promoteHistoryFixture() throws { try journal?.promoteToMailboxCut(managedChild: false) }
    func updateHistoryLedgerFixture(persist: Bool) throws {
        var row = history.first { $0.id == "ledger" }!
        row.detail = "A live update that may not yet have a durable receipt"
        try updatePresentation(row, persist: persist)
    }
}
