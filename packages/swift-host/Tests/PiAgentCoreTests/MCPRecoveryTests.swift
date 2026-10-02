import XCTest
@testable import PiAgentCore

/// Real MCP servers (stdio and Streamable HTTP) that reject calls, forget
/// sessions, exit and change their catalogs. A call the server rejected
/// outright never ran and must not block the workspace; a connection that
/// died is set up again for the next call, never replaying the old one.
final class MCPRecoveryTests: XCTestCase {
    static let stdioServer = #"""
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
def log(name, text):
    with (state / name).open('a') as f: f.write(text + '\n')
log('starts.txt', 'start')
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method, mode = request['method'], ''
    reply = {'jsonrpc': '2.0', 'id': request['id']}
    if method == 'initialize':
        reply['result'] = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {'listChanged': True}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
    elif method == 'tools/list':
        log('lists.txt', 'list')
        reply['result'] = {'tools': [{'name': 'echo', 'description': 'Echo', 'inputSchema': {'type': 'object'}}]}
    elif method == 'tools/call':
        mode = request['params']['arguments'].get('mode', '')
        log('calls.txt', mode)
        if mode == 'reject': reply['error'] = {'code': -32602, 'message': 'Invalid params: text is required'}
        elif mode == 'internal': reply['error'] = {'code': -32603, 'message': 'Internal error'}
        else: reply['result'] = {'content': [{'type': 'text', 'text': 'echo ' + mode}], 'isError': False}
        if mode == 'changed': print(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'}), flush=True)
    else:
        reply['error'] = {'code': -32601, 'message': 'Unsupported'}
    print(json.dumps(reply), flush=True)
    if mode == 'exit': sys.exit(0)
"""#
    static let httpServer = #"""
import http.server, json, pathlib, sys, uuid
state = pathlib.Path(sys.argv[1]); sessions = set()
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
        method, sid = request.get('method'), self.headers.get('Mcp-Session-Id')
        with (state / 'http.txt').open('a') as f: f.write('%s %s\n' % (method, 'session' if sid else 'none'))
        if method == 'initialize':
            new = uuid.uuid4().hex; sessions.add(new)
            return self.reply(200, {'jsonrpc': '2.0', 'id': request['id'], 'result': {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}}}, {'Mcp-Session-Id': new})
        if sid not in sessions: return self.reply(404, {'error': 'unknown session'})
        if 'id' not in request: return self.reply(202)
        if method == 'tools/list':
            return self.reply(200, {'jsonrpc': '2.0', 'id': request['id'], 'result': {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}})
        mode = request['params']['arguments'].get('mode', '')
        if mode.startswith('status-'): return self.reply(int(mode[7:]), {'error': 'fixture'})
        self.reply(200, {'jsonrpc': '2.0', 'id': request['id'], 'result': {'content': [{'type': 'text', 'text': 'echo ' + mode}], 'isError': False}})
        if mode == 'restart': sessions.clear()
server = http.server.HTTPServer(('127.0.0.1', 0), MCP)
(state / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (state / 'ready.tmp').replace(state / 'ready.json')
server.serve_forever()
"""#

    /// Streamable HTTP over SSE, as a 2025-11-25 server sends it: each stream
    /// opens with a priming event (an id and empty data), then heartbeats and
    /// other data-less events, then the response, written a few bytes at a
    /// time. argv[2] is "all" to prime every request or "call" for tools/call.
    static let primingServer = #"""
import http.server, json, pathlib, random, sys, time
state, scope = pathlib.Path(sys.argv[1]), sys.argv[2]; counter = [0]
class MCP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = request.get('method')
        with (state / 'http.txt').open('a') as f: f.write('%s\n' % method)
        if 'id' not in request:
            self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
        mode = ''
        if method == 'initialize':
            result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'echo', 'inputSchema': {'type': 'object'}}]}
        else:
            mode = request['params']['arguments'].get('mode', '')
            with (state / 'calls.txt').open('a') as f: f.write(mode + '\n')
            result = {'content': [{'type': 'text', 'text': 'échø ✓ ' + mode}], 'isError': False}
        counter[0] += 1; n = counter[0]
        body = ''
        if scope == 'all' or method == 'tools/call':
            body += 'id: prime-%d\r\ndata:\r\n\r\n: heartbeat\n\nretry: 1000\n\ndata:   \n\ndata:\ndata:\n\n' % n
        if mode == 'notify': body += 'data: %s\n\n' % json.dumps({'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {'level': 'info', 'data': 'working'}})
        if mode == 'malformed': body += 'data: {"jsonrpc": "2.0", "id"\n\n'
        elif mode != 'eof': body += 'id: reply-%d\nevent: message\ndata: %s\n\n' % (n, json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}, ensure_ascii=False))
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        data, pieces, at = body.encode(), random.Random(n), 0
        while at < len(data):
            size = pieces.randint(1, 7); self.wfile.write(data[at:at + size]); self.wfile.flush(); at += size; time.sleep(0.0005)
