import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Quit, relaunch and recovery driven through the packaged helper and the
/// synthetic gateway (`fixtures/native/ui-gateway.py`), in a real window.
///
/// These stop, start and restart the helper against the app's own wall-clock
/// deadlines (the handshake watchdog, the wait for a stopping helper), so a
/// loaded machine can run one out: in ten parallel clones a restart was
/// cancelled. They run in the serial lane (`scripts/test-lanes.py`).
final class LifecycleHelperTests: XCTestCase, SerialTestLane {
    /// One project folder, one gateway and a model over a fresh state root.
    @MainActor final class Bench {
        let root: URL, folder: URL, workspace: WorkspaceRecord, profile: ProfileRecord
        let fixture: Process
        private(set) var model: WorkspaceModel
        private let configuration: VaultConfiguration

        init(_ name: String) async throws {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { repository.deleteLastPathComponent() }
            let gatewayScript = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
            guard FileManager.default.isReadableFile(atPath: gatewayScript.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
            root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("\(name)-" + UUID().uuidString)
            folder = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Synthetic fixture file.\n".utf8).write(to: folder.appendingPathComponent("README.md"))
            let fixture = Process(), pipe = Pipe()
            fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            fixture.arguments = ["-u", gatewayScript.path]
            fixture.currentDirectoryURL = root; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
            fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
            try fixture.run()
            self.fixture = fixture
            let handle = pipe.fileHandleForReading
            let greeting = await Task.detached { handle.availableData }.value
            let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
            let base = "http://127.0.0.1:\(port)"
            workspace = WorkspaceRecord(id: "lifecycle-project", path: folder.path, trusted: true)
            var profile = ProfileRecord()
            profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
            profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
            self.profile = profile
            var configuration = VaultConfiguration()
            configuration.workspaces = [workspace]
            configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
            configuration.automaticUpdateChecks = false
            configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
            self.configuration = configuration
            model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
            await model.restore()
        }
        /// A relaunch: the old model is shut down and a new one restores
        /// from the same state root and vault.
        func relaunch() async throws -> WorkspaceModel {
            await model.stopHostsAndWait(); model.shutdown(); try await model.traces.close(); await model.store?.close()
            model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
            await model.restore()
            return model
        }
        func newChat(_ title: String) async throws -> ChatRecord {
            let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: title, path: nil, profileID: profile.id)
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
            return chat
        }
        /// The orderly end of a test: helpers are waited for, stores closed.
        func close() async {
            await model.stopHostsAndWait(); model.shutdown(); try? await model.traces.close(); await model.store?.close()
            tearDown()
        }
        /// Also runs when a test fails part way (from a `defer`): nothing it
        /// started is left running. Helpers exit on their own at end of input.
        func tearDown() {
            model.shutdown()
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A window showing one chat's pane, drawn on demand.
    @MainActor final class PaneWindow {
        let window: NSWindow, hosted: NSHostingView<ConversationPane>
        init(_ model: WorkspaceModel, _ session: SessionDisplay, _ chat: ChatRecord) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 1100))
            window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        }
        func settle(_ turns: Int = 6) async {
            for _ in 0..<turns { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
        }
        func close() { window.contentView = nil; window.close() }
    }

    @MainActor static func waitUntil(_ what: String, seconds: Double = 60, settle: () async -> Void, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return }; await settle() }
        XCTFail(what); throw CancellationError()
    }

    /// The journal's records, in order, parsed one line at a time.
    static func records(_ path: String) throws -> [[String: WireValue]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode([String: WireValue].self, from: Data($0)) }
    }
}

