import Foundation
import XCTest
@testable import PiAgentCore

final class OpeningProgressTests: HelperTestCase {
    func testProgressIsAdvancingBoundedAndRateLimited() {
        let clock = ProgressTestClock(), progress = JournalWorkProgress(clock: { clock.now }), values = OpeningFrames()
        _ = progress.observe { values.append(["completed":JSON(Double($0.completed)), "total":JSON(Double($0.total))]) }
        progress.update(1, of: 1_000_000, validating: true)
        progress.update(100_000, of: 1_000_000, validating: true)
        XCTAssertEqual(values.values.count, 1)
        clock.advance(0.25); progress.update(200_000, of: 1_000_000, validating: true)
        clock.advance(0.25); progress.update(200_000, of: 1_000_000, validating: true)
        progress.update(100_000, of: 1_000_000, validating: true)
        XCTAssertEqual(values.values.count, 2, "Repeated work is not progress")
        progress.update(500_000, of: 1_000_000)
        XCTAssertEqual(values.values.last?["completed"].int, 1_500_000)
        XCTAssertEqual(Set(values.values.compactMap { $0["total"].int }), [2_000_000])
        clock.advance(0.25); progress.update(4_000_000, of: 4_000_000)
        XCTAssertEqual(values.values.last?["completed"].int, 2_000_000, "The original bound cannot grow")
    }

