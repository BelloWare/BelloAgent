import XCTest
@testable import PiAgentCore

private final class DisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 1000
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Double) { lock.lock(); defer { lock.unlock() }; value = next }
}

private actor HeldDisplayClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var reply: ModelReply?
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func finish(_ value: ModelReply) { reply = value }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while reply == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        return reply!
    }
}

private actor DisplayTools: ToolExecuting {
    private var callback: (@Sendable (JSON) async -> Void)?
    private var held = true
    var ready: Bool { callback != nil }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "Fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { try await invoke(call, readOnly: readOnly, onUpdate: { _ in }) }
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON {
        callback = onUpdate
        while held { try await Task.sleep(nanoseconds: 1_000_000) }
        return resultText("Finished")
    }
    func progress(_ text: String) async { await callback?(resultText(text)) }
    func release() { held = false }
}

private actor HeldDisplayTraceSnapshot {
    private var held = true
    private(set) var started = false
    func read() async -> (latest: JSON, mode: String) {
        started = true
        while held { try? await Task.sleep(nanoseconds: 1_000_000) }
        return (.null, "memory")
    }
    func release() { held = false }
}

final class DisplayObservationTests: XCTestCase {
    func testOldestVisibleDeltaSurvivesStatusAndUnchangedProjectionPolls() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock(), client = HeldDisplayClient()
        let session = try AgentSession(id: "display", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await session.close() }
        let initial = await session.snapshot()
        XCTAssertTrue(initial["displayObservedAt"].isNull)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.ready }
        let started = await session.snapshot()
        XCTAssertTrue(started["displayObservedAt"].isNull, "User submission and empty assistant placeholder are not model deltas")
        clock.set(1100); try await client.emit(.text("first"))
        clock.set(1200); try await client.emit(.thinking("reasoning"))
        clock.set(1300); try await client.emit(.tool("call", "read", "{\"path\":"))
        let status = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(status["messages"].isNull); XCTAssertTrue(status["displayObservedAt"].isNull)
        let suppressed = await session.snapshot(["displayRevision": status["displayRevision"]])
        XCTAssertTrue(suppressed["messages"].isNull); XCTAssertTrue(suppressed["displayObservedAt"].isNull)
        let projected = await session.snapshot(["displayRevision": started["displayRevision"]])
        XCTAssertEqual(projected["displayObservedAt"].double, 1100, "Keep the earliest real display change, not snapshot time or latest delta")
        XCTAssertEqual(projected["messages"].list.last?["text"].text, "first")
        clock.set(1400)
        try await client.emit(.text("")); try await client.emit(.thinking("")); try await client.emit(.tool("call", "", ""))
        try await session.configureQueue(["followUpMode": "all"])
        let unchanged = await session.snapshot(["displayRevision": projected["displayRevision"]])
        XCTAssertTrue(unchanged["messages"].isNull); XCTAssertTrue(unchanged["displayObservedAt"].isNull)
        clock.set(1500); try await client.emit(.text(" next"))
        let next = await session.snapshot(["displayRevision": projected["displayRevision"]])
        XCTAssertEqual(next["displayObservedAt"].double, 1500, "Previously delivered timestamps must not contaminate the next display revision")
        clock.set(1600); await client.finish(answer("first next"))
        try await eventually { !(await session.isRunning) }
        let complete = await session.snapshot(["displayRevision": next["displayRevision"]])
        XCTAssertEqual(complete["displayObservedAt"].double, 1600)
        let idle = await session.snapshot(["displayRevision": complete["displayRevision"]])
        XCTAssertTrue(idle["displayObservedAt"].isNull)
    }

    func testDeltasBeyondDisplayedPreviewDoNotCreateUnrelatedTimingSamples() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock(), client = HeldDisplayClient()
        let session = try AgentSession(id: "bounded", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.ready }
        clock.set(2000); try await client.emit(.text(String(repeating: "x", count: 16384)))
        _ = await session.snapshot()
        clock.set(2100); try await client.emit(.text("x"))
        let truncated = await session.snapshot()
        XCTAssertEqual(truncated["displayObservedAt"].double, 2100, "The truncation indicator is a visible change")
        clock.set(2200); try await client.emit(.text(String(repeating: "x", count: 5000)))
        let hidden = await session.snapshot(["displayRevision": truncated["displayRevision"]])
        XCTAssertTrue(hidden["messages"].isNull); XCTAssertTrue(hidden["displayObservedAt"].isNull)
        clock.set(2300); try await client.emit(.thinking("visible reasoning"))
        let thinking = await session.snapshot(["displayRevision": truncated["displayRevision"]])
        XCTAssertEqual(thinking["displayObservedAt"].double, 2300, "An undisplayed text suffix must not be charged to a later reasoning update")
        await client.finish(answer("Completed")); try await eventually { !(await session.isRunning) }
    }

    func testDeltaDuringTraceSnapshotAwaitBelongsToNextProjection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock(), client = HeldDisplayClient(), traceSnapshot = HeldDisplayTraceSnapshot()
        let session = try AgentSession(id: "reentrant", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await traceSnapshot.release(); await session.close() }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.ready }
        clock.set(4000); try await client.emit(.text("Before await"))
        let firstTask = Task { await session.snapshot([:], traceSnapshot: { await traceSnapshot.read() }) }
        try await eventually { await traceSnapshot.started }
        clock.set(4100); try await client.emit(.text("; during await"))
        let status = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(status["displayObservedAt"].isNull)
        await traceSnapshot.release()
        let first = await firstTask.value
        XCTAssertEqual(first["displayObservedAt"].double, 4000)
        XCTAssertEqual(first["messages"].list.last?["text"].text, "Before await")
        let next = await session.snapshot(["displayRevision": first["displayRevision"]])
        XCTAssertEqual(next["displayObservedAt"].double, 4100, "The first snapshot must not erase a delta received after its message array was captured")
        XCTAssertEqual(next["messages"].list.last?["text"].text, "Before await; during await")
        clock.set(4200); await client.finish(answer("Completed")); try await eventually { !(await session.isRunning) }
    }

    func testCompletionAndCancellationKeepUndeliveredEarliestDelta() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let clock = DisplayClock(), client = HeldDisplayClient()
            let session = try AgentSession(id: cancel ? "cancelled" : "completed", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
            addTeardownBlock { await session.close() }
            _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
            try await eventually { await client.ready }
            clock.set(5000); try await client.emit(.text("First visible answer"))
            clock.set(5100)
            if cancel { await session.stop() } else { await client.finish(answer("First visible answer")) }
            try await eventually { !(await session.isRunning) }
            let snapshot = await session.snapshot()
            XCTAssertEqual(snapshot["displayObservedAt"].double, 5000, "Completing or saving a cancelled partial must retain the first undispatched model delta")
            XCTAssertEqual(snapshot["messages"].list.last?["text"].text, "First visible answer")
            await session.close()
        }
    }

    func testOffPageHistoryCannotContaminateVisibleObservation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock()
        var profile = try fixtureProfile().raw; profile["contextWindow"] = 1_000_000
        let replies = (0..<36).map { answer("Turn \($0): " + String(repeating: "x", count: 16_384)) }
        let session = try AgentSession(id: "off-page", profile: Profile(profile), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient(replies), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await session.close() }
        for index in 0..<35 {
            clock.set(Double(6000 + index))
            _ = try await session.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot["total"].int, 70)
        XCTAssertGreaterThan(snapshot["before"].int ?? 0, 10, "Exercise the serialized-byte limit as well as the 60-message window")
        XCTAssertLessThan(snapshot["messages"].list.count, 60)
        let firstVisible = try XCTUnwrap(snapshot["messages"].list.first { $0["role"].text == "assistant" })
        let firstIndex = try XCTUnwrap(firstVisible["text"].text?.split(separator: ":").first.flatMap { Int($0.dropFirst(5)) })
        XCTAssertEqual(snapshot["displayObservedAt"].double, Double(6000 + firstIndex), "Only observations for rows in this bounded projection contribute")
        let oldPage = await session.historyPage(before: 10)
        XCTAssertFalse(oldPage["messages"].list.isEmpty); XCTAssertTrue(oldPage["displayObservedAt"].isNull)
        clock.set(9000)
        _ = try await session.submit(Submission(commandID: "last", turnID: "last", text: "Last question"), steer: false)
        try await eventually { !(await session.isRunning) }
        let next = await session.snapshot(["displayRevision": snapshot["displayRevision"]])
        XCTAssertEqual(next["displayObservedAt"].double, 9000, "Earlier off-page observations must not be charged to a later visible turn")
    }

    func testCompactionSummaryIsObservedWhenItsNewMessageArrives() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock()
        let session = try AgentSession(id: "compact", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([answer("First answer"), answer("Second answer"), answer("Continuation summary")]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await session.close() }
        for index in 0..<2 {
            _ = try await session.submit(Submission(commandID: "turn-\(index)", turnID: "turn-\(index)", text: "Question \(index)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        let before = await session.snapshot()
        clock.set(10_000); try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        let after = await session.snapshot(["displayRevision": before["displayRevision"]])
        XCTAssertEqual(after["displayObservedAt"].double, 10_000)
        XCTAssertEqual(after["messages"].list.last?["text"].text, "Conversation summary:\nContinuation summary")
    }

    func testToolProgressAndCompletionUseOriginalObservationRatherThanStatusTime() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = DisplayClock(), tools = DisplayTools()
        let session = try AgentSession(id: "tools", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([toolReply(["first"]), answer("Done")]), tools: tools, traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Run tools"), steer: false)
        try await eventually { await tools.ready }
        let started = await session.snapshot()
        clock.set(3000); await tools.progress("First output")
        clock.set(3100); await tools.progress("First output")
        let status = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(status["displayObservedAt"].isNull)
        clock.set(3200); await tools.progress("More output")
        let progress = await session.snapshot(["displayRevision": started["displayRevision"]])
        XCTAssertEqual(progress["displayObservedAt"].double, 3000)
        XCTAssertTrue(progress["messages"].encoded().contains("More output"))
        clock.set(3300); await tools.progress("More output")
        let unchanged = await session.snapshot(["displayRevision": progress["displayRevision"]])
        XCTAssertTrue(unchanged["displayObservedAt"].isNull); XCTAssertTrue(unchanged["messages"].isNull)
        clock.set(3400); await tools.release(); try await eventually { !(await session.isRunning) }
        let completed = await session.snapshot(["displayRevision": progress["displayRevision"]])
        XCTAssertEqual(completed["displayObservedAt"].double, 3400)
        XCTAssertTrue(completed["messages"].list.contains { $0["role"].text == "tool" })
    }

    func testRestoredAndSideSeedHistoryHaveNoNewLiveObservation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), clock = DisplayClock(), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root)
        let first = try AgentSession(id: "saved", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([answer("Saved answer")]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false, displayClock: { clock.now() })
        _ = try await first.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { !(await first.isRunning) }
        let path = await first.path
        await first.close(); clock.set(9000)
        let restored = try AgentSession(id: "saved", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false, displayClock: { clock.now() })
        let snapshot = await restored.snapshot(), seed = await restored.sideSeed()
        XCTAssertFalse(snapshot["messages"].list.isEmpty); XCTAssertTrue(snapshot["displayObservedAt"].isNull)
        let side = try AgentSession(id: "side", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), seed: seed.messages, parent: seed.info, autoCompaction: false, displayClock: { clock.now() })
        let sideSnapshot = await side.snapshot()
        XCTAssertFalse(sideSnapshot["messages"].list.isEmpty); XCTAssertTrue(sideSnapshot["displayObservedAt"].isNull)
        await side.close(); await restored.close()
    }
}
