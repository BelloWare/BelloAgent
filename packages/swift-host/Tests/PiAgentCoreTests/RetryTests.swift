import XCTest
@testable import PiAgentCore

/// Fails a scripted number of times before answering, so the retry policy can
/// be observed without a network.
private actor FlakyClient: ModelClient {
    var failures: [AgentError], replies: [ModelReply], requests = 0
    init(failures: [AgentError], replies: [ModelReply]) { self.failures = failures; self.replies = replies }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1
        try Task.checkCancellation()
        if !failures.isEmpty {
            // A partial reply arrives before the stream dies, as with a dropped connection.
            try await onDelta(.text("partial "))
            throw failures.removeFirst()
        }
        guard !replies.isEmpty else { throw AgentError("fixture_exhausted", "Unexpected model request") }
        let reply = replies.removeFirst(); try await onDelta(.text(reply.message.text)); return reply
    }
}

final class RetryTests: XCTestCase {
    private func session(_ client: FlakyClient, root: URL) throws -> AgentSession {
        try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
    }

    func testTransientFailuresAreRetriedTwiceBeforeTheReplyLands() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_transport","stream dropped"),AgentError("provider_http","Provider returned HTTP 503. Inspect request a.")],replies:[answer("finally")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        // The first attempt fails at once; the session then waits one second before the second.
        try await eventually { await session.snapshot()["runStatus"].text == "retrying" }
        let midway = await session.snapshot()
        XCTAssertEqual(midway["retry"]["attempt"].int, 2); XCTAssertEqual(midway["retry"]["of"].int, 3); XCTAssertEqual(midway["retry"]["reason"].text, "stream dropped")
        XCTAssertEqual(midway["state"].text, "running")
        XCTAssertEqual(midway["messages"].list.last?["text"].text, "", "The failed attempt's partial text is dropped before the retry")
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests, 3)
        let final = await session.snapshot()
        XCTAssertEqual(final["state"].text, "idle"); XCTAssertTrue(final["retry"].isNull)
        XCTAssertEqual(final["messages"].list.last?["text"].text, "finally")
        await session.close()
    }

    func testTheThirdFailureIsReportedWithItsAttemptCount() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:Array(repeating:AgentError("provider_failed","Model overloaded (overloaded_error)"),count:3),replies:[])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests, 3, "Two retries, never more")
        let final = await session.snapshot()
        XCTAssertEqual(final["state"].text, "error")
        XCTAssertEqual(final["preflightError"].text, "Failed after 3 attempts. Model overloaded (overloaded_error)")
        XCTAssertTrue(final["retry"].isNull)
        await session.close()
    }

    func testRequestErrorsFailAtOnce() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_http","Provider returned HTTP 400. Invalid request.")],replies:[answer("never")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests, 1)
        let final = await session.snapshot()
        XCTAssertEqual(final["preflightError"].text, "Provider returned HTTP 400. Invalid request.", "A single failure keeps the original message")
        await session.close()
    }

    func testStopDuringTheBackoffCancelsInsteadOfRetrying() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_transport","stream dropped")],replies:[answer("never")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { await session.snapshot()["runStatus"].text == "retrying" }
        await session.stop()
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests, 1)
        let final = await session.snapshot()
        XCTAssertEqual(final["runStatus"].text, "cancelled"); XCTAssertTrue(final["retry"].isNull)
        await session.close()
    }

    func testRetryPolicy() {
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_transport", "x")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_http", "Provider returned HTTP 429. slow down")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_http", "Provider returned HTTP 502. bad gateway")))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_http", "Provider returned HTTP 401. no")))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_http", "Provider returned HTTP 404. no such model")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_failed", "The server is temporarily unavailable (server_error)")))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_failed", "Requested model is unavailable.\nCheck the route. (model_not_found)")), "A missing model is not transient even though it says unavailable")
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_failed", "Invalid API key (authentication_error)")))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("context_limit", "too big")))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("request_limit", "too big")))
        XCTAssertEqual(AgentSession.httpStatus(in: "Provider returned HTTP 503. x"), 503); XCTAssertNil(AgentSession.httpStatus(in: "no status"))
    }

    func testRowsCarryTheirTurnAndTheMeasuredModelTime() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[],replies:[answer("hello")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"turn-1",text:"go"),steer:false)
        try await eventually { !(await session.isRunning) }
        let rows = await session.snapshot()["messages"].list
        XCTAssertEqual(rows.map { $0["turn"].text }, ["turn-1", "turn-1"], "The user row and the reply both name the turn they belong to")
        XCTAssertNil(rows[0]["modelMs"].double, "A user row has no model request")
        let modelMs = try XCTUnwrap(rows[1]["modelMs"].double)
        XCTAssertGreaterThanOrEqual(modelMs, 0)
        await session.close()
        // The journal keeps both fields, so a reopened session groups and times its turns the same way.
        let path=root.appendingPathComponent("state").appendingPathComponent("s.jsonl").path
        let reopened=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:FlakyClient(failures:[],replies:[]),tools:RecordingTools(),traces:TraceStore(),resumePath:path,autoCompaction:false)
        let restored = await reopened.snapshot()["messages"].list
        XCTAssertEqual(restored.map { $0["turn"].text }, ["turn-1", "turn-1"])
        XCTAssertEqual(restored[1]["modelMs"].double, modelMs)
        await reopened.close()
    }
}
