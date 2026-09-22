import XCTest
@testable import PiAgentCore

private actor OrderClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var pending: [ModelReply] = []
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func finish(_ value: ModelReply) { pending.append(value) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while pending.isEmpty { try await Task.sleep(nanoseconds: 500_000) }
        callback = nil
        return pending.removeFirst()
    }
}

/// What the display row says about the order a reply happened in.
///
/// A reply is not reasoning, then tools, then prose: it is whatever the model
/// actually produced, in that order. The row carries that order as its parts —
/// arrival order while it streams, the recorded order once it is journaled —
/// and keeps `text`, `thinking` and `tools` beside it so a reader that only
/// knows those fields is unaffected.
final class ResponseOrderTests: XCTestCase {
    private func session(root: URL, id: String, client: any ModelClient) throws -> AgentSession {
        var profile = try fixtureProfile().raw; profile["contextWindow"] = 1_000_000
        return try AgentSession(id: id, profile: Profile(profile), apiKey: "fixture", cwd: root,
                                directory: root.appendingPathComponent("state"), readOnly: true,
                                resources: Resources(cwd: root, home: root), client: client,
                                tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
    }
    /// One provider part event, as the display-event reader makes them.
    private func part(_ ordinal: Int, _ kind: String, _ update: String, _ text: String, call: String? = nil, name: String? = nil, item: Int? = nil) -> ResponsePartEvent {
        ResponsePartEvent(attemptID: "attempt-1", ordinal: ordinal, itemID: "item-\(item ?? ordinal)", outputIndex: item ?? ordinal,
                          partIndex: 0, kind: kind, update: update, text: text, callID: call, name: name)
    }
    /// The kinds of a display row's parts, in the order the row holds them.
    private func kinds(_ row: JSON) -> [String] { row["responseTimeline"]["segments"].list.compactMap { $0["part"]["kind"].text } }
    private func texts(_ row: JSON) -> [String] { row["responseTimeline"]["segments"].list.compactMap { $0["text"].text } }
    private func streamingRow(_ snapshot: JSON) -> JSON? { snapshot["messages"].list.last { $0["state"].text == "streaming" } }

    /// text → a tool call → returned reasoning → text, as it arrived.
    func testTheStreamingRowKeepsTheArrivalOrderOfItsParts() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OrderClient()
        let session = try session(root: root, id: "arrival", client: client)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Run the tests and explain"), steer: false)
        try await eventually { await client.ready }
        // The reply, in the order the provider delivered it.
        try await client.emit(.part(part(0, "text", "append", "First, here is what I found.")))
        try await client.emit(.text("First, here is what I found."))
        try await client.emit(.part(part(1, "toolArguments", "append", "{\"command\":\"npm test\"}", call: "call-0", name: "bash")))
        try await client.emit(.tool("call-0", "bash", "{\"command\":\"npm test\"}"))
        try await client.emit(.part(part(2, "reasoningText", "append", "The suite passed.")))
        try await client.emit(.thinking("The suite passed."))
        try await client.emit(.part(part(3, "text", "append", "So the change is safe.")))
        try await client.emit(.text("So the change is safe."))
        let snapshot = await session.snapshot()
        let row = try XCTUnwrap(streamingRow(snapshot))
        XCTAssertEqual(kinds(row), ["text", "toolArguments", "reasoningText", "text"],
                       "The row says what happened, in order")
        XCTAssertEqual(texts(row), ["First, here is what I found.", "{\"command\":\"npm test\"}", "The suite passed.", "So the change is safe."],
                       "A text segment split by an intervening call stays two segments")
        // The call's own card, referenced by the part that made it.
        let segments = row["responseTimeline"]["segments"].list
        XCTAssertEqual(segments[1]["part"]["callID"].text, "call-0")
        XCTAssertEqual(row["tools"].list.first?["id"].text, "call-0")
        // The flat fields a 0.1.78 reader knows are unchanged.
        XCTAssertEqual(row["text"].text, "First, here is what I found.So the change is safe.")
        XCTAssertEqual(row["thinking"].text, "The suite passed.")
        await client.finish(answer("Done"))
        try await eventually { !(await session.isRunning) }
    }

