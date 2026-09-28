import XCTest
@testable import PiAgentCore

/// How long a long chat takes to open: the journal written by the real run
/// loop (a tool call, an 8 KB result and an answer per turn), then read back
/// the way `session.open` reads it. Opt-in with `PI_PERF_SESSION_TURNS`; it
/// prints its figures and asserts only that the reopened chat is the same.
final class SessionOpenPerformanceTests: XCTestCase {
    private actor BulkTools: ToolExecuting {
        func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "test", [:])] }
        func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
            resultText(String(repeating: "Line of tool output with some words in it.\n", count: 190))
        }
    }

    /// `PI_PERF_OPEN_JOURNAL`: open a journal this test kept earlier
    /// (`PI_PERF_KEEP_JOURNAL`) without writing one, for profiling the open.
    func testOpeningAKeptJournal() async throws {
        guard let kept = ProcessInfo.processInfo.environment["PI_PERF_OPEN_JOURNAL"] else {
            throw XCTSkip("Set PI_PERF_OPEN_JOURNAL to a journal kept with PI_PERF_KEEP_JOURNAL.")
        }
        // Opened where it is: a long journal need not be copied to be measured.
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), path = URL(fileURLWithPath: kept), directory = path.deletingLastPathComponent()
        let repeats = ProcessInfo.processInfo.environment["PI_PERF_REPEAT"].flatMap(Int.init) ?? 3
        for attempt in 1...repeats {
            let clock = ContinuousClock(), start = clock.now
            let reader = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                          resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: BulkTools(), traces: TraceStore(),
                                          resumePath: path.path, autoCompaction: false)
            let opened = clock.now - start
            let snapshot = await reader.snapshot()
            XCTAssertNotNil(snapshot["messages"].list.last)
            print("PERF kept journal open \(attempt): open \(opened.formatted(.units(allowed: [.milliseconds])))")
            await reader.close()
        }
    }

    func testOpeningALongChat() async throws {
        guard let turns = ProcessInfo.processInfo.environment["PI_PERF_SESSION_TURNS"].flatMap(Int.init), turns > 0 else {
            throw XCTSkip("Set PI_PERF_SESSION_TURNS to measure opening a long chat.")
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), directory = root.appendingPathComponent("state")
        let reply = String(repeating: "A paragraph of the assistant's answer, long enough to be realistic. ", count: 24)
        // `PI_PERF_COMPACT_EVERY`: a compaction every so many turns, as a long
        // chat has them.
        let every = ProcessInfo.processInfo.environment["PI_PERF_COMPACT_EVERY"].flatMap(Int.init) ?? 0
        var replies: [ModelReply] = []
        for turn in 0..<turns {
            replies.append(toolReply(["first"])); replies.append(answer(reply))
            if every > 0, (turn + 1) % every == 0 { replies.append(answer("Summary of the turns so far: files were read and summarised.")) }
        }
        let client = ScriptClient(replies)
        let writer = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                      resources: Resources(cwd: root, home: root), client: client, tools: BulkTools(), traces: TraceStore(), autoCompaction: false)
        let started = Date()
        for turn in 0..<turns {
            _ = try await writer.submit(Submission(commandID: "c\(turn)", turnID: "t\(turn)", text: "Question \(turn): please look at the file and summarise it."), steer: false)
            var waited = 0
            while await writer.isRunning, waited < 2_000 { try await Task.sleep(nanoseconds: 1_000_000); waited += 1 }
            if every > 0, (turn + 1) % every == 0 {
                try await writer.compact(commandID: "compact-\(turn)")
                waited = 0
                while await writer.isRunning, waited < 2_000 { try await Task.sleep(nanoseconds: 1_000_000); waited += 1 }
            }
        }
        let written = await writer.snapshot()
        let path = try XCTUnwrap(written["path"].text)
        let expected = await writer.context.map(\.id)
        await writer.close()
        let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "PERF session open: wrote %d turns (%.1f MB) in %.1f s", turns, Double(bytes) / 1_048_576, Date().timeIntervalSince(started)))

        for attempt in 1...3 {
            let clock = ContinuousClock(), start = clock.now
            let reader = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                          resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: BulkTools(), traces: TraceStore(),
                                          resumePath: path, autoCompaction: false)
            let opened = clock.now - start
            let snapshot = await reader.snapshot()
            let shown = clock.now - start
            let context = await reader.context.map(\.id)
            XCTAssertEqual(context, expected, "The reopened chat is the same chat")
            XCTAssertNotNil(snapshot["messages"].list.last)
            print("PERF session open \(attempt): \(turns) turns, open \(opened.formatted(.units(allowed: [.milliseconds]))), first snapshot at \(shown.formatted(.units(allowed: [.milliseconds])))")
            await reader.close()
        }
        // Moved, not copied: a long journal need not exist twice on a full disk.
        if let keep = ProcessInfo.processInfo.environment["PI_PERF_KEEP_JOURNAL"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.moveItem(atPath: path, toPath: keep)
        }
    }
}
