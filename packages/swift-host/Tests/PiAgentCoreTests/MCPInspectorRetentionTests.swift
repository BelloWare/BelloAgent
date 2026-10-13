import XCTest
@testable import PiAgentCore

/// The writer has the reply but the app has not received it. Keep a copy of
/// exactly the marker a crash in that window would leave for the next helper.
private final class InspectorReplyProbe: @unchecked Sendable {
    let marker: URL, crashCopy: URL
    private let lock = NSLock()
    private var reply: JSON?
    private(set) var markerAtReply = false
    init(_ root: URL) { marker = root.appendingPathComponent("state/.mcp-outcome-unknown.json"); crashCopy = root.appendingPathComponent("crash.json") }
    func emit(_ frame: JSON) {
        guard frame["kind"].text == "reply", frame["commandId"].text == "inspector-call" else { return }
        lock.lock(); defer { lock.unlock() }
        markerAtReply = FileManager.default.fileExists(atPath: marker.path)
        if markerAtReply { try? FileManager.default.copyItem(at: marker, to: crashCopy) }
        reply = frame
    }
    var received: JSON? { lock.lock(); defer { lock.unlock() }; return reply }
}

final class MCPInspectorRetentionTests: XCTestCase {
    private func completed(_ root: URL) async throws -> (NativeHostService, InspectorReplyProbe) {
        let script = root.appendingPathComponent("server.py"); try Data(MCPRecoveryTests.stdioServer.utf8).write(to: script)
        let probe = InspectorReplyProbe(root), host = NativeHostService(emit: { probe.emit($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1])
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path),
            "mcp": ["servers": ["fixture": ["command": "/usr/bin/python3", "args": [JSON(script.path), JSON(root.path)], "timeoutSeconds": 2]]]])
        _ = try await host.command("session.open", sessionID: "chat", params: ["profile": try fixtureProfile().raw, "apiKey": "fixture"])
        await host.receive(["v": 1, "kind": "command", "hostEpoch": JSON(host.epoch), "commandId": "inspector-call", "method": "mcp.invoke", "sessionId": "chat",
            "params": ["server": "fixture", "tool": "echo", "arguments": ["mode": "inspector"]]])
        try await eventually { probe.received != nil }
        XCTAssertEqual(probe.received?["ok"].flag, true)
        XCTAssertTrue(probe.markerAtReply, "Emitting a reply is not evidence the app kept it")
        return (host, probe)
    }

    func testACrashBeforeTheAppReceivesTheResultLeavesRecoveryBlocked() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (host, probe) = try await completed(root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.marker.path))
        let restarted = MCPManager(cwd: root, outcomeMarker: probe.crashCopy)
        let recovered = try await restarted.perform(["action": "list"])
        XCTAssertEqual(recovered["outcomeUnknown"].flag, true)
        do { _ = try await restarted.perform(["action": "invoke", "server": "fixture", "tool": "echo", "arguments": [:]]); XCTFail("Do not replay the completed call") }
        catch let error as AgentError { XCTAssertEqual(error.code, "mcp_outcome_unknown") }
        // An unrelated acknowledgement cannot discharge this result.
        _ = try await host.command("mcp.resultRetained", sessionID: nil, params: ["commandId": "other", "retained": true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.marker.path))
        _ = try await host.command("mcp.resultRetained", sessionID: nil, params: ["commandId": "other", "retained": false])
        let listed = try await host.command("mcp.list", sessionID: nil, params: [:])
        XCTAssertEqual(listed["outcomeUnknown"].flag, false, "Only a matching result can report lost retention")
        _ = try await host.command("mcp.resultRetained", sessionID: nil, params: ["commandId": "inspector-call", "retained": true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.marker.path))
        await host.shutdown()
    }

    func testAFailedAppSaveLeavesTheInspectorOutcomeUnknown() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (host, probe) = try await completed(root)
        _ = try await host.command("mcp.resultRetained", sessionID: nil, params: ["commandId": "inspector-call", "retained": false])
        let listed = try await host.command("mcp.list", sessionID: nil, params: [:])
        XCTAssertEqual(listed["outcomeUnknown"].flag, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.marker.path))
        _ = try await host.command("mcp.resultRetained", sessionID: nil, params: ["commandId": "inspector-call", "retained": true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.marker.path), "A late success cannot erase a failed retention")
        await host.shutdown()
    }
}
