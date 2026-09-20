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
        for start in stride(from: 0, to: size, by: 32_768) {
            client?.urlProtocol(self, didLoad: Data(repeating: 97, count: min(32_768, size - start)))
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
}
