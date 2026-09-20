import XCTest
@testable import PiAgentCore

/// Saving a connection never waits for its chats: a run that is going keeps
/// the settings it started with and the next turn uses the new ones; an idle
/// session switches at once, without being closed and reopened.
final class SessionConfigureTests: XCTestCase {
    func testSettingsSavedDuringARunApplyWhenItEndsAndAtOnceWhenIdle() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("first"), answer("second"), answer("third")], holdFirst: true)
        let session = try AgentSession(id: "cfg", profile: fixtureProfile(), apiKey: "old-key", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "go"), steer: false)
        try await eventually { await client.count == 1 }
        var raw = try fixtureProfile().raw; raw["name"] = "Renamed"; raw["maxOutputTokens"] = 2048; raw["modelOutputLimit"] = 8192
        let updated = try Profile(raw)
        let appliedDuringRun = try await session.configure(profile: updated, apiKey: "new-key")
        XCTAssertFalse(appliedDuringRun, "a run in flight keeps the settings it started with")
        let running = await session.snapshot()
        XCTAssertEqual(running["settingsPending"].flag, true); XCTAssertEqual(running["state"].text, "running")
        let stillOld = await session.profile; XCTAssertEqual(stillOld.maxOutput, 4096)
        await client.release(); try await eventually { !(await session.isRunning) }
        let settled = await session.snapshot()
        XCTAssertEqual(settled["settingsPending"].flag, false); XCTAssertEqual(settled["state"].text, "idle")
        let switched = await session.profile; XCTAssertEqual(switched.maxOutput, 2048); XCTAssertEqual(switched.raw["name"].text, "Renamed")
        _ = try await session.submit(Submission(commandID: "b", turnID: "b", text: "again"), steer: false)
        try await eventually { !(await session.isRunning) }
        // Idle: the next settings are in use immediately.
        let appliedIdle = try await session.configure(profile: fixtureProfile(), apiKey: "third-key")
        XCTAssertTrue(appliedIdle)
        _ = try await session.submit(Submission(commandID: "c", turnID: "c", text: "once more"), steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles, keys = await client.keys
        XCTAssertEqual(profiles.map(\.maxOutput), [4096, 2048, 4096], "the first request kept the old settings; the next two used what was saved")
        XCTAssertEqual(profiles.map(\.wireOutputLimit), [nil, 8192, nil])
        XCTAssertEqual(keys, ["old-key", "new-key", "third-key"])
        let messages = (await session.snapshot())["messages"].list
        XCTAssertEqual(messages.filter { $0["role"].text == "assistant" }.map { $0["text"].text }, ["first", "second", "third"])
        await session.close()
    }

    func testTheHostCommandReportsWhetherTheSettingsAreInUse() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "cfg", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "toolMode": "read-only"])
        var raw = try fixtureProfile().raw; raw["name"] = "Renamed"
        let result = try await host.command("session.configure", sessionID: "cfg", params: ["profile": raw, "apiKey": "synthetic-2"])
        XCTAssertEqual(result["applied"].flag, true)
        let status = try await host.command("session.status", sessionID: "cfg", params: [:])
        XCTAssertEqual(status["settingsPending"].flag, false)
        for invalid: JSON in [["profile": "not an object"], ["profile": [:]]] {
            do { _ = try await host.command("session.configure", sessionID: "cfg", params: invalid); XCTFail("an invalid profile must be refused") }
            catch let error as AgentError { XCTAssertTrue(["invalid_profile", "invalid_params", "invalid_range"].contains(error.code), error.code) }
        }
        await host.shutdown()
    }

    func testConfigureCannotChangeTheJournalRouteBinding() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in }), original = try fixtureProfile().raw
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "cfg", params: ["profile": original, "apiKey": "synthetic", "toolMode": "read-only"])
        for (field, value) in [("modelId", "another-model"), ("baseUrl", "http://127.0.0.1:12346/v1")] {
            var changed = original; changed[field] = JSON(value)
            do {
                _ = try await host.command("session.configure", sessionID: "cfg", params: ["profile": changed, "apiKey": "replacement"])
                XCTFail("Changing \(field) needs a separate bound session")
            } catch let error as AgentError { XCTAssertEqual(error.code, "session_conflict") }
            let info = try await host.command("context.info", sessionID: "cfg", params: [:])
            XCTAssertEqual(info["profile"], original, "A rejected configure must leave the current session intact")
        }
        let fork = try await host.command("session.fork", sessionID: "cfg", params: ["forkSessionId": "fork"])
        XCTAssertEqual(fork["accepted"].flag, true, "The host's saved profile must also retain the accepted binding")
        await host.shutdown()
    }

    func testToolRoundsAndQueuedTurnsKeepConfigurationUntilTheWholeRunSettles() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([toolReply(["first"]), answer("first finished"), answer("queued finished"), answer("new settings")], holdFirst: true)
        let session = try AgentSession(id: "cfg", profile: fixtureProfile(), apiKey: "old-key", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First", model: "first-model", thinkingLevel: "high"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "queued", turnID: "queued", text: "Queued", model: "queued-model", thinkingLevel: "low"), steer: false)
        var changed = try fixtureProfile().raw; changed["maxOutputTokens"] = 2048
        _ = try await session.configure(profile: Profile(changed), apiKey: "superseded-key")
        changed["maxOutputTokens"] = 1024
        _ = try await session.configure(profile: Profile(changed), apiKey: "latest-key")
        let held = try await session.prepareContext(["text": "Unsent draft", "model": "draft-model"])
        XCTAssertEqual(held["model"].text, "first-model")
        await client.release(); try await eventually { !(await session.isRunning) }
        _ = try await session.submit(Submission(commandID: "next", turnID: "next", text: "Next"), steer: false)
        try await eventually { !(await session.isRunning) }
        let profiles = await client.profiles, keys = await client.keys
        XCTAssertEqual(profiles.map(\.model), ["first-model", "first-model", "queued-model", "fixture-model"])
        XCTAssertEqual(profiles.map(\.maxOutput), [4096, 4096, 4096, 1024])
        XCTAssertEqual(keys, ["old-key", "old-key", "old-key", "latest-key"])
        await session.close()
    }
}
