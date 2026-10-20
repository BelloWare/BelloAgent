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
        XCTAssertEqual(savedIntent?.text, intent.text, "The failed draft write must still retain its captured input")
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
        XCTAssertEqual(copies?.map(\.text), ["Remaining input"])
        // Empty debounces and continued typing replace only the episode copy.
        for text in ["", "Later typing", ""] {
            b.draft = text; second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        }
        let reader = MetadataStore(url: second.root.appendingPathComponent("desktop.sqlite"))
        let recovered = try await reader.selectionMetadata(id: b.id, draft: true, anchor: false)
        XCTAssertEqual(recovered.recovered.map(\.text), [intent.text])
        XCTAssertEqual(recovered.conflicts.map(\.draft.text), [""])
        XCTAssertEqual(recovered.draft?.text, "Winning draft")
        await reader.close()
    }

    func testRejectedSubmissionSettlesOnlyWhenRestoredOrDiscarded() async throws {
        for insert in [true, false] {
            let (first, a, second, b) = try await fixture()
            a.draft = "Winning draft"; try await first.flushDrafts()
            let intent = CommandIntent(id: "submission", sessionID: b.id, turnID: "turn", text: "Captured input", state: "intent", draftReviewTracked: true)
            do { try await second.store?.recordSubmission(intent, draft: DraftRecord(id: b.id, text: "Remaining input"), draftVersion: b.draftVersion); XCTFail("Must conflict") } catch { }
            // Recreate the display without the losing process's in-memory input.
            second.displays.removeAll()
            await second.select(b.id, focusesComposer: false)
            let reopened = try XCTUnwrap(second.displays[b.id])
            XCTAssertEqual(reopened.recovered.map(\.id), [intent.id])
            second.recoverDraft(intent, insert: insert)
            await second.draftWrites.recoveries[b.id]?.value
            let saved = try await second.store?.get(DraftRecord.self, kind: "draft", id: b.id)
            XCTAssertEqual(saved?.text, insert ? "Winning draft\n\nCaptured input" : "Winning draft")
            let pending = try await second.store?.list(CommandIntent.self, kind: "pending:" + b.id)
            XCTAssertTrue(pending?.isEmpty == true)
        }
    }

    func testFailedCapturedInputPreservationPinsUntilBothRecordsCommit() async throws {
        let (first, a, second, b) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        let intent = CommandIntent(id: "submission", sessionID: b.id, turnID: "turn", text: "Captured input", state: "intent")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(second.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_input BEFORE INSERT ON records WHEN NEW.kind='pending:chat' BEGIN SELECT RAISE(FAIL, 'generated failure'); END;", nil, nil, nil), SQLITE_OK)
        do { try await second.store?.recordSubmission(intent, draft: DraftRecord(id: b.id, text: "Remaining input"), draftVersion: b.draftVersion); XCTFail("Must fail") } catch { }
        XCTAssertTrue(b.draftVersion.hasUnsavedConflict, "An unsaved captured input pins its display")
        let pendingCopies = try await second.store?.draftConflicts(id: b.id)
        XCTAssertTrue(pendingCopies?.isEmpty == true, "The composer copy and captured input must commit together")
        fillDisplayCache(second, oldest: b); second.releaseUnreadDisplays(keeping: "other-9")
        XCTAssertTrue(second.displays[b.id] === b)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_input", nil, nil, nil), SQLITE_OK)
        b.draft = ""; second.draftChanged(b); await second.draftWrites.tasks[b.id]?.value
        XCTAssertFalse(b.draftVersion.hasUnsavedConflict)
        let pending = try await second.store?.list(CommandIntent.self, kind: "pending:" + b.id)
        XCTAssertEqual(pending?.map(\.text), [intent.text])
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

    func testConflictEpisodeUpdatesOneCopyUntilTheOtherInstanceChangesAgain() async throws {
        let (model, view, original) = try await conflicted()
        for _ in 0..<3 { try? await model.flushDrafts() }
        var copies = try await model.store?.draftConflicts(id: view.id) ?? []
        let first = try XCTUnwrap(copies.first)
        XCTAssertEqual(first.draft, original); XCTAssertEqual(copies.count, 1)
        for index in 0..<20 { view.draft = "Later losing edit \(index)"; try? await model.flushDrafts() }
        copies = try await model.store?.draftConflicts(id: view.id) ?? []
        XCTAssertEqual(copies.count, 1, "Typing in one conflict episode must update its copy in place")
        XCTAssertEqual(copies.first?.id, first.id)
        XCTAssertEqual(copies.first?.draft, view.savedDraft)
        let previous = view.savedDraft
        try await model.store?.put(DraftRecord(id: view.id, text: "The other instance changed again"), kind: "draft", id: view.id)
        view.draft = "New conflict episode"; try? await model.flushDrafts()
        copies = try await model.store?.draftConflicts(id: view.id) ?? []
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.contains { $0.id == first.id && $0.draft == previous })
        XCTAssertTrue(copies.contains { $0.id != first.id && $0.draft == view.savedDraft })
    }

    func testConflictRestorationKeepsAPausedQueueAndAllowsTheNextFlush() async throws {
        let (first, a, model, view) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        view.draft = "Saved losing input"; try? await model.flushDrafts()
        let copies = try await model.store?.draftConflicts(id: view.id) ?? []
        let conflict = try XCTUnwrap(copies.first)
        view.draft = "Current unsaved input"
        view.state = "paused"; view.queuePaused = true
        view.queue = [["turnId": .string("queued"), "text": .string("Retained follow-up")]]; view.queueCount = 1
        let queue = view.queue
        XCTAssertTrue(view.hasWork); XCTAssertFalse(view.busy)
        model.restoreConflictedDraft(conflict)
        await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, conflict.draft.text, "A paused queue must not block replacing the composer")
        XCTAssertEqual(view.queue, queue); XCTAssertEqual(view.queueCount, 1); XCTAssertTrue(view.queuePaused)
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, conflict.draft.text)
    }

    func testAnEpisodeTracksTheLatestDraftEvenWhenItReturnsToTheLoadedBaseline() async throws {
        let (first, a, model, view) = try await fixture()
        a.draft = "Winning draft"; try await first.flushDrafts()
        view.draft = "Losing text"; try? await model.flushDrafts()
        let original = try await model.store?.draftConflicts(id: view.id).first
        view.draft = ""; try? await model.flushDrafts()
        let copies = try await model.store?.draftConflicts(id: view.id) ?? []
        XCTAssertEqual(copies.count, 1); XCTAssertEqual(copies.first?.id, original?.id)
        XCTAssertEqual(copies.first?.draft.text, "", "The existing episode must follow an intentional clear too")
    }

    func testConflictRestorationDoesNotReplaceAnActiveSendOrEdit() async throws {
        let states: [(String, (SessionDisplay) -> Void)] = [
            ("send preparation", { $0.loading = true }), ("running", { $0.state = "running" }), ("resume", { $0.resuming = true }),
            ("message edit", { $0.editingMessageID = "message" }), ("edit preparation", { $0.editPreparing = true }),
            ("edit submission", { $0.editSubmitting = true }), ("queue edit", { $0.queueEditingID = "turn" }),
            ("queue begin", { $0.queueEditBeginning = "edit" }), ("queue cancel", { $0.queueEditCancelling = "edit" }),
        ]
        for (name, prepare) in states {
            let (first, a, model, view) = try await fixture()
            a.draft = "Winning draft"; try await first.flushDrafts()
            view.draft = "Losing text"; try? await model.flushDrafts()
            let copies = try await model.store?.draftConflicts(id: view.id) ?? []
            let conflict = try XCTUnwrap(copies.first)
            view.draft = "Active input"; prepare(view)
            model.restoreConflictedDraft(conflict)
            XCTAssertNil(model.draftWrites.recoveries[view.id], name)
            XCTAssertEqual(view.draft, "Active input", name)
        }
    }

    func testFailedEpisodeUpdateKeepsItsPinAndRetriesTheSameCopy() async throws {
        let (model, view, _) = try await conflicted()
        let original = try await model.store?.draftConflicts(id: view.id).first
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_conflict BEFORE INSERT ON records WHEN NEW.kind LIKE 'draft-conflict:%' BEGIN SELECT RAISE(ABORT, 'generated update failure'); END", nil, nil, nil), SQLITE_OK)
        view.draft = "Latest losing text"; try? await model.flushDrafts()
        XCTAssertTrue(view.draftVersion.hasUnsavedConflict)
        let held = try await model.store?.draftConflicts(id: view.id)
        XCTAssertEqual(held?.first, original, "The previously durable copy remains until its replacement commits")
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_conflict", nil, nil, nil), SQLITE_OK)
        try? await model.flushDrafts()
        let copies = try await model.store?.draftConflicts(id: view.id) ?? []
        XCTAssertEqual(copies.count, 1); XCTAssertEqual(copies.first?.id, original?.id)
        XCTAssertEqual(copies.first?.draft, view.savedDraft); XCTAssertFalse(view.draftVersion.hasUnsavedConflict)
    }

    func testRecoveryChooserCanRestoreTheOldestOfManyCopiesWithAPausedQueue() async throws {
        let (model, view, _, _) = try await fixture()
        for index in 0..<40 { try await model.store?.put(DraftRecord(id: view.id, text: "Copy \(index)"), kind: "draft-conflict:" + view.id, id: "copy-\(index)") }
        let copies = try await model.store?.draftConflicts(id: view.id) ?? []
        let oldest = try XCTUnwrap(copies.last)
        view.state = "paused"; view.queuePaused = true; view.queueCount = 1
        view.queue = [["turnId": .string("follow-up"), "text": .string("Retained")]]
        let banner = RecoveredBannerView(); banner.update([], conflicts: copies, model: model)
        let chooser = try XCTUnwrap(ConversationPaneTests.views(PiKit.MenuButton.self, in: banner).first)
        let menu = PiMenus.menu(chooser.entries())
        XCTAssertTrue(PiMenus.perform("restore-conflict-" + oldest.id, in: menu))
        await model.draftWrites.recoveries[view.id]?.value
        XCTAssertEqual(view.draft, oldest.draft.text); XCTAssertEqual(view.queue.count, 1); XCTAssertTrue(view.queuePaused)
        let remaining = try await model.store?.draftConflicts(id: view.id) ?? []
        XCTAssertFalse(remaining.contains { $0.id == oldest.id }); XCTAssertGreaterThanOrEqual(remaining.count, 39)
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

    func testFlushDrainsACapturedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: true) }
    func testDebounceSupersedesACapturedWriteBeforeSkippingAnUnchangedDraft() async throws { try await admittedWrite(flush: false) }

    private func admittedWrite(flush: Bool) async throws {
        let (model, view, _, _) = try await fixture()
        let store = try XCTUnwrap(model.store), gate = AsyncGate(), token = UUID()
        let write = store.draftWriter.capture(view.id)
        // Capture the older snapshot before its suspension, just as every
        // asynchronous producer does. Task cancellation alone cannot stop
        // this fixture; the store must reject its superseded ticket.
        let admitted = Task {
            defer { if model.draftWrites.tokens[view.id] == token { model.draftWrites.tasks[view.id] = nil; model.draftWrites.tokens[view.id] = nil } }
            await gate.wait()
            try? await store.put(DraftRecord(id: view.id, text: "Older queued write"), kind: "draft", id: view.id, draftVersion: view.draftVersion, write: write)
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

    func testStorageFailuresLeaveDraftBaselinesAtTheDurableRevision() async throws {
        for operation in ["snapshot", "submission", "withdrawal", "review", "restore", "registration"] {
            let (model, view, _, _) = try await fixture(), store = try XCTUnwrap(model.store)
            view.draft = "Saved input"; try await model.flushDrafts()
            let before = view.draftVersion.snapshot, changed = DraftRecord(id: view.id, text: "Changed input")
            let intent = CommandIntent(id: "captured", sessionID: view.id, turnID: "turn", text: "Captured input", state: "intent")
            let conflict = SavedDraftConflict(id: "copy", draft: changed)
            let chat = try XCTUnwrap(model.chats.first)
            try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
            try await store.put(changed, kind: "draft-conflict:" + view.id, id: conflict.id)
            try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: view.id)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let deletion = operation == "withdrawal" || operation == "restore"
            let kind = operation == "registration" ? SideKeepRegistration.kind
                : operation == "restore" ? "draft-conflict:" + view.id
                : ["submission", "withdrawal"].contains(operation) ? "pending:" + view.id : "draft"
            let event = deletion ? "DELETE" : "INSERT", row = deletion ? "OLD" : "NEW"
            XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_operation BEFORE \(event) ON records WHEN \(row).kind='\(kind)' BEGIN SELECT RAISE(ABORT, 'generated transaction failure'); END", nil, nil, nil), SQLITE_OK)
            func write() async throws {
                switch operation {
                case "snapshot": try await store.put(changed, kind: "draft", id: view.id, draftVersion: view.draftVersion)
                case "submission": try await store.recordSubmission(intent, draft: changed, draftVersion: view.draftVersion)
                case "withdrawal": try await store.withdrawSubmission(sessionID: view.id, commandID: intent.id, draft: changed, draftVersion: view.draftVersion)
                case "review": try await store.preserveSubmissionReviews(sessionID: view.id, commands: [intent.id], draftVersion: view.draftVersion)
                case "restore": try await store.restoreConflict(conflict, replacing: changed, version: view.draftVersion)
                default: _ = try await store.commitKeptSide(chat, draft: changed, expected: chat, draftVersion: view.draftVersion)
                }
            }
            do { try await write(); XCTFail(operation + " must fail at the injected storage operation") }
            catch { XCTAssertEqual(error as? StoreError, .unavailable, operation) }
            let durable = try await store.draftVersion(id: view.id).snapshot
            XCTAssertEqual(durable.revision, before.revision, operation)
            XCTAssertEqual(durable.draft, before.draft, operation)
            XCTAssertEqual(view.draftVersion.snapshot.revision, durable.revision, operation)
            XCTAssertEqual(view.draftVersion.snapshot.draft, durable.draft, operation)
            XCTAssertFalse(view.draftVersion.hasUnsavedConflict, "A storage failure is not another instance's edit")
            let retained = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
            let copies = try await store.draftConflicts(id: view.id)
            let keep = try await store.get(SideKeepIntent.self, kind: "side-keep", id: view.id)
            XCTAssertNotNil(retained, operation); XCTAssertEqual(copies, [conflict], operation); XCTAssertNotNil(keep, operation)
            XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_operation", nil, nil, nil), SQLITE_OK)
            try await write()
            let retried = try await store.draftVersion(id: view.id).snapshot
            XCTAssertEqual(view.draftVersion.snapshot.revision, retried.revision, operation)
            XCTAssertEqual(view.draftVersion.snapshot.draft, retried.draft, operation)
            XCTAssertNotEqual(retried.revision, before.revision, operation)
        }
    }

    func testStorageFailuresLeaveAnchorBaselinesAtTheDurableRevision() async throws {
        for clearing in [false, true] {
            let (model, view, _, _) = try await fixture(), store = try XCTUnwrap(model.store)
            let first = TranscriptAnchor(id: "first", offset: 12, followsBottom: false)
            try await store.putAnchor(first, id: view.id, version: view.anchorVersion)
            if !clearing { try await store.putAnchor(nil, id: view.id, version: view.anchorVersion) }
            let before = view.anchorVersion.snapshot
            let next = clearing ? nil : TranscriptAnchor(id: "next", offset: 34, followsBottom: false)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let kind = clearing ? "anchor" : "anchor-deleted"
            XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_anchor BEFORE DELETE ON records WHEN OLD.kind='\(kind)' BEGIN SELECT RAISE(ABORT, 'generated anchor failure'); END", nil, nil, nil), SQLITE_OK)
            do { try await store.putAnchor(next, id: view.id, version: view.anchorVersion); XCTFail("Must roll back both anchor rows") }
            catch { XCTAssertEqual(error as? StoreError, .unavailable) }
            let durable = try await store.anchorVersion(id: view.id).snapshot
            XCTAssertEqual(durable.revision, before.revision); XCTAssertEqual(durable.anchor, before.anchor)
            XCTAssertEqual(view.anchorVersion.snapshot.revision, durable.revision)
            XCTAssertEqual(view.anchorVersion.snapshot.anchor, durable.anchor)
            XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_anchor", nil, nil, nil), SQLITE_OK)
            try await store.putAnchor(next, id: view.id, version: view.anchorVersion)
            let retried = try await store.anchorVersion(id: view.id).snapshot
            XCTAssertEqual(retried.anchor, next); XCTAssertNotEqual(retried.revision, before.revision)
            XCTAssertEqual(view.anchorVersion.snapshot.revision, retried.revision)
        }
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
