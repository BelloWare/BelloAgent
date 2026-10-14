import XCTest
@testable import PiApp

func subagentCaptureScope(source: String, owner: String = "parent", purpose: String = "turn") throws -> WireValue {
    let link = SubagentLink(delegationID: "delegation-" + source, childSessionID: source, budgetOwnerSessionID: owner,
                           call: .init(parentSessionID: owner, assistantMessageID: "assistant", toolCallID: "call-" + source),
                           parentTurnID: "parent-turn", parentExecutionID: "parent-execution", parentAttemptID: "parent-attempt")
    let delegation = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(link))
    return .object(["sourceSessionID":.string(source),"budgetOwnerSessionID":.string(owner),"turnID":.string("turn"),
                    "executionID":.string("execution"),"purpose":.string(purpose),"ownerGeneration":.number(0),"delegation":delegation])
}

final class SubagentCaptureTests: XCTestCase {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()).appendingPathComponent("subagent-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func metadata(_ session: String, cost: Double?, owner: String? = nil, purpose: String = "turn") throws -> [String: WireValue] {
        var value: [String: WireValue] = ["attemptId":.string(UUID().uuidString),"sessionId":.string(session),"turnId":.string("turn"),
            "purpose":.string(purpose),"api":.string("openai-responses"),"requestedModel":.string("fixture-model"),"mode":.string("off"),
            "outcome":.string("completed"),"wallTimestamp":.number(2000),"timingVersion":.number(2),"timings":.object(["dispatch":.number(100)]),
            "usage":.object(["inputIncludingCache":.number(20),"output":.number(5)]),
            "gateway":.object(["version":.number(1),"cost":.object(["status":.string(cost == nil ? "unreported" : "reported"),"usd":cost.map(WireValue.number) ?? .null])])]
        if let owner { value["requestScope"] = try subagentCaptureScope(source: session, owner: owner, purpose: purpose) }
        return value
    }
    private func archive(_ root: URL) async throws -> PayloadArchive {
        let value = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await value.configure(quota: nil, bodyRetention: 100, metricRetention: 1000)
        return value
    }
    private func save(_ value: [String: WireValue], to archive: PayloadArchive, workspace: String = "workspace") async throws {
        try await archive.begin(value, workspace: workspace); try await archive.finish(value)
    }

    func testBudgetEvidenceUsesRegisteredIDsOwnerWorkspaceAndRetainedTerminalMetadata() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await archive(root)
        var ids: [String] = [], expected: String?
        for (session, owner, workspace, outcome) in [("child", "parent", "workspace", "completed"), ("foreign", "parent", "foreign", "completed"), ("other", "other-parent", "workspace", "completed"), ("live", "parent", "workspace", "running")] {
            var value = try metadata(session, cost: 0.2, owner: owner)
            value["outcome"] = .string(outcome); value["requestHeaders"] = .object(["fixture":.string("private")])
            let id = try XCTUnwrap(value["attemptId"]?.string); ids.append(id)
            if session == "child" { expected = id }
            try await save(value, to: archive, workspace: workspace)
        }
        let evidence = try await archive.budgetEvidence(attempts: ids, owner: "parent", workspace: "workspace")
        XCTAssertEqual(evidence.compactMap { $0.object?["attemptId"]?.string }, [try XCTUnwrap(expected)])
        XCTAssertNil(evidence.first?.object?["requestHeaders"])
        let absent = try await archive.budgetEvidence(attempts: ["not-registered"], owner: "parent", workspace: "workspace")
        XCTAssertTrue(absent.isEmpty)
        try await archive.close()
    }

    func testFamilyOutputSpeedIncludesEachPhysicalAttemptsTTFTExactlyOnce() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await archive(root)
        for (session, owner, ttft, span) in [("parent", nil, 1_000.0, 1_000.0), ("child", "parent", 3_000.0, 1_000.0)] as [(String, String?, Double, Double)] {
            var value = try metadata(session, cost: 0.1, owner: owner)
            value["modelOutcome"] = .string("completed")
            value["timings"] = .object(["dispatch":.number(100),"firstContent":.number(100 + ttft),"lastContent":.number(100 + ttft + span),"modelComplete":.number(100 + ttft + span + 500)])
            value["usage"] = .object(["output":.number(60)])
            try await save(value, to: archive)
        }
        let parent = try await archive.gatewayAccounting(sessionID: "parent", workspaceID: "workspace", messages: [])
        XCTAssertEqual(parent.session.decodeMilliseconds, 6_000); XCTAssertEqual(parent.session.decodeOutputTokens, 120)
        let inspector = try await archive.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: Date(timeIntervalSince1970: 2001), includeFamily: true)
        XCTAssertEqual(inspector.gateway.decodeMilliseconds, 6_000)
        let child = try await archive.gatewayAccounting(sessionID: "child", workspaceID: "workspace", messages: [])
        XCTAssertEqual(child.session.decodeMilliseconds, 4_000)
        try await archive.close()
    }

    @MainActor func testCaptureControlsUseTheParentPreference() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        var child = ChatRecord(id: "child", workspaceID: "w", title: "Task", profileID: "p")
        let scope = try JSONDecoder().decode(RequestScope.self, from: JSONEncoder().encode(subagentCaptureScope(source: "child")))
        child.delegation = scope.delegation
        model.chats = [ChatRecord(id: "parent", workspaceID: "w", title: "Parent", profileID: "p"), child]
        try await model.setCaptureMode("off", sessionID: "parent")
        let preference = try await model.capturePreference(sessionID: "child")
        XCTAssertEqual(preference.mode, "off")
        do { try await model.setCaptureMode("persist", sessionID: "child"); XCTFail("Child preference changed independently") } catch { }
        XCTAssertNil(model.configuration.capture.sessionModes["child"])
        try await model.traces.close(); await model.store?.close()
    }

    func testFamilyRollupKeepsPhysicalAndGlobalTotalsSeparate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await archive(root)
        try await save(metadata("parent", cost: 0.01), to: archive)
        try await save(metadata("child", cost: 0.02, owner: "parent"), to: archive)
        try await save(metadata("child", cost: nil, owner: "parent", purpose: "compaction"), to: archive)
        try await save(metadata("unrelated", cost: 0.04, owner: "other-parent"), to: archive)
        try await save(metadata("foreign-child", cost: 0.5, owner: "parent"), to: archive, workspace: "foreign")
        let parent = try await archive.gatewayAccounting(sessionID: "parent", workspaceID: "workspace", messages: [])
        let child = try await archive.gatewayAccounting(sessionID: "child", workspaceID: "workspace", messages: [])
        XCTAssertEqual(parent.session.requests, 3); XCTAssertEqual(parent.session.costSamples, 2)
        XCTAssertEqual(try XCTUnwrap(parent.session.costUSD), 0.03, accuracy: 1e-9)
        XCTAssertEqual(parent.session.tokens?.input, 60)
        XCTAssertEqual(child.session.requests, 2); XCTAssertEqual(child.session.costUSD, 0.02)
        let rows = try await archive.allSessionTotals()
        XCTAssertEqual(rows["workspace\u{0}parent"]?.requests, 3); XCTAssertEqual(rows["workspace\u{0}child"]?.requests, 2)
        let global = try await archive.dashboard(DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001)))
        XCTAssertEqual(global.gateway.requests, 5, "Project/global totals count physical attempts only")
        XCTAssertEqual(try XCTUnwrap(global.gateway.costUSD), 0.57, accuracy: 1e-9)
        let physical = try await archive.list(sessionID: "parent", workspaceID: "workspace")
        XCTAssertEqual(physical.count, 1, "Physical-session listings retain their meaning")
        try await archive.close()
    }

    func testInspectorUsageIncludesTheSelectedFamilyAndCachesEachScopeSeparately() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await archive(root), until = Date(timeIntervalSince1970: 2001)
        for (session, owner, cost, workspace) in [("parent", nil, 0.01, "workspace"), ("child", "parent", 0.02, "workspace"), ("child", "parent", nil, "workspace"), ("unrelated", "other", 0.04, "workspace"), ("foreign", "parent", 0.5, "foreign")] as [(String, String?, Double?, String)] {
            var value = try metadata(session, cost: cost, owner: owner, purpose: cost == nil ? "compaction" : "turn")
            value["requestedModel"] = .string(session + "-model")
            try await save(value, to: archive, workspace: workspace)
        }
        let family = try await archive.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: until, includeFamily: true)
        XCTAssertEqual(family.gateway.requests, 3); XCTAssertEqual(family.modelGroups, 2)
        XCTAssertEqual(family.compactionRequests, 1); XCTAssertEqual(family.costUnreported, 1)
        XCTAssertEqual(try XCTUnwrap(family.gateway.costUSD), 0.03, accuracy: 1e-9)
        XCTAssertEqual(family.models.first { $0.requestedAlias == "child-model" }?.gateway.requests, 2)
        let own = try await archive.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: until)
        XCTAssertEqual(own.gateway.requests, 1); XCTAssertEqual(own.gateway.costUSD, 0.01)
        // Page reads reuse summaries: switching filters must not reuse a
        // differently scoped aggregate, even when the model page is empty.
        let familyPage = try await archive.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: until, offset: 24, includeFamily: true)
        let ownPage = try await archive.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: until, offset: 24)
        XCTAssertEqual(familyPage.gateway.requests, 3); XCTAssertEqual(ownPage.gateway.requests, 1)
        let child = try await archive.sessionMetrics(sessionID: "child", workspaceID: "workspace", until: until)
        XCTAssertEqual(child.gateway.requests, 2); XCTAssertEqual(child.costUnreported, 1)
        try await archive.close()
    }

    func testCaptureLineageCannotChangeOrDisappearAfterBegin() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await archive(root), original = try metadata("child", cost: 0.01, owner: "parent")
        try await archive.begin(original, workspace: "workspace")
        for nextScope in [try subagentCaptureScope(source: "child", owner: "other-parent"), .null] {
            var changed = original; changed["requestScope"] = nextScope
            do { try await archive.update(changed); XCTFail("Capture ownership changed after begin") } catch { }
        }
        var forged = try metadata("child", cost: 0.01, owner: "parent")
        forged["sessionId"] = .string("another-child")
        do { try await archive.begin(forged, workspace: "workspace"); XCTFail("A physical capture adopted another source's scope") } catch { }
        let retained = try await archive.metadata(attempt: XCTUnwrap(original["attemptId"]?.string))
        XCTAssertEqual(retained["requestScope"], original["requestScope"])
        try await archive.close()
    }

    func testExistingVersionFiveCapturesGainIndexedLineageWithoutChangingMetadata() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var archive: PayloadArchive? = try await archive(root)
        let value = try metadata("child", cost: 0.02, owner: "parent"), id = try XCTUnwrap(value["attemptId"]?.string)
        try await save(value, to: XCTUnwrap(archive)); try await archive?.close(); archive = nil
        do {
            let database = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            let columns = try database.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string }
            for index in ["attempts_family", "attempts_delegation"] { try database.execute("DROP INDEX IF EXISTS " + index) }
            for column in ["budget_owner", "parent_session", "parent_attempt", "parent_assistant", "parent_tool_call", "delegation"] where columns.contains(column) {
                try database.execute("ALTER TABLE attempts DROP COLUMN " + column)
            }
            try database.execute("PRAGMA user_version=5")
        }
        let reopened = try await self.archive(root)
        let database = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"), readOnly: true)
        let columns = try database.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string }
        XCTAssertTrue(columns.contains("budget_owner")); XCTAssertTrue(columns.contains("parent_attempt"))
        if columns.contains("budget_owner") {
            let row = try database.rows("SELECT budget_owner,parent_session,parent_attempt,parent_assistant,parent_tool_call,delegation FROM attempts WHERE id=?", [.text(id)]).first
            XCTAssertEqual(row?["budget_owner"]?.string, "parent"); XCTAssertEqual(row?["parent_attempt"]?.string, "parent-attempt")
            XCTAssertEqual(row?["parent_tool_call"]?.string, "call-child")
        }
        let retained = try await reopened.metadata(attempt: id)
        XCTAssertEqual(retained["requestScope"], value["requestScope"])
        try await reopened.close()
    }
}
