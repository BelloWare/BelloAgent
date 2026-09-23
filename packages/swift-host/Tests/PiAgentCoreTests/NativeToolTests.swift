import XCTest
@testable import PiAgentCore

/// The built-in tools: what they return to the model, and what happens to a
/// command that outlives its deadline while a child still holds the pipes.
final class NativeToolTests: XCTestCase {
    func testNativeShellAndFileTools() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let tools=NativeTools(cwd:root,outputs:root.appendingPathComponent("out"),mcp:MCPManager(cwd:root))
        let written = try await tools.invoke(ToolCall(id:"w",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        XCTAssertEqual(written["stats"]["added"].int, 1); XCTAssertEqual(written["stats"]["removed"].int, 0)
        XCTAssertEqual(written["stats"]["path"].text, root.resolvingSymlinksInPath().appendingPathComponent("file.txt").path)
        let read=try await tools.invoke(ToolCall(id:"r",name:"read",arguments:["path":"file.txt"]),readOnly:true)
        XCTAssertTrue(read.encoded().contains("abc"))
        let edited = try await tools.invoke(ToolCall(id:"e2",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"line one\nline two"]),readOnly:false)
        XCTAssertEqual(edited["stats"]["added"].int, 2, "the replaced line became two"); XCTAssertEqual(edited["stats"]["removed"].int, 1)
        XCTAssertTrue(edited["content"].list.first?["text"].text?.contains("(+2 -1)") ?? false)
        _ = try await tools.invoke(ToolCall(id:"w2",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        do { _ = try await tools.invoke(ToolCall(id:"e",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"x"]),readOnly:true);XCTFail("Readonly edit accepted") } catch {}
        let shell=try await tools.invoke(ToolCall(id:"b",name:"bash",arguments:["command":"printf hello; printf error >&2","timeout":2]),readOnly:false)
        XCTAssertTrue(shell.encoded().contains("hello"));XCTAssertTrue(shell.encoded().contains("error"))
    }
    func testShellTimeoutTerminatesOrphanHoldingPipes() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let start=nowMS()
        let result=try await ShellRun(command:"sleep 4 & exit 0",cwd:folder,outputDirectory:folder,onUpdate:{_ in}).run(timeoutSeconds:1)
        XCTAssertLessThan(nowMS()-start,3500,"Descendants must not keep the result hanging after timeout")
        XCTAssertEqual(result["isError"].flag,true,"A timeout is a failed tool result the model can act on, not a cancellation")
        XCTAssertTrue(result["content"].list.first?["text"].text?.contains("timed out after 1 seconds") ?? false)
    }

