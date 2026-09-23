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