extension LifecycleHelperTests {
    /// Stop and Quit while a reply streams. The app used to answer AppKit
    /// before its helper had stopped the run, so the helper died with the app:
    /// the partial reply was never written and the journal still said the run
    /// was active, which reopened as a crash. The answer now waits for every
    /// helper to exit, and by then the journal holds both.
    @MainActor func testStopAndQuitMidStreamKeepsThePartialReplyAndStopsTheRun() async throws {
        let bench = try await Bench("stop-quit"); defer { bench.tearDown() }
        let model = bench.model
        let chat = try await bench.newChat("Quit")
        await model.select(chat.id)
        let session = try XCTUnwrap(model.displays[chat.id])
        let pane = PaneWindow(model, session, chat); defer { pane.close() }
        await pane.settle(20)
        session.draft = "slow: walk through the retry loop step by step"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("No text streamed", settle: { await pane.settle(2) }) {
            session.busy && model.record(chat.id)?.path != nil && session.messages.contains { $0.role == "assistant" && !$0.text.isEmpty }
        }
        let path = try XCTUnwrap(model.record(chat.id)?.path, "The first send names the journal")
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = [], helpersRunningAtAnswer: [Int32] = [], journalAtAnswer: [[String: WireValue]] = []
        lifecycle.answerTermination = { value in
            // What is on disk and alive now is all a quitting app leaves.
            helpersRunningAtAnswer = model.hosts.values.compactMap(\.helperProcessIdentifier)
            journalAtAnswer = (try? Self.records(path)) ?? []
            answers.append(value)
        }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        // The question goes on whichever window AppKit calls key or main.
        func asking() -> NSWindow? { NSApp.windows.first { $0.attachedSheet != nil && $0.isVisible } }
        try await Self.waitUntil("The quit question never appeared", seconds: 5, settle: { await pane.settle(1) }) { asking() != nil }
        let host = try XCTUnwrap(asking()), sheet = try XCTUnwrap(host.attachedSheet)
        host.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await Self.waitUntil("Quit never answered", seconds: 30, settle: { await pane.settle(1) }) { !answers.isEmpty }
        XCTAssertEqual(answers, [true])
        XCTAssertEqual(helpersRunningAtAnswer, [], "The app answers only once its helpers have exited")
        let states = journalAtAnswer.filter { $0["customType"]?.string == "pi-app.native.state.v1" }
        let last = try XCTUnwrap(states.last?["data"]?.object, "The journal holds a state record")
        XCTAssertEqual(last["active"], .bool(false), "The run is recorded as stopped, not as still going")
        XCTAssertEqual(last["runStatus"]?.string, "cancelled")
        let partial = journalAtAnswer.compactMap { $0["message"]?.object }.last { $0["role"]?.string == "assistant" }
        XCTAssertEqual(partial?["nativeStopReason"]?.string, "interrupted", "The reply cut off by the quit is kept as an interrupted one")
        let text = partial?["content"]?.array?.compactMap { $0.object?["text"]?.string }.joined() ?? ""
        XCTAssertFalse(text.isEmpty, "The interrupted reply holds the text that had streamed")
        await bench.close()
    }
}

extension LifecycleHelperTests {
    /// A saved reading position (the second question, 40 points below the
    /// top) lands on the heights the rows above have at that moment, mostly
    /// estimated. Their measurement a moment later moved the question by the
    /// estimate's error, up to 40 points, or the landing was lost to it.
    /// Whole window, run loop only; no helper.
    @MainActor func testASavedReadingPositionStaysPutThroughTheMeasurementAfterLanding() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("saved-position-" + UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "launch-profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "launch-model"
        let project = WorkspaceRecord(id: "second-project", path: root.path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [project]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic")]; $0.automaticUpdateChecks = false }
        let answer = (0..<40).map { "Paragraph \($0) of a long answer, long enough to wrap across the width of the pane." }.joined(separator: "\n\n")
        var data = Data(), parent: WireValue = .null
        func append(_ value: [String: WireValue]) throws { data.append(try JSONEncoder().encode(value)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string("b2")])
        for turn in 0..<3 {
            for (role, id, text) in [("user", "b2-q\(turn)", "Question \(turn)"), ("assistant", "b2-a\(turn)", "Answer \(turn).\n\n" + answer)] {
                try append(["type": .string("message"), "id": .string(id), "parentId": parent, "message": .object(["role": .string(role), "content": .string(text)])])
                parent = .string(id)
            }
        }
        let path = root.appendingPathComponent("b2.jsonl"); try data.write(to: path)
        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        try await store.put(ChatRecord(id: "a", workspaceID: project.id, title: "A", path: nil, profileID: profile.id, sidebarOrder: 3_000), kind: "chat", id: "a")
        try await store.put(ChatRecord(id: "b2", workspaceID: project.id, title: "B2", path: path.path, profileID: profile.id, sidebarOrder: 1_000), kind: "chat", id: "b2")
        try await store.put(TranscriptAnchor(id: "b2-q1", offset: 40, followsBottom: false), kind: "anchor", id: "b2")
        await store.close()
        let model = WorkspaceModel(stateRoot: state, vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close(); model.report.suspend(); model.shutdown() }
        func page() -> TranscriptPage? {
            func markers(_ view: NSView) -> [TranscriptSurfaceMarker] { ((view as? TranscriptSurfaceMarker).map { [$0] } ?? []) + view.subviews.flatMap { markers($0) } }
            return markers(view).first?.page
        }
        try await Task.sleep(for: .milliseconds(300))
        await model.select("b2")
        var samples: [CGFloat] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if let page = page(), page.sessionID == "b2", let question = page.rowFrame(of: "b2-q1") { samples.append(question.minY - page.scrollY) }
        }
        XCTAssertFalse(samples.isEmpty, "The chat was shown")
        for (step, place) in samples.enumerated() {
            XCTAssertEqual(place, 40, accuracy: 1.5, "Sample \(step): the second question stays 40 points below the top")
        }
        try? await model.traces.close(); await model.store?.close()
    }
}

