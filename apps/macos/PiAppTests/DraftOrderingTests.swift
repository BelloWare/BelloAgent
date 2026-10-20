import XCTest
@testable import PiApp

extension MetadataStore {
    func heldDraftCommit(_ draft: DraftRecord, version: DraftVersion, write: OrderedDraftWriter.Ticket, gate: DraftBaselineGate) throws {
        try orderedDraftWrite(draft.id, ticket: write) {
            gate.hold()
            try put(draft, kind: "draft", id: draft.id, draftVersion: version)
        }
    }
}

@MainActor final class DraftOrderingTests: XCTestCase {
    private func fixture() async throws -> (WorkspaceModel, SessionDisplay, MetadataStore) {
        let root = scratchRoot("draft-ordering"), vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")] }
        let model = makeWorkspaceModel(stateRoot: root, vault: vault); model.prewarmsHelpers = false
        try await model.reloadConfiguration()
        let store = try XCTUnwrap(model.store)
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p")
        try await store.put(chat, kind: "chat", id: chat.id)
        try await store.put(DraftRecord(id: chat.id, text: ""), kind: "draft", id: chat.id)
        let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        view.draftVersion = try await store.draftVersion(id: chat.id)
        model.chats = [chat]; model.displays[chat.id] = view
        return (model, view, store)
    }

