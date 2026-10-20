import XCTest
@testable import PiApp

@MainActor final class SubmissionPersistenceTests: XCTestCase {
    private func fixture() async throws -> (WorkspaceModel, SessionDisplay, SubmissionPersistenceHost) {
        let root = scratchRoot("submission-persistence")
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        var config = VaultConfiguration()
        config.workspaces = [workspace]; config.profiles = [.init(profile: profile, apiKey: "generated-fixture-key")]
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        model.prewarmsHelpers = false
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        try await model.reloadConfiguration()
        var chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", profileID: "p"); chat.titleWasEdited = true
        let view = SessionDisplay(id: chat.id)
        view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view
        model.selectedID = chat.id; model.focusedSessionID = chat.id; model.selected = view
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        let wire = SubmissionPersistenceHost(root: root)
        try await wire.host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts["w"] = wire.host; model.opened.insert(chat.id)
        return (model, view, wire)
    }

    func testSendKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot() async throws { try await typingDuringWrite("turn.submit") }
    func testQueuedSaveProtectsOutputBeforePublishingCapturedInput() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.draft = "Captured output reference"; view.queueEditingID = "queued"; view.queueEditID = "edit"
        view.queueEditOriginal = "Original queued text"; view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "")
        let gate = AsyncGate(); var entered = false
        model.toolOutputProducerStep = { producer in
            if producer == .queuedEdit { entered = true; await gate.wait() }
        }
        wire.heldMethod = "queue.edit.save"
        model.saveQueuedEdit(sessionID: view.id)
        XCTAssertTrue(model.toolOutputProducers.values.contains(.queuedEdit), "Captured input needs protection before its persistence task starts")
        try await eventually("Queued Save reached output protection") { entered }
        let durable = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(durable.map(\.text), ["Captured output reference"], "Captured input must be durable while recycling delays dispatch")
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "queue.edit.save" })
        view.draft = "Newer typing"; model.draftChanged(view)
        await gate.open()
        try await eventually("Captured queue Save dispatched") { wire.held != nil }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "queue.edit.save" }.count, 1)
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(pending.map(\.text), ["Captured output reference"])
        wire.release()
        try await eventually("Queued Save settled") { !view.queueEditResolving && model.toolOutputProducers.isEmpty }
        XCTAssertTrue(view.draft.contains("Newer typing"))
        try await wire.host.shutdownAndWait()
    }
    func testSteerKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot() async throws { try await typingDuringWrite("turn.steer") }
    func testHistoricalEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot() async throws { try await typingDuringWrite("turn.edit") }
    func testQueuedEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot() async throws { try await typingDuringWrite("queue.edit.save") }

    private func typingDuringWrite(_ method: String) async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.draft = "Captured replacement"
        if method == "turn.edit" {
            view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked input")
        } else if method == "queue.edit.save" {
            view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original queued text"
            view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked input")
        } else if method == "turn.steer" { view.runState = .running }
        wire.heldMethod = method
        let gate = DraftBaselineGate(expectation(description: "Metadata writer held"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
        else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
        else { model.send(steer: method == "turn.steer", sessionID: view.id) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(wire.frames.contains { $0["method"]?.string == method }, "Captured input must be durable before dispatch")
        view.draft = "Newer typing"; model.draftChanged(view)
        try await Task.sleep(for: .milliseconds(180))
        gate.resume.signal(); await blocker.value
        // Wait for persistence and either dispatch or the old pre-dispatch failure.
        try await Task.sleep(for: .milliseconds(250))
        let frames = wire.frames.filter { $0["method"]?.string == method }
        XCTAssertEqual(frames.count, 1, "Typing must not cancel a captured submission")
        XCTAssertEqual(frames.first?["params"]?.object?["text"]?.string, "Captured replacement")
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(pending.map(\.text), ["Captured replacement"], "Only the composer snapshot is replaceable")
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(method == "queue.edit.save" ? saved?.queuedEdit?.rewrite : saved?.text, "Newer typing")
        wire.release()
        try await eventually("Submission settled") { !view.loading && !view.queueEditResolving }
        XCTAssertTrue(view.draft.contains("Newer typing"))
        try await wire.host.shutdownAndWait()
    }

    func testSideFirstSendIsDurableWhileParentOpeningAndTypingContinue() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.opened.remove(parent.id); wire.heldMethod = "session.open"
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Captured first side message"
        let gate = DraftBaselineGate(expectation(description: "Side metadata held"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        model.send(sessionID: side.id)
        try await Task.sleep(for: .milliseconds(30))
        view.draft = "New side typing"; model.draftChanged(view)
        gate.resume.signal(); await blocker.value
        try await eventually("Parent opening held") { wire.held != nil }
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + side.id)
        XCTAssertEqual(pending.map(\.text), ["Captured first side message"], "A side's first input is not its replaceable draft")
        wire.release(holding: "turn.submit")
        try await eventually("Side submission dispatched") { wire.held?["method"]?.string == "turn.submit" }
        let frames = wire.frames.filter { $0["method"]?.string == "turn.submit" }
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames.first?["params"]?.object?["text"]?.string, "Captured first side message")
        wire.release()
        try await eventually("Side submission settled") { !view.loading }
        XCTAssertEqual(view.draft, "New side typing")
        try await wire.host.shutdownAndWait()
    }

    func testFirstChatSendSurvivesTypingDuringMaterializationDraftWrite() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.pendingChatIDs.insert(view.id)
        let first = DraftBaselineGate(expectation(description: "First metadata barrier"))
        let second = DraftBaselineGate(expectation(description: "Materialization snapshot barrier"))
        let blocker = Task { await store.holdDraftBaseline(first) }
        await fulfillment(of: [first.entered], timeout: 3)
        defer { first.resume.signal(); second.resume.signal() }
        wire.heldMethod = "turn.submit"
        view.draft = "Captured first chat input"; model.send(sessionID: view.id)
        try await eventually("Chat write queued") { model.pendingChatSaveCounts[view.id] == 1 }
        // The pending chat's draft is sampled after its row is saved. Arrange
        // another actor operation between that row and the draft write.
        let nextBlocker = Task { await store.holdDraftBaseline(second) }
        view.draft = "Typing during chat creation"; model.draftChanged(view)
        first.resume.signal(); await blocker.value
        await fulfillment(of: [second.entered], timeout: 3)
        try await eventually("Materialization captured its draft") { !model.pendingChatIDs.contains(view.id) }
        view.draft = "Newer typing during materialization"; model.draftChanged(view)
        second.resume.signal(); await nextBlocker.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, 1)
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(pending.map(\.text), ["Captured first chat input"])
        wire.release()
        try await eventually("First chat send settled") { !view.loading }
        XCTAssertEqual(view.draft, "Newer typing during materialization")
        try await wire.host.shutdownAndWait()
    }

    func testRejectedHistoricalEditRetainsItsInputWhenTheComposerChanged() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.draft = "Captured replacement"; view.editingMessageID = "original"
        view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked input")
        wire.heldMethod = "turn.edit"; model.sendEdit(sessionID: view.id)
        try await eventually("Edit held") { wire.held != nil }
        view.draft = "Different replacement"; model.draftChanged(view)
        await model.draftWrites.tasks[view.id]?.value
        wire.rejectedMethod = "turn.edit"; wire.release()
        try await eventually("Rejected edit settled") { !view.loading }
        await model.draftWrites.tasks[view.id]?.value
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(pending.map(\.text), ["Captured replacement"], "A refusal cannot discard input replaced by subsequent typing")
        XCTAssertEqual(view.draft, "Different replacement")
        try await wire.host.shutdownAndWait()
    }

    func testFailedSideFirstSendKeepsItsInputUntilDurableRecovery() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.opened.remove(parent.id); wire.heldMethod = "session.open"
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.draft = "Captured side input"; view.snapshotInFlight = true
        model.send(sessionID: view.id)
        try await eventually("Parent opening held") { wire.held != nil }
        view.draft = "Later side typing"; model.draftChanged(view)
        wire.rejectedMethod = "session.open"; wire.release()
        try await eventually("First side send refused") { !view.loading }
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertTrue(pending.contains { $0.text == "Captured side input" } || saved?.text.contains("Captured side input") == true,
                      "Restoring only into an ephemeral display cannot retire the durable input")
        XCTAssertTrue(view.draft.contains("Captured side input")); XCTAssertTrue(view.draft.contains("Later side typing"))
        try await wire.host.shutdownAndWait()
    }

    func testQueuedSaveRecoveryRetiresOnlyTheMatchingDurableOutcome() async throws {
        for matches in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let intent = CommandIntent(id: "captured", sessionID: view.id, turnID: "queue-edit:edit", text: "Captured queued rewrite",
                                       state: "intent", draftReviewTracked: true, queueEditID: "edit")
            try await store.recordSubmission(intent, draft: nil)
            view.draft = "Later typing"; model.draftChanged(view)
            await model.draftWrites.tasks[view.id]?.value
            model.queueEditOperation = { method, _, _ in
                XCTAssertEqual(method, "queue.edit.status")
                return ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(matches ? intent.text : "Some other rewrite"))]
            }
            let reopened = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
            let durable = try await reopened.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertEqual(durable.map(\.text), [intent.text])
            let recovered = try await model.recoverableIntents(durable, for: try XCTUnwrap(model.record(view.id)), view: view)
            XCTAssertEqual(recovered.map(\.text), matches ? [] : [intent.text])
            let remaining = try await reopened.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertEqual(remaining.map(\.text), matches ? [] : [intent.text])
            XCTAssertEqual(view.draft, "Later typing")
            await reopened.close(); try await wire.host.shutdownAndWait()
        }
    }

    func testQueuedSaveRetriesKeepOneRecordPerCapturedInput() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked input")
        model.queueEditOperation = { _, _, _ in throw HostError.rejected("fixture", "Generated refusal") }
        for text in ["First captured rewrite", "First captured rewrite", "Different captured rewrite"] {
            view.draft = text; model.saveQueuedEdit(sessionID: view.id)
            try await eventually("Queue save refused") { !view.queueEditResolving }
        }
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(pending.map(\.text).sorted(), ["Different captured rewrite", "First captured rewrite"],
                       "A retry repeats the same input; a different capture must not overwrite it")
        try await wire.host.shutdownAndWait()
    }
}

