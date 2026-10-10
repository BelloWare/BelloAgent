import Foundation

// Swift 0.1.122's own session code writes journals for the Rust importer's
// tests, and replays them: the oracle. Compiled together with PiAgentCore's
// sources unchanged (one module, so its internal API is in reach).
//   oracle generate OUTDIR   journals of scripted chats, one per scenario
//   oracle dump JOURNAL ID   the journal replayed: its visible rows and context

func fixtureProfile() throws -> Profile {
    try Profile(["id":"oracle","revision":"1","providerId":"litellm","modelId":"oracle-model","api":"openai-responses","baseUrl":"http://127.0.0.1:12345/v1","contextWindow":100000,"maxOutputTokens":4096,"reasoning":true,"thinkingLevel":"default"])
}
func answer(_ text: String, thinking: String? = nil) -> ModelReply {
    var content: [JSON] = []
    if let thinking { content.append(["type":"thinking","thinking":JSON(thinking)]) }
    content.append(textBlock(text))
    return ModelReply(message: ChatMessage(role: "assistant", content: content), usage: ["input":100,"output":5,"inputIncludingCache":100], terminal: ModelTerminalOutcome(status: "completed"))
}
func toolReply(_ names: [String], text: String = "") -> ModelReply {
    let calls = names.enumerated().map { ToolCall(id: "call-\($0.offset)", name: $0.element, arguments: ["value": JSON($0.offset), "path": "src/main.rs"]) }
    var content: [JSON] = text.isEmpty ? [] : [textBlock(text)]
    content += calls.map { ["type":"toolCall","id":JSON($0.id),"name":JSON($0.name),"arguments":$0.arguments] }
    var message = ChatMessage(role: "assistant", content: content)
    message.providerItems = calls.map { ["type":"function_call","id":JSON("item-"+$0.id),"call_id":JSON($0.id),"name":JSON($0.name),"arguments":JSON($0.arguments.encoded())] }
    return ModelReply(message: message, calls: calls, usage: ["input":100,"output":10])
}
actor ScriptClient: ModelClient {
    var replies: [ModelReply], holdFirst: Bool, requests = 0
    init(_ replies: [ModelReply], holdFirst: Bool = false) { self.replies = replies; self.holdFirst = holdFirst }
    func release() { holdFirst = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let index = requests; requests += 1
        while index == 0 && holdFirst { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        guard index < replies.count else { throw AgentError("fixture_exhausted", "The scripted model has no reply") }
        try await onDelta(.text(replies[index].message.text))
        return replies[index]
    }
}
actor ScriptTools: ToolExecuting {
    var fail: Set<String>
    init(fail: Set<String> = []) { self.fail = fail }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "test", [:]), ToolDefinition("second", "test", [:]), ToolDefinition("read", "test", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        if fail.contains(call.name) { return resultText("failed " + call.name, error: true) }
        return resultText("done " + call.name + "\nline two")
    }
}
func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !(await predicate()) {
        guard Date() < deadline else { throw AgentError("oracle_timeout", "A scripted chat did not settle") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

struct Chat {
    let root: URL, state: URL, profile: Profile, resources: Resources, traces = TraceStore()
    func session(_ id: String, _ replies: [ModelReply], tools: any ToolExecuting = ScriptTools(), holdFirst: Bool = false) throws -> (AgentSession, ScriptClient) {
        var policy = CompactionPolicy(); policy.keepRecentTokens = 1
        let client = ScriptClient(replies, holdFirst: holdFirst)
        return (try AgentSession(id: id, profile: profile, apiKey: "oracle", cwd: root, directory: state, readOnly: false, resources: resources,
                                 client: client, tools: tools, traces: traces, autoCompaction: false, compactionPolicy: policy), client)
    }
}
func send(_ session: AgentSession, _ id: String, _ text: String, steer: Bool = false, wait: Bool = true) async throws {
    _ = try await session.submit(Submission(commandID: id, turnID: id, text: text), steer: steer)
    if wait { try await eventually { !(await session.isRunning) } }
}

func generate(_ out: URL) async throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-import-oracle-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = Chat(root: root, state: root.appendingPathComponent("state"), profile: try fixtureProfile(), resources: Resources(cwd: root, home: root))
    var made: [String] = []
    func keep(_ name: String, _ id: String, file: String? = nil) throws {
        let source = chat.state.appendingPathComponent(file ?? id + ".jsonl")
        let target = out.appendingPathComponent(name + ".jsonl")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        let meta: JSON = ["id": JSON(id), "cwd": JSON(chat.root.path)]
        try meta.data().write(to: out.appendingPathComponent(name + ".meta.json"))
        made.append(name)
    }
    // Plain turns, Markdown and reasoning.
    do {
        let (session, _) = try chat.session("plain", [answer("Hi **there**.\n\n- one\n- two"), answer("```swift\nlet a = 1\n```", thinking: "Considering the code."), answer("Third.")])
        try await send(session, "t1", "Hello")
        try await send(session, "t2", "Show code")
        try await send(session, "t3", "And **more**\nwith a second line")
        try keep("plain", "plain")
    }
    // A tool round: two calls, one failing, then the answer.
    do {
        let (session, _) = try chat.session("tools", [toolReply(["first", "second"], text: "Let me look."), toolReply(["read"]), answer("Done with tools.")], tools: ScriptTools(fail: ["second"]))
        try await send(session, "t1", "Use the tools")
        try await send(session, "t2", "Thanks")
        try keep("tools", "tools")
    }
    // Compaction between turns.
    do {
        let (session, _) = try chat.session("compaction", [answer(String(repeating: "First answer. ", count: 400)), answer(String(repeating: "Second answer. ", count: 400)), answer("## Summary\nThe user said hello twice."), answer("After compaction.")])
        try await send(session, "t1", "One")
        try await send(session, "t2", "Two")
        try await session.compact(commandID: "c1")
        try await eventually { !(await session.isRunning) }
        try await send(session, "t3", "Three")
        try keep("compaction", "compaction")
    }
    // A historical edit: the second question rewritten.
    do {
        let (session, _) = try chat.session("edit", [answer("Answer one."), answer("Answer two."), answer("Answer to the edit.")])
        try await send(session, "t1", "Question one")
        try await send(session, "t2", "Question two")
        let snapshot = await session.snapshot()
        let users = snapshot["messages"].list.filter { $0["role"].text == "user" }.compactMap { $0["id"].text }
        _ = try await session.edit(fromMessageID: users[1], input: Submission(commandID: "e1", turnID: "e1", text: "Question two, edited"))
        try await eventually { !(await session.isRunning) }
        try keep("edit", "edit")
    }
    // Steering while a reply runs.
    do {
        let (session, client) = try chat.session("steer", [answer("Working on it."), answer("Steered.")], holdFirst: true)
        try await send(session, "t1", "Start", wait: false)
        try await send(session, "s1", "Change course", steer: true, wait: false)
        await client.release()
        try await eventually { !(await session.isRunning) }
        try keep("steer", "steer")
    }
    // A request that fails: the turn ends in an error.
    do {
        let (session, _) = try chat.session("failure", [answer("Fine.")])
        try await send(session, "t1", "Works")
        try await send(session, "t2", "Fails")
        try keep("failure", "failure")
    }
    // A fork at the first reply.
    do {
        let (session, _) = try chat.session("forked", [answer("Reply one."), answer("Reply two.")])
        try await send(session, "t1", "First")
        try await send(session, "t2", "Second")
        let snapshot = await session.snapshot()
        let replies = snapshot["messages"].list.filter { $0["role"].text == "assistant" }.compactMap { $0["id"].text }
        _ = try await session.fork(to: "fork", at: replies[0])
        try keep("forked", "forked")
        try keep("fork", "fork", file: "fork_fork.jsonl")
    }
    func userIDs(_ session: AgentSession) async -> [String] {
        await session.snapshot()["messages"].list.filter { $0["role"].text == "user" }.compactMap { $0["id"].text }
    }
    let long = { (word: String) in answer(String(repeating: word + " ", count: 400)) }
    // An edit after a compaction: the edited turn follows the summary.
    do {
        let (session, _) = try chat.session("edit-after-compaction", [long("one"), long("two"), answer("## Summary\nTwo turns."), answer("Three."), answer("Three, edited.")])
        try await send(session, "t1", "One")
        try await send(session, "t2", "Two")
        try await session.compact(commandID: "c1")
        try await eventually { !(await session.isRunning) }
        try await send(session, "t3", "Three")
        let users = await userIDs(session)
        _ = try await session.edit(fromMessageID: users.last!, input: Submission(commandID: "e1", turnID: "e1", text: "Three, edited"))
        try await eventually { !(await session.isRunning) }
        try keep("edit-after-compaction", "edit-after-compaction")
    }
    // An edit of a turn the compaction summarized.
    do {
        let (session, _) = try chat.session("edit-before-compaction", [long("one"), long("two"), answer("## Summary\nTwo turns."), answer("Three."), answer("Two, edited.")])
        try await send(session, "t1", "One")
        try await send(session, "t2", "Two")
        try await session.compact(commandID: "c1")
        try await eventually { !(await session.isRunning) }
        try await send(session, "t3", "Three")
        _ = try await session.edit(fromMessageID: "t2", input: Submission(commandID: "e1", turnID: "e1", text: "Two, edited"))
        try await eventually { !(await session.isRunning) }
        try keep("edit-before-compaction", "edit-before-compaction")
    }
    // An edit after a tool round.
    do {
        let (session, _) = try chat.session("edit-after-tools", [toolReply(["first"]), answer("Tools done."), answer("Second."), answer("Second, edited.")])
        try await send(session, "t1", "Use a tool")
        try await send(session, "t2", "Second")
        _ = try await session.edit(fromMessageID: "t2", input: Submission(commandID: "e1", turnID: "e1", text: "Second, edited"))
        try await eventually { !(await session.isRunning) }
        try keep("edit-after-tools", "edit-after-tools")
    }
    // A side chat, kept.
    do {
        let (parent, _) = try chat.session("side-parent", [answer("Parent answer.")])
        try await send(parent, "t1", "Parent question")
        let seed = await parent.sideSeed()
        var policy = CompactionPolicy(); policy.keepRecentTokens = 1
        let side = try AgentSession(id: "side", profile: chat.profile, apiKey: "oracle", cwd: chat.root, directory: chat.state, readOnly: true, resources: chat.resources,
                                    client: ScriptClient([answer("Side answer.")]), tools: ScriptTools(), traces: chat.traces, seed: seed.messages, parent: seed.info,
                                    autoCompaction: false, compactionPolicy: policy)
        try await send(side, "s1", "Side question")
        _ = try await side.keep(whenFinished: false)
        try keep("side", "side", file: "side_side.jsonl")
    }
    // A run stopped while the model answers.
    do {
        let (session, client) = try chat.session("stopped", [answer("Never shown."), answer("After the stop.")], holdFirst: true)
        try await send(session, "t1", "Start", wait: false)
        try await eventually { await client.requests > 0 }
        await session.stop()
        try await eventually { !(await session.isRunning) }
        await client.release()
        try keep("stopped", "stopped")
    }
    // A chat moved to another connection.
    do {
        let (session, _) = try chat.session("rebound", [answer("Before the move.")])
        try await send(session, "t1", "First")
        await session.close()
        let url = chat.state.appendingPathComponent("rebound.jsonl")
        let other = try Profile(["id":"other","revision":"1","providerId":"litellm","modelId":"other-model","api":"openai-responses","baseUrl":"http://127.0.0.1:12346/v1","contextWindow":100000,"maxOutputTokens":4096,"reasoning":true,"thinkingLevel":"default"])
        do {
            let journal = try SessionJournal(url: url, id: "rebound", cwd: chat.root, binding: nil, create: false)
            try journal.rebind(to: other.binding)
        }
        try keep("rebound", "rebound")
    }
    let list: JSON = .array(made.map { JSON($0) })
    try list.data().write(to: out.appendingPathComponent("scenarios.json"))
    print("generated", made.joined(separator: " "))
}

/// A row as the importer must read it.
func row(_ m: ChatMessage) -> JSON {
    var value: JSON = ["id": JSON(m.id), "role": JSON(m.role), "text": JSON(m.text), "thinking": JSON(m.thinking), "isError": JSON(m.isError), "replayEligible": JSON(m.replayEligible)]
    let calls = m.content.filter { $0["type"].text == "toolCall" }.map { ["id": $0["id"], "name": $0["name"], "arguments": $0["arguments"]] as JSON }
    if !calls.isEmpty { value["toolCalls"] = .array(calls) }
    if let kind = m.kind { value["kind"] = JSON(kind) }
    if let id = m.toolCallId { value["toolCallId"] = JSON(id) }
    if let name = m.toolName { value["toolName"] = JSON(name) }
    if let text = m.displayText { value["displayText"] = JSON(text) }
    if let input = m.userInput { value["userInput"] = input }
    if let reason = m.stopReason { value["stopReason"] = JSON(reason) }
    if let detail = m.detail { value["detail"] = JSON(detail) }
    if let turn = m.turn { value["turn"] = JSON(turn) }
    if let root = m.taskRootID { value["taskRoot"] = JSON(root) }
    if let lane = m.inputLane { value["inputLane"] = JSON(lane) }
    if let items = m.providerItems { value["providerItems"] = .array(items) }
    if let usage = m.usage { value["usage"] = usage }
    if let stats = m.toolStats { value["toolStats"] = stats }
    if let compaction = m.compaction { value["compaction"] = compaction }
    if let timestamp = m.timestamp { value["timestamp"] = JSON(timestamp) }
    return value
}

func dump(_ path: String, _ id: String, _ cwd: String) throws {
    let copyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("swift-import-dump-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: copyRoot) }
    let copy = copyRoot.appendingPathComponent("copy.jsonl")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
    let journal = try SessionJournal(url: copy, id: id, cwd: URL(fileURLWithPath: cwd), binding: nil, create: false)
    let replay = try AgentSession.replay(journal, url: copy, id: id, binding: journal.binding ?? .null, spendTracked: false, resume: false)
    let out: JSON = ["visible": .array(replay.visible.map(row)), "context": .array(replay.context.map { JSON($0.id) }),
                     "state": replay.stateRecord ?? .null, "parent": replay.parentInfo]
    FileHandle.standardOutput.write(try out.data())
}

let arguments = CommandLine.arguments
do {
    switch arguments.dropFirst().first {
    case "generate": try await generate(URL(fileURLWithPath: arguments[2]))
    case "dump": try dump(arguments[2], arguments[3], arguments[4])
    default: print("usage: oracle generate OUTDIR | oracle dump JOURNAL ID CWD"); exit(2)
    }
} catch { FileHandle.standardError.write(Data("oracle: \(error)\n".utf8)); exit(1) }
