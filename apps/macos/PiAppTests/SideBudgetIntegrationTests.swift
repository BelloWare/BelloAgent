import AppKit
import XCTest
@testable import PiApp

final class SideBudgetIntegrationTests: XCTestCase {
    @MainActor func testMissingOwnerReadingCannotOfferContinueFromRetainedCaptureTotals() async throws {
        let model = try await sideBudgetFixture()
        model.budgetStates.removeAll()
        model.publishChatStats(GatewayTotals(requests:1,costSamples:1,costUSD:0.2),sessionID:"main")
        let side = SessionDisplay(id:"side"); model.displays[side.id] = side
        model.observeCost(["cost":.object(["spentUSD":.number(0.1),"reportedRequests":.number(1)])],view:side)
        XCTAssertNil(side.footer.cost.budgetSpentUSD,"Retained captures are not the authoritative budget ledger")
        XCTAssertTrue(side.costLimitHeld,"Unknown owner spend must not unlock Continue")
    }

    @MainActor func testOpeningATranscriptPreservesTheAuthoritativeBudgetReading() async throws {
        let model = try await sideBudgetFixture()
        model.observeCost(["cost":.object(["spentUSD":.number(1.2),"reportedRequests":.number(2),"limitUSD":.number(0.75)])],sessionID:"main")
        let display = SessionDisplay(id:"main"); model.displays[display.id] = display
        XCTAssertEqual(display.footer.cost.spentUSD,1.2)
        XCTAssertTrue(display.costLimitHeld)
    }