    /// Starts a process that leaves bash's process group (as a daemon does)
    /// and keeps the command's output pipes open for `seconds`. It writes its
    /// pid first, so the test can end the process it started.
    private func daemon(_ pidFile: URL, seconds: Int = 8) -> String {
        "perl -MPOSIX -e 'setsid() or die; open(my $f, \">\", \"\(pidFile.path)\") or die; print $f $$; close $f; sleep \(seconds)' &"
    }
    private func started(_ pidFile: URL) async throws {
        try await eventually { ((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0) } ?? 0) > 0 }
    }
    private func end(_ pidFile: URL) {
        if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), pid > 1 { kill(pid, SIGKILL) }
    }
    private func text(_ result: JSON) -> String { result["content"].list.first?["text"].text ?? "" }

    func testStopReturnsPromptlyWhileADaemonKeepsTheOutputOpen() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("daemon.pid"); defer { end(pidFile) }
        let run = try ShellRun(command: daemon(pidFile) + " sleep 20", cwd: folder, outputDirectory: folder, onUpdate: { _ in })
        let task = Task { try await run.run(timeoutSeconds: 60) }
        try await started(pidFile)
        let stoppedAt = nowMS(); task.cancel()
        do { _ = try await task.value; XCTFail("A stopped command reports its cancellation") } catch is CancellationError {}
        let elapsed = nowMS() - stoppedAt
        print("PERF shell.stop-with-daemon ms=\(Int(elapsed))")
        XCTAssertLessThan(elapsed, 2_500, "Stop must not wait for a process that left the command's group")
    }

    func testDeadlineReturnsPromptlyWhileADaemonKeepsTheOutputOpen() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("daemon.pid"); defer { end(pidFile) }
        let start = nowMS()
        let result = try await ShellRun(command: daemon(pidFile) + " echo started; sleep 20", cwd: folder, outputDirectory: folder, onUpdate: { _ in }).run(timeoutSeconds: 1)
        let elapsed = nowMS() - start
        print("PERF shell.deadline-with-daemon ms=\(Int(elapsed))")
        XCTAssertLessThan(elapsed, 3_000, "The deadline must not wait for a process that left the command's group")
        XCTAssertEqual(result["isError"].flag, true)
        XCTAssertTrue(text(result).contains("timed out after 1 seconds"), text(result))
        XCTAssertTrue(text(result).contains("started"), "Output collected before the deadline is kept")
        XCTAssertTrue(text(result).contains("background process"), "The model is told why the output stayed open")
    }

    func testBackgroundJobHoldingTheOutputDoesNotHoldTheResult() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("job.pid"); defer { end(pidFile) }
        let start = nowMS()
        let result = try await ShellRun(command: "sleep 8 & echo $! > \(pidFile.path); echo hi", cwd: folder, outputDirectory: folder, onUpdate: { _ in }).run(timeoutSeconds: 60)
        let elapsed = nowMS() - start
        print("PERF shell.background-job ms=\(Int(elapsed))")
        XCTAssertLessThan(elapsed, 3_000, "A finished command returns soon after bash exits, not when its background job does")
        XCTAssertEqual(result["isError"].flag, false, "bash itself succeeded")
        XCTAssertTrue(text(result).contains("hi") && text(result).contains("Exit code: 0"), text(result))
        XCTAssertTrue(text(result).contains("background process"), text(result))
    }

    func testCommandThatClosesItsOutputStillReturnsEverythingItWrote() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let start = nowMS()
        let result = try await ShellRun(command: "for i in $(seq 1 20000); do echo line-$i; done; echo done >&2", cwd: folder, outputDirectory: folder, onUpdate: { _ in }).run(timeoutSeconds: 30)
        XCTAssertLessThan(nowMS() - start, 1_400, "A command whose output reaches end of file never waits for the grace")
        XCTAssertTrue(text(result).contains("line-1\n"))
        XCTAssertTrue(text(result).contains("Output preview truncated. Retained 208899 of 208899 bytes"), text(result))
        XCTAssertFalse(text(result).contains("background process"))
    }

    /// A command that has filled its 32 KiB preview and keeps writing gives
    /// the card nothing new to show: no further notice reaches the session.
    func testFullPreviewStopsWakingTheCard() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let updates = UpdateRecorder()
        _ = try await ShellRun(command: "for i in $(seq 1 14); do head -c 4096 /dev/zero | tr '\\0' x; sleep 0.07; done", cwd: folder, outputDirectory: folder, onUpdate: { await updates.record($0) }).run(timeoutSeconds: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        let sizes = await updates.sizes
        print("PERF shell.preview-notices count=\(sizes.count) bytes=\(sizes.max() ?? 0)")
        XCTAssertLessThanOrEqual(sizes.count, 9, "Only a growing preview is sent: 8 chunks fill it, the other 6 add nothing")
        XCTAssertEqual(Set(sizes).count, sizes.count, "Every notice carries a preview the card has not shown")
    }

    func testUnchangedLiveOutputEmitsNoUpdateEvent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        await session.setToolState("call", ["id": "call", "name": "bash", "state": "running", "output": ""])
        let start = await session.eventPage(since: nil)["seq"].int ?? 0
        for _ in 0..<3 { await session.toolUpdate("call", resultText("same output")) }
        let updates = await session.eventPage(since: start)["events"].list.filter { $0["type"].text == "tool_execution_update" }
        XCTAssertEqual(updates.count, 1, "An update that changes nothing on the card wakes no reader")
        await session.close()
    }

    /// End to end: Stop on a bash call whose daemon keeps the pipes open
    /// settles the run, and the workspace editing gate is free again.
    func testStoppingABashCallHeldByADaemonSettlesTheRunAndFreesTheWorkspace() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("daemon.pid"); defer { end(pidFile) }
        let call = ToolCall(id: "bash-1", name: "bash", arguments: ["command": JSON(daemon(pidFile) + " sleep 20"), "timeout": 60])
        let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": "bash-1", "name": "bash", "arguments": call.arguments]]), calls: [call])
        let gate = AsyncGate()
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([reply]), tools: tools, traces: TraceStore(), editingGate: gate, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "start a server"), steer: false)
        try await started(pidFile)
        let stoppedAt = nowMS()
        await session.stop()
        try await eventually { !(await session.isRunning) }
        let settled = nowMS() - stoppedAt
        print("PERF session.stop-bash-with-daemon ms=\(Int(settled))")
        XCTAssertLessThan(settled, 2_500, "Stop settles the chat instead of sticking at Stopping")
        let state = await session.snapshot()
        XCTAssertEqual(state["state"].text, "paused")
        XCTAssertTrue(state["messages"].list.contains { $0["role"].text == "tool" && ($0["text"].text ?? "").contains("Tool interrupted") })
        let acquiredAt = nowMS(); try await gate.acquire(); await gate.release()
        XCTAssertLessThan(nowMS() - acquiredAt, 100, "The workspace editing gate is released")
        await session.close()
    }
}

private actor UpdateRecorder {
    var sizes: [Int] = []
    func record(_ update: JSON) { sizes.append(update["content"].list.first?["text"].text?.utf8.count ?? 0) }
}
