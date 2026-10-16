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
    func testRetiredSideAncestryRepairsHistoricalAndFutureCapturesWithoutChangingIdentity() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at:root) }
        var log = try await archive(root)
        var value = try metadata("agent",cost:0.2,owner:"side")
        var scope = try XCTUnwrap(value["requestScope"]?.object)
        scope["sideParents"] = .array([.string("deleted")]); value["requestScope"] = .object(scope)
        try await save(value,to:log)
        // Forks previously mounted as sides and saved orphans both retire an
        // old projection. Nested sides retain the nearest surviving owner.
        try await save(metadata("fork",cost:0.4),to:log)
        try await save(metadata("nested",cost:0.3),to:log)
        try await log.recordSideBudgets(["fork":["deleted"],"nested":["side","deleted"]],workspaceID:"workspace")
        try await log.recordSideBudgets(["fork":[],"side":[],"nested":["side"]],workspaceID:"workspace")
        for reload in [false,true] {
            if reload {
                try await log.close(); log = try await archive(root)
                value["attemptId"] = .string(UUID().uuidString); try await save(value,to:log)
            }
            let totals = try await log.allSessionTotals()
            XCTAssertNil(totals["workspace\u{0}deleted"])
            XCTAssertEqual(try XCTUnwrap(totals["workspace\u{0}side"]?.costUSD),reload ? 0.7 : 0.5,accuracy:1e-9)
            XCTAssertEqual(totals["workspace\u{0}fork"]?.costUSD,0.4)
            let rows = try await log.list(sessionID:"agent",workspaceID:"workspace")
            XCTAssertEqual(rows.count,reload ? 2 : 1)
            let stored = try await log.budgetEvidence(attempts:[try XCTUnwrap(value["attemptId"]?.string)],owner:"side",workspace:"workspace")
            XCTAssertEqual(stored.first?.object?["requestScope"],value["requestScope"],"Physical lineage is immutable")
            let groups = try await log.inspectorSides(owner:"side",workspaceID:"workspace")
            XCTAssertEqual(groups.map(\.id),["nested"])
            let menu = try await log.menuBarMetrics(period:.retained,until:Date(timeIntervalSince1970:2001))
            XCTAssertEqual(try XCTUnwrap(menu.gateway.costUSD),reload ? 1.1 : 0.9,accuracy:1e-9)
        }
        try await log.close()
    }

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

    func testSidesAndTheirSubagentsRollUpOnceAcrossEveryAccountingSurfaceAndReload() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var log = try await archive(root)
        let requests: [(String,String?,[String]?,Double)] = [
            ("parent",nil,nil,1), ("side",nil,["parent"],0.4), ("nested",nil,["side","parent"],0.2),
            ("side-agent","side",["parent"],0.3), ("main-agent","parent",nil,0.1)]
        for (session, owner, parents, cost) in requests {
            var value = try metadata(session,cost:cost,owner:owner)
            if let parents {
                var scope = value["requestScope"]?.object ?? ["sourceSessionID":.string(session),"budgetOwnerSessionID":.string(session),"turnID":.string("turn"),"executionID":.string("execution"),"purpose":.string("turn"),"ownerGeneration":.number(0)]
                scope["sideParents"] = .array(parents.map(WireValue.string)); value["requestScope"] = .object(scope)
            }
            try await save(value,to:log); try await log.finish(value)
        }
        for reload in [false,true] {
            if reload { try await log.close(); log = try await archive(root) }
            var filter = DashboardFilter(from:Date(timeIntervalSince1970:1900),until:Date(timeIntervalSince1970:2001))
            filter.workspaceID = "workspace"; filter.status = "all"; filter.sessionID = "parent"
            let report = try await log.dashboard(filter), footer = try await log.gatewayAccounting(sessionID:"parent",workspaceID:"workspace",messages:[])
            let sidebar = try await log.allSessionTotals(), scope = SessionUsageScope(sessionID:"parent",workspaceID:"workspace")
            let scopes = requests.map { SessionUsageScope(sessionID:$0.0,workspaceID:"workspace") }
                + [SessionUsageScope(sessionID:"parent",workspaceID:"foreign")]
            let references = try await log.sessionReferenceTotals(scopes:scopes)
            for selected in scopes where selected.workspaceID == "workspace" {
                let ownScope = try await log.gatewayAccounting(sessionID:selected.sessionID,workspaceID:selected.workspaceID,messages:[])
                XCTAssertEqual(references[selected],ownScope.session,"Overlapping parent/side/child references each use their own population and breakdown")
            }
            XCTAssertEqual(references[SessionUsageScope(sessionID:"parent",workspaceID:"foreign")],GatewayTotals(),"An empty reference retains unknown coverage rather than borrowing the other project's family")
            let inspector = try await log.sessionMetrics(sessionID:"parent",workspaceID:"workspace",until:filter.until,includeFamily:true)
            for total in [report.gateway,footer.session,try XCTUnwrap(sidebar["workspace\u{0}parent"]),try XCTUnwrap(references[scope]),inspector.gateway] {
                XCTAssertEqual(total.requests,5); XCTAssertEqual(try XCTUnwrap(total.costUSD),2,accuracy:1e-9)
                XCTAssertEqual(total.tokens?.input,100); XCTAssertEqual(total.tokens?.output,25)
                XCTAssertEqual(total.sideCost?.count,1); XCTAssertEqual(try XCTUnwrap(total.sideCost?.usd),0.9,accuracy:1e-9)
                XCTAssertEqual(total.subagentCost?.count,1); XCTAssertEqual(total.subagentCost?.usd,0.1)
                XCTAssertTrue(total.costAttribution?.contains("from 1 side") == true)
            }
            let side = try await log.gatewayAccounting(sessionID:"side",workspaceID:"workspace",messages:[])
            XCTAssertEqual(side.session.requests,3); XCTAssertEqual(try XCTUnwrap(side.session.costUSD),0.9,accuracy:1e-9)
            XCTAssertEqual(side.session.budgetOwnerID,"parent")
            XCTAssertEqual(try XCTUnwrap(side.session.sideCost?.usd),0.2,accuracy:1e-9,"A side’s included-side subset excludes its own requests")
            XCTAssertEqual(side.session.subagentCost?.usd,0.3)
            let breakdown = try await log.inspectorSides(owner:"parent",workspaceID:"workspace")
            XCTAssertEqual(breakdown.map(\.id),["side"]); XCTAssertEqual(try XCTUnwrap(breakdown.first?.cost),0.9,accuracy:1e-9)
            let nested = try await log.inspectorSides(owner:"side",workspaceID:"workspace")
            XCTAssertEqual(nested.map(\.id),["nested"])
            let sideAgents = try await log.inspectorSubagents(owner:"side",workspaceID:"workspace")
            XCTAssertEqual(sideAgents.first?.cost,0.3)
            filter.sessionID = nil
            let global = try await log.dashboard(filter), sessions = try await log.sessionSummaries(filter)
            let menu = try await log.menuBarMetrics(period:.retained,until:filter.until)
            XCTAssertEqual(global.gateway.requests,5); XCTAssertEqual(menu.gateway.requests,5)
            XCTAssertEqual(sessions.total,1); XCTAssertEqual(sessions.sessions.first?.sessionID,"parent")
        }
        try await log.close()
    }

    func testLegacySideRelationshipsAdoptRetainedSpendWithoutChangingPhysicalRequests() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at:root) }
        var log = try await archive(root)
        try await save(metadata("side",cost:0.4),to:log)
        try await save(metadata("agent",cost:0.2,owner:"side"),to:log)
        for _ in 0..<2 { try await log.recordSideBudgets(["side":["parent"]],workspaceID:"workspace") }
        let parent = try await log.gatewayAccounting(sessionID:"parent",workspaceID:"workspace",messages:[])
        XCTAssertEqual(parent.session.requests,2); XCTAssertEqual(try XCTUnwrap(parent.session.costUSD),0.6,accuracy:1e-9)
        let own = try await log.list(sessionID:"side",workspaceID:"workspace")
        XCTAssertEqual(own.count,1)
        for reload in [false, true] {
            if reload { try await log.close(); log = try await archive(root) }
            // Legacy helper captures still roll up after registration/reopen,
            // without adding lookups to an unrelated ordinary request.
            let ordinary = try metadata("unrelated",cost:0.1), before = try await log.statementCount()
            try await log.begin(ordinary,workspace:"workspace")
            let statements = try await log.statementCount() - before
            XCTAssertLessThanOrEqual(statements,9)
            try await log.finish(ordinary)
            try await save(metadata("side",cost:0.4),to:log)
            try await save(metadata("agent",cost:0.2,owner:"side"),to:log)
            try await save(metadata("side",cost:0.7),to:log,workspace:"foreign")
            let expected = reload ? 1.8 : 1.2
            let family = try await log.gatewayAccounting(sessionID:"parent",workspaceID:"workspace",messages:[])
            XCTAssertEqual(try XCTUnwrap(family.session.costUSD),expected,accuracy:1e-9)
        }
        try await log.close()
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

    func testReportsChargeEveryChildAttemptToTheParentAcrossReload() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var log = try await archive(root)
        for (source, owner, purpose, outcome, cost) in [
            ("parent", nil, "turn", "completed", 0.10),
            ("child-a", "parent", "turn", "failed", 0.20),
            ("child-a", "parent", "turn", "cancelled", 0.30),
            ("child-a", "parent", "compaction", "completed", 0.40),
            ("child-a", "parent", "turn", "completed", 0.50),
            ("child-b", "parent", "turn", "completed", 0.60),
            ("side", nil, "turn", "completed", 0.70)
        ] as [(String, String?, String, String, Double)] {
            var attempt = try metadata(source, cost: cost, owner: owner, purpose: purpose)
            attempt["outcome"] = .string(outcome)
            try await save(attempt, to: log)
            try await log.finish(attempt) // Repeated terminal evidence must not charge twice.
        }
        for reload in [false, true] {
            if reload { try await log.close(); log = try await archive(root) }
            var filter = DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001))
            filter.workspaceID = "workspace"; filter.status = "all"
            let global = try await log.dashboard(filter)
            XCTAssertEqual(global.gateway.requests, 7)
            XCTAssertEqual(try XCTUnwrap(global.gateway.costUSD), 2.80, accuracy: 1e-9)
            let sessions = try await log.sessionSummaries(filter)
            XCTAssertEqual(sessions.total, 2, "By chat groups by budget owner, without duplicate child rows")
            let parent = try XCTUnwrap(sessions.sessions.first { $0.sessionID == "parent" })
            XCTAssertEqual(parent.gateway.requests, 6)
            XCTAssertEqual(try XCTUnwrap(parent.gateway.costUSD), 2.10, accuracy: 1e-9)
            XCTAssertEqual(parent.gateway.tokens?.input, 120)
            XCTAssertEqual(parent.gateway.tokens?.output, 30)
            filter.sessionID = "parent"
            let family = try await log.dashboard(filter)
            XCTAssertEqual(family.gateway.requests, 6, "A parent filter includes retries, summaries, failed/stopped and resumed children")
            XCTAssertEqual(try XCTUnwrap(family.gateway.costUSD), 2.10, accuracy: 1e-9)
            XCTAssertEqual(Set(family.requests.map(\.sessionID)), ["parent", "child-a", "child-b"], "Request identities stay physical")
            let footer = try await log.gatewayAccounting(sessionID: "parent", workspaceID: "workspace", messages: [])
            let sidebar = try await log.allSessionTotals()
            let scope = SessionUsageScope(sessionID: "parent", workspaceID: "workspace")
            let references = try await log.sessionReferenceTotals(scopes: [scope])
            let inspector = try await log.sessionMetrics(sessionID: "parent", workspaceID: "workspace", until: filter.until, includeFamily: true)
            let routes = try await log.modelSummaries(filter)
            let menu = try await log.menuBarMetrics(period: .retained, until: filter.until)
            XCTAssertEqual(menu.gateway.requests, 7)
            XCTAssertEqual(try XCTUnwrap(menu.gateway.costUSD), 2.8, accuracy: 1e-9)
            for value in [footer.session, try XCTUnwrap(sidebar["workspace\u{0}parent"]), try XCTUnwrap(references[scope]), inspector.gateway, parent.gateway, family.gateway, try XCTUnwrap(routes.first?.gateway)] {
                XCTAssertEqual(value.requests, 6)
                XCTAssertEqual(try XCTUnwrap(value.costUSD), 2.1, accuracy: 1e-9)
                XCTAssertEqual(value.tokens?.input, 120); XCTAssertEqual(value.tokens?.output, 30)
                let portion = try XCTUnwrap(value.subagentCost)
                XCTAssertEqual(portion.count, 2); XCTAssertEqual(portion.requests, 5); XCTAssertEqual(portion.reported, 5)
                XCTAssertEqual(try XCTUnwrap(portion.usd), 2, accuracy: 1e-9)
                XCTAssertTrue(value.costLabel.contains("Includes $2.00 from 2 sub-agents"))
            }
            let groups = try await log.inspectorSubagents(owner: "parent", workspaceID: "workspace")
            XCTAssertEqual(groups.count, 2)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.requests }, 5)
            XCTAssertEqual(groups.reduce(0) { $0 + ($1.cost ?? 0) }, 2, accuracy: 1e-9)
            filter.sessionID = "child-a"
            let own = try await log.dashboard(filter)
            XCTAssertEqual(own.gateway.requests, 4); XCTAssertNil(own.gateway.subagentCost)
            XCTAssertEqual(own.gateway.costAttribution, "Counts toward parent chat")
            let ownRows = try await log.sessionSummaries(filter)
            XCTAssertEqual(ownRows.sessions.map(\.sessionID), ["child-a"])

        }
        try await log.close()
    }

    func testAttributionKeepsMissingCostUnknownAndExcludesUndispatchedRequests() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try await archive(root)
        try await save(metadata("child", cost: nil, owner: "parent"), to: log)
        var prepared = try metadata("child", cost: 4, owner: "parent")
        prepared["timings"] = .object([:])
        try await save(prepared, to: log)
        let parent = try await log.gatewayAccounting(sessionID: "parent", workspaceID: "workspace", messages: [])
        XCTAssertEqual(parent.session.requests, 1); XCTAssertNil(parent.session.costUSD)
        XCTAssertEqual(parent.session.costAttribution, "Includes 1 sub-agent · cost unreported · 1 request reported no cost")
        let groups = try await log.inspectorSubagents(owner: "parent", workspaceID: "workspace")
        XCTAssertEqual(groups.first?.requests, 1); XCTAssertNil(groups.first?.cost)
        try await save(metadata("child", cost: 0, owner: "parent"), to: log)
        let zero = try await log.gatewayAccounting(sessionID: "parent", workspaceID: "workspace", messages: [])
        XCTAssertEqual(zero.session.costAttribution, "Includes $0.00 from 1 sub-agent · 1 request reported no cost")
        let encoded = try JSONEncoder().encode(zero.session)
        XCTAssertEqual(try JSONDecoder().decode(GatewayTotals.self, from: encoded), zero.session)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "subagentCost"); old.removeValue(forKey: "budgetOwnerID")
        XCTAssertNil(try JSONDecoder().decode(GatewayTotals.self, from: JSONSerialization.data(withJSONObject: old)).subagentCost)
        try await log.close()
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
