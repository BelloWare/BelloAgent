import XCTest
import AppKit
@testable import PiApp

final class CompletionSoundTests: XCTestCase {
    private func receipt(_ id: String, _ state: String, turn: String? = nil) -> WireValue {
        .object(["commandId": .string(id), "turnId": .string(turn ?? id), "state": .string(state)])
    }
    private func snapshot(_ receipts: [WireValue] = [], epoch: String = "runtime", state: String = "idle") -> [String: WireValue] {
        ["commands": .array(receipts), "monitoring": .object(["epoch": .string(epoch)]), "state": .string(state)]
    }

    func testRetainedHistoryIsSilentAndFastRepliesSoundOnceWithoutARunningPoll() {
        var tracker = SessionCompletionTracker()
        XCTAssertFalse(tracker.observe(snapshot([receipt("old", "completed")]), baseline: true))
        let finished = snapshot([receipt("old", "completed"), receipt("new", "completed")])
        XCTAssertTrue(tracker.observe(finished), "A reply may finish between the open and first status poll")
        XCTAssertFalse(tracker.observe(finished))
        XCTAssertFalse(tracker.observe(finished, baseline: true), "Reopening history is silent")
        XCTAssertFalse(tracker.observe(snapshot([receipt("recovered", "completed")], epoch: "replacement")))
        XCTAssertTrue(tracker.observe(snapshot([receipt("next", "completed")], epoch: "replacement")))
    }

    func testToolRoundsFailuresStopsRemovalsAndCompactionAreSilentButSuccessfulRetrySounds() {
        var tracker = SessionCompletionTracker()
        XCTAssertFalse(tracker.observe(snapshot()))
        for state in ["queued", "delivered", "failed", "cancelled", "removed"] {
            XCTAssertFalse(tracker.observe(snapshot([receipt("task", state)], state: "running")))
        }
        XCTAssertFalse(tracker.observe(snapshot([receipt("task", "delivered"), receipt("compact", "completed", turn: "compaction:compact")], state: "compacting")))
        XCTAssertTrue(tracker.observe(snapshot([receipt("task", "completed")])))
        XCTAssertFalse(tracker.observe(snapshot([receipt("task", "completed")])))
    }

    func testQueuedFollowUpsAndSteeringNotifyOnlyOnTaskCompletion() {
        var tracker = SessionCompletionTracker()
        _ = tracker.observe(snapshot())
        XCTAssertFalse(tracker.observe(snapshot([receipt("first", "delivered"), receipt("steer", "delivered"), receipt("next", "queued")], state: "running")))
        XCTAssertTrue(tracker.observe(snapshot([receipt("first", "delivered"), receipt("steer", "completed"), receipt("next", "delivered")], state: "running")), "The next task may already be running")
        XCTAssertFalse(tracker.observe(snapshot([receipt("first", "delivered"), receipt("steer", "completed"), receipt("next", "delivered")], state: "running")))
        XCTAssertTrue(tracker.observe(snapshot([receipt("first", "delivered"), receipt("steer", "completed"), receipt("next", "completed")])))
    }

    func testMissingReceiptsDoNotResetBaselineAndReceiptWindowStaysBounded() {
        var tracker = SessionCompletionTracker()
        XCTAssertFalse(tracker.observe(["assistantMessageCount": .number(99)]))
        XCTAssertFalse(tracker.observe(snapshot([receipt("old", "completed")])))
        XCTAssertFalse(tracker.observe([:]))
        XCTAssertFalse(tracker.observe(snapshot([receipt("old", "completed")])))
        let receipts = (0..<200).map { receipt("task-\($0)", "completed") }
        XCTAssertTrue(tracker.observe(snapshot(receipts)))
        XCTAssertFalse(tracker.observe(snapshot(Array(receipts.suffix(128)))))
        XCTAssertFalse(tracker.observe(snapshot([.null, .object(["state": .string("completed")])])), "Malformed receipts cannot announce success")
    }

    @MainActor func testShortSystemSoundExistsAndSimultaneousCompletionsShareACue() throws {
        let native = try XCTUnwrap(NSSound(named: NSSound.Name("Tink")))
        XCTAssertGreaterThan(native.duration, 0); XCTAssertLessThan(native.duration, 1, "The chosen sound must stay short")
        var now = 10.0, played = 0, available = true
        let sound = CompletionSound(now: { now }, playback: { guard available else { return false }; played += 1; return true })
        for _ in 0..<20 { sound.play() }
        XCTAssertEqual(played, 1, "Twenty simultaneous sessions share one short sound, with no delayed backlog")
        now = 10.9; XCTAssertFalse(sound.play())
        now = 11; XCTAssertTrue(sound.play()); XCTAssertEqual(played, 2)
        now += 2; available = false; XCTAssertFalse(sound.play())
        available = true; XCTAssertTrue(sound.play(), "An unavailable audio device must not consume the next cue")
    }

