import XCTest
@testable import PiApp

final class SendBookkeepingTests: XCTestCase {
    @MainActor func testAcknowledgementFailureAfterAcceptanceDoesNotFailTheSend() async throws { try await localFailure(at: "submitted", kind: "pending:chat") }
    @MainActor func testTitleFailureAfterAcceptanceDoesNotFailTheSend() async throws { try await localFailure(at: "acknowledged", kind: "chat") }
    @MainActor func testLostSubmitReplyReturnsDraftWithADurableReviewGate() async throws { try await localFailure(at: "lost", kind: "") }

    @MainActor private func localFailure(at step: String, kind: String) async throws {
        let root = scratchRoot("send-bookkeeping")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: ChatRecord.defaultTitle, path: nil, profileID: "p")
        let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(chat.id)
        var injected = false
        model.sendSteps = { current in
            guard current == step else { return }
            do {
                try RecoveredDraftTests.sql("CREATE TRIGGER refuse_bookkeeping BEFORE UPDATE ON records WHEN OLD.kind='\(kind)' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: root)
                injected = true
            } catch { XCTFail("Could not inject the bookkeeping failure: \(error)") }
        }
        view.draft = "Accepted message"; model.send(sessionID: chat.id)
        try await eventually("submission dispatched") { frames.contains { $0["method"]?.string == "turn.submit" } }
        let frame = try XCTUnwrap(frames.first { $0["method"]?.string == "turn.submit" })
        view.draft = "Newer typing"
        let pending = try await model.store?.get(CommandIntent.self, kind: "pending:chat", id: try XCTUnwrap(frame["commandId"]?.string))
        view.recovered = [try XCTUnwrap(pending)]; view.uncertain = true
        if step == "lost" {
            host.receive(.failed("Fixture lost reply"), connectionID: try XCTUnwrap(host.connectionID))
            try await eventually("failed submit returned") { !view.loading }
            let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.text, "Accepted message\n\nNewer typing")
            XCTAssertEqual(saved?.submissionReviews, [try XCTUnwrap(pending?.id)])
            view.uncertain = false; view.recovered = []
            var asked = 0; model.questions.answer = { _ in asked += 1; return false }
            model.send(sessionID: view.id); XCTAssertEqual(asked, 1)
            try await host.shutdownAndWait(); return
        }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                             "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true), "queued": .bool(false)])]),
                     connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("local bookkeeping finished") { !view.loading }
        XCTAssertTrue(injected); XCTAssertNotNil(model.error)
        XCTAssertNil(view.sendFailure); XCTAssertFalse(view.uncertain); XCTAssertEqual(view.runState, .running)
        XCTAssertEqual(view.draft, "Newer typing"); XCTAssertEqual(view.sendingRows.map(\.text), ["Accepted message"])
        XCTAssertEqual(model.chats.first?.title, "Accepted message")
        XCTAssertTrue(view.recovered.isEmpty)
        XCTAssertTrue(view.submissionReviews.isEmpty, "A known successful reply does not gate newer typing")
        model.sendSteps = nil
        try RecoveredDraftTests.sql("DROP TRIGGER refuse_bookkeeping", root: root)
        try await host.shutdownAndWait()
    }

    @MainActor func testLaunchNeverOffersAlreadyAcceptedCommandsAsRecoveredDuplicates() async throws {
        for evidence in ["acknowledged", "queued", "dispatched", "user-row", "branch", "delivering", "unsent"] {
            let root = scratchRoot("received-" + evidence)
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("chat.jsonl")
            let intent = CommandIntent(id: "command", sessionID: "chat", turnID: "sent-turn", text: "Already received", state: evidence == "acknowledged" ? "acknowledged" : "intent")
            var rows: [[String: WireValue]] = [["type": .string("session"), "version": .number(3), "id": .string("chat")],
                                               ["type": .string("custom"), "customType": .string("pi-app.native.v1"), "id": .string("native")]]
            let receipt: WireValue = .object(["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string(evidence)])
            if evidence == "queued" || evidence == "dispatched" {
                rows.append(["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "id": .string("accepted"),
                             "data": .object(["commands": .array([receipt]), "commandsDelta": .bool(true)])])
            } else if evidence == "user-row" {
                rows.append(["type": .string("message"), "id": .string(intent.turnID), "message": .object(["role": .string("user"), "content": .string(intent.text)])])
            } else if evidence == "delivering" {
                rows.append(["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "id": .string("delivering"),
                             "data": .object(["delivering": .object(["lane": .string("follow-up"), "submission": .object(["commandID": .string(intent.id), "turnID": .string(intent.turnID)])])])])
            } else if evidence == "branch" {
                rows.append(["type": .string("custom"), "id": .string("branch"), "nativeState": .object(["queue": .array([.object(["commandID": .string(intent.id), "turnID": .string(intent.turnID)])])])])
            }
            // Evidence far behind the loaded page still counts, including a
            // receipt that fell out of the helper's latest 128 receipts.
            for n in 0..<510 { rows.append(["type": .string("message"), "id": .string("m\(n)"), "message": .object(["role": .string("user"), "content": .string("Later")])]) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var bytes = Data(), parent: String?
            for var row in rows { row["parentId"] = parent.map(WireValue.string) ?? .null; bytes.append(try encoder.encode(row)); bytes.append(10); parent = row["id"]?.string }
            try bytes.write(to: path)
            let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: path.path, profileID: "p")
            model.chats = [chat]
            try await model.store?.recordSubmission(intent, draft: DraftRecord(id: chat.id, text: ""))
            await model.select(chat.id)
            let view = try XCTUnwrap(model.displays[chat.id])
            XCTAssertEqual(view.recovered.map(\.id), evidence == "unsent" ? [intent.id] : [], evidence)
            XCTAssertEqual(view.draft, "", evidence)
            XCTAssertTrue(model.hosts.isEmpty, "Launch recovery only reads the generated journal")
        }
    }
}

extension SendBookkeepingTests {
    @MainActor func testRestoredDraftCannotSendWhileAcceptanceIsBeingRead() async throws { try await acceptanceReadGate(fails: false) }
    @MainActor func testFailedAcceptanceReadKeepsSubmissionBlockedUntilRetry() async throws { try await acceptanceReadGate(fails: true) }
    @MainActor private func acceptanceReadGate(fails: Bool) async throws {
        for mode in ["chat", "edit", "side"] {
            let root = scratchRoot("acceptance-gate-" + mode)
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            let store = try XCTUnwrap(model.store), path = root.appendingPathComponent("chat.jsonl")
            try await store.open()
            try Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat\"}\n{\"type\":\"message\",\"id\":\"turn\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"Returned\"}}\n".utf8).write(to: path)
            var chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: path.path, profileID: "p")
            if mode == "side" { chat.parentSessionID = "parent" }
            model.chats = [chat, ChatRecord(id: "parent", workspaceID: "w", title: "Parent", profileID: "p")]
            let intent = CommandIntent(id: "command", sessionID: chat.id, turnID: "turn", text: "Returned", state: "intent")
            var draft = DraftRecord(id: chat.id, text: "Returned\n\nNew typing")
            if mode == "edit" { draft.edit = MessageEditDraft(messageID: "earlier", originalText: "Parked") }
            try await store.recordSubmission(intent, draft: draft)
            var release: CheckedContinuation<Void, Never>?
            model.commandAcceptanceRead = { _, intents, _ in
                guard !intents.isEmpty else { return [] }
                await withCheckedContinuation { release = $0 }
                if fails { throw StoreError.unreadableRecord }
                return [intent.id]
            }
            let selection = Task { if mode == "side" { await model.showSide(chat.id) } else { await model.select(chat.id) } }
            try await eventually("acceptance read held") { release != nil }
            let view = try XCTUnwrap(model.displays[chat.id])
            XCTAssertFalse(view.draftReady, mode)
            var steps: [String] = []; model.sendSteps = { steps.append($0) }; model.questions.answer = { _ in false }
            model.submitComposer(intent: .followUp, sessionID: chat.id)
            model.send(sessionID: chat.id); if mode == "edit" { model.sendEdit(sessionID: chat.id) }
            XCTAssertFalse(view.loading, "\(mode): all submission entry points must wait for reconciliation")
            XCTAssertTrue(steps.isEmpty, mode)
            try await eventually("blocked send settled") { !view.loading }
            release?.resume(); await selection.value
            if fails {
                XCTAssertFalse(view.draftReady, "An unreadable acceptance record does not authorize a resend")
                steps = []; model.send(sessionID: chat.id); XCTAssertFalse(view.loading); XCTAssertTrue(steps.isEmpty)
                try await eventually("failed read send settled") { !view.loading }
                model.commandAcceptanceRead = nil; model.reloadHistory(chat.id)
                try await eventually("Retry reconciled the draft") { view.draftReady }
            } else { XCTAssertTrue(view.draftReady) }
            XCTAssertEqual(view.draft, draft.text); XCTAssertTrue(view.submissionReviews.contains(intent.id))
        }
    }
    @MainActor func testReturnedSideDraftKeepsItsReviewThroughParkedEditsAndPersistence() async throws {
        for editor in ["none", "historical", "queued"] {
            let root = scratchRoot("review-side-" + editor)
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            let parent = SessionDisplay(id: "parent"), side = SessionDisplay(id: "side")
            parent.selectionMetadataLoaded = true; parent.draft = "Parent"
            if editor == "historical" { parent.draftBeforeEdit = parent.savedDraft; parent.editingMessageID = "earlier"; parent.draft = "Edit" }
            if editor == "queued" { parent.draftBeforeQueueEdit = parent.savedDraft; parent.queueEditingID = "queued"; parent.draft = "Rewrite" }
            side.draft = "Returned"; side.submissionReviews = ["command"]
            let info = SideRecord(id: side.id, parentID: parent.id, workspaceID: "w", profileID: "p", title: "Side", kept: false)
            model.displays = [parent.id: parent, side.id: side]; model.sides[parent.id] = info
            XCTAssertTrue(model.moveSideDraftHere(info)); XCTAssertTrue(side.submissionReviews.isEmpty)
            let saved = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(parent.savedDraft)).displaced
            XCTAssertEqual(saved.text, "Parent\n\nReturned", editor); XCTAssertEqual(saved.submissionReviews, ["command"], editor)
        }
    }
    @MainActor func testReviewPersistenceCannotSupersedeNewerTyping() async throws {
        let root = scratchRoot("review-typing")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let store = try XCTUnwrap(model.store)
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.draft = "Returned"; view.selectionMetadataLoaded = true; model.displays[view.id] = view
        let intent = CommandIntent(id: "command", sessionID: view.id, turnID: "turn", text: "Returned", state: "intent")
        try await store.recordSubmission(intent, draft: view.savedDraft); view.acceptedCommands.insert(intent.id)
        var release: CheckedContinuation<Void, Never>?
        let oldWrite = Task { await withCheckedContinuation { release = $0 } }
        model.draftWrites.tasks[view.id] = oldWrite
        try await eventually("old draft write held") { release != nil }
        let protection = Task { try await model.protectReturnedDrafts([intent], view: view) }
        try await eventually("returned draft protected") { !view.submissionReviews.isEmpty }
        view.draft += "\n\nNewer typing"
        let typed = view.savedDraft, revision = try await store.reserveRevision(kind: "draft", id: view.id)
        var releaseTyping: CheckedContinuation<Void, Never>?
        let typing = Task {
            await withCheckedContinuation { releaseTyping = $0 }
            try? await store.put(typed, kind: "draft", id: view.id, revision: revision)
        }
        model.draftWrites.tasks[view.id] = typing
        try await eventually("new typing reserved") { releaseTyping != nil }
        release?.resume(); try await protection.value
        releaseTyping?.resume(); await typing.value
        await model.draftWrites.tasks[view.id]?.value
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, typed.text); XCTAssertEqual(saved?.submissionReviews, [intent.id])
    }
    @MainActor func testEditPreparationCannotDiscardAReviewAddedWhileItWaited() async throws {
        let root = scratchRoot("review-edit")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.draft = "Returned"; model.displays[view.id] = view
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "Fixture", profileID: "p")]
        var release: CheckedContinuation<Void, Never>?
        model.editTargetRead = { _, id in
            await withCheckedContinuation { release = $0 }
            return ["messageId": .string(id), "text": .string("Earlier message")]
        }
        model.editMessage("old", sessionID: view.id)
        try await eventually("edit read held") { release != nil }
        view.submissionReviews.insert("command"); release?.resume()
        try await eventually("edit read finished") { !view.editPreparing }
        XCTAssertTrue(view.submissionReviews.contains("command") || view.draftBeforeEdit?.submissionReviews?.contains("command") == true,
                      "Loading an edit must preserve a review gate added during its read")
    }
    @MainActor func testReviewApprovalDoesNotApplyToTypingChangedWhileTheQuestionWasOpen() async throws {
        let root = scratchRoot("review-question")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.draft = "Returned"; view.submissionReviews = ["command"]; model.displays[view.id] = view
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "Fixture", profileID: "p")]
        var steps: [String] = []
        model.sendSteps = { steps.append($0) }; model.questions.answer = { _ in view.draft += "\nNew typing"; return true }
        model.send(sessionID: view.id)
        XCTAssertTrue(steps.isEmpty); XCTAssertEqual(view.submissionReviews, ["command"]); XCTAssertTrue(view.notice.contains("changed"))
    }
    @MainActor func testAnAcceptedLostReplyKeepsReturnedTextBehindReviewAcrossRelaunch() async throws {
        let root = scratchRoot("returned-send")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("chat.jsonl")
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat\"}\n{\"type\":\"message\",\"id\":\"turn\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"Do the work\"}}\n".utf8).write(to: path)
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: path.path, profileID: "p")
        let intent = CommandIntent(id: "command", sessionID: chat.id, turnID: "turn", text: "Do the work", state: "intent")
        let returned = "Do the work\n\nNewer typing that must stay"
        let store = try XCTUnwrap(model.store)
        try await store.recordSubmission(intent, draft: DraftRecord(id: chat.id, text: returned))
        model.chats = [chat]; await model.select(chat.id)
        let view = try XCTUnwrap(model.displays[chat.id])
        var asked: [ChatQuestion] = [], steps: [String] = []
        model.questions.answer = { asked.append($0); return false }; model.sendSteps = { steps.append($0) }
        model.send(sessionID: chat.id)
        XCTAssertEqual(asked.count, 1, "Proving acceptance must not silently authorize the returned copy")
        XCTAssertTrue(steps.isEmpty, "No new submission starts before review")
        XCTAssertEqual(view.draft, returned, "Ambiguous returned text and newer typing are both preserved")
        XCTAssertTrue(view.recovered.isEmpty, "An accepted message is never offered for Insert again")
        try await eventually("send settled") { !view.loading }
        try await model.flushDrafts()
        try await store.remove(kind: "pending:chat", id: intent.id)
        model.displays.removeAll(); model.selectedID = nil; await model.select(chat.id)
        let reopened = try XCTUnwrap(model.displays[chat.id])
        asked = []; steps = []; model.send(sessionID: chat.id)
        XCTAssertEqual(asked.count, 1, "The review gate survives even after the accepted intent is retired")
        XCTAssertTrue(steps.isEmpty); XCTAssertEqual(reopened.draft, returned)
        try await eventually("reopened send settled") { !reopened.loading }
    }
}
