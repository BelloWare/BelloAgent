import AppKit
import XCTest
@testable import PiApp

final class PastedAttachmentTests: XCTestCase {
    private let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])

    private func abandonedFiles(_ count: Int, root: URL) throws -> [URL] {
        let previous = PastedImageStorage(root: root)
        return try (0..<count).map { _ in try previous.write(png) }
    }

    @MainActor func testDismissedCopiesKeepJournalAttachmentReferencesAcrossRelaunch() async throws {
        let root = scratchRoot("dismissed-copy-images"), model = makeWorkspaceModel(stateRoot: root)
        let store = try XCTUnwrap(model.store)
        let images = try abandonedFiles(4, root: root).map(AttachmentRecord.inspect)
        var journals: [URL: Data] = [:]
        // Different preserved copies can reuse an ID. Dismissing the second
        // must not forget the first file's historical-edit or queue references.
        for index in 0..<2 {
            let file = root.appendingPathComponent("copy-\(index).jsonl")
            var bytes = try SideKeepRecoveryTests.journal(id: "different-header")
            let row: WireValue = .object([index == 0 ? "userInput" : "queue": .object(["attachments": .array([images[index].wire])])])
            bytes.append(try JSONEncoder().encode(row)); bytes.append(10); try bytes.write(to: file)
            let chat = ChatRecord(id: "copy", workspaceID: "w", title: "Preserved copy", path: file.path, profileID: "p")
            try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
            try await store.dismissSideKeep(chat)
            journals[file] = bytes
        }
        // Keep following the journal, including a helper's later final write;
        // a one-time inventory of attachment names is insufficient.
        let first = root.appendingPathComponent("copy-0.jsonl")
        var appended = try XCTUnwrap(journals[first])
        appended.append(try JSONEncoder().encode(images[2].wire)); appended.append(10)
        try appended.write(to: first); journals[first] = appended
        let inventory = try await store.pastedImageReferences(root: root)
        XCTAssertEqual(inventory.journals, Set(journals.keys.map(\.path)))
        model.shutdown(); try await model.traces.close(); await store.close()
        let reopened = makeWorkspaceModel(stateRoot: root)
        reopened.launching = false
        await reopened.reconcileSideKeeps()
        XCTAssertTrue(reopened.chats.isEmpty); XCTAssertTrue(reopened.sideKeepIssues.isEmpty)
        let pending = try await reopened.store?.list(SideKeepIntent.self, kind: "side-keep")
        XCTAssertTrue(pending?.isEmpty == true)
        try await reopened.cleanupPastedImages()
        for image in images.prefix(3) { XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: image.path)), png) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: images[3].path), "Unrelated orphans still get cleaned up")
        for (file, bytes) in journals { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        XCTAssertTrue(reopened.hosts.isEmpty)
    }

    @MainActor func testDismissedMissingJournalStillDefersAttachmentCleanup() async throws {
        let root = scratchRoot("dismissed-missing-images"), model = makeWorkspaceModel(stateRoot: root)
        let image = try PastedImageStorage(root: root).write(png), store = try XCTUnwrap(model.store)
        let chat = ChatRecord(id: "copy", workspaceID: "w", title: "Missing copy", path: root.appendingPathComponent("missing.jsonl").path, profileID: "p")
        try await store.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
        try await store.dismissSideKeep(chat)
        model.launching = false
        do { try await model.cleanupPastedImages(); XCTFail("An unreadable retained source must defer cleanup") } catch {}
        XCTAssertEqual(try? Data(contentsOf: image), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chat.path!))
        await model.reconcileSideKeeps(); XCTAssertTrue(model.sideKeepIssues.isEmpty)
    }

    @MainActor func testPastedImageSurvivesReopeningAfterTheClipboardSourceIsGone() async throws {
        let root = scratchRoot("pasted-durable")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let source = root.appendingPathComponent("temporary-clipboard.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try png.write(to: source)
        let pasted = try XCTUnwrap(ComposerTextView.writePastedImage(.init(data: try Data(contentsOf: source), isPNG: true), storage: model.pastedImages))
        let image = try AttachmentRecord.inspect(pasted)
        let store = try XCTUnwrap(model.store)
        try await store.put(DraftRecord(id: "chat", text: "Screenshot", attachments: [image]), kind: "draft", id: "chat")
        try FileManager.default.removeItem(at: source)
        await store.close()
        let reopened = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let draft = try await reopened.get(DraftRecord.self, kind: "draft", id: "chat")
        let saved = try XCTUnwrap(draft?.attachments?.first)
        XCTAssertTrue(saved.path.hasPrefix(root.resolvingSymlinksInPath().appendingPathComponent("PastedImages").path + "/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved.path)), png)
        await reopened.close()
    }

    @MainActor func testCleanupKeepsAllReferencesAndCurrentPastesButRemovesOrphans() async throws {
        let root = scratchRoot("pasted-cleanup")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.launching = false
        let store = try XCTUnwrap(model.store)
        let files = try abandonedFiles(6, root: root)
        let images = try files.map(AttachmentRecord.inspect)
        var draft = DraftRecord(id: "chat", text: "", attachments: [images[0]])
        draft.edit = MessageEditDraft(messageID: "old", originalText: "", originalAttachments: [images[1]])
        try await store.put(draft, kind: "draft", id: "chat")
        try await store.put(CommandIntent(id: "pending", sessionID: "chat", turnID: "turn", text: "", state: "intent", attachments: [images[2]]), kind: "pending:chat", id: "pending")
        let journal = root.appendingPathComponent("saved.jsonl")
        // Queued delivery and a historical edit still need their paths, even
        // after the corresponding app intent has been retired.
        let records: [WireValue] = [.object(["userInput": .object(["attachments": .array([images[3].wire])])]),
                                   .object(["queue": .array([.object(["attachments": .array([images[4].wire])])])])]
        var bytes = Data(); for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }; try bytes.write(to: journal)
        try await store.put(ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: journal.path, profileID: "p"), kind: "chat", id: "chat")
        let current = try XCTUnwrap(ComposerTextView.writePastedImage(.init(data: png, isPNG: true), storage: model.pastedImages))
        let userFile = root.appendingPathComponent("user.png"); try png.write(to: userFile)
        let symlink = model.pastedImages.directory.appendingPathComponent("pasted-\(UUID().uuidString)-\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: userFile)
        try await model.cleanupPastedImages()
        for file in files.prefix(5) + [current, userFile, symlink] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[5].path))
    }

    @MainActor func testMissingSavedJournalDefersCleanup() async throws {
        let root = scratchRoot("pasted-unavailable-journal")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.launching = false
        let store = try XCTUnwrap(model.store), file = try XCTUnwrap(abandonedFiles(1, root: root).first)
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: root.appendingPathComponent("missing.jsonl").path, profileID: "p")
        try await store.put(chat, kind: "chat", id: chat.id)
        do { try await model.cleanupPastedImages(); XCTFail("Missing reference sources must defer cleanup") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testAnUnkeptSidesPastedImageMovesToItsParentAndReopens() async throws {
        let root = scratchRoot("side-pasted")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let file = try XCTUnwrap(ComposerTextView.writePastedImage(.init(data: png, isPNG: true), storage: model.pastedImages))
        let side = SessionDisplay(id: "side"); side.draft = "Side draft"; side.attachments = [try AttachmentRecord.inspect(file)]
        let info = SideRecord(id: side.id, parentID: "parent", workspaceID: "w", profileID: "p", title: "Side", kept: false)
        model.displays[side.id] = side; model.sides[info.parentID] = info
        try await model.moveUnsavedSideDraftsToParents()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: "parent")
        let attachment = try XCTUnwrap(saved?.attachments?.first)
        XCTAssertEqual(saved?.text, "Side draft"); XCTAssertTrue(side.attachments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), png)
        let sideDraft = try await model.store?.get(DraftRecord.self, kind: "draft", id: side.id)
        XCTAssertNil(sideDraft, "Unkept side drafts remain ephemeral")
    }
}

