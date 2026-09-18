import XCTest
@testable import PiApp

final class SideTests: XCTestCase {
    @MainActor func testExactSideAndForkEnterUsePackagedHelperWithoutSendingAndClosedSideSurvivesRestart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "router"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        }
        let state = root.appendingPathComponent("state"), model = WorkspaceModel(stateRoot: state, vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: "parent", workspaceID: workspace.id, title: "Source", path: nil, profileID: profile.id, model: "selected-model", thinkingLevel: "high", contextWindow: 64_000, maxOutputTokens: 8_000)
        try await model.store?.put(parent, kind: "chat", id: parent.id); model.chats = [parent]
        await model.select(parent.id)
        let view = try XCTUnwrap(model.selected)
        view.draft = "/side"; view.directCommand = true; view.completionVisible = true
        XCTAssertTrue(model.completionKey(36, view: view), "Exact /side should execute on the first Return")
        XCTAssertEqual(view.draft, "")
        // An empty side is only on screen until its first message: no helper session, no chat record.
        let pending = try XCTUnwrap(model.sides[parent.id])
        XCTAssertTrue(pending.pending); XCTAssertTrue(model.hosts.isEmpty); XCTAssertNil(model.chats.first { $0.id == pending.id })
        XCTAssertEqual(model.focusedSessionID, pending.id)
        // The first message publishes it through the packaged helper (send() does this before submitting).
        try await model.publishPendingSide(pending, view: try XCTUnwrap(model.displays[pending.id]))
        for _ in 0..<500 {
            if let side = model.sides[parent.id], side.kept, model.displays[side.id]?.loading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let side = try XCTUnwrap(model.sides[parent.id]), saved = try XCTUnwrap(model.chats.first { $0.id == side.id })
        XCTAssertTrue(side.kept); XCTAssertEqual(saved.parentSessionID, parent.id)
        XCTAssertEqual(saved.model, parent.model); XCTAssertEqual(saved.thinkingLevel, parent.thinkingLevel)
        XCTAssertEqual(saved.contextWindow, parent.contextWindow); XCTAssertEqual(saved.maxOutputTokens, parent.maxOutputTokens)
        XCTAssertEqual(model.displays[side.id]?.captureMode, "persist")
        let host = try XCTUnwrap(model.hosts[workspace.id])
        let initial = try await host.request("session.snapshot", sessionID: side.id).object ?? [:]
        XCTAssertTrue(initial["messages"]?.array?.isEmpty == true)
        let attempts = try await host.request("debug.list", sessionID: side.id).object ?? [:]
        XCTAssertEqual(attempts["total"]?.number, 0, "Opening /side never sends a provider request")
        model.displays[side.id]?.draft = "Saved unfinished question"
        let parentFocus = view.composerFocusRequest
        model.closeSide(side.id)
        for _ in 0..<200 where model.sides[parent.id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.sides[parent.id]); XCTAssertNotNil(model.record(side.id))
        XCTAssertEqual(model.focusedSessionID, parent.id); XCTAssertGreaterThan(view.composerFocusRequest, parentFocus, "Closing the side puts the cursor back in the parent's composer")
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: side.id)
        XCTAssertEqual(draft?.text, "Saved unfinished question")

        view.draft = "/fork"; view.directCommand = true; view.completionVisible = true
        XCTAssertTrue(model.completionKey(36, view: view), "Exact /fork should also execute on the first Return")
        for _ in 0..<500 where view.loading { try await Task.sleep(for: .milliseconds(10)) }
        let fork = try XCTUnwrap(model.chats.first { $0.id != parent.id && $0.id != side.id })
        XCTAssertNil(fork.parentSessionID); XCTAssertEqual(fork.toolMode, "editing")
        XCTAssertEqual(fork.model, parent.model); XCTAssertEqual(fork.thinkingLevel, parent.thinkingLevel)
        XCTAssertEqual(fork.contextWindow, parent.contextWindow); XCTAssertEqual(fork.maxOutputTokens, parent.maxOutputTokens)
        let forkAttempts = try await host.request("debug.list", sessionID: fork.id).object ?? [:]
        XCTAssertEqual(forkAttempts["total"]?.number, 0)
        model.shutdown(); try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()

        let restored = WorkspaceModel(stateRoot: state, vault: vault)
        await restored.restore()
        XCTAssertEqual(restored.chats.first { $0.id == side.id }?.parentSessionID, parent.id)
        XCTAssertNotNil(restored.chats.first { $0.id == fork.id && $0.parentSessionID == nil })
        await restored.select(side.id); XCTAssertEqual(restored.selected?.draft, "Saved unfinished question")
        XCTAssertTrue(restored.hosts.isEmpty, "Reading a saved child after restart does not open a gateway")
        restored.shutdown(); try await restored.traces.close(); await restored.store?.close()
    }
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("native-side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @MainActor func testEphemeralDraftsAndAnchorsNeverEnterSQLiteAndBringBackDoesNotSubmit() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), parent = SessionDisplay(id: "main"), side = SessionDisplay(id: "side")
        parent.draft = "original draft"; parent.state = "running"; side.draft = "ephemeral secret"
        model.displays = ["main": parent, "side": side]
        model.sides["main"] = SideRecord(id: "side", parentID: "main", workspaceID: "w", profileID: "p", title: "side")
        model.draftChanged(side); model.anchorChanged(side)
        try await Task.sleep(for: .milliseconds(200))
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: "side")
        XCTAssertNil(draft); XCTAssertTrue(model.hasActiveWork)
        try model.bringBack("edited summary", from: "side", replace: false)
        XCTAssertEqual(parent.draft, "original draft\n\nedited summary"); XCTAssertEqual(parent.state, "running"); XCTAssertFalse(parent.directCommand)
        try model.bringBack("replacement", from: "side", replace: true); XCTAssertEqual(parent.draft, "replacement")
        XCTAssertTrue(model.hosts.isEmpty)
        let intents = try await model.store?.list(CommandIntent.self, kind: "pending:main")
        XCTAssertEqual(intents?.count, 0)
        XCTAssertThrowsError(try model.bringBack(String(repeating: "x", count: 262_145), from: "side", replace: true))
        model.shutdown()
    }
    @MainActor func testLostKeepAcknowledgementRecoversFileWithoutStartingAHostAndRetainsReadOnlyMode() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let path = root.appendingPathComponent("Workspaces/w/Sessions/side_side.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"side\"}\n{\"type\":\"message\",\"id\":\"a\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"retained 🌍\"}}\n".utf8)
        try bytes.write(to: path)
        let chat = ChatRecord(id: "side", workspaceID: "w", title: "Kept side", path: path.path, profileID: "p", toolMode: "read-only")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: "side")
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.chats.first?.toolMode, "read-only"); XCTAssertEqual(model.chats.first?.path, path.path)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertEqual(try Data(contentsOf: path), bytes)
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: "side")
        XCTAssertNil(intent)
        await model.reconcileSideKeeps(); XCTAssertEqual(model.chats.count, 1)
    }
    @MainActor func testFailedKeepValidationPreservesRecoveryIntentAndHostLossDiscardsOnlyUnkeptMemory() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), path = root.appendingPathComponent("side.jsonl")
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"wrong\"}\n".utf8).write(to: path)
        let chat = ChatRecord(id: "side", workspaceID: "w", title: "side", path: path.path, profileID: "p", toolMode: "read-only")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: "side")
        await model.reconcileSideKeeps(); XCTAssertNotNil(model.error); XCTAssertTrue(model.chats.isEmpty)
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: "side"); XCTAssertNotNil(intent)
        model.sides["parent"] = SideRecord(id: "ephemeral", parentID: "parent", workspaceID: "w", profileID: "p", title: "side")
        model.displays["parent"] = SessionDisplay(id: "parent"); model.displays["ephemeral"] = SessionDisplay(id: "ephemeral")
        model.discardLostSides(workspaceID: "w"); XCTAssertTrue(model.sides.isEmpty); XCTAssertNil(model.displays["ephemeral"]); XCTAssertNotNil(model.displays["parent"])
    }
}
