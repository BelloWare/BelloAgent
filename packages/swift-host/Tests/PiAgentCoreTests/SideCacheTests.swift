import XCTest
@testable import PiAgentCore

/// Answers from a script and records each request as the Responses body the
/// provider would build for it, with the prompt cache it joins.
private actor CacheScriptClient: ModelClient {
    var replies: [ModelReply]
    var bodies: [JSON] = [], sessions: [String] = [], caches: [String] = [], contexts: [[ChatMessage]] = []
    init(_ replies: [ModelReply]) { self.replies = replies }
    var count: Int { bodies.count }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try await complete(profile: profile, apiKey: apiKey, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, cacheSessionID: sessionID, turnID: turnID, purpose: purpose, onObservation: { _ in }, onDelta: onDelta)
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        bodies.append(try ProviderClient.requestBody(profile: profile, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID, cacheSessionID: cacheSessionID, promptCaching: purpose != "compaction"))
        sessions.append(sessionID); caches.append(cacheSessionID); contexts.append(messages)
        guard !replies.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected model request") }
        let reply = replies.removeFirst()
        try await onDelta(.text(reply.message.text))
        return reply
    }
}

/// A reply calling the named tools with these arguments.
private func calling(_ calls: [(String, JSON)]) -> ModelReply {
    let calls = calls.enumerated().map { ToolCall(id: "call-\($0.offset)", name: $0.element.0, arguments: $0.element.1) }
    let message = ChatMessage(role: "assistant", content: calls.map { ["type": "toolCall", "id": JSON($0.id), "name": JSON($0.name), "arguments": $0.arguments] })
    return ModelReply(message: message, calls: calls, usage: ["input": 100, "output": 10])
}
private func names(_ body: JSON) -> [String] { body["tools"].list.compactMap { $0["name"].text } }
/// The user items of a Responses input, as their text.
private func userTexts(_ body: JSON) -> [String] {
    body["input"].list.filter { $0["role"].text == "user" }.map { $0["content"].list.compactMap { $0["text"].text }.joined() }
}
private let note = AgentSession.sideNote.text

