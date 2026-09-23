import XCTest
import AppKit
@testable import PiApp

final class WorkspaceFailureTests: XCTestCase {
    @MainActor func testIdleWaitingQueueAlwaysOffersExplicitSendAndBusyDoesNot() {
        let display = SessionDisplay(id:"waiting")
        XCTAssertFalse(display.canResumeQueue)
        display.queue = [["turnId":.string("q"),"text":.string("Follow up")]]
        XCTAssertTrue(display.canResumeQueue,"An unpaused idle queue from an older helper must not be stranded")
        display.state = "running"; XCTAssertFalse(display.canResumeQueue)
        display.state = "error"; display.queuePaused = true; XCTAssertTrue(display.canResumeQueue)
    }
    @MainActor func testFailedSnapshotShowsErrorWhileQueueStillRequiresResume() {
        let display = SessionDisplay(id: "failed")
        display.observeRunState(["state": .string("paused"), "runStatus": .string("failed"), "queuePaused": .bool(true), "preflightError": .string("Provider rejected the model.\nChoose another model.")])
        XCTAssertEqual(display.state, "error", "Old helpers also map failed outcomes to Error")
        XCTAssertEqual(display.failureMessage, "Provider rejected the model.\nChoose another model.")
        XCTAssertFalse(display.busy); XCTAssertTrue(display.canResumeQueue)
        display.notice = "Read-only tools"
        XCTAssertNotNil(display.failureMessage, "Routine footer notices cannot hide the failure")
        display.observeRunState(["state": .string("running"), "runStatus": .string("running"), "queuePaused": .bool(false)])
        XCTAssertNil(display.failureMessage); XCTAssertFalse(display.canResumeQueue)
        display.observeRetainedFailure("An older failure")
        XCTAssertEqual(display.state, "running"); XCTAssertNil(display.failureMessage, "A delayed history read cannot replace active work")
        display.observeRunState(["state": .string("paused"), "runStatus": .string("cancelled"), "queuePaused": .bool(true), "preflightError": .string("Run cancelled.")])
        XCTAssertEqual(display.state, "paused"); XCTAssertNil(display.failureMessage); XCTAssertTrue(display.canResumeQueue)
    }

    @MainActor func testRetainedFailureLoadsWithoutAHelperAndAppearsAsErrorInActivity() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("workspace-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("failed.jsonl"), message = "Provider returned HTTP 429.\nRate limit reached (rate_limit_exceeded)"
        var data = Data(), parent: String?
        func append(_ id: String, _ fields: [String: WireValue]) throws {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            data.append(try JSONEncoder().encode(record)); data.append(10); parent = id
        }
        try append("chat", ["type": .string("session"), "version": .number(3)])
        parent = nil
        try append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1")])
        try append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Question")])])
        try append("failed", ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("failed"), "errorMessage": .string(message)])])
        try data.write(to: path)
        let reader = HistoryReader()
        for _ in 0..<2 {
            let page = try await reader.read(path: path.path)
            XCTAssertNil(page.notice); XCTAssertEqual(page.failureMessage, message, "Cached and freshly indexed history retain the error")
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = [ChatRecord(id: "chat", workspaceID: "workspace", title: "Failed chat", path: path.path, profileID: "profile")]
        await model.select("chat")
        let display = try XCTUnwrap(model.displays["chat"])
        XCTAssertEqual(display.state, "error"); XCTAssertEqual(display.failureMessage, message)
        XCTAssertTrue(model.hosts.isEmpty)
        display.uncertain = true
        let activity = model.menuBarActivity()
        XCTAssertEqual(activity.rows.first?.phase, "error"); XCTAssertEqual(activity.rows.first?.phaseLabel, "Error · needs attention")
        XCTAssertTrue(activity.runningRows.isEmpty)

        try append("completed", ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(["active": .bool(false), "queue": .array([]), "steering": .array([]), "runStatus": .string("idle"), "errorMessage": .null])])
        try data.write(to: path)
        let completed = try await reader.read(path: path.path)
        XCTAssertNil(completed.failureMessage, "A later successful run supersedes the retained failure")
        display.observeRetainedFailure(completed.failureMessage)
        XCTAssertEqual(display.state, "idle"); XCTAssertNil(display.failureMessage)
        model.shutdown(); await model.store?.close()
    }
}

