import Foundation
import XCTest
@testable import PiAgentCore

private final class DispatchReplies: @unchecked Sendable {
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

/// What each command needs before the host runs it. The host checks, in
/// order, that it is not closing, that a workspace is open, that the
/// command names a session, that the session is loaded, and that the
/// workspace is not quiesced; a command stops at the first check it needs
/// and fails. A command the host does not know goes through every check
/// before it is refused. Which commands are read-only, and so run again on
/// a repeat instead of answering from the kept reply, is pinned here too.
final class HostDispatchTests: XCTestCase {
    /// Every command the host answers, by the last of those checks it needs.
    private static let stages: [(stage: Int, methods: [String])] = [
        (0, ["display.result.read"]),
        (1, ["runtime.info", "clock.sync", "workspace.open"]),
        (2, ["workspace.quiesce", "workspace.resume", "resources.configure", "resources.inspect", "resources.skill.read", "mcp.configure", "mcp.list", "mcp.describe",
             "mcp.acknowledgeUnknown", "connection.test", "session.open", "session.portable.preview", "session.import.inspect", "session.recover", "journal.slim",
             "session.import.continue", "session.import.recover"]),
        (3, ["debug.list", "debug.body", "debug.attempt", "debug.raw-events", "debug.mode", "debug.clear", "session.forget"]),
        (4, ["turn.stop", "session.status", "session.edit.prepare", "session.snapshot", "context.info", "context.preview", "context.preview.read", "context.preview.clear",
             "session.history", "session.message.read", "session.tool.input", "session.content.search", "session.content.page", "session.event-page", "session.events",
             "session.versions", "session.version.page", "session.fork", "side.open", "side.keep", "side.close"]),
        (5, ["turn.submit", "turn.steer", "turn.edit", "queue.remove", "queue.reorder", "queue.read", "queue.update", "queue.steer", "queue.resume", "turn.retry",
             "queue.configure", "context.compact", "mcp.invoke", "session.configure", "session.close"]),
    ]
    /// Commands that refuse a quiesced workspace themselves, at an earlier stage.
    private static let refusedWhenQuiesced: Set<String> = ["connection.test", "session.open", "session.fork", "side.open"]

    private enum State { case closing, noWorkspace, noSessionID, unknownSession, quiesced, ready }

    /// The error code `method`, with no parameters, ends with in `state`, or
    /// "ok"; each on a host of its own.
    private func outcome(_ method: String, in state: State) async throws -> String {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        var session: String?
        switch state {
        case .closing: await host.shutdown()
        case .noWorkspace: break
        case .noSessionID, .unknownSession, .quiesced, .ready:
            _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)])
            if state == .unknownSession { session = "ghost" }
            if state == .quiesced || state == .ready {
                _ = try await host.command("session.open", sessionID: "s", params: ["profile": try fixtureProfile().raw, "apiKey": "fixture"])
                session = "s"
            }
            if state == .quiesced { _ = try await host.command("workspace.quiesce", sessionID: nil, params: [:]) }
        }
        let result: String
        do { _ = try await host.command(method, sessionID: session, params: [:]); result = "ok" }
        catch let error as AgentError { result = error.code }
        catch { result = String(describing: type(of: error)) }
        await host.shutdown()
        return result
    }

    private var missingIdentityCode: String {
        do { _ = try identity(.null); return "none" } catch { return (error as? AgentError)?.code ?? "none" }
    }

    func testEachCommandStopsAtTheFirstCheckItNeedsAndFails() async throws {
        let missingIdentity = missingIdentityCode
        for (stage, methods) in Self.stages {
            for method in methods {
                let closing = try await outcome(method, in: .closing)
                if stage == 0 { XCTAssertNotEqual(closing, "closing", method) } else { XCTAssertEqual(closing, "closing", method) }
                let noWorkspace = try await outcome(method, in: .noWorkspace)
                if stage <= 1 { XCTAssertNotEqual(noWorkspace, "workspace_required", method) } else { XCTAssertEqual(noWorkspace, "workspace_required", method) }
                if stage >= 3 {
                    let noSessionID = try await outcome(method, in: .noSessionID)
                    XCTAssertEqual(noSessionID, missingIdentity, method)
                }
                let unknownSession = try await outcome(method, in: .unknownSession)
                if stage <= 3 { XCTAssertNotEqual(unknownSession, "session_missing", method) } else { XCTAssertEqual(unknownSession, "session_missing", method) }
                let quiesced = try await outcome(method, in: .quiesced)
                if stage == 5 { XCTAssertEqual(quiesced, "closing", method) }
                else if Self.refusedWhenQuiesced.contains(method) { XCTAssertEqual(quiesced, "quiesced", method) }
                else { XCTAssertFalse(["closing", "quiesced"].contains(quiesced), "\(method): \(quiesced)") }
            }
        }
    }

    func testACommandTheHostDoesNotKnowGoesThroughEveryCheck() async throws {
        var seen: [String] = []
        for state: State in [.closing, .noWorkspace, .noSessionID, .unknownSession, .quiesced, .ready] { seen.append(try await outcome("session.madeUp", in: state)) }
        XCTAssertEqual(seen, ["closing", "workspace_required", missingIdentityCode, "session_missing", "closing", "unsupported_command"])
    }

    func testOnlyCommandsThatChangeNothingRunAgainOnARepeat() async throws {
        var readOnly: Set<String> = []
        for method in Self.stages.flatMap(\.methods) + ["session.content.anything", "session.madeUp"] {
            let replies = DispatchReplies(), host = NativeHostService(emit: { replies.emit($0) })
            await host.receive(["v": 1, "kind": "hello", "major": 1]); let epoch = await host.epoch
            await host.receive(["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": "c", "method": JSON(method), "params": [:]])
            _ = await replies.reply("c")
            if await host.cachedReplies.count == 0 { readOnly.insert(method) }
            await host.shutdown()
        }
        XCTAssertEqual(readOnly, ["display.result.read", "clock.sync", "runtime.info", "resources.inspect", "resources.skill.read",
                                  "session.content.search", "session.content.page", "session.content.anything",
                                  "session.status", "session.snapshot", "session.history", "session.versions", "session.version.page", "session.message.read",
                                  "session.edit.prepare", "session.tool.input", "queue.read", "session.events", "session.event-page", "context.info",
                                  "context.preview", "context.preview.read", "context.preview.clear", "mcp.list", "mcp.describe", "debug.list", "debug.body",
                                  "debug.attempt", "debug.raw-events", "session.portable.preview", "session.import.inspect"])
    }
}
