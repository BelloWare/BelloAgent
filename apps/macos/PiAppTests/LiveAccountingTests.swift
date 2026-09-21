import XCTest
@testable import PiApp

final class LiveAccountingTests: XCTestCase {
    private func folder() throws -> URL {
        let base = testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()
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

    @MainActor func testStreamingSnapshotsOnlyRefreshAccountingWhenVisibleOwnershipChanges() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        let chat = ChatRecord(id: "streaming", workspaceID: "w", title: "Streaming", path: nil, profileID: "p")
        model.chats = [chat]; model.selectedID = chat.id
        let view = SessionDisplay(id: chat.id); view.pageStartEnsured = true
        model.displays[chat.id] = view; model.selected = view
        var sent: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { sent.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID] = host; model.opened.insert(chat.id)
        let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
        var sequence = 0
        @MainActor func snapshot(_ messages: [TranscriptMessage]?, state: String = "running") async throws {
            let count = sent.count; model.refresh(chat.id)
            for _ in 0..<1000 where sent.count == count { await Task.yield() }
            let command = try XCTUnwrap(sent.dropFirst(count).first)
            sequence += 1
            var result: [String: WireValue] = ["seq": .number(Double(sequence)), "state": .string(state),
                "runStatus": .string(state), "displayRevision": .string("projection-\(sequence)")]
            if let messages { result["messages"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(messages)) }
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                "commandId": try XCTUnwrap(command["commandId"]), "ok": .bool(true), "result": .object(result)]), connectionID: connection)
            for _ in 0..<1000 where view.snapshotInFlight { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertFalse(view.snapshotInFlight); XCTAssertEqual(view.notice, "")
        }

        let id = UUID().uuidString, value = metadata(id, session: chat.id)
        let begin: [String: WireValue] = ["type": .string("begin"), "metadata": .object(value)]
        view.messages = [.init(id: "turn", role: "user", text: "Question")]
        try await model.traces.accept(begin, workspace: "w"); await model.captureDidPersist(begin, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(view.messageAccounting["turn"]?.requests, 1)
        let beforeAnswer = view.accountingRevision
        var rows = view.messages + [TranscriptMessage(id: "stream:answer", role: "assistant", text: "First", state: "streaming")]
        try await snapshot(rows); await waitForAccounting(model)
        XCTAssertEqual(view.accountingRevision, beforeAnswer + 1)
        XCTAssertEqual(view.messageAccounting["stream:answer"]?.requests, 1, "An answer appearing after dispatch metadata receives the request")
        XCTAssertNil(view.messageAccounting["turn"], "Its input no longer duplicates that request")
        let streamingRevision = view.accountingRevision
        // Cross the former polling interval without changing retained billing.
        try await Task.sleep(for: .milliseconds(300))
        for index in 0..<12 {
            rows[1].text += " delta-\(index)"; rows[1].thinking = "Thinking \(index)"
            try await snapshot(rows)
        }
        // Status-only completion must not run another historical query either.
        try await snapshot(nil, state: "idle"); await waitForAccounting(model)
        XCTAssertEqual(view.accountingRevision, streamingRevision, "Text/thinking/status pulses do not poll historical accounting")
        let finish: [String: WireValue] = ["type": .string("finish"), "metadata": .object(metadata(id, session: chat.id, cost: 0.006))]
        try await model.traces.accept(finish, workspace: "w"); await model.captureDidPersist(finish, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(view.accountingRevision, streamingRevision + 1)
        XCTAssertEqual(view.footer.gateway.costUSD, 0.006, "A late capture remains authoritative after the last idle snapshot")
        try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testLinkInvalidationOnlyQueriesItsOwnerAndVisibleInheritedOutput() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        for index in 0..<20 {
            let chat = ChatRecord(id: "chat-\(index)", workspaceID: "w", title: "Chat \(index)", path: nil, profileID: "p")
            model.chats.append(chat); model.displays[chat.id] = SessionDisplay(id: chat.id)
        }
        let owner = try XCTUnwrap(model.displays["chat-0"]), inherited = SessionDisplay(id: "side")
        owner.messages = [.init(id: "turn", role: "user", text: "Question"), .init(id: "answer", role: "assistant", text: "Answer")]
        inherited.messages = owner.messages
        model.displays[inherited.id] = inherited; model.selectedID = owner.id; model.selected = owner
        model.sides[owner.id] = SideRecord(id: inherited.id, parentID: owner.id, workspaceID: "w", profileID: "p", title: "Side")
        let id = UUID().uuidString, value = metadata(id, session: owner.id, cost: 0.003)
        try await model.traces.begin(value, workspace: "w"); try await model.traces.finish(value)
        await model.refreshAccounting(owner, workspaceID: "w"); await model.refreshAccounting(inherited, workspaceID: "w")
        XCTAssertEqual(owner.messageAccounting["turn"]?.costUSD, 0.003); XCTAssertNil(inherited.messageAccounting["answer"])
        let links: [String: WireValue] = ["type": .string("links"), "attemptId": .string(id), "outputMessageIds": .array([.string("answer")])]
        try await model.traces.accept(links, workspace: "w"); await model.captureDidPersist(links, workspaceID: "w")
        XCTAssertEqual(Set(model.accountingTasks.keys), [owner.id, inherited.id])
        await waitForAccounting(model)
        XCTAssertEqual(owner.messageAccounting["answer"]?.costUSD, 0.003); XCTAssertNil(owner.messageAccounting["turn"])
        XCTAssertEqual(inherited.messageAccounting["answer"]?.costUSD, 0.003)
        XCTAssertEqual(inherited.footer.gateway.requests, 0, "Inherited attribution does not become the side's own session usage")
        for index in 1..<20 { XCTAssertEqual(model.displays["chat-\(index)"]?.accountingRevision, 0, "An unrelated loaded chat is not invalidated") }
        // The real helper pages links separately and strips both link arrays
        // from finish/metadata. Late billing must resolve its persisted output.
        let late = metadata(id, session: owner.id, cost: 0.004)
        let finish: [String: WireValue] = ["type": .string("finish"), "metadata": .object(late)]
        try await model.traces.accept(finish, workspace: "w"); await model.captureDidPersist(finish, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(owner.messageAccounting["answer"]?.costUSD, 0.004)
        XCTAssertEqual(inherited.messageAccounting["answer"]?.costUSD, 0.004, "Late metadata also refreshes inherited visible billing")
        await model.captureDidPersist(links, workspaceID: "another-workspace")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testMissingLinkOwnerFallsBackToMatchingVisibleOutputUntilMetadataArrives() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        for id in ["owner", "visible", "unrelated"] {
            model.chats.append(ChatRecord(id: id, workspaceID: "w", title: id, path: nil, profileID: "p"))
            model.displays[id] = SessionDisplay(id: id)
        }
        let visible = try XCTUnwrap(model.displays["visible"])
        visible.messages = [.init(id: "answer", role: "assistant", text: "Inherited answer")]
        model.selectedID = visible.id; model.selected = visible
        let id = UUID().uuidString
        await model.captureDidPersist(["type": .string("links"), "attemptId": .string(id), "outputMessageIds": .array([.string("answer")])], workspaceID: "w")
        XCTAssertEqual(Set(model.accountingTasks.keys), [visible.id])
        await waitForAccounting(model)
        let value = metadata(id, session: "owner", cost: 0.005)
        let begin: [String: WireValue] = ["type": .string("begin"), "metadata": .object(value)]
        try await model.traces.accept(begin, workspace: "w")
        let links: [String: WireValue] = ["type": .string("links"), "attemptId": .string(id), "outputMessageIds": .array([.string("answer")])]
        try await model.traces.accept(links, workspace: "w")
        // Simulate the delayed presentation callback after native acceptance.
        await model.captureDidPersist(begin, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(model.displays["owner"]?.footer.gateway.costUSD, 0.005)
        XCTAssertEqual(visible.messageAccounting["answer"]?.costUSD, 0.005)
        XCTAssertEqual(model.displays["unrelated"]?.accountingRevision, 0)
        try await model.traces.close(); await model.store?.close()
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
        try await model.traces.accept(begin, workspace: "w"); await model.captureDidPersist(begin, workspaceID: "w")
        await waitForAccounting(model)
        XCTAssertEqual(view.footer.gateway.requests, 1); XCTAssertNil(view.footer.gateway.costUSD)
        // Billing can commit after the helper's final state event. There is no
        // selection, foreground transition, or extra session snapshot here.
        view.state = "idle"
        let finish: [String: WireValue] = ["type": .string("finish"), "metadata": .object(metadata(id, session: view.id, cost: 0.0013875))]
        try await model.traces.accept(finish, workspace: "w"); await model.captureDidPersist(finish, workspaceID: "w")
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
        await model.captureDidPersist(["type": .string("bytes")], workspaceID: "w")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        let id = UUID().uuidString, value = metadata(id, session: "unloaded", cost: 0.003)
        try await model.traces.begin(value, workspace: "w"); try await model.traces.finish(value)
        let packet: [String: WireValue] = ["type": .string("finish"), "metadata": .object(value)]
        await model.captureDidPersist(packet, workspaceID: "wrong-workspace")
        XCTAssertTrue(model.accountingTasks.isEmpty)
        await model.captureDidPersist(packet, workspaceID: "w")
        await model.captureDidPersist(packet, workspaceID: "w")
        XCTAssertEqual(model.accountingTasks.count, 1)
        await waitForAccounting(model)
        XCTAssertEqual(model.chatStats["unloaded"]?.costUSD, 0.003)
        XCTAssertTrue(model.displays.isEmpty, "Sidebar accounting must not load a conversation or helper")
        XCTAssertTrue(model.hosts.isEmpty)
        model.shutdown(); await model.captureDidPersist(packet, workspaceID: "w")
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
        await model.captureDidPersist(["type": .string("finish"), "metadata": .object(value)], workspaceID: "w")
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

    @MainActor func testFullNativePageKeepsAccountingPastTheOldHundredRowLimit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        let chat = ChatRecord(id: "long-chat", workspaceID: "w", title: "Long chat", path: nil, profileID: "p")
        model.chats = [chat]
        let view = SessionDisplay(id: chat.id)
        view.messages = (0..<600).map { .init(id: "row-\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Row \($0)") }
        model.displays[view.id] = view
        for (input, output, cost) in [(98, 101, 0.001), (200, 201, 0.002), (0, 1, 0.004)] {
            var value = metadata(UUID().uuidString, session: chat.id, cost: cost)
            value["turnId"] = .string("row-\(input)")
            value["messageIds"] = .array([.string("row-\(input)")])
            value["outputMessageIds"] = .array([.string("row-\(output)")])
            try await model.traces.begin(value, workspace: "w"); try await model.traces.finish(value)
        }
        await model.refreshAccounting(view, workspaceID: "w")
        XCTAssertEqual(TranscriptPage.displayPage(view.messages).count, 500)
        XCTAssertEqual(view.footer.gateway.requests, 3)
        XCTAssertEqual(try XCTUnwrap(view.footer.gateway.costUSD), 0.007, accuracy: 0.00000001)
        XCTAssertEqual(view.footer.gatewayNotice, "")
        XCTAssertEqual(view.messageAccounting["row-101"]?.costUSD, 0.001, "An answer remains attributed when its input is outside the native page")
        XCTAssertEqual(view.messageAccounting["row-201"]?.costUSD, 0.002)
        XCTAssertNil(view.messageAccounting["row-200"], "A visible input does not duplicate its visible answer's request")
        XCTAssertEqual(view.messageAccounting["row-1"]?.costUSD,0.004,"The retained earlier window includes this answer")
        XCTAssertEqual(view.messageAccounting.count, 3)
        try await model.traces.close(); await model.store?.close()
    }

}
