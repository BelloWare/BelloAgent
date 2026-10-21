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

/// Holds the metadata store's actor while encoded, so later writes queue.
private struct ConcurrencyStoreBarrier: Encodable, Sendable {
    let entered: DispatchSemaphore
    let released: DispatchSemaphore
    func encode(to encoder: Encoder) throws {
        entered.signal(); released.wait()
        var value = encoder.singleValueContainer(); try value.encode(true)
    }
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
    @MainActor func testOnboardingProbeCannotStartInsideShutdownOrUpdateBarrier() async throws {
        let model = try await fixture(count: 0)
        model.selectedWorkspaceID = "project"; model.profileChoice = "connection"
        let profile = try XCTUnwrap(model.profiles.first)
        model.installPreparing = true
        do { try await model.verifyOnboardingConnection(profile); XCTFail("Update barrier must refuse a new probe") } catch ConnectionProbeError.cancelled { }
        XCTAssertEqual(model.connectionProbeAdmissions, 0)
        model.installPreparing = false; model.shutdown()
        do { try await model.verifyOnboardingConnection(profile); XCTFail("Shutdown must refuse a new probe") } catch ConnectionProbeError.cancelled { }
        XCTAssertEqual(model.connectionProbeAdmissions, 0)
    }

    @MainActor func testOnboardingProbeCountsAsActiveWhileCredentialsArePending() async throws {
        let storage = DelayedConcurrencyVault(), model = try await fixture(count: 0, storage: storage)
        model.prewarmsHelpers = false; model.selectedWorkspaceID = "project"; model.profileChoice = "connection"
        let entered = expectation(description: "probe credentials held")
        storage.holdNextRead(entered); defer { storage.resume.signal() }
        let probe = Task { try await model.verifyOnboardingConnection(try XCTUnwrap(model.profiles.first)) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.hasActiveWork, "The private onboarding helper must participate in update/quit work accounting")
        XCTAssertFalse(model.acquireUpdateBarrier())
        model.releaseUpdateBarrier()
        do { try await model.pauseRunsForUpdate(settleTimeout: 0.05); XCTFail("Pause must wait for the private probe") } catch { }
        probe.cancel(); storage.resume.signal()
        do { try await probe.value; XCTFail("Cancelled probe must not complete") } catch { }
        XCTAssertFalse(model.hasActiveWork); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(model.acquireUpdateBarrier()); model.releaseUpdateBarrier()
    }

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

    /// A second connection the chat can move to and still open its journal
    /// on: the same endpoint and model, another saved connection.
    @MainActor private func secondConnection(_ model: WorkspaceModel, id: String = "second-connection") async throws -> ProfileRecord {
        var next = ProfileRecord(); next.id = id; next.baseUrl = "http://127.0.0.1:9/v1"; next.modelId = "router"
        try await model.saveProfile(next, key: "synthetic-\(id)-key")
        return next
    }
    /// Holds a connection change at `step` until `release` is finished.
    @MainActor private func hold(_ model: WorkspaceModel, at step: String, entered: XCTestExpectation) -> AsyncStream<Never>.Continuation {
        let (held, release) = AsyncStream<Never>.makeStream()
        var reached = false
        model.connectionSwitchSteps = { name in
            guard name == step, !reached else { return }
            reached = true; entered.fulfill()
            for await _ in held {}
        }
        return release
    }

    /// The review's order: the switch has closed the session and is writing
    /// the chat's record when an open that read the chat on the old
    /// connection starts. It waits, and is refused; no session on the old
    /// connection is left for a later open to reuse, and an open of the chat
    /// as it is now opens it on the new one.
    @MainActor func testAnOpenThatReadTheOldConnectionWaitsForTheSwitchAndOpensTheNewOne() async throws {
        let model = try await fixture(count: 1)
        let chat = try XCTUnwrap(model.chats.first), next = try await secondConnection(model)
        _ = try await model.open(chat)
        let stale = try XCTUnwrap(model.record(chat.id))
        XCTAssertNotNil(stale.path)
        let entered = expectation(description: "The switch is writing the chat's record")
        let release = hold(model, at: "metadata", entered: entered)
        let switching = Task { await model.setConnection(next.id, for: chat.id) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertFalse(model.opened.contains(chat.id))
        let opening = Task { try await model.open(stale) }
        try await eventually("The waiting open pins its budget") { model.budgetOpenCallers[chat.id] == 1 }
        XCTAssertFalse(model.isSessionOpening(chat.id), "An open waits for the switch before it starts")
        XCTAssertFalse(model.opened.contains(chat.id))
        release.finish()
        await switching.value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.record(chat.id)?.profileID, next.id)
        do { _ = try await opening.value; XCTFail("An open of the chat as it was before the switch is refused") }
        catch { XCTAssertEqual(error.localizedDescription, model.connectionChanged.localizedDescription) }
        XCTAssertFalse(model.opened.contains(chat.id))
        let host = try await model.open(try XCTUnwrap(model.record(chat.id)))
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
        XCTAssertEqual(snapshot["profileId"], .string(next.id))
    }