server = http.server.HTTPServer(('127.0.0.1', 0), MCP)
(state / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (state / 'ready.tmp').replace(state / 'ready.json')
server.serve_forever()
"""#

    private func lines(_ root: URL, _ name: String) -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private func invoke(_ manager: MCPManager, _ mode: String) async throws -> JSON {
        try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": ["mode": JSON(mode)]])
    }
    private func stdio(_ root: URL, marker: URL) async throws -> MCPManager {
        let script = root.appendingPathComponent("server.py"); try Data(Self.stdioServer.utf8).write(to: script)
        let manager = MCPManager(cwd: root, outcomeMarker: marker)
        try await manager.configure(["servers": ["fixture": ["command": "/usr/bin/python3", "args": [JSON(script.path), JSON(root.path)], "timeoutSeconds": 5]]])
        return manager
    }

    func testAJSONRPCRejectionNeverRanAndDoesNotBlockTheWorkspace() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("unknown.json"), manager = try await stdio(root, marker: marker)
        do { _ = try await invoke(manager, "reject"); XCTFail("The rejection reaches the caller") }
        catch let error as AgentError {
            XCTAssertEqual(error.code, "mcp_rejected"); XCTAssertTrue(error.message.contains("-32602") && error.message.contains("not executed"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A rejected call leaves no unknown outcome, in memory or on disk")
        let unknown = try await manager.perform(["action": "list"])["outcomeUnknown"].flag
        XCTAssertEqual(unknown, false)
        let next = try await invoke(manager, "after")
        XCTAssertEqual(next["content"].list.first?["text"].text, "echo after", "the next call runs")
        // An internal error is not a rejection: the tool may have run.
        do { _ = try await invoke(manager, "internal"); XCTFail("The error reaches the caller") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        do { _ = try await invoke(manager, "blocked"); XCTFail("An unknown outcome still quarantines") }
        catch let error as AgentError { XCTAssertEqual(error.code, "mcp_outcome_unknown") }
        XCTAssertEqual(lines(root, "calls.txt"), ["reject", "after", "internal"])
        await manager.close()
    }

    func testAStdioServerThatExitedIsStartedAgainForTheNextCallAndListedAsDisconnected() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await stdio(root, marker: root.appendingPathComponent("unknown.json"))
        let first = try await invoke(manager, "exit")
        XCTAssertEqual(first["content"].list.first?["text"].text, "echo exit")
        try await eventually { await ((try? manager.perform(["action": "list"]))?["servers"].list.first?["connected"].flag) == false }
        let second = try await invoke(manager, "again")
        XCTAssertEqual(second["content"].list.first?["text"].text, "echo again", "a new process answers the next call")
        XCTAssertEqual(lines(root, "starts.txt").count, 2)
        XCTAssertEqual(lines(root, "calls.txt"), ["exit", "again"], "the call that already ran is never replayed")
        let connected = try await manager.perform(["action": "list"])["servers"].list.first?["connected"].flag
        XCTAssertEqual(connected, true)
        await manager.close()
    }

    func testTheToolCatalogIsListedOncePerConnectionUntilTheServerSaysItChanged() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await stdio(root, marker: root.appendingPathComponent("unknown.json"))
        for index in 0..<5 { _ = try await invoke(manager, "call-\(index)") }
        XCTAssertEqual(lines(root, "lists.txt").count, 1, "five invocations on one connection list the catalog once")
        _ = try await invoke(manager, "changed")
        _ = try await invoke(manager, "after-change")
        XCTAssertEqual(lines(root, "lists.txt").count, 2, "a list_changed notification lists it again")
        _ = try await invoke(manager, "exit")
        try await eventually { await ((try? manager.perform(["action": "list"]))?["servers"].list.first?["connected"].flag) == false }
        _ = try await invoke(manager, "reconnected")
        XCTAssertEqual(lines(root, "lists.txt").count, 3, "a new connection lists its own catalog")
        await manager.close()
    }

    func testHTTPRejectionsNeverRanAndAForgottenSessionIsSetUpAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mcp_http_fixture.py"); try Data(Self.httpServer.utf8).write(to: script)
        let gateway = try await PythonGateway.start(script: script, root: root); defer { gateway.stop() }
        let port = gateway.port
        let marker = root.appendingPathComponent("unknown.json"), manager = MCPManager(cwd: root, outcomeMarker: marker)
        try await manager.configure(["servers": ["fixture": ["url": JSON("http://127.0.0.1:\(port)/mcp")]]])
        for status in [400, 403, 429] {
            do { _ = try await invoke(manager, "status-\(status)"); XCTFail("HTTP \(status) reaches the caller") }
            catch let error as AgentError { XCTAssertEqual(error.code, "mcp_rejected", "HTTP \(status): \(error.message)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "HTTP \(status) was not executed")
        }
        _ = try await invoke(manager, "restart")
        let answer = try await invoke(manager, "after-restart")
        XCTAssertEqual(answer["content"].list.first?["text"].text, "echo after-restart", "a forgotten session is initialized again and the call sent once more")
        XCTAssertEqual(lines(root, "http.txt").filter { $0.hasPrefix("initialize") }.count, 2)
        do { _ = try await invoke(manager, "status-500"); XCTFail("HTTP 500 reaches the caller") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a server failure may have run the tool")
        await manager.close()
    }

    /// Finding 10: a priming event is not a message. Every call answers once,
    /// whatever byte boundaries the stream arrives in, and a stream that ends
    /// after priming, or carries malformed data, is never replayed.
    func testPrimedSSEStreamsAnswerEachCallOnceAndNeverReplay() async throws {
        for scope in ["call", "all"] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("mcp_priming_fixture.py"); try Data(Self.primingServer.utf8).write(to: script)
            let gateway = try await PythonGateway.start(script: script, root: root, arguments: [scope]); defer { gateway.stop() }
            let marker = root.appendingPathComponent("unknown.json"), manager = MCPManager(cwd: root, outcomeMarker: marker)
            try await manager.configure(["servers": ["fixture": ["url": JSON("\(gateway.base)/mcp")]]])
            let modes = (1...6).map { "ok-\($0)" } + ["notify"]
            for mode in modes {
                let answer = try await invoke(manager, mode)
                XCTAssertEqual(answer["content"].list.first?["text"].text, "échø ✓ \(mode)", "\(scope): \(mode)")
            }
            XCTAssertEqual(lines(root, "calls.txt"), modes, "\(scope): each call reached the server exactly once")
            XCTAssertEqual(lines(root, "http.txt").filter { $0 == "initialize" }.count, 1, "\(scope): one connection served every call")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(scope): answered calls leave no unknown outcome")
            let listed = try await manager.perform(["action": "list"]); XCTAssertEqual(listed["outcomeUnknown"].flag, false)
            for (mode, code) in [("malformed", "invalid_json"), ("eof", "mcp_incomplete")] {
                do { _ = try await invoke(manager, mode); XCTFail("\(scope): \(mode) answered") }
                catch let error as AgentError { XCTAssertEqual(error.code, code, error.message) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "\(scope): \(mode) may have run")
                try await manager.acknowledgeUnknown()
            }
            XCTAssertEqual(lines(root, "calls.txt"), modes + ["malformed", "eof"], "\(scope): a failed call is never replayed")
            await manager.close()
        }
    }

    /// The same stream split at every byte boundary, and fed a byte at a
    /// time, carries exactly the one response.
    func testAPrimedStreamYieldsOneMessageAtEveryByteBoundary() throws {
        let stream = Data(("id: prime\r\ndata:\r\n\r\n: heartbeat\n\nretry: 1000\n\ndata:   \n\ndata:\ndata:\n\n"
            + "id: reply\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"7\",\"result\":{\"text\":\"échø ✓\"}}\n\n").utf8)
        func messages(_ parts: [Data]) throws -> [JSON] {
            var parser = SSEParser(); return try parts.flatMap { try parser.feed($0) }.compactMap { try HTTPMCP.message($0) }
        }
        for split in 0...stream.count {
            let found = try messages([stream.prefix(split), stream.dropFirst(split)].map { Data($0) })
            XCTAssertEqual(found.count, 1, "split at \(split)"); XCTAssertEqual(found.first?["result"]["text"].text, "échø ✓", "split at \(split)")
        }
        XCTAssertEqual(try messages(stream.map { Data([$0]) }).map { $0["id"].text }, ["7"])
        var parser = SSEParser()
        XCTAssertThrowsError(try parser.feed(Data("data: {\"jsonrpc\"\n\n".utf8)).forEach { _ = try HTTPMCP.message($0) }, "malformed data is still an error")
    }
}
