import XCTest
import SQLite3
@testable import PiApp

@MainActor final class SubmissionPersistenceTests: XCTestCase {
    func testFailedSidePublicationTransfersPersistedInputToParentRecovery() async throws {
        for closing in [true, false] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            model.openSide(parentID: parent.id)
            let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
            view.snapshotInFlight = true; view.draft = "First side input"
            wire.rejectedMethod = "side.open"
            model.send(sessionID: side.id)
            try await eventually("Side publication refused") { !view.loading && model.toolOutputProducers.isEmpty }
            let captured = try XCTUnwrap(view.recovered.first)
            let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
            XCTAssertNotNil(keep, "The parent link protects launch recovery until transfer"); XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
            view.draft = "Different side draft"
            if closing { let discarded = await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id])); XCTAssertTrue(discarded) }
            else { try await model.moveUnsavedSideDraftsToParents() }
            try await model.flushDrafts()
            let saved = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
            XCTAssertEqual(saved.map(\.text), [captured.text], "Closing and quit must leave recovery with a saved parent")
            XCTAssertEqual(parent.recovered.map(\.text), [captured.text])
            let orphaned = try await store.list(CommandIntent.self, kind: "pending:" + side.id)
            XCTAssertTrue(orphaned.isEmpty, "No unresolved input may remain under an unregistered side")
            let relaunched = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
            let metadata = try await relaunched.selectionMetadata(id: parent.id, draft: true, anchor: false)
            XCTAssertEqual(metadata.recovered.map(\.text), [captured.text])
            XCTAssertTrue(metadata.draft?.text.contains("Different side draft") == true)
            await relaunched.close(); try await wire.host.shutdownAndWait()
        }
    }

    func testWithdrawalCannotConsumeInputFromAnUnchangedButStaleDraft() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let old = DraftRecord(id: view.id, text: "Captured input")
        try await store.put(old, kind: "draft", id: view.id)
        view.draftVersion = try await store.draftVersion(id: view.id); view.draft = old.text
        let intent = CommandIntent(id: "refused", sessionID: view.id, turnID: "turn", text: old.text, state: "intent")
        view.draftVersion.preservingSubmission(intent)
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        try await other.put(DraftRecord(id: view.id, text: "Other instance's newer draft"), kind: "draft", id: view.id)
        do {
            try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: old, draftVersion: view.draftVersion)
            XCTFail("An unchanged loaded snapshot is not proof that durable storage holds the input")
        } catch {}
        XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent])
        XCTAssertTrue(view.hasUnsavedDraft, "Eviction must retain input absent from the current durable draft")
        let saved = try await other.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Other instance's newer draft")
        await other.close(); try await wire.host.shutdownAndWait()
    }

    func testFailedSidePublicationRecoversViaParentAfterRelaunch() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Side input before relaunch"
        wire.rejectedMethod = "side.open"; model.send(sessionID: side.id)
        try await eventually("Side publication refused") { !view.loading && model.toolOutputProducers.isEmpty }
        // Reconstruct from desktop records alone, without the live display.
        model.sides.removeAll(); model.displays.removeValue(forKey: side.id)
        try await wire.host.shutdownAndWait()
        await model.reconcileSideKeeps()
        let recovered = try await store.selectionMetadata(id: parent.id, draft: false, anchor: false)
        XCTAssertEqual(recovered.recovered.map(\.text), ["Side input before relaunch"])
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
        XCTAssertNil(keep); XCTAssertTrue(model.sideKeepIssues.isEmpty)
        XCTAssertEqual(parent.recovered.map(\.text), ["Side input before relaunch"])
    }

    func testPinnedSideInputMaterializesItsPendingParentBeforeTransfer() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.pendingChatIDs.insert(parent.id)
        try await store.remove(kind: "chat", id: parent.id)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Side input for a new parent"
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_keep BEFORE INSERT ON records WHEN NEW.kind='side-keep' BEGIN SELECT RAISE(ABORT, 'generated keep failure'); END", root: model.root)
        model.send(sessionID: side.id)
        try await eventually("First side capture retained") { !view.loading && model.toolOutputProducers.isEmpty }
        try RecoveredDraftTests.sql("DROP TRIGGER fail_keep", root: model.root)
        let closed = await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id]))
        XCTAssertTrue(closed)
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: parent.id)
        XCTAssertNotNil(saved)
        let inputs = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
        XCTAssertEqual(inputs.map(\.text), ["Side input for a new parent"])
        try await wire.host.shutdownAndWait()
    }

    func testSideCloseWaitsForAnAdmittedDismissalBeforeTransferringInput() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Side input to dismiss"
        wire.rejectedMethod = "side.open"; model.send(sessionID: side.id)
        try await eventually("Side publication refused") { !view.loading && model.toolOutputProducers.isEmpty }
        let intent = try XCTUnwrap(view.recovered.first)
        view.draft = "Different current draft"
        let gate = AsyncGate(); var entered = false
        model.toolOutputProducerStep = { if $0 == .draftRecovery { entered = true; await gate.wait() } }
        model.recoverDraft(intent, insert: false)
        try await eventually("Dismiss admitted before Close") { entered }
        let closing = Task { await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id])) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.displays[side.id] === view, "Close must wait for the admitted recovery action")
        await gate.open()
        let closed = try await closing.value; await model.draftWrites.recoveries[side.id]?.value
        XCTAssertTrue(closed)
        let inputs = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
        XCTAssertTrue(inputs.isEmpty, "Explicit Dismiss must not become a new recovery copy in the parent")
        XCTAssertEqual(parent.draft, "Different current draft")
        try await wire.host.shutdownAndWait()
    }

    func testDismissingFailedSideInputRetiresItsParentLinkOnClose() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Side input to dismiss"
        wire.rejectedMethod = "side.open"; model.send(sessionID: side.id)
        try await eventually("Side publication refused") { !view.loading && model.toolOutputProducers.isEmpty }
        let intent = try XCTUnwrap(view.recovered.first)
        model.recoverDraft(intent, insert: false); await model.draftWrites.recoveries[view.id]?.value
        XCTAssertTrue(view.recovered.isEmpty)
        let closed = await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id]))
        XCTAssertTrue(closed)
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
        XCTAssertNil(keep, "An explicitly dismissed input must not leave a missing-journal recovery notice")
        try await wire.host.shutdownAndWait()
    }

    func testFailedSideInputTransfersAreAtomicAndKeepThePaneReachable() async throws {
        for (event, kind, rollback) in [("INSERT", "pending:chat", false), ("DELETE", "source", false), ("DELETE", "side-keep", false), ("INSERT", "pending:chat", true)] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            model.openSide(parentID: parent.id)
            let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
            view.snapshotInFlight = true; view.draft = "Retained side input"
            wire.rejectedMethod = "side.open"; model.send(sessionID: side.id)
            try await eventually("Side publication refused") { !view.loading && model.toolOutputProducers.isEmpty }
            view.draft = "Later draft"
            let row = event == "DELETE" ? "OLD" : "NEW", target = kind == "source" ? "pending:" + side.id : kind
            try RecoveredDraftTests.sql("CREATE TRIGGER fail_transfer \(rollback ? "AFTER" : "BEFORE") \(event) ON records WHEN \(row).kind='\(target)' BEGIN SELECT RAISE(\(rollback ? "ROLLBACK" : "ABORT"), 'generated transfer failure'); END", root: model.root)
            let discarded = await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id]))
            XCTAssertFalse(discarded); XCTAssertTrue(model.displays[side.id] === view)
            XCTAssertEqual(view.recovered.map(\.text), ["Retained side input"]); XCTAssertEqual(view.draft, "Later draft")
            let source = try await store.list(CommandIntent.self, kind: "pending:" + side.id)
            let destination = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
            XCTAssertEqual(source.map(\.text), ["Retained side input"]); XCTAssertTrue(destination.isEmpty)
            try RecoveredDraftTests.sql("DROP TRIGGER fail_transfer", root: model.root)
            let closed = await model.discardPendingSide(try XCTUnwrap(model.sides[parent.id]))
            XCTAssertTrue(closed); XCTAssertEqual(parent.recovered.map(\.text), ["Retained side input"])
            try await wire.host.shutdownAndWait()
        }
    }

    func testPreservationInvalidatesAnEmptyPendingSnapshotCache() async throws {
        for restoring in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let intent = CommandIntent(id: "retained", sessionID: view.id, turnID: "turn", text: "Captured input", state: "intent")
            view.draftVersion.preservingSubmission(intent)
            try await snapshot(model, view: view, wire: wire)
            XCTAssertEqual(view.pendingIntents?.intents, []); XCTAssertEqual(view.recovered, [intent])
            if restoring {
                let copy = SavedDraftConflict(id: "copy", draft: DraftRecord(id: view.id, text: "Conflict copy"))
                try await store.put(copy.draft, kind: "draft-conflict:" + view.id, id: copy.id)
                try await store.restoreConflict(copy, replacing: view.savedDraft, version: view.draftVersion)
            } else { try await model.flushDrafts() }
            XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
            try await snapshot(model, view: view, wire: wire)
            XCTAssertEqual(view.recovered, [intent], "A preservation commit must retire the cached empty inventory")
            try await wire.host.shutdownAndWait()
        }
    }

    func testStreamingSnapshotsNeverOfferLiveSteersOrFollowupsForRecovery() async throws {
        for steer in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            view.runState = .running; view.draft = "Input being delivered"
            wire.heldMethod = steer ? "turn.steer" : "turn.submit"
            model.send(steer: steer, sessionID: view.id)
            try await eventually("Dispatch held before acceptance") { wire.held != nil }
            let durable = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            let intent = try XCTUnwrap(durable.first)
            try await snapshot(model, view: view, wire: wire)
            XCTAssertTrue(view.recovered.isEmpty, "A snapshot cannot turn live input into recovery")
            // Exercise both actions with the exact input, including a stale
            // chooser snapshot retained while a retry started.
            view.recovered = [intent]
            for insert in [false, true] {
                model.recoverDraft(intent, insert: insert)
                await model.draftWrites.recoveries[view.id]?.value
                let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
                XCTAssertEqual(pending, durable)
                XCTAssertEqual(view.draft, "")
            }
            wire.release()
            try await eventually("Accepted submission settled") { !view.loading && model.toolOutputProducers.isEmpty }
            XCTAssertTrue(view.recovered.isEmpty)
            XCTAssertEqual(wire.frames.filter { $0["method"]?.string == (steer ? "turn.steer" : "turn.submit") }.count, 1)
            try await wire.host.shutdownAndWait()
        }
    }

    func testEveryCapturedSubmissionOwnsItsInputUntilItsTaskSettles() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let view: SessionDisplay
            if method == "side" {
                model.openSide(parentID: parent.id)
                view = try XCTUnwrap(model.sides[parent.id].flatMap { model.displays[$0.id] }); view.snapshotInFlight = true
            } else { view = parent }
            view.draft = "Captured live input"
            if method == "turn.edit" { view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "queue.edit.save" { view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"; view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "turn.steer" { view.runState = .running }
            wire.heldMethod = method == "side" ? "turn.submit" : method
            if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
            else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
            else { model.send(steer: method == "turn.steer", sessionID: view.id) }
            try await eventually("Input dispatched but not accepted") { wire.held != nil }
            let durable = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            let intent = try XCTUnwrap(durable.first)
            XCTAssertEqual(view.submittingCommands, [intent.id], method)
            try await snapshot(model, view: view, wire: wire)
            XCTAssertTrue(view.recovered.isEmpty, method)
            // Isolate command ownership from the other UI guards: stale menu
            // actions must remain inert even if an unrelated callback clears
            // loading or the editor before this submission task finishes.
            let loading = view.loading, editing = view.editingMessageID, queueEditing = view.queueEditingID
            view.loading = false; view.editingMessageID = nil; view.queueEditingID = nil; view.recovered = [intent]
            let draft = view.draft
            for insert in [false, true] {
                model.recoverDraft(intent, insert: insert); await model.draftWrites.recoveries[view.id]?.value
                let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
                XCTAssertEqual(pending, durable); XCTAssertEqual(view.draft, draft)
            }
            view.loading = loading; view.editingMessageID = editing; view.queueEditingID = queueEditing
            view.recovered = []; view.draft = "Newer typing"
            wire.rejectedMethod = wire.heldMethod; wire.release()
            try await eventually("Rejected input settled") { view.submittingCommands.isEmpty && model.toolOutputProducers.isEmpty }
            if method == "turn.edit" || method == "queue.edit.save" {
                XCTAssertTrue(view.recoverableSubmissions.contains { $0.id == intent.id }, method)
            } else {
                let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
                XCTAssertTrue(saved?.text.contains(intent.text) == true, method)
            }
            try await wire.host.shutdownAndWait()
        }
    }

    func testLiveQueuedSaveKeepsItsDisplayAfterItsInputBecomesDurable() async throws {
        let (model, view, wire) = try await fixture()
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked")
        view.draft = "Live queued rewrite"; wire.heldMethod = "queue.edit.save"
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Save held after recording") { wire.held != nil }
        await model.draftWrites.tasks[view.id]?.value
        XCTAssertFalse(view.hasWork); XCTAssertFalse(view.loading); XCTAssertFalse(view.hasUnsavedDraft)
        XCTAssertEqual(view.submittingCommands.count, 1)
        view.used = .distantPast
        for index in 0..<9 {
            let id = "other-\(index)"
            model.chats.append(ChatRecord(id: id, workspaceID: "w", title: id, profileID: "p"))
            model.displays[id] = SessionDisplay(id: id)
        }
        model.selectedID = "other-8"
        model.releaseUnreadDisplays(keeping: "other-8")
        XCTAssertTrue(model.displays[view.id] === view, "A live task must retain its display ownership after durability, so hydration cannot present it as recovery")
        XCTAssertLessThanOrEqual(model.displays.count, 8)
        wire.release()
        try await eventually("Queued Save settled") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        try await wire.host.shutdownAndWait()
    }

    private func snapshot(_ model: WorkspaceModel, view: SessionDisplay, wire: SubmissionPersistenceHost) async throws {
        wire.snapshotSequence += 1
        view.snapshotInFlight = false; model.refresh(view.id)
        try await eventually("Streaming snapshot reconciled") { !view.snapshotInFlight && view.lastSequence == Double(wire.snapshotSequence) }
        view.snapshotInFlight = true
    }

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

    func testStorageFailureKeepsEveryCapturedSubmissionRecoverableInPlace() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            try await failedCapture(method, kind: "pending:%")
        }
    }

    func testDraftWriteFailureKeepsEveryCapturedSubmissionRecoverableInPlace() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            try await failedCapture(method, kind: "draft", superseding: false)
        }
    }

    func testSideIntentAndNewChatWriteFailuresRetainCapturedInput() async throws {
        try await failedCapture("side", kind: "side-keep")
        try await failedCapture("new-chat", kind: "chat")
    }

    func testRollbackAfterInputInsertKeepsEverySubmissionRecoverable() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            try await failedCapture(method, kind: "pending:%", rollback: true)
        }
    }

    func testEveryFailedCaptureCanBeExplicitlyDiscardedWithoutReturningOnFlush() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            try await failedCapture(method, kind: "pending:%", discard: true)
        }
    }

    func testSideRegistrationFailuresLeaveCapturedInputReachable() async throws {
        for (kind, event) in [("chat", "INSERT"), ("draft", "INSERT"), ("side-keep", "DELETE"), (SideKeepRegistration.kind, "INSERT")] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            model.openSide(parentID: parent.id)
            let view = try XCTUnwrap(model.sides[parent.id].flatMap { model.displays[$0.id] })
            view.snapshotInFlight = true; view.draft = "Captured before registration failure"
            wire.heldMethod = "side.open"; model.send(sessionID: view.id)
            try await eventually("Side publication held") { wire.held != nil }
            view.draft = "Newer side typing"; model.draftChanged(view)
            let row = event == "DELETE" ? "OLD" : "NEW"
            try RecoveredDraftTests.sql("CREATE TRIGGER fail_registration BEFORE \(event) ON records WHEN \(row).kind='\(kind)' BEGIN SELECT RAISE(ABORT, 'generated registration failure'); END", root: model.root)
            wire.release()
            try await eventually("Registration failure settled") { !view.loading && model.toolOutputProducers.isEmpty }
            XCTAssertFalse(wire.frames.contains { $0["method"]?.string == "turn.submit" })
            let intent = try XCTUnwrap(view.recovered.first { $0.text == "Captured before registration failure" })
            let durable = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertTrue(durable.contains { $0.id == intent.id }, kind)
            try RecoveredDraftTests.sql("DROP TRIGGER fail_registration", root: model.root)
            view.draft = "After failure"
            model.recoverDraft(intent, insert: true); await model.draftWrites.recoveries[view.id]?.value
            XCTAssertEqual(view.draft, "After failure\n\n" + intent.text, kind)
            try await wire.host.shutdownAndWait()
        }
    }

    func testCapturedInputSurvivesHydrationRefreshFlushAndRecoveryFailure() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let intent = CommandIntent(id: "captured", sessionID: view.id, turnID: "turn", text: "Captured input", state: "intent")
        view.draftVersion.preservingSubmission(intent); model.offerSubmissionRecovery(intent, in: view)
        view.selectionMetadataLoaded = false
        try await model.loadDraftBaseline(view)
        XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent])
        view.draft = "Later typing"; model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value
        XCTAssertTrue(view.draftConflicts.isEmpty)
        let reconciled = try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true })
        XCTAssertTrue(reconciled); XCTAssertEqual(view.recovered, [intent], "An empty durable inventory cannot hide pinned input")
        XCTAssertFalse(view.uncertain, "Input that could not be persisted was never dispatched")
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_input BEFORE INSERT ON records WHEN NEW.kind LIKE 'pending:%' BEGIN SELECT RAISE(ABORT, 'generated flush failure'); END", root: model.root)
        do { try await model.flushDrafts(); XCTFail("Quit/update must not release undurable input") } catch {}
        XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent]); XCTAssertEqual(view.recovered, [intent])
        try RecoveredDraftTests.sql("DROP TRIGGER fail_input", root: model.root)
        try await model.flushDrafts()
        XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
        let durable = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertEqual(durable, [intent]); XCTAssertEqual(view.recovered, [intent])
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_withdrawal BEFORE DELETE ON records WHEN OLD.kind LIKE 'pending:%' BEGIN SELECT RAISE(ABORT, 'generated recovery failure'); END", root: model.root)
        for insert in [true, false] {
            model.recoverDraft(intent, insert: insert); await model.draftWrites.recoveries[view.id]?.value
            XCTAssertEqual(view.draft, "Later typing"); XCTAssertEqual(view.recovered, [intent])
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertEqual(pending, [intent])
        }
        try RecoveredDraftTests.sql("DROP TRIGGER fail_withdrawal", root: model.root)
        model.recoverDraft(intent, insert: true); await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, "Later typing\n\n" + intent.text)
        try await wire.host.shutdownAndWait()
    }

    func testSideTransferCannotOrphanInputCapturedBeforeItsKeepIntentCouldBeSaved() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Captured before side storage failed"
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_keep BEFORE INSERT ON records WHEN NEW.kind='side-keep' BEGIN SELECT RAISE(ABORT, 'generated keep failure'); END", root: model.root)
        model.send(sessionID: view.id)
        try await eventually("Side first send refused") { !view.loading && model.toolOutputProducers.isEmpty }
        let intent = try XCTUnwrap(view.recovered.first)
        view.draft = "Newer side text"
        try RecoveredDraftTests.sql("DROP TRIGGER fail_keep", root: model.root)
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_transfer BEFORE INSERT ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'generated transfer failure'); END", root: model.root)
        do { try await model.moveSideDraft(side); XCTFail("A failed transfer must retain the source input") } catch {}
        XCTAssertTrue(view.draftVersion.unsavedSubmissions.contains { $0.id == intent.id })
        XCTAssertEqual(view.recovered, [intent])
        try RecoveredDraftTests.sql("DROP TRIGGER fail_transfer", root: model.root)
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
        XCTAssertNil(keep)
        try await model.moveSideDraft(side); try await model.flushDrafts()
        let saved = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
        XCTAssertEqual(saved.map(\.text), [intent.text])
        XCTAssertEqual(parent.recovered.map(\.text), [intent.text])
        try await wire.host.shutdownAndWait()
    }

    func testTransactionStartFailurePinsEveryCapturedSubmission() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            try await failedCapture(method, kind: "begin", busy: true)
        }
    }

    func testUnavailableMetadataPinsEveryCapturedSubmissionBeforeAnyWrite() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let view: SessionDisplay
            if method == "side" {
                model.openSide(parentID: parent.id)
                view = try XCTUnwrap(model.sides[parent.id].flatMap { model.displays[$0.id] }); view.snapshotInFlight = true
            } else { view = parent }
            view.draft = "Captured while storage unavailable"
            if method == "turn.edit" { view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "queue.edit.save" { view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"; view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "turn.steer" { view.runState = .running }
            await store.close()
            if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
            else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
            else { model.send(steer: method == "turn.steer", sessionID: view.id) }
            view.draft = "Newer typing"; model.draftChanged(view)
            try await eventually("Unavailable storage answered") { !view.loading && !view.queueEditResolving && model.toolOutputProducers.isEmpty }
            XCTAssertEqual(view.recovered.map(\.text), ["Captured while storage unavailable"], method)
            XCTAssertEqual(view.draftVersion.unsavedSubmissions.map(\.text), ["Captured while storage unavailable"], method)
            XCTAssertTrue(view.draftConflicts.isEmpty)
            try await wire.host.shutdownAndWait()
        }
    }

    func testAcceptedSubmissionBookkeepingFailuresNeverOfferDuplicateRecovery() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let view: SessionDisplay
            if method == "side" {
                model.openSide(parentID: parent.id)
                view = try XCTUnwrap(model.sides[parent.id].flatMap { model.displays[$0.id] }); view.snapshotInFlight = true
            } else { view = parent }
            view.draft = "Captured accepted input"
            if method == "turn.edit" { view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "queue.edit.save" { view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"; view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked") }
            if method == "turn.steer" { view.runState = .running }
            wire.heldMethod = method == "side" ? "turn.submit" : method
            if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
            else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
            else { model.send(steer: method == "turn.steer", sessionID: view.id) }
            try await eventually("Accepted input held") { wire.held != nil }
            view.draft = "Newer typing"; model.draftChanged(view)
            let event = method == "queue.edit.save" ? "DELETE" : "UPDATE"
            try RecoveredDraftTests.sql("CREATE TRIGGER fail_ack BEFORE \(event) ON records WHEN OLD.kind LIKE 'pending:%' BEGIN SELECT RAISE(ABORT, 'generated acknowledgement failure'); END", root: model.root)
            let before = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            let captured = try XCTUnwrap(before.first)
            wire.release()
            try await eventually("Accepted input settled") { !view.loading && !view.queueEditResolving && model.toolOutputProducers.isEmpty }
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertTrue(pending.contains { $0.id == captured.id }, method)
            XCTAssertTrue(view.acceptedCommands.contains(captured.id), method)
            XCTAssertFalse(view.recovered.contains { $0.id == captured.id }, method)
            XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty, method)
            XCTAssertTrue(view.draft.contains("Newer typing"), method)
            try RecoveredDraftTests.sql("DROP TRIGGER fail_ack", root: model.root)
            try await wire.host.shutdownAndWait()
        }
    }

    func testDefiniteRejectionRetiresVisibleRecoveryOnlyAfterItsDraftCommits() async throws {
        for method in ["turn.submit", "turn.edit"] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            view.draft = "Captured input"; wire.heldMethod = method
            if method == "turn.edit" {
                view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked")
                model.sendEdit(sessionID: view.id)
            } else { model.send(sessionID: view.id) }
            try await eventually("Delivery held") { wire.held != nil }
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            view.recovered = pending; view.pendingIntents = (view.pendingIntentRevision, pending)
            let revision = view.pendingIntentRevision
            wire.rejectedMethod = method; wire.release()
            try await eventually("Refusal settled") { !view.loading }
            XCTAssertTrue(view.recovered.isEmpty, "A successfully returned draft no longer needs a recovery action")
            XCTAssertGreaterThan(view.pendingIntentRevision, revision, "The old pending cache must not resurrect retired input")
            let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.text, "Captured input")
            try await wire.host.shutdownAndWait()
        }
    }

    func testConnectionRefusalDoesNotDropCapturedInputWhenMaterializationFails() async throws {
        try await failedCapture("connection-refused", kind: "chat")
    }

    private func failedCapture(_ method: String, kind: String, superseding: Bool = true, rollback: Bool = false, discard: Bool = false, busy: Bool = false) async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let view: SessionDisplay
        if method == "side" {
            model.openSide(parentID: parent.id)
            view = try XCTUnwrap(model.sides[parent.id].flatMap { model.displays[$0.id] })
            view.snapshotInFlight = true
        } else { view = parent }
        if method == "new-chat" || method == "connection-refused" { model.pendingChatIDs.insert(view.id) }
        if method == "connection-refused" { model.profiles = [] }
        let captured = "Captured \(method) at \(kind)"
        view.draft = captured
        if method == "turn.edit" {
            view.editingMessageID = "original"; view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked draft")
        } else if method == "queue.edit.save" {
            view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
            view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked draft")
        } else if method == "turn.steer" { view.runState = .running }
        // Ensure the send's emptied composer also owns a real draft write.
        if kind == "draft" { try await store.put(view.savedDraft, kind: "draft", id: view.id, draftVersion: view.draftVersion) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database); defer { sqlite3_close(db) }
        if busy { XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK) }
        else { XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_capture \(rollback ? "AFTER" : "BEFORE") INSERT ON records WHEN NEW.kind LIKE '\(kind)' BEGIN SELECT RAISE(\(rollback ? "ROLLBACK" : "ABORT"), 'generated capture failure'); END", nil, nil, nil), SQLITE_OK) }
        let gate = DraftBaselineGate(expectation(description: "Metadata held for \(method)/\(kind)"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
        else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
        else { model.send(steer: method == "turn.steer", sessionID: view.id) }
        try await Task.sleep(for: .milliseconds(30))
        view.draft = "Newer typing"; if superseding { model.draftChanged(view) }
        gate.resume.signal(); await blocker.value
        try await eventually("Failed capture settled", timeout: .seconds(30)) { !view.loading && !view.queueEditResolving && model.toolOutputProducers.isEmpty }
        XCTAssertFalse(wire.frames.contains { ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save"].contains($0["method"]?.string ?? "") }, "\(method)/\(kind) must not dispatch")
        let retained = view.draftVersion.unsavedSubmissions.map(\.text) + view.recovered.map(\.text)
        XCTAssertTrue(retained.contains(captured), "\(method)/\(kind) lost captured input or hid its recovery")
        XCTAssertTrue(view.draftVersion.unsavedSubmissions.contains { $0.text == captured }, "Failed persistence needs an eviction/collector pin")
        XCTAssertTrue(view.draftConflicts.isEmpty, "Storage failure must not invent a cross-instance conflict")
        if busy { XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK) }
        // Cancelling an editor and replacing all composer text must not consume
        // a different input already chosen by Save/Resend.
        if method == "turn.edit" { model.cancelEdit(sessionID: view.id) }
        if method == "queue.edit.save" {
            model.queueEditOperation = { _, _, _ in [:] }
            model.cancelQueuedEdit(sessionID: view.id)
            try await eventually("Queue edit cancelled") { view.queueEditingID == nil }
        }
        view.runState = .idle; view.draft = "After cancellation"; model.draftChanged(view)
        await model.draftWrites.tasks[view.id]?.value
        if view.draftVersion.hasUnsavedConflict {
            model.deleteChat(view.id)
            XCTAssertTrue(model.error?.contains("retained submission") == true, "Single-instance storage errors are not draft conflicts")
            XCTAssertTrue(model.displays[view.id] === view)
        }
        let intent = view.recovered.first { $0.text == captured }
        XCTAssertNotNil(intent, "\(method)/\(kind) must offer recovery without reopening")
        if !busy { XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_capture", nil, nil, nil), SQLITE_OK) }
        if let intent {
            if !discard {
                XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_recovery BEFORE INSERT ON records WHEN NEW.kind='draft' BEGIN SELECT RAISE(ABORT, 'generated recovery failure'); END", nil, nil, nil), SQLITE_OK)
                model.recoverDraft(intent, insert: true)
                await model.draftWrites.recoveries[view.id]?.value
                XCTAssertEqual(view.draft, "After cancellation")
                XCTAssertTrue(view.recovered.contains { $0.id == intent.id })
                XCTAssertTrue(view.draftVersion.unsavedSubmissions.contains { $0.id == intent.id })
                XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_recovery", nil, nil, nil), SQLITE_OK)
                try await store.preserveDraftConflicts(view.draftVersion)
                XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_retirement BEFORE DELETE ON records WHEN OLD.kind LIKE 'pending:%' BEGIN SELECT RAISE(ABORT, 'generated retirement failure'); END", nil, nil, nil), SQLITE_OK)
                for insert in [true, false] {
                    model.recoverDraft(intent, insert: insert)
                    await model.draftWrites.recoveries[view.id]?.value
                    XCTAssertEqual(view.draft, "After cancellation")
                    XCTAssertTrue(view.recovered.contains { $0.id == intent.id })
                    let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
                    XCTAssertTrue(pending.contains { $0.id == intent.id })
                }
                XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_retirement", nil, nil, nil), SQLITE_OK)
            }
            model.recoverDraft(intent, insert: !discard)
            await model.draftWrites.recoveries[view.id]?.value
            XCTAssertEqual(view.draft, discard ? "After cancellation" : "After cancellation\n\n" + captured)
            if !discard {
                let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
                XCTAssertEqual(saved?.text, view.draft)
            }
            XCTAssertFalse(view.recovered.contains { $0.id == intent.id })
            XCTAssertFalse(view.draftVersion.unsavedSubmissions.contains { $0.id == intent.id }, "Recovered pins must not reappear on flush")
            try await store.preserveDraftConflicts(view.draftVersion)
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertFalse(pending.contains { $0.id == intent.id })
        }
        try await wire.host.shutdownAndWait()
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
    var snapshotSequence = 0
    lazy var host = HostSupervisor(commandSender: { [weak self] frame in
        guard let self else { return }
        frames.append(frame)
        if frame["method"]?.string == heldMethod { held = frame } else { answer(frame) }
    })
    init(root: URL) { self.root = root }
    func release(holding method: String? = nil) { let frame = held; held = nil; heldMethod = method; if let frame { answer(frame) } }
    private func answer(_ frame: [String: WireValue]) {
        var result: [String: WireValue] = [:]
        if frame["method"]?.string == "session.snapshot" || frame["method"]?.string == "session.status" {
            result = ["seq": .number(Double(snapshotSequence)), "state": .string("running"), "queue": .array([]), "queueEditRevision": .number(0)]
        }
        if frame["method"]?.string == "side.open", rejectedMethod != "side.open", let id = frame["params"]?.object?["sideSessionId"]?.string {
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
