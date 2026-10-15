import AppKit
import XCTest
@testable import PiApp

final class SubagentCostTests: XCTestCase {
    @MainActor func testDeletingAnOwnerDetachesAndReopensSurvivingSavedSides() async throws {
        let root = URL(fileURLWithPath:scratchBase()).appendingPathComponent("side-deletion-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceRecord(id:"project",path:root.path,trusted:true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "fixture"
        let connection = VaultProfile(profile:profile,apiKey:"synthetic-unused-key"), vault = ConfigurationVault(storage:MemoryVaultStorage())
        _ = try await vault.update(expectedRevision:0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome":.string(root.appendingPathComponent("codex").path)])
        }
        let model = makeWorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:vault)
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id:"main",workspaceID:workspace.id,title:"Main",profileID:profile.id)
        try await model.store?.put(parent,kind:"chat",id:parent.id); model.chats = [parent]
        let host = try await model.open(parent)
        for (id, owner) in [("side","main"),("nested","side")] {
            let result = try await host.request("side.open",sessionID:owner,params:["sideSessionId":.string(id)])
            let record = ChatRecord(id:id,workspaceID:workspace.id,title:id,path:result.object?["path"]?.string,profileID:profile.id,toolMode:ChatRecord.readOnlyTools,parentSessionID:owner)
            try await model.store?.put(record,kind:"chat",id:id); model.chats.append(record)
            model.displays[id] = SessionDisplay(id:id)
            _ = try await model.open(record); model.refreshCostReading(id)
        }
        try await model.restoreSideBudgets()
        let source = try XCTUnwrap(model.record(parent.id)), path = try XCTUnwrap(source.path)
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await model.deleteSubagentFamily(source)
        XCTAssertNil(model.record(parent.id)); XCTAssertFalse(model.opened.contains("side")); XCTAssertFalse(model.opened.contains("nested"))
        let side = try XCTUnwrap(model.record("side")), nested = try XCTUnwrap(model.record("nested"))
        XCTAssertNil(model.costReading(for:side.id).budgetOwnerID)
        XCTAssertEqual(model.costReading(for:nested.id).budgetOwnerID,side.id)
        _ = try await model.open(nested)
        XCTAssertTrue(model.opened.contains(side.id)); XCTAssertTrue(model.opened.contains(nested.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath:path),"Reopening an orphan must not recreate the deleted parent")
        let parents = await model.traces.savedSideBudgets
        XCTAssertEqual(parents[workspace.id + "\u{0}side"],[])
        XCTAssertEqual(parents[workspace.id + "\u{0}nested"],["side"])
    }

    @MainActor func testBusyPresentationReleaseCannotMakeEditingSkipTheRealUnload() async throws {
        let root = URL(fileURLWithPath:scratchBase()).appendingPathComponent("side-tools-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceRecord(id:"project",path:root.path,trusted:true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "fixture"
        let connection = VaultProfile(profile:profile,apiKey:"synthetic-unused-key")
        let vault = ConfigurationVault(storage:MemoryVaultStorage())
        _ = try await vault.update(expectedRevision:0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome":.string(root.appendingPathComponent("codex").path)])
        }
        let model = makeWorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:vault)
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id:"main",workspaceID:workspace.id,title:"Main",profileID:profile.id,toolMode:ChatRecord.readOnlyTools)
        try await model.store?.put(parent,kind:"chat",id:parent.id); model.chats = [parent]
        model.displays[parent.id] = SessionDisplay(id:parent.id)
        let host = try await model.open(parent)
        _ = try await host.request("side.open",sessionID:parent.id,params:["sideSessionId":.string("side")])
        model.releaseHelperSession(parent.id)
        await model.sessionClosings[parent.id]?.task.value
        XCTAssertTrue(model.opened.contains(parent.id),"A rejected unload must retain the loaded tool-mode state")
        do { try await model.enableEditingAfterConfirmation(parent.id); XCTFail("The pinned owner cannot announce editing") }
        catch { }
        XCTAssertEqual(model.record(parent.id)?.toolMode,ChatRecord.readOnlyTools)
        let saved = try await model.store?.get(ChatRecord.self,kind:"chat",id:parent.id)
        XCTAssertEqual(saved?.toolMode,ChatRecord.readOnlyTools)
        _ = try await host.request("session.close",sessionID:"side")
        try await model.enableEditingAfterConfirmation(parent.id)
        XCTAssertFalse(model.opened.contains(parent.id))
        _ = try await model.open(try XCTUnwrap(model.record(parent.id)))
        let snapshot = try await host.request("session.status",sessionID:parent.id)
        XCTAssertEqual(snapshot.object?["toolMode"]?.string,ChatRecord.editingTools)
    }

    @MainActor func testMountedForkKeepsItsBudgetAndOwnsItsSides() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("mounted-fork-budget-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let main = ChatRecord(id:"main",workspaceID:"w",title:"Main",profileID:"p",costLimit:.usd(3))
        let fork = ChatRecord(id:"fork",workspaceID:"w",title:"Fork",path:"/fixture/fork_fork.jsonl",profileID:"p",parentSessionID:"main",costLimit:.usd(7))
        let side = ChatRecord(id:"side",workspaceID:"w",title:"Side",path:"/fixture/side_side.jsonl",profileID:"p",parentSessionID:"fork")
        model.chats = [main,fork,side]; model.pendingChatIDs.insert(fork.id)
        _ = model.mountSide(fork,beside:main.id)
        XCTAssertNil(model.sideBudgetParent(fork), "Pane placement cannot grant budget ownership")
        XCTAssertEqual(model.budgetOwner(for:side).id,fork.id)
        XCTAssertEqual(model.costLimit(for:fork),.usd(7))
        try await model.setCostLimit(.usd(8),for:fork.id)
        let params = await model.costLimitParams(for:try XCTUnwrap(model.record(fork.id)))
        XCTAssertEqual(params["costLimit"]?.object?["usd"]?.number,8)
        try await model.traces.configure(quota:nil,bodyRetention:86400,metricRetention:86400)
        try await model.restoreSideBudgets()
        let ancestry = await model.traces.savedSideBudgets
        XCTAssertEqual(ancestry["w\u{0}side"],["fork"])
        XCTAssertTrue(ancestry["w\u{0}fork"]?.isEmpty ?? true)
    }

    @MainActor func testOrphanedSideClearsTheFormerBudgetAttribution() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("orphan-side-budget-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        let main = ChatRecord(id:"main",workspaceID:"w",title:"Main",profileID:"p",costLimit:.usd(3))
        let side = ChatRecord(id:"side",workspaceID:"w",title:"Side",path:"/fixture/side_side.jsonl",profileID:"p",parentSessionID:"main")
        model.chats = [main,side]
        let view = SessionDisplay(id:side.id); model.displays[side.id] = view
        view.footer.cost = model.costReading(for:side.id)
        XCTAssertEqual(view.footer.cost.budgetOwnerID,main.id)
        try await model.traces.configure(quota:nil,bodyRetention:86400,metricRetention:86400)
        try await model.restoreSideBudgets()
        model.chats.removeAll { $0.id == main.id }
        try await model.restoreSideBudgets(); model.refreshCostReading(side.id)
        XCTAssertEqual(model.budgetOwner(for:side).id,side.id)
        XCTAssertNil(view.footer.cost.budgetOwnerID)
        XCTAssertNil(view.footer.cost.budgetSpentUSD)
        XCTAssertNil(view.footer.cost.costAttribution)
        let ancestry = await model.traces.savedSideBudgets
        XCTAssertEqual(ancestry["w\u{0}side"],[])
    }

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
