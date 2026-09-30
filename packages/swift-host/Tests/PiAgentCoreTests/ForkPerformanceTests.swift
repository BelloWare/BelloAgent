import XCTest
@testable import PiAgentCore

/// How long forking a very large chat takes, phase by phase: the chat's own
/// open, loading its whole history, the copy, opening the fork, and a fork
/// from a reply near the end (or `PI_PERF_FORK_AT` of the way in, such as
/// 0.1). Opt-in: `PI_PERF_FORK_MB` writes a journal of
/// about that many megabytes through the real run loop (questions, tool
/// calls with reasoning, tool output with every twentieth one large, answers,
/// compactions, and an edit), or `PI_PERF_FORK_JOURNAL` reuses one this test
/// kept earlier with `PI_PERF_KEEP_JOURNAL`. It prints its figures and asserts
/// only that each fork is the chat it was forked from.
final class ForkPerformanceTests: XCTestCase {
    private actor BulkTools: ToolExecuting {
        private var calls = 0
        func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "test", [:])] }
        func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
            calls += 1
            // Every twentieth result is a large one (a file read whole, a long log).
            let lines = calls.isMultiple(of: 20) ? 9_500 : 190
            return resultText(String(repeating: "Line of tool output with some words in it.\n", count: lines))
        }
    }

    /// The replies of a long chat, made as they are asked for: a tool call
    /// with its reasoning, then an answer, turn after turn, and a summary for
    /// each compaction. Unlike the fixture client it keeps no request, which
    /// for a chat this long would hold every context it ever sent.
    private actor LongChatClient: ModelClient {
        private var calls = 0
        func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String,
                      turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
            let reply: ModelReply
            if purpose == "compaction" { reply = answer("Summary of the turns so far: files were read and summarised.") }
            else {
                calls += 1
                var made = calls.isMultiple(of: 2) ? answer(ForkPerformanceTests.reply + " (\(calls / 2))") : toolReply(["first"])
                made.message.content.insert(["type": "thinking", "thinking": JSON(ForkPerformanceTests.reasoning)], at: 0)
                reply = made
            }
            try await onDelta(.text(reply.message.text))
            return reply
        }
    }

    fileprivate static let reasoning = String(repeating: "Thinking about which file to read and what it says. ", count: 40)
    fileprivate static let reply = String(repeating: "A paragraph of the assistant's answer, long enough to be realistic. ", count: 24)
    private func session(_ id: String, root: URL, directory: URL, client: any ModelClient = ScriptClient([]), resume: String? = nil) throws -> AgentSession {
        try AgentSession(id: id, profile: try fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                         resources: Resources(cwd: root, home: root), client: client, tools: BulkTools(), traces: TraceStore(),
                         resumePath: resume, autoCompaction: false)
    }

    private func settle(_ session: AgentSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await session.isRunning {
            guard ContinuousClock.now < deadline else { throw AgentError("benchmark", "A turn of the benchmark never finished") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// A journal of about `megabytes`, written by the run loop.
    private func writeJournal(megabytes: Int, root: URL, directory: URL) async throws -> String {
        let target = UInt64(megabytes) * 1_048_576
        // A compaction every so many turns, as a chat whose window fills has them.
        let compactEvery = ProcessInfo.processInfo.environment["PI_PERF_COMPACT_EVERY"].flatMap(Int.init) ?? 150
        let writer = try session("long", root: root, directory: directory, client: LongChatClient())
        let started = Date()
        var turn = 0, edited = false
        var path = ""
        while true {
            _ = try await writer.submit(Submission(commandID: "c\(turn)", turnID: "t\(turn)", text: "Question \(turn): please look at the file and summarise it."), steer: false)
            try await settle(writer)
            if (turn + 1) % compactEvery == 0 {
                try await writer.compact(commandID: "compact-\(turn)")
                try await settle(writer)
            }
            turn += 1
            if turn.isMultiple(of: 200) {
                path = await writer.snapshot()["path"].text ?? path
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
                // An edit near the end: the last user question but ten is asked again.
                if !edited, size >= target * 9 / 10 {
                    let questions = await writer.history.filter { $0.role == "user" }
                    if questions.count > 10 {
                        _ = try await writer.edit(fromMessageID: questions[questions.count - 10].id,
                                                  input: Submission(commandID: "edit", turnID: "edit", text: "The question asked again, differently."))
                        try await settle(writer)
                        edited = true
                    }
                }
                if size >= target { break }
            }
        }
        let last = await writer.snapshot()
        path = try XCTUnwrap(last["path"].text)
        await writer.close()
        let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "PERF fork: wrote %d turns (%.1f MB) in %.1f s", turn, Double(bytes) / 1_048_576, Date().timeIntervalSince(started)))
        return path
    }

    /// This process's CPU time so far, user and system, in milliseconds: the
    /// helper's own work, whatever else the machine is doing.
    private static func cpuMilliseconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) * 1_000 + Double(usage.ru_utime.tv_usec) / 1_000
        let system = Double(usage.ru_stime.tv_sec) * 1_000 + Double(usage.ru_stime.tv_usec) / 1_000
        return user + system
    }
    /// The one-minute load average, and the cores it is measured against.
    private static func loadAverage() -> (average: Double, cores: Int) {
        var loads = [Double](repeating: 0, count: 3); getloadavg(&loads, 3)
        return (loads[0], ProcessInfo.processInfo.activeProcessorCount)
    }
    /// One phase: wall and CPU time, and the load when it ended, on one line
    /// a driver can read (`PERFROW`).
    private func measure<T>(_ phase: String, attempt: Int, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), started = clock.now, cpu = Self.cpuMilliseconds()
        let value = try await body()
        let wall = clock.now - started, used = Self.cpuMilliseconds() - cpu, load = Self.loadAverage()
        let wallMs = Double(wall.components.seconds) * 1_000 + Double(wall.components.attoseconds) / 1e15
        print(String(format: "PERFROW run=%d phase=%@ wall_ms=%.0f cpu_ms=%.0f load=%.2f cores=%d", attempt, phase, wallMs, used, load.average, load.cores))
        return value
    }

    func testForkingAVeryLargeChat() async throws {
        let environment = ProcessInfo.processInfo.environment
        let kept = environment["PI_PERF_FORK_JOURNAL"], megabytes = environment["PI_PERF_FORK_MB"].flatMap(Int.init)
        guard kept != nil || megabytes != nil else { throw XCTSkip("Set PI_PERF_FORK_MB (or PI_PERF_FORK_JOURNAL) to measure forking a large chat.") }
        // The reply the forks from a reply start at: fifty replies back, or
        // the given fraction of the way in.
        var fraction: Double?
        if let text = environment["PI_PERF_FORK_AT"] {
            guard let value = Double(text), value.isFinite, (0...1).contains(value) else { return XCTFail("PI_PERF_FORK_AT must be a number from 0 to 1, not \(text)") }
            fraction = value
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory: URL, path: String
        if let kept {
            path = kept; directory = URL(fileURLWithPath: kept).deletingLastPathComponent()
        } else {
            directory = root.appendingPathComponent("state")
            path = try await writeJournal(megabytes: megabytes ?? 300, root: root, directory: directory)
        }
        let journal = URL(fileURLWithPath: path)
        let size = Double((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0) / 1_048_576
        print(String(format: "PERF fork journal: %.1f MB", size))
        // The chat as the app has it: opened once before, so it has its metadata file.
        if JournalCheckpoint.read(for: journal) == nil { let first = try session("long", root: root, directory: directory, resume: path); await first.close() }
        let target: String = try await {
            let parent = try session("long", root: root, directory: directory, resume: path)
            try await parent.ensureFullHistory()
            let replies = await parent.history.filter { $0.role == "assistant" && !$0.content.contains { $0["type"].text == "toolCall" } }
            await parent.close()
            if let fraction { return try XCTUnwrap(replies.isEmpty ? nil : replies[min(replies.count - 1, Int(Double(replies.count) * fraction))].id) }
            return try XCTUnwrap(replies.dropLast(50).last?.id)
        }()
        let repeats = environment["PI_PERF_REPEAT"].flatMap(Int.init) ?? 2
        for attempt in 1...repeats {
            // The same work in every build, as a control: reading the file,
            // parsing each record, and parsing and encoding each record.
            try await measure("raw-read", attempt: attempt) { let reader = try JournalRecordReader(journal); while try reader.nextLine() != nil {} }
            try await measure("raw-parse", attempt: attempt) {
                let reader = try JournalRecordReader(journal)
                while let line = try reader.nextLine() { if !line.isEmpty { _ = try JSON.parse(line) } }
            }
            try await measure("raw-parse-encode", attempt: attempt) {
                let reader = try JournalRecordReader(journal)
                while let line = try reader.nextLine() { if !line.isEmpty { _ = try JSON.parse(line).data() } }
            }
            // Phase by phase, on the session itself.
            let parent = try await measure("open", attempt: attempt) { try session("long", root: root, directory: directory, resume: path) }
            try await measure("full-history", attempt: attempt) { try await parent.ensureFullHistory() }
            let expectedContext = await parent.context.map(\.id)
            let whole = try await measure("fork-whole", attempt: attempt) { try await parent.fork(to: "fork-\(attempt)") }
            let forkPath = try XCTUnwrap(whole["path"].text)
            let fork = try await measure("fork-whole-open", attempt: attempt) { try session("fork-\(attempt)", root: root, directory: directory, resume: forkPath) }
            let forkContext = await fork.context.map(\.id)
            XCTAssertEqual(forkContext, expectedContext, "The fork's context is the chat's")
            await fork.close()
            _ = try await measure("fork-point", attempt: attempt) { try await parent.forkPointForTesting(target, path: journal) }
            let atReply = try await measure("fork-at", attempt: attempt) { try await parent.fork(to: "at-\(attempt)", at: target) }
            let atPath = try XCTUnwrap(atReply["path"].text)
            let atFork = try await measure("fork-at-open", attempt: attempt) { try session("at-\(attempt)", root: root, directory: directory, resume: atPath) }
            let atContext = await atFork.context.map(\.id)
            XCTAssertEqual(atContext.last, target, "The fork from a reply ends at it")
            await atFork.close(); await parent.close()
            for file in [forkPath, atPath] { for suffix in ["", ".lock", ".meta"] { try? FileManager.default.removeItem(atPath: file + suffix) } }
            // End to end, as the app asks: the chat just opened from its
            // metadata file, then `session.fork`, which also opens the fork.
            for (label, point) in [("host-whole", nil), ("host-at", target)] as [(String, String?)] {
                let profile = try fixtureProfile()
                let host = NativeHostService(emit: { _ in })
                _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(directory.path)])
                _ = try await host.command("session.open", sessionID: "long", params: ["profile": profile.raw, "apiKey": "fixture", "path": JSON(path)])
                var params: JSON = ["forkSessionId": JSON("\(label)-\(attempt)")]
                if let point { params["atMessageId"] = JSON(point) }
                let result = try await measure(label, attempt: attempt) { try await host.command("session.fork", sessionID: "long", params: params) }
                XCTAssertEqual(result["accepted"].flag, true)
                await host.shutdown()
                if let file = result["path"].text { for suffix in ["", ".lock", ".meta"] { try? FileManager.default.removeItem(atPath: file + suffix) } }
            }
        }
        if let keep = environment["PI_PERF_KEEP_JOURNAL"], kept == nil {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.moveItem(atPath: path, toPath: keep)
            try? FileManager.default.removeItem(atPath: keep + ".meta")
            try? FileManager.default.moveItem(atPath: path + ".meta", toPath: keep + ".meta")
        }
    }
}

extension AgentSession {
    /// Test seam: where a fork at `messageID` would end, read from `path`.
    func forkPointForTesting(_ messageID: String, path: URL) throws -> Int {
        let reader = try JournalRecordReader(path); _ = try reader.next()
        return try forkPoint(messageID, in: reader)
    }
}