/// Ours, not pi's: a side chat's requests extend its parent's, so they join
/// the parent's prompt cache (SessionSide.swift).
final class SideCacheTests: XCTestCase {
    private func tools(_ root: URL) -> NativeTools {
        NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
    }
    private func settle(_ session: AgentSession) async throws {
        try await eventually { !(await session.isRunning) }
    }
    /// An editing chat that has answered one question, and a side opened from it.
    private func parentAndSide(_ root: URL, parent parentClient: CacheScriptClient, side sideClient: CacheScriptClient, tools: NativeTools) async throws -> (AgentSession, AgentSession) {
        let directory = root.appendingPathComponent("state"), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let parent = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: parentClient, tools: tools, traces: traces, autoCompaction: false)
        _ = try await parent.submit(Submission(commandID: "p", turnID: "p", text: "Parent question"), steer: false)
        try await settle(parent)
        let seed = await parent.sideSeed()
        let side = try AgentSession(id: "side", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: sideClient, tools: tools, traces: traces, seed: seed.messages, parent: seed.info, autoCompaction: false)
        return (parent, side)
    }

    /// The owner's case, on the wire: a parent turn, then a side question.
    /// The side's first request is the parent's last one extended: the same
    /// tools, byte for byte, the same instructions and prompt cache key, and
    /// the parent's input items first. Only the correlation identity, the
    /// attempt log and the spend are the side's own.
    func testASidesFirstRequestExtendsItsParentsLastAndIsPaidForByTheSide() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("gateway.py")
        try Data(Self.gatewayScript.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { stopFixtureProcess(server) }
        let ready = root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: ready))["port"].int)
        var profile = try fixtureProfile().raw
        profile["baseUrl"] = JSON("http://127.0.0.1:\(port)")

        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path),
                                                                           "resources": ["codexHome": JSON(root.appendingPathComponent("codex").path)]])
        _ = try await host.command("session.open", sessionID: "parent", params: ["profile": profile, "apiKey": "synthetic-side-key", "toolMode": "editing"])
        _ = try await host.command("turn.submit", sessionID: "parent", params: ["clientTurnId": "parent-turn", "text": "Parent question"])
        let loaded = await host.loadedSession("parent"), parent = try XCTUnwrap(loaded); try await settle(parent)
        let opened = try await host.command("side.open", sessionID: "parent", params: ["sideSessionId": "side"])
        for (turn, text) in [("side-1", "Side question"), ("side-2", "Second side question")] {
            _ = try await host.command("turn.submit", sessionID: "side", params: ["clientTurnId": JSON(turn), "text": JSON(text)])
            let running = await host.loadedSession("side"); try await settle(try XCTUnwrap(running))
        }

        let log = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let requests = try log.split(separator: "\n").map { line -> (headers: JSON, raw: Data, body: JSON) in
            let record = try JSON.parse(Data(line.utf8)), raw = try XCTUnwrap(Data(base64Encoded: record["body"].text ?? ""))
            return (record["headers"], raw, try JSON.parse(raw))
        }
        let parentRequests = requests.filter { $0.headers["x-session-id"].text == "parent" }
        let sideRequests = requests.filter { $0.headers["x-session-id"].text == "side" }
        XCTAssertEqual(parentRequests.count, 1); XCTAssertEqual(sideRequests.count, 2)
        let last = try XCTUnwrap(parentRequests.last), first = try XCTUnwrap(sideRequests.first)
        func tools(_ raw: Data) throws -> Data {
            // Keys are sorted, so "tools" closes the body.
            let range = try XCTUnwrap(raw.range(of: Data("\"tools\":".utf8), options: .backwards))
            return raw.subdata(in: range.lowerBound..<raw.count)
        }
        XCTAssertEqual(try tools(first.raw), try tools(last.raw), "The side offers its parent's tools, byte for byte")
        XCTAssertEqual(names(first.body), ["read", "ls", "find", "grep", "write", "edit", "bash", "mcp"], "An editing parent's list, editing tools included")
        XCTAssertEqual(first.body["input"].list.first, last.body["input"].list.first, "The same instructions")
        XCTAssertEqual(first.body["prompt_cache_key"].text, "parent"); XCTAssertEqual(last.body["prompt_cache_key"].text, "parent")
        let prefix = last.body["input"].list
        XCTAssertEqual(Array(first.body["input"].list.prefix(prefix.count)), prefix, "The side's input starts with exactly the parent's last input")
        // Then the parent's reply, the hidden note, and the side's question.
        let added = Array(first.body["input"].list.dropFirst(prefix.count))
        XCTAssertEqual(added.count, 3)
        XCTAssertEqual(added.first?["role"].text, "assistant")
        XCTAssertEqual(added.dropFirst().map { $0["content"].list.compactMap { $0["text"].text }.joined() }, [note, "Side question"])
        XCTAssertEqual(Array(sideRequests[1].body["input"].list.prefix(first.body["input"].list.count)), first.body["input"].list, "Later side requests keep the prefix")
        XCTAssertEqual(userTexts(sideRequests[1].body).filter { $0 == note }.count, 1, "The note is sent once")
        for request in sideRequests {
            XCTAssertEqual(request.headers["session_id"].text, "parent"); XCTAssertEqual(request.headers["x-client-request-id"].text, "parent")
            XCTAssertEqual(request.headers["x-session-id"].text, "side"); XCTAssertEqual(request.body["metadata"]["session_id"].text, "side")
        }
        XCTAssertEqual(last.headers["session_id"].text, "parent"); XCTAssertEqual(last.body["metadata"]["session_id"].text, "parent")

        // The attempt log and the spend are the side's own.
        let sideAttempts = try await host.command("debug.list", sessionID: "side", params: [:])["attempts"].list
        let parentAttempts = try await host.command("debug.list", sessionID: "parent", params: [:])["attempts"].list
        XCTAssertEqual(sideAttempts.count, 2); XCTAssertEqual(parentAttempts.count, 1)
        XCTAssertTrue(sideAttempts.allSatisfy { $0["sessionId"].text == "side" })
        XCTAssertTrue(parentAttempts.allSatisfy { $0["sessionId"].text == "parent" })
        let sideCost = try await host.command("session.status", sessionID: "side", params: [:])["cost"]
        let parentCost = try await host.command("session.status", sessionID: "parent", params: [:])["cost"]
        XCTAssertEqual(sideCost["spentUSD"].double ?? 0, 0.0246, accuracy: 1e-9); XCTAssertEqual(sideCost["reportedRequests"].int, 2)
        XCTAssertEqual(parentCost["spentUSD"].double ?? 0, 0.0123, accuracy: 1e-9); XCTAssertEqual(parentCost["reportedRequests"].int, 1)
        func costRecords(_ path: String) throws -> [String] {
            try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
                .filter { $0["customType"].text == "pi-app.cost.v1" }.compactMap { $0["data"]["attemptId"].text }
        }
        let sideIDs = Set(sideAttempts.compactMap { $0["attemptId"].text }), journal = await parent.path, parentPath = try XCTUnwrap(journal)
        XCTAssertEqual(Set(try costRecords(try XCTUnwrap(opened["path"].text))), sideIDs, "The side's journal records its own attempts' cost")
        XCTAssertTrue(Set(try costRecords(parentPath)).isDisjoint(with: sideIDs), "and the parent's records none of them")
        await host.shutdown()
    }

    func testASideRefusesWriteEditAndBashWithoutRunningThem() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("before".utf8).write(to: root.appendingPathComponent("existing.txt"))
        let sideClient = CacheScriptClient([calling([("write", ["path": "written.txt", "content": "new"]),
                                                     ("edit", ["path": "existing.txt", "oldText": "before", "newText": "after"]),
                                                     ("bash", ["command": "touch ran.txt"])]), answer("I cannot change files here.")])
        let (parent, side) = try await parentAndSide(root, parent: CacheScriptClient([answer("Parent answer")]), side: sideClient, tools: tools(root))
        _ = try await side.submit(Submission(commandID: "s", turnID: "s", text: "Make the change"), steer: false)
        try await settle(side)
        let state = await side.snapshot(), results = await side.history.filter { $0.role == "toolResult" }
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        XCTAssertEqual(results.map(\.toolName), ["write", "edit", "bash"])
        for result in results {
            let name = try XCTUnwrap(result.toolName)
            XCTAssertEqual(result.text, "Side chats are read-only: \(name) is not available here. To make this change, ask in the main chat, or fork this side with /fork and choose Enable Editing Tools… in the new chat's menu.")
            XCTAssertTrue(result.isError); XCTAssertEqual(result.toolStats?["outcome"].text, "failed", "Refused, not an unknown outcome")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("written.txt").path), "Nothing is written")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("existing.txt"), encoding: .utf8), "before", "Nothing is edited")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran.txt").path), "Nothing is run")
        let bodies = await sideClient.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.allSatisfy { names($0) == ["read", "ls", "find", "grep", "write", "edit", "bash", "mcp"] }, "The parent's tools on every request")
        await side.close(); await parent.close()
    }

    func testTheSideNoteIsInTheSidesContextButNeverInItsRows() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sideClient = CacheScriptClient([answer("Side answer"), answer("Second side answer")])
        let (parent, side) = try await parentAndSide(root, parent: CacheScriptClient([answer("Parent answer")]), side: sideClient, tools: tools(root))
        for turn in ["q1", "q2"] {
            _ = try await side.submit(Submission(commandID: turn, turnID: turn, text: "Side " + turn), steer: false)
            try await settle(side)
        }
        let context = await side.context, bodies = await sideClient.bodies, caches = await sideClient.caches, sessions = await sideClient.sessions
        XCTAssertEqual(context.filter { $0.contextNote != nil }.map(\.id), ["q1"], "One note, carried by the side's first message")
        XCTAssertEqual(context.first(where: { $0.id == "q1" })?.contextNote, AgentSession.sideNote)
        XCTAssertEqual(userTexts(bodies[0]), ["Parent question", note, "Side q1"], "Sent as a user message of its own, after the inherited history")
        XCTAssertEqual(userTexts(bodies[1]), ["Parent question", note, "Side q1", "Side q2"])
        XCTAssertEqual(Array(bodies[1]["input"].list.prefix(bodies[0]["input"].list.count)), bodies[0]["input"].list)
        XCTAssertEqual(caches, ["parent", "parent"]); XCTAssertEqual(sessions, ["side", "side"])
        XCTAssertTrue(bodies.allSatisfy { $0["prompt_cache_key"].text == "parent" && $0["metadata"]["session_id"].text == "side" })
        let snapshot = await side.snapshot(), page = await side.historyPage(before: nil)
        XCTAssertFalse(snapshot["messages"].encoded().contains("side conversation"), "No transcript row shows the note")
        XCTAssertFalse(page["messages"].encoded().contains("side conversation"))
        XCTAssertEqual(snapshot["messages"].list.first(where: { $0["id"].text == "q1" })?["text"].text, "Side q1")
        // The context preview sends what delivery would: no second note.
        let preview = try await side.prepareContext(["text": "Draft"])
        let prepared = try await side.readPreparedContext(["revision": preview["revision"], "section": "request"])
        let request = try JSON.parse(Data(try XCTUnwrap(prepared["text"].text).utf8))
        XCTAssertEqual(userTexts(request).filter { $0 == note }.count, 1)

        // Kept and reopened, it is still in the context, still hidden.
        let saved = try await side.preserveSide(); await side.close()
        let reopenedClient = CacheScriptClient([answer("Third side answer")])
        let reopened = try AgentSession(id: "side", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: reopenedClient, tools: tools(root), traces: TraceStore(), resumePath: saved["path"].text, autoCompaction: false)
        let restored = await reopened.context
        XCTAssertEqual(restored.first(where: { $0.id == "q1" })?.contextNote, AgentSession.sideNote)
        let reopenedRows = await reopened.snapshot()["messages"].encoded()
        XCTAssertFalse(reopenedRows.contains("side conversation"))
        _ = try await reopened.submit(Submission(commandID: "q3", turnID: "q3", text: "Side q3"), steer: false)
        try await settle(reopened)
        let resumedBodies = await reopenedClient.bodies, resumed = try XCTUnwrap(resumedBodies.first)
        XCTAssertEqual(userTexts(resumed), ["Parent question", note, "Side q1", "Side q2", "Side q3"])
        XCTAssertEqual(resumed["prompt_cache_key"].text, "parent", "A kept side keeps its parent's cache")

        // A side opened from this side has a note of its own after what it inherits.
        let seed = await reopened.sideSeed(), nestedClient = CacheScriptClient([answer("Nested answer")])
        let nested = try AgentSession(id: "nested", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: nestedClient, tools: tools(root), traces: TraceStore(), seed: seed.messages, parent: seed.info, autoCompaction: false)
        _ = try await nested.submit(Submission(commandID: "n", turnID: "n", text: "Nested question"), steer: false)
        try await settle(nested)
        let nestedBodies = await nestedClient.bodies, nestedBody = try XCTUnwrap(nestedBodies.first)
        XCTAssertEqual(userTexts(nestedBody).filter { $0 == note }.count, 2)
        XCTAssertEqual(nestedBody["prompt_cache_key"].text, "parent", "It joins the cache its parent's requests joined")
        XCTAssertEqual(names(nestedBody), ["read", "ls", "find", "grep", "write", "edit", "bash", "mcp"])
        await nested.close(); await reopened.close(); await parent.close()
    }

    /// Pi's rule stays for a chat that is read-only itself: its tools are
    /// removed and it has its own cache. A fork of a side is such a chat,
    /// and the one way to make changes from a side: with its editing tools
    /// on, its next message says so, and its editing tools run.
    func testReadOnlyChatsKeepPisToolsAndAForkOfASideCanEdit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let mainClient = CacheScriptClient([answer("Read-only answer")])
        let main = try AgentSession(id: "main", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: mainClient, tools: tools(root), traces: TraceStore(), autoCompaction: false)
        _ = try await main.submit(Submission(commandID: "m", turnID: "m", text: "Question"), steer: false)
        try await settle(main)
        let mainBodies = await mainClient.bodies, mainBody = try XCTUnwrap(mainBodies.first)
        XCTAssertEqual(names(mainBody), ["read", "ls", "find", "grep", "mcp"]); XCTAssertEqual(mainBody["prompt_cache_key"].text, "main")
        XCTAssertEqual(userTexts(mainBody), ["Question"], "No note in a chat that is not a side")
        await main.close()

        let (parent, side) = try await parentAndSide(root, parent: CacheScriptClient([answer("Parent answer")]), side: CacheScriptClient([answer("Side answer")]), tools: tools(root))
        _ = try await side.submit(Submission(commandID: "s", turnID: "s", text: "Side question"), steer: false)
        try await settle(side)
        _ = try await side.preserveSide()
        let fork = try await side.fork(to: "fork"); await side.close()
        XCTAssertNil(fork["origin"]["cacheSessionId"].text); XCTAssertNil(fork["origin"]["parentToolMode"].text)
        let forkClient = CacheScriptClient([calling([("write", ["path": "forked.txt", "content": "made in the fork"])]), answer("Written.")])
        let editing = try AgentSession(id: "fork", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root), client: forkClient, tools: tools(root), traces: TraceStore(), resumePath: fork["path"].text, autoCompaction: false)
        _ = try await editing.submit(Submission(commandID: "f", turnID: "f", text: "Now write it"), steer: false)
        try await settle(editing)
        let bodies = await forkClient.bodies
        XCTAssertEqual(userTexts(bodies[0]), ["Parent question", note, "Side question", AgentSession.editingNote.text, "Now write it"])
        XCTAssertEqual(bodies[0]["prompt_cache_key"].text, "fork", "A fork has its own cache")
        XCTAssertEqual(names(bodies[0]), ["read", "ls", "find", "grep", "write", "edit", "bash", "mcp"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("forked.txt"), encoding: .utf8), "made in the fork")
        await editing.close(); await parent.close()
    }

    /// The system prompt no longer names the turn's skills, so it is the
    /// same on every request; each turn's message names its own selection,
    /// and a message that selects none says nothing of skills.
    func testTurnsWithDifferentSkillsSendTheSameInstructions() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta"] {
            let folder = root.appendingPathComponent(".codex/skills/\(name)"), agents = folder.appendingPathComponent("agents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: Fixture \(name)\n---\n\(name.uppercased()) SKILL BODY".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
        }
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let catalog = try await resources.resolve().skills
        XCTAssertEqual(catalog.map { $0["policy"].text }, ["explicitOnly", "explicitOnly"])
        func select(_ name: String) async throws -> [FrozenSkill] {
            var selection = try XCTUnwrap(catalog.first { $0["name"].text == name }); selection["intent"] = "picker"
            return try await resources.freeze([selection], text: "", tools: [])
        }
        let alpha = try await select("alpha"), beta = try await select("beta")
        let client = CacheScriptClient([answer("one"), answer("two"), answer("three")])
        let session = try AgentSession(id: "skills", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: resources, client: client, tools: tools(root), traces: TraceStore(), autoCompaction: false)
        for (turn, skills) in [("first", alpha), ("second", beta), ("third", [])] {
            _ = try await session.submit(Submission(commandID: turn, turnID: turn, text: turn + " request", skills: skills), steer: false)
            try await settle(session)
        }
        let bodies = await client.bodies
        XCTAssertEqual(bodies.count, 3)
        let instructions = bodies.map { $0["input"].list.first?["content"].text ?? "" }
        XCTAssertEqual(Set(instructions).count, 1, "Byte-identical instructions whatever the turn selected")
        XCTAssertTrue(instructions[0].hasSuffix("\n" + AgentSession.selectionPolicy))
        XCTAssertFalse(instructions[0].contains(alpha[0].id) || instructions[0].contains(beta[0].id))
        let latest = bodies.map { userTexts($0).last ?? "" }
        XCTAssertEqual(latest[0], alpha[0].expand(turnID: "first") + "\n\nCurrent explicit selection IDs: \(alpha[0].id)\n\nfirst request")
        XCTAssertEqual(latest[1], beta[0].expand(turnID: "second") + "\n\nCurrent explicit selection IDs: \(beta[0].id)\n\nsecond request")
        XCTAssertEqual(latest[2], "third request", "A message that selects no skill is its text alone")
        // An earlier selection stays in its own message, as history.
        XCTAssertEqual(userTexts(bodies[2]).filter { $0.contains("Current explicit selection IDs") }.count, 2)
        let rows = await session.snapshot()["messages"].list.filter { $0["role"].text == "user" }
        XCTAssertEqual(rows.map { $0["text"].text }, ["first request", "second request", "third request"], "Rows show what was typed")
        await session.close()
    }

    private static let gatewayScript = #"""
import base64, http.server, json, pathlib, sys, threading
root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
count = [0]
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with lock:
            count[0] += 1; n = count[0]
            with (root / 'requests.jsonl').open('a') as log:
                log.write(json.dumps({'headers': {k.lower(): v for k, v in self.headers.items()}, 'body': base64.b64encode(raw).decode()}) + '\n')
        body = json.loads(raw)
        response = json.dumps({'id': 'resp-%d' % n, 'object': 'response', 'status': 'completed', 'model': body['model'],
            'output': [{'id': 'msg-%d' % n, 'type': 'message', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'Answer %d' % n}]}],
            'usage': {'input_tokens': 100, 'output_tokens': 10, 'total_tokens': 110, 'cost': 0.0123}}, separators=(',', ':')).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response))); self.end_headers(); self.wfile.write(response)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_port})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#
}