    /// The row-update path carries the tokens of the part they belong to, and
    /// says when a new part joined the order.
    func testTheRowUpdatePathCarriesPartAppendsAndTheirOrder() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OrderClient()
        let session = try session(root: root, id: "delta", client: client)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Explain"), steer: false)
        try await eventually { await client.ready }
        try await client.emit(.part(part(0, "text", "append", "First ")))
        try await client.emit(.text("First "))
        var revision = (await session.snapshot(["messageDelta": true]))["displayRevision"]
        // A token of the part that is already there: an append, with the
        // revision it applies to.
        try await client.emit(.part(part(0, "text", "append", "half. ")))
        try await client.emit(.text("half. "))
        var next = await session.snapshot(["displayRevision": revision, "messageDelta": true])
        var parts = next["messageDelta"]["parts"].list
        XCTAssertEqual(parts.count, 1)
        let append = try XCTUnwrap(parts.first?["appends"].list.first)
        XCTAssertEqual(append["text"].text, "half. ", "An append carries the added text, not the part again")
        XCTAssertEqual(append["revision"].int, (append["baseRevision"].int ?? -1) + 1)
        XCTAssertTrue(parts.first?["order"].isNull ?? false, "The order did not change, so it is not sent")
        revision = next["displayRevision"]
        // A part that was not there before: the order is sent with it.
        try await client.emit(.part(part(1, "reasoningText", "append", "Thinking it through.")))
        try await client.emit(.thinking("Thinking it through."))
        next = await session.snapshot(["displayRevision": revision, "messageDelta": true])
        parts = next["messageDelta"]["parts"].list
        let order = try XCTUnwrap(parts.first?["order"].list).compactMap(\.text)
        XCTAssertEqual(order.count, 2, "A new part joins the order, and the order is sent")
        XCTAssertEqual(parts.first?["segments"].list.compactMap { $0["part"]["kind"].text }, ["reasoningText"],
                       "Only the part that is new travels as a whole part")
        let continued = try XCTUnwrap(parts.first?["appends"].list.first)
        XCTAssertEqual(continued["state"].text, "continued",
                       "The part it interrupted says so through an append, without its text again")
        XCTAssertEqual(continued["text"].text, "")
        await client.finish(answer("Done"))
        try await eventually { !(await session.isRunning) }
    }

    /// The journal holds the parts in order, so reopening the chat shows the
    /// same reply in the same order.
    func testReloadingTheJournalKeepsTheOrderTheReplyHappenedIn() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = OrderClient()
        let profile = try fixtureProfile(), resources = Resources(cwd: root, home: root)
        let state = root.appendingPathComponent("state")
        let session = try AgentSession(id: "reload", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true,
                                       resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Explain"), steer: false)
        try await eventually { await client.ready }
        try await client.emit(.part(part(0, "text", "append", "Before. ")))
        try await client.emit(.text("Before. "))
        try await client.emit(.part(part(1, "reasoningText", "append", "Why.")))
        try await client.emit(.thinking("Why."))
        try await client.emit(.part(part(2, "text", "append", "After.")))
        try await client.emit(.text("After."))
        var reply = ChatMessage(role: "assistant", content: [textBlock("Before. "), ["type": "thinking", "thinking": "Why."], textBlock("After.")])
        reply.id = "settled"
        await client.finish(ModelReply(message: reply, calls: [], usage: ["input": 10, "output": 3]))
        try await eventually { !(await session.isRunning) }
        let before = await session.snapshot()
        let settled = try XCTUnwrap(before["messages"].list.last)
        XCTAssertEqual(kinds(settled), ["text", "reasoningText", "text"], "The settled row keeps the order it arrived in")
        let stored = await session.path
        let path = try XCTUnwrap(stored)
        await session.close()

        let reopened = try AgentSession(id: "reload", profile: profile, apiKey: "k", cwd: root, directory: state, readOnly: true,
                                        resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                                        resumePath: path, autoCompaction: false)
        addTeardownBlock { await reopened.close() }
        let after = await reopened.snapshot()
        let reloaded = try XCTUnwrap(after["messages"].list.last)
        XCTAssertEqual(kinds(reloaded), ["text", "reasoningText", "text"], "Reopening the chat shows the same order")
        XCTAssertEqual(texts(reloaded), ["Before. ", "Why.", "After."])
        XCTAssertEqual(reloaded["text"].text, "Before. After.")
        XCTAssertEqual(reloaded["thinking"].text, "Why.")
    }

    /// A gateway whose text deltas carry no output item, followed by a
    /// terminal response object that does: the reply is one part, shown once.
    func testATerminalObjectThatRepeatsUnkeyedDeltasIsTheSameReply() {
        var events = ProviderDisplayEvents(api: "openai-responses", attempt: "attempt-1")
        let text = "Fixture reply: Summarize the plan in one line."
        for chunk in [String(text.prefix(20)), String(text.dropFirst(20))] {
            _ = events.consume(["type": "response.output_text.delta", "delta": JSON(chunk)], at: 1)
        }
        XCTAssertEqual(events.timeline.segments.map(\.text), [text], "The deltas are one part")
        let output: JSON = .array([["id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                                    "content": .array([["type": "output_text", "text": JSON(text)]])]])
        _ = events.consume(["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": output]], at: 2)
        XCTAssertEqual(events.timeline.segments.map(\.text), [text],
                       "A terminal object repeating what arrived does not show the reply twice")
        XCTAssertEqual(events.timeline.segments.count, 1)
        XCTAssertEqual(events.timeline.terminal, "completed")
        // Different terminal content is still explicit correction evidence.
        var corrected = ProviderDisplayEvents(api: "openai-responses", attempt: "attempt-2")
        _ = corrected.consume(["type": "response.output_text.delta", "delta": "Half a rep"], at: 1)
        let fixed: JSON = .array([["id": "msg_2", "type": "message", "role": "assistant", "status": "completed",
                                   "content": .array([["type": "output_text", "text": "Half a reply, then more."]])]])
        _ = corrected.consume(["type": "response.completed", "response": ["id": "resp_2", "status": "completed", "output": fixed]], at: 2)
        XCTAssertEqual(corrected.timeline.segments.map(\.text), ["Half a rep", "Half a reply, then more."],
                       "The fragment that arrived stays; the terminal content is evidence beside it")
        XCTAssertEqual(corrected.timeline.segments.map(\.part.kind), ["text", "correction"],
                       "Different terminal content is an explicit correction, which an unkeyed stream could not say before")
    }

    /// A tool result row names the call it belongs to, so a display that shows
    /// the call in its chronological place can show the result once.
    func testAToolResultRowNamesTheCallItBelongsTo() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root: root, id: "results", client: ScriptClient([toolReply(["read"]), answer("Done")]))
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Read the file"), steer: false)
        try await eventually { !(await session.isRunning) }
        let rows = await session.snapshot()["messages"].list
        let result = try XCTUnwrap(rows.first { $0["kind"].text == "toolResult" })
        XCTAssertEqual(result["toolCallID"].text, "call-0", "The result says which call it is the result of")
        let reply = try XCTUnwrap(rows.first { $0["tools"].list.contains { $0["id"].text == "call-0" } })
        XCTAssertEqual(reply["tools"].list.first?["state"].text, "completed",
                       "The reply's own card carries the same result, so the row need not be shown twice")
        XCTAssertTrue(rows.allSatisfy { $0["kind"].text == "toolResult" || $0["toolCallID"].isNull },
                      "Only a result row names a call")
    }
}
