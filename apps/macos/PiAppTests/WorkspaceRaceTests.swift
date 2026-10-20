import XCTest
@testable import PiApp

@MainActor final class WorkspaceRaceTests: XCTestCase {
    private func fixture(pending: Bool = false) async throws -> (WorkspaceModel, SessionDisplay, WorkspaceRaceHost) {
        let root = scratchRoot("workspace-race")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        var config = VaultConfiguration()
        config.workspaces = [workspace]; config.profiles = [.init(profile: profile, apiKey: "generated-fixture-key")]
        config.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        model.prewarmsHelpers = false
        try await model.reloadConfiguration()
        var chat = ChatRecord(id: "chat", workspaceID: workspace.id, title: "Fixture", profileID: profile.id)
        chat.titleWasEdited = true
        let view = SessionDisplay(id: chat.id)
        view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view
        model.selectedID = chat.id; model.focusedSessionID = chat.id; model.selected = view
        if pending { model.pendingChatIDs.insert(chat.id) }
        else { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let wire = WorkspaceRaceHost(root: root)
        try await wire.host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = wire.host
        model.boundHostConnections[workspace.id] = wire.host.connectionID
        return (model, view, wire)
    }

    private func bindLossHandling(_ model: WorkspaceModel, _ wire: WorkspaceRaceHost) async throws {
        model.boundHostConnections.removeValue(forKey: "w")
        _ = try await model.host(for: try XCTUnwrap(model.workspaces.first))
    }

    func testHelperLossKeepsTheDurableConflictCopy() async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        let store = try XCTUnwrap(model.store)
        view.draftVersion = try await store.draftVersion(id: view.id)
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        try await other.put(DraftRecord(id: view.id, text: "Other instance's draft"), kind: "draft", id: view.id)
        view.draft = "Losing input before helper exit"; model.draftChanged(view)
        await model.draftWrites.tasks[view.id]?.value
        let connection = try XCTUnwrap(wire.host.connectionID)
        wire.host.receive(.failed("Generated helper loss"), connectionID: connection)
        let copies = try await other.list(DraftRecord.self, kind: "draft-conflict:" + view.id)
        XCTAssertTrue(copies.contains(where: { $0.text == "Losing input before helper exit" }))
        XCTAssertTrue(model.displays[view.id] === view)
        await other.close()
    }

