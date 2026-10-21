import XCTest
import SQLite3
import Darwin
@testable import PiApp

@MainActor final class SubmissionPersistenceTests: XCTestCase {
    func testFailedSideInsertCommitsAReachableParentDraftBeforeConsumingInput() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Captured side input before publication"
        wire.rejectedMethod = "side.open"
        model.send(sessionID: side.id)
        try await eventually("Side publication rejected") { !view.loading && !view.recovered.isEmpty }
        let input = try XCTUnwrap(view.recovered.first)
        view.draft = "New side typing"; parent.draft = "Parent typing"; model.draftChanged(parent)
        model.recoverDraft(input, insert: true)
        await model.draftWrites.recoveries[side.id]?.value
        let reopened = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        let saved = try await reopened.get(DraftRecord.self, kind: "draft", id: parent.id)
        let pending = try await reopened.list(CommandIntent.self, kind: "pending:" + side.id)
        XCTAssertEqual(saved?.text, "Parent typing\n\n" + input.text, "Insert must commit in the indexed parent, not an unlisted side draft")
        XCTAssertEqual(parent.draft, saved?.text)
        XCTAssertEqual(view.draft, "New side typing", "The unsaved side's independent typing stays in its own composer")
        XCTAssertTrue(pending.isEmpty, "Only the reachable parent commit permits consumption")
        let indexed = try await store.get(ChatRecord.self, kind: "chat", id: parent.id)
        XCTAssertNotNil(indexed)
        await reopened.close(); try await wire.host.shutdownAndWait()
    }

    func testEveryCapturedSubmissionIsHiddenFromAnotherLiveInstance() async throws {
        for method in ["turn.submit", "turn.steer", "turn.edit", "queue.edit.save", "side"] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            var view = parent
            if method == "side" {
                model.openSide(parentID: parent.id)
                view = try XCTUnwrap(model.displays[try XCTUnwrap(model.sides[parent.id]).id])
                view.snapshotInFlight = true
            }
            view.draft = "Live captured " + method
            if method == "turn.steer" { view.runState = .running }
            if method == "turn.edit" { view.editingMessageID = "original"; view.draftBeforeEdit = .init(id: view.id, text: "Parked") }
            if method == "queue.edit.save" { view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"; view.draftBeforeQueueEdit = .init(id: view.id, text: "Parked") }
            wire.heldMethod = method == "side" ? "turn.submit" : method
            if method == "turn.edit" { model.sendEdit(sessionID: view.id) }
            else if method == "queue.edit.save" { model.saveQueuedEdit(sessionID: view.id) }
            else { model.send(steer: method == "turn.steer", sessionID: view.id) }
            try await eventually("Captured command awaiting dispatch reply") { wire.held != nil }
            let saved = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            let input = try XCTUnwrap(saved.first)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
            XCTAssertNotNil(encoded["submissionOwner"], "Every pending kind carries launch ownership: " + method)
            let other = makeWorkspaceModel(stateRoot: model.root), observer = SessionDisplay(id: view.id)
            other.prewarmsHelpers = false; other.chats = model.chats; other.displays[view.id] = observer
            observer.selectionMetadataLoaded = true
            other.commandAcceptanceRead = { _, _, _ in [] }
            other.queueEditOperation = { _, _, _ in ["state": .string("active")] }
            let item = try XCTUnwrap(model.record(view.id))
            let recovered = try await other.recoverableIntents(saved, for: item, view: observer)
            XCTAssertTrue(recovered.isEmpty, "A foreign live owner is not recovery: " + method)
            // An old chooser or a direct action must not bypass admission.
            for insert in [true, false] {
                observer.recovered = [input]
                other.recoverDraft(input, insert: insert)
                await other.draftWrites.recoveries[view.id]?.value
                let stillSaved = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: input.id)
                XCTAssertNotNil(stillSaved, "Foreign Insert/Discard cannot consume live input: " + method)
                XCTAssertEqual(observer.draft, "")
            }
            wire.release()
            try await eventually("Submission settled") { view.submittingCommands.isEmpty }
            try await wire.host.shutdownAndWait()
        }
    }

    func testCrashedInputOwnerReleasesRecoveryWithoutNormalClose() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let owner = UUID(), url = model.sidePublicationLeaseURL(owner), ready = model.root.appendingPathComponent("input-lease-ready")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,pathlib,signal\nf=open(sys.argv[1],'a')\nfcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\npathlib.Path(sys.argv[2]).touch()\nsignal.pause()", url.path, ready.path]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        try await eventually("Child owns captured input") { FileManager.default.fileExists(atPath: ready.path) }
        let input = CommandIntent(id: "queued-input", sessionID: view.id, turnID: "queue-edit:edit", text: "Input from crashed owner", state: "intent", draftReviewTracked: true, queueEditID: "edit", submissionOwner: owner.uuidString)
        try await store.recordSubmission(input, draft: nil)
        model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated unavailable queue status") }
        model.commandAcceptanceRead = { _, _, _ in [] }
        let item = try XCTUnwrap(model.record(view.id))
        var recovered = try await model.recoverableIntents([input], for: item, view: view)
        XCTAssertTrue(recovered.isEmpty)
        kill(process.processIdentifier, SIGKILL)
        try await eventually("Owner crashed without shutdown or draft flush") { !process.isRunning }
        recovered = try await model.recoverableIntents([input], for: item, view: view)
        XCTAssertEqual(recovered, [input])
        model.recoverDraft(input, insert: true); await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, input.text)
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Do not unlink lease inodes")
        try await wire.host.shutdownAndWait()
    }

    func testRecoveryReadRevalidatesAnotherInstancesCommittedRetirement() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let input = CommandIntent(id: "retained", sessionID: view.id, turnID: "turn", text: "One retained input", state: "intent", draftReviewTracked: true)
        try await store.recordSubmission(input, draft: nil)
        let other = makeWorkspaceModel(stateRoot: model.root), observer = SessionDisplay(id: view.id)
        other.chats = model.chats; other.displays[view.id] = observer; observer.selectionMetadataLoaded = true
        var release: CheckedContinuation<Void, Never>?, held = false
        other.commandAcceptanceRead = { _, _, _ in
            if !held { held = true; await withCheckedContinuation { release = $0 } }
            return []
        }
        defer { release?.resume() }
        let read = Task { try await other.recoverableIntents([input], for: try XCTUnwrap(other.record(view.id)), view: observer) }
        try await eventually("Other instance reading acceptance") { release != nil }
        model.offerSubmissionRecovery(input, in: view)
        model.recoverDraft(input, insert: false); await model.draftWrites.recoveries[view.id]?.value
        release?.resume(); release = nil
        let recovered = try await read.value
        XCTAssertTrue(recovered.isEmpty, "A foreign commit invalidates recovery even without a local pending counter change")
        observer.recovered = [input]
        other.recoverDraft(input, insert: true); await other.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(observer.draft, "", "A stale foreign chooser cannot replay consumed input")
        try await wire.host.shutdownAndWait()
    }

    func testDismissingSidePublicationCannotOrphanIndependentInput() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("missing-side.jsonl").path
        try await store.put(SideKeepIntent(chat: child), kind: "side-keep", id: child.id)
        let input = CommandIntent(id: "retained", sessionID: child.id, turnID: "turn", text: "Input needing its parent link", state: "intent")
        try await store.recordSubmission(input, draft: nil)
        do { try await store.dismissSideKeep(child) } catch {}
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: child.id)
        XCTAssertNotNil(keep, "Dismissing a reminder is not discarding its independent input")
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + child.id, id: input.id)
        XCTAssertEqual(pending, input)
        try await wire.host.shutdownAndWait()
    }

    func testReplacementDisplayCannotRecoverItsLaunchesLiveSubmission() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.draft = "Still being delivered"; wire.heldMethod = "turn.submit"
        model.send(sessionID: view.id)
        try await eventually("Submission in flight") { wire.held != nil }
        let inputs = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        let replacement = SessionDisplay(id: view.id); replacement.selectionMetadataLoaded = true
        model.commandAcceptanceRead = { _, _, _ in [] }
        let recovered = try await model.recoverableIntents(inputs, for: try XCTUnwrap(model.record(view.id)), view: replacement)
        XCTAssertTrue(recovered.isEmpty, "A live task belongs to the launch, not a replaceable display")
        wire.release(); try await eventually("Submission settled") { !view.loading }
        try await wire.host.shutdownAndWait()
    }

    func testSnapshotInvalidatesForeignPendingRecordChanges() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let input = CommandIntent(id: "retained", sessionID: view.id, turnID: "turn", text: "Already recovered elsewhere", state: "intent", draftReviewTracked: true)
        try await store.recordSubmission(input, draft: nil)
        try await snapshot(model, view: view, wire: wire)
        XCTAssertEqual(view.recovered, [input])
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        try await other.withdrawSubmission(sessionID: view.id, commandID: input.id, draft: nil)
        try await snapshot(model, view: view, wire: wire)
        XCTAssertTrue(view.recovered.isEmpty, "Another connection's commit invalidates the cached inventory")
        await other.close(); try await wire.host.shutdownAndWait()
    }

    func testTransferredSideInputAdoptsTheRecoveringLaunch() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let owner = UUID(), url = model.sidePublicationLeaseURL(owner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { let lease = try WorkspaceLock(url: url); withExtendedLifetime(lease) {} }
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("missing-side.jsonl").path
        try await store.put(SideKeepIntent(chat: child, publicationOwner: owner.uuidString), kind: "side-keep", id: child.id)
        let input = CommandIntent(id: "retained", sessionID: child.id, turnID: "turn", text: "Input from dead side", state: "intent", submissionOwner: owner.uuidString)
        try await store.recordSubmission(input, draft: nil)
        await model.reconcileSideKeeps()
        XCTAssertEqual(parent.recoverableSubmissions.map(\.text), [input.text], "The reconciliation's own acquired lease must not hide its transferred input")
        let saved = try await store.get(CommandIntent.self, kind: "pending:" + parent.id, id: input.id)
        let moved = try XCTUnwrap(saved)
        XCTAssertNotEqual(moved.submissionOwner, owner.uuidString, "The recovering launch owns the moved input")
        try await wire.host.shutdownAndWait()
    }

    func testSideRecoveryCannotMoveInputOwnedByAnotherLiveLaunch() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let publisher = UUID(), owner = UUID()
        try FileManager.default.createDirectory(at: model.sidePublicationLeaseURL(owner).deletingLastPathComponent(), withIntermediateDirectories: true)
        let lease = try WorkspaceLock(url: model.sidePublicationLeaseURL(owner))
        defer { withExtendedLifetime(lease) {} }
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("missing-side.jsonl").path
        try await store.put(SideKeepIntent(chat: child, publicationOwner: publisher.uuidString), kind: "side-keep", id: child.id)
        let input = CommandIntent(id: "live", sessionID: child.id, turnID: "turn", text: "A different launch owns this input", state: "intent", submissionOwner: owner.uuidString)
        try await store.recordSubmission(input, draft: nil)
        await model.reconcileSideKeeps()
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: child.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + child.id, id: input.id)
        XCTAssertNotNil(keep); XCTAssertEqual(pending, input)
        XCTAssertTrue(parent.recovered.isEmpty)
        try await wire.host.shutdownAndWait()
    }

    func testQueuedRetryCannotReplaceAnotherLaunchesLiveInputOwnership() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = .init(id: view.id, text: "Parked"); view.draft = "Same captured rewrite"
        wire.heldMethod = "queue.edit.save"; model.saveQueuedEdit(sessionID: view.id)
        try await eventually("First queued Save held") { wire.held != nil }
        let before = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        let original = try XCTUnwrap(before.first)
        let other = makeWorkspaceModel(stateRoot: model.root), editor = SessionDisplay(id: view.id)
        other.chats = model.chats; other.displays[view.id] = editor; editor.selectionMetadataLoaded = true
        editor.queueEditingID = "queued"; editor.queueEditID = "edit"; editor.queueEditOriginal = "Original"
        editor.draftBeforeQueueEdit = .init(id: view.id, text: "Parked"); editor.draft = original.text
        editor.draftVersion = try await store.draftVersion(id: view.id)
        var oldRecovery = original; oldRecovery.submissionOwner = UUID().uuidString
        editor.recovered = [oldRecovery]
        var dispatched = false
        other.queueEditOperation = { _, _, _ in dispatched = true; throw HostError.rejected("session_missing", "Generated retired helper") }
        other.saveQueuedEdit(sessionID: view.id)
        try await eventually("Second Save settled") { !editor.queueEditResolving && editor.submittingCommands.isEmpty }
        let after = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: original.id)
        XCTAssertEqual(after?.submissionOwner, original.submissionOwner, "A stable queue command ID must not replace its live launch owner")
        XCTAssertFalse(dispatched); XCTAssertTrue(editor.recoverableSubmissions.isEmpty)
        XCTAssertEqual(editor.queueEditPendingOperation, "save", "Cancel must still reconcile the original Save")
        XCTAssertEqual(editor.queueEditSentDigest, QueuedEditDraft.digest(original.text))
        XCTAssertEqual(editor.draft, original.text)
        wire.release(); try await eventually("First Save settled") { !view.queueEditResolving }
        try await wire.host.shutdownAndWait()
    }

    func testLiveCompactionCannotAppearAsCapturedInputRecovery() async throws {
        let (model, view, wire) = try await fixture()
        wire.heldMethod = "context.compact"; model.action("context.compact", sessionID: view.id)
        try await eventually("Compaction reply held") { wire.held != nil }
        try await snapshot(model, view: view, wire: wire)
        XCTAssertTrue(view.recoverableSubmissions.isEmpty, "Control-command pending records also have a live task owner")
        wire.release(); try await wire.host.shutdownAndWait()
    }

    func testDismissCannotRetireAnotherLaunchesLivePublicationBeforeItsInputWrite() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("not-yet-published.jsonl").path
        let owner = try model.inputPublicationOwner()
        try await store.put(SideKeepIntent(chat: child, publicationOwner: owner), kind: "side-keep", id: child.id)
        // The other instance has an old reminder, but this launch has begun
        // a new publication whose input record has not reached SQLite yet.
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        do { try await other.dismissSideKeep(child) } catch {}
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: child.id)
        XCTAssertNotNil(keep, "Publication ownership is required even before any pending input row exists")
        await other.close(); try await wire.host.shutdownAndWait()
    }

    func testRecoveryHoldsForeignOwnershipAcrossItsStorageWait() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let owner = UUID(), url = model.sidePublicationLeaseURL(owner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = CommandIntent(id: "crashed", sessionID: view.id, turnID: "turn", text: "Recovered once", state: "intent", submissionOwner: owner.uuidString)
        try await store.recordSubmission(input, draft: nil); model.offerSubmissionRecovery(input, in: view)
        let gate = DraftBaselineGate(expectation(description: "Recovery storage held"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        model.recoverDraft(input, insert: true)
        let other = makeWorkspaceModel(stateRoot: model.root), observer = SessionDisplay(id: view.id)
        other.chats = model.chats; other.displays[view.id] = observer; observer.selectionMetadataLoaded = true
        other.commandAcceptanceRead = { _, _, _ in [] }
        let recovered = try await other.recoverableIntents([input], for: try XCTUnwrap(other.record(view.id)), view: observer)
        XCTAssertTrue(recovered.isEmpty, "The admitted recovery owns the input while storage waits")
        observer.recovered = [input]
        other.recoverDraft(input, insert: false); await other.draftWrites.recoveries[view.id]?.value
        let pending = try await other.store?.get(CommandIntent.self, kind: "pending:" + view.id, id: input.id)
        XCTAssertEqual(pending, input)
        gate.resume.signal(); await blocker.value
        await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, input.text)
        XCTAssertNoThrow(try WorkspaceLock(url: url), "Recovery releases its borrowed lease after commit")
        try await wire.host.shutdownAndWait()
    }

    func testRecoveryRechecksOwnershipReleasedDuringItsAcceptanceRead() async throws {
        for foreign in [false, true] {
            let (model, oldView, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let owner = foreign ? UUID().uuidString : try model.inputPublicationOwner()
            let url = model.sidePublicationLeaseURL(try XCTUnwrap(UUID(uuidString: owner)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lease: WorkspaceLock? = foreign ? try WorkspaceLock(url: url) : nil
            defer { withExtendedLifetime(lease) {} }
            let input = CommandIntent(id: "settling", sessionID: oldView.id, turnID: "turn", text: "Input returned while ownership was being checked", state: "intent", submissionOwner: owner)
            try await store.recordSubmission(input, draft: nil)
            let view = SessionDisplay(id: oldView.id); view.selectionMetadataLoaded = true
            model.displays[view.id] = view
            if !foreign { model.beginSubmission(input.id, in: oldView) }
            var release: CheckedContinuation<Void, Never>?, held = false
            model.commandAcceptanceRead = { _, _, _ in
                if !held { held = true; await withCheckedContinuation { release = $0 } }
                return []
            }
            defer { release?.resume() }
            let read = Task { try await model.recoverableIntents([input], for: try XCTUnwrap(model.record(view.id)), view: view) }
            try await eventually("Recovery held with live ownership") { release != nil }
            if foreign { lease = nil }
            else { model.finishSubmission(input.id, in: oldView); model.offerSubmissionRecovery(input, in: oldView) }
            release?.resume(); release = nil
            let recovered = try await read.value
            XCTAssertEqual(recovered, [input], "Eligibility must be sampled again even without a local display or pending-record change")
            try await wire.host.shutdownAndWait()
        }
    }

    func testQueuedSaveConfirmationSurvivesLaterReconciliationAwaits() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let intent = CommandIntent(id: "queue-edit:edit:digest", sessionID: view.id, turnID: "queue-edit:edit",
                                   text: "Confirmed queued rewrite", state: "intent", draftReviewTracked: true, queueEditID: "edit")
        try await store.recordSubmission(intent, draft: nil)
        model.queueEditOperation = { _, _, _ in ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(intent.text))] }
        var release: CheckedContinuation<Void, Never>?, held = false
        model.commandAcceptanceRead = { _, _, _ in
            if !held { held = true; await withCheckedContinuation { release = $0 } }
            return []
        }
        defer { release?.resume() }
        let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
        try await eventually("History acceptance read held after queue confirmation") { release != nil }
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertTrue(pending.isEmpty)
        try await snapshot(model, view: view, wire: wire)
        XCTAssertFalse(view.acceptedCommands.contains(intent.id), "Snapshots may prune an acknowledgement with no remaining owner")
        release?.resume(); release = nil
        _ = try await reconciliation.value
        XCTAssertTrue(view.recoverableSubmissions.isEmpty, "A later await cannot re-offer the confirmed queued rewrite")
        model.recoverDraft(intent, insert: true); await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, "", "Confirmed input has no recovery action")
        try await wire.host.shutdownAndWait()
    }

    func testReconciliationKeepsSubmissionsThatFailDuringAcceptanceRead() async throws {
        for side in [false, true] {
            let (model, view, wire) = try await fixture()
            if side {
                model.chats[0].parentSessionID = "parent"
                model.chats.append(ChatRecord(id: "parent", workspaceID: "w", title: "Parent", profileID: "p"))
                model.selectedID = "parent"
                _ = model.mountSide(try XCTUnwrap(model.record(view.id)), beside: "parent")
                view.draftReady = true
            }
            wire.heldMethod = "turn.submit"; view.draft = "Captured input awaiting its reply"
            model.send(sessionID: view.id)
            try await eventually("Submission reply held") { wire.held != nil }
            let captured = try XCTUnwrap(view.submittingCommands.first)
            view.draft = "Typing while the reply is pending"; model.draftChanged(view)
            var release: CheckedContinuation<Void, Never>?, held = false
            model.commandAcceptanceRead = { _, _, _ in
                if !held { held = true; await withCheckedContinuation { release = $0 } }
                return []
            }
            defer { release?.resume() }
            let item = try XCTUnwrap(model.record(view.id))
            let reconciliation = Task {
                if side { await model.loadSideDisplay(item, view: view) }
                else { _ = try await model.reconcileSubmissionDraft(item, view: view, current: { true }) }
            }
            try await eventually("Hydration acceptance read held") { release != nil }
            try await wire.host.shutdownAndWait()
            try await eventually("Submission failed while hydration was pending") { view.submittingCommands.isEmpty && !view.loading }
            XCTAssertTrue(view.recovered.contains { $0.id == captured })
            view.draft = "Newer typing after helper loss"; model.draftChanged(view)
            release?.resume(); release = nil
            try await reconciliation.value
            XCTAssertTrue(view.recoverableSubmissions.contains { $0.id == captured }, "Hydration must merge input returned during its await, including saved sides")
            if let intent = view.recoverableSubmissions.first(where: { $0.id == captured }) {
                model.recoverDraft(intent, insert: true); await model.draftWrites.recoveries[view.id]?.value
                XCTAssertEqual(view.draft, "Newer typing after helper loss\n\n" + intent.text)
            }
        }
    }

    func testReconciliationDoesNotReviveInputConsumedDuringItsRead() async throws {
        for insert in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let intent = CommandIntent(id: "returned", sessionID: view.id, turnID: "turn", text: "Previously failed input", state: "intent", draftReviewTracked: true)
            try await store.recordSubmission(intent, draft: nil); model.offerSubmissionRecovery(intent, in: view)
            var release: CheckedContinuation<Void, Never>?, held = false
            model.commandAcceptanceRead = { _, _, _ in
                if !held { held = true; await withCheckedContinuation { release = $0 } }
                return []
            }
            defer { release?.resume() }
            let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
            try await eventually("Acceptance held before recovery action") { release != nil }
            model.recoverDraft(intent, insert: insert); await model.draftWrites.recoveries[view.id]?.value
            XCTAssertTrue(view.recovered.isEmpty)
            release?.resume(); release = nil; _ = try await reconciliation.value
            XCTAssertTrue(view.recoverableSubmissions.isEmpty, "An old read cannot undo Insert or Discard")
            XCTAssertEqual(view.draft, insert ? intent.text : "")
            try await wire.host.shutdownAndWait()
        }
    }

    func testReconciliationIncludesInputAddedWhileItsInventoryIsPending() async throws {
        for persisted in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            var release: CheckedContinuation<Void, Never>?, held = false
            model.commandAcceptanceRead = { _, _, _ in
                if !held { held = true; await withCheckedContinuation { release = $0 } }
                return []
            }
            defer { release?.resume() }
            let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
            try await eventually("Empty recovery inventory held") { release != nil }
            let intent = CommandIntent(id: "added", sessionID: view.id, turnID: "turn", text: "Input returned during reconciliation", state: "intent", draftReviewTracked: true)
            view.draftVersion.preservingSubmission(intent)
            model.offerSubmissionRecovery(intent, in: view)
            if persisted { try await store.preserveDraftConflicts(view.draftVersion) }
            release?.resume(); release = nil; _ = try await reconciliation.value
            XCTAssertEqual(view.recoverableSubmissions, [intent], "A returned pin must survive whether or not its retry commits during the read")
            try await wire.host.shutdownAndWait()
        }
    }

    func testReconciliationDoesNotPublishAQueuedRetryThatBecameLive() async throws {
        let (model, view, wire) = try await fixture()
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked"); view.draft = "Captured rewrite"
        model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated lost reply") }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Original Save unanswered") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        let intent = try XCTUnwrap(view.recovered.first)
        var release: CheckedContinuation<Void, Never>?, held = false, releaseSave: CheckedContinuation<Void, Never>?
        model.commandAcceptanceRead = { _, _, _ in
            if !held { held = true; await withCheckedContinuation { release = $0 } }
            return []
        }
        defer { release?.resume(); releaseSave?.resume() }
        let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
        try await eventually("Recovery read held") { release != nil }
        model.queueEditOperation = { method, _, _ in
            if method == "queue.edit.save" { await withCheckedContinuation { releaseSave = $0 } }
            return ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(intent.text))]
        }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Identical retry held") { releaseSave != nil }
        release?.resume(); release = nil; _ = try await reconciliation.value
        XCTAssertTrue(view.recovered.isEmpty, "The published inventory must recheck who owns the input now")
        XCTAssertTrue(view.recoverableSubmissions.isEmpty)
        for insert in [false, true] { model.recoverDraft(intent, insert: insert) }
        XCTAssertNil(model.draftWrites.recoveries[view.id], "Neither stale recovery action may act on a live retry")
        releaseSave?.resume(); releaseSave = nil
        try await eventually("Retry accepted") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        XCTAssertTrue(view.recoverableSubmissions.isEmpty)
        try await wire.host.shutdownAndWait()
    }

    func testSnapshotRevalidatesItsConnectionAfterProtectingReturnedInput() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "turn", text: "Returned input", state: "intent")
        try await store.recordSubmission(intent, draft: nil)
        view.recovered = [intent]; view.draft = intent.text
        view.showSending(.init(id: intent.turnID, role: "user", text: intent.text))
        wire.receipts = [["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string("failed")]]
        var release: CheckedContinuation<Void, Never>?
        let predecessor = Task { await withCheckedContinuation { release = $0 } }
        model.draftWrites.tasks[view.id] = predecessor
        defer { release?.resume() }
        try await eventually("Predecessor held") { release != nil }
        view.snapshotInFlight = false; model.refresh(view.id)
        try await eventually("Receipt review waits for predecessor") { view.submissionReviews.contains(intent.id) }
        let replacement = SubmissionPersistenceHost(root: model.root)
        try await replacement.host.connect(cwd: model.root, state: model.root.appendingPathComponent("replacement-host"))
        model.hosts["w"] = replacement.host
        release?.resume(); release = nil
        try await eventually("Retired snapshot settled") { !view.snapshotInFlight }
        XCTAssertTrue(view.isSending(intent.turnID), "A retired snapshot must not update the replacement runtime's sending rows")
        XCTAssertEqual(view.intentReads, 0, "The first post-await connection check must precede any further settlement")
        try await wire.host.shutdownAndWait(); try await replacement.host.shutdownAndWait()
    }

    func testSnapshotReloadsRecoveryInventoryChangedDuringReviewPersistence() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let accepted = CommandIntent(id: "accepted", sessionID: view.id, turnID: "old", text: "Returned accepted input", state: "intent")
        let failed = CommandIntent(id: "failed", sessionID: view.id, turnID: "failed-turn", text: "Unaccepted input", state: "intent", draftReviewTracked: true)
        for intent in [accepted, failed] { try await store.recordSubmission(intent, draft: nil) }
        view.draft = accepted.text
        wire.receipts = [["commandId": .string(accepted.id), "turnId": .string(accepted.turnID), "state": .string("dispatched")]]
        var release: CheckedContinuation<Void, Never>?
        let predecessor = Task { await withCheckedContinuation { release = $0 } }
        model.draftWrites.tasks[view.id] = predecessor
        defer { release?.resume() }
        try await eventually("Predecessor held") { release != nil }
        view.snapshotInFlight = false; model.refresh(view.id)
        try await eventually("Pending inventory review held") { view.submissionReviews.contains(accepted.id) }
        XCTAssertEqual(view.intentReads, 1)
        let added = CommandIntent(id: "added", sessionID: view.id, turnID: "new", text: "Input retained during review", state: "intent", draftReviewTracked: true)
        view.draftVersion.preservingSubmission(added); model.offerSubmissionRecovery(added, in: view)
        try await store.preserveDraftConflicts(view.draftVersion)
        release?.resume(); release = nil
        try await eventually("Snapshot settled after inventory change") { !view.snapshotInFlight }
        XCTAssertEqual(Set(view.recoverableSubmissions.map(\.id)), [failed.id, added.id], "This reconciliation must reload, rather than rely on a later snapshot")
        XCTAssertEqual(view.intentReads, 2)
        try await wire.host.shutdownAndWait()
    }

    func testReconciliationCannotReviveInputRetiredByAnInterveningReceipt() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let intent = CommandIntent(id: "completed", sessionID: view.id, turnID: "turn", text: "Already delivered input", state: "intent", draftReviewTracked: true)
        try await store.recordSubmission(intent, draft: nil)
        var release: CheckedContinuation<Void, Never>?, held = false
        model.commandAcceptanceRead = { _, _, _ in
            if !held { held = true; await withCheckedContinuation { release = $0 } }
            return []
        }
        defer { release?.resume() }
        let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
        try await eventually("Earlier acceptance read held") { release != nil }
        wire.receipts = [["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string("completed")]]
        try await snapshot(model, view: view, wire: wire)
        wire.receipts = []
        try await snapshot(model, view: view, wire: wire)
        XCTAssertFalse(view.acceptedCommands.contains(intent.id))
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertTrue(pending.isEmpty)
        release?.resume(); release = nil; _ = try await reconciliation.value
        XCTAssertTrue(view.recoverableSubmissions.isEmpty, "Receipt retirement must invalidate every older recovery inventory, even without a pin")
        try await wire.host.shutdownAndWait()
    }

    func testRecoveryRechecksInputAcrossQueueStatusAndReviewWaits() async throws {
        for wait in ["queue", "review"] {
            for persisted in [false, true] {
                let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
                let earlier = CommandIntent(id: "earlier", sessionID: view.id, turnID: "earlier-turn", text: "Earlier input", state: "intent",
                                            queueEditID: wait == "queue" ? "edit" : nil)
                try await store.recordSubmission(earlier, draft: nil)
                view.draft = "Current typing"
                var release: CheckedContinuation<Void, Never>?, held = false
                model.commandAcceptanceRead = { _, _, _ in wait == "review" ? [earlier.id] : [] }
                if wait == "queue" {
                    model.queueEditOperation = { _, _, _ in
                        if !held { held = true; await withCheckedContinuation { release = $0 } }
                        return ["state": .string("active")]
                    }
                } else {
                    model.draftWrites.tasks[view.id] = Task { await withCheckedContinuation { release = $0 } }
                }
                defer { release?.resume() }
                let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true }) }
                try await eventually("Recovery \(wait) held") {
                    release != nil && (wait == "queue" || view.submissionReviews.contains(earlier.id))
                }
                let added = CommandIntent(id: "added", sessionID: view.id, turnID: "added-turn", text: "Late failed input", state: "intent", draftReviewTracked: true)
                view.draftVersion.preservingSubmission(added); model.offerSubmissionRecovery(added, in: view)
                if persisted { try await store.preserveDraftConflicts(view.draftVersion) }
                release?.resume(); release = nil; _ = try await reconciliation.value
                XCTAssertEqual(Set(view.recoverableSubmissions.map(\.id)), wait == "queue" ? [earlier.id, added.id] : [added.id],
                               "Every acceptance/review await must revalidate its input inventory")
                try await wire.host.shutdownAndWait()
            }
        }
    }

    func testCancelledRecoveryKeepsPositiveAcceptanceEvidence() async throws {
        for source in ["queue", "journal"] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "turn", text: "Already accepted input", state: "intent",
                                       draftReviewTracked: true, queueEditID: source == "queue" ? "edit" : nil)
            try await store.recordSubmission(intent, draft: nil)
            var release: CheckedContinuation<Void, Never>?, current = true
            model.queueEditOperation = { _, _, _ in
                await withCheckedContinuation { release = $0 }
                return ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(intent.text))]
            }
            model.commandAcceptanceRead = { _, _, _ in
                if source == "journal" { await withCheckedContinuation { release = $0 } }
                return source == "journal" ? [intent.id] : []
            }
            defer { release?.resume() }
            let reconciliation = Task { try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { current }) }
            try await eventually("Positive evidence held before navigation retires the read") { release != nil }
            current = false; reconciliation.cancel()
            release?.resume(); release = nil
            _ = try await reconciliation.value
            XCTAssertTrue(view.acceptedCommands.contains(intent.id), "Leaving the pane cannot discard positive command-specific evidence")
            XCTAssertTrue(view.recoverableSubmissions.isEmpty)
            if source == "queue" {
                let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
                XCTAssertTrue(pending.isEmpty, "The confirmed queued input must retire even if its reader has moved on")
            }
            try await wire.host.shutdownAndWait()
        }
    }

    func testFailedQueuedSaveRetryKeepsTheEarlierOutcomeForCancelAndChangedSave() async throws {
        for changedSave in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let text = "Saved rewrite with an unanswered reply", digest = QueuedEditDraft.digest(text)
            view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
            view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked"); view.draft = text
            model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated lost reply") }
            model.saveQueuedEdit(sessionID: view.id)
            try await eventually("First Save unanswered") { !view.queueEditResolving && view.submittingCommands.isEmpty }
            try RecoveredDraftTests.sql("CREATE TRIGGER fail_retry BEFORE INSERT ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'generated retry failure'); END", root: model.root)
            model.saveQueuedEdit(sessionID: view.id)
            try await eventually("Retry persistence failed") { !view.queueEditResolving && view.submittingCommands.isEmpty }
            XCTAssertEqual(view.queueEditPendingOperation, "save", "Local failure cannot settle the original helper request")
            XCTAssertEqual(view.queueEditSentDigest, digest)
            await model.draftWrites.tasks[view.id]?.value
            let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.queuedEdit?.pending, "save")
            XCTAssertEqual(saved?.queuedEdit?.sentDigest, digest, "Relaunch must also reconcile the original digest")
            try RecoveredDraftTests.sql("DROP TRIGGER fail_retry", root: model.root)
            var methods: [String] = []
            model.queueEditOperation = { method, _, _ in
                methods.append(method)
                guard method == "queue.edit.status" else { throw HostError.rejected("queue_edit_saved", "Already saved") }
                return ["state": .string("saved"), "textDigest": .string(digest)]
            }
            if changedSave { view.draft = "Newer typing"; model.saveQueuedEdit(sessionID: view.id) }
            else { model.cancelQueuedEdit(sessionID: view.id) }
            try await eventually("Earlier Save reconciled") { view.queueEditID == nil }
            XCTAssertEqual(methods, ["queue.edit.status"], "A different operation cannot cross an unanswered Save")
            XCTAssertEqual(view.draft, changedSave ? "Newer typing\n\nParked" : "Parked")
            XCTAssertTrue(view.recoverableSubmissions.isEmpty, "Confirmed input must not be returned as unsent")
            try await wire.host.shutdownAndWait()
        }
    }

    func testLocalSidePublicationCanRetryRegistrationWithoutDroppingItsNotice() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let info = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[info.id])
        view.snapshotInFlight = true; view.draft = "First side input"
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_registration BEFORE INSERT ON records WHEN NEW.kind='chat' AND NEW.id<>'chat' BEGIN SELECT RAISE(ABORT, 'generated registration failure'); END", root: model.root)
        model.send(sessionID: info.id)
        try await eventually("Local publication failed registration") { !view.loading && view.submittingCommands.isEmpty }
        let stored = try await store.get(SideKeepIntent.self, kind: "side-keep", id: info.id)
        let intent = try XCTUnwrap(stored)
        XCTAssertEqual(intent.publicationOwner, model.sidePublicationOwnership?.id.uuidString)
        await model.applySideStatus(id: info.id, result: ["ephemeral": .bool(false), "path": .string(try XCTUnwrap(intent.chat.path))])
        XCTAssertEqual(model.sideKeepIssues.map(\.id), [info.id])
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.sideKeepIssues.map(\.id), [info.id], "Failed Retry must leave its actionable notice")
        try RecoveredDraftTests.sql("DROP TRIGGER fail_registration", root: model.root)
        await model.reconcileSideKeeps()
        let saved = try await store.get(ChatRecord.self, kind: "chat", id: info.id)
        let pending = try await store.get(SideKeepIntent.self, kind: "side-keep", id: info.id)
        XCTAssertNotNil(saved, "The publication owner must be able to retry its own settled failure")
        XCTAssertNil(pending); XCTAssertTrue(model.sideKeepIssues.isEmpty)
        XCTAssertTrue(model.sides[parent.id]?.kept == true)
        try await wire.host.shutdownAndWait()
    }

    func testRefusedQueuedSaveRetryDoesNotSettleTheEarlierUnknownOutcome() async throws {
        let (model, view, wire) = try await fixture()
        let text = "Earlier Save", digest = QueuedEditDraft.digest(text)
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked"); view.draft = text
        model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated lost reply") }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("First Save unanswered") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        model.queueEditOperation = { _, _, _ in throw HostError.rejected("session_missing", "Generated replacement runtime") }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Retry refused") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        XCTAssertEqual(view.queueEditPendingOperation, "save", "Refusing this retry cannot determine what the earlier runtime saved")
        XCTAssertEqual(view.queueEditSentDigest, digest)
        var methods: [String] = []
        model.queueEditOperation = { method, _, _ in
            methods.append(method)
            return ["state": .string("saved"), "textDigest": .string(digest)]
        }
        model.cancelQueuedEdit(sessionID: view.id)
        try await eventually("Original outcome checked") { view.queueEditID == nil }
        XCTAssertEqual(methods, ["queue.edit.status"])
        XCTAssertTrue(view.recoverableSubmissions.isEmpty)
        XCTAssertEqual(view.draft, "Parked")
        try await wire.host.shutdownAndWait()
    }

    func testInitialQueuedSaveStorageFailureDoesNotInventAnUnansweredRequest() async throws {
        let (model, view, wire) = try await fixture()
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked"); view.draft = "Unsent rewrite"
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_save BEFORE INSERT ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'generated first Save failure'); END", root: model.root)
        model.queueEditOperation = { _, _, _ in XCTFail("Failed local persistence cannot dispatch"); return [:] }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("First Save failed locally") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        XCTAssertNil(view.queueEditPendingOperation); XCTAssertNil(view.queueEditSentDigest)
        XCTAssertEqual(view.recoverableSubmissions.map(\.text), ["Unsent rewrite"])
        try RecoveredDraftTests.sql("DROP TRIGGER fail_save", root: model.root)
        model.queueEditOperation = { method, _, _ in XCTAssertEqual(method, "queue.edit.cancel"); return [:] }
        model.cancelQueuedEdit(sessionID: view.id)
        try await eventually("Cancel completed") { view.queueEditID == nil }
        XCTAssertEqual(view.draft, "Parked")
        XCTAssertEqual(view.recoverableSubmissions.map(\.text), ["Unsent rewrite"])
        try await wire.host.shutdownAndWait()
    }

    func testOwnLivePublicationIsNotReconciledByAnyPublicationRoute() async throws {
        for method in ["side.open", "side.keep", "side.close", "session.fork"] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            wire.heldMethod = method
            var fork: Task<ChatRecord, Error>?
            if method == "session.fork" { fork = Task { try await model.createFork(parentID: parent.id) } }
            else {
                model.openSide(parentID: parent.id)
                let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
                view.snapshotInFlight = true
                if method == "side.open" { view.draft = "Live first input"; model.send(sessionID: side.id) }
                else {
                    model.sides[parent.id]?.pending = false
                    if method == "side.keep" { model.keepSide(side.id) } else { model.closeSide(side.id) }
                }
            }
            try await eventually("Publication reply held") { wire.held != nil }
            let intents = try await store.list(SideKeepIntent.self, kind: "side-keep")
            let intent = try XCTUnwrap(intents.first)
            XCTAssertEqual(model.sidePublications, [intent.chat.id])
            // The file may already exist before the helper's reply. Neither
            // that fact nor an earlier Retry notice retires live publication.
            let path = URL(fileURLWithPath: try XCTUnwrap(intent.chat.path))
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SideKeepRecoveryTests.journal(id: intent.chat.id).write(to: path)
            await model.reportSideKeepFailure(id: intent.chat.id, title: intent.chat.title, error: StoreError.unavailable)
            let issue = try XCTUnwrap(model.sideKeepIssues.first)
            await model.reconcileSideKeeps()
            let registered = try await store.get(ChatRecord.self, kind: "chat", id: intent.chat.id)
            XCTAssertNil(registered, "Local reconciliation must not overtake \(method)")
            XCTAssertEqual(model.sideKeepIssues, [issue], "Waiting for the owner does not settle an existing notice")
            XCTAssertTrue(parent.recoverableSubmissions.isEmpty)
            wire.release()
            if let fork { _ = try await fork.value }
            try await eventually("Publication settled") { model.sidePublications.isEmpty && model.displays[intent.chat.id]?.loading != true }
            XCTAssertNotNil(model.chats.first { $0.id == intent.chat.id }); XCTAssertTrue(model.sideKeepIssues.isEmpty)
            try await wire.host.shutdownAndWait()
        }
    }

    func testDeferredLocalKeepWaitsForTheHelpersPublication() async throws {
        for keeping in [false, true] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let owner = UUID(), url = model.sidePublicationLeaseURL(owner)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            model.sidePublicationOwnership = (owner, try WorkspaceLock(url: url))
            var side = SideRecord(id: "side", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Deferred Keep")
            side.keeping = keeping; side.keepRequested = !keeping
            model.sides[parent.id] = side
            let view = SessionDisplay(id: side.id); view.selectionMetadataLoaded = true; model.displays[side.id] = view
            var chat = side.chat; chat.path = model.root.appendingPathComponent("side_deferred.jsonl").path
            try await store.put(SideKeepIntent(chat: chat, publicationOwner: owner.uuidString), kind: "side-keep", id: side.id)
            await model.reconcileSideKeeps()
            XCTAssertTrue(model.sideKeepIssues.isEmpty, "A Keep still held by the helper must not offer recovery")
            let pending = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
            XCTAssertNotNil(pending)
            try SideKeepRecoveryTests.journal(id: side.id).write(to: URL(fileURLWithPath: try XCTUnwrap(chat.path)))
            await model.applySideStatus(id: side.id, result: ["ephemeral": .bool(false), "keeping": .bool(false), "keepRequested": .bool(false), "path": .string(chat.path!)])
            XCTAssertTrue(model.sides[parent.id]?.kept == true); XCTAssertTrue(model.sideKeepIssues.isEmpty)
            try await wire.host.shutdownAndWait()
        }
    }

    func testLostHelperReleasesDeferredKeepOwnershipEvenWhenInputPinsItsDisplay() async throws {
        for keeping in [false, true] {
            let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let owner = UUID(), url = model.sidePublicationLeaseURL(owner)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            model.sidePublicationOwnership = (owner, try WorkspaceLock(url: url))
            var side = SideRecord(id: "side", parentID: parent.id, workspaceID: "w", profileID: "p", title: "Interrupted Keep")
            side.keeping = keeping; side.keepRequested = !keeping
            model.sides[parent.id] = side
            let view = SessionDisplay(id: side.id); view.selectionMetadataLoaded = true; model.displays[side.id] = view
            let input = CommandIntent(id: "retained", sessionID: side.id, turnID: "turn", text: "Pinned input", state: "intent")
            view.draftVersion.preservingSubmission(input)
            var chat = side.chat; chat.path = model.root.appendingPathComponent("side_interrupted.jsonl").path
            try SideKeepRecoveryTests.journal(id: side.id).write(to: URL(fileURLWithPath: chat.path!))
            try await store.put(SideKeepIntent(chat: chat, publicationOwner: owner.uuidString), kind: "side-keep", id: side.id)
            try await wire.host.shutdownAndWait()
            model.discardLostSides(workspaceID: "w")
            XCTAssertTrue(model.displays[side.id] === view, "Pinned input still owns its display")
            XCTAssertFalse(model.sides[parent.id]?.keeping == true)
            XCTAssertFalse(model.sides[parent.id]?.keepRequested == true, "A retired helper cannot keep owning publication")
            await model.reconcileSideKeeps()
            let saved = try await store.get(ChatRecord.self, kind: "chat", id: side.id)
            XCTAssertNotNil(saved, "The surviving journal can register without restarting the dead helper")
            let durable = try await store.list(CommandIntent.self, kind: "pending:" + side.id)
            XCTAssertTrue((durable + view.draftVersion.unsavedSubmissions).contains { $0.id == input.id })
        }
    }

    func testEarlierQueuedSaveConfirmationRetiresItsCapturedInput() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked")
        view.draft = "First saved rewrite"
        model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated lost reply") }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("First Save unanswered") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        XCTAssertEqual(view.queueEditPendingOperation, "save")
        let captured = try XCTUnwrap(view.recovered.first)
        view.draft = "Newer typing"
        model.queueEditOperation = { method, _, _ in
            XCTAssertEqual(method, "queue.edit.status")
            return ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(captured.text))]
        }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Earlier Save confirmed") { view.queueEditID == nil }
        await model.draftWrites.tasks[view.id]?.value
        try await snapshot(model, view: view, wire: wire)
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertTrue(pending.isEmpty, "The earlier operation's completion must retire its independent input")
        XCTAssertTrue(view.recovered.isEmpty, "A confirmed queued Save cannot be offered again")
        XCTAssertEqual(view.draft, "Newer typing\n\nParked")
        try await wire.host.shutdownAndWait()
    }

    func testConfirmedQueuedSaveRetiresAPinLeftByFailedRetryPersistence() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        view.queueEditingID = "queued"; view.queueEditID = "edit"; view.queueEditOriginal = "Original"
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked")
        view.draft = "Saved rewrite with a lost reply"
        model.queueEditOperation = { _, _, _ in throw HostError.failure("Generated lost reply") }
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("First Save unanswered") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        let captured = try XCTUnwrap(view.recovered.first)
        try RecoveredDraftTests.sql("CREATE TRIGGER fail_retry BEFORE INSERT ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'generated retry failure'); END", root: model.root)
        model.saveQueuedEdit(sessionID: view.id)
        try await eventually("Retry persistence failed") { !view.queueEditResolving && view.submittingCommands.isEmpty }
        XCTAssertEqual(view.draftVersion.unsavedSubmissions, [captured])
        try RecoveredDraftTests.sql("DROP TRIGGER fail_retry", root: model.root)
        model.queueEditOperation = { _, _, _ in ["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest(captured.text))] }
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        view.recovered = try await model.recoverableIntents(pending, for: try XCTUnwrap(model.record(view.id)), view: view)
        XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty, "Confirmation consumes both the durable record and its retry pin")
        try await snapshot(model, view: view, wire: wire)
        XCTAssertTrue(view.recovered.isEmpty, "An empty durable inventory must not revive the accepted pin")
        try await model.flushDrafts()
        let remaining = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
        XCTAssertTrue(remaining.isEmpty, "Flush must not recreate confirmed input")
        try await wire.host.shutdownAndWait()
    }

    func testAnotherInstanceCannotRecoverALiveSidePublication() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.opened.remove(parent.id); wire.heldMethod = "session.open"
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        view.snapshotInFlight = true; view.draft = "Live first side input"
        model.send(sessionID: side.id)
        try await eventually("Parent opening held") { wire.held != nil }
        let observer = makeWorkspaceModel(stateRoot: model.root, vault: model.vault)
        observer.prewarmsHelpers = false; observer.chats = model.chats
        let otherParent = SessionDisplay(id: parent.id); otherParent.selectionMetadataLoaded = true
        observer.displays[parent.id] = otherParent
        await observer.reconcileSideKeeps()
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
        let inputs = try await store.list(CommandIntent.self, kind: "pending:" + parent.id)
        XCTAssertNotNil(keep, "A different instance's missing display is not abandonment")
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(otherParent.recovered.isEmpty)
        XCTAssertTrue(observer.sideKeepIssues.isEmpty, "A live publication must not offer retirement actions")
        wire.release()
        try await eventually("Owner finishes publication") { !view.loading && view.submittingCommands.isEmpty }
        XCTAssertNotNil(model.chats.first { $0.id == side.id }, "The owner's registration intent must survive")
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.count, 1)
        try await wire.host.shutdownAndWait()
    }

    func testJournalAndTerminalReceiptSettlementRetireRetryPins() async throws {
        for evidence in ["journal", "dispatched", "completed"] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "turn", text: "Already delivered", state: "intent", draftReviewTracked: true)
            try await store.recordSubmission(intent, draft: nil)
            view.draftVersion.preservingSubmission(intent)
            if evidence == "journal" {
                model.commandAcceptanceRead = { _, _, _ in [intent.id] }
                view.recovered = try await model.recoverableIntents([intent], for: try XCTUnwrap(model.record(view.id)), view: view)
            } else {
                wire.receipts = [["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string(evidence)]]
                try await snapshot(model, view: view, wire: wire)
            }
            XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty, "Durable helper evidence must retire the retry pin")
            try await snapshot(model, view: view, wire: wire)
            XCTAssertTrue(view.recovered.isEmpty)
            try await model.flushDrafts()
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertFalse(pending.contains { $0.state == "intent" }, "Flush cannot recreate input proven accepted")
            try await wire.host.shutdownAndWait()
        }
    }

    func testQueuedSaveConfirmationSurvivesFailedCleanupAndHydratedEditorSettlement() async throws {
        for failure in [false, true] {
            let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
            let text = "Confirmed queued input", digest = QueuedEditDraft.digest(text)
            let intent = CommandIntent(id: "queue-edit:edit:" + digest, sessionID: view.id, turnID: "queue-edit:edit", text: text, state: "intent", draftReviewTracked: true, queueEditID: "edit")
            view.draftVersion.preservingSubmission(intent); view.recovered = [intent]
            let record = QueuedEditDraft(editID: "edit", turnID: "queued", rewrite: "Later typing", original: "Original", pending: "save", sent: text)
            model.queueEditOperation = { _, _, _ in ["state": .string("saved"), "textDigest": .string(digest)] }
            if failure { try RecoveredDraftTests.sql("CREATE TRIGGER fail_cleanup BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT, 'generated cleanup failure'); END", root: model.root) }
            // Include a durable row so the DELETE failure runs its trigger.
            try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
            await model.reconcileQueuedEdit(view, record)
            XCTAssertTrue(view.recovered.isEmpty)
            XCTAssertTrue(view.draft.contains("Later typing"))
            try await snapshot(model, view: view, wire: wire)
            XCTAssertTrue(view.recovered.isEmpty, "Failed cleanup cannot undo helper confirmation")
            if failure {
                XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent], "A failed transaction retains its owner")
                try RecoveredDraftTests.sql("DROP TRIGGER fail_cleanup", root: model.root)
                _ = try await model.recoverableIntents([intent], for: try XCTUnwrap(model.record(view.id)), view: view)
            }
            XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
            try await model.flushDrafts()
            let pending = try await store.list(CommandIntent.self, kind: "pending:" + view.id)
            XCTAssertTrue(pending.isEmpty)
            try await wire.host.shutdownAndWait()
        }
    }

    func testConfirmedInputWithoutADurableRowStaysSuppressedUntilCleanupRetries() async throws {
        let (model, view, wire) = try await fixture()
        let intent = CommandIntent(id: "queue-edit:edit:digest", sessionID: view.id, turnID: "queue-edit:edit", text: "Confirmed input", state: "intent", queueEditID: "edit")
        view.draftVersion.preservingSubmission(intent); view.recovered = [intent]
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do { try await model.retireConfirmedSubmission(intent.id, in: view); XCTFail("Generated storage contention must fail cleanup") }
        catch {}
        XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent])
        try await snapshot(model, view: view, wire: wire)
        XCTAssertTrue(view.acceptedCommands.contains(intent.id), "A pin still owns the acknowledgement when no durable row exists")
        XCTAssertTrue(view.recovered.isEmpty)
        model.queueEditOperation = { _, _, _ in XCTFail("Known acceptance needs no new helper call"); return [:] }
        _ = try await model.recoverableIntents([], for: try XCTUnwrap(model.record(view.id)), view: view)
        XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
        try await wire.host.shutdownAndWait()
    }

    func testAcknowledgementReleasesPinsOnlyAfterItsCommit() async throws {
        for hasRecord in [false, true] {
            for rollback in [false, true] {
                let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
                let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "turn", text: "Confirmed input", state: "intent")
                if hasRecord { try await store.recordSubmission(intent, draft: nil) }
                view.draftVersion.preservingSubmission(intent)
                let event = rollback && hasRecord ? "UPDATE" : "INSERT"
                try RecoveredDraftTests.sql("CREATE TRIGGER fail_ack \(rollback ? "AFTER" : "BEFORE") \(event) ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(\(rollback ? "ROLLBACK" : "ABORT"), 'generated acknowledgement failure'); END", root: model.root)
                do { try await store.acknowledgeCommand(sessionID: view.id, commandID: intent.id, draftVersion: view.draftVersion); XCTFail("Generated acknowledgement failure") }
                catch {}
                XCTAssertEqual(view.draftVersion.unsavedSubmissions, [intent])
                let unchanged = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
                XCTAssertEqual(unchanged?.state, hasRecord ? "intent" : nil)
                try RecoveredDraftTests.sql("DROP TRIGGER fail_ack", root: model.root)
                try await store.acknowledgeCommand(sessionID: view.id, commandID: intent.id, draftVersion: view.draftVersion)
                XCTAssertTrue(view.draftVersion.unsavedSubmissions.isEmpty)
                let saved = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
                XCTAssertEqual(saved?.state, "acknowledged")
                try await wire.host.shutdownAndWait()
            }
        }
    }

    func testAcknowledgementSurvivesALiveTaskAfterItsInputWasRetired() async throws {
        let (model, view, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "queue-edit:edit", text: "Already saved", state: "intent", queueEditID: "edit")
        view.submittingCommands.insert(intent.id)
        try await store.recordSubmission(intent, draft: nil, draftVersion: view.draftVersion)
        try await model.retireConfirmedSubmission(intent.id, in: view)
        try await snapshot(model, view: view, wire: wire)
        XCTAssertTrue(view.acceptedCommands.contains(intent.id), "The live task still owns its acknowledgement after durable cleanup")
        // Match the queued Save task's exit, after storage and any snapshot.
        model.finishSubmission(intent.id, in: view)
        if !view.acceptedCommands.contains(intent.id) { model.offerSubmissionRecovery(intent, in: view) }
        XCTAssertTrue(view.recovered.isEmpty, "Successful cleanup cannot become failed-input recovery as the task returns")
        try await wire.host.shutdownAndWait()
    }

    func testCrashedPublicationOwnerReleasesItsLeaseForParentRecovery() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let owner = UUID(), url = model.sidePublicationLeaseURL(owner), ready = model.root.appendingPathComponent("lease-ready")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,pathlib,signal\nf=open(sys.argv[1],'a')\nfcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\npathlib.Path(sys.argv[2]).touch()\nsignal.pause()", url.path, ready.path]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        try await eventually("Child owns publication lease") { FileManager.default.fileExists(atPath: ready.path) }
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("missing-side.jsonl").path
        try await store.put(SideKeepIntent(chat: child, publicationOwner: owner.uuidString), kind: "side-keep", id: child.id)
        let intent = CommandIntent(id: "input", sessionID: child.id, turnID: "turn", text: "Captured before crash", state: "intent")
        try await store.recordSubmission(intent, draft: nil)
        await model.reconcileSideKeeps()
        XCTAssertTrue(parent.recovered.isEmpty); XCTAssertTrue(model.sideKeepIssues.isEmpty)
        kill(process.processIdentifier, SIGKILL)
        try await eventually("Child exited") { !process.isRunning }
        await model.reconcileSideKeeps()
        XCTAssertEqual(parent.recovered.map(\.text), [intent.text], "The kernel releases a crashed owner's lease")
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: child.id)
        XCTAssertNil(keep); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Lease files must keep their inode")
        try await wire.host.shutdownAndWait()
    }

    func testLegacyMissingSideWithoutOwnershipEvidenceIsNotRetiredAutomatically() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        var child = try XCTUnwrap(model.record(parent.id)); child.id = "legacy-side"; child.parentSessionID = parent.id
        child.path = model.root.appendingPathComponent("missing-side.jsonl").path
        try await store.put(SideKeepIntent(chat: child), kind: "side-keep", id: child.id)
        let intent = CommandIntent(id: "input", sessionID: child.id, turnID: "turn", text: "Legacy retained input", state: "intent")
        try await store.recordSubmission(intent, draft: nil)
        await model.reconcileSideKeeps()
        let pending = try await store.list(CommandIntent.self, kind: "pending:" + child.id)
        XCTAssertEqual(pending, [intent]); XCTAssertTrue(parent.recovered.isEmpty)
        XCTAssertEqual(model.sideKeepIssues.map(\.id), [child.id])
        try await wire.host.shutdownAndWait()
    }

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
        model.sidePublicationOwnership = nil
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
            XCTAssertEqual(view.draft, "After failure", kind)
            XCTAssertEqual(parent.draft, intent.text, kind)
            let restored = try await store.get(DraftRecord.self, kind: "draft", id: parent.id)
            XCTAssertEqual(restored?.text, intent.text, kind)
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
        // Trigger changes may overlap ordinary actor commits. The injected
        // failures, not an unrelated DDL lock race, decide each assertion.
        XCTAssertEqual(sqlite3_busy_timeout(db, 3000), SQLITE_OK)
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
            let destination = method == "side" ? parent : view
            XCTAssertEqual(view.draft, discard || method == "side" ? "After cancellation" : "After cancellation\n\n" + captured)
            if !discard {
                let saved = try await store.get(DraftRecord.self, kind: "draft", id: destination.id)
                XCTAssertEqual(saved?.text, destination.draft)
                XCTAssertTrue(destination.draft.contains(captured))
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

    /// `/side <question>` empties the parent composer, so the question is the
    /// side's captured first send: its own record commits before publication
    /// waits. Process loss while the parent opens must leave the exact
    /// question reachable from the indexed parent after relaunch.
    func testSlashSideQuestionSurvivesProcessLossWhileItsParentOpens() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        let question = "Explain this failure"
        model.opened.remove(parent.id); wire.heldMethod = "session.open"
        parent.draft = "/side " + question; parent.directCommand = true
        model.send(sessionID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id])
        try await eventually("Parent opening held after the side's metadata committed") { wire.held != nil }
        let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: side.id)
        XCTAssertNotNil(keep, "The publication intent commits before the parent opens")
        XCTAssertEqual(parent.draft, "", "The slash command took the question out of the parent composer")
        // Reopening can take seconds; the emptied parent draft is saved by then.
        await model.draftWrites.tasks[parent.id]?.value
        let parentDraft = try await store.get(DraftRecord.self, kind: "draft", id: parent.id)
        XCTAssertFalse(parentDraft?.text.contains(question) == true)
        // Process loss: no close, flush, transfer or failure path runs. The
        // kernel releases the launch lease; only durable records remain.
        model.sidePublicationOwnership = nil
        let relaunched = makeWorkspaceModel(stateRoot: model.root, vault: model.vault)
        relaunched.prewarmsHelpers = false
        relaunched.automaticContextOperation = { _, _ in throw CancellationError() }
        relaunched.commandAcceptanceRead = { _, _, _ in [] }
        await relaunched.restore()
        let reopened = try XCTUnwrap(relaunched.store)
        let durable = try await reopened.selectionMetadata(id: parent.id, draft: false, anchor: false)
        XCTAssertEqual(durable.recovered.map(\.text), [question], "The exact question is recoverable through the indexed parent")
        XCTAssertTrue(relaunched.sideKeepIssues.isEmpty, "Not only a missing-file review notice")
        let stranded = try await reopened.list(CommandIntent.self, kind: "pending:" + side.id)
        XCTAssertTrue(stranded.isEmpty, "No input remains under the unpublished side")
        if relaunched.selectedID != parent.id { await relaunched.select(parent.id) }
        let shown = try XCTUnwrap(relaunched.displays[parent.id])
        try await eventually("The parent offers the question") { shown.recoverableSubmissions.map(\.text) == [question] }
        let input = try XCTUnwrap(shown.recoverableSubmissions.first)
        relaunched.recoverDraft(input, insert: true); await relaunched.draftWrites.recoveries[parent.id]?.value
        XCTAssertEqual(shown.draft, question)
        let saved = try await reopened.get(DraftRecord.self, kind: "draft", id: parent.id)
        XCTAssertEqual(saved?.text, question)
        model.shutdown(); try await wire.host.shutdownAndWait()
    }

    /// The same command without a crash: the question is captured at once as
    /// the side's first send, then published and dispatched exactly once.
    func testSlashSideQuestionIsCapturedAtOnceAndSentOnce() async throws {
        let (model, parent, wire) = try await fixture()
        parent.draft = "/side Explain this failure"; parent.directCommand = true
        model.send(sessionID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id]), view = try XCTUnwrap(model.displays[side.id])
        XCTAssertEqual(view.submittingCommands.count, 1, "The question is captured before publication can wait")
        XCTAssertEqual(view.draft, "", "and no longer sits in a replaceable side composer")
        try await eventually("Side published and its question settled") { model.sides[parent.id]?.kept == true && !view.loading && view.submittingCommands.isEmpty }
        let frames = wire.frames.filter { $0["method"]?.string == "turn.submit" }
        XCTAssertEqual(frames.map { $0["sessionId"]?.string }, [side.id])
        XCTAssertEqual(frames.first?["params"]?.object?["text"]?.string, "Explain this failure")
        XCTAssertEqual(parent.draft, ""); XCTAssertEqual(view.draft, "")
        XCTAssertNil(view.sendFailure); XCTAssertTrue(view.recoverableSubmissions.isEmpty)
        try await wire.host.shutdownAndWait()
    }

    /// `/side Q` while another side of the chat is still publishing is
    /// refused, and Q stays in the parent composer exactly as typed (and
    /// durably, once that composer is saved), never lost.
    func testSlashSideQuestionStaysInTheParentWhileAnotherSideIsPublishing() async throws {
        let (model, parent, wire) = try await fixture(), store = try XCTUnwrap(model.store)
        model.openSide(parentID: parent.id)
        let first = try XCTUnwrap(model.sides[parent.id]), firstView = try XCTUnwrap(model.displays[first.id])
        firstView.snapshotInFlight = true; firstView.draft = "First side message"
        wire.heldMethod = "side.open"; model.send(sessionID: first.id)
        try await eventually("First side still publishing") { wire.held != nil && model.sides[parent.id]?.pending == false }
        let command = "/side Explain this failure"
        parent.draft = command; parent.directCommand = true
        model.send(sessionID: parent.id)
        XCTAssertEqual(parent.draft, command, "A refused /side leaves the question where it was typed")
        XCTAssertTrue(parent.directCommand)
        XCTAssertEqual(model.sides[parent.id]?.id, first.id)
        XCTAssertEqual(model.error, "Wait for the current side to finish opening before starting another. Your question is still in this chat's composer.")
        model.draftChanged(parent); await model.draftWrites.tasks[parent.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: parent.id)
        XCTAssertEqual(saved?.text, command, "The question is never lost")
        wire.release()
        try await eventually("First side settled") { model.sides[parent.id]?.kept == true && !firstView.loading }
        XCTAssertEqual(wire.frames.filter { $0["method"]?.string == "turn.submit" }.compactMap { $0["params"]?.object?["text"]?.string }, ["First side message"])
        try await wire.host.shutdownAndWait()
    }

    /// A question the new side could not capture (too large, or a connection
    /// that is gone) stays in the parent composer, and no side is left
    /// holding it.
    func testSlashSideQuestionTheSideCannotSendStaysInTheParent() async throws {
        for refusal in ["size", "connection"] {
            let (model, parent, wire) = try await fixture()
            let question = refusal == "size" ? String(repeating: "q", count: SubmissionLimits.messageBytes + 1) : "Explain this failure"
            if refusal == "connection" { model.deletingProfiles.insert("p") }
            parent.draft = "/side " + question; parent.directCommand = true
            model.send(sessionID: parent.id)
            XCTAssertTrue(parent.draft == "/side " + question && parent.directCommand, "The composer keeps the command as typed (\(refusal))")
            XCTAssertNil(model.sides[parent.id], "No side is left holding a question it cannot send (\(refusal))")
            XCTAssertNotNil(model.error, refusal)
            model.deletingProfiles.remove("p")
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(wire.frames.contains { ["side.open", "turn.submit"].contains($0["method"]?.string ?? "") }, refusal)
            try await wire.host.shutdownAndWait()
        }
    }

    /// `/side Q` while the chat has a pending side: Q never replaces that
    /// side's unsent typing and never races its first send under way; it
    /// stays in the parent composer with a notice. An empty, idle pending
    /// side still takes Q as its first message.
    func testSlashSideQuestionNeverReplacesOrRacesAPendingSide() async throws {
        for state in ["sending", "sending and typed", "typed", "empty"] {
            let (model, parent, wire) = try await fixture()
            let sending = state.hasPrefix("sending")
            if sending { model.opened.remove(parent.id); wire.heldMethod = "session.open" }
            model.openSide(parentID: parent.id)
            let side = try XCTUnwrap(model.sides[parent.id]), sideView = try XCTUnwrap(model.displays[side.id])
            sideView.snapshotInFlight = true
            if sending {
                sideView.draft = "First side message"; model.send(sessionID: side.id)
                try await eventually("The side's first send waits for its parent") { wire.held != nil }
                XCTAssertTrue(model.sides[parent.id]?.pending == true && sideView.loading && sideView.draft.isEmpty)
            }
            if state == "sending and typed" { sideView.draft = "Typed in the side meanwhile" }
            if state == "typed" { sideView.draft = "My unsent side draft" }
            let sideDraft = sideView.draft, command = "/side Explain this failure"
            parent.draft = command; parent.directCommand = true
            model.send(sessionID: parent.id)
            XCTAssertEqual(sideView.draft, sideDraft, "The side's typing is never replaced (\(state))")
            if state == "empty" {
                XCTAssertEqual(parent.draft, "", "An empty, idle pending side takes the question")
                XCTAssertEqual(sideView.submittingCommands.count, 1)
            } else {
                XCTAssertEqual(parent.draft, command, "The question stays where it was typed (\(state))")
                XCTAssertTrue(parent.directCommand, state)
                XCTAssertEqual(model.error, sending
                    ? "Wait for this chat's side to send its first message. Your question is still in this chat's composer."
                    : "This chat's side has an unsent draft. Send or close it first; your question is still in this chat's composer.", state)
            }
            if sending { wire.release() }
            try await eventually("Side settled (\(state))") { !sideView.loading && sideView.submittingCommands.isEmpty }
            for _ in 0..<20 { await Task.yield() }
            let sent = wire.frames.filter { $0["method"]?.string == "turn.submit" }.compactMap { $0["params"]?.object?["text"]?.string }
            XCTAssertEqual(sent, sending ? ["First side message"] : state == "empty" ? ["Explain this failure"] : [], state)
            XCTAssertEqual(sideView.draft, sideDraft, state)
            if state != "empty" { XCTAssertEqual(parent.draft, command, state) }
            try await wire.host.shutdownAndWait()
        }
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
    var receipts: [[String: WireValue]] = []
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
            result = ["seq": .number(Double(snapshotSequence)), "state": .string("running"), "queue": .array([]), "queueEditRevision": .number(0),
                      "commands": .array(receipts.map(WireValue.object))]
        }
        let method = frame["method"]?.string ?? ""
        let publishing = ["side.open", "side.keep", "side.close", "session.fork"].contains(method)
        let publishedID = method == "side.open" ? frame["params"]?.object?["sideSessionId"]?.string
            : method == "session.fork" ? frame["params"]?.object?["forkSessionId"]?.string : frame["sessionId"]?.string
        if publishing, rejectedMethod != method, let id = publishedID {
            let prefix = method == "session.fork" ? "fork_" : "side_"
            let path = root.appendingPathComponent("Workspaces/w/Sessions/\(prefix)\(id).jsonl")
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header: [String: WireValue] = ["type": .string("session"), "version": .number(3), "id": .string(id)]
                var bytes = try JSONEncoder().encode(header); bytes.append(10); try bytes.write(to: path)
                result = ["sessionId": .string(id), "path": .string(path.path), "ephemeral": .bool(false)]
            } catch { XCTFail("Generated side could not be written: \(error)") }
        }
        guard let connection = host.connectionID, let epoch = host.epoch, let command = frame["commandId"] else { return }
        let rejected = frame["method"]?.string == rejectedMethod
        if rejected { result = ["code": .string("fixture_rejection"), "message": .string("Fixture rejection")] }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch), "commandId": command,
                             "ok": .bool(!rejected), "result": .object(result)]), connectionID: connection)
    }
}
