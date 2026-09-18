import XCTest
import Network
@testable import PiApp

final class GatewayModelDiscoveryTests: XCTestCase {
    func testModelsEndpointKeepsExactPrefixAndUsesSelectedAPIValidation() throws {
        for (api, leaf) in [("openai-responses", "responses")] {
            for prefix in ["", "/proxy", "/v10/team", "/proxy/v1/tenant"] {
                for suffix in ["", "/v1", "/v1/", "/v1/\(leaf)"] {
                    XCTAssertEqual(try GatewayModelDiscovery.modelsURL(base: "https://gateway.example" + prefix + suffix, api: api).absoluteString,
                                   "https://gateway.example" + prefix + "/v1/models")
                }
            }
            XCTAssertEqual(try GatewayModelDiscovery.modelsURL(base: "https://gateway.example/proxy/\(leaf)", api: api).path, "/proxy/models")
            for base in ["http://remote.example", "https://u:key@gateway.example", "https://gateway.example?key=secret",
                         "https://gateway.example#fragment", "https://gateway.example/v1/chat/completions", "https://gateway.example/a%2fb",
                         "https://gateway.example/a/../b", "https://gateway.example/v1/v1"] {
                XCTAssertThrowsError(try GatewayModelDiscovery.modelsURL(base: base, api: api))
            }
        }
        XCTAssertThrowsError(try GatewayModelDiscovery.modelsURL(base: "https://gateway.example/v1/messages", api: "openai-responses"))
        XCTAssertThrowsError(try GatewayModelDiscovery.modelsURL(base: "https://gateway.example", api: "anthropic-messages"))
    }

