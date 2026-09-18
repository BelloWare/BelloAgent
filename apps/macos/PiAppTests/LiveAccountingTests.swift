import XCTest
@testable import PiApp

final class LiveAccountingTests: XCTestCase {
    private func folder() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PI_BUILD_ROOT"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("live-accounting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func metadata(_ id: String, session: String, cost: Double? = nil) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("turn"),
         "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("auto-router"),
         "mode": .string("off"), "wallTimestamp": .number(Date().timeIntervalSince1970),
         "timingVersion": .number(2), "timings": .object(["dispatch": .number(100)]),
         "outcome": .string(cost == nil ? "running" : "completed"),
         "usage": .object(["inputIncludingCache": .number(38), "output": .number(302), "total": .number(340), "reasoning": .number(253)]),
         "gateway": .object(["version": .number(1), "cost": .object([
            "status": .string(cost == nil ? "unreported" : "reported"),
            "usd": cost.map(WireValue.number) ?? .null, "source": .string("header:x-litellm-response-cost")])])]
    }

    @MainActor private func waitForAccounting(_ model: WorkspaceModel) async {
        for _ in 0..<100 where !model.accountingTasks.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.accountingTasks.isEmpty, "Accounting invalidation must settle without a focus event")
    }

    @MainActor func testUnfocusedRunningChatReceivesLateBillingAfterItsLastStatusEvent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "background", workspaceID: "w", title: "Background", path: nil, profileID: "p")]
        model.selectedID = "another-chat"; model.selectedWorkspaceID = "other-workspace"; model.page = .report
        let view = SessionDisplay(id: "background"); view.state = "running"; model.displays[view.id] = view
        let id = UUID().uuidString
        let begin: [String: WireValue] = ["type": .string("begin"), "metadata": .object(metadata(id, session: view.id))]
        try await model.traces.accept(begin, workspace: "w"); model.captureDidPersist(begin, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(view.footer.gateway.requests, 1); XCTAssertNil(view.footer.gateway.costUSD)
        // Billing can commit after the helper's final state event. There is no
        // selection, foreground transition, or extra session snapshot here.
        view.state = "idle"
        let finish: [String: WireValue] = ["type": .string("finish"), "metadata": .object(metadata(id, session: view.id, cost: 0.0013875))]
        try await model.traces.accept(finish, workspace: "w"); model.captureDidPersist(finish, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(view.footer.gateway.costUSD, 0.0013875)
        XCTAssertEqual(model.chatStats[view.id]?.costUSD, 0.0013875)
        XCTAssertEqual(view.footer.gateway.tokens?.total, 340)
        XCTAssertEqual(model.selectedID, "another-chat"); XCTAssertEqual(model.page, .report)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testUnloadedRowReceivesLateCostAndBodyPagesDoNotTriggerAccountingQueries() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "unloaded", workspaceID: "w", title: "Unloaded", path: nil, profileID: "p")]
        model.captureDidPersist(["type": .string("bytes")], workspaceID: "w")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        let id = UUID().uuidString, value = metadata(id, session: "unloaded", cost: 0.003)
        try await model.traces.begin(value, workspace: "w"); try await model.traces.finish(value)
        let packet: [String: WireValue] = ["type": .string("finish"), "metadata": .object(value)]
        model.captureDidPersist(packet, workspaceID: "wrong-workspace")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        model.captureDidPersist(packet, workspaceID: "w")
        model.captureDidPersist(packet, workspaceID: "w")
        XCTAssertEqual(model.accountingTasks.count, 1)
        await waitForAccounting(model)
        XCTAssertEqual(model.chatStats["unloaded"]?.costUSD, 0.003)
        XCTAssertTrue(model.displays.isEmpty, "Sidebar accounting must not load a conversation or helper")
        XCTAssertTrue(model.hosts.isEmpty)
        model.shutdown(); model.captureDidPersist(packet, workspaceID: "w")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        try await model.traces.close(); await model.store?.close()
    }
    @MainActor func testRestoreLoadsTotalsAcrossEveryProjectWithoutOpeningHosts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "one", workspaceID: "first", title: "One", path: nil, profileID: "p"),
                       ChatRecord(id: "two", workspaceID: "second", title: "Two", path: nil, profileID: "p")]
        for (index, chat) in model.chats.enumerated() {
            let value = metadata(UUID().uuidString, session: chat.id, cost: Double(index + 1) / 1000)
            try await model.traces.begin(value, workspace: chat.workspaceID); try await model.traces.finish(value)
        }
        model.selectedWorkspaceID = "first"
        await model.refreshChatStats()
        XCTAssertEqual(model.chatStats["one"]?.costUSD, 0.001)
        XCTAssertEqual(model.chatStats["two"]?.costUSD, 0.002)
        model.selectedWorkspaceID = "second"
        await model.refreshChatStats()
        XCTAssertEqual(model.chatStats.count, 2, "Switching projects must retain other project rows")
        XCTAssertTrue(model.displays.isEmpty); XCTAssertTrue(model.hosts.isEmpty)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testDelayedBulkQueryCannotRewindLateCommittedBilling() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        model.chats = [ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p")]
        var releaseQuery: CheckedContinuation<Void, Never>?
        let bulk = Task { @MainActor in
            await model.refreshChatStats { _ in
                await withCheckedContinuation { releaseQuery = $0 }
                return GatewayTotals(requests: 1, costSamples: 0)
            }
        }
        while releaseQuery == nil { await Task.yield() }
        let value = metadata(UUID().uuidString, session: "chat", cost: 0.0013875)
        try await model.traces.begin(value, workspace: "w"); try await model.traces.finish(value)
        model.captureDidPersist(["type": .string("finish"), "metadata": .object(value)], workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(model.chatStats["chat"]?.costUSD, 0.0013875)
        releaseQuery?.resume(); await bulk.value
        XCTAssertEqual(model.chatStats["chat"]?.costUSD, 0.0013875, "A pre-billing query must not overwrite final cost")
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testEvictingAnIdleDisplayCannotInvalidateItsPendingFinalBillingRead() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        // Up to eight hidden chats keep their pages; the ninth selection evicts the oldest idle one.
        for index in 0..<10 {
            let id = "chat-\(index)"
            model.chats.append(ChatRecord(id: id, workspaceID: "w", title: id, path: nil, profileID: "p"))
            let display = SessionDisplay(id: id); display.used = Date(timeIntervalSince1970: Double(index))
            model.displays[id] = display
        }
        let evicted = try XCTUnwrap(model.displays["chat-0"])
        evicted.footer.gateway = GatewayTotals(requests: 1, costSamples: 0)
        model.publishChatStats(evicted.footer.gateway, sessionID: evicted.id)
        var releaseQuery: CheckedContinuation<Void, Never>?
        let finalRead = Task { @MainActor in
            await model.refreshAccounting(evicted, workspaceID: "w") {
                await withCheckedContinuation { releaseQuery = $0 }
                return SessionGatewayAccounting(session: GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.004))
            }
        }
        while releaseQuery == nil { await Task.yield() }
        await model.select("chat-4")
        XCTAssertNil(model.displays[evicted.id], "Selecting another chat evicts the oldest idle display")
        releaseQuery?.resume(); await finalRead.value
        XCTAssertEqual(model.chatStats[evicted.id]?.costUSD, 0.004, "Eviction must not promote a stale footer above a final billing read")
        XCTAssertEqual(model.selectedID, "chat-4")
        try await model.traces.close(); await model.store?.close()
    }

}