extension WorkspaceFailureTests {
    /// A run cut off by a quit or a crash, and the follow-ups waiting behind
    /// it, came back as an idle chat: no interrupted notice, no Retry or
    /// Resume, no queue, and a tool the run never finished read as done. The
    /// first send was then refused for paused messages nobody could see.
    @MainActor func testAnInterruptedRunAndItsPausedFollowUpsComeBackAsTheyWereLeft() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("workspace-interrupted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func journal(_ name: String, state: [String: WireValue]) throws -> String {
            var data = Data(), parent: String?
            func append(_ id: String, _ fields: [String: WireValue]) throws {
                var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
                data.append(try JSONEncoder().encode(record)); data.append(10); parent = id
            }
            try append(name, ["type": .string("session"), "version": .number(3)]); parent = nil
            try append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1")])
            try append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Question")])])
            try append("call", ["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("toolCall"), "id": .string("call-1"), "name": .string("bash"), "arguments": .object(["command": .string("make migrate")])])])])])
            try append("state", ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(state)])
            let path = root.appendingPathComponent(name + ".jsonl"); try data.write(to: path); return path.path
        }
        let followUp: WireValue = .object(["commandID": .string("c1"), "turnID": .string("t-follow"), "text": .string("and then summarize"), "attachments": .array([]), "skills": .array([])])
        let cut = try journal("cut", state: ["active": .bool(true), "queue": .array([followUp]), "steering": .array([]), "runStatus": .string("running"), "queuePaused": .bool(false)])
        let stopped = try journal("stopped", state: ["active": .bool(false), "queue": .array([followUp]), "steering": .array([]), "runStatus": .string("cancelled"), "queuePaused": .bool(true)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = [ChatRecord(id: "cut", workspaceID: "workspace", title: "Cut off", path: cut, profileID: "profile"),
                       ChatRecord(id: "stopped", workspaceID: "workspace", title: "Stopped", path: stopped, profileID: "profile")]

        await model.select("cut")
        let display = try XCTUnwrap(model.displays["cut"])
        XCTAssertEqual(display.state, "interrupted"); XCTAssertTrue(display.uncertain)
        XCTAssertTrue(display.presentedMessages.contains { $0.id == "failure:run:cut" }, "The interruption is said where the chat stopped, with Retry")
        XCTAssertTrue(display.canResumeQueue); XCTAssertTrue(display.queuePaused)
        XCTAssertEqual(QueuedMessage.from(display.queue).map(\.text), ["and then summarize"], "The paused follow-up is listed")
        XCTAssertEqual(display.messages.first { $0.id == "call" }?.tools?.first?.state, "unknown", "A call the run never answered is not shown as done")
        XCTAssertEqual(model.menuBarActivity().rows.first { $0.id == "cut" }?.phase, "paused")
        XCTAssertTrue(model.hosts.isEmpty, "Nothing starts until the reader acts")
        XCTAssertFalse(model.hasActiveWork, "Paused work retained in a journal does not hold quit or update")

        await model.select("stopped")
        let paused = try XCTUnwrap(model.displays["stopped"])
        XCTAssertEqual(paused.state, "paused"); XCTAssertFalse(paused.uncertain)
        XCTAssertTrue(paused.canResumeQueue); XCTAssertEqual(paused.queue.count, 1)
        XCTAssertFalse(paused.presentedMessages.contains { $0.kind == "failure" }, "A deliberate stop is no failure")
        XCTAssertEqual(paused.messages.first { $0.id == "call" }?.tools?.first?.state, "recorded", "Only a run cut off leaves its calls unknown")
        model.shutdown(); await model.store?.close()
    }
}

extension WorkspaceFailureTests {
    /// A journal whose last line was cut off (power loss, full disk) made the
    /// whole chat "Couldn't load this conversation", though every record but
    /// the last was intact. The complete records now show, read-only.
    @MainActor func testAChatWhoseLastRecordWasCutOffShowsEverythingBeforeItReadOnly() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("workspace-tail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data(), parent: String?
        func append(_ id: String, _ fields: [String: WireValue]) throws {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            data.append(try JSONEncoder().encode(record)); data.append(10); parent = id
        }
        try append("chat", ["type": .string("session"), "version": .number(3)]); parent = nil
        try append("native", ["type": .string("custom"), "customType": .string("pi-app.native.v1")])
        try append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Question")])])
        try append("answer", ["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .string("Answer")])])
        data.append(Data("{\"type\":\"message\",\"id\":\"x\"".utf8))
        let path = root.appendingPathComponent("cut.jsonl"); try data.write(to: path)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = [ChatRecord(id: "chat", workspaceID: "workspace", title: "Cut", path: path.path, profileID: "profile")]
        await model.select("chat")
        let display = try XCTUnwrap(model.displays["chat"])
        if case .failed(let reason) = display.historyState { XCTFail("The chat failed to load: \(reason)") }
        XCTAssertEqual(display.messages.map(\.id), ["question", "answer"], "Every complete record shows")
        XCTAssertTrue(display.damagedTail, "The chat is read-only, with Recover Copy in place of the composer")
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), data, "Reading changed nothing")
        model.shutdown(); await model.store?.close()
    }
}

/// A login Keychain that is locked until the test unlocks it.
private final class LockedKeychain: VaultStorage, @unchecked Sendable {
    private let lock = NSLock(), bytes: Data
    private var locked = true
    init(_ bytes: Data) { self.bytes = bytes }
    func unlock() { lock.lock(); locked = false; lock.unlock() }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; if locked { throw VaultError.denied(-25308) }; return bytes }
    func replace(expected: Data?, with replacement: Data) throws { throw VaultError.denied(-25308) }
}

extension WorkspaceFailureTests {
    /// With the Keychain locked at launch, the projects and connections were
    /// never read: every chat stayed "Project unavailable" after unlocking,
    /// until Settings happened to reload the vault.
    @MainActor func testSettingsLockedAtLaunchAreReadWhenTheAppIsNextActive() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("workspace-locked-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "locked-profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let project = WorkspaceRecord(id: "locked-project", path: root.path, trusted: true)
        var configuration = VaultConfiguration(); configuration.workspaces = [project]; configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic")]
        configuration.automaticUpdateChecks = false
        let keychain = LockedKeychain(try JSONEncoder().encode(configuration))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: keychain))
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        defer { model.report.suspend(); model.shutdown() }
        await model.restore()
        XCTAssertFalse(model.configurationLoaded); XCTAssertNil(model.workspace(for: project.id))
        keychain.unlock()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for _ in 0..<500 where !model.configurationLoaded || model.configurationRetry != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.configurationLoaded, "Unlocking and coming back to the app reads the settings")
        XCTAssertEqual(model.workspace(for: project.id)?.path, project.path)
        XCTAssertEqual(model.profiles.map(\.id), [profile.id])
        XCTAssertNil(model.configurationRetry, "Once read, it stops trying")
        XCTAssertEqual(model.selectedWorkspaceID, project.id); XCTAssertEqual(model.profileChoice, profile.id, "New Chat has a project and a connection again")
        try await model.traces.close(); await model.store?.close()
    }
}
