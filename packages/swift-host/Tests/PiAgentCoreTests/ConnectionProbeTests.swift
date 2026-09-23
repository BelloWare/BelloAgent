import XCTest
@testable import PiAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ConnectionProbeTests: XCTestCase {
    func testOneSmallModelSpecificRequestWithNoToolsOrWorkspaceResources() async throws {
        let client = ProbeClient(.success(answer("Connected.")))
        var raw = try fixtureProfile().raw
        raw["modelId"] = "owner-selected-router"; raw["thinkingLevel"] = "high"
        _ = try await ConnectionProbe.run(profile: Profile(raw), apiKey: "synthetic-key", sessionID: "probe", client: client)
        let calls = await client.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].profile.model, "owner-selected-router")
        XCTAssertEqual(calls[0].profile.maxOutput, 256)
        XCTAssertEqual(calls[0].profile.raw["thinkingLevel"], "default")
        XCTAssertEqual(calls[0].instructions, ConnectionProbe.instructions)
        XCTAssertEqual(calls[0].messages.map(\.text), [ConnectionProbe.prompt])
        XCTAssertEqual(calls[0].purpose, "connection-test"); XCTAssertEqual(calls[0].tools, 0)
        let body = try ProviderClient.requestBody(profile: calls[0].profile, messages: calls[0].messages, instructions: calls[0].instructions, tools: [], sessionID: "probe")
        XCTAssertTrue(body["reasoning"].isNull); XCTAssertTrue(body["include"].isNull); XCTAssertTrue(body["tools"].list.isEmpty)
        raw["maxOutputTokens"] = 32
        let limited = ProbeClient(.success(answer("OK")))
        _ = try await ConnectionProbe.run(profile: Profile(raw), apiKey: "synthetic-key", sessionID: "limited", client: limited)
        let limitedCalls = await limited.calls; XCTAssertEqual(limitedCalls[0].profile.maxOutput, 32)
    }

    func testEmptyTruncatedToolAndHTTPFailuresNeverVerifyOrRetry() async throws {
        var truncated = answer("partial"); truncated.truncated = true
        let cases: [(Result<ModelReply, AgentError>, String)] = [
            (.success(answer(" \n")), "connection_test_empty"),
            (.success(truncated), "connection_test_truncated"),
            (.success(toolReply(["read"])), "connection_test_empty"),
            (.failure(AgentError("provider_http", "Provider returned HTTP 401 synthetic-key")), "connection_test_http"),
            (.failure(AgentError("provider_transport", "synthetic-key")), "connection_test_failed")]
        for (result, code) in cases {
            let client = ProbeClient(result)
            do { _ = try await ConnectionProbe.run(profile: fixtureProfile(), apiKey: "synthetic-key", sessionID: "probe", client: client); XCTFail("Unexpected verification") }
            catch let error as AgentError { XCTAssertEqual(error.code, code); XCTAssertFalse(error.message.contains("synthetic-key")) }
            let count = await client.calls.count; XCTAssertEqual(count, 1)
        }
    }

    func testTimeoutCancelsOnlyAttemptAndCallerCancellationIsNotSuccess() async throws {
        let profile = try fixtureProfile(), timed = ProbeClient(.success(answer("late")), hold: true)
        do { _ = try await ConnectionProbe.run(profile: profile, apiKey: "synthetic-key", sessionID: "timeout", client: timed, timeout: .milliseconds(20)); XCTFail("Timed out request verified") }
        catch let error as AgentError { XCTAssertEqual(error.code, "connection_test_timeout") }
        let timedCount = await timed.calls.count, timeoutCancelled = await timed.cancelled
        XCTAssertEqual(timedCount, 1); XCTAssertTrue(timeoutCancelled)
        let cancelled = ProbeClient(.success(answer("late")), hold: true)
        let task = Task { try await ConnectionProbe.run(profile: profile, apiKey: "synthetic-key", sessionID: "cancel", client: cancelled) }
        try await eventually { await cancelled.calls.count == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request verified") } catch is CancellationError { }
        let cancelCount = await cancelled.calls.count, didCancel = await cancelled.cancelled
        XCTAssertEqual(cancelCount, 1); XCTAssertTrue(didCancel)
    }

    func testActualHTTPProbeValidatesSelectedModelAndCapturesBytesWithoutCreatingSession() async throws {
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("connection-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Deliberately put instructions alongside the helper's workspace. A
        // connection probe must never load these into its small request.
        try Data("PRIVATE WORKSPACE INSTRUCTIONS MUST NEVER BE SENT".utf8).write(to: scratch.appendingPathComponent("AGENTS.md"))
        let script = scratch.appendingPathComponent("gateway.py")
        try Data(Self.gatewayScript.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, scratch.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { stopFixtureProcess(server) }
        let ready = scratch.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try JSON.parse(Data(contentsOf: ready))["port"].int!
        let base = "http://127.0.0.1:\(port)"
        let service = NativeHostService(emit: { _ in })
        let journal = scratch.appendingPathComponent("Sessions")
        _ = try await service.command("workspace.open", sessionID: nil,
            params: ["cwd": JSON(scratch.path), "directory": JSON(journal.path), "mcp": ["servers": [:]]])
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON(base); raw["modelId"] = "owner-selected-router"
        raw["maxOutputTokens"] = 8192; raw["thinkingLevel"] = "high"
        raw["compat"] = ["supportsMaxOutputTokens": false]
        let result = try await service.command("connection.test", sessionID: "connection-test-fixture",
            params: ["profile": raw, "apiKey": "synthetic-probe-key"])
        XCTAssertEqual(result["verified"], true); XCTAssertEqual(result["model"], "owner-selected-router")
        let attempts = try await service.command("debug.list", sessionID: "connection-test-fixture", params: [:])["attempts"].list
        XCTAssertEqual(attempts.count, 1)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt["purpose"], "connection-test")
        XCTAssertEqual(attempt["outcome"], "completed")
        let metadata = try await service.command("debug.attempt", sessionID: "connection-test-fixture", params: ["attemptId": attempt["attemptId"]])
        XCTAssertEqual(metadata["requestHeaders"]["authorization"].text, "Bearer ********-key")
        let recorded = try JSON.parse(Data(contentsOf: scratch.appendingPathComponent("record.json")))
        for kind in ["request", "response"] {
            let body = try await service.command("debug.body", sessionID: "connection-test-fixture", params: ["attemptId": attempt["attemptId"], "body": JSON(kind)])
            XCTAssertEqual(body["bytes"], recorded[kind], "\(kind) capture must match independent gateway bytes")
        }
        do { _ = try await service.command("session.snapshot", sessionID: "connection-test-fixture", params: [:]); XCTFail("Probe must not open a chat runtime") }
        catch let error as AgentError { XCTAssertEqual(error.code, "session_missing") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: journal.path).contains { $0.hasSuffix(".jsonl") })
        // The fixture derives its answer from a validated request; malformed
        // model/tools must be rejected instead of receiving a canned success.
        let sent = try XCTUnwrap(recorded["request"].text.flatMap { Data(base64Encoded: $0) })
        for invalid in ["model", "tools"] {
            var body = try JSON.parse(sent)
            body[invalid] = invalid == "model" ? "wrong-model" : [["type": "function", "name": "read"]]
            var request = URLRequest(url: URL(string: base + "/v1/responses")!)
            request.httpMethod = "POST"; request.httpBody = try body.data()
            request.setValue("Bearer synthetic-probe-key", forHTTPHeaderField: "Authorization")
            request.setValue("connection-test-fixture", forHTTPHeaderField: "x-session-id")
            request.setValue("negative-probe", forHTTPHeaderField: "x-turn-id")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 422)
        }
        await service.shutdown()
    }

    static let gatewayScript = #"""
