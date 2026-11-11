import XCTest
@testable import PiAgentCore

/// LiteLLM carries a Gemini thought signature inside the tool call id
/// (`call_<28 hex>__thought__<base64>`, from LiteLLM 1.80.5): a few hundred
/// bytes to hundreds of thousands. Its Gemini route needs that id back byte
/// for byte, as the call's id and as its output's: LiteLLM reads the signature
/// from the id and pairs an output with its call by equality. OpenAI refuses a
/// call id over 64 characters. So the id is kept whole everywhere and sent
/// back whole to the model that made the call (`ProviderToolCallID`); only a
/// request to another model names the call by a short id derived from it
/// (`ProviderClient.sentCallID`).
///
/// These fixtures have the shape LiteLLM's Responses bridge really sends: the
/// item's id repeats the call id (after `fc_` from LiteLLM 1.104), Gemini
/// signs only the first call of a reply, and every argument delta names its
/// item by that long id.
final class GatewayCallIDTests: HelperTestCase {
    /// LiteLLM's id for a Gemini call: its own, then the signature.
    static func signed(_ seed: String, signature: Int) -> String {
        "call_" + String(repeating: seed, count: 14) + "__thought__" + String(String(repeating: "CiQB0e2Kb/+", count: signature / 11 + 1).prefix(signature - 2)) + "=="
    }
    static let signedID = signed("a1", signature: 3_300), plainID = "call_" + String(repeating: "b2", count: 14)

