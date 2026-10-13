import XCTest
@testable import PiAgentCore

/// A live connection can keep producing bytes without ever answering. The
/// configured deadline bounds each exchange, including setup and notifications.
final class HTTPMCPDeadlineTests: XCTestCase {
    private static let server = #"""
import http.server, json, pathlib, sys, time
state, phase, format = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
class MCP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = request['method']
        with (state / 'requests.txt').open('a') as f: f.write(method + '\n')
        if method == phase:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream' if format == 'sse' else 'application/json')
            self.end_headers()
            try:
                while True:
                    self.wfile.write(b': heartbeat\n\nid: primed\ndata:\n\n' if format == 'sse' else b' ')
                    self.wfile.flush(); time.sleep(0.025)
            except OSError:
                (state / 'disconnected').touch()
            return
        if 'id' not in request:
            self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
        result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}} if method == 'initialize' else {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}
        data = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MCP)
(state / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (state / 'ready.tmp').replace(state / 'ready.json')
server.serve_forever()
"""#

    private func deadline(phase: String, format: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: Self.server, root: root, arguments: [phase, format]); defer { gateway.stop() }
        let marker = root.appendingPathComponent("unknown.json"), manager = MCPManager(cwd: root, outcomeMarker: marker)
        try await manager.configure(["servers": ["fixture": ["url": JSON(gateway.base + "/mcp"), "timeoutSeconds": 1]]])
        let began = ContinuousClock.now
        let call = Task { try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": [:]]) }
        // Bound a broken implementation too: this cancellation must never be
        // what ends the call once the request deadline is enforced.
        let backstop = Task { try await Task.sleep(for: .seconds(3)); call.cancel() }
        defer { backstop.cancel() }
        do { _ = try await call.value; XCTFail("The fixture never answers") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "mcp_timeout", "\(phase), \(format): \(error)") }
        XCTAssertGreaterThanOrEqual(began.duration(to: .now), .milliseconds(750))
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(2500), "Keep-alive bytes must not renew the deadline")
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("disconnected").path) }
        let dispatched = phase == "tools/call"
        XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), dispatched)
        let listed = try await manager.perform(["action": "list"])
        XCTAssertEqual(listed["outcomeUnknown"].flag, dispatched)
        if dispatched {
            let restarted = MCPManager(cwd: root, outcomeMarker: marker)
            let recovered = try await restarted.perform(["action": "list"])
            XCTAssertEqual(recovered["outcomeUnknown"].flag, true, "An expired call may have completed remotely")
            do { _ = try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": [:]]); XCTFail("An unknown call must not be replayed") }
            catch let error as AgentError { XCTAssertEqual(error.code, "mcp_outcome_unknown") }
        }
        let requests = try String(contentsOf: root.appendingPathComponent("requests.txt"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(requests.filter { $0 == Substring(phase) }.count, 1)
        await manager.close()
    }

    func testHeartbeatsAndKeepAliveBytesCannotExtendTheInvocationDeadline() async throws {
        for format in ["sse", "json"] { try await deadline(phase: "tools/call", format: format) }
    }
    func testSetupAndNotificationEachHaveADeadline() async throws {
        for phase in ["initialize", "notifications/initialized", "tools/list"] { try await deadline(phase: phase, format: "sse") }
    }
}
