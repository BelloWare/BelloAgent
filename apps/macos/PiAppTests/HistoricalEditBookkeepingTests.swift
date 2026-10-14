import XCTest
import SQLite3
@testable import PiApp

final class HistoricalEditBookkeepingTests: XCTestCase {
    @MainActor func testAcceptedEditRestoresOriginalDraftWhenAcknowledgementCannotBeSaved() async throws {
        try await acceptedEdit(newerTyping: false)
    }
    @MainActor func testAcceptedEditRetargetsNewerTypingWhenAcknowledgementCannotBeSaved() async throws {
        try await acceptedEdit(newerTyping: true)
    }

    @MainActor private func acceptedEdit(newerTyping: Bool) async throws {
        let root = scratchRoot("edit-bookkeeping")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p")
        let view = SessionDisplay(id: chat.id); view.selectionMetadataLoaded = true; view.snapshotInFlight = true
        model.chats = [chat]; model.displays[chat.id] = view
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(chat.id)
        view.draftBeforeEdit = DraftRecord(id: chat.id, text: "Original unsent draft")
        view.editingMessageID = "old-turn"; view.draft = "Replacement"
        model.sendEdit(sessionID: chat.id)
        try await eventually("edit dispatched") { frames.contains { $0["method"]?.string == "turn.edit" } }
        let frame = try XCTUnwrap(frames.first { $0["method"]?.string == "turn.edit" })
        let commandID = try XCTUnwrap(frame["commandId"]?.string)
        let turnID = try XCTUnwrap(frame["params"]?.object?["clientTurnId"]?.string)
        if newerTyping { view.draft = "Newer replacement" }
        try RecoveredDraftTests.sql("CREATE TRIGGER refuse_edit_ack BEFORE UPDATE ON records WHEN OLD.kind='pending:chat' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: root)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                             "commandId": .string(commandID), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]),
                     connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("helper acceptance published") { view.acceptedCommands.contains(commandID) }
        // Draft restoration can finish while acknowledgement storage is blocked.
        // The condition used below must still wait for that bookkeeping.
        let acknowledgementFinished = { !view.loading }
        XCTAssertFalse(acknowledgementFinished(), "Acknowledgement bookkeeping is still blocked")
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await eventually("edit acknowledgement handled", acknowledgementFinished)
        XCTAssertFalse(view.uncertain, "Local persistence cannot make a known acceptance uncertain")
        XCTAssertNotEqual(view.runState, .interrupted)
        XCTAssertTrue(view.acceptedCommands.contains(commandID))
        XCTAssertFalse(view.submissionReviews.contains(commandID))
        XCTAssertTrue(model.error?.contains("Edit accepted") == true)
        XCTAssertEqual(view.editingMessageID, newerTyping ? turnID : nil)
        XCTAssertEqual(view.draft, newerTyping ? "Newer replacement" : "Original unsent draft")
        if newerTyping { model.cancelEdit(sessionID: chat.id); XCTAssertEqual(view.draft, "Original unsent draft") }
        try RecoveredDraftTests.sql("DROP TRIGGER refuse_edit_ack", root: root)
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(saved?.text, "Original unsent draft"); XCTAssertNil(saved?.edit)
        try await host.shutdownAndWait()
    }
}
