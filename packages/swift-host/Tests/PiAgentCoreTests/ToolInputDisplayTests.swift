import XCTest
@testable import PiAgentCore

/// A client that hands the test the delta callback, then returns the replies
/// it is given, so a turn can be driven one streamed tool call at a time.
private actor SteppedClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var queued: [ModelReply] = []
    init(_ replies: [ModelReply] = []) { queued = replies }
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func enqueue(_ reply: ModelReply) { queued.append(reply) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while queued.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        return queued.removeFirst()
    }
}

final class ToolInputDisplayTests: XCTestCase {
    private func session(_ root: URL, id: String, seed: [ChatMessage] = [], client: any ModelClient = ScriptClient([])) throws -> AgentSession {
        var profile = try fixtureProfile().raw; profile["contextWindow"] = 1_000_000
        return try AgentSession(id: id, profile: Profile(profile), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), seed: seed, autoCompaction: false)
    }
    private func assistant(_ calls: [ToolCall], id: String = "assistant-1") -> ChatMessage {
        var message = ChatMessage(role: "assistant", content: calls.map { ["type": "toolCall", "id": JSON($0.id), "name": JSON($0.name), "arguments": $0.arguments] })
        message.id = id; return message
    }
    private func card(_ snapshot: JSON, callID: String) -> JSON {
        snapshot["messages"].list.flatMap { $0["tools"].list }.first { $0["id"].text == callID } ?? .null
    }

    /// The bug: `preview(arguments.encoded(), bytes: 4096)` cut the encoded
    /// document mid-string, so every edit over 4 KiB reached the transcript as
    /// unparseable text and showed raw JSON instead of a diff.
    func testInlineToolInputParsesAtEveryArgumentSize() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "let value = 1\n", count: 1500) // ~20 KiB
        let call = ToolCall(id: "call-edit", name: "edit", arguments: ["path": "/tmp/big.swift", "oldText": JSON(body), "newText": JSON(body + "// tail\n")])
        let session = try session(root, id: "inline", seed: [assistant([call])])
        addTeardownBlock { await session.close() }
        let view = card(await session.snapshot(), callID: "call-edit")
        let text = view["input"].text ?? ""
        let parsed = try JSON.parse(Data(text.utf8))
        XCTAssertEqual(parsed["path"].text, "/tmp/big.swift", "Every key survives the display bound")
        XCTAssertNotNil(parsed["oldText"].text); XCTAssertNotNil(parsed["newText"].text)
        XCTAssertEqual(parsed["oldText"].text,body)
        XCTAssertEqual(parsed["newText"].text,body + "// tail\n")
        XCTAssertEqual(view["inputTruncated"].flag, false)
        XCTAssertEqual(view["inputBytes"].int, call.arguments.encoded().utf8.count)
        XCTAssertEqual(view["truncated"].flag, false)
    }

    /// A 20 KiB edit fits the per-tool bound whole: the app can render a full
    /// diff from the on-demand document.
    func testTwentyKiBEditRoundTripsCompleteAtTheToolBound() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let old = String(repeating: "before line\n", count: 1700), new = String(repeating: "after line\n", count: 1700)
        XCTAssertGreaterThan(old.utf8.count, 20_000)
        let call = ToolCall(id: "call-edit", name: "edit", arguments: ["path": "/tmp/big.swift", "oldText": JSON(old), "newText": JSON(new)])
        let session = try session(root, id: "roundtrip", seed: [assistant([call])])
        addTeardownBlock { await session.close() }
        let full = try await session.toolInput(messageID: "assistant-1", callID: "call-edit")
        XCTAssertEqual(full["inputTruncated"].flag, false)
        let parsed = try JSON.parse(Data((full["input"].text ?? "").utf8))
        XCTAssertEqual(parsed["oldText"].text, old, "The whole old text reaches the diff")
        XCTAssertEqual(parsed["newText"].text, new)
        XCTAssertEqual(parsed["path"].text, "/tmp/big.swift")
        do { _ = try await session.toolInput(messageID: "assistant-1", callID: "absent"); XCTFail("An unknown call must not resolve") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "tool_call_missing") }
        do { _ = try await session.toolInput(messageID: "absent", callID: "call-edit"); XCTFail("An unknown message must not resolve") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "message_missing") }
    }

    /// The complete write is displayed even beyond the previous per-tool cap.
    func testTwoHundredKiBWriteIsReturnedWithoutCuttingFields() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let content = String(repeating: "0123456789", count: 20_480) // 200 KiB
        let call = ToolCall(id: "call-write", name: "write", arguments: ["path": "/tmp/huge.txt", "content": JSON(content)])
        let session = try session(root, id: "huge", seed: [assistant([call])])
        addTeardownBlock { await session.close() }
        let full = try await session.toolInput(messageID: "assistant-1", callID: "call-write")
        XCTAssertEqual(full["inputTruncated"].flag, false)
        XCTAssertEqual(full["inputBytes"].int, call.arguments.encoded().utf8.count)
        let text = full["input"].text ?? ""
        let parsed = try JSON.parse(Data(text.utf8))
        XCTAssertEqual(parsed["path"].text, "/tmp/huge.txt", "A short field is never collateral damage")
        let shown = try XCTUnwrap(parsed["content"].text)
        XCTAssertEqual(shown, content)
    }

    /// Complete snapshots may exceed a frame, but each transfer chunk cannot.
    func testCompleteToolSnapshotUsesBoundedTransferChunks() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = SteppedClient(), session = try session(root, id: "delta", client: client)
        addTeardownBlock { await client.enqueue(answer("done")); await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
        try await eventually { await client.ready }
        let body = String(repeating: "abcdefgh", count: 2048) // 16 KiB per text field
        var maximumPage = 0, maximumFrame = 0, revision = ""
        for index in 0..<50 {
            try await client.emit(.tool("call-\(index)", "edit", "{\"path\":\"/tmp/f\(index)\",\"oldText\":\"\(body)\",\"newText\":\"\(body)\"}"))
            let snapshot = await session.snapshot(["displayRevision": JSON(revision)])
            revision = snapshot["displayRevision"].text ?? ""
            maximumPage = max(maximumPage, try snapshot["messages"].data().count)
            maximumFrame = max(maximumFrame, try snapshot.data().count)
        }
        print("PERF tool-input-delta 50x32KiB maxPageBytes=\(maximumPage) maxFrameBytes=\(maximumFrame)")
        XCTAssertGreaterThan(maximumPage,1_048_576, "Complete large snapshots are transferred in pages, not truncated")
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["messages"].list.last?["tools"].list.count,50)
        var transfers = DisplayResultTransfers()
        let marker = try transfers.insert(snapshot.data())
        let first = try transfers.read(marker["id"].text!,offset:0)
        XCTAssertLessThan(try first.data().count,1_048_576)

    }

    /// A reply that announces hundreds of calls used to project every one of
    /// them into the streaming row: a 9.8 MB frame, which exits the helper.
    func testStreamedRowKeepsEveryToolCardWithoutEndingTheTransport() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = SteppedClient(), session = try session(root, id: "many", client: client)
        addTeardownBlock { await client.enqueue(answer("done")); await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
        try await eventually { await client.ready }
        // Control characters encode as \u00XX: six protocol bytes per source byte.
        let hostile = String(repeating: "\u{0001}", count: 8192)
        for index in 0..<400 { try await client.emit(.tool("call-\(index)", "write", hostile)) }
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["messages"].list.last?["truncated"].flag, false)
        try await client.emit(.text("more"))
        snapshot = await session.snapshot()
        let row = try XCTUnwrap(snapshot["messages"].list.last)
        XCTAssertEqual(row["state"].text, "streaming")
        XCTAssertEqual(row["tools"].list.count, 400)
        XCTAssertEqual(row["truncated"].flag, false)
        XCTAssertEqual(row["tools"].list.map { $0["id"].text }, (0..<400).map { "call-\($0)" }, "Cards keep arrival order, not lexicographic order")
        let frame = try snapshot.data().count
        print("PERF tool-input-streaming 400 calls frameBytes=\(frame)")
        XCTAssertGreaterThan(frame,1_048_576)
        var transfers = DisplayResultTransfers()
        let marker = try transfers.insert(snapshot.data())
        XCTAssertLessThan(try transfers.read(marker["id"].text!,offset:0).data().count,1_048_576)
        for card in row["tools"].list { XCTAssertEqual(card["input"].text,hostile) }
    }

    /// Live cards are bounded by count and by the bytes they hold, and the
    /// oldest retire first: a dictionary's key order retired a running card
    /// and kept a finished one.
    func testLiveToolCardsRetireOldestFirstWithinTheirByteBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "y", count: 8192)
        let calls = (0..<300).map { ToolCall(id: "call-\($0)", name: "write", arguments: ["path": JSON("/tmp/f\($0)"), "content": JSON(body)]) }
        let client = ScriptClient([ModelReply(message: assistant(calls), calls: calls, usage: ["input": 1, "output": 1]), answer("done")])
        let session = try session(root, id: "retire", client: client)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "go"), steer: false)
        try await eventually { !(await session.isRunning) }
        let retained = await session.retainedToolStateIDs, bytes = await session.retainedToolStateBytes
        XCTAssertLessThanOrEqual(retained.count, 256)
        XCTAssertLessThanOrEqual(bytes, ToolInputDisplay.retainedTotalBytes)
        XCTAssertEqual(retained.last, "call-299", "The newest card is always retained")
        XCTAssertFalse(retained.contains("call-0"), "The oldest cards retire first")
        let arrival = retained.compactMap { Int($0.dropFirst("call-".count)) }
        XCTAssertEqual(arrival, arrival.sorted(), "Retirement follows arrival order")
    }

    /// A durable card is rebuilt from the complete recorded arguments.
    func testReloadedJournalRowProjectsAParseableToolInput() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state")
        let content = String(repeating: "z", count: 40_960)
        let call = ToolCall(id: "call-write", name: "write", arguments: ["path": "/tmp/reload.txt", "content": JSON(content)])
        let profile = try fixtureProfile()
        let live = try AgentSession(id: "reload", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                    resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        let livePath = await live.path
        let path = try XCTUnwrap(livePath)
        try await live.addHandoff("seed")
        await live.close()
        var record: JSON = ["type": "message", "message": assistant([call]).pi]
        record["id"] = "assistant-1"
        var data = try record.data(); data.append(10)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try handle.seekToEnd()
        // The journal is a single branch: chain onto the last record it holds.
        try handle.close()
        let existing = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let last = try XCTUnwrap(existing.split(separator: "\n").last.map { try JSON.parse(Data($0.utf8))["id"] })
        record["parentId"] = last
        var appended = try record.data(); appended.append(10)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try writer.seekToEnd(); try writer.write(contentsOf: appended); try writer.close()
        let reopened = try AgentSession(id: "reload", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                        resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false)
        addTeardownBlock { await reopened.close() }
        let view = card(await reopened.snapshot(), callID: "call-write")
        // Reload pairs an unresolved call with an explicit unknown outcome,
        // so the reopened row is an outcome-unknown card built from the
        // durable result (before 0.1.85 it read as a plain failure).
        XCTAssertEqual(view["state"].text, "unknown")
        let parsed = try JSON.parse(Data((view["input"].text ?? "").utf8))
        XCTAssertEqual(parsed["path"].text, "/tmp/reload.txt")
        XCTAssertEqual(view["inputTruncated"].flag, false)
        let full = try await reopened.toolInput(messageID: "assistant-1", callID: "call-write")
        XCTAssertEqual(try JSON.parse(Data((full["input"].text ?? "").utf8))["path"].text, "/tmp/reload.txt")
    }

    /// Both reads reach the loaded session under the parameter names the app
    /// sends, instead of falling through to `unsupported_command`.
    func testHostRoutesTheOnDemandReadsToTheSession() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "routed", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic"])
        do { _ = try await host.command("session.tool.input", sessionID: "routed", params: ["messageId": "absent", "callId": "absent"]); XCTFail("The read must reach the session") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "message_missing") }
        do { _ = try await host.command("queue.read", sessionID: "routed", params: ["turnId": "absent"]); XCTFail("The read must reach the session") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "queue_missing") }
        do { _ = try await host.command("session.tool.invented", sessionID: "routed", params: [:]); XCTFail("An invented method is refused") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "unsupported_command") }
        await host.shutdown()
    }

    func testBoundedDocumentKeepsShortValuesAndCapsPathologicalShapes() throws {
        let small: JSON = ["a": "one", "b": 2, "c": .null, "d": [true, false]]
        let untouched = ToolInputDisplay.bounded(small, limit: 4096)
        XCTAssertFalse(untouched.truncated)
        XCTAssertEqual(try JSON.parse(Data(untouched.text.utf8)), small)
        var wide: [String: JSON] = [:]
        for index in 0..<2000 { wide["key-\(index)"] = JSON(String(repeating: "v", count: 64)) }
        let capped = ToolInputDisplay.bounded(.object(wide), limit: 4096)
        XCTAssertTrue(capped.truncated)
        XCTAssertNotNil(try? JSON.parse(Data(capped.text.utf8)), "A pathological shape still parses")
        XCTAssertLessThanOrEqual(capped.text.utf8.count, 4096)
        let list = ToolInputDisplay.bounded(.array((0..<2000).map { JSON("item-\($0)") }), limit: 4096)
        XCTAssertNotNil(try? JSON.parse(Data(list.text.utf8)))
        XCTAssertLessThanOrEqual(list.text.utf8.count, 4096)
    }
}
