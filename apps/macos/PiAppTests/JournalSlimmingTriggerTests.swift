import XCTest
@testable import PiApp

/// The once-per-launch pass that asks each chat's helper to slim a journal
/// written before 0.1.111 (`WorkspaceJournalSlimming.swift`): which chats it
/// asks about, and what it keeps of the answer. The slimming itself, the
/// Trash included, is the helper's (`JournalSlimmingTests`); a test here must
/// not move anything into the owner's Trash, so the chat it asks about has
/// little to gain.
final class JournalSlimmingTriggerTests: XCTestCase {
    /// A native journal of `messages` rows of about `bytes` each, with two
    /// run-state records.
    private func journal(_ id: String, in sessions: URL, messages: Int, bytes: Int) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data(), parent: WireValue = .null
        func append(_ value: [String: WireValue], id recordID: String? = nil) throws {
            var value = value
            if let recordID { value["id"] = .string(recordID); value["parentId"] = parent; parent = .string(recordID) }
            data.append(try encoder.encode(value)); data.append(10)
        }
        try append(["type": .string("session"), "version": .number(3), "id": .string(id), "cwd": .string(sessions.path), "timestamp": .string("2026-09-01T00:00:00Z")])
        try append(["type": .string("custom"), "customType": .string("pi-app.native.v1"),
                    "data": .object(["binding": .object(["api": .string("fixture")]), "version": .number(1)])], id: "marker")
        let text = String(repeating: "Retained answer text. ", count: max(1, bytes / 22))
        for index in 0..<messages {
            try append(["type": .string("message"), "message": .object(["role": .string(index % 2 == 0 ? "user" : "assistant"), "content": .string(text)])], id: "m\(index)")
            if index == messages / 2 || index == messages - 1 {
                try append(["type": .string("custom"), "customType": .string("pi-app.native.state.v1"),
                            "data": .object(["active": .bool(false), "queue": .array([]), "steering": .array([]), "commands": .array([]), "queuePaused": .bool(false)])], id: "s\(index)")
            }
        }
        let url = sessions.appendingPathComponent(id + ".jsonl")
        try data.write(to: url)
        return url
    }

    @MainActor func testThePassAsksAboutLargeClosedNativeChatsOnceAndLeavesTheRest() async throws {
        let root = scratchRoot("journal-slimming")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "slim-project", path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.id = "slim-profile"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "slim-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-slim-key")]
            $0.automaticUpdateChecks = false
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        }
        let state = root.appendingPathComponent("state")
        let model = WorkspaceModel(stateRoot: state, vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        registerWorkspaceFixtureTeardown(model, root: root)
        await model.restore()
        model.journalSlimming?.cancel()
        let sessions = state.appendingPathComponent("Workspaces/\(workspace.id)/Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // Large, closed and native: asked about. Its run state takes little
        // room, so the helper leaves it as it is and says why.
        let lean = try journal("lean", in: sessions, messages: 60, bytes: 40_000)
        // Too small to be asked about; imported; the one the reader has open.
        let small = try journal("small", in: sessions, messages: 4, bytes: 200)
        let imported = try journal("imported", in: sessions, messages: 60, bytes: 40_000)
        let shown = try journal("shown", in: sessions, messages: 60, bytes: 40_000)
        func chat(_ id: String, _ url: URL, imported: Bool = false) -> ChatRecord {
            var chat = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: url.path, profileID: profile.id); chat.imported = imported; return chat
        }
        let chats = [chat("lean", lean), chat("small", small), chat("imported", imported, imported: true), chat("shown", shown)]
        for record in chats { try await model.store?.put(record, kind: "chat", id: record.id) }
        model.chats = chats
        await model.select("shown")
        let before = try Data(contentsOf: lean)

        XCTAssertEqual(model.slimmingCandidates(marked: []).map(\.chat.id).sorted(), ["lean", "shown"], "Large native chats only")
        await model.slimJournals(waitForQuiet: false)
        let store = try XCTUnwrap(model.store)
        let marks = try await store.list(JournalSlimMark.self, kind: JournalSlimMark.kind)
        XCTAssertEqual(marks.map(\.chatID), ["lean"], "The open chat waits for a later launch; the others are never asked")
        XCTAssertEqual(marks.first?.slimmed, false)
        XCTAssertEqual(marks.first?.reason, "little-to-gain")
        XCTAssertEqual(marks.first?.bytesBefore, Double(before.count))
        XCTAssertEqual(try Data(contentsOf: lean), before, "A journal with little to gain is left as it is")
        XCTAssertEqual(model.slimmingCandidates(marked: Set(marks.map(\.chatID))).map(\.chat.id), ["shown"], "A chat asked about once is not asked again")
    }
}