    func testBoundedModelParsingSortsDeduplicatesAndRejectsMalformedIDs() throws {
        let service = GatewayModelDiscovery(limits: .init(timeout: 1, bodyBytes: 4096, modelCount: 4))
        XCTAssertEqual(try service.parse(Data(#"{"data":[{"id":"router/z"},{"id":"a"},{"id":"router/z"}]}"#.utf8)), ["a", "router/z"])
        XCTAssertEqual(try service.parse(Data(#"{"data":[]}"#.utf8)), [])
        for malformed in [#"[]"#, #"{"data":{}}"#, #"{"data":[1]}"#, #"{"data":[{"id":2}]}"#,
                          #"{"data":[{"id":""}]}"#, #"{"data":[{"id":"a\nb"}]}"#,
                          "{\"data\":[{\"id\":\"" + String(repeating: "a", count: 257) + "\"}]}",
                          #"{"data":[{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"},{"id":"e"}]}"#] {
            XCTAssertThrowsError(try service.parse(Data(malformed.utf8)))
        }
        XCTAssertThrowsError(try service.parse(Data(repeating: 32, count: 4097))) { XCTAssertEqual($0 as? GatewayModelDiscovery.Failure, .oversized) }
    }

    func testRealGatewaySeesOnlySelectedPathAndExplicitAuthentication() async throws {
        let gateway = try ModelListGateway { _ in .json(#"{"data":[{"id":"auto-router"},{"id":"resolved-model"}]}"#) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        do { _ = try await GatewayModelDiscovery().models(base: base + "/v10/team/v1/messages", api: "anthropic-messages", key: "synthetic-only"); XCTFail("Retired API must fail before HTTP") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Only the Responses API")) }
        XCTAssertTrue(gateway.requests.isEmpty)
        let models = try await GatewayModelDiscovery().models(base: base + "/v10/team/v1/responses", api: "openai-responses", key: "synthetic-only")
        XCTAssertEqual(models, ["auto-router", "resolved-model"])
        let requests = gateway.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].hasPrefix("GET /v10/team/v1/models HTTP/1.1\r\n"))
        XCTAssertTrue(requests[0].lowercased().contains("authorization: bearer synthetic-only\r\n"))
        XCTAssertTrue(requests[0].lowercased().contains("accept: application/json\r\n"))
        XCTAssertFalse(requests[0].lowercased().contains("cookie:"))
    }

    func testRedirectCannotForwardKeyToAnotherGateway() async throws {
        let destination = try ModelListGateway { _ in .json(#"{"data":[{"id":"should-not-be-read"}]}"#) }
        defer { destination.stop() }
        let destinationURL = try await destination.start()
        let source = try ModelListGateway { _ in .init(bytes: Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: \(destinationURL)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
        defer { source.stop() }
        let base = try await source.start()
        do { _ = try await GatewayModelDiscovery().models(base: base, api: "openai-responses", key: "synthetic-redirect-key"); XCTFail("Redirect must be rejected") }
        catch { XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .redirected) }
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(destination.requests.count, 0)
    }

    func testSameOriginRedirectAlsoRequiresExplicitFinalEndpoint() async throws {
        let gateway = try ModelListGateway { _ in .init(bytes: Data("HTTP/1.1 302 Found\r\nLocation: /other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        do { _ = try await GatewayModelDiscovery().models(base: base, api: "openai-responses", key: "synthetic-key"); XCTFail("Redirect must be rejected") }
        catch { XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .redirected) }
        XCTAssertEqual(gateway.requests.count, 1)
    }

    func testStreamedAndDeclaredOversizedResponsesAreStopped() async throws {
        let service = GatewayModelDiscovery(limits: .init(timeout: 2, bodyBytes: 128, modelCount: 4))
        for declared in [false, true] {
            let gateway = try ModelListGateway { _ in
                let length = declared ? "Content-Length: 4096\r\n" : ""
                return .init(bytes: Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + length + "Connection: close\r\n\r\n" + String(repeating: "x", count: 4096)).utf8))
            }
            defer { gateway.stop() }
            let base = try await gateway.start()
            do { _ = try await service.models(base: base, api: "openai-responses", key: "synthetic-key"); XCTFail("Oversized body must fail") }
            catch { XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .oversized) }
        }
    }

    func testHTTPErrorDoesNotExposeGatewayResponseBody() async throws {
        let gateway = try ModelListGateway { _ in .init(bytes: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 18\r\nConnection: close\r\n\r\nsynthetic-test-key".utf8)) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        do { _ = try await GatewayModelDiscovery().models(base: base, api: "openai-responses", key: "synthetic-test-key"); XCTFail("HTTP error must fail") }
        catch {
            XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .http(403))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-test-key"))
        }
    }

    func testTimeoutBoundsStalledModelList() async throws {
        let gateway = try ModelListGateway { _ in nil }
        defer { gateway.stop() }
        let base = try await gateway.start(), began = Date()
        do { _ = try await GatewayModelDiscovery(limits: .init(timeout: 1)).models(base: base, api: "openai-responses", key: "synthetic-key"); XCTFail("Stalled response must time out") }
        catch { XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testInvalidCredentialIsRejectedBeforeNetworkRequest() async throws {
        let gateway = try ModelListGateway { _ in .json(#"{"data":[]}"#) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        for key in ["", "key\r\nInjected: value", String(repeating: "x", count: 16_385)] {
            do { _ = try await GatewayModelDiscovery().models(base: base, api: "openai-responses", key: key); XCTFail("Invalid credential must fail") }
            catch { XCTAssertEqual(error as? GatewayModelDiscovery.Failure, .credential) }
        }
        XCTAssertTrue(gateway.requests.isEmpty)
    }
}

/// Request-aware loopback fixture. It never reads real vaults or credentials.
final class ModelListGateway: @unchecked Sendable {
    struct Reply: Sendable {
        var bytes: Data
        static func json(_ text: String) -> Reply {
            let body = Data(text.utf8)
            return Reply(bytes: Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.OnboardingModelFixture")
    private let lock = NSLock()
    private var captured: [String] = []
    private var connections: [NWConnection] = []
    private let respond: @Sendable (String) -> Reply?
    var requests: [String] { lock.withLock { captured } }

    init(respond: @escaping @Sendable (String) -> Reply?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        let open = lock.withLock { connections }
        open.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard bytes.count <= 65_536, error == nil else { connection.cancel(); return }
            if let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") {
                self.lock.withLock { self.captured.append(request) }
                if let reply = self.respond(request) {
                    connection.send(content: reply.bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if !complete { self.receive(connection, previous: bytes) }
            else { connection.cancel() }
        }
    }
}
