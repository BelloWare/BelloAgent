import AppKit
import XCTest
@testable import PiApp

final class ComposerImportSubmissionTests: XCTestCase {
    @MainActor func testReturnDuringPasteRequiresAnotherSendAfterTheImageArrives() async throws { try await sendingDuringImport(paste: true) }
    @MainActor func testSendDuringFileInspectionRequiresAnotherPressAfterItFinishes() async throws { try await sendingDuringImport(paste: false) }
    @MainActor func testNewerTypingDuringImportStaysInTheSameDraft() async throws { try await sendingDuringImport(paste: true, changeDraft: true) }
    @MainActor func testFailedImageInspectionDoesNotSendTextWithoutTheImage() async throws { try await sendingDuringImport(paste: true, invalidImage: true) }
    @MainActor func testRepeatedSendWhileImportingNeverSubmitsAutomatically() async throws {
        try await sendingDuringImport(paste: true, changeDraft: true, resubmit: true)
    }
    @MainActor func testNavigationUnderCachePressureKeepsTheImageInTheOriginatingDraft() async throws {
        try await sendingDuringImport(paste: true, navigate: true)
    }
    @MainActor func testNavigationKeepsANewImageOnlyChatWhileItsImageIsImporting() async throws {
        try await sendingDuringImport(paste: true, navigate: true, newImageOnlyChat: true)
    }
    @MainActor func testHistoricalEditDuringImportNeedsAFreshSend() async throws {
        try await sendingDuringImport(paste: true, editing: true)
    }

    @MainActor func testSendAndInlineNoticeFollowAllPendingImportsWithoutChangingTheDraft() async throws {
        let root = scratchRoot("composer-import-lockout")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.draft = "Keep this draft"; model.displays[view.id] = view
        let composer = ComposerInputView(model: model); composer.show(view)
        XCTAssertTrue(composer.send.isEnabled)
        let first = model.beginImageImport(sessionID: view.id), second = model.beginImageImport(sessionID: view.id)
        defer { first.finish(); second.finish() }
        try await eventually("composer observes its imports") { !composer.send.isEnabled }
        let note = try XCTUnwrap(ConversationPaneTests.views(PiKit.Note.self, in: composer).first { !$0.isHidden })
        XCTAssertEqual(note.text, "Adding image… Send when it finishes")
        first.finish()
        composer.refresh()
        XCTAssertFalse(composer.send.isEnabled, "One image is still being prepared")
        XCTAssertFalse(note.isHidden)
        second.finish()
        try await eventually("composer unlocks after its last import, including failure") { composer.send.isEnabled && note.isHidden }
        XCTAssertEqual(view.draft, "Keep this draft"); XCTAssertTrue(view.attachments.isEmpty)
    }