extension LifecycleHelperTests {
    /// The offered recovery of a chat whose last record was cut off was
    /// rejected by the helper, whatever the file held. Recover Copy now makes
    /// a new chat from the complete records, which sends like any other, and
    /// leaves the original file byte for byte as it was.
    @MainActor func testRecoverCopyMakesAChatThatSendsAndLeavesTheOriginal() async throws {
        let bench = try await Bench("recover"); defer { bench.tearDown() }
        let chat = try await bench.newChat("Cut off")
        var model = bench.model
        await model.select(chat.id)
        var session = try XCTUnwrap(model.displays[chat.id])
        var pane = PaneWindow(model, session, chat)
        await pane.settle(10)
        session.draft = "first question"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The first turn never finished", settle: { await pane.settle(2) }) {
            !session.hasWork && session.messages.contains { $0.role == "assistant" } && model.record(chat.id)?.path != nil
        }
        let path = try XCTUnwrap(model.record(chat.id)?.path)
        pane.close()
        await model.stopHostsAndWait()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"cut\"".utf8)); try handle.close()
        let damaged = try Data(contentsOf: URL(fileURLWithPath: path))

        model = try await bench.relaunch()
        await model.select(chat.id)
        session = try XCTUnwrap(model.displays[chat.id])
        XCTAssertTrue(session.damagedTail)
        XCTAssertTrue(session.messages.contains { $0.role == "assistant" }, "The complete records show")
        pane = PaneWindow(model, session, try XCTUnwrap(model.record(chat.id))); defer { pane.close() }
        await pane.settle(10)
        model.recoverCopy(chat.id)
        func asking() -> NSWindow? { NSApp.windows.first { $0.attachedSheet != nil && $0.isVisible } }
        try await Self.waitUntil("Recover Copy never asked", seconds: 10, settle: { await pane.settle(1) }) { asking() != nil }
        let host = try XCTUnwrap(asking()), sheet = try XCTUnwrap(host.attachedSheet)
        host.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await Self.waitUntil("No recovered chat was opened", settle: { await pane.settle(1) }) { model.selectedID != nil && model.selectedID != chat.id }
        XCTAssertNil(model.error, model.error ?? "")
        let copyID = try XCTUnwrap(model.selectedID), copy = try XCTUnwrap(model.displays[copyID])
        try await Self.waitUntil("The copy never showed its history", settle: { await pane.settle(1) }) { copy.messages.contains { $0.role == "assistant" } }
        XCTAssertFalse(copy.damagedTail)
        copy.draft = "second question"
        model.send(sessionID: copyID)
        try await Self.waitUntil("The recovered chat did not answer", settle: { await pane.settle(2) }) {
            !copy.hasWork && copy.messages.filter { $0.role == "assistant" }.count >= 2
        }
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), damaged, "The original file is untouched")
        await bench.close()
    }
}

