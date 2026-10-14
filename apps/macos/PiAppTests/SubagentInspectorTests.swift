import XCTest
import AppKit
@testable import PiApp

final class SubagentInspectorTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()).appendingPathComponent("subagent-inspector-" + UUID().uuidString)
    }
    private func metadata(_ session: String, owner: String? = nil, wall: Double = 2000) throws -> [String: WireValue] {
        var value: [String: WireValue] = ["attemptId":.string(UUID().uuidString),"sessionId":.string(session),"turnId":.string("turn"),
            "purpose":.string("turn"),"api":.string("openai-responses"),"mode":.string("off"),"wallTimestamp":.number(wall),"outcome":.string("completed")]
        if let owner { value["requestScope"] = try subagentCaptureScope(source: session, owner: owner) }
        return value
    }
    func testFamilyListingIncludesChildRequestsWithoutIncludingAnotherWorkspace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: nil, bodyRetention: 1000, metricRetention: 1000)
        for (session, owner, workspace) in [("parent", nil, "w"), ("child", "parent", "w"), ("foreign", "parent", "other")] {
            let value = try metadata(session, owner: owner)
            try await archive.begin(value, workspace: workspace); try await archive.finish(value)
        }
        let family = try await archive.inspectorRows(sessionID: "parent", workspaceID: "w")
        XCTAssertEqual(family.rows.count, 2)
        let child = try await archive.inspectorRows(sessionID: "child", workspaceID: "w")
        XCTAssertEqual(child.rows.count, 1)
        try await archive.close()
    }

    @MainActor func testComparisonsAndBodyRoutingUseThePhysicalChild() throws {
        func row(_ id: String, session: String, wall: Double) throws -> InspectorRequestRow {
            try InspectorRequestRow.archived(["id":.text(id),"session":.text(session),"wall":.real(wall),"turn":.text(id),
                                               "purpose":.text("turn"),"api":.text("openai-responses"),"outcome":.text("completed")])
        }
        let first = try row("first", session: "one", wall: 1), second = try row("second", session: "two", wall: 2)
        let third = try row("third", session: "one", wall: 3)
        let index = InspectorIndex(archived: [first, second, third])
        XCTAssertNil(index.predecessor(of: "second"), "A sibling's request is never the comparison baseline")
        XCTAssertEqual(index.predecessor(of: "third")?.id, "first")
        let request = InspectorRequestModel(archive: PayloadArchive(root: root()), sessionID: "parent", workspace: nil, cache: InspectorDocumentCache())
        request.open(second, predecessor: nil, previousLabel: nil)
        XCTAssertEqual(request.sessionID, "two", "Live bodies, events and exports route to the physical session")
        request.open(second, predecessor: first, previousLabel: "sibling")
        XCTAssertNil(request.predecessor); XCTAssertNil(request.previousLabel)
    }

    func testGroupsWithoutRequestsAreDurableAndIdentityCannotBeReassigned() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: nil, bodyRetention: 1000, metricRetention: 1000)
        let scope = try JSONDecoder().decode(RequestScope.self, from: JSONEncoder().encode(subagentCaptureScope(source: "child")))
        let link = try XCTUnwrap(scope.delegation)
        var summary = SubagentSummary(link: link, description: "Read the tests", model: "fixture", status: .queued, revision: 1)
        try await archive.recordSubagent(summary, workspaceID: "w")
        let queued = try await archive.inspectorSubagents(owner: "parent", workspaceID: "w")
        XCTAssertEqual(queued.count, 1); XCTAssertEqual(queued.first?.requests, 0)
        summary.status = .notExecuted; summary.revision = 2
        try await archive.recordSubagent(summary, workspaceID: "w")
        summary.status = .running; summary.revision = 1
        try await archive.recordSubagent(summary, workspaceID: "w")
        let retained = try await archive.inspectorSubagents(owner: "parent", workspaceID: "w")
        XCTAssertEqual(retained.first?.summary.status, .notExecuted, "Late live evidence cannot revive a terminal task")
        var forged = link; forged.childSessionID = "other-child"
        summary.link = forged
        do { try await archive.recordSubagent(summary, workspaceID: "w"); XCTFail("Delegation was reassigned") } catch { }
        let foreign = try await archive.inspectorSubagents(owner: "parent", workspaceID: "other")
        XCTAssertTrue(foreign.isEmpty)
        try await archive.close()
        let reopened = PayloadArchive(root: root)
        try await reopened.configure(quota: nil, bodyRetention: 1000, metricRetention: 1000)
        let saved = try await reopened.inspectorSubagents(owner: "parent", workspaceID: "w")
        XCTAssertEqual(saved, retained); try await reopened.close()
    }

    func testDirectLookupChecksBothWorkspaceAndFamily() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: nil, bodyRetention: 1000, metricRetention: 1000)
        let value = try metadata("child", owner: "parent"), id = try XCTUnwrap(value["attemptId"]?.string)
        try await archive.begin(value, workspace: "w"); try await archive.finish(value)
        let own = try await archive.inspectorRequest(id, sessionID: "parent", workspaceID: "w")
        XCTAssertEqual(own?.sessionID, "child"); XCTAssertEqual(own?.parentToolCallID, "call-child")
        let unrelated = try await archive.inspectorRequest(id, sessionID: "other-parent", workspaceID: "w")
        let foreign = try await archive.inspectorRequest(id, sessionID: "parent", workspaceID: "other")
        XCTAssertNil(unrelated); XCTAssertNil(foreign)
        try await archive.close()
    }

    @MainActor func testOverviewUsageFollowsFamilyFiltersAndIgnoresTheParentsFooterForAChild() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { workspace.shutdown() }
        let archive = workspace.traces
        try await archive.configure(quota: nil, bodyRetention: 1000, metricRetention: 1000)
        for (session, owner) in [("parent", nil), ("child", "parent"), ("sibling", "parent")] as [(String, String?)] {
            var value = try metadata(session, owner: owner, wall: Date().timeIntervalSince1970)
            value["timingVersion"] = .number(2); value["timings"] = .object(["dispatch":.number(100)])
            value["gateway"] = .object(["version":.number(1), "cost":.object(["status":.string("reported"), "usd":.number(0.01)])])
            try await archive.begin(value, workspace: "w"); try await archive.finish(value)
        }
        let parent = SessionDisplay(id: "parent")
        workspace.displays["parent"] = parent
        let model = SessionInspectorModel(scope: .init(sessionID: "parent", workspaceID: "w"), title: "Parent", archive: archive,
                                         workspace: workspace, usageLoader: { scope, until, offset in
            try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
        }, cache: InspectorDocumentCache())
        model.follow(parent); model.setVisible(true)
        defer { model.setVisible(false) }
        for _ in 0..<300 where model.usage.snapshot == nil || model.groups.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.usage.snapshot?.gateway.requests, 3)
        XCTAssertEqual(model.inputs.gateway.requests, 3, "An empty loaded footer must fall back to the family capture totals")
        parent.footer.gateway = GatewayTotals(requests: 20)
        parent.footer.cost = SessionCostReading(limit: .usd(10), spentUSD: 9, reportedRequests: 20)
        model.setFamilyFilter(.chat)
        for _ in 0..<300 where model.usage.loading || model.usage.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.usage.snapshot?.gateway.requests, 1)
        XCTAssertEqual(model.inputs.gateway.requests, 1, "This chat only excludes the parent's rolled-up footer")
        model.setFamilyFilter(.child("child"))
        for _ in 0..<300 where model.usage.loading || model.usage.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.usage.scope.sessionID, "child")
        XCTAssertEqual(model.inputs.gateway.requests, 1)
        XCTAssertEqual(model.scope.sessionID, "parent", "Inspector commands stay owned by the parent window")
        for _ in 0..<300 where model.tokenCharts.hero.first(where: { $0.id == "cost" })?.value != SessionStatsFormat.cost(0.01) { try await Task.sleep(for: .milliseconds(10)) }
        let overview = InspectorOverviewPage(inspector: model, compact: true)
        overview.frame = NSRect(x: 0, y: 0, width: 680, height: 600); overview.layoutSubtreeIfNeeded()
        let cost = try XCTUnwrap(ConversationPaneTests.views(PiKit.Figure.self, in: overview).first { $0.accessibilityIdentifier() == "inspector-figure-cost" })
        XCTAssertEqual(cost.value, SessionStatsFormat.cost(0.01), "A child's figure must not display the parent's $9 budget spend")
        XCTAssertFalse(cost.caption?.contains("limit") == true)
        model.setFamilyFilter(.family)
        for _ in 0..<300 where model.usage.loading || model.usage.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.usage.snapshot?.gateway.requests, 3)
        XCTAssertEqual(model.inputs.gateway.requests, 20, "The family overview retains the parent's complete live accounting")
        model.setVisible(false); try await archive.close(); await workspace.store?.close()
    }

    @MainActor func testExplicitRequestOutsideTheNavigatorWindowCanBeOpened() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 10000) })
        try await archive.configure(quota: nil, bodyRetention: 100000, metricRetention: 100000)
        let target = UUID().uuidString
        do {
            let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
            try db.transaction {
                for index in 0...5000 {
                    try db.execute("INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,outcome,wall,updated,metadata) VALUES(?,'parent','w','turn','turn','openai-responses','fixture','completed',?,10000,?)",
                                   [.text(index == 0 ? target : UUID().uuidString),.real(Double(index + 1000)),.blob(Data("{}".utf8))])
                }
            }
        }
        let model = SessionInspectorModel(scope: .init(sessionID: "parent", workspaceID: "w"), title: "Parent", archive: archive,
                                         workspace: nil, usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        model.setVisible(true); defer { model.setVisible(false) }
        for _ in 0..<500 where !model.indexLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.index.requests.count, 5000); XCTAssertEqual(model.index.olderRequests, 1)
        model.focus(.request(target))
        for _ in 0..<500 where model.page != .request(target) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.page, .request(target)); XCTAssertNil(model.focusNotice)
        let child = try metadata("child", owner: "parent", wall: 500)
        try await archive.begin(child, workspace: "w"); try await archive.finish(child)
        model.refresh()
        for _ in 0..<500 where model.groups.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.groups.count, 1)
        let view = SessionInspectorView(inspector: model); view.frame = NSRect(x: 0, y: 0, width: 920, height: 600)
        view.layoutSubtreeIfNeeded()
        model.setFamilyFilter(.child("child"))
        for _ in 0..<500 where model.index.requests.first?.sessionID != "child" || model.index.requests.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.index.requests.count, 1); XCTAssertEqual(model.index.requests.first?.sessionID, "child")
        XCTAssertEqual(model.page, .subagent("delegation-child"))
        model.setFamilyFilter(.child("foreign"))
        XCTAssertEqual(model.familyFilter, .child("child"), "A filter cannot request an unrelated session")
        model.setVisible(false); try await archive.close()
    }
}