@MainActor private final class SubmissionPersistenceHost {
    let root: URL
    var frames: [[String: WireValue]] = []
    var heldMethod: String?
    var rejectedMethod: String?
    var held: [String: WireValue]?
    lazy var host = HostSupervisor(commandSender: { [weak self] frame in
        guard let self else { return }
        frames.append(frame)
        if frame["method"]?.string == heldMethod { held = frame } else { answer(frame) }
    })
    init(root: URL) { self.root = root }
    func release(holding method: String? = nil) { let frame = held; held = nil; heldMethod = method; if let frame { answer(frame) } }
    private func answer(_ frame: [String: WireValue]) {
        var result: [String: WireValue] = [:]
        if frame["method"]?.string == "side.open", let id = frame["params"]?.object?["sideSessionId"]?.string {
            let path = root.appendingPathComponent("Workspaces/w/Sessions/side_\(id).jsonl")
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header: [String: WireValue] = ["type": .string("session"), "version": .number(3), "id": .string(id)]
                var bytes = try JSONEncoder().encode(header); bytes.append(10); try bytes.write(to: path)
                result = ["sessionId": .string(id), "path": .string(path.path)]
            } catch { XCTFail("Generated side could not be written: \(error)") }
        }
        guard let connection = host.connectionID, let epoch = host.epoch, let command = frame["commandId"] else { return }
        let rejected = frame["method"]?.string == rejectedMethod
        if rejected { result = ["code": .string("fixture_rejection"), "message": .string("Fixture rejection")] }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch), "commandId": command,
                             "ok": .bool(!rejected), "result": .object(result)]), connectionID: connection)
    }
}
