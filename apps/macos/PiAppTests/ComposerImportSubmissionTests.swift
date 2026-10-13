import AppKit
import XCTest
@testable import PiApp

final class ComposerImportSubmissionTests: XCTestCase {
    @MainActor func testReturnImmediatelyAfterPastingWaitsForTheImage() async throws { try await sendingDuringImport(paste: true) }
    @MainActor func testSendingImmediatelyAfterChoosingAFileWaitsForInspection() async throws { try await sendingDuringImport(paste: false) }
    @MainActor func testNewerTypingCancelsTheSendThatWaitedForAnImage() async throws { try await sendingDuringImport(paste: true, changeDraft: true) }
    @MainActor func testFailedImageInspectionDoesNotSendTextWithoutTheImage() async throws { try await sendingDuringImport(paste: true, invalidImage: true) }
    @MainActor func testResubmittingNewerTypingWhileImportingSendsTheUpdatedDraftOnce() async throws {
        try await sendingDuringImport(paste: true, changeDraft: true, resubmit: true)
    }
    @MainActor func testNavigationUnderCachePressureKeepsTheImportAndRequestedSend() async throws {
        try await sendingDuringImport(paste: true, navigate: true)
    }

    @MainActor private func sendingDuringImport(paste: Bool, changeDraft: Bool = false, invalidImage: Bool = false,
                                               resubmit: Bool = false, navigate: Bool = false) async throws {
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
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        var frames: [[String: WireValue]] = [], accepted = 0
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(chat.id)
        model.sendSteps = { if $0 == "accepted" { accepted += 1 } }
        view.draft = "Explain this image"
        let composer = ComposerInputView(model: model); composer.show(view)
        let editor = try XCTUnwrap(composer.field?.documentView as? ComposerTextView)
        let png = invalidImage ? Data([1, 2, 3]) : Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        // Keep the import pending across the asynchronous navigation read,
        // independently of how fast the actual paste conversion finishes.
        let heldImport = navigate ? model.beginImageImport(sessionID: view.id) : nil
        defer { heldImport?.finish(false) }
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
        XCTAssertEqual(accepted, 0, "Return must wait for the chosen image")
        XCTAssertEqual(view.draft, "Explain this image")
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
            XCTAssertTrue(heldImport?.isCurrent() == true)
            XCTAssertFalse(frames.contains { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == chat.id })
            guard model.displays[chat.id] === view else { try await host.shutdownAndWait(); return }
            heldImport?.finish(true)
        }
        if (changeDraft && !resubmit) || invalidImage {
            try await eventually("image import settled") { model.attachmentImports == 0 }
            XCTAssertEqual(accepted, 0)
            XCTAssertFalse(frames.contains { $0["method"]?.string == "turn.submit" })
            XCTAssertEqual(view.draft, changeDraft ? "Newer typing" : "Explain this image")
            XCTAssertEqual(view.attachments.count, invalidImage ? 0 : 1)
            XCTAssertNil(view.submissionAfterImages)
            XCTAssertFalse(view.notice.contains("Waiting for"))
            try await host.shutdownAndWait()
            return
        }
        try await eventually("submission and import finished") {
            guard let sent = frames.first(where: { $0["method"]?.string == "turn.submit" }) else { return false }
            return model.attachmentImports == 0 && (!(sent["params"]?.object?["attachments"]?.array ?? []).isEmpty || !view.attachments.isEmpty)
        }
        let frame = try XCTUnwrap(frames.first { $0["method"]?.string == "turn.submit" })
        XCTAssertEqual(frame["params"]?.object?["text"]?.string, changeDraft ? "Newer typing" : "Explain this image")
        let images = frame["params"]?.object?["attachments"]?.array ?? []
        XCTAssertEqual(images.count, 1); XCTAssertEqual(accepted, 1, "Repeated Return coalesces while importing")
        if let path = images.first?.object?["path"]?.string { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png) }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]), connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("send settled") { !view.loading }
        XCTAssertEqual(view.draft, ""); XCTAssertTrue(view.attachments.isEmpty, "The image must not spill into the next draft")
        try await host.shutdownAndWait()
    }
}