    /// The events of LiteLLM's Responses bridge for a reply with these calls:
    /// each item's id repeats its call id (`fc_` before it from LiteLLM 1.104),
    /// and the arguments arrive ten characters at a time, every delta naming
    /// the item by that id.
    static func bridgeEvents(_ calls: [(id: String, name: String, arguments: String)], fc: Bool = false) -> [JSON] {
        var events: [JSON] = [["type": "response.created", "response": ["id": "resp_1", "status": "in_progress", "output": []]]], output: [JSON] = []
        for (index, call) in calls.enumerated() {
            let itemID = (fc ? "fc_" : "") + call.id
            func item(_ status: String, _ arguments: String) -> JSON {
                ["type": "function_call", "id": JSON(itemID), "call_id": JSON(call.id), "name": JSON(call.name), "status": JSON(status), "arguments": JSON(arguments)]
            }
            events.append(["type": "response.output_item.added", "output_index": JSON(index), "item": item("in_progress", "")])
            var rest = Substring(call.arguments)
            while !rest.isEmpty {
                events.append(["type": "response.function_call_arguments.delta", "item_id": JSON(itemID), "output_index": JSON(index), "delta": JSON(String(rest.prefix(10)))])
                rest = rest.dropFirst(10)
            }
            events.append(["type": "response.function_call_arguments.done", "item_id": JSON(itemID), "output_index": JSON(index), "arguments": JSON(call.arguments)])
            events.append(["type": "response.output_item.done", "output_index": JSON(index), "item": item("completed", call.arguments)])
            output.append(item("completed", call.arguments))
        }
        events.append(["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": .array(output), "usage": ["input_tokens": 100, "output_tokens": 10]]])
        return events
    }
    static let twoCalls: [(id: String, name: String, arguments: String)] = [(signedID, "first", #"{"value":0}"#), (plainID, "second", #"{"value":1}"#)]

    /// A reply as the provider client returns one for those events.
    private func reply(fc: Bool = false, model: String = "fixture-model") throws -> ModelReply {
        var accumulator = ProviderAccumulator(api: "openai-responses")
        for event in Self.bridgeEvents(Self.twoCalls, fc: fc) { _ = try accumulator.consume(event) }
        var reply = try accumulator.result()
        reply.message.providerBinding = try ProviderClient.replayBinding(profile(model: model))
        return reply
    }
    private func profile(model: String = "fixture-model", policy: String? = nil) throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["modelId"] = JSON(model)
        if let policy { raw["routing"] = ["replayPolicy": JSON(policy)] }
        return try Profile(raw)
    }
    private func result(_ call: String, _ text: String) -> ChatMessage {
        var message = ChatMessage(role: "toolResult", content: [textBlock(text)]); message.toolCallId = call; return message
    }
    /// A request's calls (item id, call id) and the call ids its outputs answer.
    private func ids(_ input: [JSON]) -> (calls: [[String?]], outputs: [String?]) {
        (input.filter { $0["type"].text == "function_call" }.map { [$0["id"].text, $0["call_id"].text] },
         input.filter { $0["type"].text == "function_call_output" }.map { $0["call_id"].text })
    }

    // MARK: The reply

    func testALongGatewayCallIDIsAReplyNotAnError() throws {
        XCTAssertGreaterThan(Self.signedID.utf8.count, 3_300)
        for fc in [false, true] {
            var accumulator = ProviderAccumulator(api: "openai-responses"), named: [String] = []
            for event in Self.bridgeEvents(Self.twoCalls, fc: fc) {
                for delta in try accumulator.consume(event) { if case .tool(let id, _, _) = delta { named.append(id) } }
            }
            let reply = try accumulator.result()
            XCTAssertEqual(reply.calls.map(\.name), ["first", "second"])
            XCTAssertEqual(reply.calls.map(\.arguments), [["value": 0], ["value": 1]])
            // The gateway's ids, whole: in the stream, the calls and the message.
            XCTAssertEqual(reply.calls.map(\.id), [Self.signedID, Self.plainID])
            XCTAssertEqual(Set(named), [Self.signedID, Self.plainID], "every streamed fragment names its call as the reply does")
            XCTAssertEqual(reply.message.content.filter { $0["type"].text == "toolCall" }.map { $0["id"].text }, [Self.signedID, Self.plainID])
            // What the gateway sent is kept as it came.
            let prefix = fc ? "fc_" : ""
            XCTAssertEqual(reply.message.providerItems?.map { [$0["id"].text, $0["call_id"].text] }, [[prefix + Self.signedID, Self.signedID], [prefix + Self.plainID, Self.plainID]])
        }
    }

    func testEveryLengthOfSignatureIsAccepted() throws {
        // 512 bytes was the helper's old bound; one signature in the wild was 278,100.
        for signature in [200, 468, 469, 4_096, 278_100] {
            let id = Self.signed("c3", signature: signature)
            var accumulator = ProviderAccumulator(api: "openai-responses")
            for event in Self.bridgeEvents([(id, "first", "{}")]) { _ = try accumulator.consume(event) }
            let reply = try accumulator.result()
            XCTAssertEqual(reply.calls.map(\.id), [id], "\(signature)")
            XCTAssertEqual(reply.message.providerItems?.first?["call_id"].text, id, "\(signature)")
        }
    }

    func testAnOversizeIDSaysThatLengthIsTheReason() throws {
        let id = String(repeating: "x", count: ProviderToolCallID.maximumUTF8Bytes + 1)
        var accumulator = ProviderAccumulator(api: "openai-responses")
        for event in Self.bridgeEvents([(id, "first", "{}")]) { _ = try accumulator.consume(event) }
        XCTAssertThrowsError(try accumulator.result()) {
            XCTAssertEqual(($0 as? AgentError)?.message, "Invalid tool call id: 1048577 bytes, over the 1048576-byte limit")
        }
    }

    func testTheTimelineNamesACallAsItsCardDoes() throws {
        var accumulator = ProviderAccumulator(api: "openai-responses"), display = ProviderDisplayEvents(api: "openai-responses", attempt: "fixture")
        for event in Self.bridgeEvents(Self.twoCalls) { _ = try accumulator.consume(event); _ = display.consume(event, at: 1) }
        let calls = try accumulator.result().calls.map(\.id)
        XCTAssertEqual(display.timeline.segments.compactMap(\.part.callID), calls, "the app pairs a timeline segment with its tool card by this id")
        XCTAssertEqual(calls, [Self.signedID, Self.plainID])
    }

    // MARK: The next request

    func testTheModelThatMadeACallGetsItsGatewaysIDBackByteForByte() throws {
        for fc in [false, true] {
            let reply = try reply(fc: fc)
            let history = [ChatMessage(role: "user", content: [textBlock("go")]), reply.message,
                           result(reply.calls[0].id, "A"), result(reply.calls[1].id, "B")]
            let prefix = fc ? "fc_" : ""
            // Replayed from the provider's items, or portably from the visible calls.
            for policy in [nil, "portable"] {
                let sent = ids(try ProviderClient.responsesInput(history, instructions: "", profile: profile(policy: policy)))
                XCTAssertEqual(sent.calls.map { $0[1] }, [Self.signedID, Self.plainID], "\(policy ?? "default")")
                XCTAssertEqual(sent.outputs, [Self.signedID, Self.plainID], "LiteLLM pairs an output with its call by equality (\(policy ?? "default"))")
                // Pi replays an item id that begins with `fc_`, and no other.
                if policy == nil { XCTAssertEqual(sent.calls.map { $0[0] }, fc ? [prefix + Self.signedID, prefix + Self.plainID] : [nil, nil]) }
            }
        }
    }

    func testACallWhoseResultNeverCameIsAnsweredUnderTheGatewaysID() throws {
        let reply = try reply()
        // The second result is missing: pi's synthetic result closes it.
        let history = [ChatMessage(role: "user", content: [textBlock("go")]), reply.message, result(reply.calls[0].id, "A"),
                       ChatMessage(role: "user", content: [textBlock("next")])]
        let input = try ProviderClient.responsesInput(history, instructions: "", profile: profile())
        let outputs = input.filter { $0["type"].text == "function_call_output" }
        XCTAssertEqual(outputs.map { [$0["call_id"].text, $0["output"].text] }, [[Self.signedID, "A"], [Self.plainID, "No result provided"]])
        try CompactionPlanner.validateRequest(["input": .array(input)])
    }

    func testAnotherModelGetsIDsItAccepts() throws {
        let reply = try reply(model: "gemini-model")
        let history = [ChatMessage(role: "user", content: [textBlock("go")]), reply.message,
                       result(reply.calls[0].id, "A"), result(reply.calls[1].id, "B")]
        let sent = ids(try ProviderClient.responsesInput(history, instructions: "", profile: profile(model: "gpt-model")))
        let short = ProviderClient.sentCallID(Self.signedID, own: false)
        XCTAssertEqual(sent.calls, [[nil, short], [nil, Self.plainID]], "an id of ordinary length is left alone")
        XCTAssertEqual(sent.outputs, sent.calls.map { $0[1] }, "each output answers its call")
        XCTAssertEqual(short.utf8.count, 37, "OpenAI refuses a call id over 64 characters; a chat-completions route, over 40")
        XCTAssertEqual(short, ProviderClient.sentCallID(Self.signedID, own: false), "the same call, the same name: the other model's prefix stays cached")
        XCTAssertNotEqual(short, ProviderClient.sentCallID(Self.signedID + "x", own: false))
        XCTAssertEqual(ProviderClient.sentCallID(Self.signedID, own: true), Self.signedID)
        // A call the other model never got a result for is closed under the same name.
        let open = ids(try ProviderClient.responsesInput(Array(history.prefix(3)) + [ChatMessage(role: "user", content: [textBlock("next")])], instructions: "", profile: profile(model: "gpt-model")))
        XCTAssertEqual(open.outputs, [short, Self.plainID])
    }


    // MARK: Through the gateway

    /// Answers as LiteLLM does for `fixture-model` (a Gemini route), and as
    /// OpenAI does for any other model. Every request is kept, one per line.
    static let gatewayScript = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
SIGNED = 'call_' + 'a1' * 14 + '__thought__' + ('CiQB0e2Kb/+' * 301)[:3298] + '=='
PLAIN = 'call_' + 'b2' * 14
def item(call_id, name, status, arguments):
    return {'type': 'function_call', 'id': call_id, 'call_id': call_id, 'name': name, 'status': status, 'arguments': arguments}
def refusal(body):
    gemini, called = body['model'] == 'fixture-model', set()
    for index, entry in enumerate(body['input']):
        kind, call_id = entry.get('type'), entry.get('call_id') or ''
        if kind == 'function_call':
            called.add(call_id)
            if not gemini and 'id' in entry and not entry['id'].startswith('fc'):
                return "Invalid 'input[%d].id': '%s'. Expected an ID that begins with 'fc'." % (index, entry['id'])
        if kind in ('function_call', 'function_call_output') and not gemini and len(call_id) > 64:
            return "Invalid 'input[%d].call_id': string too long. Expected a string with maximum length 64, but got a string with length %d instead." % (index, len(call_id))
        if kind == 'function_call_output' and call_id not in called:
            return 'Missing corresponding tool call for tool response message.'
    if gemini and called and called != {SIGNED, PLAIN}:
        return 'Function call is missing a thought_signature in functionCall parts.'
    return None
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        with (root / 'requests.jsonl').open('a') as log: log.write(json.dumps(body) + '\n')
        refused = refusal(body)
        if refused:
            payload = json.dumps({'error': {'message': refused, 'type': 'invalid_request_error', 'code': '400'}}).encode()
            self.send_response(400); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        frames = [{'type': 'response.created', 'response': {'id': 'r1', 'status': 'in_progress', 'output': []}}]
        usage = {'input_tokens': 100, 'output_tokens': 10, 'total_tokens': 110}
        if any(entry.get('type') == 'function_call_output' for entry in body['input']):
            message = {'type': 'message', 'id': 'msg_1', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'Both ran.', 'annotations': []}]}
            frames += [{'type': 'response.output_item.added', 'output_index': 0, 'item': {**message, 'status': 'in_progress', 'content': []}},
                       {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': 'msg_1', 'content_index': 0, 'delta': 'Both ran.'},
                       {'type': 'response.output_item.done', 'output_index': 0, 'item': message},
                       {'type': 'response.completed', 'response': {'id': 'r1', 'status': 'completed', 'model': body['model'], 'output': [message], 'usage': usage}}]
        else:
            output = []
            for index, (call_id, name, arguments) in enumerate([(SIGNED, 'first', '{"value":0}'), (PLAIN, 'second', '{"value":1}')]):
                frames.append({'type': 'response.output_item.added', 'output_index': index, 'item': item(call_id, name, 'in_progress', '')})
                frames += [{'type': 'response.function_call_arguments.delta', 'item_id': call_id, 'output_index': index, 'delta': arguments[at:at + 10]} for at in range(0, len(arguments), 10)]
                frames.append({'type': 'response.function_call_arguments.done', 'item_id': call_id, 'output_index': index, 'arguments': arguments})
                output.append(item(call_id, name, 'completed', arguments))
                frames.append({'type': 'response.output_item.done', 'output_index': index, 'item': output[-1]})
            frames.append({'type': 'response.completed', 'response': {'id': 'r1', 'status': 'completed', 'model': body['model'], 'output': output, 'usage': usage}})
        payload = b''.join(b'event: ' + f['type'].encode() + b'\ndata: ' + json.dumps(f).encode() + b'\n\n' for f in frames)
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload))); self.end_headers()
        self.wfile.write(payload); self.wfile.flush()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    private func requests(_ root: URL) throws -> [JSON] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
    }

    /// The owner's report: a Gemini turn that makes a tool call fails with
    /// "Invalid tool call id". Here the whole turn runs, the chat goes on after
    /// the helper restarts, and a turn on another model is accepted too.
    func testAGeminiTurnWithToolCallsRunsAndGoesOnAfterARestartAndAModelSwitch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(gateway.port)/v1")
        let profile = try Profile(raw)
        func open(resume path: String? = nil) throws -> (AgentSession, RecordingTools) {
            let traces = TraceStore(), tools = RecordingTools()
            return (try AgentSession(id: "gemini-ids", profile: profile, apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                     resources: Resources(cwd: root, home: root), client: ProviderClient(traces: traces), tools: tools, traces: traces, resumePath: path, autoCompaction: false), tools)
        }
        func last(_ session: AgentSession) async -> String { await session.context.last.map { "\($0.role): \($0.text)" } ?? "" }

        var (session, tools) = try open()
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "Run both"), steer: false)
        try await eventually { !(await session.isRunning) }
        let failure = await session.snapshot(["includeMessages": false])["preflightError"]
        let ran = await tools.calls
        XCTAssertEqual(ran.sorted(), ["first", "second"], "both calls ran; the turn's failure, if any: \(failure.encoded())")
        let answered = await last(session)
        XCTAssertEqual(answered, "assistant: Both ran.", failure.encoded())
        let results = await session.context.filter { $0.role == "toolResult" }.map(\.toolCallId)
        XCTAssertEqual(results, [Self.signedID, Self.plainID], "the chat keeps the gateway's ids whole")
        var sent = try requests(root)
        guard sent.count == 2 else { await session.close(); return XCTFail("The turn made \(sent.count) of its 2 requests: \(failure.encoded())") }
        XCTAssertEqual(ids(sent[1]["input"].list).outputs, [Self.signedID, Self.plainID], "the gateway got its own ids back")
        let journal = await session.path
        await session.close()

        // After a restart the journal still says which id the gateway minted.
        (session, tools) = try open(resume: try XCTUnwrap(journal))
        _ = try await session.submit(Submission(commandID: "b", turnID: "b", text: "And again"), steer: false)
        try await eventually { !(await session.isRunning) }
        sent = try requests(root)
        guard sent.count == 3 else { await session.close(); return XCTFail("The reopened chat sent \(sent.count - 2) requests") }
        XCTAssertEqual(ids(sent[2]["input"].list).calls.map { $0[1] }, [Self.signedID, Self.plainID])
        XCTAssertEqual(ids(sent[2]["input"].list).outputs, [Self.signedID, Self.plainID])
        let again = await last(session)
        XCTAssertEqual(again, "assistant: Both ran.")

        // Another model (an OpenAI route here) takes the same history.
        _ = try await session.submit(Submission(commandID: "c", turnID: "c", text: "Now you", model: "other-model"), steer: false)
        try await eventually { !(await session.isRunning) }
        sent = try requests(root)
        guard sent.count == 4 else { await session.close(); return XCTFail("The other model's turn sent \(sent.count - 3) requests") }
        XCTAssertEqual(sent[3]["model"].text, "other-model")
        let other = ids(sent[3]["input"].list)
        XCTAssertEqual(other.calls.map { $0[1] }, [ProviderClient.sentCallID(Self.signedID, own: false), Self.plainID]); XCTAssertEqual(other.outputs, other.calls.map { $0[1] })
        let switched = await last(session)
        XCTAssertEqual(switched, "assistant: Both ran.")
        await session.close()
    }
}
