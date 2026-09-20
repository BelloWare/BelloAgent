import XCTest
@testable import PiAgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A blocking barrier, deliberately not an async suspension: overlapping
/// arrivals must occupy different OS threads until the test releases them.
private final class WorkerBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false, active = 0, maximum = 0
    private var started: [Int] = [], threads: Set<UInt64> = []
    var state: (started: [Int], threads: Set<UInt64>, maximum: Int) {
        condition.lock(); defer { condition.unlock() }; return (started, threads, maximum)
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func enter(_ index: Int, cancellation: BlockingWorkCancellation, cooperative: Bool = true) throws -> Int {
        #if canImport(Darwin)
        var thread: UInt64 = 0; pthread_threadid_np(nil, &thread)
        #else
        let thread = UInt64(pthread_self())
        #endif
        condition.lock()
        active += 1; maximum = max(maximum, active); started.append(index); threads.insert(thread)
        defer { active -= 1; condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !released {
            if cooperative { try cancellation.checkCancellation() }
            guard Date() < deadline else { throw AgentError("fixture_timeout", "Worker barrier was not released") }
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
        return index
    }
}

final class BlockingWorkTests: XCTestCase {
    func testTwentyJobsOverlapOnFourOSWorkerThreadsAndNeverExceedTheBound() async throws {
        let workers = BlockingWorkExecutor(), barrier = WorkerBarrier()
        defer { barrier.release() }
        let tasks = (0..<20).map { index in Task { try await workers.run { try barrier.enter(index, cancellation: $0) } } }
        try await eventually { workers.occupancy.active == 4 && workers.occupancy.waiting == 16 && barrier.state.started.count == 4 }
        XCTAssertEqual(barrier.state.threads.count, 4, "A held blocking barrier requires four distinct OS threads")
        XCTAssertEqual(barrier.state.maximum, 4)
        barrier.release()
        for (index, task) in tasks.enumerated() { let value = try await task.value; XCTAssertEqual(value, index) }
        try await eventually { workers.occupancy.active == 0 }
        XCTAssertEqual(barrier.state.started.count, 20)
        XCTAssertEqual(barrier.state.maximum, 4)
        print("BLOCKING_WORK jobs=20 simultaneousOSThreads=4 maximumActive=4 queuedAtBarrier=16")
    }

    func testQueuedCancellationNeverExecutesAndFIFOQueueHasAnExplicitLimit() async throws {
        let workers = BlockingWorkExecutor(maximumWorkers: 1, maximumWaiting: 2), barrier = WorkerBarrier()
        defer { barrier.release() }
        let first = Task { try await workers.run { try barrier.enter(0, cancellation: $0) } }
        try await eventually { barrier.state.started == [0] }
        let second = Task { try await workers.run { try barrier.enter(1, cancellation: $0) } }
        try await eventually { workers.occupancy.waiting == 1 }
        let cancelled = Task { try await workers.run { try barrier.enter(2, cancellation: $0) } }
        try await eventually { workers.occupancy.waiting == 2 }
        do { _ = try await workers.run { _ in 99 }; XCTFail("A full bounded queue accepted more work") }
        catch let error as AgentError { XCTAssertEqual(error.code, "tool_busy") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled queued work returned a result") }
        catch is CancellationError {}
        XCTAssertEqual(workers.occupancy.waiting, 1)
        XCTAssertEqual(barrier.state.started, [0], "Cancellation must finish without starting the queued operation")
        let replacement = Task { try await workers.run { try barrier.enter(3, cancellation: $0) } }
        try await eventually { workers.occupancy.waiting == 2 }
        barrier.release()
        _ = try await first.value; _ = try await second.value; _ = try await replacement.value
        XCTAssertEqual(barrier.state.started, [0, 1, 3], "Surviving jobs keep FIFO order")
    }

    func testTaskCancellationReachesRunningWorkerAndLeavesItsNeighborUsable() async throws {
        let workers = BlockingWorkExecutor(maximumWorkers: 1), barrier = WorkerBarrier()
        defer { barrier.release() }
        let running = Task { try await workers.run { try barrier.enter(0, cancellation: $0) } }
        try await eventually { barrier.state.started == [0] }
        let neighbor = Task { try await workers.run { _ in "neighbor" } }
        try await eventually { workers.occupancy.waiting == 1 }
        running.cancel()
        do { _ = try await running.value; XCTFail("Running job ignored task cancellation") }
        catch is CancellationError {}
        let value = try await neighbor.value
        XCTAssertEqual(value, "neighbor", "Cooperative cancellation must release the slot without releasing the fixture barrier")
    }

    func testCancellingUninterruptibleCallKeepsItsWorkerSlotUntilItReturns() async throws {
        let workers = BlockingWorkExecutor(maximumWorkers: 1), barrier = WorkerBarrier()
        defer { barrier.release() }
        let running = Task { try await workers.run { try barrier.enter(0, cancellation: $0, cooperative: false) } }
        try await eventually { barrier.state.started == [0] }
        let neighbor = Task { try await workers.run { try barrier.enter(1, cancellation: $0) } }
        try await eventually { workers.occupancy.waiting == 1 }
        running.cancel()
        XCTAssertEqual(workers.occupancy.active, 1)
        XCTAssertEqual(workers.occupancy.waiting, 1)
        XCTAssertEqual(barrier.state.started, [0], "Cancellation must not oversubscribe blocked worker threads")
        barrier.release()
        do { _ = try await running.value; XCTFail("A cancelled operation returned success after its blocking call ended") }
        catch is CancellationError {}
        let value = try await neighbor.value; XCTAssertEqual(value, 1)
    }

    func testTwentyNativeFileJobsQueueWithoutBlockingDefinitionsAndKeepTheirOwnResults() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let workers = BlockingWorkExecutor(), barrier = WorkerBarrier()
        defer { barrier.release() }
        let blockers = (0..<4).map { index in Task { try await workers.run { try barrier.enter(index, cancellation: $0) } } }
        try await eventually { barrier.state.started.count == 4 }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root), workers: workers)
        var calls: [ToolCall] = [], expected: [String] = []
        for index in 0..<20 {
            let directory = root.appendingPathComponent("job-\(index)"), file = "file-\(index).txt", content = "unique content \(index)"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: directory.appendingPathComponent(file))
            let name: String, arguments: JSON, result: String
            switch index % 4 {
            case 0: name = "read"; arguments = ["path": JSON("job-\(index)/" + file)]; result = content
            case 1: name = "grep"; arguments = ["path": JSON("job-\(index)"), "pattern": JSON(content), "literal": true]; result = "\(file):1: \(content)"
            case 2: name = "find"; arguments = ["path": JSON("job-\(index)"), "pattern": JSON(file)]; result = file
            default: name = "ls"; arguments = ["path": JSON("job-\(index)")]; result = file
            }
            calls.append(ToolCall(id: "call-\(index)", name: name, arguments: arguments)); expected.append(result)
        }
        let tasks = calls.map { call in Task { try await tools.invoke(call, readOnly: true) } }
        try await eventually { workers.occupancy.waiting == 20 }
        let definitions = await tools.definitions(readOnly: true)
        XCTAssertEqual(Set(definitions.map(\.name)), Set(["read", "ls", "find", "grep", "mcp"]))
        let capabilities = await tools.capabilityIDs(readOnly: true)
        XCTAssertTrue(capabilities.contains("read"))
        tasks[7].cancel()
        do { _ = try await tasks[7].value; XCTFail("Queued tool cancellation returned success") }
        catch is CancellationError {}
        XCTAssertEqual(workers.occupancy.waiting, 19)
        barrier.release()
        for task in blockers { _ = try await task.value }
        for (index, task) in tasks.enumerated() where index != 7 {
            let result = try await task.value
            XCTAssertEqual(result["isError"].flag, false)
            XCTAssertTrue(result["content"].list.first?["text"].text?.contains(expected[index]) == true, "Tool \(index) returned another job's result")
        }
        try await eventually { workers.occupancy.active == 0 && workers.occupancy.waiting == 0 }
    }

    func testPermissionAndSchemaFailuresPrecedeWorkerAdmissionAndReadOutputStaysBounded() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let workers = BlockingWorkExecutor(maximumWorkers: 1, maximumWaiting: 0), barrier = WorkerBarrier()
        defer { barrier.release() }
        let blocker = Task { try await workers.run { try barrier.enter(0, cancellation: $0) } }
        try await eventually { barrier.state.started == [0] }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root), workers: workers)
        for name in ["write", "edit", "bash"] {
            do { _ = try await tools.invoke(ToolCall(id: name, name: name, arguments: [:]), readOnly: true); XCTFail("Read-only mutation accepted") }
            catch let error as AgentError { XCTAssertEqual(error.code, "tool_unavailable") }
        }
        do { _ = try await tools.invoke(ToolCall(id: "invalid", name: "read", arguments: ["path": "file", "unexpected": true]), readOnly: true); XCTFail("Invalid schema accepted") }
        catch let error as AgentError { XCTAssertEqual(error.code, "tool_arguments") }
        do { _ = try await tools.invoke(ToolCall(id: "full", name: "read", arguments: ["path": "file"]), readOnly: true); XCTFail("Unbounded file job accepted") }
        catch let error as AgentError { XCTAssertEqual(error.code, "tool_busy") }
        XCTAssertEqual(workers.occupancy.waiting, 0)
        barrier.release(); _ = try await blocker.value
        try await eventually { workers.occupancy.active == 0 }
        try Data(String(repeating: "x", count: 40_000).utf8).write(to: root.appendingPathComponent("file"))
        let result = try await tools.invoke(ToolCall(id: "bounded", name: "read", arguments: ["path": "file"]), readOnly: true)
        let text = try XCTUnwrap(result["content"].list.first?["text"].text)
        XCTAssertTrue(text.hasPrefix(String(repeating: "x", count: 32_768)))
        XCTAssertTrue(text.contains("Truncated")); XCTAssertLessThan(text.utf8.count, 33_000)
    }

    func testNativeReadSessionFinishesWhileAnEditSessionWaitsForTheExistingGate() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("before".utf8).write(to: file)
        let gate = AsyncGate(), tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        func session(_ id: String, call: ToolCall) throws -> AgentSession {
            let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": JSON(call.name), "arguments": call.arguments]]), calls: [call])
            return try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent(id), readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([reply, answer("done")]), tools: tools, traces: TraceStore(), editingGate: gate, autoCompaction: false)
        }
        let edit = try session("editing", call: ToolCall(id: "edit", name: "edit", arguments: ["path": "file.txt", "oldText": "before", "newText": "after"]))
        let read = try session("reading", call: ToolCall(id: "read", name: "read", arguments: ["path": "file.txt"]))
        try await gate.acquire()
        var held = true
        defer { if held { Task { await gate.release() } } }
        _ = try await edit.submit(Submission(commandID: "edit", turnID: "edit", text: "edit"), steer: false)
        try await eventually { await edit.snapshot()["activity"]["phase"].text == "tool" }
        _ = try await read.submit(Submission(commandID: "read", turnID: "read", text: "read"), steer: false)
        try await eventually { !(await read.isRunning) }
        let snapshot = await read.snapshot(), editing = await edit.isRunning
        XCTAssertEqual(snapshot["state"].text, "idle"); XCTAssertTrue(snapshot["messages"].encoded().contains("before"))
        XCTAssertTrue(editing); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        await gate.release(); held = false
        try await eventually { !(await edit.isRunning) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")
        await read.close(); await edit.close()
    }
}
