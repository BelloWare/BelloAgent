import XCTest
@testable import PiAgentCore

/// BUG-002 (review 2026-10-16): in MCP 2025-06-18 and 2025-11-25 either party
/// may ping, and the receiver must answer with an empty result. Over
/// Streamable HTTP a server may send that request on a call's response
/// stream, and the client answers in a new POST. The loopback server below
/// pings during `tools/call` and holds the call's result until the answer
/// arrives, so a client that does not answer, or answers on the wrong
/// channel, never gets it.
final class HTTPMCPPingTests: XCTestCase {
    private static let server = #"""
import http.server, json, pathlib, sys, threading, time
state = pathlib.Path(sys.argv[1]); answered = threading.Event()
def log(text):
    with (state / 'http.txt').open('a') as f: f.write(text + '\n')
class MCP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body=None, headers={}):
        data = json.dumps(body).encode() if body is not None else b''
        self.send_response(status)
        for key, value in headers.items(): self.send_header(key, value)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = request.get('method')
        if method is None:
            log('response %s %s %s %s' % (request.get('id'), json.dumps(request.get('result')), self.headers.get('Mcp-Session-Id'), self.headers.get('MCP-Protocol-Version')))
            if request.get('id') == 'server-ping-1' and request.get('result') == {}: answered.set()
            return self.reply(202)
        log(method)
        if method == 'initialize':
            return self.reply(200, {'jsonrpc': '2.0', 'id': request['id'], 'result': {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}}}, {'Mcp-Session-Id': 'fixture-session'})
        if 'id' not in request: return self.reply(202)
        if method == 'tools/list':
            return self.reply(200, {'jsonrpc': '2.0', 'id': request['id'], 'result': {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}})
        mode = request['params']['arguments'].get('mode', '')
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def event(value): self.wfile.write(b'data: ' + json.dumps(value).encode() + b'\n\n'); self.wfile.flush()
        if mode == 'ping':
            answered.clear()
            event({'jsonrpc': '2.0', 'id': 'server-ping-1', 'method': 'ping'})
            log('pinged ' + ('answered' if answered.wait(5) else 'unanswered'))
        event({'jsonrpc': '2.0', 'id': request['id'], 'result': {'content': [{'type': 'text', 'text': 'echo ' + mode}], 'isError': False}})
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MCP)
(state / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (state / 'ready.tmp').replace(state / 'ready.json')
server.serve_forever()
"""#

    func testAServerPingDuringACallIsAnsweredAndTheCallCompletes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.server, root: root); defer { gateway.stop() }
        let marker = root.appendingPathComponent("unknown.json"), manager = MCPManager(cwd: root, outcomeMarker: marker)
        try await manager.configure(["servers": ["fixture": ["url": JSON(gateway.base + "/mcp"), "timeoutSeconds": 10]]])
        let first = try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": ["mode": "ping"]])
        XCTAssertEqual(first["content"].list.first?["text"].text, "echo ping", "the original stream is still read after the ping")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "an answered ping leaves no unknown outcome")
        let listed = try await manager.perform(["action": "list"])
        XCTAssertEqual(listed["outcomeUnknown"].flag, false)
        let next = try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": ["mode": "after"]])
        XCTAssertEqual(next["content"].list.first?["text"].text, "echo after", "a later call is admitted without acknowledgement")
        let log = try String(contentsOf: root.appendingPathComponent("http.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(log.contains("response server-ping-1 {} fixture-session 2025-06-18"), "the empty result goes in its own POST, in the session, at the negotiated version: \(log)")
        XCTAssertTrue(log.contains("pinged answered"), "\(log)")
        XCTAssertEqual(log.filter { $0 == "tools/call" }.count, 2, "no call is replayed")
        await manager.close()
    }
}
