import XCTest
import AppKit
@testable import PiApp

final class ComposerSubmissionTests: XCTestCase {
    @MainActor private func key(_ code: UInt16 = 36, _ flags: NSEvent.ModifierFlags = [], editor: ComposerTextView) {
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!)
    }
    @MainActor func testNativeEnterModifiersCompletionAndIME() {
        let editor = ComposerTextView(); editor.isRichText = false
        var intents: [ComposerSubmissionIntent] = [], completions = 0
        editor.send = { intents.append($0) }
        editor.completionKey = { _, flags in
            guard flags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            completions += 1; return true
        }
        for code: UInt16 in [36, 76] {
            key(code, editor: editor); XCTAssertTrue(intents.isEmpty)
            key(code, .command, editor: editor); XCTAssertEqual(intents, [.steer]); intents.removeAll()
        }
        XCTAssertEqual(completions, 2)
        editor.completionKey = nil
        for code: UInt16 in [36, 76] {
            key(code, editor: editor); key(code, .command, editor: editor)
            XCTAssertEqual(intents, [.followUp, .steer]); intents.removeAll()
            for flags: NSEvent.ModifierFlags in [.shift, [.shift, .command], [.shift, .option], .option, .control] {
                key(code, flags, editor: editor); XCTAssertTrue(intents.isEmpty)
            }
        }
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        key(36, .command, editor: editor); XCTAssertTrue(intents.isEmpty)
    }

    @MainActor func testUncommittedSkillAndNonChatPageCannotSubmit() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "origin"); view.draft = "/uncommitted"; view.directCommand = true
        model.displays[view.id] = view
        model.submitComposer(intent: .steer, sessionID: view.id)
        XCTAssertEqual(view.draft, "/uncommitted"); XCTAssertTrue(view.skills.isEmpty)
        XCTAssertTrue(view.notice.contains("Select the skill")); XCTAssertFalse(view.loading)
        XCTAssertFalse(model.completionKey(36, modifiers: .command, view: view))
        model.page = .report
        view.notice = "unchanged"
        model.submitComposer(intent: .followUp, sessionID: view.id)
        XCTAssertEqual(view.notice, "unchanged"); XCTAssertFalse(view.loading)
    }

    @MainActor func testNativeKeysReachDurableHelperLanesAndPreserveDraftOnStaleBusyState() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("composer-lanes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("scripts/test-native-host.py").path, "--serve"]
        fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        try fixture.run(); defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading, greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let workspace = WorkspaceRecord(id: "keys", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "slow"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture-secret")]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("empty").path), "skills": .bool(false)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "origin", workspaceID: workspace.id, title: "Keyboard fixture", path: nil, profileID: profile.id)
        let view = SessionDisplay(id: chat.id); model.chats = [chat]; model.displays[chat.id] = view
        model.selectedID = chat.id; model.selected = view
        let editor = ComposerTextView(); editor.send = { model.submitComposer(intent: $0, sessionID: chat.id) }
        func accepted() async throws {
            for _ in 0..<200 { if !view.loading { return }; try await Task.sleep(for: .milliseconds(10)) }
            XCTFail("Helper admission did not finish")
        }
        view.draft = "start"; key(76, .command, editor: editor); try await accepted()
        XCTAssertNil(view.sendFailure); XCTAssertEqual(view.draft, "")
        let host = try XCTUnwrap(model.hosts[workspace.id]); view.state = "running"
        view.draft = "follow up"; key(editor: editor); key(editor: editor)
        // A newer edit made before durable acceptance belongs to the reader.
        view.draft = "newer edit"; try await accepted(); XCTAssertEqual(view.draft, "newer edit")
        model.focusedSessionID = "unrelated"
        view.draft = "steering"; key(76, .command, editor: editor); try await accepted()
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
        let queue = snapshot["queue"]?.array?.compactMap(\.object) ?? []
        XCTAssertEqual(queue.filter { $0["kind"]?.string == "follow-up" }.count, 1)
        XCTAssertEqual(queue.filter { $0["kind"]?.string == "steering" }.count, 1)
        XCTAssertEqual(snapshot["commands"]?.array?.count, 3, "One key yields one acceptance; double presses while loading do not duplicate")
        _ = try await host.request("turn.stop", sessionID: chat.id)
        for _ in 0..<200 {
            let state = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
            if state["state"]?.string == "paused" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The next assertions deliberately simulate stale UI run state. Stop
        // live snapshot publication so an unrelated cancellation observation
        // cannot race those assignments or open an uncertainty-review sheet.
        for _ in 0..<200 where view.snapshotInFlight { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.snapshotInFlight)
        view.snapshotInFlight = true
        defer { view.snapshotInFlight = false }
        view.uncertain = false
        view.state = "running"; view.draft = "preserved stale steer"
        key(36, .command, editor: editor); try await accepted()
        XCTAssertEqual(view.draft, "preserved stale steer")
        XCTAssertEqual(view.sendFailure, "The run finished. Press Return to send this as a new message.")
        XCTAssertFalse(view.uncertain)
        view.state = "paused"; key(36, .command, editor: editor); try await accepted()
        XCTAssertTrue(view.sendFailure?.contains("Resume or remove") == true)
        XCTAssertEqual(view.draft, "preserved stale steer")
    }
}
