import XCTest
@testable import PiApp

final class WorkspaceOpeningProgressTests: XCTestCase {
    @MainActor private func fixture() async throws -> (WorkspaceModel, ChatRecord, SessionDisplay) {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("opening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "connection"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "fixture"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome":.string(root.appendingPathComponent("empty-codex").path)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.prewarmsHelpers = false
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: workspace.id, title: "Opening fixture", path: nil, profileID: profile.id)
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        let view = SessionDisplay(id: chat.id); view.draft = "Keep my unsent message"
        model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        return (model, chat, view)
    }

    @MainActor func testCancelAfterLateSuccessReturnsTheMessageAndClosesBeforeRetry() async throws {
        let (model, chat, view) = try await fixture(), gate = OpeningStepGate()
        defer { gate.release() }
        model.sessionOpeningStep = { if $0 == "acknowledged" { await gate.wait() } }
        model.send(sessionID: chat.id)
        try await eventually("The helper replied, before runtime adoption") { gate.entered }
        let host = try XCTUnwrap(model.hosts[chat.workspaceID])
        XCTAssertFalse(model.opened.contains(chat.id))
        model.selectedID = nil
        XCTAssertFalse(try XCTUnwrap(model.sessionOpenings[chat.id]).task.isCancelled,
                       "Selecting another chat leaves the shared opening alive")
        model.cancelSessionOpening(chat.id)
        XCTAssertTrue(try XCTUnwrap(model.sessionOpenings[chat.id]).task.isCancelled)
        gate.release()
        try await eventually("Cancelled send and runtime withdrawal settle") {
            !view.loading && model.sessionOpenings[chat.id] == nil && model.sessionClosings[chat.id] == nil
        }
        XCTAssertEqual(view.draft, "Keep my unsent message")
        XCTAssertEqual(view.sendFailure, "Opening cancelled. Your message was not sent.")
        XCTAssertTrue(view.sendingRows.isEmpty); XCTAssertFalse(view.uncertain)
        XCTAssertEqual(view.helperOpening, .cancelled)
        XCTAssertFalse(model.opened.contains(chat.id))
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(chat.id)")
        XCTAssertEqual(pending?.count, 0, "The restored draft replaces the undispatched send intent")
        do { _ = try await host.request("session.status", sessionID: chat.id); XCTFail("The late success leaked a runtime") }
        catch { if case HostError.rejected(let code, _) = error { XCTAssertEqual(code, "session_missing") } else { throw error } }
        model.sessionOpeningStep = nil
        _ = try await model.open(try XCTUnwrap(model.record(chat.id)))
        XCTAssertTrue(model.opened.contains(chat.id), "Retry can resume the journal made by the cancelled first open")
        XCTAssertEqual(view.draft, "Keep my unsent message", "Retry opens; it does not send the returned draft")
    }

    @MainActor func testFailedOpeningReturnsTheMessageAndRetryDoesNotResendIt() async throws {
        let (model, chat, view) = try await fixture()
        model.sessionOpeningStep = { _ in throw HostError.failure("Generated opening failure") }
        model.send(sessionID: chat.id)
        try await eventually("The refused opening settles the send") { !view.loading && view.sendFailure != nil }
        XCTAssertEqual(view.draft, "Keep my unsent message")
        XCTAssertEqual(view.sendFailure, "Generated opening failure")
        XCTAssertEqual(view.helperOpening, .failed("Generated opening failure"))
        XCTAssertTrue(view.sendingRows.isEmpty); XCTAssertFalse(view.uncertain)
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(chat.id)")
        XCTAssertEqual(pending?.count, 0)
        model.sessionOpeningStep = nil
        model.retrySessionOpening(chat.id)
        try await eventually("Retry opens without dispatching the message") { model.opened.contains(chat.id) && view.helperOpening == nil }
        XCTAssertEqual(view.draft, "Keep my unsent message")
        XCTAssertFalse(view.loading)
    }

    @MainActor func testDisconnectDuringOpeningReturnsThePendingMessage() async throws {
        let (model, chat, view) = try await fixture(), gate = OpeningStepGate()
        defer { gate.release() }
        model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait() } }
        model.send(sessionID: chat.id)
        try await eventually("Opening is shared") { gate.entered }
        let host = try XCTUnwrap(model.hosts[chat.workspaceID]), connection = try XCTUnwrap(host.connectionID)
        host.receive(.failed("Generated disconnect during opening"), connectionID: connection)
        gate.release()
        try await eventually("Disconnected opening restores the draft") { !view.loading && view.sendFailure != nil }
        XCTAssertEqual(view.draft, "Keep my unsent message")
        XCTAssertTrue(view.sendingRows.isEmpty); XCTAssertFalse(view.uncertain)
        XCTAssertFalse(model.opened.contains(chat.id))
        XCTAssertNil(model.sessionOpenings[chat.id])
        try await host.shutdownAndWait()
    }
}

@MainActor private final class OpeningStepGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
