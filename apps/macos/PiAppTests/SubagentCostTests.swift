import AppKit
import XCTest
@testable import PiApp

final class SubagentCostTests: XCTestCase {
    @MainActor func testLegacyCostSeedUsesOnlyPhysicalSpendBeforeHelperAddsSavedSides() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-cost-seed-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let main = ChatRecord(id:"main",workspaceID:"w",title:"Main",path:"/fixture/main.jsonl",profileID:"p")
        model.chats = [main]
        try await model.traces.configure(quota:nil,bodyRetention:86400,metricRetention:86400)
        for (id, amount) in [("main",0.5),("side",0.7)] {
            let scope = RequestScope(sourceSessionID:id,budgetOwnerSessionID:id,turnID:"turn",executionID:"execution",purpose:"turn",ownerGeneration:0,delegation:nil,sideParents:id == "main" ? nil : ["main"])
            let value: [String:WireValue] = ["attemptId":.string(UUID().uuidString),"sessionId":.string(id),"turnId":.string("turn"),"purpose":.string("turn"),"api":.string("openai-responses"),"mode":.string("off"),"outcome":.string("completed"),"wallTimestamp":.number(Date().timeIntervalSince1970),"timingVersion":.number(2),"timings":.object(["dispatch":.number(100)]),"requestScope":try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(scope)),"gateway":.object(["version":.number(1),"cost":.object(["status":.string("reported"),"usd":.number(amount)])])]
            try await model.traces.begin(value,workspace:"w"); try await model.traces.finish(value)
        }
        let totals = try await model.traces.gatewayAccounting(sessionID:"main",workspaceID:"w",messages:[]).session
        model.publishChatStats(totals, sessionID:"main")
        let params = await model.costLimitParams(for:main)
        XCTAssertEqual(params["costSeed"]?.object?["usd"]?.number,0.5)
        XCTAssertEqual(params["costSeed"]?.object?["reported"]?.number,1)
    }

    @MainActor func testSidesInheritTheMainLimitAndForksRemainIndependent() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-cost-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let parent = ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p", costLimit: .usd(3))
        let side = ChatRecord(id: "side", workspaceID: "w", title: "Side", path: "/fixture/side_side.jsonl", profileID: "p", parentSessionID: "main", costLimit: .usd(99))
        let nested = ChatRecord(id: "nested", workspaceID: "w", title: "Nested", path: "/fixture/side_nested.jsonl", profileID: "p", parentSessionID: "side", costLimit: .unlimited)
        let fork = ChatRecord(id: "fork", workspaceID: "w", title: "Fork", path: "/fixture/fork.jsonl", profileID: "p", parentSessionID: "main", costLimit: .usd(7))
        model.chats = [parent, side, nested, fork]
        XCTAssertEqual(model.costLimit(for: side), .usd(3))
        XCTAssertEqual(model.costLimit(for: nested), .usd(3))
        XCTAssertEqual(model.costLimit(for: fork), .usd(7))
        model.sides[parent.id] = SideRecord(id: "draft", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Draft", costLimit: .usd(100))
        XCTAssertEqual(model.costLimit(for: "draft"), .usd(3))
        let parentView = SessionDisplay(id:"main"), sideView = SessionDisplay(id:"side")
        model.displays = ["main":parentView,"side":sideView]
        model.observeCost(["cost":.object(["spentUSD":.number(3.2),"reportedRequests":.number(4),"limitUSD":.number(3)])],view:parentView)
        model.observeCost(["cost":.object(["spentUSD":.number(0.4),"reportedRequests":.number(1),"limitUSD":.null])],view:sideView)
        XCTAssertTrue(sideView.footer.cost.reached)
        XCTAssertEqual(sideView.footer.cost.figure,"$0.40")
        XCTAssertEqual(SessionStatsPresentation(gateway:sideView.footer.gateway,work:nil,cost:sideView.footer.cost).costAttribution,"Counts toward Main")
        do { try await model.setCostLimit(.usd(100),for:"side"); XCTFail("Sides cannot override the main budget") } catch { }
        XCTAssertEqual(model.record("side")?.costLimit,.usd(99),"Legacy values remain stored but ignored")
    }

    @MainActor func testChildCaptureBeforeDiscoveryUpdatesParentFooterSidebarAndMenu() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sub-cost-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats = [ChatRecord(id: "parent", workspaceID: "workspace", title: "Main task", profileID: "fixture")]
        let parent = SessionDisplay(id: "parent"); parent.runState = .running; parent.runStateKnown = true
        model.displays[parent.id] = parent; model.selectedID = parent.id; model.selected = parent
        try await model.traces.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        let metadata: [String: WireValue] = ["attemptId":.string(UUID().uuidString), "sessionId":.string("child"), "turnId":.string("turn"),
            "purpose":.string("turn"), "api":.string("openai-responses"), "requestedModel":.string("fixture"), "mode":.string("off"),
            "outcome":.string("failed"), "wallTimestamp":.number(Date().timeIntervalSince1970), "timingVersion":.number(2),
            "timings":.object(["dispatch":.number(100)]), "requestScope":try subagentCaptureScope(source: "child"),
            "usage":.object(["inputIncludingCache":.number(100), "output":.number(20)]),
            "gateway":.object(["version":.number(1), "cost":.object(["status":.string("reported"), "usd":.number(1.25)])])]
        try await model.traces.begin(metadata, workspace: "workspace"); try await model.traces.finish(metadata)
        await model.captureDidPersist(["type":.string("finish"), "metadata":.object(metadata)], workspaceID: "workspace")
        try await eventually("parent accounting after undiscovered child", timeout: .seconds(10)) {
            parent.footer.gateway.requests == 1 && model.chatStats[parent.id]?.requests == 1
        }
        XCTAssertNil(model.record("child"), "Accounting must not wait for desktop child discovery")
        XCTAssertEqual(parent.footer.gateway.costUSD, 1.25)
        XCTAssertEqual(parent.footer.gateway.tokens?.input, 100)
        let stats = SessionStatsPresentation(gateway: parent.footer.gateway, work: nil, cost: parent.footer.cost)
        XCTAssertTrue(stats.costFigure?.hasPrefix("$1.25") == true)
        XCTAssertEqual(stats.costAttribution, "Includes $1.25 from 1 sub-agent")
        XCTAssertTrue(ChatRowStats(totals: model.chatStats[parent.id]).costHelp?.contains(stats.costAttribution!) == true)
        let menu = try XCTUnwrap(model.menuBarActivity().rows.first { $0.id == parent.id })
        XCTAssertEqual(menu.costUSD, 1.25); XCTAssertEqual(menu.tokens, 120)
        XCTAssertTrue(menu.costHelp?.contains(stats.costAttribution!) == true)
        model.observeCost(["cost":.object(["spentUSD":.number(1.25), "reportedRequests":.number(1), "limitUSD":.number(25)])], view: parent)
        XCTAssertEqual(parent.footer.cost.spentUSD, 1.25)
        XCTAssertEqual(SessionStatsPresentation(gateway: parent.footer.gateway, work: nil, cost: parent.footer.cost).costFigure, "$1.25 of $25.00")
    }

    @MainActor func testCostHelpIsAccessibleCompactAndAbsentWithoutChildren() async throws {
        var totals = GatewayTotals(requests: 4, costSamples: 4, costUSD: 1.23)
        totals.tokens = GatewayTokenTotals(input: 100, output: 20, total: 120, inputSamples: 4, outputSamples: 4, samples: 4)
        let original = SessionStatsPresentation(gateway: totals, work: nil)
        XCTAssertNil(original.costAttribution)
        XCTAssertNil(ChatRowStats(totals: totals).costHelp, "Ordinary chats gain no sub-agent explanation")
        XCTAssertNil(ChatRowStats(totals: GatewayTotals()).costHelp, "Empty sides keep their existing accessible name")
        totals.subagentCost = GatewaySubagentCost(count: 3, requests: 3, reported: 3, usd: 0.45)
        let session = SessionDisplay(id: "parent"); session.footer.gateway = totals
        session.footer.cost = SessionCostReading(limit: .usd(5), spentUSD: 1.23, reportedRequests: 4)
        let pills = SessionStatsPills(session: session, selectedContextWindow: nil, compact: false, open: { _ in })
        pills.update(context: [:]); pills.frame = CGRect(x: 0, y: 0, width: 350, height: 50); pills.layoutSubtreeIfNeeded()
        let usage = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: pills).first { $0.accessibilityIdentifier() == "session-stats-usage" })
        let label = "Includes $0.45 from 3 sub-agents"
        XCTAssertTrue(usage.toolTip?.contains(label) == true)
        XCTAssertTrue(usage.accessibilityLabel()?.contains(label) == true)
        XCTAssertLessThanOrEqual(usage.frame.maxX, pills.bounds.width + 1)
        XCTAssertEqual(SessionStatsPresentation(gateway: totals, work: nil).usageFace.label, original.usageFace.label, "Attribution does not widen the pill")
        let editor = CostLimitLiveEditor(footer: session.footer, choose: { _ in })
        XCTAssertEqual(editor.reading.costAttribution, label)
        XCTAssertTrue(ConversationPaneTests.views(CostLimitMeter.self, in: editor).first?.accessibilityLabel()?.contains(label) == true)
        // The helper can retain spend beyond capture retention; label the scope honestly.
        var older = session.footer.cost; older.reportedRequests = 9; older.spentUSD = 3
        XCTAssertEqual(SessionStatsPresentation(gateway: totals, work: nil, cost: older).costAttribution, label + " (retained requests)")
    }
}
