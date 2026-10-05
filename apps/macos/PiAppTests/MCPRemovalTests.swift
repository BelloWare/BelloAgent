import XCTest
@testable import PiApp

/// "Remove All MCP Servers…": it deletes one project's saved configuration,
/// the project named when the reader was asked, says so honestly, and
/// does nothing on Cancel.
@MainActor final class MCPRemovalTests: XCTestCase {
    private let secret = "mcp-header-secret-value"
    private var questions: [NSAlert] = []

    private func server(_ name: String) -> WireValue {
        .object(["servers": .object([name: .object(["url": .string("https://\(name).example/mcp"),
                                                    "headers": .object(["authorization": .string("Bearer " + secret)])])])])
    }

    /// Two projects, each with a saved server; A selected.
    private func fixture(emptyA: Bool = false) async throws -> (WorkspaceModel, MemoryVaultStorage, WorkspaceRecord, WorkspaceRecord) {
        let root = scratchRoot("mcp-removal")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let a = WorkspaceRecord(id: "project-a", path: root.appendingPathComponent("alpha").path, trusted: true)
        let b = WorkspaceRecord(id: "project-b", path: root.appendingPathComponent("beta").path, trusted: true)
        let aConfig = emptyA ? WireValue.object(["servers": .object([:])]) : server("alpha"), bConfig = server("beta")
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [a, b]; $0.mcp[a.id] = aConfig; $0.mcp[b.id] = bConfig }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        addTeardownBlock { @MainActor in model.shutdown() }
        try await model.reloadConfiguration()
        model.selectedWorkspaceID = a.id
        return (model, storage, a, b)
    }

    private func answer(_ response: NSApplication.ModalResponse, also: @escaping @MainActor () -> Void = {}) {
        addTeardownBlock { @MainActor in PiQuestion.shared.answerAlert = nil }
        PiQuestion.shared.answerAlert = { [unowned self] alert in questions.append(alert); also(); return response }
    }

    func testCancelWritesNothingAndReconfiguresNothing() async throws {
        let (model, storage, a, b) = try await fixture()
        let before = storage.writes, aBefore = model.configuration.mcp[a.id], bBefore = model.configuration.mcp[b.id]
        answer(.alertSecondButtonReturn)
        let notice = await model.confirmAndRemoveAllMCPServers()
        XCTAssertNil(notice)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(storage.writes, before, "Cancel wrote the vault")
        XCTAssertEqual(model.configuration.mcp[a.id], aBefore); XCTAssertEqual(model.configuration.mcp[b.id], bBefore)
        XCTAssertFalse(model.mcpRemovalInProgress)
    }

    func testCancellingTheOwnerRejectsAnAcceptedRemovalAnswer() async throws {
        let (model, storage, a, b) = try await fixture()
        let before = storage.writes, aBefore = model.configuration.mcp[a.id], bBefore = model.configuration.mcp[b.id]
        answer(.alertFirstButtonReturn) { withUnsafeCurrentTask { $0?.cancel() } }
        let removal = Task { await model.confirmAndRemoveAllMCPServers() }
        let notice = await removal.value
        XCTAssertNil(notice)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(storage.writes, before, "A confirmation from a closed owner must not write the vault")
        XCTAssertEqual(model.configuration.mcp[a.id], aBefore); XCTAssertEqual(model.configuration.mcp[b.id], bBefore)
        XCTAssertFalse(model.mcpRemovalInProgress); XCTAssertTrue(model.hosts.isEmpty)
    }

    func testTheQuestionNamesTheProjectDefaultsToCancelAndHoldsNoSecret() async throws {
        let (model, _, a, _) = try await fixture()
        answer(.alertSecondButtonReturn)
        _ = await model.confirmAndRemoveAllMCPServers()
        let alert = try XCTUnwrap(questions.first)
        XCTAssertTrue(alert.messageText.contains("alpha"), alert.messageText)
        XCTAssertTrue(alert.messageText.hasPrefix("Remove all MCP servers"))
        XCTAssertTrue(alert.informativeText.contains(a.path))
        XCTAssertTrue(alert.informativeText.contains("1 server"))
        XCTAssertTrue(alert.informativeText.contains("not a temporary disconnect"))
        XCTAssertFalse((alert.messageText + alert.informativeText).contains(secret))
        XCTAssertEqual(alert.buttons.map(\.title), ["Remove All Servers", "Cancel"])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "Return must choose Cancel")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "The removal must need a click")
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
    }

    /// The reader switches to project B while the question about A is up:
    /// A's servers go, B's stay exactly as saved.
    func testOnlyTheCapturedProjectChangesWhenTheSelectionMoves() async throws {
        let (model, _, a, b) = try await fixture()
        let bBefore = model.configuration.mcp[b.id]
        answer(.alertFirstButtonReturn) { model.selectedWorkspaceID = b.id }
        let notice = await model.confirmAndRemoveAllMCPServers()
        XCTAssertEqual(notice, "Removed all MCP servers from “alpha”.")
        XCTAssertEqual(model.mcpServerCount(a.id), 0)
        XCTAssertEqual(model.configuration.mcp[b.id], bBefore)
        let stored = try await model.vault.load()
        XCTAssertEqual(stored.mcp[a.id], .object(["servers": .object([:])]))
        XCTAssertEqual(stored.mcp[b.id], bBefore)
    }

    func testAProjectWithNoSavedServersIsNotAskedOrWritten() async throws {
        let (model, storage, _, _) = try await fixture(emptyA: true)
        let before = storage.writes
        answer(.alertFirstButtonReturn)
        let notice = await model.confirmAndRemoveAllMCPServers()
        XCTAssertEqual(notice, "This project has no saved MCP servers.")
        XCTAssertTrue(questions.isEmpty); XCTAssertEqual(storage.writes, before)
    }

    /// Servers saved after the question was put are not removed unseen.
    func testAStaleRevisionIsRefused() async throws {
        let (model, storage, a, _) = try await fixture()
        let asked = model.configuration.revision
        let added = server("added")
        try await model.updateConfiguration { $0.mcp[a.id] = added }
        let before = storage.writes
        do { _ = try await model.removeAllMCPServers(workspaceID: a.id, expectedRevision: asked); XCTFail("A stale removal went through") }
        catch { XCTAssertEqual(error.localizedDescription, "The MCP configuration changed while you were asked. Review it and try again.") }
        XCTAssertEqual(storage.writes, before); XCTAssertEqual(model.mcpServerCount(a.id), 1)
    }

    func testAFailedVaultWriteKeepsTheServers() async throws {
        let (model, storage, a, _) = try await fixture()
        storage.writeError = .conflict
        answer(.alertFirstButtonReturn)
        let notice = await model.confirmAndRemoveAllMCPServers()
        XCTAssertNotNil(notice); XCTAssertFalse(notice?.hasPrefix("Removed") ?? true, notice ?? "")
        XCTAssertEqual(model.mcpServerCount(a.id), 1)
        storage.writeError = nil
        let stored = try await model.vault.load()
        XCTAssertEqual(stored.mcp[a.id]?.object?["servers"]?.object?.count, 1)
    }

    func testRunningWorkOrAnUnkeptSideBlocksTheRemoval() async throws {
        let (model, storage, a, _) = try await fixture()
        let chat = ChatRecord(id: "busy", workspaceID: a.id, title: "Busy", path: nil, profileID: "p")
        let view = SessionDisplay(id: chat.id); view.state = "running"
        model.chats = [chat]; model.displays[chat.id] = view
        let before = storage.writes
        do { _ = try await model.removeAllMCPServers(workspaceID: a.id, expectedRevision: model.configuration.revision); XCTFail("Removed during work") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stop project work")) }
        view.state = "idle"
        model.sides["side"] = SideRecord(id: "side", parentID: chat.id, workspaceID: a.id, profileID: "p", title: "Side")
        do { _ = try await model.removeAllMCPServers(workspaceID: a.id, expectedRevision: model.configuration.revision); XCTFail("Removed with an unkept side") }
        catch { XCTAssertTrue(error.localizedDescription.contains("keep sides")) }
        model.sides = [:]
        // A send already on its way: its row shows, the helper hasn't run it yet.
        view.showSending(TranscriptMessage(id: "turn", role: "user", text: "hello", state: TranscriptMessage.sendingState))
        do { _ = try await model.removeAllMCPServers(workspaceID: a.id, expectedRevision: model.configuration.revision); XCTFail("Removed under a send") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stop project work")) }
        view.dropSending("turn"); view.loading = true
        do { _ = try await model.removeAllMCPServers(workspaceID: a.id, expectedRevision: model.configuration.revision); XCTFail("Removed while a chat loads") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stop project work")) }
        XCTAssertEqual(storage.writes, before)
    }

    /// While the vault is written and the helper told, the project counts as
    /// changing: no chat can open and no helper start on it.
    func testTheProjectIsHeldWhileItsServersAreRemoved() async throws {
        let (model, _, a, _) = try await fixture()
        let (host, sent) = try await helper(for: a, model: model)
        answer(.alertFirstButtonReturn)
        let removal = Task { await model.confirmAndRemoveAllMCPServers() }
        try await eventually("mcp.configure sent") { sent.frames.contains { $0["method"]?.string == "mcp.configure" } }
        XCTAssertTrue(model.workspaceChangesInFlight.contains(a.id), "Work could start while the servers were being removed")
        XCTAssertTrue(model.workspaceHasActiveWork(a.id))
        reply(host, to: try XCTUnwrap(sent.frames.last { $0["method"]?.string == "mcp.configure" }), ok: true)
        _ = await removal.value
        XCTAssertFalse(model.workspaceChangesInFlight.contains(a.id))
    }

    /// A helper that replaced the one asked is left running, and the removal
    /// is reported done: the new helper read the saved configuration.
    func testAReplacementHelperIsNeitherStoppedNorReportedStopping() async throws {
        let (model, _, a, _) = try await fixture()
        let (host, sent) = try await helper(for: a, model: model)
        answer(.alertFirstButtonReturn)
        let removal = Task { await model.confirmAndRemoveAllMCPServers() }
        try await eventually("mcp.configure sent") { sent.frames.contains { $0["method"]?.string == "mcp.configure" } }
        let frame = try XCTUnwrap(sent.frames.last { $0["method"]?.string == "mcp.configure" })
        let (replacement, _) = try await helper(for: a, model: model)
        reply(host, to: frame, ok: false, message: "connection replaced")
        let notice = await removal.value
        XCTAssertEqual(notice, "Removed all MCP servers from “alpha”.")
        XCTAssertTrue(replacement.isReady)
    }

    /// The project is removed from the sidebar while its question is up.
    func testARemovedProjectIsNotWritten() async throws {
        let (model, storage, a, _) = try await fixture()
        let before = storage.writes
        answer(.alertFirstButtonReturn) { model.workspaces.removeAll { $0.id == a.id } }
        let notice = await model.confirmAndRemoveAllMCPServers()
        XCTAssertEqual(notice, "That project is no longer in the sidebar.")
        XCTAssertEqual(storage.writes, before)
    }

    /// A second click while the first question is up, or while the vault is
    /// being written, asks nothing and writes nothing.
    func testRepeatedClicksAskOnceAndRemoveOnce() async throws {
        let (model, storage, _, _) = try await fixture()
        let before = storage.writes
        var second: Task<String?, Never>?
        answer(.alertFirstButtonReturn) { second = Task { await model.confirmAndRemoveAllMCPServers() } }
        let first = await model.confirmAndRemoveAllMCPServers()
        XCTAssertNotNil(first)
        let repeated = await second?.value
        XCTAssertNil(repeated ?? nil)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(storage.writes, before + 1)
    }

    /// A running helper is handed the empty configuration.
    func testARunningHelperIsReconfigured() async throws {
        let (model, _, a, _) = try await fixture()
        let (host, sent) = try await helper(for: a, model: model)
        answer(.alertFirstButtonReturn)
        let removal = Task { await model.confirmAndRemoveAllMCPServers() }
        try await eventually("mcp.configure sent") { sent.frames.contains { $0["method"]?.string == "mcp.configure" } }
        let frame = try XCTUnwrap(sent.frames.last { $0["method"]?.string == "mcp.configure" })
        XCTAssertEqual(frame["params"]?.object?["config"], .object(["servers": .object([:])]))
        reply(host, to: frame, ok: true)
        let notice = await removal.value
        XCTAssertEqual(notice, "Removed all MCP servers from “alpha”.")
        XCTAssertTrue(host.isReady)
    }

    /// The vault saved but the helper refused: the reader is told both, in
    /// fixed words that can't quote a secret, and that helper is stopped.
    func testAHelperFailureAfterTheVaultSavedIsReportedAsPartial() async throws {
        let (model, _, a, _) = try await fixture()
        let (host, sent) = try await helper(for: a, model: model)
        answer(.alertFirstButtonReturn)
        let removal = Task { await model.confirmAndRemoveAllMCPServers() }
        try await eventually("mcp.configure sent") { sent.frames.contains { $0["method"]?.string == "mcp.configure" } }
        let frame = try XCTUnwrap(sent.frames.last { $0["method"]?.string == "mcp.configure" })
        reply(host, to: frame, ok: false, message: "refused Bearer " + secret)
        let finished = await removal.value
        let notice = try XCTUnwrap(finished)
        XCTAssertTrue(notice.hasPrefix("Removed “alpha”'s saved MCP servers."), notice)
        XCTAssertTrue(notice.contains("being stopped"), notice)
        XCTAssertFalse(notice.contains(secret))
        XCTAssertEqual(model.mcpServerCount(a.id), 0)
        XCTAssertFalse(host.isReady, "The helper that refused was not stopped")
    }

    private final class Sent { var frames: [[String: WireValue]] = [] }
    private func helper(for project: WorkspaceRecord, model: WorkspaceModel) async throws -> (HostSupervisor, Sent) {
        let sent = Sent(), host = HostSupervisor(commandSender: { sent.frames.append($0) })
        let state = scratchRoot("mcp-removal-host")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try await host.connect(cwd: URL(fileURLWithPath: project.path).deletingLastPathComponent(), state: state)
        model.hosts[project.id] = host
        addTeardownBlock { @MainActor in try? await host.shutdownAndWait() }
        return (host, sent)
    }
    private func reply(_ host: HostSupervisor, to frame: [String: WireValue], ok: Bool, message: String = "") {
        guard let connection = host.connectionID, let epoch = host.epoch else { return XCTFail("No helper connection") }
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch), "commandId": frame["commandId"] ?? .null,
                             "ok": .bool(ok), "result": ok ? .object([:]) : .object(["code": .string("mcp_failed"), "message": .string(message)])]),
                     connectionID: connection)
    }
}

