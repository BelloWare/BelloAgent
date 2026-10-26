import XCTest
@testable import PiAgentCore

final class SubagentPermissionTests: HelperTestCase {
    func testRestrictedExecutorRejectsForgedCallsAndCannotWidenReadOnlyPermissions() async throws {
        let base = PermissionTools()
        let tools = RestrictedTools(base: base, allowed: ["read", "write", "mcp", "subagent"], readOnly: true, capabilities: ["mcp:allowed"])
        let names = await tools.definitions(readOnly: false).map(\.name)
        XCTAssertEqual(names, ["read", "mcp"])
        for name in ["write", "bash", "subagent"] {
            do { _ = try await tools.invoke(ToolCall(id: name, name: name, arguments: [:]), readOnly: false); XCTFail("Forged call ran") }
            catch { XCTAssertEqual((error as? AgentError)?.code, "tool_unavailable") }
        }
        let calls = await base.calls
        XCTAssertTrue(calls.isEmpty)
        let empty = RestrictedTools(base: base, allowed: [], readOnly: false, capabilities: ["mcp:allowed"])
        let capabilities = await empty.capabilityIDs(readOnly: false)
        XCTAssertTrue(capabilities.isEmpty)
    }

    func testLaterRestrictionAppliesWithoutExpandingTheFrozenGrant() async throws {
        let base = PermissionTools()
        let tools = RestrictedTools(base: base, allowed: ["read"], readOnly: false, capabilities: [])
        await base.removeRead()
        do { _ = try await tools.invoke(ToolCall(id: "call", name: "read", arguments: [:]), readOnly: false); XCTFail("Revoked tool ran") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "tool_unavailable") }
    }

    func testMCPGrantAndRetentionDoNotCrossChildrenWithTheSameCallID() async throws {
        let base = PermissionTools()
        let a = RestrictedTools(base: base, allowed: ["mcp"], readOnly: false, capabilities: ["mcp:allowed"])
        let b = RestrictedTools(base: base, allowed: ["mcp"], readOnly: false, capabilities: ["mcp:allowed"])
        do { _ = try await a.invoke(ToolCall(id: "same", name: "mcp", arguments: ["action":"invoke", "server":"forbidden"]), readOnly: false); XCTFail("Foreign server ran") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "mcp_server") }
        let call = ToolCall(id: "same", name: "mcp", arguments: ["action":"invoke", "server":"allowed"])
        _ = try await a.invoke(call, readOnly: false)
        _ = try await b.invoke(call, readOnly: false)
        await a.resultsRetained(["same"], retained: true)
        let calls = await base.calls, retained = await base.retained
        XCTAssertEqual(calls.count, 2); XCTAssertNotEqual(calls[0], calls[1])
        XCTAssertEqual(retained, [calls[0]])
        let listing = try await a.invoke(ToolCall(id: "list", name: "mcp", arguments: ["action":"list"]), readOnly: false)
        XCTAssertEqual(listing["servers"].list.compactMap { $0["server"].text }, ["allowed"])
    }

    func testThrownMCPInvocationDropsItsRetentionTokenWithoutClaimingAnOutcome() async throws {
        let base = PermissionTools(); await base.failInvocations()
        let tools = RestrictedTools(base: base, allowed: ["mcp"], readOnly: false, capabilities: ["mcp:allowed"])
        do { _ = try await tools.invoke(ToolCall(id: "failed", name: "mcp", arguments: ["server":"allowed"]), readOnly: false); XCTFail("Expected failure") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "fixture_unknown") }
        await tools.resultsRetained(["failed"], retained: true)
        let retained = await base.retained
        XCTAssertTrue(retained.isEmpty, "A thrown invocation has no retained result; its unknown-outcome marker must stay")
    }

    func testMCPDiscoveryDoesNotRetainInvocationTokens() async throws {
        let base = PermissionTools()
        let tools = RestrictedTools(base: base, allowed: ["mcp"], readOnly: true, capabilities: ["mcp:allowed"])
        let ids = (0..<100).map { "discovery-\($0)" }
        for (index, id) in ids.enumerated() {
            _ = try await tools.invoke(ToolCall(id: id, name: "mcp", arguments: ["action":JSON(index % 2 == 0 ? "list" : "describe"), "server":"allowed"]), readOnly: true)
        }
        await tools.resultsRetained(ids, retained: true)
        let retained = await base.retained
        XCTAssertTrue(retained.isEmpty, "Discovery must not retain mappings or acknowledge invocation outcomes")
    }

    func testOfferedModelUsesItsGrantAndOmittedModelInheritsParent() throws {
        let parent = try fixtureProfile()
        XCTAssertEqual(try SubagentModelGrant.resolve(nil, parent: parent, grants: []).1.raw, parent.raw)
        let grant = SubagentModelGrant(model: "offered", thinkingLevel: "default", contextWindow: 64000, maxOutputTokens: 4000)
        let chosen = try SubagentModelGrant.resolve("offered", parent: parent, grants: [grant]).1
        XCTAssertEqual(chosen.id, parent.id); XCTAssertEqual(chosen.endpoint, parent.endpoint)
        XCTAssertEqual(chosen.model, "offered"); XCTAssertEqual(chosen.maxOutput, 4000)
    }

    func testNotOfferedModelInheritsParentsExactProfile() throws {
        var raw = try fixtureProfile().raw
        raw["headers"] = ["X-Region":"fixture-region"]
        raw["routing"] = ["replayPolicy":"pinned", "expectedModel":"fixture-model", "replayContract":"fixture-stable"]
        let parent = try Profile(raw)
        for grants in [[], [SubagentModelGrant(model: "offered")]] {
            let (grant, chosen) = try SubagentModelGrant.resolve("not-offered", parent: parent, grants: grants)
            XCTAssertEqual(grant, .inherited(parent))
            XCTAssertEqual(chosen.raw, parent.raw, "Fallback preserves the parent's connection, route, headers and model settings")
            XCTAssertEqual(try SubagentModelGrant.childModel("not-offered", parent: parent, grants: grants),
                           try SubagentModelGrant.childModel(nil, parent: parent, grants: grants))
        }
    }

    func testParentsOwnModelWorksWithoutACatalogGrant() throws {
        let parent = try fixtureProfile()
        for grants in [[], [SubagentModelGrant(model: "other")]] {
            let (grant, chosen) = try SubagentModelGrant.resolve(parent.model, parent: parent, grants: grants)
            XCTAssertEqual(grant, .inherited(parent))
            XCTAssertEqual(chosen.raw, parent.raw)
            XCTAssertNil(grant.fallbackNotice(requested: parent.model))
        }
    }

    func testManagedChildRefusesIndependentSubmissionAndConfiguration() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile()
        let child = try AgentSession(id: "child", profile: profile, apiKey: "fixture", cwd: root, directory: root,
                                     readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                                     tools: DisabledTools(), traces: TraceStore(), prepared: nil, subagentOrigin: subagentFixtureOrigin())
        do {
            _ = try await child.configure(profile: profile, apiKey: "another")
            XCTFail("A child must not accept independent connection settings")
        } catch { XCTAssertEqual((error as? AgentError)?.code, "managed_subagent") }
        do {
            _ = try await child.submit(Submission(commandID: "command", turnID: "task", text: "independent task"), steer: false)
            XCTFail("A child must not accept user input")
        } catch { XCTAssertEqual((error as? AgentError)?.code, "managed_subagent") }
        for method in ["side.open", "session.fork", "turn.retry", "run.continue", "context.compact", "mcp.invoke", "session.configure", "queue.edit.begin", "unknown.mutation"] {
            do { try await child.requireSubagentCommand(method); XCTFail("Child accepted \(method)") }
            catch { XCTAssertEqual((error as? AgentError)?.code, "managed_subagent") }
        }
        for method in ["session.history", "session.message.read", "session.content.search", "turn.stop"] { try await child.requireSubagentCommand(method) }
        do { _ = try await child.fork(to: "fork"); XCTFail("Child was forked") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "managed_subagent") }
        await child.close()
    }
}

private actor PermissionTools: ToolExecuting {
    var calls: [String] = [], retained: [String] = [], read = true
    var failing = false
    func failInvocations() { failing = true }
    func removeRead() { read = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] {
        ((read ? ["read"] : []) + (readOnly ? [] : ["write", "bash"]) + ["mcp", "subagent"]).map { ToolDefinition($0, "fixture", [:]) }
    }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON {
        calls.append(call.id)
        if failing { throw AgentError("fixture_unknown", "Outcome unknown") }
        return ["servers":[["server":"allowed"], ["server":"forbidden"]]]
    }
    func resultsRetained(_ callIDs: [String], retained: Bool) { self.retained += callIDs }
}
