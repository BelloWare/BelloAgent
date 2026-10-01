import XCTest
@testable import PiAgentCore

/// A chat moved to another saved connection: the helper never answers an
/// open on the new connection with the session loaded on the old one.
final class ConnectionSwitchTests: XCTestCase {
    func testAnOpenOnAnotherConnectionIsNotAnsweredByTheLoadedSession() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        let original = try fixtureProfile().raw
        _ = try await host.command("session.open", sessionID: "chat", params: ["profile": original, "apiKey": "synthetic", "toolMode": "read-only"])
        var other = original; other["id"] = "other-connection"
        do {
            _ = try await host.command("session.open", sessionID: "chat", params: ["profile": other, "apiKey": "synthetic", "toolMode": "read-only"])
            XCTFail("The session loaded on the first connection must not answer an open on the second")
        } catch let error as AgentError { XCTAssertEqual(error.code, "session_conflict") }
        let again = try await host.command("session.open", sessionID: "chat", params: ["profile": original, "apiKey": "synthetic", "toolMode": "read-only"])
        XCTAssertEqual(again["profileId"].text, original["id"].text)
        await host.shutdown()
    }
}
