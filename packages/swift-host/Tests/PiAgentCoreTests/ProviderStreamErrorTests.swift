import XCTest
@testable import PiAgentCore

/// A gateway whose upstream fails after the first token. LiteLLM's proxy ends
/// the Responses stream with a bare `{"error":…}` frame, one with no `type`,
/// and closes the connection.
final class ProviderStreamErrorTests: XCTestCase {
    static let gatewayScript = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        frames = [
            {'type':'response.created','response':{'id':'r1','status':'in_progress','output':[]}},
            {'type':'response.output_item.added','output_index':0,'item':{'type':'message','id':'m1','role':'assistant','content':[]}},
            {'type':'response.output_text.delta','output_index':0,'item_id':'m1','content_index':0,'delta':'Hel'},
            {'error':{'message':'Overloaded','type':'overloaded_error','param':None,'code':'529'}},
        ]
        body = b''.join(b'data: ' + json.dumps(f).encode() + b'\n\n' for f in frames)
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body); self.wfile.flush()
server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.json').write_text(json.dumps({'port': server.server_address[1]}))
server.serve_forever()
"""#

    func testBareErrorFrameAfterTheFirstTokenFailsWithTheProvidersReasonAndIsRetryable() async throws {
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
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(port)/v1")
        let traces = TraceStore(), client = ProviderClient(traces: traces)
        do {
            _ = try await client.complete(profile: Profile(raw), apiKey: "fixture", messages: [ChatMessage(role: "user", content: [textBlock("hello")])], instructions: "fixture", tools: [], sessionID: "s", turnID: "t", purpose: "turn", onDelta: { _ in })
            XCTFail("A failed upstream must reach the caller")
        } catch let error as AgentError {
            XCTAssertEqual(error.code, "provider_failed", error.message)
            XCTAssertTrue(error.message.contains("Overloaded"), "The provider's own reason is kept: \(error.message)")
            XCTAssertTrue(AgentSession.isRetryable(error), "An overloaded upstream is transient")
        }
        let attempt = try await traces.command("debug.list", session: "s", params: [:])["attempts"].list.first
        XCTAssertEqual(attempt?["modelOutcome"].text, "failed", "The provider reported a failure; the stream did not merely stop")
    }

    func testBareErrorFrameIsAFailureForTheAccumulatorToo() {
        var accumulator = ProviderAccumulator(api: "openai-responses")
        XCTAssertThrowsError(try accumulator.consume(["error": ["message": "Overloaded", "type": "overloaded_error"]])) { error in
            XCTAssertEqual((error as? AgentError)?.code, "provider_failed")
            XCTAssertTrue((error as? AgentError)?.message.contains("Overloaded") == true)
        }
        XCTAssertNoThrow(try accumulator.consume(["note": "a frame with neither type nor error is ignored"]))
    }
}
