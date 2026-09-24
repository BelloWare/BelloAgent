import Foundation
import XCTest
@testable import PiAgentCore

private final class HostReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: JSON] = [:], waiting: [String: CheckedContinuation<JSON, Never>] = [:]
    func emit(_ value: JSON) {
        guard value["kind"].text == "reply", let id = value["commandId"].text else { return }
        lock.lock()
        if let continuation = waiting.removeValue(forKey: id) { lock.unlock(); continuation.resume(returning: value) }
        else { replies[id] = value; lock.unlock() }
    }
    func reply(_ id: String) async -> JSON {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value = replies.removeValue(forKey: id) { lock.unlock(); continuation.resume(returning: value) }
            else { waiting[id] = continuation; lock.unlock() }
        }
    }
}

/// The host between the app and its chats: what it keeps of the replies it
/// sent, and whether one chat opening can hold up the others.
final class HostServiceTests: XCTestCase {
    func testReadRepliesAreNotKeptForReplayButMutationRepliesAre() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let replies = HostReplies(), host = NativeHostService(emit: { replies.emit($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1]); let epoch = await host.epoch
        func send(_ id: String, _ method: String, _ params: JSON = [:], session: String? = nil) async -> JSON {
            var frame: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": JSON(id), "method": JSON(method), "params": params]
            if let session { frame["sessionId"] = JSON(session) }
            await host.receive(frame); return await replies.reply(id)
        }
        _ = await send("workspace", "workspace.open", ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)])
        let openParams: JSON = ["profile": try fixtureProfile().raw, "apiKey": "fixture"]
        let opened = await send("open", "session.open", openParams, session: "s")
        XCTAssertEqual(opened["ok"].flag, true, opened.encoded())
        for index in 0..<600 {
            let read = await send("read-\(index)", "session.snapshot", [:], session: "s")
            XCTAssertEqual(read["ok"].flag, true)
        }
        let cached = await host.cachedReplies
        print("PERF host-reply-cache reads=600 cachedReplies=\(cached.count) cachedBytes=\(cached.bytes)")
        XCTAssertEqual(cached.count, 2, "only the two mutations are kept for an identical retry; reads are answered again")
        let again = await send("read-0", "session.snapshot", [:], session: "s")
        XCTAssertEqual(again["ok"].flag, true, "a repeated read runs again and answers")
        let replayed = await send("open", "session.open", openParams, session: "s")
        XCTAssertEqual(replayed, opened, "a repeated mutation is answered from the cache, not run twice")
        await host.shutdown()
    }

    /// The chat's capture mode rides on its open: the reply names the mode
    /// applied, so the app sends no `debug.mode` before its first turn. A
    /// mode the helper does not know opens nothing.
    func testSessionOpenAppliesTheCaptureModeItCarries() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let replies = HostReplies(), host = NativeHostService(emit: { replies.emit($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1]); let epoch = await host.epoch
        func send(_ id: String, _ method: String, _ params: JSON = [:], session: String? = nil) async -> JSON {
            var frame: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": JSON(id), "method": JSON(method), "params": params]
            if let session { frame["sessionId"] = JSON(session) }
            await host.receive(frame); return await replies.reply(id)
        }
        _ = await send("workspace", "workspace.open", ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)])
        let profile = try fixtureProfile().raw
        let refused = await send("bad", "session.open", ["profile": profile, "apiKey": "fixture", "captureMode": "everything"], session: "s")
        XCTAssertEqual(refused["ok"].flag, false, refused.encoded())
        XCTAssertEqual(refused["result"]["code"].text, "invalid_mode")
        let missing = await send("status", "session.status", [:], session: "s")
        XCTAssertEqual(missing["result"]["code"].text, "session_missing", "a refused mode opens no session")
        let opened = await send("open", "session.open", ["profile": profile, "apiKey": "fixture", "captureMode": "off"], session: "s")
        XCTAssertEqual(opened["ok"].flag, true, opened.encoded())
        XCTAssertEqual(opened["result"]["captureMode"].text, "off")
        let listed = await send("list", "debug.list", [:], session: "s")
        XCTAssertEqual(listed["ok"].flag, true, listed.encoded())
        let again = await send("reopen", "session.open", ["profile": profile, "apiKey": "fixture", "captureMode": "memory"], session: "s")
        XCTAssertEqual(again["result"]["captureMode"].text, "memory", "an open of a loaded session applies the mode too")
        let plain = await send("plain", "session.open", ["profile": profile, "apiKey": "fixture"], session: "s")
        XCTAssertEqual(plain["result"]["captureMode"].text, "memory", "an open without a mode reports the one in force, which the app compares")
        await host.shutdown()
    }

    /// The app opts in to the recorded tool outcomes in its hello; the ready
    /// frame says the helper offers them, and every chat it opens uses them.
    func testTheHelloChoosesTheToolCardStatesEveryChatReports() async throws {
        for asked in [true, false] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let frames = ReadyFrames(), replies = HostReplies()
            let host = NativeHostService(emit: { frames.emit($0); replies.emit($0) })
            var hello: JSON = ["v": 1, "kind": "hello", "major": 1]
            if asked { hello["unknownToolOutcomes"] = true }
            await host.receive(hello); let epoch = await host.epoch
            XCTAssertTrue(frames.ready?["capabilities"].list.contains("tool-outcome-unknown") == true)
            let workspace: JSON = ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)]
            let open: JSON = ["profile": try fixtureProfile().raw, "apiKey": "fixture"]
            for (id, method, params, session) in [("w", "workspace.open", workspace, nil as String?), ("o", "session.open", open, "s")] {
                var frame: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": JSON(id), "method": JSON(method), "params": params]
                if let session { frame["sessionId"] = JSON(session) }
                await host.receive(frame); let reply = await replies.reply(id)
                XCTAssertEqual(reply["ok"].flag, true, reply.encoded())
            }
            let reports = await host.loadedSession("s")?.reportsUnknownToolOutcomes
            XCTAssertEqual(reports, asked)
            await host.shutdown()
        }
    }

    func testOpeningALongChatDoesNotHoldUpTheOthers() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), profile = try fixtureProfile()
        let path = directory.appendingPathComponent("long.jsonl")
        do {
            let journal = try SessionJournal(url: path, id: "long", cwd: root, binding: profile.binding, create: true)
            for index in 0..<12_000 {
                var message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: [textBlock("Message \(index) " + String(repeating: "x", count: 200))])
                message.id = "m-\(index)"
                try journal.append(["type": "message", "message": message.pi], id: message.id, flush: false)
            }
            try journal.append(["type": "custom", "customType": "pi-app.native.state.v1", "data": ["active": false, "queue": [], "steering": [], "commands": [], "queuePaused": false]], flush: true)
        }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(directory.path)])
        _ = try await host.command("session.open", sessionID: "quick", params: ["profile": profile.raw, "apiKey": "fixture"])
        let openedAt = nowMS()
        let opening = Task { try await host.command("session.open", sessionID: "long", params: ["profile": profile.raw, "apiKey": "fixture", "path": JSON(path.path)]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        var worst = 0.0
        for _ in 0..<5 {
            let asked = nowMS()
            _ = try await host.command("session.snapshot", sessionID: "quick", params: ["includeMessages": false])
            worst = max(worst, nowMS() - asked)
        }
        let long = try await opening.value
        let openMs = nowMS() - openedAt
        print("PERF open-long-chat messages=12000 openMs=\(Int(openMs)) otherChatWorstMs=\(Int(worst))")
        XCTAssertEqual(long["total"].int, 12_000)
        XCTAssertGreaterThan(openMs, 150, "the journal is long enough to measure")
        XCTAssertLessThan(worst, openMs / 3, "another chat is answered while the long one is still opening")
        await host.shutdown()
    }
}

