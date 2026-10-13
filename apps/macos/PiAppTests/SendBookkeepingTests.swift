import XCTest
@testable import PiApp

final class SendBookkeepingTests: XCTestCase {
    @MainActor func testAcknowledgementFailureAfterAcceptanceDoesNotFailTheSend() async throws { try await localFailure(at: "submitted", kind: "pending:chat") }
    @MainActor func testTitleFailureAfterAcceptanceDoesNotFailTheSend() async throws { try await localFailure(at: "acknowledged", kind: "chat") }

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
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                             "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true), "queued": .bool(false)])]),
                     connectionID: try XCTUnwrap(host.connectionID))
        try await eventually("local bookkeeping finished") { !view.loading }
        XCTAssertTrue(injected); XCTAssertNotNil(model.error)
        XCTAssertNil(view.sendFailure); XCTAssertFalse(view.uncertain); XCTAssertEqual(view.runState, .running)
        XCTAssertEqual(view.draft, "Newer typing"); XCTAssertEqual(view.sendingRows.map(\.text), ["Accepted message"])
        XCTAssertEqual(model.chats.first?.title, "Accepted message")
        XCTAssertTrue(view.recovered.isEmpty)
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