    @MainActor private func sendingDuringImport(paste: Bool, changeDraft: Bool = false, invalidImage: Bool = false,
                                               resubmit: Bool = false, navigate: Bool = false, editing: Bool = false,
                                               newImageOnlyChat: Bool = false) async throws {
        let root = scratchRoot("composer-import-send")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        var chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p"); chat.titleWasEdited = true
        let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        if newImageOnlyChat { model.pendingChatIDs.insert(chat.id) }
        else { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        var frames: [[String: WireValue]] = [], accepted = 0
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(chat.id)
        model.sendSteps = { if $0 == "accepted" { accepted += 1 } }
        let originalDraft = newImageOnlyChat ? "" : "Explain this image"
        view.draft = originalDraft
        if editing {
            view.draftBeforeEdit = DraftRecord(id: chat.id, text: "Original unsent draft")
            view.editingMessageID = "old-turn"
        }
        let composer = ComposerInputView(model: model); composer.show(view)
        let editor = try XCTUnwrap(composer.field?.documentView as? ComposerTextView)
        let png = invalidImage ? Data([1, 2, 3]) : Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        // Keep the import pending across UI refreshes and navigation,
        // independently of how fast actual conversion and inspection finish.
        let heldImport = model.beginImageImport(sessionID: view.id)
        defer { heldImport.finish() }
        let board = NSPasteboard(name: .init("composer-import-" + UUID().uuidString)); defer { board.releaseGlobally() }
        if paste {
            board.setData(png, forType: .png)
            XCTAssertTrue(editor.pasteAttachments(from: board))
        } else {
            let file = root.appendingPathComponent("selected.png"); try png.write(to: file)
            model.attachImageFiles([file], sessionID: view.id)
        }
        // No actor suspension between paste/selection and Return: conversion
        // and inspection cannot have completed, regardless of machine speed.
        model.submitComposer(intent: .followUp, sessionID: view.id)
        model.submitComposer(intent: .followUp, sessionID: view.id)
        // Direct send paths (including an edit) must have the same lockout.
        if editing { model.sendEdit(sessionID: view.id) }
        else { model.send(sessionID: view.id) }
        XCTAssertEqual(accepted, 0, "Return during import does not submit")
        XCTAssertFalse(view.loading); XCTAssertFalse(view.editSubmitting)
        XCTAssertEqual(view.draft, originalDraft)
        composer.refresh()
        XCTAssertFalse(composer.send.isEnabled)
        XCTAssertTrue(ConversationPaneTests.views(PiKit.Note.self, in: composer).contains { !$0.isHidden && $0.text == "Adding image… Send when it finishes" })
        if changeDraft { view.draft = "Newer typing" }
        if resubmit {
            model.submitComposer(intent: .followUp, sessionID: view.id)
            model.submitComposer(intent: .followUp, sessionID: view.id)
        }
        if navigate {
            for n in 0..<8 {
                let other = ChatRecord(id: "other-\(n)", workspaceID: "w", title: "Other", profileID: "p")
                let display = SessionDisplay(id: other.id); display.resuming = true; display.selectionMetadataLoaded = true
                model.chats.append(other); model.displays[other.id] = display
            }
            await model.select("other-7", revealInSidebar: false, focusesComposer: false)
            XCTAssertEqual(model.selectedID, "other-7")
            XCTAssertTrue(model.displays[chat.id] === view, "The pending import must keep its originating composer alive")
            XCTAssertTrue(heldImport.isCurrent())
            XCTAssertFalse(frames.contains { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == chat.id })
            guard model.displays[chat.id] === view else { try await host.shutdownAndWait(); return }
        }
        try await eventually("actual image import settled") { model.attachmentImports == 1 }
        heldImport.finish()
        let draft = changeDraft ? "Newer typing" : originalDraft
        XCTAssertEqual(model.attachmentImports, 0)
        XCTAssertEqual(accepted, 0, "Finishing an import must never submit")
        XCTAssertFalse(view.loading); XCTAssertFalse(view.editSubmitting)
        XCTAssertEqual(view.draft, draft)
        XCTAssertEqual(view.attachments.count, invalidImage ? 0 : 1)
        XCTAssertFalse(frames.contains { ["turn.submit", "turn.edit"].contains($0["method"]?.string ?? "") })
        composer.refresh()
        XCTAssertTrue(composer.send.isEnabled, "Only a new press can send after import completion")
        XCTAssertFalse(ConversationPaneTests.views(PiKit.Note.self, in: composer).contains { !$0.isHidden })
        guard !invalidImage, !view.loading, !view.editSubmitting, view.draft == draft else { try await host.shutdownAndWait(); return }

        model.submitComposer(intent: .followUp, sessionID: view.id)
        let method = editing ? "turn.edit" : "turn.submit"
        try await eventually("fresh Send dispatched with the imported image") { frames.contains { $0["method"]?.string == method } }
        let frame = try XCTUnwrap(frames.first { $0["method"]?.string == method })
        XCTAssertEqual(frame["params"]?.object?["text"]?.string, draft)
        let images = frame["params"]?.object?["attachments"]?.array ?? []
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(frames.filter { $0["method"]?.string == method }.count, 1)
        if !editing { XCTAssertEqual(accepted, 1) }
        if let path = images.first?.object?["path"]?.string { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png) }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]), connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("send settled") { !view.loading && !view.editSubmitting }
        XCTAssertEqual(view.draft, editing ? "Original unsent draft" : ""); XCTAssertTrue(view.attachments.isEmpty, "The image must not spill into the next draft")
        try await host.shutdownAndWait()
    }
}
