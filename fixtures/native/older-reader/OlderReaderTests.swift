import XCTest
@testable import PiAgentCore

/// Not part of this checkout's tests. `scripts/older-reader-check.sh` copies
/// this file into a checkout of an earlier release and runs it there: that
/// release's helper must open a chat and a connection the current build wrote
/// (owner, 2026-11-11: "It has to be backward compatible").
///
/// The chat comes from `ReasoningQuestionTests`: replies marked for reasoning
/// replay, two answered refusals (`pi-app.reasoning-withheld.v1` records and
/// their quiet lines in the transcript), a third still standing in the saved
/// state, and a checkpoint that carries what is withheld. None of that exists
/// in a release before 0.1.138.
///
/// A second chat comes from `OverWindowTests`: a task whose request is over
/// the model's window, with the row that says so (an execution record of a
/// kind this release already draws) and a failed run to retry. And a
/// checkpoint record whose framing line has 0.1.138's added clause: this
/// release sends whatever line a record holds.
final class OlderReaderTests: HelperTestCase {
    func testAChatWithAnOverWindowNoticeOpensAndGoesOn() async throws {
        guard let out = ProcessInfo.processInfo.environment["PI_OVERWINDOW_COMPAT_OUT"], !out.isEmpty else { throw XCTSkip("Run by scripts/older-reader-check.sh") }
        let source = URL(fileURLWithPath: out), root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let export = try JSON.parse(Data(contentsOf: source.appendingPathComponent("export.json")))
        try FileManager.default.copyItem(at: source.appendingPathComponent("state"), to: root.appendingPathComponent("state"))
        let journal = root.appendingPathComponent("state").appendingPathComponent(try XCTUnwrap(export["journal"].text))
        XCTAssertTrue(try String(contentsOf: journal, encoding: .utf8).contains("Context · This request is about"))
        let profile = try Profile(export["profile"])
        for resumed in [true, false] {
            if !resumed { try? FileManager.default.removeItem(at: JournalCheckpoint.url(for: journal)) }
            let client = ScriptClient([answer("Done after all.")])
            let session = try AgentSession(id: "over", profile: profile, apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                           resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: journal.path)
            let context = await session.context, history = await session.history, state = await session.snapshot(["includeMessages": false])
            let notice = history.filter { $0.kind == "execution" && ($0.detail ?? "").hasPrefix("Context · ") }
            XCTAssertEqual(notice.count, 1, "The row is read as the execution record it is (\(resumed))"); XCTAssertEqual(notice.first?.replayEligible, false)
            XCTAssertFalse(context.contains { ($0.detail ?? "").hasPrefix("Context · ") }, "and is no part of what is sent")
            XCTAssertEqual(context.filter { $0.role == "toolResult" }.count, 10, "Every result of the batch is there")
            XCTAssertEqual(state["state"].text, "error")
            try await session.retryRun(overrides: [:])
            try await eventually { !(await session.isRunning) }
            let after = await session.snapshot(["includeMessages": false]), last = await session.context.last
            XCTAssertEqual(after["state"].text, "idle", after["preflightError"].encoded()); XCTAssertEqual(last?.text, "Done after all.")
            await session.close()
            try FileManager.default.removeItem(at: root.appendingPathComponent("state"))
            try FileManager.default.copyItem(at: source.appendingPathComponent("state"), to: root.appendingPathComponent("state"))
        }
    }

    func testACheckpointWithALaterBuildsFramingLineIsSentAsRecorded() throws {
        guard ProcessInfo.processInfo.environment["PI_OVERWINDOW_COMPAT_OUT"]?.isEmpty == false else { throw XCTSkip("Run by scripts/older-reader-check.sh") }
        let line = "The task was in progress when this checkpoint was made. Continue from the retained request and latest results without asking the owner to repeat them, and without redoing work the summary records as done."
        let record: JSON = ["type": "compaction", "id": "cp", "summary": "## Progress and evidence\nparts 01 to 06 read", "nativeCompactionVersion": 2, "nativeKeptIDs": [], "tokensBefore": 9000,
                            "nativeCompaction": ["version": 2, "continuationText": JSON(line), "operationId": "op", "keptIDs": [], "sourceIDs": [], "protectedIDs": []]]
        let summary = try CompactionCheckpoint.summary(record)
        let sent = ProviderClient.userContent(summary, images: false).first?["text"].text ?? ""
        XCTAssertTrue(sent.hasSuffix("</summary>\n\n" + line), sent)
    }

    func testAChatAndAConnectionWrittenByALaterBuildOpenAndGoOn() async throws {
        guard let out = ProcessInfo.processInfo.environment["PI_REASONING_COMPAT_OUT"], !out.isEmpty else { throw XCTSkip("Run by scripts/older-reader-check.sh") }
        let source = URL(fileURLWithPath: out), root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let export = try JSON.parse(Data(contentsOf: source.appendingPathComponent("export.json")))
        try FileManager.default.copyItem(at: source.appendingPathComponent("state"), to: root.appendingPathComponent("state"))
        let journal = root.appendingPathComponent("state").appendingPathComponent(try XCTUnwrap(export["journal"].text))
        let written = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertTrue(written.contains("pi-app.reasoning-withheld.v1")); XCTAssertTrue(written.contains("nativeReasoningReplay")); XCTAssertTrue(written.contains("reasoningRejection"))

        // The connection as the later build saves "Never send reasoning
        // back": this release's `portable`, and a field it does not know.
        var raw = export["profile"]; raw["routing"] = ["replayPolicy": "portable"]; raw["reasoningReplay"] = "never"
        let profile = try Profile(raw)
        for resumed in [true, false] {
            // Once from the later build's checkpoint, once from the journal alone.
            if !resumed { try? FileManager.default.removeItem(at: JournalCheckpoint.url(for: journal)) }
            let client = ScriptClient([answer("Still here.")])
            let session = try AgentSession(id: "reasoning", profile: profile, apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                           resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: journal.path, autoCompaction: false)
            let context = await session.context, state = await session.snapshot(["includeMessages": false])
            XCTAssertEqual(context.filter { $0.role == "user" }.map(\.text), ["Use the tool", "Next", "More", "Again", "Back", "Once more"], "Every message is there (\(resumed))")
            XCTAssertEqual(context.filter { $0.role == "assistant" }.count, 6)
            // The refusal that was standing is a failed run here, with Retry.
            XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(state["errorCode"].text, "reasoning_rejected")
            XCTAssertTrue(state["preflightError"].text?.contains("can't use the earlier reasoning") == true)
            // What this release sends of it: text and tool calls, by its own rule.
            let input = try ProviderClient.requestBody(profile: profile, messages: context, instructions: "", tools: [], sessionID: "s")["input"].list
            XCTAssertFalse(input.contains { $0["type"].text == "reasoning" }); XCTAssertTrue(input.contains { $0["type"].text == "function_call" })
            // And the chat goes on.
            try await session.retryRun(overrides: [:])
            try await eventually { !(await session.isRunning) }
            let after = await session.snapshot(["includeMessages": false]), last = await session.context.last
            XCTAssertEqual(after["state"].text, "idle", after["preflightError"].encoded()); XCTAssertEqual(last?.text, "Still here.")
            await session.close()
            // The next pass reads the same chat again, as it was written.
            try FileManager.default.removeItem(at: root.appendingPathComponent("state"))
            try FileManager.default.copyItem(at: source.appendingPathComponent("state"), to: root.appendingPathComponent("state"))
        }
    }
}