    @MainActor func testBudgetOnlyRefreshCoalescesAndRejectsRetiredRuntimeReplies() async throws {
        let model = try await sideBudgetFixture()
        await model.stopHostsAndWait()
        var frames: [[String:WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd:model.root,state:model.root.appendingPathComponent("budget-host"))
        model.hosts["w"] = host; model.boundHostConnections["w"] = host.connectionID
        model.opened = ["main","side"]; model.budgetDependencySessions = ["main"]
        model.displays["side"] = SessionDisplay(id:"side")
        func reply(_ index: Int, _ spend: Double) throws {
            XCTAssertEqual(frames[index]["method"]?.string,"session.status")
            XCTAssertEqual(frames[index]["params"]?.object?["budgetOnly"],.bool(true))
            host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(try XCTUnwrap(host.epoch)),
                "commandId":try XCTUnwrap(frames[index]["commandId"]),"ok":.bool(true),
                "result":.object(["cost":.object(["spentUSD":.number(spend),"limitUSD":.number(0.75),"reportedRequests":.number(2)])])]),connectionID:try XCTUnwrap(host.connectionID))
        }
        model.refresh("main")
        try await eventually("First budget read") { frames.count == 1 }
        for _ in 0..<20 { model.refresh("main") }
        XCTAssertEqual(frames.count,1)
        try reply(0,0.4)
        try await eventually("One follow-up carries all invalidations") { frames.count == 2 }
        try reply(1,1.4)
        try await eventually("Authoritative root warns its side") {
            model.displays["side"]?.footer.cost.budgetSpentUSD == 1.4 && model.budgetStates["main"]?.readTask == nil
        }
        XCTAssertTrue(model.displays["side"]?.costLimitHeld == true)
        model.refresh("main")
        try await eventually("Held retired read") { frames.count == 3 }
        let retired = model.budgetStates["main"]?.readTask
        model.helperSessionDidUnload("main")
        model.opened.insert("main"); model.budgetDependencySessions.insert("main")
        model.refresh("main")
        try await eventually("Replacement runtime read") { frames.count == 4 }
        try reply(3,1.6)
        try await eventually("Replacement reading published") { model.budgetStates["main"]?.reading.spentUSD == 1.6 }
        try reply(2,0.1)
        await retired?.value
        XCTAssertEqual(model.budgetStates["main"]?.reading.spentUSD,1.6)
        XCTAssertEqual(model.displays["side"]?.footer.cost.budgetSpentUSD,1.6)
        XCTAssertNil(model.displays["main"])
    }

    @MainActor func testBudgetOnlyOwnerPublishesDurableSpendWithoutATranscript() async throws {
        let model = try await sideBudgetFixture()
        model.costSeedRead = { item in item.id == "main" ? .object(["usd":.number(1.2),"reported":.number(2),"unreported":.number(0)]) : nil }
        let nested = try XCTUnwrap(model.record("nested"))
        let view = SessionDisplay(id:nested.id); model.displays[nested.id] = view
        _ = try await model.open(nested)
        model.refreshCostReading(nested.id)
        XCTAssertEqual(model.costReading(for:nested.id).budgetSpentUSD,1.2)
        XCTAssertTrue(model.costReading(for:nested.id).reached,"Continue must stay blocked after capture expiration")
        XCTAssertTrue(view.footer.cost.reached)
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        try await model.setCostLimit(.usd(2),for:"main")
        try await eventually("Shared warning follows the raised owner limit") { view.footer.cost.limit == .usd(2) && !view.footer.cost.reached }
        XCTAssertNil(model.displays["main"])
    }

    @MainActor func testPersistedUnlistedSideAncestryRetiresAfterParentDeletionAndReload() async throws {
        let model = try await sideBudgetFixture(), parent = try XCTUnwrap(model.record("main"))
        let store = try XCTUnwrap(model.store)
        let fillers = (0..<10_001).map { ChatRecord(id:"filler-\($0)",workspaceID:"w",title:"Chat",profileID:"p") }
        try await store.putChats(fillers)
        try await store.put(parent,kind:"chat",id:parent.id)
        model.chats = try await store.loadChats()
        XCTAssertNil(model.record("side")); XCTAssertNil(model.record("nested"))
        try await model.traces.recordSideBudgets(["side":["main"],"nested":["side","main"]],workspaceID:"w")
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at:url) } }
        try await model.deleteSubagentFamily(parent)
        for _ in 0..<2 {
            try await model.restoreSideBudgets()
            let mappings = await model.traces.savedSideBudgets
            XCTAssertEqual(mappings["w\u{0}side"],[])
            XCTAssertEqual(mappings["w\u{0}nested"],["side"])
            XCTAssertNil(model.record("side"),"Repairing accounting must not expand the chat window with descendants")
            model.chats = try await store.loadChats()
        }
    }
    @MainActor func testColdSideOpensPersistedAncestorsMissingFromTheListedChats() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        model.chats = [side]
        let host = try await model.open(side)
        XCTAssertEqual(model.budgetOwner(for: side).id, "main")
        XCTAssertEqual(model.costLimit(for: side), .usd(0.75))
        XCTAssertTrue(Set(["main", "side", "nested"]).isSubset(of: model.opened))
        let status = try await host.request("session.status", sessionID: "main")
        XCTAssertEqual(status.object?["cost"]?.object?["limitUSD"]?.number, 0.75)
    }

    @MainActor func testRestoreKeepsUnlistedAncestorsAndOnlyRetiresDeletedParents() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        model.chats = [side]
        try await model.restoreSideBudgets()
        var parents = await model.traces.savedSideBudgets
        XCTAssertEqual(parents["w\u{0}nested"], ["side", "main"])
        XCTAssertEqual(model.budgetOwner(for: side).id, "main")
        let parent = try XCTUnwrap(model.record("main"))
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        try await model.deleteSubagentFamily(parent)
        parents = await model.traces.savedSideBudgets
        XCTAssertEqual(parents["w\u{0}nested"], ["side"])
        XCTAssertNil(model.record("main"))
        _ = try await model.open(side)
        XCTAssertEqual(model.budgetOwner(for: side).id, "side")
    }

    @MainActor func testLastDependentReleaseUnloadsImplicitAncestorsButKeepsDirectUses() async throws {
        let model = try await sideBudgetFixture()
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        _ = try await model.open(try XCTUnwrap(model.record("sibling")))
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        model.releaseHelperSession("nested")
        try await eventually("Nested dependency is released", timeout: .seconds(5)) { !model.opened.contains("nested") && !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main"), "The sibling still pins the root")
        model.releaseHelperSession("sibling")
        try await eventually("Last side releases its budget writer", timeout: .seconds(5)) { model.opened.isEmpty }

        let host = try await model.open(try XCTUnwrap(model.record("main")))
        _ = try await model.open(try XCTUnwrap(model.record("side")))
        model.releaseHelperSession("side")
        try await eventually("Side release settles") { !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main"), "A direct open has independent lifetime")
        _ = try await host.request("session.status", sessionID: "main")
    }
    @MainActor func testConcurrentSideOpensShareAndReleaseTheirImplicitWriter() async throws {
        let model = try await sideBudgetFixture()
        let (held, release) = AsyncStream<Never>.makeStream()
        model.sessionClosings["main"] = (UUID(), Task { for await _ in held {} })
        let side = try XCTUnwrap(model.record("side")), sibling = try XCTUnwrap(model.record("sibling"))
        let first = Task { try await model.open(side) }, second = Task { try await model.open(sibling) }
        try await eventually("Both dependents wait for the previous owner close") { model.budgetOpenCallers["main"] == 2 }
        model.sessionClosings.removeValue(forKey: "main"); release.finish()
        _ = try await first.value; _ = try await second.value
        XCTAssertTrue(model.budgetDependencySessions.contains("main"), "Concurrent budget opens must not look like a direct user open")
        model.releaseHelperSession("side"); model.releaseHelperSession("sibling")
        try await eventually("The shared writer releases after both sides", timeout: .seconds(3)) { model.opened.isEmpty }
        let (nextHeld, nextRelease) = AsyncStream<Never>.makeStream()
        model.sessionClosings["main"] = (UUID(), Task { for await _ in nextHeld {} })
        let main = try XCTUnwrap(model.record("main"))
        let direct = Task { try await model.open(main) }, dependent = Task { try await model.open(side) }
        try await eventually("A direct use shares the pending writer") { model.budgetOpenCallers["main"] == 2 }
        model.sessionClosings.removeValue(forKey: "main"); nextRelease.finish()
        _ = try await direct.value; _ = try await dependent.value
        model.releaseHelperSession("side")
        try await eventually("Dependent is released") { !model.opened.contains("side") }
        XCTAssertTrue(model.opened.contains("main")); XCTAssertFalse(model.budgetDependencySessions.contains("main"))
    }

    @MainActor func testFailedSideOpenReleasesPartiallyOpenedAncestors() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        try FileManager.default.removeItem(atPath: try XCTUnwrap(side.path))
        do { _ = try await model.open(side); XCTFail("Missing journal must fail") } catch { }
        try await eventually("Failed side open releases its partial ancestry") { model.opened.isEmpty && model.sessionClosings.isEmpty }
        XCTAssertTrue(model.budgetDependencySessions.isEmpty)
    }

    @MainActor func testOpeningDependentPinsAncestorsUntilItFailsOrReleases() async throws {
        let model = try await sideBudgetFixture(), side = try XCTUnwrap(model.record("nested"))
        var held: CheckedContinuation<WireValue?, Never>?
        model.costSeedRead = { item in
            if item.id == side.id { return await withCheckedContinuation { held = $0 } }
            return nil
        }
        let opening = Task { try await model.open(side) }
        try await eventually("The child is held before its runtime opens") { held != nil }
        model.releaseHelperSession("main"); model.releaseHelperSession("side")
        XCTAssertTrue(model.sessionClosings.isEmpty, "Credential/seed reads pin the budget before session.open is sent")
        XCTAssertTrue(model.opened.contains("main")); XCTAssertTrue(model.opened.contains("side"))
        held?.resume(returning: nil); held = nil
        _ = try await opening.value
        model.releaseHelperSession(side.id)
        try await eventually("Pending release runs after the last child unload") { model.opened.isEmpty && model.sessionClosings.isEmpty }
    }

    @MainActor func testConfigurationFallbackRetainsAnOwnerWhoseUnloadIsRejected() async throws {
        let model = try await sideBudgetFixture()
        await model.stopHostsAndWait()
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: model.root, state: model.root.appendingPathComponent("mock-host"))
        model.hosts["w"] = host; model.boundHostConnections["w"] = host.connectionID
        model.opened = ["main", "side"]
        let profile = try XCTUnwrap(model.profiles.first)
        var finished = false
        let saving = Task { defer { finished = true }; try await model.saveProfile(profile, key: "synthetic-unused-key") }
        var replied = 0
        while !finished {
            try await eventually("Configuration command or completion") { finished || frames.count > replied }
            while replied < frames.count {
                let frame = frames[replied]; replied += 1
                let rejected = frame["method"]?.string == "session.configure" || frame["sessionId"]?.string == "main"
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                    "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(!rejected), "result": .object([:]),
                    "error": .object(["code": .string("session_busy"), "message": .string("Synthetic pinned owner")])]), connectionID: try XCTUnwrap(host.connectionID))
            }
        }
        try await saving.value
        XCTAssertTrue(model.opened.contains("main"), "A busy acknowledgement cannot forget the loaded owner")
        XCTAssertFalse(model.opened.contains("side"))
    }

}