    func testCancelDuringValidationAndReplayUnwindsBeforeAnotherWriterOpens() async throws {
        for fraction in [0.10, 0.35, 0.60, 0.90] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let profile = try fixtureProfile(), url = root.appendingPathComponent("chat.jsonl")
            do {
                let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: true)
                for n in 0..<256 {
                    try journal.append(["type":"message", "message":["role":"user", "content":JSON("Question \(n)\n" + String(repeating: "escaped \" text\n", count: 1024))]], id: "u\(n)", flush: false)
                }
            }
            let clock = ProgressTestClock(), frames = OpeningFrames(), gate = ProgressTestGate(fraction)
            defer { gate.release.signal() }
            let host = NativeHostService(emit: { frames.append($0) })
            await host.setOpeningProbe(clock: { clock.tick() }, step: { gate.step($0) })
            await host.receive(["v":1,"kind":"hello","major":1,"commandProgress":true])
            _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(root.path),"directory":JSON(root.path)])
            let epoch = await host.epoch
            await host.receive(["v":1,"kind":"command","hostEpoch":JSON(epoch),"commandId":"open","readToken":"cancel-token",
                "method":"session.open","sessionId":"chat","params":["profile":profile.raw,"apiKey":"fixture","path":JSON(url.path),"connectionTest":true]])
            try await eventually { gate.entered }
            // Foreign tokens, epochs and IDs cannot cancel this worker.
            for (e,id,token) in [("old", "open", "cancel-token"), (epoch,"other","cancel-token"), (epoch,"open","foreign")] {
                await host.receive(["v":1,"kind":"read.cancel","hostEpoch":JSON(e),"requestId":JSON(id),"readToken":JSON(token)])
            }
            await host.receive(["v":1,"kind":"read.cancel","hostEpoch":JSON(epoch),"requestId":"open","readToken":"cancel-token"])
            gate.release.signal()
            try await eventually { frames.values.contains { $0["kind"].text == "reply" && $0["commandId"].text == "open" } }
            let reply = try XCTUnwrap(frames.values.first { $0["kind"].text == "reply" && $0["commandId"].text == "open" })
            XCTAssertEqual(reply["result"]["code"].text, "command_cancelled")
            let last = try XCTUnwrap(frames.values.last { $0["kind"].text == "command.progress" })
            XCTAssertLessThan(Double(last["completed"].int!) / Double(last["total"].int!), fraction + 0.03,
                              "Cancellation must reach the detached loop, not just reject its eventual result")
            do { _ = try await host.command("session.status", sessionID: "chat", params: [:]); XCTFail("Cancelled session was adopted") }
            catch let error as AgentError { XCTAssertEqual(error.code, "session_missing") }
            do {
                let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: false)
                XCTAssertGreaterThan(journal.size, 0, "The writer lock was released before the failure reply")
            }
            _ = try await host.command("session.open", sessionID: "chat", params: ["profile":profile.raw,"apiKey":"fixture","path":JSON(url.path),"connectionTest":true])
            await host.shutdown()
        }
    }

    func testOldAppNeverReceivesAProgressFrame() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let frames = OpeningFrames(), host = NativeHostService(emit: { frames.append($0) })
        await host.receive(["v":1,"kind":"hello","major":1])
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(root.path),"directory":JSON(root.path)])
        await host.receive(["v":1,"kind":"command","hostEpoch":JSON(await host.epoch),"commandId":"open","method":"session.open","sessionId":"chat",
            "params":["profile":try fixtureProfile().raw,"apiKey":"fixture","connectionTest":true]])
        try await eventually { frames.values.contains { $0["kind"].text == "reply" } }
        XCTAssertFalse(frames.values.contains { $0["kind"].text == "command.progress" })
        await host.shutdown()
    }

    func testLateSuccessCanWithdrawOnlyItsOwnOpeningAndKeepsQueuedInput() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), url = root.appendingPathComponent("chat.jsonl")
        let queued = Submission(commandID: "pending", turnID: "next", text: "Keep this pending question")
        do {
            let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: true)
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.state),
                "data":["active":false,"runStatus":"idle","queue":[queued.savedValue],"steering":[],"queuePaused":true]])
        }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(root.path),"directory":JSON(root.path)])
        let params: JSON = ["profile":profile.raw,"apiKey":"fixture","path":JSON(url.path),"connectionTest":true]
        _ = try await host.command("session.open", sessionID: "chat", params: params, commandID: "original")
        do {
            _ = try await host.command("session.close", sessionID: "chat", params: ["openingCommandId":"foreign"])
            XCTFail("A foreign opening must not withdraw recovered queued work")
        } catch let error as AgentError { XCTAssertEqual(error.code, "session_busy") }
        _ = try await host.command("session.close", sessionID: "chat", params: ["openingCommandId":"original"])
        do {
            let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: false)
            XCTAssertGreaterThan(journal.size, 0)
        }
        let reopened = try await host.command("session.open", sessionID: "chat", params: params, commandID: "new")
        XCTAssertEqual(reopened["queue"].list.first?["text"].text, "Keep this pending question")
        _ = try await host.command("session.open", sessionID: "chat", params: params, commandID: "shared")
        do {
            _ = try await host.command("session.close", sessionID: "chat", params: ["openingCommandId":"new"])
            XCTFail("A second open retired the first opening's withdrawal authority")
        } catch let error as AgentError { XCTAssertEqual(error.code, "session_busy") }
        await host.shutdown()
    }

    func testSharedWorkerForwardsOnlyAdvancingWorkToEachReader() {
        let clock = ProgressTestClock(), source = JournalWorkProgress(clock: { clock.tick() })
        let reader = JournalWorkProgress(), frames = OpeningFrames()
        _ = reader.observe { frames.append(["completed":JSON(Double($0.completed))]) }
        source.update(1, of: 1_000_000)
        let token = source.forward(to: reader)!
        source.update(100_000, of: 1_000_000)
        source.update(100_000, of: 1_000_000)
        source.remove(token); source.update(200_000, of: 1_000_000)
        XCTAssertEqual(frames.values.compactMap { $0["completed"].int }, [1,100_000])
    }
    func testCancelledReplayNeverClaimsTheJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), url = root.appendingPathComponent("chat.jsonl")
        do {
            let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: true)
            for n in 0..<40 { try journal.append(["type":"message", "message":["role":"user", "content":JSON("Question \(n)")]], id: "u\(n)") }
        }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let opening = Task.detached {
            entered.signal(); release.wait()
            return try AgentSession(id: "chat", profile: profile, apiKey: "fixture", cwd: root, directory: root,
                readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                tools: RecordingTools(), traces: TraceStore(), resumePath: url.path)
        }
        entered.wait(); opening.cancel(); release.signal()
        do { let session = try await opening.value; await session.close(); XCTFail("A cancelled replay must not adopt a session") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        // An independent writer can take the same lock immediately after unwind.
        let journal = try SessionJournal(url: url, id: "chat", cwd: root, binding: profile.binding, create: false)
        XCTAssertGreaterThan(journal.size, 0)
    }

    func testReadyAdvertisesNegotiatedOpeningProgress() async {
        let frames = OpeningFrames(), host = NativeHostService(emit: { frames.append($0) })
        await host.receive(["v":1, "kind":"hello", "major":1, "commandProgress":true])
        XCTAssertTrue(frames.values.first?["capabilities"].list.contains("command-progress-v1") == true)
        XCTAssertTrue(frames.values.first?["capabilities"].list.contains("open-cancel-v1") == true)
        await host.shutdown()
    }
}

private final class ProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
    func tick() -> Double { lock.lock(); defer { lock.unlock() }; value += 0.25; return value }
}
private final class ProgressTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    let fraction: Double, release = DispatchSemaphore(value: 0)
    init(_ fraction: Double) { self.fraction = fraction }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return held }
    func step(_ value: JournalWorkProgress.Value) {
        lock.lock()
        let hold = !held && Double(value.completed) / Double(value.total) >= fraction
        if hold { held = true }; lock.unlock()
        if hold { release.wait() }
    }
}
private extension NativeHostService {
    func setOpeningProbe(clock: @escaping @Sendable () -> Double, step: @escaping @Sendable (JournalWorkProgress.Value) -> Void) {
        journalProgressClock = clock; journalProgressStep = step
    }
}

private final class OpeningFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSON] = []
    var values: [JSON] { lock.lock(); defer { lock.unlock() }; return frames }
    func append(_ frame: JSON) { lock.lock(); frames.append(frame); lock.unlock() }
}
