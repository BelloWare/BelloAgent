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
        model.connectionSwitchSteps = { step in if step == "closed" { try FileManager.default.moveItem(at: journal, to: aside) } }
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
}
