import AppKit
import XCTest
@testable import PiApp

final class SubagentCostTests: XCTestCase {
    @MainActor func testOrphanTransitionRefreshesRetainedAttributionOnExistingDisplaysAndCachedRows() async throws {
        let root = URL(fileURLWithPath:scratchBase()).appendingPathComponent("orphan-cached-cost-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        let main = ChatRecord(id:"main",workspaceID:"w",title:"Main",profileID:"p")
        let side = ChatRecord(id:"side",workspaceID:"w",title:"Side",path:"/fixture/side_side.jsonl",profileID:"p",parentSessionID:"main")
        let nested = ChatRecord(id:"nested",workspaceID:"w",title:"Nested",path:"/fixture/side_nested.jsonl",profileID:"p",parentSessionID:"side")
        let scope = try subagentCaptureScope(source:"agent",owner:side.id)
        let link = try JSONDecoder().decode(RequestScope.self,from:JSONEncoder().encode(scope)).delegation
        let agent = ChatRecord(id:"agent",workspaceID:"w",title:"Agent",profileID:"p",parentSessionID:side.id,delegation:link)
        model.chats = [main,side,nested,agent]
        try await model.store?.putChats(model.chats)
        let display = SessionDisplay(id:side.id); model.displays[side.id] = display
        let child = SessionDisplay(id:agent.id); model.displays[agent.id] = child
        try await model.traces.configure(quota:nil,bodyRetention:86400,metricRetention:86400)
        for id in [side.id,nested.id,agent.id] {
            var metadata: [String:WireValue] = ["attemptId":.string(UUID().uuidString),"sessionId":.string(id),"turnId":.string("turn"),"purpose":.string("turn"),
                "api":.string("openai-responses"),"requestedModel":.string("fixture"),"mode":.string("off"),"outcome":.string("completed"),
                "wallTimestamp":.number(Date().timeIntervalSince1970),"timingVersion":.number(2),"timings":.object(["dispatch":.number(100)]),
                "usage":.object(["inputIncludingCache":.number(100),"output":.number(20)]),
                "gateway":.object(["version":.number(1),"cost":.object(["status":.string("reported"),"usd":.number(0.2)])])]
            if id == agent.id { metadata["requestScope"] = scope }
            try await model.traces.begin(metadata,workspace:"w"); try await model.traces.finish(metadata)
        }
        try await model.restoreSideBudgets(); model.refreshCostReading(side.id)
        for view in [display,child] { await model.refreshAccounting(view,workspaceID:"w",includeMessages:false) }
        await model.refreshChatStats()
        try await eventually("original accounting reads settle") { model.accountingTasks.isEmpty }
        XCTAssertEqual(display.footer.gateway.budgetOwnerID,main.id)
        XCTAssertEqual(child.footer.gateway.budgetOwnerID,main.id)
        XCTAssertEqual(model.chatStats[nested.id]?.budgetOwnerID,main.id)
        model.chats.removeAll { $0.id == main.id }
        try await model.store?.remove(kind:"chat",id:main.id)
        try await model.restoreSideBudgets(); model.refreshCostReading(side.id)
        try await eventually("orphan ancestry refreshes cached accounting without a new request") {
            display.footer.gateway.budgetOwnerID == nil && model.chatStats[side.id]?.budgetOwnerID == nil && model.chatStats[nested.id]?.budgetOwnerID == side.id && child.footer.gateway.budgetOwnerID == side.id
        }
        XCTAssertEqual(try XCTUnwrap(display.footer.gateway.costUSD),0.6,accuracy:1e-9)
        XCTAssertEqual(display.footer.gateway.sideCost?.usd,0.2)
        XCTAssertEqual(display.footer.gateway.subagentCost?.usd,0.2)
        XCTAssertEqual(model.chatStats[nested.id]?.costUSD,0.2)
        let help = SessionStatsPresentation(gateway:display.footer.gateway,work:nil,cost:display.footer.cost).usageHelp
        XCTAssertFalse(help.contains("Counts toward")); XCTAssertTrue(help.contains("side"))
        // A repeated restore is inert: no requests, new ancestry or cache work.
        try await eventually("accounting refresh completes") { model.accountingTasks.isEmpty }
        let revision = display.accountingRevision
        try await model.restoreSideBudgets()
        XCTAssertTrue(model.accountingTasks.isEmpty); XCTAssertEqual(display.accountingRevision,revision)
    }

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
        try await model.store?.putChats(model.chats)
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
        try await model.store?.putChats(model.chats)
        let view = SessionDisplay(id:side.id); model.displays[side.id] = view
        view.footer.cost = model.costReading(for:side.id)
        XCTAssertEqual(view.footer.cost.budgetOwnerID,main.id)
        let inspector = SessionInspectorModel(scope:.init(sessionID:side.id,workspaceID:side.workspaceID),title:side.title,archive:model.traces,workspace:model,
            usageLoader: { [archive = model.traces] scope, until, offset in
                try await archive.sessionMetrics(sessionID:scope.sessionID,workspaceID:scope.workspaceID,until:until,offset:offset,includeFamily:scope.includeFamily)
            },cache:InspectorDocumentCache())
        let overview = InspectorOverviewPage(inspector:inspector,compact:true)
        func limitCard() -> NSView? { ConversationPaneTests.views(NSView.self,in:overview).first { $0.accessibilityIdentifier() == "inspector-cost-limit" } }
        XCTAssertNil(limitCard())
        try await model.traces.configure(quota:nil,bodyRetention:86400,metricRetention:86400)
        try await model.restoreSideBudgets()
        model.chats.removeAll { $0.id == main.id }
        try await model.store?.remove(kind:"chat",id:main.id)
        try await model.restoreSideBudgets(); model.refreshCostReading(side.id)
        XCTAssertEqual(model.budgetOwner(for:side).id,side.id)
        XCTAssertNil(view.footer.cost.budgetOwnerID)
        XCTAssertNil(view.footer.cost.budgetSpentUSD)
        XCTAssertNil(view.footer.cost.costAttribution)
        XCTAssertTrue(inspector.display === view,"The open Overview retains the same display and footer")
        try await eventually("orphan gains its budget editor without recreating Overview") { limitCard() != nil }
        let card = try XCTUnwrap(limitCard())
        model.pendingChatIDs.insert(side.id)
        try await model.setCostLimit(.usd(8),for:side.id)
        try await eventually("orphan editor follows its own limit") {
            ConversationPaneTests.views(CostLimitLiveEditor.self,in:card).contains { $0.reading.limit == .usd(8) }
        }
        model.chats.insert(main,at:0); model.refreshCostReading(side.id)
        try await eventually("rebound side relinquishes its budget editor") { limitCard() == nil }
        XCTAssertEqual(view.footer.cost.budgetOwnerID,main.id)
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

    @MainActor func testColdSideKeepFinishesBeforeTheArchiveAndProjectsCostsWhenItOpens() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-keep-budget-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let parent = ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p")
        let file = root.appendingPathComponent("side_side.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SideKeepRecoveryTests.journal(id: "side").write(to: file)
        let side = ChatRecord(id: "side", workspaceID: "w", title: "Side", path: file.path, profileID: "p", parentSessionID: "main")
        model.chats = [parent]
        try await model.store?.put(parent, kind: "chat", id: parent.id)
        try await model.store?.put(SideKeepIntent(chat: side), kind: "side-keep", id: side.id)
        try await model.registerKeptSide(id: side.id, path: file.path)
        XCTAssertNotNil(model.record(side.id)); XCTAssertTrue(model.sideKeepIssues.isEmpty); XCTAssertNil(model.error)
        let initial = await model.traces.savedSideBudgets
        XCTAssertTrue(initial.isEmpty)
        let opened = await model.openConfiguredArchive(VaultConfiguration())
        XCTAssertTrue(opened)
        let projected = await model.traces.savedSideBudgets
        XCTAssertEqual(projected["w\u{0}side"], ["main"])
    }

    @MainActor func testLateSideChildLinksRefreshEveryCurrentFamilyRecipient() async throws {
        for legacyScope in [false, true] {
            let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-links-" + UUID().uuidString)
            let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            let main = ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p")
            let side = ChatRecord(id: "side", workspaceID: "w", title: "Side", path: "/fixture/side_side.jsonl", profileID: "p", parentSessionID: "main")
            model.chats = [main, side]
            try await model.store?.putChats(model.chats)
            model.displays[side.id] = SessionDisplay(id: side.id)
            try await model.traces.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
            try await model.restoreSideBudgets()
            try await eventually("Initial empty accounting settles") { model.accountingTasks.isEmpty }
            var scope = try XCTUnwrap(subagentCaptureScope(source: "child", owner: "side").object)
            if !legacyScope { scope["sideParents"] = .array([.string("main")]) }
            let attempt = UUID().uuidString
            let metadata: [String: WireValue] = ["attemptId": .string(attempt), "sessionId": .string("child"), "turnId": .string("turn"), "purpose": .string("turn"),
                "api": .string("openai-responses"), "mode": .string("off"), "outcome": .string("completed"), "wallTimestamp": .number(Date().timeIntervalSince1970),
                "timingVersion": .number(2), "timings": .object(["dispatch": .number(100)]), "requestScope": .object(scope),
                "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.2)])])]
            try await model.traces.begin(metadata, workspace: "w"); try await model.traces.finish(metadata)
            await model.captureDidPersist(["type": .string("links"), "attemptId": .string(attempt)], workspaceID: "w")
            try await eventually("Late link refreshes the direct owner and main without child discovery", timeout: .seconds(3)) {
                model.displays["side"]?.footer.gateway.costUSD == 0.2 && model.chatStats["main"]?.costUSD == 0.2
            }
            XCTAssertNil(model.record("child"))
            model.chats.removeAll { $0.id == "main" }
            try await model.store?.remove(kind:"chat",id:main.id)
            try await model.restoreSideBudgets()
            let target = try await model.traces.accountingTarget(attemptID: attempt, workspaceID: "w")
            XCTAssertEqual(target?.budgetOwnerSessionID, "side", "The orphan projection replaces historical ancestry")
            XCTAssertEqual(target?.familySessionIDs, ["side"])
            // An old scope on a metadata-only update uses current desktop
            // ancestry without a body read or an unrelated transcript scan.
            model.chats.append(main)
            try await model.store?.put(main,kind:"chat",id:main.id)
            try await model.restoreSideBudgets()
            try await eventually("Projection refresh settles") { model.accountingTasks.isEmpty }
            model.publishChatStats(GatewayTotals(), sessionID: "main")
            await model.captureDidPersist(["type": .string("finish"), "metadata": .object(metadata)], workspaceID: "w")
            try await eventually("Metadata invalidates the current root") { model.chatStats["main"]?.costUSD == 0.2 }
        }
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