extension LifecycleHelperTests {
    /// A project folder moved while the app was closed made every send fail
    /// with "The bundled host could not start. Reinstall this build.", and
    /// nothing could point the project at the new place. The folder is now
    /// named, and Locate Folder… repoints the same project: the chat keeps its
    /// history and sends again.
    @MainActor func testAMovedProjectFolderIsNamedAndLocatingItKeepsTheChat() async throws {
        let bench = try await Bench("moved"); defer { bench.tearDown() }
        let chat = try await bench.newChat("Moved")
        let model = bench.model
        await model.select(chat.id)
        let session = try XCTUnwrap(model.displays[chat.id])
        let pane = PaneWindow(model, session, chat); defer { pane.close() }
        await pane.settle(10)
        session.draft = "first question"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The first turn never finished", settle: { await pane.settle(2) }) {
            !session.hasWork && session.messages.contains { $0.role == "assistant" }
        }
        await model.stopHostsAndWait()
        let moved = bench.root.appendingPathComponent("project-renamed")
        try FileManager.default.moveItem(at: bench.folder, to: moved)

        session.draft = "second question"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The send never failed", settle: { await pane.settle(2) }) { session.sendFailure != nil }
        XCTAssertTrue(session.sendFailure?.contains(bench.folder.path) == true, "The failure names the missing folder: \(session.sendFailure ?? "")")
        XCTAssertFalse(session.sendFailure?.contains("Reinstall") == true)
        XCTAssertEqual(model.missingProjectFolders[bench.workspace.id], bench.folder.path, "The pane offers Locate Folder…")
        XCTAssertEqual(session.draft, "second question", "Nothing typed is lost")

        try await model.relocateProjectFolder(bench.workspace.id, from: bench.folder.path, to: moved.path)
        XCTAssertEqual(model.workspaces.first { $0.id == bench.workspace.id }?.path, moved.resolvingSymlinksInPath().path, "The same project now points at the new place")
        XCTAssertNil(model.missingProjectFolders[bench.workspace.id])
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The chat did not send after the folder was located", settle: { await pane.settle(2) }) {
            !session.hasWork && session.messages.filter { $0.role == "assistant" }.count >= 2
        }
        XCTAssertNil(session.sendFailure)
        XCTAssertTrue(session.messages.contains { $0.role == "user" && $0.text.contains("first question") }, "The chat kept its history")
        await bench.close()
    }
}

extension LifecycleHelperTests {
    /// The journal of a first send is named in the chat's record only after
    /// the helper made it. A crash between the two left a record with no
    /// path: the chat reopened empty and every send failed with "Session path
    /// already exists; open it explicitly".
    @MainActor func testAChatWhoseJournalWasNeverNamedReopensWithItsHistoryAndSends() async throws {
        let bench = try await Bench("unnamed"); defer { bench.tearDown() }
        let chat = try await bench.newChat("Unnamed")
        var model = bench.model
        await model.select(chat.id)
        var session = try XCTUnwrap(model.displays[chat.id])
        let pane = PaneWindow(model, session, chat)
        await pane.settle(10)
        session.draft = "first question"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The first turn never finished", settle: { await pane.settle(2) }) {
            !session.hasWork && session.messages.contains { $0.role == "assistant" } && model.record(chat.id)?.path != nil
        }
        pane.close()
        await model.stopHostsAndWait()
        // The crash: the journal exists, the record never learned its name.
        var unnamed = try XCTUnwrap(model.record(chat.id)); unnamed.path = nil
        try await model.store?.put(unnamed, kind: "chat", id: chat.id)

        model = try await bench.relaunch()
        await model.select(chat.id)
        session = try XCTUnwrap(model.displays[chat.id])
        XCTAssertNotNil(model.record(chat.id)?.path, "Launch names the journal that is there")
        XCTAssertTrue(session.messages.contains { $0.role == "assistant" }, "The chat opens with its history")
        let again = PaneWindow(model, session, try XCTUnwrap(model.record(chat.id))); defer { again.close() }
        session.draft = "second question"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("The chat did not send again", settle: { await again.settle(2) }) {
            session.sendFailure != nil || (!session.hasWork && session.messages.filter { $0.role == "assistant" }.count >= 2)
        }
        XCTAssertNil(session.sendFailure, session.sendFailure ?? "")
        await bench.close()
    }
}
