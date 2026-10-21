import XCTest
import AppKit
@testable import PiApp

@MainActor final class ImportLifecycleTests: XCTestCase {
    private func fixture() throws -> (WorkspaceModel, SessionDisplay, URL) {
        let root = scratchRoot("import-lifecycle")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.prewarmsHelpers = false
        var profile = ProfileRecord(); profile.id = "p"; profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
        model.profiles = [profile]
        model.chats = [ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: profile.id)]
        let view = SessionDisplay(id: "chat"); view.selectionMetadataLoaded = true
        model.displays[view.id] = view
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7l8AAAAASUVORK5CYII=")!
        let image = try model.pastedImages.write(png)
        return (model, view, image)
    }

    func testQuitRefusesAnImageStillBeingInspectedThenFlushesIt() async throws {
        let (model, view, image) = try fixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.attachmentInspect = { url in entered.signal(); release.wait(); return try AttachmentRecord.inspect(url) }
        model.attachImageFiles([image], sessionID: view.id)
        try await eventually("inspection held") { entered.wait(timeout: .now()) == .success }
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(model.attachmentImports, 1)
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateCancel)
        // Waiting on a store operation also lets an incorrectly accepted Quit
        // finish its flush. The refusal itself must leave shutdown untouched.
        try await model.store?.put(true, kind: "fixture", id: "quit-check")
        XCTAssertFalse(model.installPreparing); XCTAssertFalse(answers.contains(true))
        release.signal()
        try await eventually("image inspection finished") { model.attachmentImports == 0 }
        XCTAssertEqual(view.attachments.map(\.path), [image.path])
        if model.isShutDown { XCTFail("Quit approved termination before the import finished"); return }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        try await eventually("quit answered") { answers.contains(true) }
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.attachments?.map(\.path), [image.path])
    }

    func testUpdateBarrierRefusesAnOutstandingImageImport() throws {
        let (model, view, _) = try fixture()
        let importing = model.beginImageImport(sessionID: view.id)
        XCTAssertFalse(model.acquireUpdateBarrier(), "An update must not flush before its image import finishes")
        importing.finish()
        XCTAssertTrue(model.acquireUpdateBarrier())
        model.releaseUpdateBarrier()
    }

    func testPauseForUpdatePreservesAnAdmittedClipboardImport() async throws {
        let (model, view, image) = try fixture()
        // Clipboard conversion owns this ticket before it hands the file to
        // attachImageFiles for inspection, just as NativeComposer does.
        let clipboard = model.beginImageImport(sessionID: view.id)
        view.loading = true
        var finished = false, refused = false
        let pause = Task {
            defer { finished = true }
            do { try await model.pauseRunsForUpdate() } catch { refused = true }
        }
        try await eventually("pause entered or refused") { model.installPreparing || finished }
        XCTAssertTrue(clipboard.isCurrent())
        model.attachImageFiles([image], sessionID: view.id); clipboard.finish()
        view.loading = false
        await pause.value
        try await eventually("clipboard inspection finished") { model.attachmentImports == 0 }
        XCTAssertTrue(refused, "Pause must refuse before closing admission on an accepted clipboard conversion")
        XCTAssertEqual(view.attachments.map(\.path), [image.path])
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.attachments?.map(\.path), [image.path])
    }

    func testShutdownBarrierBlocksNewFileAndClipboardImports() async throws {
        let (model, view, image) = try fixture()
        model.installPreparing = true
        let clipboard = model.beginImageImport(sessionID: view.id)
        XCTAssertFalse(clipboard.isCurrent()); XCTAssertEqual(model.attachmentImports, 0)
        clipboard.finish()
        model.attachImageFiles([image], sessionID: view.id)
        XCTAssertEqual(model.attachmentImports, 0)
        try await eventually("no outstanding inspection") { model.attachmentImports == 0 }
        XCTAssertTrue(view.attachments.isEmpty)
        model.installPreparing = false; model.shutdown()
        let afterShutdown = model.beginImageImport(sessionID: view.id)
        XCTAssertFalse(afterShutdown.isCurrent()); XCTAssertEqual(model.attachmentImports, 0)
        afterShutdown.finish()
    }
}
