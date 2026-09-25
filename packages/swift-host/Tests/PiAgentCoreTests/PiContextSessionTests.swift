import XCTest
@testable import PiAgentCore

/// Pi 0.85.1's context rules in a running session. The fixture's window is
/// 100,000 tokens, so pi's compaction threshold is 100,000 - 16,384 = 83,616.
final class PiContextSessionTests: XCTestCase {
    func testTheMeterIsTheLastReplysTokensAndTheUsageSurvivesReload() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let s = try session(root, ScriptClient([reply("first answer", total: 12_000)]))
        _ = try await s.submit(Submission(commandID: "a", turnID: "a", text: "question"), steer: false)
        try await eventually { !(await s.isRunning) }
        let stored = await s.context.last { $0.role == "assistant" }?.usage
        XCTAssertEqual(stored, ["input": 5_995, "output": 10, "cacheRead": 5_995, "cacheWrite": 0, "totalTokens": 12_000], "pi's usage: input without the cache")
        let context = await s.snapshot(["includeMessages": false])["context"]
        XCTAssertEqual(context["tokens"], 12_000); XCTAssertEqual(context["method"], "pi-estimate")
        XCTAssertEqual(context["source"].text, "Last reply's reported tokens, plus about 4 characters per token for the messages since")
        XCTAssertEqual(context["usageTokens"], 12_000); XCTAssertEqual(context["trailingTokens"], 0)
        let journal = await s.path; await s.close()
        let path = try XCTUnwrap(journal)
        let reopened = try session(root, ScriptClient([]), resume: path)
        let reloaded = await reopened.context.last { $0.role == "assistant" }?.usage
        XCTAssertEqual(reloaded, stored)
        let reopenedContext = await reopened.snapshot(["includeMessages": false])["context"]
        XCTAssertEqual(reopenedContext["tokens"], 12_000)
        await reopened.close()
    }

    func testCompactionWaitsForPendingWorkAndFollowingReplyRefreshesUsage() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([reply(String(repeating:"evidence ",count:1500),total:66000),answer("Summary: verified work."),reply("after",total:3000)])
        let s=try session(root,client)
        _=try await s.submit(Submission(commandID:"a",turnID:"a",text:"one"),steer:false)
        try await eventually { !(await s.isRunning) }
        let first=await client.purposes
        XCTAssertEqual(first,["turn"],"Do not compact an idle finished task")
        _=try await s.submit(Submission(commandID:"b",turnID:"b",text:"two"),steer:false)
        try await eventually { !(await s.isRunning) }
        let second=await client.purposes, snapshot=await s.snapshot(["includeMessages":false])
        XCTAssertEqual(second,["turn","compaction","turn"])
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded())
        XCTAssertEqual(snapshot["context"]["tokens"],3000,"The ordinary reply, not summary usage, measures the new context")
        await s.close()
    }

    func testATurnCompactsBeforeItsNextRequestWhenAToolResultCrossesTheThreshold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // The call's reply sits at the threshold; its "done write" result (3 tokens) crosses it.
        var call = toolReply(["write"]); call.usage = ["input": 66000, "inputIncludingCache": 66000, "output": 10]
        call.message.providerItems=nil; call.message.content.insert(textBlock(String(repeating:"evidence ",count:1500)),at:0)
        let client = ScriptClient([call, answer("Summary: wrote."), answer("finished")])
        let s = try session(root, client)
        _ = try await s.submit(Submission(commandID: "a", turnID: "a", text: "write it"), steer: false)
        try await eventually { !(await s.isRunning) }
        let purposes = await client.purposes, snapshot = await s.snapshot(["includeMessages": false])
        XCTAssertEqual(purposes, ["turn", "compaction", "turn"])
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        XCTAssertEqual(snapshot["latestSuccessfulCompaction"]["operation"]["reason"].text, "threshold")
        await s.close()
    }

    private func reply(_ text: String, total: Int) -> ModelReply {
        var value = answer(text)
        value.usage = UsageObservation.normalized(["input_tokens": JSON(total - 10), "output_tokens": 10, "total_tokens": JSON(total),
                                                   "input_tokens_details": ["cached_tokens": JSON((total - 10) / 2)]], api: "openai-responses")
        return value
    }
    /// These cases measure when pi compacts. Their few short messages sit
    /// inside pi's 20,000-token tail, so a one-token tail gives it work.
    private func session(_ root: URL, _ client: ScriptClient, resume: String? = nil) throws -> AgentSession {
        var policy = CompactionPolicy(); policy.keepRecentTokens = 1
        return try AgentSession(id: "pi-context", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: resume, compactionPolicy: policy)
    }
}