private final class ReadyFrames: @unchecked Sendable {
    private let lock = NSLock(); private var frame: JSON?
    func emit(_ value: JSON) { guard value["kind"].text == "ready" else { return }; lock.lock(); frame = value; lock.unlock() }
    var ready: JSON? { lock.lock(); defer { lock.unlock() }; return frame }
}

/// A journal whose last record was cut off could not be reopened, and the
/// recovery the app offered was rejected outright. `session.recover` copies
/// every complete record to a new chat and leaves the original as it was.
final class SessionRecoverTests: XCTestCase {
    private func journal(_ lines: [JSON], tail: String) throws -> Data {
        var data = Data(); for line in lines { data.append(try line.data()); data.append(10) }
        data.append(Data(tail.utf8)); return data
    }
    private func open(_ root: URL) async throws -> (NativeHostService, URL) {
        let host = NativeHostService(emit: { _ in }), sessions = root.appendingPathComponent("state/Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(sessions.path), "mcp": ["servers": [:]]])
        return (host, sessions)
    }
    func testRecoverCopiesTheCompleteRecordsUnderANewIdentityAndLeavesTheOriginal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (host, sessions) = try await open(root)
        let header: JSON = ["type": "session", "version": 3, "id": "original", "cwd": JSON(root.path), "timestamp": "2026-09-01T00:00:00Z"]
        let records: [JSON] = [header,
            ["type": "custom", "customType": "pi-app.native.v1", "data": ["binding": ["api": "fixture"], "version": 1], "id": "n1", "parentId": .null],
            ["type": "message", "message": ["role": "user", "content": "Question"], "id": "u1", "parentId": "n1"],
            ["type": "message", "message": ["role": "assistant", "content": "Answer"], "id": "a1", "parentId": "u1"]]
        let source = sessions.appendingPathComponent("original.jsonl"), damaged = try journal(records, tail: "{\"type\":\"message\",\"id\":\"x\"")
        try damaged.write(to: source)
        let result = try await host.command("session.recover", sessionID: nil, params: ["path": JSON(source.path), "newSessionId": "recovered"])
        XCTAssertEqual(result["sessionId"].text, "recovered"); XCTAssertEqual(result["records"].int, 3)
        let copy = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(result["sessionFile"].text)))
        let lines = copy.split(separator: 10).map { try? JSON.parse(Data($0)) }
        XCTAssertEqual(copy.last, 10, "The copy ends on a complete record")
        XCTAssertEqual(lines.count, 4); XCTAssertEqual(lines.first??["id"].text, "recovered")
        XCTAssertEqual(lines.first??["cwd"].text, root.path, "Only the identity of the header changes")
        XCTAssertEqual(Array(copy.split(separator: 10).dropFirst()), Array(damaged.split(separator: 10).dropFirst().dropLast()), "Every complete record, byte for byte")
        XCTAssertEqual(try Data(contentsOf: source), damaged, "The original is untouched")
        do { _ = try await host.command("session.recover", sessionID: nil, params: ["path": JSON(source.path), "newSessionId": "recovered"]); XCTFail("An existing chat is never replaced") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sessions.path).allSatisfy { !$0.hasPrefix(".recover-") }, "No temporary file is left")
        await host.shutdown()
    }
    func testRecoverRefusesDamageBeforeTheLastRecordAndPathsOutsideTheProject() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (host, sessions) = try await open(root)
        let broken: [JSON] = [["type": "session", "version": 3, "id": "broken"],
            ["type": "custom", "customType": "pi-app.native.v1", "data": ["binding": ["api": "fixture"], "version": 1], "id": "n1", "parentId": .null],
            ["type": "message", "message": ["role": "user", "content": "Question"], "id": "u1", "parentId": "missing"]]
        let source = sessions.appendingPathComponent("broken.jsonl"); try journal(broken, tail: "{").write(to: source)
        do { _ = try await host.command("session.recover", sessionID: nil, params: ["path": JSON(source.path), "newSessionId": "copy"]); XCTFail("A broken branch is not recovered") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "session_damaged") }
        let outside = root.appendingPathComponent("elsewhere.jsonl"); try Data(contentsOf: source).write(to: outside)
        do { _ = try await host.command("session.recover", sessionID: nil, params: ["path": JSON(outside.path), "newSessionId": "copy"]); XCTFail("Only the project's own chats") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "invalid_path") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("copy.jsonl").path))
        await host.shutdown()
    }
}