    func testOldOpeningCleanupCannotCloseTheReplacementHelpersRuntime() async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        let chat = try XCTUnwrap(model.record(view.id)), lease = try model.connectionLease(for: chat)
        let gate = AsyncGate(); var waiting = false
        let old = Task { try await model.withConnectionOpen(chat, lease: lease, host: wire.host) { waiting = true; await gate.wait() } }
        try await eventually("old opening held") { waiting }
        try await wire.host.shutdownAndWait()
        model.profileDeletionGenerations[chat.profileID, default: 0] += 1
        _ = try await model.open(chat)
        let before = wire.frames.filter { $0["method"]?.string == "turn.stop" || $0["method"]?.string == "session.close" }.count
        await gate.open(); _ = try? await old.value
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.stop" || $0["method"]?.string == "session.close" }.count, before)
        XCTAssertTrue(model.opened.contains(chat.id), "Cleanup of an old lease must not unload the replacement runtime")
    }

    func testOpenReplyFollowedByHelperLossCannotRepublishItsRuntime() async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        wire.heldMethod = "debug.mode"
        let opening = Task { try await model.open(try XCTUnwrap(model.record(view.id))) }
        try await eventually("capture reply held") { wire.held != nil }
        let connection = try XCTUnwrap(wire.host.connectionID)
        wire.release()
        wire.host.receive(.failed("Generated helper loss"), connectionID: connection)
        _ = try? await opening.value
        XCTAssertFalse(model.opened.contains(view.id), "A reply resumed after loss must not restore the dead runtime")
        try await wire.host.shutdownAndWait()
        _ = try await model.host(for: try XCTUnwrap(model.workspaces.first))
        let before = wire.frames.filter { $0["method"]?.string == "session.open" && $0["sessionId"]?.string == view.id }.count
        _ = try await model.open(try XCTUnwrap(model.record(view.id)))
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.open" && $0["sessionId"]?.string == view.id }.count, before + 1)
    }

    func testForkRegistrationAfterHelperLossKeepsTheForkButReopensItsRuntime() async throws { try await forkRegistrationAfterLoss(reconnectEarly: false) }
    func testForkRegistrationCannotPublishOnAReplacementConnection() async throws { try await forkRegistrationAfterLoss(reconnectEarly: true) }

    private func forkRegistrationAfterLoss(reconnectEarly: Bool) async throws {
        let (model, parent, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        wire.heldMethod = "session.fork"
        let creation = Task { try await model.createFork(parentID: parent.id) }
        try await eventually("fork reply held") { wire.held != nil }
        let id = try XCTUnwrap(wire.held?["params"]?.object?["forkSessionId"]?.string)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let blocker = Task { try await model.store?.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "registration") }
        try await eventually("store held before registration") { entered.wait(timeout: .now()) == .success }
        wire.release()
        try await wire.host.shutdownAndWait()
        if reconnectEarly {
            try await wire.host.connect(cwd: model.root, state: model.root.appendingPathComponent("replacement-host"))
            _ = try await wire.host.request("workspace.open")
            model.boundHostConnections["w"] = wire.host.connectionID
        }
        released.signal(); try await blocker.value
        _ = try? await creation.value
        let fork = try XCTUnwrap(model.record(id))
        XCTAssertFalse(model.opened.contains(id), "Durable registration cannot publish a dead helper session")
        _ = try await model.host(for: try XCTUnwrap(model.workspaces.first))
        _ = try await model.open(fork)
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.open" && $0["sessionId"]?.string == id }.count, 1)
    }

    func testSidePublicationReplyFollowedByLossCannotRepublishItsRuntime() async throws {
        let (model, parent, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        wire.heldMethod = "session.status"; wire.heldSessionID = side.id
        let publication = Task { try await model.publishPendingSide(side, view: view) }
        try await eventually("side status reply held") { wire.held != nil }
        let connection = try XCTUnwrap(wire.host.connectionID)
        wire.release(); wire.host.receive(.failed("Generated helper loss"), connectionID: connection)
        _ = try? await publication.value
        let saved = try XCTUnwrap(model.record(side.id))
        XCTAssertFalse(model.opened.contains(side.id))
        try await wire.host.shutdownAndWait()
        _ = try await model.open(saved)
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.open" && $0["sessionId"]?.string == side.id }.count, 1)
    }

    func testOpeningReconcilesReplacementCredentialsBeforeSendingAgain() async throws {
        let (model, view, wire) = try await fixture()
        wire.heldMethod = "session.open"
        view.draft = "First"; model.send(sessionID: view.id)
        try await eventually("opening with the original key") { wire.held != nil }
        XCTAssertEqual(wire.held?["params"]?.object?["apiKey"]?.string, "generated-fixture-key")
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B", headers: "{\"X-Fixture\":\"B\"}")
        wire.release()
        try await eventually("first send settled") { !view.loading }
        view.draft = "Second"; model.send(sessionID: view.id)
        try await eventually("second send settled") { !view.loading }
        let configurations = wire.frames.filter { $0["method"]?.string == "session.configure" }
        XCTAssertEqual(configurations.last?["params"]?.object?["apiKey"]?.string, "replacement-B")
        XCTAssertEqual(configurations.last?["params"]?.object?["profile"]?.object?["headers"]?.object?["X-Fixture"]?.string, "B")
        let submits = wire.frames.indices.filter { wire.frames[$0]["method"]?.string == "turn.submit" }
        XCTAssertEqual(submits.count, 2)
        if let configured = wire.frames.lastIndex(where: { $0["method"]?.string == "session.configure" }), let second = submits.last { XCTAssertLessThan(configured, second) }
        else { XCTFail("Replacement credentials must reach the runtime before its next turn") }
    }

    func testConflictDuringOpeningKeepsCapturedSubmissionAfterEmptyDebounce() async throws {
        let (model, view, wire) = try await fixture()
        let store = try XCTUnwrap(model.store)
        view.draft = "Captured input waiting for the helper"
        try await store.put(view.savedDraft, kind: "draft", id: view.id)
        view.draftVersion = try await store.draftVersion(id: view.id)
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        try await other.put(DraftRecord(id: view.id, text: "Other instance's newer draft"), kind: "draft", id: view.id)
        wire.heldMethod = "session.open"
        model.send(sessionID: view.id)
        try await eventually("opening held while the empty composer is saved") { wire.held != nil && model.draftWrites.tasks[view.id] == nil }
        let captured = try await other.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(captured.map(\.text), ["Captured input waiting for the helper"], "Captured input must have its own durable record before opening finishes")
        let copies = try await other.draftConflicts(id: view.id)
        XCTAssertEqual(copies.map(\.draft.text), [""], "The debounce owns only the composer snapshot")
        wire.release()
        try await eventually("rejected submission returned") { !view.loading }
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "turn.submit" })
        await other.close()
    }

    /// A credential read may outlive the runtime that admitted it. Hold that
    /// continuation independently of the transport (whose requests fail on loss).
    private func holdConfiguration(_ model: WorkspaceModel, _ wire: WorkspaceRaceHost, chat: ChatRecord, gate: AsyncGate) throws -> Task<Void, Error> {
        let lease = try model.configurationLease(for: chat, host: wire.host)
        let task = Task {
            await gate.wait()
            try model.requireConfiguration(lease, host: wire.host)
        }
        model.sessionConfigurations[chat.id] = (UUID(), lease, task)
        return task
    }

    func testReplacementOpeningDoesNotAwaitRetiredConfiguration() async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        let gate = AsyncGate()
        let old = try holdConfiguration(model, wire, chat: chat, gate: gate)
        try await wire.host.shutdownAndWait()
        var finished = false
        let replacement = Task { defer { finished = true }; return try await model.open(chat) }
        try await eventually("replacement reached capture setup") { wire.frames.filter { $0["method"]?.string == "debug.mode" }.count == 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(finished, "Replacement opening must not wait for a retired configuration's credentials")
        await gate.open(); _ = try? await old.value
        do { _ = try await replacement.value } catch { XCTFail("Retired configuration rejected the replacement: \(error)") }
        XCTAssertTrue(model.opened.contains(chat.id))
    }

    func testReplacementOpeningDoesNotAwaitRetiredOpeningConfiguration() async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        let gate = AsyncGate()
        let old = try holdConfiguration(model, wire, chat: chat, gate: gate)
        let opening = Task { try await old.value }
        model.sessionOpenings[chat.id] = (UUID(), opening)
        try await wire.host.shutdownAndWait()
        var finished = false
        let replacement = Task { defer { finished = true }; return try await model.open(chat) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(finished, "An opening waiting for retired configuration must not block a replacement")
        await gate.open(); _ = try? await opening.value
        do { _ = try await replacement.value } catch { XCTFail("An obsolete opening rejected the replacement: \(error)") }
        XCTAssertTrue(model.opened.contains(chat.id))
    }

    func testRetiredConfigurationFailureCannotCloseReplacementHelper() async throws {
        try await retiredConfigurationCleanup(restart: true)
    }

    func testRetiredConfigurationFailureCannotCloseReassignedChat() async throws {
        try await retiredConfigurationCleanup(restart: false)
    }

    func testRetiredConfigurationFailureCannotCloseReopenedRuntime() async throws {
        try await retiredConfigurationCleanup(restart: false, reassign: false)
    }

    func testReconciliationDoesNotShareConfigurationFromAnotherLease() async throws {
        let (model, view, wire) = try await fixture()
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        let gate = AsyncGate()
        let old = try holdConfiguration(model, wire, chat: chat, gate: gate)
        model.connectionGenerations[chat.id, default: 0] += 1
        var finished = false
        let current = Task { defer { finished = true }; try await model.reconcileSessionProfile(chat, host: wire.host) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(finished, "A task under the previous chat lease cannot be shared")
        await gate.open(); _ = try? await old.value
        do { try await current.value } catch { XCTFail("The retired lease rejected current reconciliation: \(error)") }
    }

    func testConfigurationCloseReplyCannotClearReopenedRuntime() async throws {
        try await configurationCloseReply(rejected: false)
    }

    func testConfigurationCloseFailureCannotReleaseReopenedRuntime() async throws {
        try await configurationCloseReply(rejected: true)
    }

    private func configurationCloseReply(rejected: Bool) async throws {
        let (model, view, wire) = try await fixture()
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        wire.rejectedMethod = "session.configure"; wire.heldMethod = "session.close"
        let saving = Task { try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B") }
        try await eventually("unsupported configuration reached close fallback") { wire.held != nil }
        // An unload event can precede the close reply. A new opening now owns
        // the same session ID and helper connection, but a different runtime.
        model.helperSessionDidUnload(chat.id)
        _ = try await model.open(chat)
        let configured = model.sessionProfileRevisions[chat.id]?.revision
        wire.rejectedMethod = rejected ? "session.close" : nil
        wire.release(); try await saving.value
        XCTAssertTrue(model.opened.contains(chat.id))
        XCTAssertEqual(model.sessionProfileRevisions[chat.id]?.revision, configured)
        XCTAssertFalse(model.releasedHelperSessions.contains(chat.id))
    }

    func testUnsupportedConfigurationStillClosesItsCurrentIdleRuntime() async throws {
        let (model, view, wire) = try await fixture()
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        wire.rejectedMethod = "session.configure"
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B")
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.close" }.count, 1)
        XCTAssertFalse(model.opened.contains(chat.id))
        wire.rejectedMethod = nil
        _ = try await model.open(chat)
        XCTAssertEqual(wire.frames.last { $0["method"]?.string == "session.open" }?["params"]?.object?["apiKey"]?.string, "replacement-B")
    }

    private func retiredConfigurationCleanup(restart: Bool, reassign: Bool = true) async throws {
        let (model, view, wire) = try await fixture()
        try await bindLossHandling(model, wire)
        let chat = try XCTUnwrap(model.record(view.id))
        _ = try await model.open(chat)
        let gate = AsyncGate()
        let old = try holdConfiguration(model, wire, chat: chat, gate: gate)
        let saving = Task { try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B") }
        try await eventually("save is reconciling the loaded session") { model.configuration.profiles.first?.apiKey == "replacement-B" }
        try await Task.sleep(for: .milliseconds(50))
        if restart { try await wire.host.shutdownAndWait() }
        else {
            // Switching away and back retires the lease even on the same helper.
            if reassign { model.connectionGenerations[chat.id, default: 0] += 1 }
            model.helperSessionDidUnload(chat.id)
        }
        // Isolate failure cleanup from sharing an obsolete task (covered above).
        model.sessionConfigurations.removeValue(forKey: chat.id)
        _ = try await model.open(chat)
        let before = wire.frames.filter { $0["method"]?.string == "session.close" }.count
        await gate.open(); _ = try? await old.value; try await saving.value
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.close" }.count, before, "A retired save must not close a replacement runtime")
        XCTAssertTrue(model.opened.contains(chat.id), "A retired save must not clear replacement bookkeeping")
    }

    func testOpeningRepeatsConfigurationWhenAnotherSaveIntervenes() async throws {
        let (model, view, wire) = try await fixture()
        wire.heldMethod = "session.open"
        view.draft = "First"; model.send(sessionID: view.id)
        try await eventually("opening held") { wire.held != nil }
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B")
        wire.release(holding: "session.configure")
        try await eventually("reconciliation held or send finished") { wire.held != nil || !view.loading }
        XCTAssertNotNil(wire.held, "Opening must reconcile the replacement key")
        guard wire.held != nil else { return }
        let saving = Task { try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-C") }
        try await eventually("second replacement saved") { model.configuration.profiles.first?.apiKey == "replacement-C" }
        wire.release()
        try await saving.value
        try await eventually("send settled") { !view.loading }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "session.configure" }.compactMap { $0["params"]?.object?["apiKey"]?.string }, ["replacement-B", "replacement-C"])
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, 1)
    }

    func testRetryAfterCaptureSetupFailureReconcilesTheExistingRuntime() async throws {
        let (model, view, wire) = try await fixture()
        let chat = try XCTUnwrap(model.record(view.id))
        wire.rejectedMethod = "debug.mode"
        do { _ = try await model.open(chat); XCTFail("Fixture capture setup must fail") }
        catch HostError.rejected(let code, _) { XCTAssertEqual(code, "fixture_rejection") }
        XCTAssertFalse(model.opened.contains(chat.id))
        wire.rejectedMethod = nil
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B")
        _ = try await model.open(chat)
        XCTAssertEqual(wire.frames.last { $0["method"]?.string == "session.configure" }?["params"]?.object?["apiKey"]?.string, "replacement-B", "The helper may already hold the runtime from the failed opening")
    }

    func testLoadedRuntimeWaitsForReplacementConfiguration() async throws {
        let (model, view, wire) = try await fixture()
        _ = try await model.open(try XCTUnwrap(model.record(view.id)))
        wire.heldMethod = "session.configure"
        let saving = Task { try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B") }
        try await eventually("replacement configuration held") { wire.held != nil }
        view.draft = "After the saved replacement"; model.send(sessionID: view.id)
        // Give the accepted send a chance to get through an incorrectly
        // cached open. The configuration remains held for this whole interval.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "turn.submit" })
        wire.release(); try await saving.value
        try await eventually("send finished after configuration") { !view.loading }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, 1)
    }

    func testStopDoesNotWaitForCredentialReconciliation() async throws {
        let (model, view, wire) = try await fixture()
        _ = try await model.open(try XCTUnwrap(model.record(view.id)))
        wire.heldMethod = "session.configure"
        let saving = Task { try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B") }
        try await eventually("replacement configuration held") { wire.held != nil }
        view.state = "running"; model.stop(sessionID: view.id)
        try await eventually("Stop dispatched without waiting for configuration") { wire.frames.contains { $0["method"]?.string == "turn.stop" } }
        XCTAssertNotNil(wire.held)
        wire.release(); try await saving.value
    }

    func testNewSideReconcilesCredentialsSavedDuringPublication() async throws {
        let (model, parent, wire) = try await fixture()
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "First side message"
        wire.heldMethod = "side.open"
        model.send(sessionID: side.id)
        try await eventually("side publication held") { wire.held != nil }
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B")
        wire.release()
        try await eventually("side send settled") { !view.loading }
        XCTAssertEqual(wire.frames.last { $0["method"]?.string == "session.configure" && $0["sessionId"]?.string == side.id }?["params"]?.object?["apiKey"]?.string, "replacement-B")
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" && $0["sessionId"]?.string == side.id }.count, 1)
    }

    func testNewForkReconcilesCredentialsSavedDuringPublication() async throws {
        let (model, parent, wire) = try await fixture()
        wire.heldMethod = "session.fork"
        let creation = Task { try await model.createFork(parentID: parent.id) }
        try await eventually("fork publication held") { wire.held != nil }
        try await model.saveProfile(try XCTUnwrap(model.profiles.first), key: "replacement-B")
        wire.release()
        let fork = try await creation.value
        _ = try await model.open(fork)
        XCTAssertEqual(wire.frames.last { $0["method"]?.string == "session.configure" && $0["sessionId"]?.string == fork.id }?["params"]?.object?["apiKey"]?.string, "replacement-B")
    }

    func testPendingSideWithAnImageImportCannotBeDiscarded() async throws {
        let (model, parent, _) = try await fixture()
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id])
        let importing = model.beginImageImport(sessionID: side.id); defer { importing.finish() }
        XCTAssertFalse(model.discardPendingSideNow(side))
        let discarded = await model.discardPendingSide(side)
        XCTAssertFalse(discarded); XCTAssertNotNil(model.displays[side.id])
    }

    func testSidePublicationDoesNotTakeFocusBackFromASavedSibling() async throws {
        let (model, parent, wire) = try await fixture()
        let side = SideRecord(id: "side", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Side", pending: true)
        let view = SessionDisplay(id: side.id)
        view.selectionMetadataLoaded = true; view.snapshotInFlight = true; view.draft = "First side message"
        model.sides[parent.id] = side; model.displays[side.id] = view
        var sibling = side.chat; sibling.id = "sibling"
        model.chats.append(sibling); try await model.store?.put(sibling, kind: "chat", id: sibling.id)
        wire.heldMethod = "debug.mode"; wire.heldSessionID = side.id
        model.send(sessionID: side.id)
        try await eventually("saved side capture setup held") { wire.held != nil }
        XCTAssertTrue(model.side(side.id)?.kept == true)
        await model.openFromSidebar(sibling.id)
        XCTAssertEqual(model.focusedSessionID, sibling.id)
        wire.release()
        try await eventually("first send finished") { !view.loading }
        XCTAssertEqual(model.focusedSessionID, sibling.id, "Late publication must not take the sibling's focus")
        XCTAssertEqual(model.sides[parent.id]?.boundary["parentSessionId"]?.string, parent.id)
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" && $0["sessionId"]?.string == side.id }.count, 1)
    }

    func testPendingSideImportStartedDuringDraftTransferRemainsReachable() async throws {
        let (model, parent, _) = try await fixture()
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.draft = "Move this draft"; parent.selectionMetadataLoaded = false
        let store = try XCTUnwrap(model.store)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
        defer { released.signal() }
        try await eventually("parent draft read held") { entered.wait(timeout: .now()) == .success }
        let discard = Task { await model.discardPendingSide(side) }
        try await eventually("side draft transfer held") { model.sideDraftTransfers[side.id] != nil }
        let importing = model.beginImageImport(sessionID: side.id); defer { importing.finish() }
        released.signal(); try await barrier.value
        let discarded = await discard.value
        XCTAssertFalse(discarded)
        XCTAssertTrue(model.displays[side.id] === view, "The in-progress import still needs its side destination")
        XCTAssertTrue(importing.isCurrent())
    }

    func testSiblingNavigationCannotDiscardAPublishingSide() async throws { try await publishingSideNavigation("sidebar") }
    func testDirectDiscardCannotRemoveAPublishingSide() async throws { try await publishingSideNavigation("discard") }
    func testSidePublicationRechecksOwnershipAfterParentOpening() async throws { try await publishingSideNavigation("replace") }

    private func publishingSideNavigation(_ action: String) async throws {
        let (model, parent, wire) = try await fixture()
        let side = SideRecord(id: "side", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Side", pending: true)
        let view = SessionDisplay(id: side.id)
        view.selectionMetadataLoaded = true; view.snapshotInFlight = true; view.draft = "First side message"
        model.sides[parent.id] = side; model.displays[side.id] = view
        var sibling = side.chat; sibling.id = "sibling"; sibling.title = "Saved sibling"
        sibling.path = model.root.appendingPathComponent("Workspaces/w/Sessions/side_sibling.jsonl").path
        model.chats.append(sibling); try await model.store?.put(sibling, kind: "chat", id: sibling.id)
        wire.heldMethod = "session.open"
        model.send(sessionID: side.id)
        try await eventually("parent opening for first side send") { wire.held != nil }
        switch action {
        case "sidebar": await model.openFromSidebar(sibling.id)
        case "discard":
            XCTAssertFalse(model.discardPendingSideNow(side))
            let discarded = await model.discardPendingSide(side); XCTAssertFalse(discarded)
        default:
            model.sides[parent.id] = SideRecord(id: "replacement", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Replacement", pending: true)
        }
        if action != "replace" {
            XCTAssertTrue(model.displays[side.id] === view, "Publishing side must remain reachable")
            XCTAssertEqual(model.sides[parent.id]?.id, side.id)
        }
        wire.release()
        try await eventually("side send settled") { !view.loading }
        let publishes = wire.frames.filter { $0["method"]?.string == "side.open" }
        let submits = wire.frames.filter { $0["method"]?.string == "turn.submit" && $0["sessionId"]?.string == side.id }
        if action == "replace" {
            XCTAssertTrue(publishes.isEmpty, "Lost ownership must be detected before creating a helper side")
            XCTAssertEqual(model.sides[parent.id]?.pending, true, "An obsolete publisher must not change the replacement")
        } else {
            XCTAssertEqual(publishes.count, 1); XCTAssertEqual(submits.count, 1)
            XCTAssertTrue(model.displays[side.id] === view)
            let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: side.id)
            XCTAssertNotNil(saved)
        }
    }

    func testCaptureSettingsPreserveOptOutAndTimestampThroughReloadAndOpen() async throws {
        let (model, view, wire) = try await fixture()
        let settings = ConnectionSettingsController(model: model)
        await settings.load(discardingDrafts: true)
        XCTAssertEqual(settings.preferences.capture.defaultMode, "persist")
        settings.preferences.capture.retentionDays = 7
        try await model.setCaptureMode("off", sessionID: view.id)
        let since = try XCTUnwrap(model.configuration.capture.sessionSince[view.id])
        XCTAssertFalse(since.isEmpty)
        let saved = await settings.save(); XCTAssertTrue(saved, settings.message)
        try await model.reloadConfiguration()
        let reloaded = try await model.vault.load()
        XCTAssertEqual(reloaded.capture.sessionModes[view.id], "off")
        XCTAssertEqual(reloaded.capture.sessionSince[view.id], since)
        XCTAssertEqual(reloaded.capture.retentionDays, 7)
        model.opened.remove(view.id); wire.frames = []
        _ = try await model.open(try XCTUnwrap(model.record(view.id)))
        XCTAssertEqual(wire.frames.last { $0["method"]?.string == "debug.mode" }?["params"]?.object?["mode"]?.string, "off")
    }

    func testCapturePreferencesMergeIndividuallyAndNeverCopySessionState() {
        let baseline = VaultConfiguration()
        var edits = baseline; edits.capture.retentionDays = 7
        var current = baseline
        current.capture.defaultMode = "off"; current.capture.quotaBytes *= 2; current.capture.quotaUnlimited = true
        current.capture.sessionModes["chat"] = "off"; current.capture.sessionSince["chat"] = "newer"
        let retained = ConnectionSettingsController.merging(edits, from: baseline, onto: current)
        current.capture.retentionDays = 7
        XCTAssertEqual(retained.capture, current.capture)
        edits = baseline
        edits.capture.defaultMode = "memory"; edits.capture.quotaBytes *= 3; edits.capture.quotaUnlimited = true
        current = baseline; current.capture.retentionDays = 2
        current.capture.sessionModes["chat"] = "off"; current.capture.sessionSince["chat"] = "newer"
        let merged = ConnectionSettingsController.merging(edits, from: baseline, onto: current)
        XCTAssertEqual(merged.capture.defaultMode, "memory"); XCTAssertEqual(merged.capture.quotaBytes, edits.capture.quotaBytes)
        XCTAssertTrue(merged.capture.quotaUnlimited); XCTAssertEqual(merged.capture.retentionDays, 2)
        XCTAssertEqual(merged.capture.sessionModes, current.capture.sessionModes)
        XCTAssertEqual(merged.capture.sessionSince, current.capture.sessionSince)
    }

    func testDeleteRefusesPendingFirstSendAndKeepsDurableChat() async throws {
        try await pendingSend(discardDirectly: false)
    }

    func testDeleteRefusesPendingSideFirstSend() async throws {
        let (model, parent, wire) = try await fixture()
        let side = SideRecord(id: "side", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Side", pending: true)
        let view = SessionDisplay(id: side.id)
        view.selectionMetadataLoaded = true; view.snapshotInFlight = true; view.draft = "First side message"
        model.sides[parent.id] = side; model.displays[side.id] = view
        wire.heldMethod = "session.open"
        model.send(sessionID: side.id)
        try await eventually("parent opening for first side send") { wire.held != nil }
        XCTAssertTrue(view.loading); XCTAssertTrue(model.side(side.id)?.pending == true)
        model.deleteChat(side.id)
        XCTAssertTrue(model.error?.contains("Stop work") == true)
        wire.release()
        try await eventually("side send finished") { !view.loading }
        XCTAssertNotNil(model.record(side.id)); XCTAssertTrue(model.displays[side.id] === view)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: side.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" && $0["sessionId"]?.string == side.id }.count, 1)
    }

    func testRemovedChatAbortsMaterializingSubmission() async throws {
        try await pendingSend(discardDirectly: true)
    }

    func testRemovedPlaceholderMaterializationThrowsAfterCleaningItsRow() async throws {
        let (model, view, _) = try await fixture(pending: true)
        let store = try XCTUnwrap(model.store)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
        defer { released.signal() }
        try await eventually("metadata actor held") { entered.wait(timeout: .now()) == .success }
        let materialize = Task { try await model.materializeChat(view.id) }
        try await eventually("materialization pending") { model.pendingChatSaveCounts[view.id] == 1 }
        model.discardPendingChat(view.id)
        released.signal(); try await barrier.value
        do { try await materialize.value; XCTFail("A removed placeholder must not report successful materialization") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: view.id)
        XCTAssertNil(saved)
    }

    private func pendingSend(discardDirectly: Bool) async throws {
        let (model, view, wire) = try await fixture(pending: true)
        let store = try XCTUnwrap(model.store)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
        defer { released.signal() }
        try await eventually("metadata actor held") { entered.wait(timeout: .now()) == .success }
        view.draft = "First message"
        model.send(sessionID: view.id)
        try await eventually("first metadata write pending") { model.pendingChatSaveCounts[view.id] == 1 }
        XCTAssertTrue(view.loading); XCTAssertFalse(view.busy)
        if discardDirectly { model.discardPendingChat(view.id) }
        else {
            model.deleteChat(view.id)
            XCTAssertNotNil(model.record(view.id), "Delete must refuse an accepted first send")
            XCTAssertTrue(model.displays[view.id] === view)
            XCTAssertTrue(model.error?.contains("Stop work") == true)
        }
        released.signal(); try await barrier.value
        try await eventually("send settled") { !view.loading }
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: view.id)
        XCTAssertEqual(saved != nil, !discardDirectly)
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, discardDirectly ? 0 : 1)
        if discardDirectly { XCTAssertFalse(model.opened.contains(view.id)) }
    }

    func testArchiveDuringSendOpeningReturnsUnsentDraft() async throws { try await archiveDuringOpening("turn.submit") }
    func testArchiveThenRestoreStillInvalidatesPendingSend() async throws { try await archiveDuringOpening("turn.submit", restore: true) }
    func testArchiveDuringEditOpeningKeepsReplacementDraft() async throws { try await archiveDuringOpening("turn.edit") }
    func testArchiveDuringResumeOpeningDoesNotContinue() async throws { try await archiveDuringOpening("run.continue") }
    func testArchiveDuringCompactionOpeningDoesNotDispatch() async throws { try await archiveDuringOpening("context.compact") }
    func testArchiveDuringQueueResumeOpeningDoesNotDispatch() async throws { try await archiveDuringOpening("queue.resume") }

    func testStopInvalidatesResumeBlockedOnMetadataBeforeItsAcknowledgment() async throws {
        try await stopDuringResumeMetadata()
    }
    func testStopInvalidatesFamilyResumeBlockedOnMetadata() async throws {
        try await stopDuringResumeMetadata(family: true)
    }
    func testStopInvalidatesQueuedResumeBlockedOnMetadata() async throws {
        try await stopDuringResumeMetadata(queued: true)
    }
    private func stopDuringResumeMetadata(family: Bool = false, queued: Bool = false) async throws {
        let (model, view, wire) = try await fixture()
        model.opened.insert(view.id); view.runState = .paused; view.runStateKnown = true; view.continuable = true
        view.costPaused = family; view.queueCount = queued ? 1 : 0
        let method = queued ? "queue.resume" : "run.continue"
        let store = try XCTUnwrap(model.store)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
        defer { released.signal() }
        try await eventually("metadata preflight blocked") { entered.wait(timeout: .now()) == .success }
        if queued { model.action(method, sessionID: view.id) } else { model.resumeRun(sessionID: view.id) }
        try await eventually("Resume awaiting metadata") { model.budgetOpenCallers[view.id, default: 0] > 0 }
        model.stop(sessionID: view.id)
        try await eventually("Stop acknowledged") { wire.answered.contains("turn.stop") }
        released.signal(); try await barrier.value
        try await eventually("Resume retired") { !view.resuming && model.budgetOpenCallers[view.id, default: 0] == 0 }
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == method }, "A Resume prepared before Stop must never dispatch afterward")
        let intents = try await store.list(CommandIntent.self, kind: "pending:\(view.id)")
        XCTAssertTrue(intents.isEmpty, "Undispatched Resume must not become uncertain on reopen")
        view.runState = .paused
        if queued { model.action(method, sessionID: view.id) } else { model.resumeRun(sessionID: view.id) }
        try await eventually("fresh Resume finished") { !view.resuming && wire.answered.contains(method) }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == method }.count, 1, "A new click after Stop still resumes")
    }

    func testStopInvalidatesResumeWhileOpeningAnUnloadedChat() async throws {
        let (model, view, wire) = try await fixture()
        wire.heldMethod = "session.open"
        model.resumeRun(sessionID: view.id)
        try await eventually("opening held") { wire.held != nil }
        model.stop(sessionID: view.id)
        wire.release()
        try await eventually("opening Resume retired") { !view.resuming }
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "run.continue" })
        let intents = try await model.store?.list(CommandIntent.self, kind: "pending:\(view.id)")
        XCTAssertTrue(intents?.isEmpty == true)
    }

    func testSideStopCancelsFamilyPreparationButNotAnOrdinaryRootResume() async throws {
        for family in [false, true] {
            let (model, view, wire) = try await fixture()
            view.runState = .paused; view.runStateKnown = true; view.costPaused = family
            let side = ChatRecord(id: "side", workspaceID: "w", title: "Side", path: wire.root.appendingPathComponent("side_side.jsonl").path, profileID: "p", parentSessionID: view.id)
            model.chats.append(side); try await model.store?.put(side, kind: "chat", id: side.id)
            let sideView = SessionDisplay(id: side.id); sideView.queueCount = 1; sideView.snapshotInFlight = true
            model.displays[side.id] = sideView; model.opened.formUnion([view.id, side.id])
            let store = try XCTUnwrap(model.store)
            let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
            defer { released.signal() }
            try await eventually("family metadata held") { entered.wait(timeout: .now()) == .success }
            model.resumeRun(sessionID: view.id)
            try await eventually("root preparing") { model.budgetOpenCallers[view.id, default: 0] > 0 }
            model.stop(sessionID: side.id)
            try await eventually("side Stop acknowledged") { wire.answered.contains("turn.stop") }
            released.signal(); try await barrier.value
            try await eventually("root preparation finished") { !view.resuming }
            XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "run.continue" }.count, family ? 0 : 1)
        }
    }

    func testStopAfterRootResumeDispatchPreventsLaterSideFanout() async throws {
        let (model, view, wire) = try await fixture()
        view.runState = .paused; view.runStateKnown = true; view.costPaused = true
        let side = ChatRecord(id: "side", workspaceID: "w", title: "Side", path: wire.root.appendingPathComponent("side_side.jsonl").path, profileID: "p", parentSessionID: view.id)
        model.chats.append(side); try await model.store?.put(side, kind: "chat", id: side.id)
        model.opened.formUnion([view.id, side.id]); wire.pausedMembers = [side.id]
        wire.heldMethod = "run.continue"
        model.resumeRun(sessionID: view.id)
        try await eventually("root Resume accepted, reply held") { wire.held != nil }
        model.stop(sessionID: view.id)
        try await eventually("root Stop acknowledged") { wire.answered.contains("turn.stop") }
        wire.release()
        try await eventually("family Resume finished") { !view.resuming }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "run.continue" }.compactMap { $0["sessionId"]?.string }, [view.id], "Stop must retire the side fan-out after an accepted root request")
    }

    func testStopDuringResumeIntentPersistenceRemovesUndispatchedIntent() async throws {
        try await stopAfterResumePreflight(queued: false)
    }
    func testStopGenerationAlsoFencesADirectResumeCaller() async throws {
        let (model, view, wire) = try await fixture()
        model.opened.insert(view.id); view.runState = .paused; view.resuming = true
        wire.heldMethod = "session.status"
        let item = try XCTUnwrap(model.record(view.id))
        // Direct callers do not own a registered UI task. The synchronous
        // Stop generation must protect them independently of Task.cancel().
        let pending = Task { await model.performResume(item, view: view) }
        try await eventually("direct Resume status held") { wire.held != nil }
        model.stop(sessionID: view.id)
        try await eventually("direct Stop acknowledged") { wire.answered.contains("turn.stop") }
        wire.release()
        let result = await pending.value; view.resuming = false
        XCTAssertNil(result)
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "run.continue" })
        let intents = try await model.store?.list(CommandIntent.self, kind: "pending:\(view.id)")
        XCTAssertTrue(intents?.isEmpty == true)
    }
    func testStopCancelsResumeStillQueuedInTheSupervisor() async throws {
        try await stopAfterResumePreflight(queued: true)
    }
    private func stopAfterResumePreflight(queued: Bool) async throws {
        let (model, view, wire) = try await fixture()
        model.opened.insert(view.id); view.runState = .paused; view.continuable = true
        wire.heldMethod = "session.status"
        var recording = false
        model.resumeSteps = { if $0 == "recording" { recording = true } }
        model.resumeRun(sessionID: view.id)
        try await eventually("Resume status held") { wire.held != nil }
        let store = try XCTUnwrap(model.store)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let barrier = Task { try await store.put(WorkspaceRaceStoreBarrier(entered: entered, released: released), kind: "fixture", id: "barrier") }
        var blockers: [Task<WireValue, Error>] = []
        defer { released.signal(); wire.release(); for task in blockers { task.cancel() } }
        try await eventually("intent writer blocked") { entered.wait(timeout: .now()) == .success }
        wire.release()
        try await eventually("Resume recording its intent") { recording }
        if queued {
            wire.heldMethod = "context.info"
            for _ in 0..<32 { blockers.append(Task { try await wire.host.request("context.info", sessionID: view.id) }) }
            try await eventually("all supervisor slots occupied") { wire.heldFrames.count == 32 }
            released.signal(); try await barrier.value
            try await eventually("run.continue queued locally") { wire.host.queuedCommandCount == 1 }
            XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "run.continue" })
        }
        // The forwarded action has the same synchronous retirement as the
        // Stop button; even a full normal-command lane cannot delay its ack.
        if queued { model.stop(sessionID: view.id) } else { model.action("turn.stop", sessionID: view.id) }
        try await eventually("Stop acknowledged before preflight/queue released") { wire.answered.contains("turn.stop") }
        if queued { wire.release(); for task in blockers { _ = try await task.value } }
        else { released.signal(); try await barrier.value }
        try await eventually("Resume cancelled") { !view.resuming }
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "run.continue" })
        let intents = try await store.list(CommandIntent.self, kind: "pending:\(view.id)")
        XCTAssertTrue(intents.isEmpty)
        XCTAssertNil(model.error)
    }

    func testBulkRestoreDoesNotCancelAnActiveChatsPendingSend() async throws {
        let (model, view, wire) = try await fixture()
        var archived = ChatRecord(id: "archived", workspaceID: "w", title: "Archived", profileID: "p")
        archived.archivedAt = Date()
        model.chats.append(archived); try await model.store?.put(archived, kind: "chat", id: archived.id)
        wire.heldMethod = "session.open"
        view.draft = "An active chat's message"; model.send(sessionID: view.id)
        try await eventually("active chat open held") { wire.held != nil }
        model.markedSessionIDs = [view.id, archived.id]
        model.archiveMarkedSessions(false)
        try await eventually("bulk restore finished") { model.record(archived.id)?.isArchived == false && !model.organizationScheduler.inFlight }
        wire.release()
        try await eventually("active chat send finished") { !view.loading }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, 1)
        XCTAssertNil(view.sendFailure); XCTAssertEqual(view.draft, "")
    }

    private func archiveDuringOpening(_ method: String, restore: Bool = false) async throws {
        let (model, view, wire) = try await fixture()
        wire.heldMethod = "session.open"
        view.draft = "Recoverable input"
        switch method {
        case "turn.submit": model.send(sessionID: view.id)
        case "turn.edit": view.editingMessageID = "original"; model.sendEdit(sessionID: view.id)
        case "run.continue": model.resumeRun(sessionID: view.id)
        default: model.action(method, sessionID: view.id)
        }
        try await eventually("session open held") { wire.held != nil }
        _ = try await model.enqueueOrganization([view.id], change: .archived(true)).value
        XCTAssertTrue(model.record(view.id)?.isArchived == true)
        if restore { _ = try await model.enqueueOrganization([view.id], change: .archived(false)).value }
        wire.release()
        try await eventually("preparation finished") {
            !view.loading && !view.resuming && (model.error != nil || view.sendFailure != nil || !view.editNotice.isEmpty || wire.frames.contains { $0["method"]?.string == method })
        }
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == method }, "Archived preparation dispatched \(method)")
        XCTAssertEqual(view.draft, "Recoverable input")
        if method == "turn.submit" || method == "turn.edit" {
            let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(draft?.text, "Recoverable input")
        }
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(view.id)")
        XCTAssertTrue(pending?.isEmpty == true, "Undispatched work must not become uncertain after relaunch")
    }

    func testArchiveInvalidatesSendBeforeArchiveCommitReturns() async throws {
        let (model, view, wire) = try await fixture()
        let store = try XCTUnwrap(model.store), gate = AsyncGate()
        var writing = false
        model.organizationWrite = { ids, change in
            writing = true; await gate.wait()
            return try await store.updateChatOrganizations(ids: ids, change: change)
        }
        wire.heldMethod = "session.open"
        view.draft = "Do not send while archiving"; model.send(sessionID: view.id)
        try await eventually("open held") { wire.held != nil }
        let archive = model.enqueueOrganization([view.id], change: .archived(true))
        try await eventually("archive commit held") { writing }
        wire.release()
        do { try await eventually("send finished before archive write") { !view.loading } }
        catch { await gate.open(); _ = try? await archive.value; throw error }
        await gate.open(); _ = try await archive.value
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "turn.submit" })
        XCTAssertEqual(view.draft, "Do not send while archiving")
    }

    func testSendStartedDuringArchiveCommitKeepsItsDraft() async throws {
        let (model, view, wire) = try await fixture()
        let store = try XCTUnwrap(model.store), gate = AsyncGate()
        var writing = false
        model.organizationWrite = { ids, change in
            writing = true; await gate.wait()
            return try await store.updateChatOrganizations(ids: ids, change: change)
        }
        model.opened.insert(view.id)
        let archive = model.enqueueOrganization([view.id], change: .archived(true))
        try await eventually("archive commit held") { writing }
        view.draft = "Typed during archive"; model.send(sessionID: view.id)
        do { try await eventually("send settled") { !view.loading } }
        catch { await gate.open(); _ = try? await archive.value; throw error }
        await gate.open(); _ = try await archive.value
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "turn.submit" })
        XCTAssertEqual(view.draft, "Typed during archive")
    }

    func testReplyForkKeepsReportNavigation() async throws { try await forkNavigation(reply: true, returnToChats: false) }
    func testReplyForkDoesNotNavigateAfterLeavingAndReturning() async throws { try await forkNavigation(reply: true, returnToChats: true) }
    func testWholeChatForkKeepsReportNavigation() async throws { try await forkNavigation(reply: false, returnToChats: false) }
    func testReplyForkStillOpensWithoutNewNavigation() async throws { try await forkNavigation(reply: true, returnToChats: false, navigate: false) }
    func testWholeChatForkStillOpensWithoutNewNavigation() async throws { try await forkNavigation(reply: false, returnToChats: false, navigate: false) }

    private func forkNavigation(reply: Bool, returnToChats: Bool, navigate: Bool = true) async throws {
        let (model, view, wire) = try await fixture()
        model.opened.insert(view.id); wire.heldMethod = "session.fork"
        if reply { model.forkFromReply(sessionID: view.id, messageID: "reply") }
        else { model.forkSession(view.id) }
        try await eventually("fork creation held") { wire.held != nil }
        if navigate { model.openReport() }
        if returnToChats { model.closeReport() }
        wire.release()
        try await eventually("fork finished") { model.forkingReplies.isEmpty && !view.loading }
        let fork = try XCTUnwrap(model.chats.first { $0.id != view.id })
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: fork.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(model.page, !navigate || returnToChats ? .chats : .report)
        XCTAssertEqual(model.selectedID, navigate ? view.id : fork.id)
        XCTAssertEqual(model.focusedSessionID, navigate ? view.id : fork.id)
        if navigate { XCTAssertEqual(model.displays[fork.id]?.composerFocusRequest, 0) }
        XCTAssertNil(model.error)
    }
}