    @MainActor func testMutedExcludedArchivedAndClosedAppStatesDoNotReplayCues() {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("completion-policy-" + UUID().uuidString)
        var played = 0, now = 0.0
        let sound = CompletionSound(now: { now += 2; return now }, playback: { played += 1; return true })
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()), completionSound: sound)
        registerWorkspaceFixtureTeardown(model, root: root)
        var archived = ChatRecord(id: "archived", workspaceID: "w", title: "Archived", path: nil, profileID: "p"); archived.archivedAt = Date()
        var background = ChatRecord(id: "title", workspaceID: "w", title: "Generate title", path: nil, profileID: "p"); background.backgroundTask = "session-title"
        model.chats = [archived, background,
                       ChatRecord(id: "test", workspaceID: "w", title: "Test", path: nil, profileID: "p", connectionTest: true),
                       ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p")]
        for chat in model.chats {
            model.displays[chat.id] = SessionDisplay(id: chat.id)
            model.observeSessionCompletion(sessionID: chat.id, snapshot: snapshot(), baseline: true)
        }
        for id in ["archived", "title", "test"] { model.observeSessionCompletion(sessionID: id, snapshot: snapshot([receipt("a", "completed")])) }
        XCTAssertEqual(played, 0)
        model.configuration.playsCompletionSound = false
        model.observeSessionCompletion(sessionID: "chat", snapshot: snapshot([receipt("a", "completed")]))
        model.configuration.playsCompletionSound = true
        model.observeSessionCompletion(sessionID: "chat", snapshot: snapshot([receipt("a", "completed")]))
        XCTAssertEqual(played, 0, "Enabling sound must not replay a muted completion")
        model.chats[0].archivedAt = nil
        model.observeSessionCompletion(sessionID: "archived", snapshot: snapshot([receipt("a", "completed")]))
        XCTAssertEqual(played, 0, "Restoring an archived chat must not replay its completion")
        model.page = .report; model.selectedID = nil; model.selected = nil
        model.observeSessionCompletion(sessionID: "chat", snapshot: snapshot([receipt("b", "completed")]))
        XCTAssertEqual(played, 1, "A finished chat sounds even without a visible conversation pane")
        model.shutdown()
        model.observeSessionCompletion(sessionID: "chat", snapshot: snapshot([receipt("c", "completed")]))
        XCTAssertEqual(played, 1, "Late snapshots during shutdown must stay quiet")
    }

    @MainActor func testDefaultPreferenceDecodesOldVaultAndSettingsSaveAndMergePreserveChoice() async throws {
        let old = try JSONEncoder().encode(VaultConfiguration())
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("completionSoundEnabled"))
        XCTAssertTrue(try ConfigurationVault.decode(old).playsCompletionSound)
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("completion-settings-" + UUID().uuidString)
        let vault = ConfigurationVault(storage: MemoryVaultStorage(old))
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        controller.preferences.playsCompletionSound = false
        let saved = await controller.save(); XCTAssertTrue(saved, "Changing a global preference needs no saved connection")
        let stored = try await vault.load(); XCTAssertFalse(stored.playsCompletionSound)
        controller.startNew(); controller.draft.profile.name = "Sound fixture"
        controller.draft.profile.baseUrl = "https://gateway.example"; controller.draft.profile.modelId = "router"; controller.draft.key = "synthetic-only"
        controller.preferences.playsCompletionSound = true
        let savedConnection = await controller.save(); XCTAssertTrue(savedConnection)
        let reloaded = try await vault.load(); XCTAssertTrue(reloaded.playsCompletionSound); XCTAssertEqual(reloaded.profiles.count, 1)

        let baseline = VaultConfiguration()
        var concurrent = baseline; concurrent.playsCompletionSound = false
        XCTAssertFalse(ConnectionSettingsController.merging(baseline, from: baseline, onto: concurrent).playsCompletionSound, "Untouched preferences preserve a concurrent mute")
        var edits = baseline; edits.playsCompletionSound = false
        XCTAssertFalse(ConnectionSettingsController.merging(edits, from: baseline, onto: baseline).playsCompletionSound)
    }

    @MainActor func testRealHelperToolLoopAndFastReplyEmitOneCueEachAndReopeningIsSilent() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("completion-gateway-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Completion fixture\n".utf8).write(to: root.appendingPathComponent("README.md"))
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("scripts/test-native-host.py").path, "--serve"]
        fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        try fixture.run(); defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading, greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let project = WorkspaceRecord(id: "sound", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "observation-final"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [project]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture-secret")]
            $0.resources[project.id] = .object(["codexHome": .string(root.appendingPathComponent("empty").path), "skills": .bool(false)])
        }
        var cues = 0, clock = 0.0
        let sound = CompletionSound(now: { clock += 2; return clock }, playback: { cues += 1; return true })
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault, completionSound: sound)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        for (index, route) in ["observation-final", "json"].enumerated() {
            let chat = ChatRecord(id: "chat-\(index)", workspaceID: project.id, title: "Completion test", path: nil, profileID: profile.id, model: route)
            let view = SessionDisplay(id: chat.id); model.chats.append(chat); model.displays[chat.id] = view
            // Keep both chats hidden: background status polling must suffice.
            view.draft = "Please complete this task"; model.send(sessionID: chat.id)
            for _ in 0..<1_000 {
                if !view.loading && !view.busy && cues == index + 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(view.sendFailure); XCTAssertNil(view.failureMessage)
            XCTAssertEqual(cues, index + 1, "One cue per task, even when three model requests and two tools ran")
            let host = try XCTUnwrap(model.hosts[project.id])
            let result = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
            XCTAssertEqual(result["assistantMessageCount"]?.number, index == 0 ? 3 : 1)
            _ = try await host.request("session.close", sessionID: chat.id)
            model.opened.remove(chat.id)
            _ = try await model.open(try XCTUnwrap(model.record(chat.id)))
            model.refresh(chat.id)
            for _ in 0..<200 where view.snapshotInFlight { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(cues, index + 1, "Reloading retained command receipts is silent")
        }
    }
}
