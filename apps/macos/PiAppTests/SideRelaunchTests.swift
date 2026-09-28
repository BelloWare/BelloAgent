import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A side the reader sent from and then closed stays closed after a
/// relaunch: the steps as the reader takes them, in the window, with the
/// packaged helper and the synthetic gateway behind both chats, and the
/// app's own quit path between the two launches.
final class SideRelaunchTests: XCTestCase {
    @MainActor private struct Setup {
        let root: URL, state: URL
        let vault: ConfigurationVault
        let workspace: WorkspaceRecord, profile: ProfileRecord
    }

    @MainActor private func setup() async throws -> Setup {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        let root = scratchRoot("side-relaunch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let gateway = Process(), pipe = Pipe()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", script.path]
        gateway.currentDirectoryURL = root; gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
        // A slow turn streams for about three seconds: long enough to close its side mid-reply.
        gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path, "PI_APP_UI_FIXTURE_SLOW_WORDS": "12"]
        try gateway.run()
        addTeardownBlock { gateway.terminate(); gateway.waitUntilExit() }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"
        let workspace = WorkspaceRecord(id: "side-relaunch-project", path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        return Setup(root: root, state: root.appendingPathComponent("app-state"), vault: vault, workspace: workspace, profile: profile)
    }

    /// A launch: a new model over the same state, in a window, restored as the app does.
    @MainActor private func launch(_ setup: Setup) async -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
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

    /// ⌘Q: the app's own quit path, which saves before it answers.
    @MainActor private func quit(_ model: WorkspaceModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        await waitFor("The model still had work in flight when the test quit", file: file, line: line) { !model.hasActiveWork }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater, file: file, line: line)
        await waitFor("Quitting never answered", file: file, line: line) { !answers.isEmpty }
        XCTAssertEqual(answers, [true], "Nothing here should keep the app from quitting", file: file, line: line)
        model.report.suspend()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line,
                                    _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }

    /// Everything the last send started has finished, and its reply is in.
    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    private struct StoredSelection: Decodable, Sendable { var chatID: String?; var shownSides: [String: String]? }

    /// The first launch up to the side: a chat with a turn of its own, open.
    @MainActor private func chatWithATurn(_ setup: Setup) async throws -> (WorkspaceModel, ChatRecord) {
        let first = await launch(setup)
        first.selectedWorkspaceID = setup.workspace.id; first.profileChoice = setup.profile.id
        let parent = ChatRecord(id: "parent-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Parent", path: nil, profileID: setup.profile.id)
        first.chats = [parent]; try await first.store?.put(parent, kind: "chat", id: parent.id)
        await first.select(parent.id)
        let parentView = try XCTUnwrap(first.displays[parent.id])
        parentView.draft = "A question for the chat"; first.send(sessionID: parent.id)
        await waitFor("The chat's turn never finished") { quiet(first.displays[parent.id]) }
        return (first, parent)
    }

    /// Quits, launches again, and checks the chat came back without its side.
    @MainActor private func relaunchWithoutTheSide(_ first: WorkspaceModel, _ setup: Setup, parent: ChatRecord, side: String,
                                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = try XCTUnwrap(first.store)
        await first.flushSelection()
        let closed = try await store.get(StoredSelection.self, kind: "selection", id: "main")
        XCTAssertNil(closed?.shownSides?[parent.id], "A closed side is forgotten at once", file: file, line: line)
        try await quit(first, file: file, line: line)

        let second = await launch(setup)
        XCTAssertEqual(second.selectedID, parent.id, "The chat comes back", file: file, line: line)
        XCTAssertNil(second.sides[parent.id], "The side closed before quitting stays closed", file: file, line: line)
        XCTAssertNotNil(second.chats.first { $0.id == side }, "and is still a saved chat", file: file, line: line)
    }

    @MainActor func testASideSentFromAndClosedStaysClosedAfterARelaunch() async throws {
        let setup = try await setup()
        let (first, parent) = try await chatWithATurn(setup)
        first.openSide(parentID: parent.id)
        let pending = try XCTUnwrap(first.sides[parent.id])
        XCTAssertTrue(pending.pending)
        let sideView = try XCTUnwrap(first.displays[pending.id])
        sideView.draft = "A question for the side"; first.send(sessionID: pending.id)
        await waitFor("The side's turn never finished") { first.sides[parent.id]?.kept == true && quiet(first.displays[pending.id]) }
        let store = try XCTUnwrap(first.store)
        await first.flushSelection()
        let shown = try await store.get(StoredSelection.self, kind: "selection", id: "main")
        XCTAssertEqual(shown?.shownSides?[parent.id], pending.id, "The side is saved once it sends, and remembered while it is open")

        first.closeSide(pending.id)
        await waitFor("Closing the side never finished") { first.sides[parent.id] == nil }
        try await relaunchWithoutTheSide(first, setup, parent: parent, side: pending.id)
    }

    /// Closed while its reply is still streaming, and quit once it finished.
    @MainActor func testASideClosedWhileItsReplyStreamsStaysClosedAfterARelaunch() async throws {
        let setup = try await setup()
        let (first, parent) = try await chatWithATurn(setup)
        first.openSide(parentID: parent.id)
        let pending = try XCTUnwrap(first.sides[parent.id])
        let sideView = try XCTUnwrap(first.displays[pending.id])
        sideView.draft = "A slow question for the side"; first.send(sessionID: pending.id)
        await waitFor("The side's reply never started streaming") {
            first.sides[parent.id]?.kept == true && first.displays[pending.id]?.loading == false && first.displays[pending.id]?.messages.last?.isStreaming == true
        }
        first.closeSide(pending.id)
        await waitFor("Closing the side never finished") { first.sides[parent.id] == nil }
        // The run goes on without its pane, and finishes.
        let host = try XCTUnwrap(first.hosts[setup.workspace.id])
        var idle = false
        for _ in 0..<400 where !idle {
            idle = try await host.request("session.status", sessionID: pending.id).object?["state"]?.string == "idle"
            if !idle { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(idle, "The side's turn never finished")
        try await relaunchWithoutTheSide(first, setup, parent: parent, side: pending.id)
    }

    /// `/side <question>`: the side opens with its question already on its way.
    @MainActor func testASideOpenedWithAQuestionAndClosedStaysClosedAfterARelaunch() async throws {
        let setup = try await setup()
        let (first, parent) = try await chatWithATurn(setup)
        first.openSide(parentID: parent.id, question: "A question for the side")
        let side = try XCTUnwrap(first.sides[parent.id])
        await waitFor("The side's turn never finished") { first.sides[parent.id]?.kept == true && quiet(first.displays[side.id]) }
        first.closeSide(side.id)
        await waitFor("Closing the side never finished") { first.sides[parent.id] == nil }
        try await relaunchWithoutTheSide(first, setup, parent: parent, side: side.id)
    }
}
