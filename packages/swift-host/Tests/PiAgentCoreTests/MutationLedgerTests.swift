import Foundation
import XCTest
@testable import PiAgentCore

private final class MutationReplies: @unchecked Sendable {
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

final class MutationLedgerTests: XCTestCase {
    func testExpiredMutationsRemainRejectedAfterRecentBindingsAreEvicted() {
        var ledger = MutationLedger(recentLimit: 4)
        for index in 0..<10_000 { ledger.record("mutation-\(index)", fingerprint: "payload-\(index)") }
        XCTAssertNil(ledger.fingerprint(for: "mutation-0"))
        for index in 0..<9_996 { XCTAssertTrue(ledger.mayHaveExpired("mutation-\(index)"), "Eviction must never forget a previously executed mutation") }
        XCTAssertEqual(ledger.fingerprint(for: "mutation-9999"), "payload-9999")
        XCTAssertFalse(ledger.mayHaveExpired("fresh-command"))
    }

    func testReplayAfter4096MutationsCannotUndoQuiescenceAndFreshCommandsStillWork() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let replies = MutationReplies(), host = NativeHostService(emit: { replies.emit($0) })
        await host.receive(["v": 1, "kind": "hello", "major": 1])
        let epoch = await host.epoch
        func send(_ id: String, _ method: String, _ params: JSON = [:], session: String? = nil) async -> JSON {
            var frame: JSON = ["v": 1, "kind": "command", "hostEpoch": JSON(epoch), "commandId": JSON(id), "method": JSON(method), "params": params]
            if let session { frame["sessionId"] = JSON(session) }
            await host.receive(frame)
            return await replies.reply(id)
        }
        let opened = await send("open", "workspace.open", ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path)])
        XCTAssertEqual(opened["ok"].flag, true)
        let original = await send("old-resume", "workspace.resume")
        XCTAssertEqual(original["ok"].flag, true)
        for index in 0..<4_097 {
            let resumed = await send("resume-\(index)", "workspace.resume")
            XCTAssertEqual(resumed["ok"].flag, true, "The host must remain usable after 4096 mutations")
        }
        let quiesced = await send("quiesce", "workspace.quiesce")
        XCTAssertEqual(quiesced["ok"].flag, true)
        let replayed = await send("old-resume", "workspace.resume")
        XCTAssertEqual(replayed["error"]["code"].text, "command_result_expired")
        let conflict = await send("old-resume", "workspace.resume", ["changed": true])
        XCTAssertEqual(conflict["error"]["code"].text, "command_result_expired")
        let blocked = await send("check-quiescence", "session.open", [:], session: "proof")
        XCTAssertEqual(blocked["error"]["code"].text, "quiesced", "Replaying an expired resume must not mutate quiescence")
        let fresh = await send("fresh-resume", "workspace.resume")
        XCTAssertEqual(fresh["ok"].flag, true)
        let session = await send("fresh-session", "session.open", ["profile": try fixtureProfile().raw, "apiKey": "fixture"], session: "proof")
        XCTAssertEqual(session["ok"].flag, true)
        await host.shutdown()
    }
}
