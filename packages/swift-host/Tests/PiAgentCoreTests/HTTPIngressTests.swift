import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PiAgentCore

private final class IngressFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let size = Int(request.url!.lastPathComponent)!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!, cacheStoragePolicy: .notAllowed)
        let small = request.url!.query == "small"
        let chunk = small ? 1024 : 32_768
        for start in stride(from: 0, to: size, by: chunk) {
            if small { Thread.sleep(forTimeInterval: 0.001) }
            client?.urlProtocol(self, didLoad: Data(repeating: small ? UInt8(start / chunk) : 97, count: min(chunk, size - start)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPIngressTests: XCTestCase {
    /// An HTTP/1.1 server that keeps connections alive, like a gateway.
    private static let keepAliveServer = """
    import http.server, json, os, sys
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body = b"data: {}\\n\\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream"); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(os.path.join(sys.argv[1], "ready.json"), "w") as ready: json.dump({"port": server.server_address[1]}, ready)
    server.serve_forever()
    """
    /// Model requests share one keep-alive session per gateway and
    /// credential: the second request goes out on the connection the first
    /// one opened, and another credential gets a session of its own.
    func testSequentialRequestsReuseOneSessionAndItsConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py")
        try Data(Self.keepAliveServer.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path, root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: ready))["port"].int)
        let pool = HTTPSessionPool()
        func send(_ turn: String, key: String = "fixture-key") async throws -> HTTPStream {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue(turn, forHTTPHeaderField: "x-turn-id")
            let stream = HTTPStream()
            var body = Data()
            for try await part in stream.start(request, pool: pool, connection: HTTPSessionPool.key(request, perRequest: ["x-turn-id"])) {
                if case .bytes(let bytes, _) = part { body.append(bytes); stream.consumed(bytes.count) }
            }
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "data: {}\n\n")
            XCTAssertEqual(stream.observation()["transportOutcome"].text, "eof")
            _ = await stream.endObservation()
            for _ in 0..<400 where stream.reusedConnection == nil { try await Task.sleep(for: .milliseconds(5)) }
            return stream
        }
        let first = try await send("t1"), second = try await send("t2")
        XCTAssertEqual(pool.created, 1, "One session serves both requests")
        XCTAssertEqual(first.reusedConnection, false)
        XCTAssertEqual(second.reusedConnection, true, "The second request reuses the first one's connection")
        _ = try await send("t3", key: "another-key")
        XCTAssertEqual(pool.created, 2, "Another credential gets a session of its own")
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IngressFixtureProtocol.self]
        return config
    }
    func testSlowConsumerRetainsExactOrderedBytesAndReturnsReservations() async throws {
        let budget = HTTPIngressBudget(limit: 4 * 1024 * 1024)
        let stream = HTTPStream(budget: budget)
        var bytes = Data()
        for try await part in stream.start(URLRequest(url: URL(string: "https://fixture.invalid/524288")!), configuration: configuration()) {
            if case .bytes(let data, _) = part {
                try await Task.sleep(for: .milliseconds(1))
                bytes.append(data); stream.consumed(data.count)
            }
        }
        XCTAssertEqual(bytes, Data(repeating: 97, count: 524_288))
        XCTAssertEqual(budget.accounting.used, 0)
        XCTAssertLessThanOrEqual(budget.accounting.peak, budget.limit)
        XCTAssertEqual(stream.observation()["transportOutcome"].text, "eof")
    }
    func testIngressRejectsOversizeBeforeConsumerCanClaimCompletion() async throws {
        let budget = HTTPIngressBudget(limit: 32_768)
        var stream: HTTPStream? = HTTPStream(budget: budget, bufferLimit: 32_768, responseLimit: 65_536)
        var received = Data()
        do {
            let parts = stream!.start(URLRequest(url: URL(string: "https://fixture.invalid/1048576")!), configuration: configuration())
            try await Task.sleep(for: .milliseconds(30))
            for try await part in parts {
                if case .bytes(let data, _) = part { received.append(data); stream!.consumed(data.count) }
            }
            XCTFail("An over-budget response must fail")
        } catch { XCTAssertTrue(error is AgentError) }
        _ = await stream!.endObservation()
        XCTAssertLessThanOrEqual(received.count, 32_768)
        XCTAssertEqual(received, Data(repeating: 97, count: received.count))
        XCTAssertLessThanOrEqual(budget.accounting.peak, 32_768)
        XCTAssertEqual(stream!.observation()["transportOutcome"].text, "error")
        stream = nil
        try await eventually { budget.accounting.used == 0 }
    }
    func testWorkspaceBudgetCannotBeExceededByTwentyConcurrentReservations() async {
        let budget = HTTPIngressBudget(limit: 1_048_576)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask {
                for _ in 0..<100 {
                    if budget.reserve(131_072) { await Task.yield(); budget.release(131_072) }
                }
            } }
        }
        XCTAssertEqual(budget.accounting.used, 0)
        XCTAssertLessThanOrEqual(budget.accounting.peak, budget.limit)
    }
    func testSlowRecorderCoalescesReceivedCallbacksWithoutChangingArrivalTimesOrBytes() async throws {
        let budget = HTTPIngressBudget(limit: 1_048_576)
        // Waiting before consuming simulates a durable recorder holding its
        // first ACK, while callbacks already in flight continue to arrive.
        let measured = HTTPStream(budget: budget)
        let parts = measured.start(URLRequest(url: URL(string: "https://fixture.invalid/65536?small")!), configuration: configuration())
        try await Task.sleep(for: .milliseconds(200))
        var bytes = Data(), batches = 0, times: [Double] = []
        for try await part in parts {
            if case .bytes(let data, let receivedAt) = part {
                batches += 1
                XCTAssertLessThanOrEqual(data.count, 32_768)
                times.append(measured.receivedAt(byteOffset: bytes.count + 1, fallback: receivedAt))
                times.append(measured.receivedAt(byteOffset: bytes.count + data.count, fallback: receivedAt))
                bytes.append(data); measured.consumed(data.count)
            }
        }
        let expected = (0..<64).reduce(into: Data()) { $0.append(Data(repeating: UInt8($1), count: 1024)) }
        XCTAssertEqual(bytes, expected)
        XCTAssertLessThanOrEqual(batches, 4, "64 received callbacks should not require 64 capture ACKs")
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(try XCTUnwrap(times.last) - XCTUnwrap(times.first), 20,
                             "Original callback times survive coalescing, independently of parse time")
        XCTAssertEqual(budget.accounting.used, 0)
        XCTAssertEqual(measured.observation()["responseObservedBytes"].int, bytes.count)
    }
}
