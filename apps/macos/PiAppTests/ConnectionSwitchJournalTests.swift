import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A chat with a journal moved to another connection, against two synthetic
/// gateways: each accepts only its own model, so a turn that finishes went to
/// the gateway its connection names. The journal moves before the chat says
/// it has; a move that fails leaves the chat working where it was.
final class ConnectionSwitchJournalTests: XCTestCase {
    private struct Setup {
        let workspace: GatewayWorkspace
        let second: ProfileRecord
    }
    /// The first gateway and its connection, and a second gateway on another
    /// port that answers only `ui-fixture-b`, with a connection to it.
    @MainActor private func setup() async throws -> Setup {
        let workspace = try await gatewayWorkspace("connection-switch-journal", projectID: "switch-project")
        let folder = workspace.root.appendingPathComponent("second-gateway")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gateway = try await startSyntheticGateway(in: folder, environment: ["PI_APP_UI_FIXTURE_MODEL": "ui-fixture-b"])
        var second = workspace.profile
        second.id = "second-connection"; second.name = "Second"; second.baseUrl = gateway.base
        second.modelId = "ui-fixture-b"; second.catalogUrl = gateway.base + "/catalog"
        // A new model clears the ceiling; each gateway holds a request to its own.
        second.modelOutputLimit = 300_000
        // Saved as the first is, with the output ceiling each gateway holds a
        // request to.
        let saved = try await workspace.vault.load(), connection = VaultProfile(profile: second, apiKey: "synthetic-loopback-only-key")
        _ = try await workspace.vault.update(expectedRevision: saved.revision) { $0.profiles.append(connection) }
        return Setup(workspace: workspace, second: second)
    }
    @MainActor private func launch(_ setup: Setup) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: setup.workspace.state, vault: setup.workspace.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        await model.restore()
        return model
    }
    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }
    /// Sends `text` and waits for its answer.
    @MainActor private func ask(_ model: WorkspaceModel, _ chatID: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let view = try XCTUnwrap(model.displays[chatID], file: file, line: line)
        let before = view.messages.count
        view.draft = text; model.send(sessionID: chatID)
        try await eventually("The turn “\(text)” never finished", timeout: .seconds(60), file: file, line: line) {
            view.sendFailure != nil || view.runState == .error || (quiet(view) && view.messages.count >= before + 2)
        }
        XCTAssertNotEqual(view.runState, .error, view.failureMessage ?? "", file: file, line: line)
        XCTAssertNil(view.sendFailure, file: file, line: line)
    }
    /// A chat on the first connection with one turn answered.
    @MainActor private func answeredChat(_ model: WorkspaceModel, _ setup: Setup) async throws -> ChatRecord {
        model.selectedWorkspaceID = setup.workspace.workspace.id; model.profileChoice = setup.workspace.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.workspace.id, title: "Moving", path: nil, profileID: setup.workspace.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        try await ask(model, chat.id, "A first question")
        return try XCTUnwrap(model.record(chat.id))
    }
    @MainActor private func stored(_ model: WorkspaceModel, _ id: String) async throws -> ChatRecord? {
        try await model.store?.get(ChatRecord.self, kind: "chat", id: id)
    }

    /// Moved, the chat's next turn goes to the second gateway with its
    /// history; moved back with no metadata file, the whole journal is read
    /// and the first gateway answers again.
    @MainActor func testASentChatMovesToAnotherGatewayAndGoesOnThere() async throws {
        let setup = try await setup(), model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        let path = try XCTUnwrap(chat.path)
        // Its replies hold no reasoning only the first connection sends: no question.
        model.questions.answer = { question in XCTFail("Asked “\(question.title)” with nothing to lose"); return false }
        await model.setConnection(setup.second.id, for: chat.id)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.record(chat.id)?.profileID, setup.second.id)
        XCTAssertNil(model.record(chat.id)?.journalRebind)
        let saved = try await stored(model, chat.id)
        XCTAssertEqual(saved?.profileID, setup.second.id); XCTAssertNil(saved?.journalRebind)
        try await ask(model, chat.id, "A second question")
        XCTAssertEqual(model.displays[chat.id]?.messages.filter { $0.role == "user" }.map(\.text), ["A first question", "A second question"])

        JournalCheckpoint.remove(for: URL(fileURLWithPath: path))
        await model.setConnection(setup.workspace.profile.id, for: chat.id)
        XCTAssertNil(model.error)
        try await ask(model, chat.id, "A third question")
        XCTAssertEqual(model.displays[chat.id]?.messages.filter { $0.role == "user" }.count, 3)
    }

    /// The journal moved but the record naming the new connection was not
    /// written: the chat stays on its connection, marked, and its next open
    /// (here after a relaunch) binds the journal back before it opens.
    @MainActor func testAMoveWhoseRecordWasNotWrittenIsPutBackByTheNextOpen() async throws {
        let setup = try await setup(), model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        model.connectionSwitchSteps = { step in if step == "metadata" { throw StoreError.unavailable } }
        await model.setConnection(setup.second.id, for: chat.id)
        XCTAssertEqual(model.error, StoreError.unavailable.localizedDescription)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
        XCTAssertEqual(model.record(chat.id)?.journalRebind, true)
        let marked = try await stored(model, chat.id)
        XCTAssertEqual(marked?.profileID, chat.profileID); XCTAssertEqual(marked?.journalRebind, true)
        model.connectionSwitchSteps = nil
        model.report.suspend(); model.shutdown()
        for host in model.hosts.values { try await host.shutdownAndWait() }
        try await model.traces.close(); await model.store?.close()

        let relaunched = try await launch(setup)
        await relaunched.select(chat.id)
        try await ask(relaunched, chat.id, "After the relaunch")
        XCTAssertNil(relaunched.record(chat.id)?.journalRebind)
        let settled = try await stored(relaunched, chat.id)
        XCTAssertEqual(settled?.profileID, chat.profileID); XCTAssertNil(settled?.journalRebind)
    }

    /// The helper cannot move the journal: the chat stays where it was. The
    /// mark stays until the journal is known to be bound there, which the
    /// next open makes sure of; the chat answers there.
    @MainActor func testAMoveTheHelperRefusesLeavesTheChatWhereItWas() async throws {
        let setup = try await setup(), model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        let journal = URL(fileURLWithPath: try XCTUnwrap(chat.path)), aside = journal.appendingPathExtension("aside")
        model.connectionSwitchSteps = { step in if step == "marked" { try FileManager.default.moveItem(at: journal, to: aside) } }
        await model.setConnection(setup.second.id, for: chat.id)
        model.connectionSwitchSteps = nil
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
        XCTAssertEqual(model.record(chat.id)?.journalRebind, true, "Nothing could say where the journal is")
        try FileManager.default.moveItem(at: aside, to: journal)
        model.error = nil
        try await ask(model, chat.id, "Still here")
        XCTAssertNil(model.record(chat.id)?.journalRebind)
        let saved = try await stored(model, chat.id)
        XCTAssertEqual(saved?.profileID, chat.profileID); XCTAssertNil(saved?.journalRebind)
    }

    /// The journal cannot be read when the switch looks at it: nothing
    /// changes, and nothing is marked.
    @MainActor func testAJournalThatCannotBeReadStopsTheSwitchBeforeAnythingChanges() async throws {
        let setup = try await setup(), model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        let journal = URL(fileURLWithPath: try XCTUnwrap(chat.path)), aside = journal.appendingPathExtension("aside")
        model.connectionSwitchSteps = { step in if step == "closed" { try FileManager.default.moveItem(at: journal, to: aside) } }
        await model.setConnection(setup.second.id, for: chat.id)
        model.connectionSwitchSteps = nil
        XCTAssertNotNil(model.error)
        try FileManager.default.moveItem(at: aside, to: journal)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID); XCTAssertNil(model.record(chat.id)?.journalRebind)
        let saved = try await stored(model, chat.id)
        XCTAssertEqual(saved?.profileID, chat.profileID); XCTAssertNil(saved?.journalRebind)
        model.error = nil
        try await ask(model, chat.id, "Still here")
    }

    /// The journal moved but the answer was lost: the chat stays on its
    /// connection, its journal is bound back there, and only then unmarked.
    @MainActor func testAMoveWhoseAnswerWasLostIsBoundBackAndUnmarked() async throws {
        let setup = try await setup(), model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        model.connectionSwitchSteps = { step in if step == "rebound" { throw HostError.rejected("session_damaged", "A journal synchronization failed") } }
        await model.setConnection(setup.second.id, for: chat.id)
        model.connectionSwitchSteps = nil
        XCTAssertEqual(model.error, HostError.rejected("session_damaged", "A journal synchronization failed").localizedDescription)
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID)
        XCTAssertNil(model.record(chat.id)?.journalRebind)
        let saved = try await stored(model, chat.id)
        XCTAssertEqual(saved?.profileID, chat.profileID); XCTAssertNil(saved?.journalRebind)
        model.error = nil
        try await ask(model, chat.id, "Still on the first")
    }

    /// The first connection replays native reasoning on a fixed route, and a
    /// reply of the chat holds some: the reader is asked. No keeps the chat
    /// where it is, journal untouched; yes moves it, and that reply goes to
    /// the second gateway, which refuses opaque reasoning, as its text.
    @MainActor func testAMoveThatLeavesReasoningBehindIsAskedAboutEachTime() async throws {
        let setup = try await setup()
        let routing = #"{"routing":{"replayPolicy":"pinned","expectedModel":"ui-fixture","replayContract":"synthetic fixed route"}}"#
        let saved = try await setup.workspace.vault.load()
        _ = try await setup.workspace.vault.update(expectedRevision: saved.revision) { configuration in
            if let index = configuration.profiles.firstIndex(where: { $0.profile.id == setup.workspace.profile.id }) { configuration.profiles[index].profile.advancedJSON = routing }
        }
        let model = try await launch(setup)
        let chat = try await answeredChat(model, setup)
        let path = try XCTUnwrap(chat.path), url = URL(fileURLWithPath: path)
        // The gateway's reply as one with reasoning would be recorded: its
        // reasoning item, and the model the gateway reported.
        try await model.hosts[chat.workspaceID]?.shutdownAndWait()
        try await eventually("The helper's exit was never seen") { !model.opened.contains(chat.id) }
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let index = try XCTUnwrap(lines.lastIndex { $0.contains(#""role":"assistant""#) && $0.contains(#""type":"message""#) })
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any])
        var message = try XCTUnwrap(record["message"] as? [String: Any])
        let items = try XCTUnwrap(message["nativeProviderItems"] as? [Any])
        message["nativeProviderItems"] = [["type": "reasoning", "id": "rs-fixture", "encrypted_content": "opaque", "summary": [Any]()]] + items
        message["nativeProviderIdentity"] = ["status": "reported", "effectiveModel": "ui-fixture"]
        record["message"] = message
        lines[index] = String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        JournalCheckpoint.remove(for: url)
        let bytes = try Data(contentsOf: url)

        var asked: [ChatQuestion] = []
        model.questions.answer = { asked.append($0); return false }
        await model.setConnection(setup.second.id, for: chat.id)
        XCTAssertNil(model.error)
        XCTAssertEqual(asked, [WorkspaceModel.reasoningLeftBehind(from: "Fixture", to: "Second")])
        XCTAssertEqual(asked.first?.title, "Earlier reasoning from Fixture can't be sent to Second. Switch anyway?")
        XCTAssertEqual(model.record(chat.id)?.profileID, chat.profileID); XCTAssertNil(model.record(chat.id)?.journalRebind)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "No leaves the journal as it was")

        model.questions.answer = { asked.append($0); return true }
        await model.setConnection(setup.second.id, for: chat.id)
        XCTAssertNil(model.error)
        XCTAssertEqual(asked.count, 2, "asked each time")
        XCTAssertEqual(model.record(chat.id)?.profileID, setup.second.id)
        XCTAssertEqual(try Data(contentsOf: url).prefix(bytes.count), bytes, "the journal keeps everything it had")
        try await ask(model, chat.id, "On the second gateway")
    }
}