import XCTest
@testable import PiApp

private struct ConcurrentOpenObservation: Sendable {
    let id: String
    let connection: UUID?
    let snapshot: [String: WireValue]
    let requests: Double?
    let captureReady: Bool
}

private final class DelayedConcurrencyVault: VaultStorage, @unchecked Sendable {
    private let storage = MemoryVaultStorage(), lock = NSLock()
    private var entered: XCTestExpectation?
    let resume = DispatchSemaphore(value: 0)
    func holdNextRead(_ expectation: XCTestExpectation) { lock.lock(); entered = expectation; lock.unlock() }
    func read() throws -> Data? {
        lock.lock(); let gate = entered; entered = nil; lock.unlock()
        if let gate { gate.fulfill(); resume.wait() }
        return try storage.read()
    }
    func replace(expected: Data?, with replacement: Data) throws { try storage.replace(expected: expected, with: replacement) }
}

@MainActor private final class ConcurrencyHeartbeat {
    private(set) var samples = 0
    private(set) var maximumGap = 0.0
    private var last = ProcessInfo.processInfo.systemUptime
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maximumGap = max(maximumGap, now - last); last = now; samples += 1
    }
}

final class WorkspaceConcurrencyTests: XCTestCase {
    @MainActor private func fixture(count: Int, storage: any VaultStorage = MemoryVaultStorage()) async throws -> WorkspaceModel {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("workspace-concurrency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "connection"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "router"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("empty-codex").path)])
            for index in 0..<count where index % 2 == 0 { $0.capture.sessionModes["session-\(index)"] = "off" }
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        for index in 0..<count {
            let id = "session-\(index)", chat = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: profile.id)
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: id)
            let display = SessionDisplay(id: id); display.draft = "Unsent draft for \(id)"; model.displays[id] = display
        }
        model.selectedID = model.chats.first?.id; model.selected = model.selectedID.flatMap { model.displays[$0] }
        return model
    }

    @MainActor private func openTogether(_ chats: [ChatRecord], model: WorkspaceModel) async throws -> [ConcurrentOpenObservation] {
        // Start every MainActor task before awaiting any result. The operations
        // overlap at their real IPC/storage awaits while preserving isolation.
        let tasks: [Task<ConcurrentOpenObservation, Error>] = chats.map { chat in
            Task { @MainActor [model, chat] in
                let host = try await model.open(chat)
                // Check readiness at the instant open returns, before another
                // command can give an unfinished debug.mode time to catch up.
                let captureReady = model.displays[chat.id]?.captureAvailable == true
                let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
                let requests = try await host.request("debug.list", sessionID: chat.id).object?["total"]?.number
                return ConcurrentOpenObservation(id: chat.id, connection: host.connectionID, snapshot: snapshot,
                                                 requests: requests, captureReady: captureReady)
            }
        }
        do {
            var results: [ConcurrentOpenObservation] = []
            for task in tasks { results.append(try await task.value) }
            return results
        } catch {
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            throw error
        }
    }

    @MainActor func testTwentyColdSessionsShareWorkspaceInitializationAndSettleRefreshBursts() async throws {
        let model = try await fixture(count: 20), heartbeat = ConcurrencyHeartbeat()
        let displayIdentities = model.displays.mapValues(ObjectIdentifier.init)
        let pulse = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                heartbeat.tick()
            }
        }
        defer { pulse.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let observations = try await openTogether(model.chats, model: model)
        let openedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(observations.count, 20)
        XCTAssertEqual(Set(observations.map(\.id)), Set(model.chats.map(\.id)))
        XCTAssertEqual(Set(observations.compactMap(\.connection)).count, 1, "Twenty sessions share one fully bound project host")
        XCTAssertEqual(model.hosts.count, 1); XCTAssertEqual(model.opened, Set(model.chats.map(\.id)))
        XCTAssertEqual(Set(model.chats.compactMap(\.path)).count, 20, "Each session owns a distinct durable journal")
        XCTAssertEqual(Set(displayIdentities.values).count, 20)
        for observation in observations {
            let index = try XCTUnwrap(Int(observation.id.replacingOccurrences(of: "session-", with: "")))
            XCTAssertTrue(observation.captureReady)
            XCTAssertEqual(observation.snapshot["sessionId"], .string(observation.id))
            XCTAssertEqual(observation.snapshot["state"], .string("idle"))
            XCTAssertEqual(observation.snapshot["messages"]?.array?.count, 0)
            XCTAssertEqual(observation.snapshot["queueCount"], .number(0))
            XCTAssertEqual(observation.snapshot["captureMode"], .string(index % 2 == 0 ? "off" : "persist"))
            XCTAssertEqual(observation.requests, 0, "Opening a session must not dispatch generation")
            let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: observation.id)
            XCTAssertEqual(saved?.path, model.record(observation.id)?.path)
            let path = try XCTUnwrap(saved?.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        // Repeated invalidations arrive while the first snapshot is in flight.
        // Each session coalesces its own work without stealing another's state.
        for _ in 0..<50 { for chat in model.chats { model.refresh(chat.id) } }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, model.displays.values.contains(where: { $0.snapshotInFlight || $0.dirty }) || !model.accountingTasks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        pulse.cancel(); await pulse.value
        XCTAssertTrue(model.accountingTasks.isEmpty)
        XCTAssertTrue(model.dirtyAccounting.isEmpty)
        for chat in model.chats {
            let display = try XCTUnwrap(model.displays[chat.id])
            XCTAssertEqual(ObjectIdentifier(display), displayIdentities[chat.id])
            XCTAssertEqual(display.draft, "Unsent draft for \(chat.id)")
            XCTAssertEqual(display.state, "idle"); XCTAssertGreaterThanOrEqual(display.lastSequence, 0)
            XCTAssertFalse(display.snapshotInFlight); XCTAssertFalse(display.dirty)
            XCTAssertEqual(display.notice, ""); XCTAssertEqual(display.footer.gatewayNotice, "")
            XCTAssertEqual(display.footer.gateway.requests, 0)
            let attempts = try await model.traces.list(sessionID: chat.id)
            XCTAssertTrue(attempts.isEmpty)
        }
        XCTAssertGreaterThan(heartbeat.samples, 0, "The MainActor must make progress while the helper starts")
        print(String(format: "CONCURRENCY 20 native cold opens %.2f ms; refresh settlement %.2f ms; MainActor heartbeat samples %d, max gap %.2f ms", (openedAt - start) * 1000, (ProcessInfo.processInfo.systemUptime - openedAt) * 1000, heartbeat.samples, heartbeat.maximumGap * 1000))
    }

    @MainActor func testTwentyConcurrentCallersWaitForTheSameSessionsCapturePreference() async throws {
        let model = try await fixture(count: 1), chat = try XCTUnwrap(model.chats.first)
        let observations = try await openTogether(Array(repeating: chat, count: 20), model: model)
        XCTAssertEqual(observations.count, 20)
        XCTAssertEqual(Set(observations.compactMap(\.connection)).count, 1)
        XCTAssertEqual(Set(observations.compactMap { $0.snapshot["path"]?.string }).count, 1)
        XCTAssertEqual(model.opened, [chat.id])
        for observation in observations {
            XCTAssertTrue(observation.captureReady, "No concurrent caller can return before native capture initialization finishes")
            XCTAssertEqual(observation.snapshot["captureMode"], .string("off"))
            XCTAssertEqual(observation.snapshot["state"], .string("idle"))
            XCTAssertEqual(observation.requests, 0)
        }
        let record = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(record?.path, model.record(chat.id)?.path)
        XCTAssertEqual(model.displays[chat.id]?.draft, "Unsent draft for \(chat.id)")
    }

    @MainActor func testShutdownDuringCredentialReadCannotStartALateHelper() async throws {
        let storage = DelayedConcurrencyVault(), model = try await fixture(count: 1, storage: storage)
        let chat = try XCTUnwrap(model.chats.first), entered = expectation(description: "Credential read is in progress")
        storage.holdNextRead(entered)
        let opening = Task { try await model.open(chat) }
        await fulfillment(of: [entered], timeout: 3)
        model.shutdown(); storage.resume.signal()
        do { _ = try await opening.value; XCTFail("A credential read completing after shutdown must not open a host") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        XCTAssertNil(model.record(chat.id)?.path)
        XCTAssertEqual(model.displays[chat.id]?.draft, "Unsent draft for \(chat.id)")
        do { _ = try await model.host(for: try XCTUnwrap(model.workspaces.first)); XCTFail("Terminal shutdown rejects later direct host requests too") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testConnectionSwitchCannotOvertakeAnOpeningSession() async throws {
        let storage = DelayedConcurrencyVault(), model = try await fixture(count: 1, storage: storage)
        let chat = try XCTUnwrap(model.chats.first)
        var next = ProfileRecord(); next.id = "second-connection"; next.baseUrl = "http://127.0.0.1:9/v1"; next.modelId = "second-router"
        try await model.saveProfile(next, key: "synthetic-second-key")
        let entered = expectation(description: "Credential read is in progress")
        storage.holdNextRead(entered)
        let opening = Task { try await model.open(chat) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.isSessionOpening(chat.id))
        XCTAssertEqual(model.displays[chat.id]?.loading, false, "Automatic context initialization need not set composer loading")
        await model.setConnection(next.id, for: chat.id)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
        XCTAssertEqual(model.error, "Wait for this chat's connection to finish opening.")
        storage.resume.signal()
        let host = try await opening.value
        XCTAssertFalse(model.isSessionOpening(chat.id))
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
        XCTAssertEqual(snapshot["profileId"], .string(chat.profileID))
        // The guard is scoped to startup, rather than permanently freezing the
        // session's connection after a rejected choice.
        await model.setConnection(next.id, for: chat.id)
        XCTAssertEqual(model.record(chat.id)?.profileID, next.id)
        XCTAssertFalse(model.opened.contains(chat.id))
        XCTAssertEqual(model.displays[chat.id]?.draft, "Unsent draft for \(chat.id)")
    }

    @MainActor func testTwentyBackgroundAccountingBurstsUpdateTotalsWithoutRewritingHiddenTranscripts() async throws {
        let model = try await fixture(count: 20)
        model.selectedID = nil; model.selected = nil
        var snapshots: [String: [TranscriptMessage]] = [:]
        var packets: [[String: WireValue]] = []
        for (index, chat) in model.chats.enumerated() {
            let display = try XCTUnwrap(model.displays[chat.id])
            display.messages = [.init(id: "user-\(index)", role: "user", text: "Question \(index)"),
                                .init(id: "answer-\(index)", role: "assistant", text: "Answer \(index)")]
            var metadata: [String: WireValue] = ["attemptId": .string(UUID().uuidString), "sessionId": .string(chat.id),
                "turnId": .string("user-\(index)"), "messageIds": .array([.string("user-\(index)")]),
                "outputMessageIds": .array([.string("answer-\(index)")]), "purpose": .string("turn"),
                "api": .string("openai-responses"), "requestedModel": .string("router"), "mode": .string("off"),
                "wallTimestamp": .number(Date().timeIntervalSince1970), "outcome": .string("completed"),
                "timingVersion": .number(2), "timings": .object(["dispatch": .number(100)]),
                "usage": .object(["inputIncludingCache": .number(38), "output": .number(302), "total": .number(340)]),
                "gateway": .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(0.001)])])]
            try await model.traces.begin(metadata, workspace: chat.workspaceID); try await model.traces.finish(metadata)
            await model.refreshAccounting(display, workspaceID: chat.workspaceID)
            XCTAssertEqual(display.footer.gateway.requests, 1, "Only a timing-v2 dispatched attempt participates in accounting")
            XCTAssertEqual(display.messageAccounting["answer-\(index)"]?.costUSD, 0.001)
            snapshots[chat.id] = display.messages
            metadata["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(Double(index + 2) / 1000)])])
            try await model.traces.finish(metadata)
            packets.append(["type": .string("finish"), "metadata": .object(metadata)])
        }
        for _ in 0..<50 { for packet in packets { await model.captureDidPersist(packet, workspaceID: "project") } }
        XCTAssertEqual(model.accountingTasks.count, 20, "Each session coalesces its own invalidation burst")
        let deadline = Date().addingTimeInterval(5)
        while !model.accountingTasks.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.accountingTasks.isEmpty); XCTAssertTrue(model.dirtyAccounting.isEmpty)
        for (index, chat) in model.chats.enumerated() {
            let display = try XCTUnwrap(model.displays[chat.id]), cost = Double(index + 2) / 1000
            XCTAssertEqual(display.footer.gateway.costUSD, cost); XCTAssertEqual(model.chatStats[chat.id]?.costUSD, cost)
            XCTAssertEqual(display.footer.gateway.tokens?.total, 340)
            XCTAssertEqual(display.messages, snapshots[chat.id], "Hidden transcript rows must not be republished for billing-only changes")
            XCTAssertEqual(display.accountingRevision, 2, "Fifty duplicate invalidations produce one additional query")
        }
        let visible = try XCTUnwrap(model.displays["session-0"])
        model.selectedID = visible.id; model.selected = visible
        await model.refreshAccounting(visible, workspaceID: "project")
        XCTAssertEqual(visible.messageAccounting["answer-0"]?.costUSD, 0.002, "Focusing the session still refreshes its inline attribution")
        XCTAssertTrue(model.hosts.isEmpty, "Billing refresh does not start a runtime")
    }
}