    /// A send while the chat is moving is refused where it was typed, with
    /// its draft kept; a second switch waits for the first to finish.
    @MainActor func testASendAndASecondSwitchDuringASwitchAreRefused() async throws {
        let model = try await fixture(count: 1)
        let chat = try XCTUnwrap(model.chats.first), next = try await secondConnection(model)
        let third = try await secondConnection(model, id: "third-connection")
        _ = try await model.open(chat)
        let entered = expectation(description: "The switch has closed the session")
        let release = hold(model, at: "closed", entered: entered)
        let switching = Task { await model.setConnection(next.id, for: chat.id) }
        await fulfillment(of: [entered], timeout: 5)
        model.send(sessionID: chat.id)
        try await eventually("The refused send settles") { model.displays[chat.id]?.loading == false && model.displays[chat.id]?.sendFailure != nil }
        XCTAssertEqual(model.displays[chat.id]?.sendFailure, model.connectionChanged.localizedDescription)
        XCTAssertEqual(model.displays[chat.id]?.draft, "Unsent draft for \(chat.id)")
        await model.setConnection(third.id, for: chat.id)
        XCTAssertEqual(model.error, "Wait for this chat's connection change to finish.")
        release.finish()
        await switching.value
        XCTAssertEqual(model.record(chat.id)?.profileID, next.id)
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(stored?.profileID, next.id)
    }

    /// A switch whose record cannot be written leaves the chat on its
    /// connection, and an open waiting for it opens the chat there.
    @MainActor func testAFailedSwitchLeavesTheChatOpenableOnItsConnection() async throws {
        let model = try await fixture(count: 1)
        let chat = try XCTUnwrap(model.chats.first), next = try await secondConnection(model)
        _ = try await model.open(chat)
        let entered = expectation(description: "The switch is writing the chat's record")
        let (held, release) = AsyncStream<Never>.makeStream()
        model.connectionSwitchSteps = { name in
            guard name == "metadata" else { return }
            entered.fulfill(); for await _ in held {}
            throw StoreError.unavailable
        }
        let opened = try XCTUnwrap(model.record(chat.id))
        let switching = Task { await model.setConnection(next.id, for: chat.id) }
        await fulfillment(of: [entered], timeout: 5)
        let opening = Task { try await model.open(opened) }
        let cancelled = Task { try await model.open(opened) }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        release.finish()
        await switching.value
        XCTAssertEqual(model.error, StoreError.unavailable.localizedDescription)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
        do { _ = try await cancelled.value; XCTFail("A cancelled open does not go on once the switch ends") }
        catch { XCTAssertTrue(error is CancellationError) }
        let host = try await opening.value
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
        XCTAssertEqual(snapshot["profileId"], .string(chat.profileID))
        XCTAssertTrue(model.opened.contains(chat.id))
    }

