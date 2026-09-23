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

    func testCompactionFollowsTheReplyThatCrossesTheThresholdAndTheMeterWaitsForTheNextReply() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // The one-token tail splits the second turn: pi summarizes the history, then the turn's prefix.
        let client = ScriptClient([reply("at the threshold", total: 83_616), reply("over it", total: 83_617), answer("Summary: done."), answer("Prefix: two."), reply("after", total: 3_000)])
        let s = try session(root, client)
        _ = try await s.submit(Submission(commandID: "a", turnID: "a", text: "one"), steer: false)
        try await eventually { !(await s.isRunning) }
        let first = await client.purposes
        XCTAssertEqual(first, ["turn"], "at the threshold is not over it")
        _ = try await s.submit(Submission(commandID: "b", turnID: "b", text: "two"), steer: false)
        try await eventually { !(await s.isRunning) }
        let second = await client.purposes
        XCTAssertEqual(second, ["turn", "turn", "compaction", "compaction"], "pi compacts right after the reply that crossed it")
        let compacted = await s.snapshot(["includeMessages": false])
        XCTAssertEqual(compacted["state"].text, "idle", compacted["preflightError"].encoded())
        XCTAssertEqual(compacted["context"]["state"], "post-compaction"); XCTAssertEqual(compacted["context"]["tokens"], .null)
        XCTAssertEqual(compacted["context"]["source"].text, "Pending until the next reply")
        XCTAssertEqual(compacted["contextState"]["count"]["state"], "post-compaction")
        _ = try await s.submit(Submission(commandID: "c", turnID: "c", text: "three"), steer: false)
        try await eventually { !(await s.isRunning) }
        let third = await client.purposes
        XCTAssertEqual(third, ["turn", "turn", "compaction", "compaction", "turn"], "a reply from before the compaction triggers nothing more")
        let measured = await s.snapshot(["includeMessages": false])["context"]
        XCTAssertEqual(measured["tokens"], 3_000); XCTAssertNil(measured["state"].text)
        await s.close()
    }

    func testATurnCompactsBeforeItsNextRequestWhenAToolResultCrossesTheThreshold() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // The call's reply sits at the threshold; its "done write" result (3 tokens) crosses it.
        var call = toolReply(["write"]); call.usage = ["input": 83_606, "inputIncludingCache": 83_606, "output": 10]
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
