import XCTest
@testable import PiApp

final class WorkspaceFailureTests: XCTestCase {
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
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("workspace-failure-" + UUID().uuidString)
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
