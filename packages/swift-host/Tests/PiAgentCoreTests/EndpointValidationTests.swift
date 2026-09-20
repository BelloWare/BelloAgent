import XCTest
@testable import PiAgentCore

/// What a connection may point at: the route a base URL resolves to, and the
/// URLs that are refused before any request is built.
final class EndpointValidationTests: XCTestCase {
    func testEndpointsAndUnsafeURLs() throws {
        XCTAssertEqual(try fixtureProfile().endpoint.absoluteString,"http://127.0.0.1:12345/v1/responses")
        XCTAssertThrowsError(try fixtureProfile("anthropic-messages")) { XCTAssertEqual(($0 as? AgentError)?.code, "unsupported_api") }
        var raw=try fixtureProfile().raw;raw["baseUrl"]="http://remote.example/v1";XCTAssertThrowsError(try Profile(raw))
        raw["baseUrl"]="https://user:pass@example.com/v1";XCTAssertThrowsError(try Profile(raw))
    }
    func testLiteLLMOnlyCredentialsAndEndpointRoutes() throws {
        let original = try fixtureProfile().raw
        let leaf = "responses"
        for prefix in ["", "/prefix"] {
            var value = original; value["baseUrl"] = JSON("https://gateway.example" + prefix + "/" + leaf)
            XCTAssertEqual(try Profile(value).endpoint.path, prefix + "/" + leaf)
        }
        for route in ["/v1/v1", "/chat/completions", "/a%2fb", "/a/../b", "/messages/responses"] {
            var value = original; value["baseUrl"] = JSON("https://gateway.example" + route)
            XCTAssertThrowsError(try Profile(value))
        }
        XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(original), supplied: nil))
        for field in ["source", "apiKeyEnv", "authHeader"] {
            var value = original; value[field] = "external-reference"
            XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(value), supplied: "synthetic"))
        }
        var direct = original; direct["providerId"] = "openai"
        XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(direct), supplied: "synthetic"))
        for separator in ["\r", "\n", "\r\n", "\0"] {
            XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(original), supplied: "synthetic" + separator + "injection"))
        }
    }
}
