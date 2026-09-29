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

    /// The process's footprint, as Activity Monitor reports it: dirty memory
    /// it holds, compressed included.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// `PI_PERF_MEMORY_JOURNAL` with `PI_PERF_MEMORY_MODE` (`partial`,
    /// `paged`, `searched` or `full`): what one open chat holds, measured in a
    /// process of its own so nothing earlier is counted. `partial` opens from
    /// the metadata file, `paged` then pages back past the rows it loaded,
    /// `searched` searches every row for words none has, and `full` opens
    /// without the metadata file. Held memory is read after two idle seconds,
    /// once freed memory has gone back to the system.
    func testMemoryOfOneOpenChat() async throws {
        guard let kept = ProcessInfo.processInfo.environment["PI_PERF_MEMORY_JOURNAL"],
              let mode = ProcessInfo.processInfo.environment["PI_PERF_MEMORY_MODE"] else {
            throw XCTSkip("Set PI_PERF_MEMORY_JOURNAL and PI_PERF_MEMORY_MODE.")
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), path = URL(fileURLWithPath: kept), directory = path.deletingLastPathComponent()
        let meta = JournalCheckpoint.url(for: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meta.path), "The journal needs its metadata file; run the partial mode once first")
        let saved = mode == "full" ? try Data(contentsOf: meta) : nil
        if mode == "full" { try FileManager.default.removeItem(at: meta) }
        defer { if let saved { try? saved.write(to: meta) } }
        malloc_zone_pressure_relief(nil, 0)
        let baseline = Self.footprint()
        let clock = ContinuousClock(), started = clock.now
        let reader = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                      resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: BulkTools(), traces: TraceStore(),
                                      resumePath: path.path, autoCompaction: false)
        _ = await reader.snapshot()
        var peak = Self.footprint()
        if mode == "paged" {
            // Page back to the first page past the rows the open loaded.
            var window = try await reader.historyWindow(["version": 2, "direction": "older"]), pages = 1
            while await reader.partialHistory, await reader.olderIndex == nil, !window["older"].isNull, pages < 500 {
                window = try await reader.historyWindow(["version": 2, "direction": "older", "cursor": window["older"]]); pages += 1
            }
            peak = max(peak, Self.footprint())
        }
        if mode == "searched" {
            let searchStarted = clock.now
            let found = try await reader.contentSearch(["query": "no such words anywhere", "start": 0])
            let again = clock.now
            _ = try await reader.contentSearch(["query": "no such words anywhere", "start": 0])
            print("PERF search: first \((again - searchStarted).formatted(.units(allowed: [.milliseconds]))), again \((clock.now - again).formatted(.units(allowed: [.milliseconds]))), \(found["total"].int ?? 0) rows")
            peak = max(peak, Self.footprint())
        }
        let took = clock.now - started
        try await Task.sleep(for: .seconds(2))
        malloc_zone_pressure_relief(nil, 0)
        let held = Self.footprint()
        let partial = await reader.partialHistory, older = await reader.olderRows, rows = await reader.visible.count
        print(String(format: "PERF one chat (%@): peak +%.1f MB, held +%.1f MB after idle; %d rows held, %d older rows not loaded, partial %@, took %@",
                     mode, Double(Int64(peak) - Int64(baseline)) / 1_048_576, Double(Int64(held) - Int64(baseline)) / 1_048_576, rows, older, partial ? "yes" : "no",
                     took.formatted(.units(allowed: [.milliseconds]))))
        await reader.close()
    }

    /// `PI_PERF_SLIM_JOURNAL`: a journal kept with `PI_PERF_KEEP_JOURNAL`,
    /// written again with every run-state record whole, as before 0.1.111,
    /// then slimmed (`JournalSlimming`): its size and a full open, before and
    /// after. The journal is changed in place; the original goes to a folder
    /// of the test's, not the Trash.
    func testSlimmingAKeptJournal() async throws {
        guard let kept = ProcessInfo.processInfo.environment["PI_PERF_SLIM_JOURNAL"] else {
            throw XCTSkip("Set PI_PERF_SLIM_JOURNAL to a journal kept with PI_PERF_KEEP_JOURNAL.")
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), path = URL(fileURLWithPath: kept), directory = path.deletingLastPathComponent()
        // Every run-state record whole, as the helper wrote them before 0.1.111.
        var lines: [Data] = [], list: [JSON] = []
        let reader = try JournalRecordReader(path)
        while let line = try reader.nextLine() {
            if line.isEmpty { continue }
            var record = try JSON.parse(line)
            if record["customType"].text == "pi-app.native.state.v1" {
                let data = record["data"]
                list = data[CommandReceipts.deltaKey].flag == true ? CommandReceipts.apply(data["commands"].list, to: list) : data["commands"].list
                var whole = data.removing([CommandReceipts.deltaKey]); whole["commands"] = .array(list); record["data"] = whole
                lines.append(try record.data())
            } else {
                if !record["nativeState"].isNull { list = record["nativeState"]["commands"].list }
                lines.append(line)
            }
        }
        var whole = Data(); for line in lines { whole.append(line); whole.append(10) }
        try whole.write(to: path)
        func open(_ label: String) async throws {
            for attempt in 1...3 {
                JournalCheckpoint.remove(for: path)
                let clock = ContinuousClock(), start = clock.now
                let session = try AgentSession(id: "long", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true,
                                               resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: BulkTools(), traces: TraceStore(),
                                               resumePath: path.path, autoCompaction: false)
                let opened = clock.now - start
                print("PERF \(label) full open \(attempt): \(opened.formatted(.units(allowed: [.milliseconds])))")
                await session.close()
            }
        }
        func size() throws -> Double { Double((try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0) / 1_048_576 }
        print(String(format: "PERF whole-list journal: %.1f MB", try size()))
        try await open("whole-list")
        JournalCheckpoint.remove(for: path)
        let bin = root.appendingPathComponent("bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let clock = ContinuousClock(), start = clock.now
        let outcome = try JournalSlimming.slim(url: path, id: "long", discard: { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) })
        print("PERF slimming took \((clock.now - start).formatted(.units(allowed: [.milliseconds]))): \(outcome)")
        XCTAssertTrue(outcome.slimmed)
        print(String(format: "PERF slimmed journal: %.1f MB", try size()))
        try await open("slimmed")
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