// This class opens the real Inspector window; run it alone in the serial lane.
final class SideBudgetInspectorLifetimeTests: XCTestCase, SerialTestLane {
    @MainActor func testRaiseLimitFromNestedSideHasAnEditableOwnerWithoutADisplay() async throws {
        let model = try await sideBudgetFixture()
        model.costSeedRead = { item in item.id == "main" ? .object(["usd":.number(1.2),"reported":.number(2),"unreported":.number(0)]) : nil }
        _ = try await model.open(try XCTUnwrap(model.record("nested")))
        model.costLimitNotice(.raise,sessionID:"nested",anchor:NSView())
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID:"main"))
        let content = try XCTUnwrap(controller.window?.contentView)
        try await eventually("Raise limit presents the owner editor") { !ConversationPaneTests.views(CostLimitLiveEditor.self,in:content).isEmpty }
        let editor = try XCTUnwrap(ConversationPaneTests.views(CostLimitLiveEditor.self,in:content).first)
        XCTAssertEqual(editor.reading.spentUSD,1.2)
        try await editor.choose(.usd(2))
        try await eventually("Owner editor follows its saved value") { editor.reading.limit == .usd(2) }
        XCTAssertEqual(model.costReading(for:"nested").limit,.usd(2))
        XCTAssertFalse(model.costReading(for:"nested").reached)
        XCTAssertNil(model.displays["main"]); XCTAssertNil(model.displays["side"])
        controller.close()
    }
    @MainActor func testInspectorPinsAnImplicitWriterUntilItsWindowCloses() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-budget-inspector-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p")]
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts["w"] = host; model.opened = ["main"]; model.budgetDependencySessions = ["main"]
        let inspector = SessionInspectorWindows.shared.show(model: model, sessionID: "main", workspaceID: "w", title: "Main", focus: .overview)
        model.releaseUnusedBudgetSessions()
        XCTAssertTrue(model.sessionClosings.isEmpty); XCTAssertTrue(frames.isEmpty)
        inspector.close()
        try await eventually("Closing the last Inspector releases the budget-only runtime") { !frames.isEmpty }
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame["method"]?.string, "session.close")
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]), connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("The unload is acknowledged") { model.opened.isEmpty && model.sessionClosings.isEmpty }
        XCTAssertTrue(model.budgetDependencySessions.isEmpty)
    }
}

extension XCTestCase {
    @MainActor fileprivate func sideBudgetFixture() async throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-budget-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "fixture"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: "main", workspaceID: "w", title: "Main", profileID: "p", costLimit: .usd(0.75))
        try await model.store?.put(parent, kind: "chat", id: parent.id); model.chats = [parent]
        let host = try await model.open(parent)
        for (id, owner) in [("side", "main"), ("nested", "side"), ("sibling", "main")] {
            _ = try await host.request("side.open", sessionID: owner, params: ["sideSessionId": .string(id)])
            let result = try await host.request("side.keep", sessionID: id)
            let record = ChatRecord(id: id, workspaceID: "w", title: id, path: result.object?["path"]?.string,
                                    profileID: "p", toolMode: ChatRecord.readOnlyTools, parentSessionID: owner, costLimit: .usd(99))
            XCTAssertNotNil(record.path)
            try await model.store?.put(record, kind: "chat", id: id); model.chats.append(record)
        }
        // Keep the process alive, but release every runtime to model a cold
        // visit. No request is sent to the synthetic connection.
        for id in ["nested", "sibling", "side", "main"] { _ = try await host.request("session.close", sessionID: id) }
        model.opened.removeAll(); model.displays.removeAll()
        return model
    }

}
