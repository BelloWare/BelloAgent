import XCTest
@testable import PiAgentCore

/// A gateway that ends a healthy Responses stream before its terminal event
/// (owner, 2026-11-13, gpt-6-astra through LiteLLM: reasoning items only,
/// one every 16–18 s, then the connection ends about 60 s after the start,
/// with no `response.completed`, `response.failed` or `error`).
///
/// Nothing in the helper ends a stream that is still sending events: the
/// idle bound is 300 s between body bytes, the whole request has a week.
/// What the helper does with such a cut is what these tests pin: the attempt
/// fails, its request log says why, and a retry sends the same input again,
/// so the text the cut attempt streamed (a commentary message before the
/// model went on reasoning) stays as a reply of its own that the model never
/// sees, and the next attempt answers the same message afresh.
final class CutStreamTests: HelperTestCase {
    /// Kinds, by model name:
    /// - `cut-reasoning`: created, in_progress, three reasoning items
    ///   (added, then done), a fourth added, then the socket closes (EOF).
    /// - `cut-text`: a reasoning item, a commentary message whose text
    ///   streams in full, a second reasoning item opens, then EOF.
    /// - `reset-text`: the same, then the connection is reset instead.
    /// - `slow-complete`: four reasoning items, then the final answer and
    ///   `response.completed`.
    /// - `cut-once-text`: the first request is `cut-text`, later ones
    ///   `slow-complete`.
    /// The pause between events is `gap` seconds (the file `gap`, else 0.05).
    /// Every request body is saved as `request-<n>.json`.
    static let gatewayScript = #"""
import http.server, json, pathlib, socket, struct, sys, threading, time
root = pathlib.Path(sys.argv[1])
lock = threading.Lock(); count = [0]
def frame(value): return b'event: ' + value['type'].encode() + b'\ndata: ' + json.dumps(value).encode() + b'\n\n'
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with lock:
            count[0] += 1; number = count[0]
        (root / ('request-%d.json' % number)).write_bytes(body)
        request = json.loads(body); kind = request['model']
        gap_file = root / 'gap'
        gap = float(gap_file.read_text()) if gap_file.exists() else 0.05
        response = {'id': 'resp_cut', 'object': 'response', 'created_at': 1794579298, 'status': 'in_progress', 'model': kind,
                    'output': [], 'max_output_tokens': request.get('max_output_tokens'), 'store': False, 'truncation': 'disabled'}
        sequence = [0]
        def send(value):
            value['sequence_number'] = sequence[0]; sequence[0] += 1
            self.wfile.write(frame(value)); self.wfile.flush()
        def reasoning(index, size): return {'type': 'reasoning', 'id': 'rs_%d' % index, 'summary': [], 'content': [], 'encrypted_content': 'litellm_enc:bW9kZWxfaWQ6Zml4dHVyZQ==;gAAAA' + 'x' * size}
        def think(index):
            send({'type': 'response.output_item.added', 'output_index': index, 'item': reasoning(index, 200)})
            time.sleep(gap)
            send({'type': 'response.output_item.done', 'output_index': index, 'item': reasoning(index, 4000)})
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        send({'type': 'response.created', 'response': response})
        send({'type': 'response.in_progress', 'response': response})
        output = []
        if kind == 'cut-once-text' and number > 1: kind = 'slow-complete'
        if kind in ('cut-reasoning', 'slow-complete'):
            items = 4 if kind == 'slow-complete' else 3
            for index in range(items):
                think(index); output.append(reasoning(index, 4000))
            if kind == 'cut-reasoning':
                send({'type': 'response.output_item.added', 'output_index': 3, 'item': reasoning(3, 200)})
                time.sleep(gap); return
            message = {'type': 'message', 'id': 'msg_final', 'role': 'assistant', 'status': 'completed', 'phase': 'final_answer',
                       'content': [{'type': 'output_text', 'text': 'Done after a long think.', 'annotations': []}]}
            send({'type': 'response.output_item.added', 'output_index': items, 'item': dict(message, status='in_progress', content=[])})
            send({'type': 'response.output_text.delta', 'output_index': items, 'item_id': 'msg_final', 'content_index': 0, 'delta': 'Done after a long think.'})
            send({'type': 'response.output_item.done', 'output_index': items, 'item': message})
            output.append(message)
            send({'type': 'response.completed', 'response': dict(response, status='completed', output=output,
                  usage={'input_tokens': 120, 'output_tokens': 40, 'output_tokens_details': {'reasoning_tokens': 30}})})
            return
        think(0)
        text = ['Hi — I’m here. ', 'The senior reviewer already has a read-only inspector; ', 'I’m adapting it for both reviewers.']
        message = {'type': 'message', 'id': 'msg_commentary_%d' % number, 'role': 'assistant', 'status': 'completed', 'phase': 'commentary',
                   'content': [{'type': 'output_text', 'text': ''.join(text), 'annotations': []}]}
        send({'type': 'response.output_item.added', 'output_index': 1, 'item': dict(message, status='in_progress', content=[])})
        for piece in text:
            send({'type': 'response.output_text.delta', 'output_index': 1, 'item_id': message['id'], 'content_index': 0, 'delta': piece})
        send({'type': 'response.output_item.done', 'output_index': 1, 'item': message})
        send({'type': 'response.output_item.added', 'output_index': 2, 'item': reasoning(2, 200)})
        time.sleep(gap)
        if kind == 'reset-text':
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            self.connection.close()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    private func profile(_ kind: String, port: Int) throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(port)/v1"); raw["modelId"] = JSON(kind)
        return try Profile(raw)
    }
    /// One request through the real provider path; its error, if any, and its request log.
    private func attempt(_ kind: String, gateway: PythonGateway) async throws -> (error: AgentError?, metadata: JSON, deltas: String) {
        let traces = TraceStore(), client = ProviderClient(traces: traces)
        let text = TextSink()
        var failure: AgentError?
        do {
            _ = try await client.complete(profile: try profile(kind, port: gateway.port), apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("hi")])],
                                          instructions: "fixture", tools: [], sessionID: "cut", turnID: "t", purpose: "turn",
                                          onDelta: { delta in if case .text(let piece) = delta { await text.add(piece) } })
        } catch let error as AgentError { failure = error }
        return (failure, await traces.latest("cut"), await text.value)
    }

    /// The owner's stream: reasoning items only, then it just ends. The
    /// attempt fails as a stream without its terminal event, which pi reads
    /// as transient (so it is retried), and its request log says so: the
    /// outcome, how the connection ended, and the reason in words.
    func testAStreamThatEndsWhileTheModelReasonsFailsAndItsLogSaysWhy() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let result = try await attempt("cut-reasoning", gateway: gateway)
        let error = try XCTUnwrap(result.error, "a stream without its terminal event is not a reply")
        XCTAssertEqual(error.code, "incomplete_stream")
        XCTAssertTrue(AgentSession.isRetryable(error), "pi retries a stream that ended before its terminal event")
        XCTAssertEqual(result.metadata["outcome"].text, "failed")
        XCTAssertEqual(result.metadata["modelOutcome"].text, "interrupted", "the gateway sent no failure event")
        XCTAssertEqual(result.metadata["transportOutcome"].text, "eof", "the gateway closed the stream itself")
        XCTAssertTrue(result.metadata["usage"].map.isEmpty || result.metadata["usage"]["output"].isNull, "no usage arrives without the terminal event")
        // The reason, in the request's own log (Inspector › Raw › Metadata).
        XCTAssertEqual(result.metadata["failure"]["code"].text, "incomplete_stream")
        XCTAssertTrue(result.metadata["failure"]["message"].text?.contains("ended without its terminal event") == true, "\(result.metadata["failure"])")
    }

    /// A reset connection after the text: a transport failure, retried too,
    /// and the log names it.
    func testAResetAfterTheTextFailsAsATransportErrorAndItsLogSaysWhy() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let result = try await attempt("reset-text", gateway: gateway)
        XCTAssertTrue(result.deltas.hasPrefix("Hi — I’m here."), "the commentary streamed in full before the cut")
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(["provider_transport", "incomplete_stream"].contains(error.code), error.code)
        XCTAssertTrue(AgentSession.isRetryable(error))
        XCTAssertEqual(result.metadata["outcome"].text, "failed")
        XCTAssertEqual(result.metadata["failure"]["code"].text, error.code)
        XCTAssertFalse((result.metadata["failure"]["message"].text ?? "").isEmpty)
    }

    private func session(_ kind: String, gateway: PythonGateway, root: URL, retries: Int) async throws -> AgentSession {
        let traces = TraceStore()
        let session = try AgentSession(id: "cut-turn", profile: try profile(kind, port: gateway.port), apiKey: "fixture", cwd: root,
                                       directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root),
                                       client: ProviderClient(traces: traces), tools: RecordingTools(), traces: traces, autoCompaction: false)
        // The owner's settings: ten retries, the first after one second (here 1 ms).
        await session.useRetrySettings(PiProviderRules.RetrySettings(enabled: true, maxRetries: retries, baseDelayMs: 1))
        _ = try await session.submit(Submission(commandID: "hi", turnID: "hi", text: "hi"), steer: false)
        try await eventually(timeout: .seconds(30)) { !(await session.isRunning) }
        return session
    }
    private func bodies(_ root: URL) throws -> [JSON] {
        var bodies: [JSON] = []
        while case let url = root.appendingPathComponent("request-\(bodies.count + 1).json"), FileManager.default.fileExists(atPath: url.path) {
            bodies.append(try JSON.parse(Data(contentsOf: url)))
        }
        return bodies
    }

    /// The screenshots: every request is cut after its commentary streamed
    /// (a proxy's 60-second limit). A retry sends the same bytes, without the
    /// text the cut attempt showed, so the model greets again, and each cut
    /// attempt's text stays as a reply row of its own. With the owner's ten
    /// retries that was eleven paid requests in a row; now the second broken
    /// stream of one request ends the run, paused, with a notice that says
    /// what happened, whatever the retry setting.
    func testASecondBrokenStreamOfOneRequestEndsTheRunWithAPlainNotice() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let session = try await session("cut-text", gateway: gateway, root: root, retries: 10)
        let sent = try bodies(root)
        XCTAssertEqual(sent.count, 2, "one request and one re-send, not eleven")
        XCTAssertEqual(sent[1]["input"], sent[0]["input"], "a retry sends the same input")
        XCTAssertFalse(sent[1]["input"].encoded().contains("I’m here"), "the cut attempt's text is not sent back")
        let cut = await session.history.filter { $0.role == "assistant" }
        XCTAssertEqual(cut.count, 2, "each cut attempt is a reply row of its own")
        XCTAssertEqual(cut.map(\.stopReason), ["interrupted", "interrupted"])
        XCTAssertTrue(cut.allSatisfy { $0.text.hasPrefix("Hi — I’m here.") && !$0.replayEligible })
        let failed = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(failed["state"].text, "error")
        XCTAssertEqual(failed["queuePaused"].flag, true)
        let notice = try XCTUnwrap(failed["preflightError"].text)
        XCTAssertTrue(notice.hasPrefix("The connection was closed before the reply finished, 2 times for this request (after "), notice)
        XCTAssertTrue(notice.contains("A time limit on the gateway or a proxy in front of it is the likely cause. Retry sends it once more."), notice)
        XCTAssertTrue(notice.contains("ended without its terminal event"), "the last error is named: \(notice)")
        await session.close()
    }

    /// One broken stream is still retried: a dropped connection recovers.
    func testOneBrokenStreamIsSentAgainAndTheReplyCompletes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let session = try await session("cut-once-text", gateway: gateway, root: root, retries: 3)
        XCTAssertEqual(try bodies(root).count, 2)
        let replies = await session.history.filter { $0.role == "assistant" }
        XCTAssertEqual(replies.map(\.stopReason), ["interrupted", nil], "the cut attempt, then the answer")
        XCTAssertEqual(replies.last?.text, "Done after a long think.")
        let done = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(done["state"].text, "idle")
        await session.close()
    }

    /// Without retries the bound changes nothing: the first failure stops.
    func testWithRetriesOffABrokenStreamFailsAsBefore() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let session = try await session("cut-text", gateway: gateway, root: root, retries: 0)
        XCTAssertEqual(try bodies(root).count, 1)
        let failed = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(failed["preflightError"].text?.hasPrefix("The stream ended without its terminal event") == true, "\(failed["preflightError"])")
        await session.close()
    }

    /// A connection lost under a reply in progress (the owner's records:
    /// HTTP 200, `transportOutcome` "error", URLError -1005 61.7 s after
    /// dispatch) is a broken stream as well, and its error says so rather
    /// than that the gateway could not be reached.
    func testAConnectionLostAfterTheResponseBeganIsABrokenStreamAndSaysSo() async throws {
        let lost = URLError(.networkConnectionLost)
        let cut = AgentError("provider_transport", ProviderClient.transportGuidance(lost, attempt: "7", afterResponse: true), failure: .transientTransport,
                             providerMessage: PiErrorText.transport(lost, afterResponse: true))
        XCTAssertTrue(AgentSession.isBrokenStream(cut)); XCTAssertTrue(AgentSession.isRetryable(cut))
        XCTAssertTrue(cut.message.hasPrefix("The connection was closed while the reply was arriving ("), cut.message)
        XCTAssertTrue(cut.message.contains("-1005"), cut.message)
        XCTAssertFalse(cut.message.contains("could not be reached"))
        // Before any response it is the gateway that could not be reached: retried in full.
        let unreached = AgentError("provider_transport", ProviderClient.transportGuidance(URLError(.cannotConnectToHost), attempt: "7"), failure: .transientTransport,
                                   providerMessage: PiErrorText.transport(URLError(.cannotConnectToHost), afterResponse: false))
        XCTAssertFalse(AgentSession.isBrokenStream(unreached)); XCTAssertTrue(unreached.message.contains("could not be reached"))
        // A gateway's own retryable failure is not a broken stream either.
        XCTAssertFalse(AgentSession.isBrokenStream(AgentError("provider_http", "Provider returned HTTP 503. Try again.")))
        // The request log keeps the connection's own error.
        let record = ProviderClient.failureRecord(cut, cause: lost, afterMs: 61_686.8)
        XCTAssertEqual(record["code"].text, "provider_transport")
        XCTAssertEqual(record["connectionError"]["domain"].text, NSURLErrorDomain)
        XCTAssertEqual(record["connectionError"]["code"].int, -1005)
        XCTAssertEqual(record["afterMs"].double, 61_687)
        XCTAssertTrue(ProviderClient.failureRecord(cut, cause: cut, afterMs: nil)["connectionError"].isNull)
    }

    /// The bound counts broken streams only: failures the gateway reports
    /// (a 503, a rate limit) keep the owner's whole retry setting, and two
    /// lost connections end the run whatever it is.
    func testOnlyBrokenStreamsAreBoundedNotTheGatewaysReportedFailures() async throws {
        func run(_ failures: [AgentError]) async throws -> (requests: Int, snapshot: JSON) {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let client = FailingClient(failures: failures)
            let session = try AgentSession(id: "bound", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                           resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
            await session.useRetrySettings(PiProviderRules.RetrySettings(enabled: true, maxRetries: 10, baseDelayMs: 1))
            _ = try await session.submit(Submission(commandID: "go", turnID: "go", text: "go"), steer: false)
            try await eventually { !(await session.isRunning) }
            let result = (await client.requests, await session.snapshot(["includeMessages": false]))
            await session.close()
            return result
        }
        let unavailable = AgentError("provider_http", "Provider returned HTTP 503. The gateway failed on its side; try again.")
        let reported = try await run(Array(repeating: unavailable, count: 5))
        XCTAssertEqual(reported.requests, 6, "five reported failures, then the reply")
        XCTAssertEqual(reported.snapshot["state"].text, "idle")
        let lost = URLError(.networkConnectionLost)
        let cut = AgentError("provider_transport", ProviderClient.transportGuidance(lost, attempt: "a", afterResponse: true), failure: .transientTransport,
                             providerMessage: PiErrorText.transport(lost, afterResponse: true))
        let broken = try await run([cut, unavailable, cut, cut])
        XCTAssertEqual(broken.requests, 3, "a cut, a reported failure, a second cut: not sent again")
        XCTAssertEqual(broken.snapshot["state"].text, "error")
        XCTAssertTrue(broken.snapshot["preflightError"].text?.hasPrefix("The connection was closed before the reply finished, 2 times for this request") == true, "\(broken.snapshot["preflightError"])")
    }

    /// Nothing of the helper's own ends a stream that is still sending: the
    /// owner's shape (a reasoning item every 17 s, no delta between them)
    /// completes after more than 60 s. Slow (about 70 s), so it runs only
    /// with PI_SLOW_GATEWAY_TESTS=1.
    func testAStreamOfReasoningItemsSeventeenSecondsApartIsNotCutAtSixtySeconds() async throws {
        guard ProcessInfo.processInfo.environment["PI_SLOW_GATEWAY_TESTS"] == "1" else { throw XCTSkip("Set PI_SLOW_GATEWAY_TESTS=1 to run the 70-second stream") }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("17".utf8).write(to: root.appendingPathComponent("gap"))
        let gateway = try await PythonGateway.start(source: Self.gatewayScript, root: root); defer { gateway.stop() }
        let started = Date()
        let result = try await attempt("slow-complete", gateway: gateway)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertGreaterThan(elapsed, 65)
        XCTAssertEqual(result.deltas, "Done after a long think.")
        XCTAssertEqual(result.metadata["outcome"].text, "completed")
        XCTAssertTrue(result.metadata["failure"].isNull, "a completed request names no failure")
    }
}

/// Fails with each of `failures` after a partial reply, then answers.
private actor FailingClient: ModelClient {
    var failures: [AgentError], requests = 0
    init(failures: [AgentError]) { self.failures = failures }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1
        try await onDelta(.text("Hi — I’m here. "))
        if !failures.isEmpty { throw failures.removeFirst() }
        return answer("Hi — I’m here. Done.")
    }
}

private actor TextSink {
    private(set) var value = ""
    func add(_ piece: String) { value += piece }
}
