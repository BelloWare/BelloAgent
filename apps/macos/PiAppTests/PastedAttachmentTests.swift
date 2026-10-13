import AppKit
import XCTest
@testable import PiApp

final class PastedAttachmentTests: XCTestCase {
    private let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])

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
        let previous = PastedImageStorage(root: root), store = try XCTUnwrap(model.store)
        let files = try (0..<6).map { _ in try XCTUnwrap(ComposerTextView.writePastedImage(.init(data: png, isPNG: true), storage: previous)) }
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
        let symlink = previous.directory.appendingPathComponent("pasted-\(UUID().uuidString)-\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: userFile)
        try await store.cleanupPastedImages(model.pastedImages)
        for file in files.prefix(5) + [current, userFile, symlink] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[5].path))
    }

    @MainActor func testMissingSavedJournalDefersCleanup() async throws {
        let root = scratchRoot("pasted-unavailable-journal")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let previous = PastedImageStorage(root: root), store = try XCTUnwrap(model.store)
        let file = try XCTUnwrap(ComposerTextView.writePastedImage(.init(data: png, isPNG: true), storage: previous))
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Fixture", path: root.appendingPathComponent("missing.jsonl").path, profileID: "p")
        try await store.put(chat, kind: "chat", id: chat.id)
        do { try await store.cleanupPastedImages(model.pastedImages); XCTFail("Missing reference sources must defer cleanup") } catch {}
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
