import XCTest
@testable import PiAgentCore

final class SideForkTests: XCTestCase {
    func testForkPreservesToolReasoningBranchAndCompactionRecordsAndExactContextWithoutDispatch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), sourcePath = directory.appendingPathComponent("parent.jsonl")
        let profile = try fixtureProfile(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        var journal: SessionJournal? = try SessionJournal(url: sourcePath, id: "parent", cwd: root, binding: profile.binding, create: true)
        try journal!.append(["type":"message","message":["role":"user","content":"older retained prompt"]], id: "older-user")
        try journal!.append(["type":"message","message":["role":"assistant","content":[["type":"thinking","thinking":"visible reasoning","signature":"fixture-signature"],["type":"text","text":"older answer"]],"nativeProviderItems":[["type":"reasoning","encrypted_content":"opaque-fixture-content"]]]], id: "older-answer")
        try journal!.append(["type":"compaction","summary":"retained summary","nativeKeptIDs":["older-user"],"tokensBefore":9000], id: "summary")
        try journal!.append(["type":"message","message":["role":"user","content":"old edited prompt"]], id: "old-edit")
        try journal!.append(["type":"message","message":["role":"assistant","content":"abandoned answer remains on disk"]], id: "abandoned")
        try journal!.append(["type":"branch","fromMessageId":"old-edit","keptIds":["summary","older-user"]], id: "branch")
        try journal!.append(["type":"message","message":["role":"user","content":"replacement prompt"]], id: "replacement")
        let calls = toolReply(["first"]).message
        try journal!.append(["type":"message","message":calls.pi], id: "tools")
        var result = ChatMessage(role: "toolResult", content: [textBlock("full durable tool result")]); result.toolCallId = "call-0"; result.toolName = "first"
        try journal!.append(["type":"message","message":result.pi], id: "tool-result")
        try journal!.append(["type":"message","message":["role":"assistant","content":"final answer"]], id: "answer")
        try journal!.append(["type":"custom","customType":"pi-app.native.context.v1","data":["ids":["summary","replacement","tools","tool-result","answer"]]])
        let sourceRecords = try journal!.records(); journal = nil
        let client = ScriptClient([]), tools = RecordingTools()
        let parent = try AgentSession(id: "parent", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: tools, traces: traces, resumePath: sourcePath.path)
        let originalBytes = try Data(contentsOf: sourcePath), sourceContext = await parent.sideSeed(), sourceView = await parent.snapshot()
        let resultFork = try await parent.fork(to: "fork")
        XCTAssertEqual(try Data(contentsOf: sourcePath), originalBytes, "Forking never rewrites the source")
        let copyPath = try XCTUnwrap(resultFork["path"].text)
        let copy = try AgentSession(id: "fork", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: tools, traces: traces, resumePath: copyPath)
        let copiedContext = await copy.sideSeed(), copiedView = await copy.snapshot()
        XCTAssertEqual(copiedContext.messages.map(\.id), sourceContext.messages.map(\.id))
        XCTAssertEqual(copiedContext.messages.map { $0.content }, sourceContext.messages.map { $0.content })
        XCTAssertEqual(copiedView["messages"], sourceView["messages"])
        XCTAssertEqual(copiedView["queueCount"].int, 0); XCTAssertEqual(copiedView["state"].text, "idle")
        let requests = await client.count; XCTAssertEqual(requests, 0)
        let serialized = try String(contentsOfFile: copyPath, encoding: .utf8)
        XCTAssertTrue(serialized.contains("opaque-fixture-content")); XCTAssertTrue(serialized.contains("fixture-signature"))
        XCTAssertTrue(serialized.contains("abandoned answer remains on disk"))
        let copiedRecords = try Data(contentsOf: URL(fileURLWithPath: copyPath)).split(separator: 10).map { try JSON.parse(Data($0)) }
        for record in sourceRecords where ["message", "branch", "compaction"].contains(record["type"].text ?? "") {
            let saved = try XCTUnwrap(copiedRecords.first { $0["id"] == record["id"] })
            XCTAssertEqual(saved.removing(["parentId", "timestamp", "nativeState"]), record.removing(["parentId", "timestamp", "nativeState"]))
        }
        do { _ = try await parent.fork(to: "fork"); XCTFail("An existing fork must never be overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: sourcePath), originalBytes)
        await copy.close(); await parent.close()
    }

    func testRunningParentForkDoesNotCopyOrReplayPendingQueueAndStaysIndependent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), client = ScriptClient([answer("parent only")], holdFirst: true)
        let resources = Resources(cwd: root, home: root), tools = RecordingTools(), traces = TraceStore(), profile = try fixtureProfile()
        let parent = try AgentSession(id: "parent", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: tools, traces: traces)
        _ = try await parent.submit(Submission(commandID: "active", turnID: "active", text: "current question"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await parent.submit(Submission(commandID: "pending", turnID: "pending", text: "pending follow-up"), steer: false)
        let result = try await parent.fork(to: "fork"), forkClient = ScriptClient([])
        let copy = try AgentSession(id: "fork", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: forkClient, tools: tools, traces: traces, resumePath: result["path"].text)
        let snapshot = await copy.snapshot(), active = await parent.isRunning
        XCTAssertTrue(active); XCTAssertEqual(snapshot["queueCount"].int, 0); XCTAssertEqual(snapshot["state"].text, "idle")
        XCTAssertEqual(snapshot["messages"].list.count, 1); XCTAssertEqual(snapshot["messages"].list.first?["text"].text, "current question")
        XCTAssertFalse(snapshot.encoded().contains("pending follow-up"))
        let count = await forkClient.count; XCTAssertEqual(count, 0)
        await copy.close(); await parent.close()
    }
}