import base64, http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else 'probe'
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        try:
            body = json.loads(raw)
            assert self.path == '/v1/responses'
            if mode == 'errors':
                assert self.headers.get('Authorization') == 'Bearer synthetic-error-key'
                assert self.headers.get('x-route-key') == 'synthetic-route-key'
                assert self.headers.get('x-session-id') == 'failure-integration'
                assert self.headers.get('x-turn-id') == 'failure-turn'
                assert body['model'] in ('http-failure', 'sse-failure')
                assert body['stream'] is True and body['store'] is False
                assert body.get('tools', []) == []
                assert body['metadata'] == {'session_id': 'failure-integration'}
                assert 'instructions' not in body
                assert body['input'] == [{'role':'developer','content':'Failure transport test'},{'role':'user','content':[{'type':'input_text','text':'Test this response failure'}]}]
                detail = {'code':'rate_limit_exceeded', 'message':'Rate limit reached. Retry later. Credential echoes: synthetic-error-key / synthetic-route-key.'}
                streaming = body['model'] == 'sse-failure'
                value = {'type':'response.failed','response':{'id':'failed-response','model':body['model'],'status':'failed','error':detail}} if streaming else {'error':detail}
                encoded = json.dumps(value, separators=(',', ':'))
                response = ('event: response.failed\r\ndata: ' + encoded + '\r\n\r\n').encode() if streaming else encoded.encode()
                record = {'request':base64.b64encode(raw).decode(),'response':base64.b64encode(response).decode()}
                (root / 'record.json').write_text(json.dumps(record))
                self.send_response(200 if streaming else 429)
                self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
                self.send_header('Content-Length', str(len(response))); self.end_headers()
                for start in range(0, len(response), 7):
                    self.wfile.write(response[start:start + 7]); self.wfile.flush()
                return
            assert self.headers.get('Authorization') == 'Bearer synthetic-probe-key'
            assert self.headers.get('x-session-id') == 'connection-test-fixture'
            assert self.headers.get('x-turn-id')
            assert body['model'] == 'owner-selected-router'
            assert body['stream'] is True and body['store'] is False
            assert body['max_output_tokens'] == 256
            assert body.get('tools', []) == []
            assert 'reasoning' not in body and 'include' not in body
            assert body['metadata'] == {'session_id': 'connection-test-fixture'}
            # Pi's system prompt leads the input: a system message to a model without reasoning.
            assert 'instructions' not in body
            assert body['input'] == [{'role':'system','content':'This is a connection test. Reply briefly with OK.'},{'role':'user','content':[{'type':'input_text','text':'Reply with OK to confirm this connection.'}]}]
        except (AssertionError, KeyError, ValueError):
            self.send_response(422); self.end_headers(); self.wfile.write(b'{"error":"invalid probe"}'); return
        response = json.dumps({'id':'response-probe','object':'response','status':'completed','model':body['model'],
            'output':[{'id':'message-probe','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'OK'}]}],
            'usage':{'input_tokens':12,'output_tokens':1,'total_tokens':13}}, separators=(',', ':')).encode()
        record = {'request':base64.b64encode(raw).decode(),'response':base64.b64encode(response).decode()}
        (root / 'record.json').write_text(json.dumps(record))
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response))); self.end_headers(); self.wfile.write(response)
server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port':server.server_port})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#
}

private actor ProbeClient: ModelClient {
    struct Call: Sendable { let profile: Profile; let messages: [ChatMessage]; let instructions: String; let purpose: String; let tools: Int }
    let result: Result<ModelReply, AgentError>, hold: Bool
    var calls: [Call] = [], cancelled = false
    init(_ result: Result<ModelReply, AgentError>, hold: Bool = false) { self.result = result; self.hold = hold }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        calls.append(Call(profile: profile, messages: messages, instructions: instructions, purpose: purpose, tools: tools.count))
        if hold { do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error } }
        return try result.get()
    }
}
