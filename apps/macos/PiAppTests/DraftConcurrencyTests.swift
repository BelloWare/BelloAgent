import XCTest
import AppKit
import SQLite3
@testable import PiApp

@MainActor final class DraftConcurrencyTests: XCTestCase {
    private func fixture(saved: Bool = true) async throws -> (WorkspaceModel, SessionDisplay, WorkspaceModel, SessionDisplay) {
        let root = scratchRoot("draft-concurrency")
        let first = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let second = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Shared chat", profileID: "p")
        try await first.store?.put(chat, kind: "chat", id: chat.id)
        if saved { try await first.store?.put(DraftRecord(id: chat.id, text: ""), kind: "draft", id: chat.id) }
        for model in [first, second] {
            model.prewarmsHelpers = false; model.chats = [chat]
            let view = SessionDisplay(id: chat.id); model.displays[chat.id] = view
            let loaded = try await model.reconcileSubmissionDraft(chat, view: view, current: { true })
            XCTAssertTrue(loaded); XCTAssertTrue(view.selectionMetadataLoaded)
        }
        return (first, try XCTUnwrap(first.displays[chat.id]), second, try XCTUnwrap(second.displays[chat.id]))
    }

    private func conflicted() async throws -> (WorkspaceModel, SessionDisplay, DraftRecord) {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        b.draft = "Losing draft with user input"
        b.submissionReviews = ["unacknowledged-command"]
        b.editingMessageID = "edited-message"
        b.draftBeforeEdit = DraftRecord(id: b.id, text: "Displaced input")
        let losing = b.savedDraft
        second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        XCTAssertNotNil(second.error)
        return (second, b, losing)
    }

    private func assertConflictSaved(_ model: WorkspaceModel, _ losing: DraftRecord, file: StaticString = #filePath, line: UInt = #line) async throws {
        // A different connection must find the complete copy, even after the
        // original display or store is no longer available.
        let reader = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        let copies = try await reader.list(DraftRecord.self, kind: "draft-conflict:" + losing.id)
        XCTAssertTrue(copies.contains(losing), "The losing draft must already be durable", file: file, line: line)
        let winner = try await reader.get(DraftRecord.self, kind: "draft", id: losing.id)
        XCTAssertEqual(winner?.text, "Winning draft", file: file, line: line)
        await reader.close()
    }

    private func fillDisplayCache(_ model: WorkspaceModel, oldest: SessionDisplay) {
        oldest.used = .distantPast
        for n in 0..<10 {
            let chat = ChatRecord(id: "other-\(n)", workspaceID: "w", title: "Other", profileID: "p")
            model.chats.append(chat); model.displays[chat.id] = SessionDisplay(id: chat.id)
        }
    }

    func testConflictIsDurableAtDetectionAndAfterDisplayEviction() async throws {
        let (model, view, losing) = try await conflicted()
        try await assertConflictSaved(model, losing)
        fillDisplayCache(model, oldest: view); model.releaseUnreadDisplays(keeping: "other-9")
        try await assertConflictSaved(model, losing)
    }

    func testChatSwitchPreservesTheConflictCopy() async throws {
        let (model, view, losing) = try await conflicted()
        model.selectedID = view.id; model.selected = view
        fillDisplayCache(model, oldest: view)
        await model.select("other-9", focusesComposer: false)
        try await assertConflictSaved(model, losing)
        await model.select(view.id, focusesComposer: false)
        let copies = try await model.store?.list(DraftRecord.self, kind: "draft-conflict:" + view.id)
        XCTAssertTrue(copies?.contains(losing) == true)
    }

    func testSideClosePreservesTheConflictCopy() async throws {
        let (model, view, losing) = try await conflicted()
        var info = SideRecord(id: view.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
        info.kept = true; model.sides[info.parentID] = info
        model.closeSide(view.id)
        try await eventually("side close settled") { !view.loading }
        try await assertConflictSaved(model, losing)
    }

    func testQuitPreservesTheConflictCopyBeforeAnswering() async throws {
        let (model, _, losing) = try await conflicted()
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = []; lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        try await eventually("quit answered") { !answers.isEmpty }
        XCTAssertEqual(answers, [false], "The existing explicit conflict refusal remains")
        try await assertConflictSaved(model, losing)
    }

    func testUpdatePreservesTheConflictCopyBeforeRefusing() async throws {
        let (model, _, losing) = try await conflicted()
        XCTAssertTrue(model.acquireUpdateBarrier())
        do { try await model.prepareForInstall(); XCTFail("The existing conflict refusal remains") } catch { }
        model.releaseUpdateBarrier()
        try await assertConflictSaved(model, losing)
    }

    func testConflictCopySurvivesSubmissionTransactionRollback() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let losing = DraftRecord(id: b.id, text: "Draft inside failed transaction")
        let intent = CommandIntent(id: "submission", sessionID: b.id, turnID: "turn", text: "Message", state: "intent")
        do { try await second.store?.recordSubmission(intent, draft: losing, draftVersion: b.draftVersion); XCTFail("Must conflict") } catch { }
        try await assertConflictSaved(second, losing)
        let savedIntent = try await second.store?.get(CommandIntent.self, kind: "pending:" + b.id, id: intent.id)
        XCTAssertNil(savedIntent, "Preserving a conflict must not commit the failed submission")
    }

