import XCTest
@testable import PiAgentCore

/// Reasoning is sent back, also after a model switch; a provider that refuses
/// it is the owner's question (owner, 2026-11-11: "encrypted reasoning should
/// be not ignored… unless it got rejected by litellm due to model switch,
/// which then we need user confirmation to proceed with previous encrypted
/// reasoning removed or something like that, while keep new encrypted
/// reasoning"). Through the real client and a loopback gateway that answers
/// as a LiteLLM 1.108.0 gateway does: each model's provider reads only the
/// reasoning it made and refuses another's, with the texts of the probes.
final class ReasoningQuestionTests: HelperTestCase {
    static let organization = "The encrypted content for item rs_fixture-model_1 could not be verified. Reason: Encrypted content organization_id did not match the target organization."
    /// `sys.argv[2]`: `http` refuses with HTTP 400 and LiteLLM's wrapped body,
    /// `sse` with HTTP 200 and a `response.failed` event (its Gemini bridge),
    /// `always` refuses every request of another model whatever it carries,
    /// `strict` refuses the other model any earlier reasoning, its own too.
    static let gatewayScript = #"""
import http.server, json, pathlib, sys
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
ORG = "The encrypted content for item rs_fixture-model_1 could not be verified. Reason: Encrypted content organization_id did not match the target organization."
HELP = "\n\n This error occurs when load balancing Responses API across deployments with different API keys.\n   Encrypted content is tied to the organization that created it and cannot be decrypted by other organizations.\n\n   Solution: Enable 'encrypted_content_affinity' to route follow-up requests to the correct deployment"
count = {'n': 0}
def refusal(body):
    model, made = body['model'], set()
    if mode == 'always' and model != 'fixture-model': return ORG
    if mode == 'strict':
        # The first model's provider takes whatever comes; the other's takes no earlier reasoning at all, its own included.
        return ORG if model != 'fixture-model' and any(entry.get('type') == 'reasoning' for entry in body['input']) else None
    for entry in body['input']:
        kind = entry.get('type')
        if kind == 'reasoning':
            made.add(entry.get('id'))
            if entry.get('encrypted_content') != 'ENC-' + model: return ORG
        # OpenAI: a call that keeps its item id needs the reasoning item it came with.
        if kind == 'function_call' and entry.get('id', '').startswith('fc_') and 'rs_' + entry['id'][3:] not in made:
            return "Item '%s' of type 'function_call' was provided without its required 'reasoning' item: 'rs_%s'." % (entry['id'], entry['id'][3:])
    return None
def text_of(entry):
    content = entry.get('content')
    return content if isinstance(content, str) else ''.join(part.get('text', '') for part in content or [])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, status, kind, payload):
        self.send_response(status); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); self.wfile.flush()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        with (root / 'requests.jsonl').open('a') as log: log.write(json.dumps(body) + '\n')
        model, refused = body['model'], refusal(body)
        if refused and mode == 'sse':
            wrapped = "litellm.BadRequestError: Vertex_ai_betaException BadRequestError - b'{\"error\": {\"code\": 400, \"message\": \"Corrupted thought signature.\", \"status\": \"INVALID_ARGUMENT\"}}'"
            failed = {'type': 'response.failed', 'response': {'id': 'resp_f', 'created_at': 1, 'error': {'code': 'invalid_request_error', 'message': wrapped}, 'object': 'response', 'output': [], 'status': 'failed'}, 'sequence_number': 0}
            return self.send(200, 'text/event-stream', b'event: response.failed\ndata: ' + json.dumps(failed).encode() + b'\n\ndata: [DONE]\n\n')
        if refused:
            inner = json.dumps({'error': {'message': refused, 'type': 'invalid_request_error', 'param': None, 'code': 'invalid_encrypted_content'}})
            return self.send(400, 'application/json', json.dumps({'error': {'message': 'litellm.BadRequestError: OpenAIException - ' + inner + HELP, 'type': 'invalid_request_error', 'param': None, 'code': '400'}}).encode())
        count['n'] += 1; n = count['n']
        last = body['input'][-1]
        said = text_of(last) if last.get('role') == 'user' else ''
        tag = '%s_%d' % (model, n)
        reasoning = {'type': 'reasoning', 'id': 'rs_' + tag, 'summary': [], 'encrypted_content': 'ENC-' + model}
        if 'continuation checkpoint' in said:
            output = [{'type': 'message', 'id': 'msg_' + tag, 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'SUMMARY of the earlier work.', 'annotations': []}]}]
        elif 'tool' in said:
            output = [reasoning, {'type': 'function_call', 'id': 'fc_' + tag, 'call_id': 'call_' + tag, 'name': 'first', 'status': 'completed', 'arguments': '{}'}]
        else:
            output = [reasoning, {'type': 'message', 'id': 'msg_' + tag, 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'Answer %d.' % n, 'annotations': []}]}]
        size = len(json.dumps(body['input'])) // 4
        usage = {'input_tokens': size, 'output_tokens': 10, 'total_tokens': size + 10}
        frames = [{'type': 'response.created', 'response': {'id': 'r' + str(n), 'status': 'in_progress', 'output': []}}]
        for index, entry in enumerate(output):
            frames += [{'type': 'response.output_item.added', 'output_index': index, 'item': entry}, {'type': 'response.output_item.done', 'output_index': index, 'item': entry}]
        frames.append({'type': 'response.completed', 'response': {'id': 'r' + str(n), 'status': 'completed', 'model': model, 'output': output, 'usage': usage}})
        self.send(200, 'text/event-stream', b''.join(b'event: ' + f['type'].encode() + b'\ndata: ' + json.dumps(f).encode() + b'\n\n' for f in frames))
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    private struct Chat {
        let root: URL, gateway: PythonGateway, profile: Profile
        func open(_ id: String = "reasoning", resume path: String? = nil, auto: Bool = false) throws -> (AgentSession, RecordingTools) {
            let traces = TraceStore(), tools = RecordingTools()
            return (try AgentSession(id: id, profile: profile, apiKey: "sk-loopback-0000", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                     resources: Resources(cwd: root, home: root), client: ProviderClient(traces: traces), tools: tools, traces: traces, resumePath: path, autoCompaction: auto), tools)
        }
        func requests() throws -> [JSON] {
            let file = root.appendingPathComponent("requests.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        }
    }
    private func chat(_ mode: String, window: Int = 100_000) async throws -> Chat {
        let root = try temporaryDirectory()
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root, arguments: [mode])
        addTeardownBlock { gateway.stop(); try? FileManager.default.removeItem(at: root) }
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(gateway.port)/v1"); raw["contextWindow"] = JSON(window)
        return Chat(root: root, gateway: gateway, profile: try Profile(raw))
    }
    private func send(_ session: AgentSession, _ id: String, _ text: String, model: String? = nil) async throws {
        _ = try await session.submit(Submission(commandID: id, turnID: id, text: text, model: model), steer: false)
        try await eventually(timeout: .seconds(30)) { !(await session.isRunning) }
    }
    private func retry(_ session: AgentSession, _ overrides: JSON) async throws {
        try await session.retryRun(overrides: overrides)
        try await eventually(timeout: .seconds(30)) { !(await session.isRunning) }
    }
    private func status(_ session: AgentSession) async -> JSON { await session.snapshot(["includeMessages": false]) }
    /// The encrypted reasoning a request carries, by the model that made it.
    private func reasoning(_ request: JSON) -> [String] { request["input"].list.filter { $0["type"].text == "reasoning" }.compactMap { $0["encrypted_content"].text } }
    private func calls(_ request: JSON) -> [JSON] { request["input"].list.filter { $0["type"].text == "function_call" } }

    /// The whole of it over HTTP 400: sent after a switch, refused, asked,
    /// asked again after a relaunch, continued without the earlier reasoning
    /// and with the later, for good.
    func testARefusalAfterAModelSwitchIsAskedAboutAndContinueLeavesTheEarlierReasoningOut() async throws {
        let chat = try await chat("http")
        var (session, tools) = try chat.open()
        try await send(session, "a", "Use the tool")
        var sent = try chat.requests()
        var state = await status(session)
        guard sent.count == 2 else { await session.close(); return XCTFail("The first turn made \(sent.count) of its 2 requests: \(state["preflightError"].encoded())") }
        XCTAssertEqual(reasoning(sent[1]), ["ENC-fixture-model"], "The same model gets its reasoning back between tool rounds")
        XCTAssertEqual(calls(sent[1]).map { $0["id"].text }, ["fc_fixture-model_1"])

        // Another model: the reasoning goes with the request, and its provider refuses it.
        try await send(session, "b", "Next", model: "other-model")
        sent = try chat.requests()
        guard sent.count == 3 else { await session.close(); return XCTFail("The switched turn made \(sent.count - 2) requests, not 1") }
        XCTAssertEqual(sent[2]["model"].text, "other-model")
        XCTAssertEqual(reasoning(sent[2]), ["ENC-fixture-model", "ENC-fixture-model"], "Reasoning is not left out after a model switch")
        XCTAssertEqual(sent[2]["input"].list.first { $0["type"].text == "reasoning" }, ["type": "reasoning", "id": "rs_fixture-model_1", "summary": [], "encrypted_content": "ENC-fixture-model"], "As it was received")
        state = await status(session)
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "reasoning_rejected")
        let question = state["reasoningRejection"]
        let asked = try XCTUnwrap(question["id"].text, state.encoded())
        XCTAssertEqual(question["rule"].text, "organization"); XCTAssertEqual(question["routeChanged"].flag, true); XCTAssertEqual(question["purpose"].text, "turn")
        XCTAssertEqual(question["sentence"].text, Self.organization, "The provider's own sentence")
        // The notice's words: what happened, whose reasoning, what is still sent, and the way back.
        XCTAssertEqual(question["title"].text, "other-model can't use the earlier reasoning")
        XCTAssertEqual(question["body"].text, "Its provider refused the hidden reasoning saved from earlier replies by fixture-model. Your messages, the replies and the tool results are all still sent.")
        XCTAssertEqual(question["hint"].text, "Switching back to fixture-model keeps its reasoning."); XCTAssertEqual(question["ownReasoning"].flag, false)
        XCTAssertEqual(state["preflightError"].text, "other-model can't use the earlier reasoning\nIts provider refused the hidden reasoning saved from earlier replies by fixture-model. Your messages, the replies and the tool results are all still sent.\n\nProvider's message: " + Self.organization)
        XCTAssertTrue(question["replies"].isNull, "Reply ids are the helper's own")
        XCTAssertEqual(try chat.requests().count, 3, "Nothing is retried before the owner answers")
        let ran = await tools.calls
        XCTAssertEqual(ran, ["first"])

        // A relaunch asks the same question.
        let saved = await session.path
        let path = try XCTUnwrap(saved)
        await session.close()
        (session, tools) = try chat.open(resume: path)
        state = await status(session)
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected"); XCTAssertEqual(state["reasoningRejection"]["id"].text, asked)
        XCTAssertEqual(state["reasoningRejection"]["sentence"].text, Self.organization)

        // An answer to another question changes nothing.
        do { try await session.retryRun(overrides: ["model": "other-model", "withoutEarlierReasoning": ["rejection": "another"]]); XCTFail("A stale answer was taken") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "reasoning_confirmation_stale") }
        XCTAssertEqual(try chat.requests().count, 3)

        // Continue: the request goes once more, without the earlier reasoning.
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        sent = try chat.requests()
        state = await status(session)
        guard sent.count == 4 else { await session.close(); return XCTFail("Continue made \(sent.count - 3) requests, not 1: \(state.encoded())") }
        XCTAssertEqual(reasoning(sent[3]), [], "The earlier reasoning is left out")
        XCTAssertEqual(calls(sent[3]).map { $0["id"] }, [.null], "and so is the item id that names it: OpenAI refuses a call 'without its required reasoning item'")
        XCTAssertEqual(calls(sent[3]).map { $0["call_id"].text }, ["call_fixture-model_1"]); XCTAssertEqual(sent[3]["input"].list.filter { $0["type"].text == "function_call_output" }.map { $0["call_id"].text }, ["call_fixture-model_1"])
        state = await status(session)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded()); XCTAssertTrue(state["reasoningRejection"].isNull)
        let rerun = await tools.calls
        XCTAssertEqual(rerun, [], "No tool ran again")
        let journal = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(journal.contains("pi-app.reasoning-withheld.v1"), "The answer is in the journal")
        XCTAssertTrue(journal.contains("ENC-fixture-model"), "and the chat's history is not rewritten")
        let lines = await session.history.filter { $0.kind == "notice" }.map(\.displayText)
        XCTAssertEqual(lines, ["Continued without earlier reasoning · other-model"], "One quiet line where the notice was")

        // Reasoning made from here on is kept and sent; the earlier stays out.
        try await send(session, "c", "More", model: "other-model")
        sent = try chat.requests()
        guard sent.count == 5 else { await session.close(); return XCTFail("The next turn made \(sent.count - 4) requests") }
        XCTAssertEqual(reasoning(sent[4]), ["ENC-other-model"])

        // After another relaunch too.
        await session.close()
        (session, tools) = try chat.open(resume: path)
        try await send(session, "d", "Again", model: "other-model")
        sent = try chat.requests()
        guard sent.count == 6 else { await session.close(); return XCTFail("The reopened chat made \(sent.count - 5) requests") }
        XCTAssertEqual(reasoning(sent[5]), ["ENC-other-model", "ENC-other-model"])

        // Back on the first model, which never refused: it gets everything,
        // its own reasoning with it. What the other model made since is this
        // provider's to refuse, and that is a new question.
        try await send(session, "e", "Back")
        sent = try chat.requests()
        guard sent.count == 7 else { await session.close(); return XCTFail("The turn back made \(sent.count - 6) requests") }
        XCTAssertEqual(reasoning(sent[6]), ["ENC-fixture-model", "ENC-fixture-model", "ENC-other-model", "ENC-other-model", "ENC-other-model"], "The answer was for the model that refused")
        state = await status(session)
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected")
        let again = try XCTUnwrap(state["reasoningRejection"]["id"].text)
        XCTAssertNotEqual(again, asked, "A new refusal is a new question")
        // What goes is the other model's reasoning. This model keeps its own.
        XCTAssertEqual(state["reasoningRejection"]["ownReasoning"].flag, false); XCTAssertEqual(state["reasoningRejection"]["model"].text, "fixture-model")
        XCTAssertEqual(state["reasoningRejection"]["title"].text, "fixture-model can't use the earlier reasoning")
        XCTAssertTrue(state["reasoningRejection"]["body"].text?.contains("saved from earlier replies by other-model.") == true, state["reasoningRejection"].encoded())
        try await retry(session, ["withoutEarlierReasoning": ["rejection": JSON(again)]])
        sent = try chat.requests(); state = await status(session)
        guard sent.count == 8 else { await session.close(); return XCTFail("\(sent.count - 7) requests after the second Continue: \(state.encoded())") }
        XCTAssertEqual(reasoning(sent[7]), ["ENC-fixture-model", "ENC-fixture-model"]); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        // A third refusal is left standing for the export below.
        try await send(session, "f", "Once more", model: "other-model")
        state = await status(session)
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected", state.encoded())
        await session.close()
        try export(chat, journal: path)
    }

    /// For `scripts/older-reader-check.sh`: with `PI_REASONING_COMPAT_OUT`
    /// set, the chat's journal, its checkpoint and its connection are left
    /// there for an earlier release's helper to open
    /// (`fixtures/native/older-reader/OlderReaderTests.swift`).
    private func export(_ chat: Chat, journal: String) throws {
        guard let out = ProcessInfo.processInfo.environment["PI_REASONING_COMPAT_OUT"], !out.isEmpty else { return }
        let target = URL(fileURLWithPath: out), state = chat.root.appendingPathComponent("state")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: state, to: target.appendingPathComponent("state"))
        let relative = String(URL(fileURLWithPath: journal).standardizedFileURL.path.dropFirst(state.standardizedFileURL.path.count + 1))
        try JSON.object(["journal": JSON(relative), "profile": chat.profile.raw]).data().write(to: target.appendingPathComponent("export.json"))
    }

    /// The same over HTTP 200 and a failure event, and Stop: nothing changes,
    /// and a plain Retry of the request is refused and asked about again.
    func testARefusalInsideAStreamIsAskedAboutAndStopChangesNothing() async throws {
        let chat = try await chat("sse")
        let (session, _) = try chat.open()
        try await send(session, "a", "Use the tool")
        try await send(session, "b", "Next", model: "other-model")
        var state = await status(session)
        XCTAssertEqual(try chat.requests().count, 3)
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected", state.encoded())
        XCTAssertEqual(state["reasoningRejection"]["rule"].text, "thoughtSignature"); XCTAssertEqual(state["reasoningRejection"]["routeChanged"].flag, false)
        XCTAssertEqual(state["reasoningRejection"]["sentence"].text, "Corrupted thought signature.")
        let first = try XCTUnwrap(state["reasoningRejection"]["id"].text)
        // Stop is the turn as it stands: stopped, with the provider's error.
        XCTAssertTrue(state["preflightError"].text?.hasSuffix("Provider's message: Corrupted thought signature.") == true)
        try await retry(session, ["model": "other-model"])
        let sent = try chat.requests()
        XCTAssertEqual(sent.count, 4); XCTAssertEqual(reasoning(sent[3]), ["ENC-fixture-model", "ENC-fixture-model"], "Retry sends what was sent")
        state = await status(session)
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected")
        let second = try XCTUnwrap(state["reasoningRejection"]["id"].text)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(state["reasoningRejection"]["ownReasoning"].flag, false, "The reasoning refused is another model's")
        XCTAssertEqual(state["reasoningRejection"]["hint"].text, "Switching back to fixture-model keeps its reasoning.")

        // Continue is the refusing model's: it goes on without the other
        // model's earlier reasoning.
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(second)]])
        var all = try chat.requests()
        XCTAssertEqual(all.count, 5); XCTAssertEqual(reasoning(all[4]), [])
        // The model that made that reasoning never refused it and still gets
        // it: switching back recovers the chat. It refuses the other model's
        // (a new question), and after Continue keeps what it wrote itself.
        try await send(session, "c", "Back")
        all = try chat.requests(); state = await status(session)
        guard all.count == 6 else { await session.close(); return XCTFail("\(all.count - 5) requests on the way back: \(state.encoded())") }
        XCTAssertEqual(reasoning(all[5]), ["ENC-fixture-model", "ENC-fixture-model", "ENC-other-model"])
        let third = try XCTUnwrap(state["reasoningRejection"]["id"].text, state.encoded())
        XCTAssertEqual(state["reasoningRejection"]["ownReasoning"].flag, false)
        try await retry(session, ["withoutEarlierReasoning": ["rejection": JSON(third)]])
        all = try chat.requests(); state = await status(session)
        guard all.count == 7 else { await session.close(); return XCTFail("\(all.count - 6) requests after Continue: \(state.encoded())") }
        XCTAssertEqual(reasoning(all[6]), ["ENC-fixture-model", "ENC-fixture-model"], "A model keeps getting the reasoning it wrote itself")
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        // What was made after an answer is sent to the model that gave it,
        // whoever wrote it. Refused, it is asked about: never left out unasked.
        try await send(session, "d", "And again", model: "other-model")
        all = try chat.requests(); state = await status(session)
        guard all.count == 8 else { await session.close(); return XCTFail("\(all.count - 7) requests on the other model again: \(state.encoded())") }
        XCTAssertEqual(reasoning(all[7]), ["ENC-other-model", "ENC-fixture-model"]); XCTAssertEqual(state["errorCode"].text, "reasoning_rejected")
        await session.close()
    }

    /// One question for a refusal, never a second: Continue means the model
    /// goes on without whatever earlier reasoning its provider refuses. The
    /// request goes again without the others'; refused again, once more
    /// without the model's own, with no new question; and each step is in
    /// the journal with what it left out.
    func testContinueCoversTheModelsOwnReasoningWhenTheRetryIsRefusedToo() async throws {
        let chat = try await chat("strict")
        let (session, _) = try chat.open()
        try await send(session, "a", "Use the tool")
        try await send(session, "b", "Next", model: "other-model")
        var state = await status(session)
        var asked = try XCTUnwrap(state["reasoningRejection"]["id"].text, state.encoded())
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        try await send(session, "c", "Back")
        state = await status(session)
        XCTAssertEqual(try chat.requests().count, 5); XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        // The other model again: its request carries its own earlier
        // reasoning and what the first model made since.
        try await send(session, "d", "And again", model: "other-model")
        var sent = try chat.requests(); state = await status(session)
        guard sent.count == 6 else { await session.close(); return XCTFail("\(sent.count - 5) requests: \(state.encoded())") }
        XCTAssertEqual(reasoning(sent[5]), ["ENC-other-model", "ENC-fixture-model"])
        XCTAssertEqual(state["reasoningRejection"]["ownReasoning"].flag, false)
        asked = try XCTUnwrap(state["reasoningRejection"]["id"].text)
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        sent = try chat.requests(); state = await status(session)
        guard sent.count == 8 else { await session.close(); return XCTFail("\(sent.count - 6) requests after Continue: \(state.encoded())") }
        XCTAssertEqual(reasoning(sent[6]), ["ENC-other-model"], "First without the others': its own stays in")
        XCTAssertEqual(reasoning(sent[7]), [], "Refused again: once more without its own, and no second question")
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded()); XCTAssertTrue(state["reasoningRejection"].isNull)
        let lines = await session.history.filter { $0.kind == "notice" }.map(\.displayText)
        XCTAssertEqual(lines, ["Continued without earlier reasoning · other-model", "Continued without earlier reasoning · other-model", "Continued without its own earlier reasoning too · other-model"],
                       "The first answer's line, then this one's and what its second step added")
        let saved = await session.path
        let records = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(saved)), encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
            .filter { $0["customType"].text == "pi-app.reasoning-withheld.v1" }.map { $0["data"] }
        XCTAssertEqual(records.map { $0["own"].flag }, [false, false, true], "What each step left out")
        XCTAssertEqual(records.suffix(2).map { $0["rejection"].text }, [asked, asked], "The second step belongs to the same answer")
        await session.close()
    }

    /// A manual compaction of an idle chat that is refused has no request to
    /// send again: it is that compaction's failure, and no question is asked.
    /// And an answer given in a side chat that has no journal yet is in the
    /// journal it gets when it is kept.
    func testAnIdleCompactionIsNotAskedAboutAndAKeptSideCarriesItsAnswer() async throws {
        let chat = try await chat("http")
        let (session, _) = try chat.open()
        // An earlier exchange large enough to be worth a summary.
        try await send(session, "a", "Use the tool. " + String(repeating: "evidence ", count: 5_000))
        try await send(session, "b", "Next", model: "other-model")
        var state = await status(session)
        let asked = try XCTUnwrap(state["reasoningRejection"]["id"].text, state.encoded())
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        XCTAssertEqual(try chat.requests().count, 4)
        // The first model summarizes: its request carries the other's reasoning, which its provider refuses.
        _ = try? await session.compact(commandID: "compact")
        try await eventually(timeout: .seconds(30)) { !(await session.isRunning) }
        state = await status(session)
        let sent = try chat.requests()
        guard sent.count == 5 else { await session.close(); return XCTFail("The compaction sent \(sent.count - 4) requests: \(state["compaction"].encoded())") }
        XCTAssertEqual(reasoning(sent[4]), ["ENC-fixture-model", "ENC-fixture-model", "ENC-other-model"])
        XCTAssertNotEqual(state["errorCode"].text, "reasoning_rejected", state.encoded()); XCTAssertTrue(state["reasoningRejection"].isNull)
        XCTAssertEqual(state["compaction"]["errorCode"].text, "provider_http", state["compaction"].encoded())

        // A side chat started from here, not saved: it inherits the answer,
        // and one of its own is held in memory until it is kept.
        let seed = await session.sideSeed()
        let traces = TraceStore()
        let side = try AgentSession(id: "side", profile: chat.profile, apiKey: "sk-loopback-0000", cwd: chat.root, directory: chat.root.appendingPathComponent("state"), readOnly: true,
                                    resources: Resources(cwd: chat.root, home: chat.root), client: ProviderClient(traces: traces), tools: RecordingTools(), traces: traces,
                                    seed: seed.messages, parent: seed.info, autoCompaction: false)
        try await send(side, "s", "On the side")
        state = await status(side)
        let own = try XCTUnwrap(state["reasoningRejection"]["id"].text, "The first model refuses the other's reasoning here too: \(state.encoded())")
        try await retry(side, ["withoutEarlierReasoning": ["rejection": JSON(own)]])
        state = await status(side)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        let kept = try await side.preserveSide()
        let path = try XCTUnwrap(kept["path"].text, kept.encoded())
        await side.close()
        let journal = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(journal.contains("pi-app.reasoning-withheld.v1"), "The side's journal carries the answer given before it had one")
        let (reopened, _) = try chat.open("side", resume: path)
        try await send(reopened, "t", "After reopening")
        let after = try chat.requests(), final = await status(reopened)
        XCTAssertEqual(reasoning(try XCTUnwrap(after.last)), ["ENC-fixture-model", "ENC-fixture-model", "ENC-fixture-model"], "Its own, and nothing it agreed to leave out")
        XCTAssertEqual(final["state"].text, "idle", final["preflightError"].encoded())
        await reopened.close(); await session.close()
    }

    /// A model chosen while the question waits gets a question of its own:
    /// the answer, and its one retry, belong to the model that refused.
    func testAModelChosenWhileTheQuestionWaitsIsAskedForItself() async throws {
        let chat = try await chat("http")
        let (session, _) = try chat.open()
        try await send(session, "a", "Use the tool")
        try await send(session, "b", "Next", model: "other-model")
        var state = await status(session)
        let asked = try XCTUnwrap(state["reasoningRejection"]["id"].text, state.encoded())
        XCTAssertEqual(state["reasoningRejection"]["model"].text, "other-model")
        // Continue, with the chat's model changed in the meantime.
        try await retry(session, ["model": "third-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        let sent = try chat.requests(); state = await status(session)
        guard sent.count == 4 else { await session.close(); return XCTFail("\(sent.count - 3) requests after Continue: \(state.encoded())") }
        XCTAssertEqual(sent[3]["model"].text, "third-model")
        XCTAssertEqual(reasoning(sent[3]), ["ENC-fixture-model", "ENC-fixture-model"], "The answer was the other model's: this one never refused")
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected", "Its refusal is a question, not the ordinary failure of a second refusal")
        XCTAssertEqual(state["reasoningRejection"]["model"].text, "third-model"); XCTAssertEqual(state["reasoningRejection"]["title"].text, "third-model can't use the earlier reasoning")
        await session.close()
    }

    /// One retry: a refusal of the request the owner's Continue paid for,
    /// with no reasoning left in it, is the run's failure. It asks nothing
    /// and is not retried as a transient error.
    func testARefusalOfTheContinuedRequestIsAnOrdinaryFailure() async throws {
        let chat = try await chat("always")
        let (session, _) = try chat.open()
        try await send(session, "a", "Use the tool")
        try await send(session, "b", "Next", model: "other-model")
        var state = await status(session)
        let asked = try XCTUnwrap(state["reasoningRejection"]["id"].text, state.encoded())
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        state = await status(session)
        XCTAssertEqual(try chat.requests().count, 4, "Sent once, and not again")
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "provider_http"); XCTAssertTrue(state["reasoningRejection"].isNull)
        // The same answer twice is refused: the question no longer stands.
        do { try await session.retryRun(overrides: ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]]); XCTFail("A repeated answer was taken") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "reasoning_confirmation_stale") }
        await session.close()
    }

    /// A summary request replays the same replies. Refused for their
    /// reasoning, it is the same question, not a summary paid for and wasted:
    /// the task's automatic compaction is not written off, and after Continue
    /// the summary is made and the turn goes on.
    func testASummaryRequestRefusedForItsReasoningAsksAndThenCompacts() async throws {
        let chat = try await chat("http", window: 60_000)
        let (session, _) = try chat.open(auto: true)
        // An earlier task large enough that the chat compacts before a later
        // task starts, and a short exchange after it, which stays.
        try await send(session, "a", "Note this. " + String(repeating: "evidence ", count: 14_000))
        try await send(session, "b", "Use the tool")
        var sent = try chat.requests(), state = await status(session)
        guard sent.count == 3, state["state"].text == "idle" else { await session.close(); return XCTFail("\(sent.count) requests before the switch: \(state.encoded())") }
        // The switched task starts by compacting: that request is the first to be refused.
        try await send(session, "c", "Next", model: "other-model")
        sent = try chat.requests(); state = await status(session)
        guard sent.count == 4 else { await session.close(); return XCTFail("\(sent.count - 3) requests after the switch: \(state.encoded())") }
        XCTAssertTrue(sent[3]["input"].list.last?.encoded().contains("continuation checkpoint") == true, "The summary request")
        XCTAssertEqual(state["errorCode"].text, "reasoning_rejected", state.encoded()); XCTAssertEqual(state["reasoningRejection"]["purpose"].text, "compaction")
        let held = await session.suppressedCompactionTask, fingerprint = await session.failedCompactionFingerprint
        XCTAssertNil(held, "Not a summary that was paid for and not adopted"); XCTAssertNil(fingerprint)
        let asked = try XCTUnwrap(state["reasoningRejection"]["id"].text)
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        sent = try chat.requests(); state = await status(session)
        guard sent.count == 6 else { await session.close(); return XCTFail("\(sent.count - 4) requests after Continue: \(state.encoded())") }
        XCTAssertTrue(sent[4]["input"].list.last?.encoded().contains("continuation checkpoint") == true, "Whether a summary is still needed is asked again")
        XCTAssertEqual(reasoning(sent[4]), []); XCTAssertEqual(reasoning(sent[5]), [])
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        let context = await session.context
        XCTAssertEqual(context.first?.kind, "compaction", "The summary was adopted")
        await session.close()
    }

    /// A fork cut at a reply from before the answer does not send that
    /// reply's reasoning again: the answer goes with the fork.
    func testAForkFromBeforeTheAnswerInheritsIt() async throws {
        let chat = try await chat("http")
        let (session, _) = try chat.open()
        try await send(session, "a", "Use the tool")
        let replies = await session.context
        let first = try XCTUnwrap(replies.last { $0.role == "assistant" }?.id)
        try await send(session, "b", "Next", model: "other-model")
        let refused = await status(session)
        let asked = try XCTUnwrap(refused["reasoningRejection"]["id"].text)
        try await retry(session, ["model": "other-model", "withoutEarlierReasoning": ["rejection": JSON(asked)]])
        XCTAssertEqual(try chat.requests().count, 4)
        let forked = try await session.fork(to: "fork", at: first)
        await session.close()
        let (fork, _) = try chat.open("fork", resume: try XCTUnwrap(forked["path"].text))
        try await send(fork, "f", "On the fork", model: "other-model")
        let sent = try chat.requests()
        guard sent.count == 5 else { await fork.close(); return XCTFail("The fork made \(sent.count - 4) requests") }
        XCTAssertEqual(reasoning(sent[4]), [], "The fork ends before the answer was written, and has it")
        let state = await status(fork)
        XCTAssertEqual(state["state"].text, "idle", state["preflightError"].encoded())
        await fork.close()
    }
}
