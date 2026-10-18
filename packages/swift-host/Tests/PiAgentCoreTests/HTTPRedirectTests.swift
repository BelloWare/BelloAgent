import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PiAgentCore

final class HTTPRedirectTests: XCTestCase {
    private static let server = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
target = sys.argv[2] if len(sys.argv) > 2 else None
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        with (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'body': body, 'headers': dict(self.headers)}) + '\n')
        code = int(self.path.strip('/')) if target else 200
        self.send_response(code)
        if target: self.send_header('Location', target + '/collect')
        self.send_header('Content-Length', '0'); self.end_headers()
    do_GET = do_POST
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#

    func testPooledModelAndUnpooledHTTPStreamsRefuseEveryRedirect() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sinkRoot = root.appendingPathComponent("sink"), sourceRoot = root.appendingPathComponent("source")
        for folder in [sinkRoot, sourceRoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sink = try await PythonGateway.start(source: Self.server, root: sinkRoot); defer { sink.stop() }
        let source = try await PythonGateway.start(source: Self.server, root: sourceRoot, arguments: [sink.base]); defer { source.stop() }
        let pool = HTTPSessionPool()
        for pooled in [false, true] {
            for code in [301, 302, 303, 307, 308] {
                var request = URLRequest(url: URL(string: source.base + "/\(code)")!)
                request.httpMethod = "POST"; request.httpBody = Data(#"{"request":"generated private text"}"#.utf8)
                request.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
                request.setValue("fixture-header", forHTTPHeaderField: "X-Private")
                let stream = HTTPStream()
                var status: Int?
                for try await part in stream.start(request, pool: pooled ? pool : nil) {
                    switch part {
                    case .head(let code, _): status = code
                    case .bytes(let bytes, _): stream.consumed(bytes.count)
                    }
                }
                XCTAssertEqual(status, code, "pooled: \(pooled)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: sinkRoot.appendingPathComponent("requests.jsonl").path), "pooled: \(pooled), HTTP \(code)")
            }
        }
        let requests = try String(contentsOf: sourceRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(requests.count, 10)
        XCTAssertTrue(requests.allSatisfy { $0.contains("generated private text") && $0.contains("fixture-key") && $0.contains("fixture-header") })
    }

    func testHTTPMCPRefusesRedirectBeforeForwardingItsHeadersAndRPCBody() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sinkRoot = root.appendingPathComponent("sink"), sourceRoot = root.appendingPathComponent("source")
        for folder in [sinkRoot, sourceRoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sink = try await PythonGateway.start(source: Self.server, root: sinkRoot); defer { sink.stop() }
        let source = try await PythonGateway.start(source: Self.server, root: sourceRoot, arguments: [sink.base]); defer { source.stop() }
        for code in [307, 308] {
            let manager = MCPManager(cwd: root)
            try await manager.configure(["servers": ["fixture": ["url": JSON(source.base + "/\(code)"),
                "headers": ["Authorization": "Bearer fixture-key", "X-Private": "fixture-header"], "timeoutSeconds": 3]]])
            do { _ = try await manager.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": ["text": "generated private text"]]); XCTFail("Redirect must fail") }
            catch { XCTAssertTrue(String(describing: error).contains("\(code)"), "\(error)") }
            await manager.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: sinkRoot.appendingPathComponent("requests.jsonl").path))
        }
        let requests = try String(contentsOf: sourceRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.contains("initialize") && $0.contains("fixture-key") && $0.contains("fixture-header") })
    }
}