    func testConflictCopyWriteFailurePinsTheDisplayDuringNavigation() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(second.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_conflict BEFORE INSERT ON records WHEN NEW.kind LIKE 'draft-conflict:%' BEGIN SELECT RAISE(ABORT, 'generated conflict storage failure'); END", nil, nil, nil), SQLITE_OK)
        b.draft = "Only in memory until storage recovers"; second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        fillDisplayCache(second, oldest: b); second.releaseUnreadDisplays(keeping: "other-9")
        XCTAssertTrue(second.displays[b.id] === b, "Failed conflict preservation must pin its only remaining copy")
        await second.select("other-9", focusesComposer: false)
        XCTAssertTrue(second.displays[b.id] === b)
        var info = SideRecord(id: b.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
        info.pending = true; second.sides[info.parentID] = info
        XCTAssertFalse(second.discardPendingSideNow(info))
        let removed = await second.discardPendingSide(info); XCTAssertFalse(removed)
        info.pending = false; second.sides[info.parentID] = info
        second.discardLostSides(workspaceID: info.workspaceID)
        XCTAssertTrue(second.displays[b.id] === b, "Helper loss must keep a conflict whose durable write failed")
        XCTAssertEqual(second.sides[info.parentID]?.id, b.id)
        second.sides.removeAll()
        second.pendingChatIDs.insert(b.id); second.discardPendingChat(b.id)
        XCTAssertTrue(second.displays[b.id] === b)
        second.pendingChatIDs.remove(b.id)
        second.deleteChat(b.id)
        XCTAssertNotNil(second.record(b.id))
        XCTAssertTrue(second.acquireUpdateBarrier())
        do { try await second.prepareForInstall(); XCTFail("Failed conflict persistence must refuse update") } catch { }
        second.releaseUpdateBarrier()
        let lifecycle = ApplicationLifecycle(); lifecycle.model = second
        var answers: [Bool] = []; lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        try await eventually("failed-storage quit answered") { !answers.isEmpty }
        XCTAssertEqual(answers, [false]); XCTAssertTrue(second.displays[b.id] === b)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_conflict", nil, nil, nil), SQLITE_OK)
        try? await second.flushDrafts()
        try await assertConflictSaved(second, b.savedDraft)
    }

    func testAChangedDraftStaysPinnedWhileItsConflictCheckIsWaiting() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let store = try XCTUnwrap(second.store), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let held = Task { try await store.put(DraftConflictStoreGate(entered: entered, release: release), kind: "fixture", id: "hold") }
        try await eventually("store held") { entered.wait(timeout: .now()) == .success }
        b.draft = "Waiting for conflict detection"
        var checking = false
        let flush = Task { checking = true; try? await second.flushDrafts() }
        try await eventually("flush waiting") { checking }
        fillDisplayCache(second, oldest: b); second.releaseUnreadDisplays(keeping: "other-9")
        XCTAssertTrue(second.displays[b.id] === b)
        release.signal(); try await held.value; await flush.value
        try await assertConflictSaved(second, b.savedDraft)
    }