    /// The destination is deleted in Settings while the switch waits for its
    /// catalog, which finishes during the deletion or is cancelled by it.
    /// Nothing is closed, rebound or published for a deleted connection: the
    /// chat stays where it was, says why, and still opens there.
    @MainActor func testAConnectionDeletedWhileItsCatalogLoadsIsNeverSwitchedTo() async throws {
        for finishing in [true, false] {
            let storage = DelayedConcurrencyVault(), model = try await fixture(count: 1, storage: storage)
            let chat = try XCTUnwrap(model.chats.first), view = try XCTUnwrap(model.displays[chat.id])
            let requested = DispatchSemaphore(value: 0), reply = DispatchSemaphore(value: 0)
            let catalog = try ModelListGateway { _ in
                requested.signal(); reply.wait()
                return .json(#"[{"id":"router"},{"id":"second-router"}]"#)
            }
            defer { reply.signal(); catalog.stop() }
            var doomed = ProfileRecord(); doomed.id = "doomed-connection"; doomed.name = "Doomed"
            doomed.baseUrl = "http://127.0.0.1:9/v1"; doomed.modelId = "router"; doomed.catalogUrl = try await catalog.start() + "/catalog"
            try await model.saveProfile(doomed, key: "synthetic-doomed-key")
            await model.setModel("router", for: chat.id)
            XCTAssertNil(model.error)
            _ = try await model.open(chat)
            XCTAssertNotNil(model.record(chat.id)?.path)
            var steps: [String] = []
            model.connectionSwitchSteps = { steps.append($0) }
            let switching = Task { await model.setConnection(doomed.id, for: chat.id) }
            try await eventually("The switch waits for the destination's catalog") { requested.wait(timeout: .now()) == .success }
            if finishing {
                let held = expectation(description: "The deletion is writing the vault")
                storage.holdNextRead(held)
                let deleting = Task { try await model.deleteProfile(doomed.id) }
                await fulfillment(of: [held], timeout: 5)
                XCTAssertTrue(model.deletingProfiles.contains(doomed.id))
                XCTAssertTrue(model.profiles.contains { $0.id == doomed.id }, "The listing finishes while the deletion is still writing")
                reply.signal()
                await switching.value
                storage.resume.signal()
                try await deleting.value
            } else {
                try await model.deleteProfile(doomed.id)
                reply.signal()
                await switching.value
            }
            XCTAssertEqual(steps, [], "A deleted destination is never closed toward, rebound or published (\(finishing ? "finished" : "cancelled") listing)")
            XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
            XCTAssertNil(model.record(chat.id)?.journalRebind)
            let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
            XCTAssertEqual(stored?.profileID, chat.profileID); XCTAssertNil(stored?.journalRebind); XCTAssertEqual(stored?.model, "router")
            XCTAssertFalse(view.notice.contains("Next turn uses"), "No success notice for a connection that is gone")
            XCTAssertEqual(model.error, "That connection was deleted before this chat could switch to it. The chat stays on its current connection.")
            XCTAssertTrue(model.opened.contains(chat.id), "Its session on its own connection stays open")
            let host = try? await model.open(try XCTUnwrap(model.record(chat.id)))
            XCTAssertNotNil(host, "The chat still opens on its own connection")
            if let host {
                let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
                XCTAssertEqual(snapshot["profileId"], .string(chat.profileID))
            }
        }
    }

    /// The destination is deleted at a later step of the switch. Before the
    /// journal moves, nothing moves; after it moved, it is bound back at once,
    /// or by the next open once the move was confirmed. A deletion that begins
    /// during the final record write did not count the chat as its own: the
    /// chat then reads as any chat of a deleted connection, never "Next turn uses".
    @MainActor func testADeletionAtEachSwitchStepIsNeverAnnouncedAsTheChatsConnection() async throws {
        for step in ["closed", "rebound", "metadata", "published"] {
            let model = try await fixture(count: 1)
            let chat = try XCTUnwrap(model.chats.first), view = try XCTUnwrap(model.displays[chat.id])
            let doomed = try await secondConnection(model, id: "doomed-connection")
            _ = try await model.open(chat)
            XCTAssertNotNil(model.record(chat.id)?.path)
            let store = try XCTUnwrap(model.store)
            let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            let holding: () -> Bool = { entered.wait(timeout: .now()) == .success }
            defer { released.signal() }
            var steps: [String] = [], barrier: Task<Void, Error>?, queued = false
            model.connectionSwitchSteps = { name in
                steps.append(name)
                if name == step { try await model.deleteProfile(doomed.id) }
                if step == "published", name == "metadata" {
                    // The record's write queues behind this until the deletion begins.
                    barrier = Task { try await store.put(ConcurrencyStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
                    while !holding() { try await Task.sleep(for: .milliseconds(5)) }
                    // Returning, the switch passes its last check and suspends
                    // in the record's write before anything else can run.
                    queued = true
                }
            }
            let switching = Task { await model.setConnection(doomed.id, for: chat.id) }
            if step == "published" {
                try await eventually("The final write is queued") { queued }
                let deleting = Task { try await model.deleteProfile(doomed.id) }
                try await eventually("The deletion began") { model.deletingProfiles.contains(doomed.id) || !model.profiles.contains { $0.id == doomed.id } }
                released.signal(); try await barrier?.value
                await switching.value
                try await deleting.value
            } else { await switching.value }
            XCTAssertFalse(view.notice.contains("Next turn uses"), "No success notice for a deleted connection (\(step))")
            let stored = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
            if step == "published" {
                XCTAssertEqual(steps, ["closed", "marked", "rebound", "metadata"])
                XCTAssertNil(model.error)
                XCTAssertEqual(model.record(chat.id)?.profileID, doomed.id); XCTAssertEqual(stored?.profileID, doomed.id)
                XCTAssertEqual(view.notice, "This chat's connection was deleted. Choose another connection to continue.")
                continue
            }
            let reached = ["closed": ["closed"], "rebound": ["closed", "marked", "rebound"], "metadata": ["closed", "marked", "rebound", "metadata"]]
            XCTAssertEqual(steps, reached[step], "The switch stops at the first check after the deletion (\(step))")
            XCTAssertEqual(model.error, "That connection was deleted before this chat could switch to it. The chat stays on its current connection.", step)
            XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID, step); XCTAssertEqual(stored?.profileID, chat.profileID, step)
            // Bound back at once, or marked for the next open to bind back.
            XCTAssertEqual(model.record(chat.id)?.journalRebind, step == "metadata" ? true : nil, step)
            XCTAssertEqual(stored?.journalRebind, step == "metadata" ? true : nil, step)
            let host = try await model.open(try XCTUnwrap(model.record(chat.id)))
            let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
            XCTAssertEqual(snapshot["profileId"], .string(chat.profileID), step)
            XCTAssertNil(model.record(chat.id)?.journalRebind, step)
        }
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