    func testDelayedDebounceCannotOverwriteDirectSave() async throws {
        let (model, view, store) = try await fixture(), gate = AsyncGate()
        model.draftWrites.tasks[view.id] = Task { await gate.wait() }
        view.draft = "Older typing"; model.draftChanged(view)
        let debounce = model.draftWrites.tasks[view.id]
        let latest = DraftRecord(id: view.id, text: "Direct save")
        try await store.put(latest, kind: "draft", id: view.id, draftVersion: view.draftVersion)
        await gate.open(); await debounce?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, latest.text)
    }

    func testDelayedDebounceCannotRemoveAnEditSubmissionReview() async throws {
        let (model, view, store) = try await fixture(), gate = AsyncGate()
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: model.root, state: model.root.appendingPathComponent("host"))
        model.hosts["w"] = host; model.opened.insert(view.id)
        view.draftBeforeEdit = DraftRecord(id: view.id, text: "Parked input")
        view.editingMessageID = "old-turn"; view.draft = "Replacement"
        model.draftWrites.tasks[view.id] = Task { await gate.wait() }
        model.draftChanged(view); let debounce = model.draftWrites.tasks[view.id]
        model.sendEdit(sessionID: view.id)
        try await eventually("edit dispatched") { frames.contains { $0["method"]?.string == "turn.edit" } }
        let command = try XCTUnwrap(frames.first { $0["method"]?.string == "turn.edit" }?["commandId"]?.string)
        await gate.open(); await debounce?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.submissionReviews, [command], "An interrupted edit must reopen behind its review gate")
        try await host.shutdownAndWait()
    }

    func testSupersededRevisionCannotStartOrReplaceAConflictEpisode() async throws {
        for existingEpisode in [false, true] {
            let (model, view, store) = try await fixture()
            let old = try await store.reserveRevision(kind: "draft", id: view.id)
            try await store.put(DraftRecord(id: view.id, text: "Newer local save"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
            let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
            let version = try await other.draftVersion(id: view.id)
            try await other.put(DraftRecord(id: view.id, text: "Other instance"), kind: "draft", id: view.id, draftVersion: version)
            if existingEpisode {
                do { try await store.put(DraftRecord(id: view.id, text: "Latest losing input"), kind: "draft", id: view.id, draftVersion: view.draftVersion); XCTFail("Expected conflict") }
                catch { XCTAssertEqual(error as? StoreError, .draftConflict) }
            }
            let before = try await store.draftConflicts(id: view.id)
            do {
                try await store.put(DraftRecord(id: view.id, text: "Obsolete snapshot"), kind: "draft", id: view.id, revision: old, draftVersion: view.draftVersion)
                XCTFail("Expected stale local revision")
            } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
            let after = try await store.draftConflicts(id: view.id)
            XCTAssertEqual(after, before, "Superseded input must not create or replace a recovery copy")
            XCTAssertEqual(view.draftVersion.hasConflictEpisode, existingEpisode)
            XCTAssertFalse(view.draftVersion.hasUnsavedConflict)
            await other.close()
        }
    }

    func testSupersededTicketIsStaleEvenWhenItsTaskIgnoresCancellation() async throws {
        let (model, view, store) = try await fixture()
        let old = store.draftWriter.capture(view.id)
        try await store.put(DraftRecord(id: view.id, text: "Newer local"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        let other = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        let otherVersion = try await other.draftVersion(id: view.id)
        try await other.put(DraftRecord(id: view.id, text: "Other instance"), kind: "draft", id: view.id, draftVersion: otherVersion)
        do {
            try await store.put(DraftRecord(id: view.id, text: "Superseded"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: old)
            XCTFail("Superseded tickets must not reach conflict detection")
        } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        let copies = try await store.draftConflicts(id: view.id)
        XCTAssertTrue(copies.isEmpty); XCTAssertFalse(view.draftVersion.hasConflictEpisode)
        await other.close()
    }

    func testObsoleteReservationCannotCancelNewerPendingTyping() async throws {
        let (_, view, store) = try await fixture()
        let old = try await store.reserveRevision(kind: "draft", id: view.id)
        try await store.put(DraftRecord(id: view.id, text: "Committed"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        let latest = store.draftWriter.capture(view.id)
        for revision in [old, try XCTUnwrap(view.draftVersion.snapshot.revision)] {
            do {
                try await store.put(DraftRecord(id: view.id, text: "Obsolete"), kind: "draft", id: view.id, revision: revision, draftVersion: view.draftVersion)
                XCTFail("A committed or older revision cannot be reused")
            } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        }
        try await store.put(DraftRecord(id: view.id, text: "Latest typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: latest)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Latest typing")
    }

    func testAnchorAndComposerDoNotSupersedeEachOther() async throws {
        let (_, view, store) = try await fixture()
        let draft = store.draftWriter.capture(view.id)
        let position = TranscriptAnchor(id: "position", offset: 12, followsBottom: false)
        try await store.putAnchor(position, id: view.id, version: view.anchorVersion)
        try await store.put(DraftRecord(id: view.id, text: "Typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: draft)
        let anchor = store.draftWriter.capture(view.id, payload: .anchor)
        try await store.put(DraftRecord(id: view.id, text: "More typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        try await store.putAnchor(nil, id: view.id, version: view.anchorVersion, write: anchor)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let cleared = try await store.anchorVersion(id: view.id).snapshot
        XCTAssertEqual(saved?.text, "More typing"); XCTAssertNil(cleared.anchor); XCTAssertNotNil(cleared.revision)
    }

    func testDelayedAnchorCannotOverwriteDirectPositionOrClear() async throws {
        for clear in [false, true] {
            let (model, view, store) = try await fixture(), gate = AsyncGate()
            view.anchorWrite = Task { await gate.wait() }
            view.scrollAnchor = TranscriptAnchor(id: "old", offset: 1, followsBottom: false)
            model.anchorChanged(view); let delayed = view.anchorWrite
            let newest = clear ? nil : TranscriptAnchor(id: "new", offset: 9, followsBottom: false)
            try await store.putAnchor(newest, id: view.id, version: view.anchorVersion)
            await gate.open(); await delayed?.value
            let saved = try await store.anchorVersion(id: view.id).snapshot.anchor
            XCTAssertEqual(saved, newest)
        }
    }

    func testEveryDirectDraftWriterSupersedesAPendingDebounce() async throws {
        for writer in ["put", "reviews", "submission", "withdrawal", "restore", "keep", "handoff", "remove"] {
            let (model, view, store) = try await fixture(), gate = AsyncGate()
            let latest = DraftRecord(id: view.id, text: "Latest " + writer)
            try await store.put(latest, kind: "draft", id: view.id, draftVersion: view.draftVersion)
            let chat = try XCTUnwrap(model.record(view.id))
            let conflict = SavedDraftConflict(id: "copy", draft: latest)
            let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: "Captured input", state: "intent")
            try await store.put(conflict.draft, kind: "draft-conflict:" + view.id, id: conflict.id)
            try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
            try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
            model.draftWrites.tasks[view.id] = Task { await gate.wait() }
            view.draft = "Old snapshot"; model.draftChanged(view)
            let pending = model.draftWrites.tasks[view.id]
            switch writer {
            case "put": try await store.put(latest, kind: "draft", id: view.id, draftVersion: view.draftVersion)
            case "reviews": try await store.preserveSubmissionReviews(sessionID: view.id, commands: [intent.id], draftVersion: view.draftVersion)
            case "submission": try await store.recordSubmission(intent, draft: latest, draftVersion: view.draftVersion)
            case "withdrawal": try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: latest, draftVersion: view.draftVersion)
            case "restore": try await store.restoreConflict(conflict, replacing: latest, version: view.draftVersion)
            case "keep": try await store.commitKeptSide(chat, draft: latest, expected: chat, draftVersion: view.draftVersion)
            case "handoff": try await store.commitPortableHandoff(chat, draft: latest, provenance: nil)
            case "remove": try await store.remove(kind: "draft", id: view.id)
            default: XCTFail("Unknown writer")
            }
            XCTAssertTrue(pending?.isCancelled == true, writer)
            await gate.open(); await pending?.value
            let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.text, writer == "remove" ? nil : latest.text, writer)
            if writer == "reviews" { XCTAssertEqual(saved?.submissionReviews, [intent.id]) }
        }
    }

    func testSupersededSubmissionSnapshotKeepsItsIndependentInput() async throws {
        let (_, view, store) = try await fixture()
        let old = store.draftWriter.capture(view.id)
        try await store.put(DraftRecord(id: view.id, text: "Newer typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: "Captured input", state: "intent")
        try await store.recordSubmission(intent, draft: DraftRecord(id: view.id, text: ""), draftVersion: view.draftVersion, write: old)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
        XCTAssertEqual(saved?.text, "Newer typing"); XCTAssertEqual(pending?.text, intent.text)
        let copies = try await store.draftConflicts(id: view.id)
        XCTAssertTrue(copies.isEmpty)
    }

    func testSupersededRecoveryCannotConsumeItsInputOrConflictCopy() async throws {
        let (_, view, store) = try await fixture()
        let recovered = DraftRecord(id: view.id, text: "Recoverable input")
        let conflict = SavedDraftConflict(id: "copy", draft: recovered)
        let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: recovered.text, state: "intent")
        try await store.put(recovered, kind: "draft-conflict:" + view.id, id: conflict.id)
        try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
        let old = store.draftWriter.capture(view.id)
        try await store.put(DraftRecord(id: view.id, text: "Newer typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        do {
            try await store.restoreConflict(conflict, replacing: recovered, version: view.draftVersion, write: old)
            XCTFail("A superseded restoration must not touch recovery records")
        } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        do {
            try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: recovered, draftVersion: view.draftVersion, write: old)
            XCTFail("A superseded recovery must retain its captured input")
        } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        let copies = try await store.draftConflicts(id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
        XCTAssertEqual(copies, [conflict]); XCTAssertEqual(pending?.text, intent.text)
    }

    func testLateCancellationBindingAndCleanupCannotRetireANewerTicket() async throws {
        let (_, view, store) = try await fixture()
        let old = store.draftWriter.capture(view.id), newest = store.draftWriter.capture(view.id)
        let gate = AsyncGate(), task = Task { await gate.wait() }
        store.draftWriter.cancelOnSupersession(old, task: task)
        XCTAssertTrue(task.isCancelled)
        store.draftWriter.finish(old)
        try await store.put(DraftRecord(id: view.id, text: "Newest"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: newest)
        await gate.open(); await task.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Newest")
    }

    func testBegunWriteCommitsBeforeNewerSnapshotReservesItsRevision() async throws {
        let (_, view, store) = try await fixture()
        let gate = DraftBaselineGate(expectation(description: "older write began"))
        let old = store.draftWriter.capture(view.id)
        let committing = Task { try await store.heldDraftCommit(DraftRecord(id: view.id, text: "Committing"), version: view.draftVersion, write: old, gate: gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let newest = store.draftWriter.capture(view.id)
        let saving = Task { try await store.put(DraftRecord(id: view.id, text: ""), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: newest) }
        gate.resume.signal(); try await committing.value; try await saving.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "", "Returning to the original baseline must follow the already-begun write")
        XCTAssertEqual(view.draftVersion.snapshot.draft, saved)
    }

    func testCompletedRegistrationLeavesPendingTypingWithItsWriter() async throws {
        let (model, view, store) = try await fixture(), gate = AsyncGate()
        let chat = try XCTUnwrap(model.record(view.id))
        try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
        try await store.commitKeptSide(chat, draft: view.savedDraft, expected: chat, draftVersion: view.draftVersion)
        model.draftWrites.tasks[view.id] = Task { await gate.wait() }
        view.draft = "Typing while registration finishes"; model.draftChanged(view)
        let debounce = model.draftWrites.tasks[view.id]
        try await store.commitKeptSide(chat, draft: view.savedDraft, expected: chat, draftVersion: view.draftVersion, write: store.draftWriter.prepare(view.id))
        XCTAssertFalse(debounce?.isCancelled == true)
        await gate.open(); await debounce?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, view.draft, "A receipt replay must leave pending typing with its own writer")
    }

    func testPreparedRegistrationCannotOverwriteNewerTypingOrConsumeItsIntent() async throws {
        let (model, view, store) = try await fixture()
        let chat = try XCTUnwrap(model.record(view.id))
        try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
        let prepared = store.draftWriter.prepare(view.id)
        try await store.put(DraftRecord(id: view.id, text: "Newer typing"), kind: "draft", id: view.id, draftVersion: view.draftVersion)
        do {
            try await store.commitKeptSide(chat, draft: DraftRecord(id: view.id, text: "Older registration"), expected: chat, draftVersion: view.draftVersion, write: prepared)
            XCTFail("A newer snapshot supersedes a conditional writer too")
        } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let intent = try await store.get(SideKeepIntent.self, kind: "side-keep", id: view.id)
        XCTAssertEqual(saved?.text, "Newer typing"); XCTAssertNotNil(intent)
    }

    func testConditionalWritersRetireOnlyOlderPreparationsWhenTheyBegin() async throws {
        for newestFirst in [false, true] {
            let (_, view, store) = try await fixture()
            let older = store.draftWriter.prepare(view.id), newer = store.draftWriter.prepare(view.id)
            if !newestFirst { try await store.put(DraftRecord(id: view.id, text: "Older"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: older) }
            try await store.put(DraftRecord(id: view.id, text: "Newer"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: newer)
            if newestFirst {
                do {
                    try await store.put(DraftRecord(id: view.id, text: "Older"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: older)
                    XCTFail("A later conditional commit retires earlier preparations")
                } catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
            }
            let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.text, "Newer")
        }
    }

    func testPreparedRegistrationSupersedesAnOlderDebounceWhenItWrites() async throws {
        let (model, view, store) = try await fixture(), gate = AsyncGate()
        let chat = try XCTUnwrap(model.record(view.id))
        try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
        model.draftWrites.tasks[view.id] = Task { await gate.wait() }
        view.draft = "Older typing"; model.draftChanged(view)
        let debounce = model.draftWrites.tasks[view.id]
        view.draft = "Current registration draft"
        try await store.commitKeptSide(chat, draft: view.savedDraft, expected: chat, draftVersion: view.draftVersion, write: store.draftWriter.prepare(view.id))
        XCTAssertTrue(debounce?.isCancelled == true)
        await gate.open(); await debounce?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, view.draft)
    }

    func testConnectionRefusalSavesCurrentTypingInsteadOfItsCapturedMessage() async throws {
        let (model, view, store) = try await fixture()
        model.chats[0].profileID = "missing-connection"
        view.draft = "Text when Return was pressed"
        model.send(sessionID: view.id)
        // Send has captured its refusal, but its task has not started. The
        // refused input stays editable and receives a newer complete snapshot.
        view.draft = "Newer typing after the refusal"; model.draftChanged(view)
        try await eventually("refused send settled") { !view.loading }
        await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertNotNil(view.sendFailure); XCTAssertTrue(view.sendingRows.isEmpty)
        XCTAssertEqual(saved?.text, view.draft)
    }
}