    func testPendingSideConflictMustBeSavedBeforeQuitOrUpdate() async throws {
        for quit in [false, true] {
            let (first, a, model, view) = try await fixture()
            a.draft = "Winning draft"; try await first.flushDrafts()
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_conflict BEFORE INSERT ON records WHEN NEW.kind LIKE 'draft-conflict:%' BEGIN SELECT RAISE(ABORT, 'generated storage failure'); END", nil, nil, nil), SQLITE_OK)
            view.draft = "Original losing input"; try? await model.flushDrafts()
            let original = view.savedDraft
            view.draft = "Later input in the side"
            var side = SideRecord(id: view.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
            side.pending = true; model.sides[side.parentID] = side
            if quit {
                let lifecycle = ApplicationLifecycle(); lifecycle.model = model
                var answers: [Bool] = []; lifecycle.answerTermination = { answers.append($0) }
                XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
                try await eventually("pending side quit answered") { !answers.isEmpty }
                XCTAssertEqual(answers, [false], "Quit must not drop an uncommitted conflict snapshot")
                XCTAssertFalse(model.isShutDown)
            } else {
                XCTAssertTrue(model.acquireUpdateBarrier())
                do { try await model.prepareForInstall(); XCTFail("Update must refuse the uncommitted conflict snapshot") } catch { }
                model.releaseUpdateBarrier()
            }
            XCTAssertEqual(view.draft, "Later input in the side", "Do not consume the side before its conflict copy is durable")
            XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_conflict", nil, nil, nil), SQLITE_OK)
            let discarded = await model.discardPendingSide(side)
            XCTAssertTrue(discarded, "Closing must retry preservation once storage recovers")
            try await assertConflictSaved(model, original)
        }
    }

    private func anchored() async throws -> (WorkspaceModel, SessionDisplay, WorkspaceModel, SessionDisplay) {
        let (first, a, second, b) = try await fixture()
        try await first.store?.put(TranscriptAnchor(id: "old", offset: 3, followsBottom: false), kind: "anchor", id: a.id)
        for (model, view) in [(first, a), (second, b)] {
            view.selectionMetadataLoaded = false
            _ = try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true })
        }
        return (first, a, second, b)
    }

    func testUnchangedStaleQuitDoesNotOverwriteANewerReadingPosition() async throws {
        let (first, a, second, _) = try await anchored()
        let newest = TranscriptAnchor(id: "new", offset: 42, followsBottom: false)
        a.scrollAnchor = newest; try await first.flushDrafts(); try await second.flushDrafts()
        let saved = try await first.store?.get(TranscriptAnchor.self, kind: "anchor", id: a.id)
        XCTAssertEqual(saved, newest)
    }

    func testChangedStaleReadingPositionCannotOverwriteAnotherInstancesSave() async throws {
        let (first, a, second, b) = try await anchored()
        let newest = TranscriptAnchor(id: "new", offset: 42, followsBottom: false)
        a.scrollAnchor = newest; try await first.flushDrafts()
        b.scrollAnchor = TranscriptAnchor(id: "stale", offset: 9, followsBottom: false)
        second.anchorChanged(b)
        try await Task.sleep(for: .milliseconds(100))
        try await second.flushDrafts()
        let saved = try await first.store?.get(TranscriptAnchor.self, kind: "anchor", id: a.id)
        XCTAssertEqual(saved, newest)
    }

    func testRejectedSubmissionPreservesItsInputAsWellAsTheRemainingDraft() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let intent = CommandIntent(id: "submission", sessionID: b.id, turnID: "turn", text: "Accepted input waiting to send", state: "intent")
        do { try await second.store?.recordSubmission(intent, draft: DraftRecord(id: b.id, text: "Remaining input"), draftVersion: b.draftVersion); XCTFail("Must conflict") } catch { }
        let copies = try await second.store?.list(DraftRecord.self, kind: "draft-conflict:" + b.id)
        XCTAssertTrue(copies?.contains(where: { $0.text == intent.text }) == true, "The rejected submission's input must be durable too")
    }

    func testConflictRecoveryAfterReloadKeepsWinnerAndFullLosingDraft() async throws {
        let (model, view, losing) = try await conflicted()
        // Recreate the display as after process exit; no old composer helps.
        model.displays.removeAll(); model.selected = nil; model.selectedID = nil
        await model.select(view.id, focusesComposer: false)
        let reopened = try XCTUnwrap(model.displays[view.id])
        XCTAssertEqual(reopened.draft, "Winning draft")
        let conflict = try XCTUnwrap(reopened.draftConflicts.first { $0.draft == losing })
        model.restoreConflictedDraft(conflict)
        try await eventually("conflict recovery finished") { !reopened.loading }
        XCTAssertTrue(reopened.savedDraft.hasSameContents(as: losing))
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: losing.id)
        XCTAssertTrue(saved?.hasSameContents(as: losing) == true)
        let copies = try await model.store?.list(DraftRecord.self, kind: "draft-conflict:" + losing.id)
        XCTAssertTrue(copies?.contains(where: { $0.text == "Winning draft" }) == true, "Explicit restoration must keep the previous saved copy")
    }

    func testRepeatedConflictsKeepDistinctEditsWithoutDuplicatingRetries() async throws {
        let (model, view, original) = try await conflicted()
        for _ in 0..<3 { try? await model.flushDrafts() }
        var copies = try await model.store?.list(DraftRecord.self, kind: "draft-conflict:" + view.id)
        XCTAssertEqual(copies?.filter { $0 == original }.count, 1)
        view.draft = "Later losing edit"; try? await model.flushDrafts()
        copies = try await model.store?.list(DraftRecord.self, kind: "draft-conflict:" + view.id)
        XCTAssertEqual(copies?.count, 2)
        XCTAssertTrue(copies?.contains(original) == true)
        XCTAssertTrue(copies?.contains(view.savedDraft) == true)
    }

    func testConflictCopyKeepsItsPastedImageThroughCleanup() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7l8AAAAASUVORK5CYII=")!
        let file = try PastedImageStorage(root: second.root).write(png)
        b.attachments = [try AttachmentRecord.inspect(file)]; b.draft = "Picture in losing draft"
        let losing = b.savedDraft
        try? await second.flushDrafts()
        second.displays.removeAll(); second.launching = false
        try await second.cleanupPastedImages()
        XCTAssertEqual(try Data(contentsOf: file), png)
        try await assertConflictSaved(second, losing)
    }

    func testFailedConflictCopyDefersPastedImageCleanup() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7l8AAAAASUVORK5CYII=")!
        let file = try PastedImageStorage(root: second.root).write(png)
        b.attachments = [try AttachmentRecord.inspect(file)]; b.draft = "Conflict with an image"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(second.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_conflict BEFORE INSERT ON records WHEN NEW.kind LIKE 'draft-conflict:%' BEGIN SELECT RAISE(ABORT, 'generated storage failure'); END", nil, nil, nil), SQLITE_OK)
        try? await second.flushDrafts()
        b.attachments = []; b.draft = "Later input while storage remains unavailable"
        second.launching = false
        try await second.cleanupPastedImages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "A conflict awaiting its durable copy still owns its image")
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_conflict", nil, nil, nil), SQLITE_OK)
    }

    func testClearedReadingPositionCannotBeResurrectedByAStaleQuit() async throws {
        let (first, a, second, _) = try await anchored()
        a.scrollAnchor = nil; first.anchorChanged(a)
        try await first.flushDrafts(); try await second.flushDrafts()
        let saved = try await first.store?.get(TranscriptAnchor.self, kind: "anchor", id: a.id)
        XCTAssertNil(saved)
    }

    func testMissingAnchorBaselineCannotOverwriteACreatedThenClearedPosition() async throws {
        let (first, a, second, b) = try await fixture()
        a.scrollAnchor = .init(id: "new", offset: 1, followsBottom: false); try await first.flushDrafts()
        a.scrollAnchor = nil; first.anchorChanged(a); try await first.flushDrafts()
        b.scrollAnchor = .init(id: "obsolete", offset: 2, followsBottom: false); try await second.flushDrafts()
        let saved = try await first.store?.get(TranscriptAnchor.self, kind: "anchor", id: a.id)
        XCTAssertNil(saved, "Cleared anchors need a revision even though their value is absent")
    }

    func testAnchorWritesSettleInLocalOrderBeforeQuit() async throws {
        let (model, view, _, _) = try await anchored()
        view.scrollAnchor = .init(id: "first", offset: 1, followsBottom: false); model.anchorChanged(view)
        view.scrollAnchor = nil; model.anchorChanged(view)
        let newest = TranscriptAnchor(id: "last", offset: 3, followsBottom: false)
        view.scrollAnchor = newest; model.anchorChanged(view)
        try await model.flushDrafts()
        let saved = try await model.store?.get(TranscriptAnchor.self, kind: "anchor", id: view.id)
        XCTAssertEqual(saved, newest)
    }

    func testSideCloseUsesItsLoadedAnchorRevision() async throws {
        let (first, a, second, b) = try await anchored()
        let newest = TranscriptAnchor(id: "new", offset: 42, followsBottom: false)
        a.scrollAnchor = newest; try await first.flushDrafts()
        var info = SideRecord(id: b.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
        info.kept = true; second.sides[info.parentID] = info
        second.closeSide(b.id); try await eventually("side closed") { !b.loading }
        let saved = try await first.store?.get(TranscriptAnchor.self, kind: "anchor", id: a.id)
        XCTAssertEqual(saved, newest)
    }

    func testUnchangedStaleInstanceDoesNotOverwriteAnotherInstancesDraft() async throws {
        for saved in [false, true] {
            let (first, a, second, _) = try await fixture(saved: saved)
            a.draft = "Saved by A"; first.draftChanged(a)
            await first.draftWrites.tasks[a.id]?.value
            try await first.flushDrafts()
            try await second.flushDrafts()
            let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
            XCTAssertEqual(persisted?.text, "Saved by A")
        }
    }

    func testConflictingEditsStayInTheirComposerAndRefuseTheQuitFlush() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Saved by A"; try await first.flushDrafts()
        b.draft = "Still owned by B"
        do { try await second.flushDrafts(); XCTFail("A conflicting draft must not silently replace another instance's text") } catch { }
        XCTAssertEqual(b.draft, "Still owned by B")
        let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(persisted?.text, "Saved by A")
        // A debounce must use the same optimistic check as Quit.
        second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        let afterDebounce = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(afterDebounce?.text, "Saved by A"); XCTAssertNotNil(second.error)
    }

    func testUnchangedLegacyEditedDraftDoesNotBecomeANewWrite() async throws {
        let (first, a, second, b) = try await fixture()
        let legacy = DraftRecord(id: a.id, text: "Edited message", edit: MessageEditDraft(messageID: "m", originalText: "Parked draft"))
        try await first.store?.put(legacy, kind: "draft", id: a.id)
        for (model, view) in [(first, a), (second, b)] {
            view.selectionMetadataLoaded = false
            _ = try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(view.id)), view: view, current: { true })
        }
        a.draft = "A newer edit"; try await first.flushDrafts()
        try await second.flushDrafts()
        let saved = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(saved?.text, "A newer edit")
    }

    func testFlushWaitsForAnAdmittedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: true) }
    func testDebounceWaitsForAnAdmittedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: false) }

    private func admittedWrite(flush: Bool) async throws {
        let (model, view, _, _) = try await fixture()
        let store = try XCTUnwrap(model.store), gate = AsyncGate(), token = UUID()
        let revision = try await store.reserveRevision(kind: "draft", id: view.id)
        // A write already dispatched to the actor is not withdrawn by Task
        // cancellation. Hold its completion while the composer returns to
        // the initially loaded empty draft.
        let admitted = Task {
            defer { if model.draftWrites.tokens[view.id] == token { model.draftWrites.tasks[view.id] = nil; model.draftWrites.tokens[view.id] = nil } }
            await gate.wait()
            try? await store.put(DraftRecord(id: view.id, text: "Older queued write"), kind: "draft", id: view.id, revision: revision, draftVersion: view.draftVersion)
        }
        model.draftWrites.tasks[view.id] = admitted; model.draftWrites.tokens[view.id] = token
        var finished = false
        let latest = Task {
            if flush { try await model.flushDrafts() }
            else { model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value }
            finished = true
        }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(finished, "An admitted older write must settle before an unchanged draft can skip saving")
        await gate.open(); await admitted.value; try await latest.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "", "Undoing back to the loaded draft must survive the older in-flight write")
    }

    func testFailedSubmissionTransactionDoesNotAdvanceTheDraftVersion() async throws {
        let (model, view, _, _) = try await fixture()
        let store = try XCTUnwrap(model.store), revision = view.draftVersion.snapshot.revision
        let invalid = CommandIntent(id: "bad", sessionID: view.id, turnID: "t", text: String(repeating: "x", count: MetadataStore.inputRecordByteLimit), state: "intent")
        do {
            try await store.recordSubmission(invalid, draft: DraftRecord(id: view.id, text: "Rolled back"), draftVersion: view.draftVersion)
            XCTFail("The oversized intent must roll back its draft too")
        } catch { XCTAssertEqual(error as? StoreError, .invalidRecord) }
        XCTAssertEqual(view.draftVersion.snapshot.revision, revision)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "")
        view.draft = "Retry after rollback"; try await model.flushDrafts()
        let retried = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(retried?.text, view.draft)
    }

    func testConcurrentDraftFlushesHaveOneWinnerAndPreserveTheOtherInput() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "A"; b.draft = "B"
        let one = Task { () -> Bool in do { try await first.flushDrafts(); return true } catch { return false } }
        let two = Task { () -> Bool in do { try await second.flushDrafts(); return true } catch { return false } }
        let results = await [one.value, two.value]
        XCTAssertEqual(results.filter { $0 }.count, 1, "The draft comparison and write must be atomic across store actors")
        XCTAssertEqual(a.draft, "A"); XCTAssertEqual(b.draft, "B")
        let persisted = try await first.store?.get(DraftRecord.self, kind: "draft", id: a.id)
        XCTAssertEqual(persisted?.text, results[0] ? "A" : "B")
    }
}

private struct DraftConflictStoreGate: Encodable, Sendable {
    let entered: DispatchSemaphore
    let release: DispatchSemaphore
    func encode(to encoder: Encoder) throws {
        entered.signal(); release.wait()
        var value = encoder.singleValueContainer(); try value.encode(true)
    }
}