private final class PastedJournalPause: @unchecked Sendable {
    private let lock = NSLock(), releaseRead = DispatchSemaphore(value: 0)
    private var began = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func read(_ path: String) throws -> Set<String> {
        lock.lock(); began = true; lock.unlock()
        releaseRead.wait()
        return try PastedImageStorage.names(inJournal: path)
    }
    func release() { releaseRead.signal() }
}

extension PastedAttachmentTests {
    @MainActor func testCleanupRechecksStoredLiveAndInFlightReferencesAfterScanning() async throws {
        for source in ["stored", "live", "sending", "importing"] {
            let root = scratchRoot("paste-race-" + source)
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            let store = try XCTUnwrap(model.store), pause = PastedJournalPause()
            let file = try XCTUnwrap(abandonedFiles(1, root: root).first), image = try AttachmentRecord.inspect(file)
            let journal = root.appendingPathComponent("chat.jsonl"); try Data("{}\n".utf8).write(to: journal)
            let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: journal.path, profileID: "p")
            try await store.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
            let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; model.displays[chat.id] = view
            model.pastedImageRead = { try pause.read($0) }; defer { pause.release() }
            let sweep = Task { try await model.cleanupPastedImages() }
            try await eventually("journal sweep held") { pause.entered }
            switch source {
            case "stored": try await store.put(DraftRecord(id: "other", text: "", attachments: [image]), kind: "draft", id: "other")
            case "live": view.attachments = [image]
            case "sending": view.loading = true
            default:
                var profile = ProfileRecord(); profile.id = "p"; profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
                model.profiles = [profile]; model.attachImageFiles([file], sessionID: view.id)
                XCTAssertEqual(model.attachmentImports, 1, "An import registers before its detached file inspection starts")
            }
            pause.release(); try await sweep.value
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), source)
            if source == "importing" { try await eventually("image import finished") { model.attachmentImports == 0 }; XCTAssertEqual(view.attachments.first?.path, image.path) }
            view.loading = false
        }
    }
    @MainActor func testCleanupDoesNotHoldRestorationOrMetadataReads() async throws {
        let root = scratchRoot("paste-cleanup-restore")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store), pause = PastedJournalPause()
        _ = try abandonedFiles(1, root: root)
        let journal = root.appendingPathComponent("old.jsonl"); try Data("{}\n".utf8).write(to: journal)
        var chat = ChatRecord(id: "old", workspaceID: "w", title: "Old chat", path: journal.path, profileID: "p"); chat.archivedAt = Date(timeIntervalSince1970: 1)
        try await store.put(chat, kind: "chat", id: chat.id)
        model.pastedImageRead = { try pause.read($0) }
        defer { pause.release() }
        var restored = false
        let restoration = Task { await model.restore(); restored = true }
        do { try await eventually("cleanup started") { pause.entered } } catch {
            // Whether the sweep was scheduled and what could have deferred it,
            // or whether it was merely still waiting for a utility thread.
            XCTFail("cleanup: scheduled=\(model.pastedImageCleanup != nil) restored=\(restored) launching=\(model.launching) " +
                    "activeWork=\(model.hasActiveWork) installPreparing=\(model.installPreparing) shutDown=\(model.isShutDown) " +
                    "draftWrites=\(model.draftWrites.tasks.count) sessionOpenings=\(model.sessionOpenings.count)")
            throw error
        }
        XCTAssertTrue(restored, "Initial restoration must finish before a retained journal sweep starts")
        XCTAssertFalse(model.launching)
        XCTAssertEqual(model.chats.map(\.id), [chat.id])
        let read = expectation(description: "metadata stays available during journal scan")
        let lookup = Task { _ = try? await store.get(ChatRecord.self, kind: "chat", id: chat.id); read.fulfill() }
        await fulfillment(of: [read], timeout: 1)
        pause.release(); await restoration.value; await lookup.value; await model.pastedImageCleanup?.value
    }
}
