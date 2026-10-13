import XCTest
@testable import PiAgentCore

final class SubagentToolTests: XCTestCase {
    func testSchemaRejectsExtraAuthorityAndInvalidNarrowingArguments() throws {
        for value: JSON in [["task":"work","cwd":"/other"], ["task":"work","apiKey":"secret"], ["task":"work","tools":["read","read"]], ["task":"work","tools":.null], ["task":" "], ["task":"work","model":4]] {
            XCTAssertThrowsError(try SubagentSpec(value))
        }
        XCTAssertNil(try SubagentSpec(["task":"work"]).tools)
        XCTAssertEqual(try SubagentSpec(["task":"work","tools":[]]).tools, [])
        XCTAssertThrowsError(try SubagentSpec(["task":JSON(String(repeating: "é", count: 131_073))]))
        let grapheme = "a" + String(repeating: "\u{301}", count: 500)
        XCTAssertLessThanOrEqual(try SubagentSpec(["task":JSON(grapheme)]).description.utf8.count, 480)
    }
    func testEnvelopeCutsAtAUTF8BoundaryAndCarriesOnlyModelFields() throws {
        let plan = SubagentPlan(origin: subagentFixtureOrigin(), task: "work", resultMessageID: "result")
        let result = SubagentToolResult(plan: plan, status: .outputLimited, text: String(repeating: "🙂", count: 20_000), messageIDs: ["answer"], accountingRevision: 4, began: true)
        XCTAssertEqual(result.envelope["text"].text?.utf8.count, 65_536)
        XCTAssertFalse(result.envelope["text"].text?.contains("�") ?? true)
        XCTAssertEqual(result.envelope["truncated"].flag, true)
        XCTAssertEqual(Set(result.envelope.map.keys), ["status", "text", "truncated"])
        XCTAssertEqual(result.metadata["sessionId"].text, "child")
        XCTAssertEqual(result.metadata["resultRef"]["messageIds"].list, ["answer"])
    }
    func testMCPInvocationCannotAdoptAWiderConfigurationAfterDelegation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let mcp = MCPManager(cwd: root), transport = FakeMCP()
        await mcp.installForTesting(name: "server", transport: transport)
        let base = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: mcp)
        let policy = await base.delegationMCPPolicy()
        let child = RestrictedTools(base: base, allowed: ["mcp"], readOnly: false, capabilities: ["mcp:server"], mcpPolicy: policy)
        try await mcp.configure(["servers":["server":["enabled":true,"transport":"stdio","command":"/usr/bin/false","allowedTools":["echo","new-tool"]]]])
        do {
            _ = try await child.invoke(ToolCall(id: "call", name: "mcp", arguments: ["action":"invoke","server":"server","tool":"echo","arguments":[:]]), readOnly: false)
            XCTFail("A changed MCP policy must be rejected before any invocation")
        } catch { XCTAssertEqual((error as? AgentError)?.code, "mcp_policy") }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
        await mcp.close()
    }
}
