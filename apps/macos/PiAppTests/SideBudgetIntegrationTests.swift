import XCTest
@testable import PiApp

final class SideBudgetIntegrationTests: XCTestCase {
    @MainActor private func fixture() async throws -> WorkspaceModel {
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

    @MainActor func testColdSideOpensPersistedAncestorsMissingFromTheListedChats() async throws {
        let model = try await fixture(), side = try XCTUnwrap(model.record("nested"))
        model.chats = [side]
        let host = try await model.open(side)
        XCTAssertEqual(model.budgetOwner(for: side).id, "main")
        XCTAssertEqual(model.costLimit(for: side), .usd(0.75))
        XCTAssertTrue(Set(["main", "side", "nested"]).isSubset(of: model.opened))
        let status = try await host.request("session.status", sessionID: "main")
        XCTAssertEqual(status.object?["cost"]?.object?["limitUSD"]?.number, 0.75)
    }

    @MainActor func testRestoreKeepsUnlistedAncestorsAndOnlyRetiresDeletedParents() async throws {
        let model = try await fixture(), side = try XCTUnwrap(model.record("nested"))
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
        let model = try await fixture()
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
        let model = try await fixture()
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
        let model = try await fixture(), side = try XCTUnwrap(model.record("nested"))
        try FileManager.default.removeItem(atPath: try XCTUnwrap(side.path))
        do { _ = try await model.open(side); XCTFail("Missing journal must fail") } catch { }
        try await eventually("Failed side open releases its partial ancestry") { model.opened.isEmpty && model.sessionClosings.isEmpty }
        XCTAssertTrue(model.budgetDependencySessions.isEmpty)
    }

    @MainActor func testOpeningDependentPinsAncestorsUntilItFailsOrReleases() async throws {
        let model = try await fixture(), side = try XCTUnwrap(model.record("nested"))
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
        let model = try await fixture()
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