@MainActor private final class WorkspaceRaceHost {
    let root: URL
    var frames: [[String: WireValue]] = []
    var answered: [String] = []
    var heldMethod: String?
    var rejectedMethod: String?
    var heldSessionID: String?
    var held: [String: WireValue]?
    var heldFrames: [[String: WireValue]] = []
    var stopRevision = 0
    var pausedMembers: [String] = []
    lazy var host = HostSupervisor(commandSender: { [weak self] frame in
        guard let self else { return }
        self.frames.append(frame)
        if frame["method"]?.string == self.heldMethod, self.heldSessionID == nil || frame["sessionId"]?.string == self.heldSessionID { self.held = frame; self.heldFrames.append(frame) }
        else { self.answer(frame) }
    })
    init(root: URL) { self.root = root }
    func release(holding method: String? = nil) { let frames = heldFrames; heldFrames = []; held = nil; heldMethod = method; for frame in frames { answer(frame) } }
    private func answer(_ frame: [String: WireValue]) {
        var result: [String: WireValue] = [:]
        if frame["method"]?.string == "turn.stop" { stopRevision += 1 }
        if frame["method"]?.string == "session.status" || frame["method"]?.string == "session.open" {
            result["resumeToken"] = .string("fixture:\(stopRevision)")
            if !pausedMembers.isEmpty { result["cost"] = .object(["paused": .bool(true), "pausedMembers": .array(pausedMembers.map(WireValue.string))]) }
        }
        if frame["method"]?.string == "run.continue" { result["pausedMembers"] = .array(pausedMembers.map(WireValue.string)) }
        let side = frame["method"]?.string == "side.open"
        if side || frame["method"]?.string == "session.fork", let id = frame["params"]?.object?[side ? "sideSessionId" : "forkSessionId"]?.string {
            let path = root.appendingPathComponent("Workspaces/w/Sessions/\(side ? "side" : "fork")_\(id).jsonl")
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header: [String: WireValue] = ["type": .string("session"), "version": .number(3), "id": .string(id)]
                var bytes = try JSONEncoder().encode(header); bytes.append(10); try bytes.write(to: path)
                result = ["sessionId": .string(id), "path": .string(path.path)]
            } catch { XCTFail("Generated fork could not be written: \(error)") }
        }
        guard let connection = host.connectionID, let epoch = host.epoch, let command = frame["commandId"] else { return }
        let rejected = frame["method"]?.string == rejectedMethod
        if rejected { result = ["code": .string("fixture_rejection"), "message": .string("Fixture rejection")] }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch), "commandId": command,
                             "ok": .bool(!rejected), "result": .object(result)]), connectionID: connection)
        answered.append(frame["method"]?.string ?? "")
    }
}

private struct WorkspaceRaceStoreBarrier: Encodable, Sendable {
    let entered: DispatchSemaphore
    let released: DispatchSemaphore
    func encode(to encoder: Encoder) throws {
        entered.signal(); released.wait()
        var value = encoder.singleValueContainer(); try value.encode(true)
    }
}
