import XCTest
@testable import PiApp

final class DraftBaselineGate: @unchecked Sendable {
    let entered: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() { entered.fulfill(); resume.wait() }
}

extension HistoryReader {
    func holdDraftBaseline(_ gate: DraftBaselineGate) { gate.hold() }
}

extension MetadataStore {
    func holdDraftBaseline(_ gate: DraftBaselineGate) { gate.hold() }
}

final class DraftLoadingTests: XCTestCase {
    @MainActor private func fixture() async throws -> WorkspaceModel {
        let root = scratchRoot("draft-loading")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.prewarmsHelpers = false
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        try await model.reloadConfiguration()
        for id in ["parent", "side"] {
            let path = root.appendingPathComponent(id + ".jsonl")
            try Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\"}\n".utf8).write(to: path)
            var chat = ChatRecord(id: id, workspaceID: "project", title: id, path: path.path, profileID: "profile")
            if id == "side" { chat.parentSessionID = "parent" }
            model.chats.append(chat)
            try await model.store?.put(chat, kind: "chat", id: id)
            try await model.store?.put(DraftRecord(id: id, text: ""), kind: "draft", id: id)
            try await model.store?.put(TranscriptAnchor(id: "saved", offset: 17, followsBottom: false), kind: "anchor", id: id)
        }
        return model
    }

    @MainActor private func assertSaved(_ model: WorkspaceModel, view: SessionDisplay, text: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        await model.draftWrites.tasks[view.id]?.value; await view.anchorWrite?.value
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        let anchor = try await model.store?.get(TranscriptAnchor.self, kind: "anchor", id: view.id)
        let conflicts = try await model.store?.draftConflicts(id: view.id)
        XCTAssertEqual(draft?.text, text, file: file, line: line)
        XCTAssertNil(anchor, "Returning to latest before loading must remain cleared", file: file, line: line)
        XCTAssertEqual(conflicts, [], "One instance must not manufacture a conflict", file: file, line: line)
        XCTAssertTrue(view.draftConflicts.isEmpty, file: file, line: line)
        XCTAssertFalse(model.draftWrites.failed, file: file, line: line)
    }

    @MainActor private func typingDuringLoad(_ route: String) async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        if route == "side" { await model.select("parent") }
        let gate = DraftBaselineGate(expectation(description: "Initial history read held"))
        let blocker = Task { await model.history.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        let id = route == "side" ? "side" : "parent"
        let loading = Task {
            if route == "side" { await model.showSide("side") }
            else if route == "relaunch" {
                _ = await model.reopenRememberedSelection(.init(chatID: id), unlessSelectedSince: model.selectionRevision)
            } else { await model.select(id) }
        }
        try await eventually("Pending draft fixture did not settle") { model.displays[id] != nil }
        let view = try XCTUnwrap(model.displays[id])
        XCTAssertFalse(view.selectionMetadataLoaded)
        view.draft = "Typed during \(route)"; model.draftChanged(view)
        view.scrollAnchor = nil; model.anchorChanged(view)
        await model.draftWrites.tasks[id]?.value; await view.anchorWrite?.value
        let before = try await store.draftConflicts(id: id)
        XCTAssertTrue(before.isEmpty, "Typing while the baseline is pending is not a conflict")
        XCTAssertNil(model.draftWrites.tasks[id])
        gate.resume.signal(); await blocker.value; await loading.value
        XCTAssertTrue(view.selectionMetadataLoaded)
        try await assertSaved(model, view: view, text: "Typed during \(route)")
    }

    @MainActor func testColdOpenTypingWaitsForBaselineAndReschedules() async throws { try await typingDuringLoad("cold") }
    @MainActor func testSavedSideTypingWaitsForBaselineAndReschedules() async throws { try await typingDuringLoad("side") }
    @MainActor func testRelaunchSelectionTypingWaitsForBaselineAndReschedules() async throws { try await typingDuringLoad("relaunch") }

    @MainActor func testFlushLoadsBaselineForTypingAfterNavigationRetiresTheRead() async throws {
        let model = try await fixture()
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        // This is the retained display after the reader left before hydration.
        view.draft = "Typed before leaving"; model.draftChanged(view)
        view.scrollAnchor = nil; model.anchorChanged(view)
        try await model.flushDrafts()
        try await assertSaved(model, view: view, text: "Typed before leaving")
    }

    @MainActor func testSideCloseLoadsBaselineForTypingBeforeHydration() async throws {
        let model = try await fixture()
        let child = try XCTUnwrap(model.record("side"))
        let view = model.mountSide(child, beside: "parent")
        view.draft = "Typed before closing"; model.draftChanged(view)
        view.scrollAnchor = nil; model.anchorChanged(view)
        model.closeSide(view.id)
        try await eventually("Pending draft fixture did not settle") { !view.loading }
        XCTAssertNil(model.sides["parent"])
        try await assertSaved(model, view: view, text: "Typed before closing")
    }

    @MainActor func testReceiptProtectionLoadsBaselineBeforeMarkingPendingTyping() async throws {
        let model = try await fixture()
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        view.draft = "Typing before receipt reconciliation"; model.draftChanged(view)
        let intent = CommandIntent(id: "legacy", sessionID: view.id, turnID: "turn", text: "Earlier input", state: "acknowledged")
        try await model.protectReturnedDrafts([intent], view: view)
        await model.draftWrites.tasks[view.id]?.value
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        let copies = try await model.store?.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, view.draft); XCTAssertEqual(saved?.submissionReviews, ["legacy"])
        XCTAssertEqual(copies, [])
    }

    @MainActor func testSideRegistrationLoadsBaselineBeforeSavingPendingTyping() async throws {
        let model = try await fixture(), child = try XCTUnwrap(model.record("side"))
        let view = SessionDisplay(id: child.id); model.displays[view.id] = view
        try await model.store?.put(SideKeepIntent(chat: child), kind: "side-keep", id: child.id)
        view.draft = "Typing before side registration"; model.draftChanged(view)
        try await model.registerKeptSide(id: child.id, path: child.path)
        await model.draftWrites.tasks[view.id]?.value
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        let copies = try await model.store?.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, view.draft); XCTAssertEqual(copies, [])
    }

    @MainActor func testDraftTransferJoinsTypingBeforeParentBaselineLoads() async throws {
        let model = try await fixture()
        let gate = DraftBaselineGate(expectation(description: "Parent read held"))
        let blocker = Task { await model.history.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        let loading = Task { await model.select("parent") }
        try await eventually("Pending draft fixture did not settle") { model.displays["parent"] != nil }
        let parent = try XCTUnwrap(model.displays["parent"])
        parent.draft = "Parent typing"; model.draftChanged(parent)
        parent.scrollAnchor = nil; model.anchorChanged(parent)
        let side = SessionDisplay(id: "new-side"); side.draft = "Side input"
        var info = SideRecord(id: side.id, parentID: parent.id, workspaceID: "project", profileID: "profile", title: "Side")
        info.pending = true; model.sides[parent.id] = info; model.displays[side.id] = side
        try await model.moveSideDraft(info)
        gate.resume.signal(); await blocker.value; await loading.value
        await model.draftWrites.tasks[parent.id]?.value
        XCTAssertTrue(parent.draft.contains("Parent typing"))
        XCTAssertTrue(parent.draft.contains("Side input"), "Transfer must not disappear behind the typed composer")
        XCTAssertTrue(side.draft.isEmpty)
        try await assertSaved(model, view: parent, text: parent.draft)
    }

    @MainActor func testClearingPendingTypingPinsTheDisplayUntilFlushLoadsItsBaseline() async throws {
        let model = try await fixture()
        try await model.store?.put(DraftRecord(id: "parent", text: "Previously saved"), kind: "draft", id: "parent")
        let view = SessionDisplay(id: "parent"); view.used = .distantPast; model.displays[view.id] = view
        view.draft = "Typing"; model.draftChanged(view)
        view.draft = ""; model.draftChanged(view)
        for index in 0..<10 { model.displays["other-\(index)"] = SessionDisplay(id: "other-\(index)") }
        model.releaseUnreadDisplays(keeping: "other-9")
        XCTAssertTrue(model.displays[view.id] === view, "A pending clear is user input too")
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        let copies = try await model.store?.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, ""); XCTAssertEqual(copies, [])
    }

    @MainActor func testLateBaselineCannotReplaceTheVersionUsedForNewTyping() async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        // A navigation read answered before a flush, but returns to the main
        // actor after that flush already installed and advanced its baseline.
        let late = try await store.selectionMetadata(id: view.id, draft: true, anchor: true)
        let atStart = view.savedDraft
        try await model.loadDraftBaseline(view)
        view.draft = "First typing"; model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value
        let revision = view.draftVersion.snapshot.revision
        model.adoptDraftBaseline(late, into: view, draftAtStart: atStart)
        XCTAssertEqual(view.draftVersion.snapshot.revision, revision)
        view.draft = "Later typing"; model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let copies = try await store.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, view.draft); XCTAssertEqual(copies, [])
    }

    @MainActor func testPendingMaterializationInstallsBaselineBeforeItsFirstWrite() async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        try await store.remove(kind: "draft", id: "parent")
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view; model.pendingChatIDs.insert(view.id)
        let late = try await store.selectionMetadata(id: view.id, draft: true, anchor: true), atStart = view.savedDraft
        view.draft = "Typing before materialization"; model.draftChanged(view)
        try await model.materializeChat(view.id)
        XCTAssertTrue(view.selectionMetadataLoaded, "The initial nil revision must be installed before it advances")
        model.adoptDraftBaseline(late, into: view, draftAtStart: atStart)
        view.draft = "Typing after materialization"; model.draftChanged(view); await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let copies = try await store.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, view.draft); XCTAssertEqual(copies, [])
    }

    @MainActor func testReceiptRecoveryLoadsBaselineBeforeMergingPendingTyping() async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        let intent = CommandIntent(id: "recover", sessionID: view.id, turnID: "turn", text: "Interrupted input", state: "intent")
        try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
        view.draft = "Pending typing"; model.draftChanged(view)
        // A runtime snapshot can expose recovery before navigation hydrates.
        view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        await model.draftWrites.recoveries[view.id]?.value; await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
        let copies = try await store.draftConflicts(id: view.id)
        XCTAssertEqual(saved?.text, "Pending typing\n\nInterrupted input")
        XCTAssertNil(pending); XCTAssertEqual(copies, []); XCTAssertTrue(view.recovered.isEmpty)
    }

    @MainActor func testPendingPositionPinsAnOtherwiseEmptyDisplayUntilFlush() async throws {
        let model = try await fixture()
        let view = SessionDisplay(id: "parent"); view.used = .distantPast; model.displays[view.id] = view
        view.scrollAnchor = nil; model.anchorChanged(view)
        for index in 0..<10 { model.displays["other-\(index)"] = SessionDisplay(id: "other-\(index)") }
        model.releaseUnreadDisplays(keeping: "other-9")
        XCTAssertTrue(model.displays[view.id] === view)
        try await model.flushDrafts()
        let saved = try await model.store?.get(TranscriptAnchor.self, kind: "anchor", id: view.id)
        XCTAssertNil(saved)
    }

    @MainActor func testAcceptanceDuringRecoveryBaselineLoadStillRetiresTheInsert() async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        let intent = CommandIntent(id: "accepted", sessionID: view.id, turnID: "turn", text: "Already sent", state: "intent")
        try await store.put(intent, kind: "pending:" + view.id, id: intent.id)
        view.draft = "New typing"; model.draftChanged(view); view.recovered = [intent]
        let gate = DraftBaselineGate(expectation(description: "Recovery baseline held"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        model.recoverDraft(intent, insert: true)
        // The recovery task is suspended inside its initial metadata read.
        try await Task.sleep(for: .milliseconds(50))
        view.acceptedCommands.insert(intent.id)
        gate.resume.signal(); await blocker.value
        await model.draftWrites.recoveries[view.id]?.value; await model.draftWrites.tasks[view.id]?.value
        XCTAssertEqual(view.draft, "New typing")
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "New typing")
    }

    @MainActor func testRecoveryCannotReplaceAnEditRestoredByItsBaselineLoad() async throws {
        let model = try await fixture(), store = try XCTUnwrap(model.store)
        let view = SessionDisplay(id: "parent"); model.displays[view.id] = view
        let edit = DraftRecord(id: view.id, text: "Editing an earlier message",
                              edit: MessageEditDraft(messageID: "earlier", originalText: "Displaced draft"))
        try await store.put(edit, kind: "draft", id: view.id)
        let intent = CommandIntent(id: "recover", sessionID: view.id, turnID: "turn", text: "Interrupted input", state: "intent")
        try await store.put(intent, kind: "pending:" + view.id, id: intent.id); view.recovered = [intent]
        model.recoverDraft(intent, insert: true)
        await model.draftWrites.recoveries[view.id]?.value; await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        let pending = try await store.get(CommandIntent.self, kind: "pending:" + view.id, id: intent.id)
        XCTAssertEqual(saved?.text, edit.text); XCTAssertEqual(view.draft, edit.text)
        XCTAssertEqual(pending?.text, intent.text); XCTAssertEqual(view.editingMessageID, "earlier")
    }
}