/// A question whose Cancel is the default, on a real sheet: Escape
/// cancels, Return belongs to Cancel, and the action has no key at all.
@MainActor final class CancelDefaultQuestionTests: XCTestCase {
    private func sheet(cancelIsDefault: Bool = true) async throws -> (NSAlert, NSWindow, () -> NSApplication.ModalResponse?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        let alert = PiQuestion.alert(title: "Remove?", detail: "Gone for good.", action: "Remove", cancel: "Cancel",
                                     destructive: true, cancelIsDefault: cancelIsDefault)
        var answer: NSApplication.ModalResponse?
        alert.beginSheetModal(for: window) { answer = $0 }
        try await eventually("the sheet is up") { window.attachedSheet != nil }
        return (alert, try XCTUnwrap(window.attachedSheet), { answer })
    }
    private func key(_ characters: String, _ keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    func testEscapeCancels() async throws {
        let (_, sheet, answer) = try await sheet()
        XCTAssertTrue(sheet.performKeyEquivalent(with: try key("\u{1b}", 53, in: sheet)), "Escape reached no button")
        try await eventually("the sheet answered") { answer() != nil }
        XCTAssertEqual(answer(), .alertSecondButtonReturn)
    }
    func testReturnBelongsToCancelAndTheActionHasNoKey() async throws {
        let (alert, sheet, answer) = try await sheet()
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Cancel", "Return must choose Cancel")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertFalse(sheet.performKeyEquivalent(with: try key("\r", 36, in: sheet)) && answer() == .alertFirstButtonReturn)
        XCTAssertNotEqual(answer(), .alertFirstButtonReturn)
        sheet.endSheet(sheet)
    }
    /// The invisible Escape button takes no room: the question is laid out
    /// exactly as the plain destructive one.
    func testTheEscapeButtonTakesNoRoom() async throws {
        let (_, plain, _) = try await sheet(cancelIsDefault: false)
        let plainSize = plain.frame.size
        plain.sheetParent?.endSheet(plain)
        let (_, guarded, _) = try await sheet()
        XCTAssertEqual(guarded.frame.size, plainSize)
        if let folder = testEnvironment("PI_APP_QUESTION_SNAPSHOT"), let view = guarded.contentView?.superview ?? guarded.contentView,
           let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("cancel-default-question.png"))
        }
        guarded.sheetParent?.endSheet(guarded)
    }
}
