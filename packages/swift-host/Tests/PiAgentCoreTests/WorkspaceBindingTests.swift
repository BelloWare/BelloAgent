import XCTest
@testable import PiAgentCore

/// A refused workspace configuration must leave the host bound to nothing, so
/// the next open starts clean instead of inheriting half of the last attempt.
final class WorkspaceBindingTests: XCTestCase {
    func testInvalidWorkspaceConfigurationCannotPartiallyBindAHost() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        var parameters: JSON = ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("first-state").path), "mcp": ["servers": ["bad": ["transport": "stdio", "command": "/usr/bin/true", "inheritEnv": ["SECRET"]]]]]
        do { _ = try await host.command("workspace.open", sessionID: nil, params: parameters); XCTFail("Reject inherited credentials") } catch { }
        parameters["directory"] = JSON(root.appendingPathComponent("second-state").path)
        parameters["mcp"] = ["servers": [:]]
        let opened = try await host.command("workspace.open", sessionID: nil, params: parameters)
        XCTAssertEqual(opened["directory"].text, root.appendingPathComponent("second-state").path)
        parameters["resources"] = ["mcpConfigPath": "retired.json"]
        do { _ = try await host.command("workspace.open", sessionID: nil, params: parameters); XCTFail("Even already-open hosts reject retired configuration") } catch { }
        await host.shutdown()
    }
}
