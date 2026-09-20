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
