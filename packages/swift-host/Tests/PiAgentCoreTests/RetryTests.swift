import XCTest
@testable import PiAgentCore

/// Fails a scripted number of times before answering, so the retry policy can
/// be observed without a network.
private actor FlakyClient: ModelClient {
    var failures: [AgentError], replies: [ModelReply], requests = 0
    /// The model and reasoning effort of every request, so a retry can be compared with the request it repeats.
    var routes: [String] = []
    init(failures: [AgentError], replies: [ModelReply]) { self.failures = failures; self.replies = replies }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1; routes.append(profile.model + "/" + (profile.raw["thinkingLevel"].text ?? "default"))
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

/// Fails its first request as a dropped connection, then holds every later
/// request until it is cancelled: a retried request the reader stops.
private actor HeldRetryClient: ModelClient {
    var requests = 0
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests += 1
        if requests == 1 { try await onDelta(.text("partial ")); throw AgentError("provider_transport", "stream dropped") }
        while true { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}

final class RetryTests: XCTestCase {
    private func session(_ client: FlakyClient, root: URL) throws -> AgentSession {
        try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
    }

    /// A request the policy does not retry on its own can be retried by the
    /// reader from where it stopped, without a new message; a completed turn cannot.
    func testAFailedRequestCanBeRetriedFromWhereItStopped() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_http","Provider returned HTTP 401. The gateway rejected the API key."),AgentError("provider_http","Provider returned HTTP 401. Still rejected.")],replies:[answer("recovered")])
        let session=try session(client,root:root)
        var submission=Submission(commandID:"c1",turnID:"t1",text:"go"); submission.model="override-model"; submission.thinkingLevel="high"
        _ = try await session.submit(submission,steer:false)
        try await eventually { !(await session.isRunning) }
        let failed=await session.snapshot(); let firstRequests=await client.requests
        XCTAssertEqual(failed["state"].text,"error"); XCTAssertEqual(firstRequests,1,"a 401 is not retried by the policy")
        // The retry carries the chat's current choices: here the pills moved to another model and effort.
        try await session.retryRun(overrides:["model":"switched-model","thinkingLevel":"low"])
        try await eventually { !(await session.isRunning) }
        let switched=await session.snapshot()
        XCTAssertEqual(switched["state"].text,"error","the second attempt failed too")
        // Cleared pills retry with the connection's own model and effort.
        try await session.retryRun(overrides:[:])
        try await eventually { !(await session.isRunning) }
        let recovered=await session.snapshot(); let secondRequests=await client.requests; let routes=await client.routes
        let profile=try fixtureProfile(); let defaults=profile.model + "/" + (profile.raw["thinkingLevel"].text ?? "default")
        XCTAssertEqual(routes,["override-model/high","switched-model/low",defaults],"each retry sends the chat's current model and effort")
        XCTAssertEqual(secondRequests,3)
        XCTAssertEqual(recovered["state"].text,"idle"); XCTAssertTrue(recovered["preflightError"].isNull); XCTAssertEqual(recovered["queuePaused"].flag,false)
        XCTAssertEqual(recovered["messages"].list.last?["text"].text,"recovered")
        XCTAssertEqual(recovered["messages"].list.filter { $0["role"].text=="user" }.count,1,"no message was added to retry")
        do { try await session.retryRun(); XCTFail("a completed turn has nothing to retry") } catch let error as AgentError { XCTAssertEqual(error.code,"nothing_to_retry") }
        await session.close()
    }

    func testTransientFailuresAreRetriedTwiceBeforeTheReplyLands() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_transport","stream dropped"),AgentError("provider_http","Provider returned HTTP 503. Inspect request a.")],replies:[answer("finally")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        // The first attempt fails at once; the session then waits one second before the second.
        try await eventually { await session.snapshot()["runStatus"].text == "retrying" }
        let midway = await session.snapshot()
        XCTAssertEqual(midway["retry"]["attempt"].int, 2); XCTAssertEqual(midway["retry"]["of"].int, 6); XCTAssertEqual(midway["retry"]["reason"].text, "stream dropped")
        XCTAssertEqual(midway["state"].text, "running")
        XCTAssertEqual(midway["messages"].list.last?["text"].text, "", "The replacement attempt starts with a new, empty source")
        XCTAssertEqual(midway["messages"].list.filter { $0["stopReason"].text == "interrupted" }.count,1,"The failed attempt's visible prose stays inspectable")
        XCTAssertEqual(midway["taskPresentation"]["active"]["rootID"].text,"t1")
        XCTAssertTrue(midway["taskPresentation"]["recent"].list.isEmpty,"A retry is not task completion")
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        XCTAssertEqual(requests, 3)
        let final = await session.snapshot()
        XCTAssertEqual(final["state"].text, "idle"); XCTAssertTrue(final["retry"].isNull)
        XCTAssertEqual(final["messages"].list.last?["text"].text, "finally")
        XCTAssertEqual(final["taskPresentation"]["recent"].list.count,1)
        XCTAssertEqual(final["taskPresentation"]["recent"].list.first?["executionID"],midway["taskPresentation"]["active"]["executionID"])
        let assistants = final["messages"].list.filter { $0["role"].text == "assistant" }
        XCTAssertEqual(Set(assistants.compactMap { $0["id"].text }).count,3,"Two retained failed attempts and the final prose never share a body")
        await session.close()
    }

    func testFiveRetriesStopAfterSixFailedAttempts() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:Array(repeating:AgentError("provider_failed","Model overloaded (overloaded_error)"),count:6),replies:[])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        let deadline = Date().addingTimeInterval(40)
        while await session.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let running = await session.isRunning
        XCTAssertFalse(running, "Five bounded backoffs must eventually settle")
        let requests = await client.requests
        XCTAssertEqual(requests, 6, "Initial request plus five retries, never a seventh attempt")
        let final = await session.snapshot()
        XCTAssertEqual(final["state"].text, "error")
        XCTAssertEqual(final["preflightError"].text, "Failed after 6 attempts. Model overloaded (overloaded_error)")
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

    /// A stream that stopped before its terminal event ran no tool: its partial
    /// reply stays as an interrupted row and the request is sent again.
    func testAStreamThatEndsWithoutItsTerminalEventIsRetried() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("incomplete_stream","The stream ended without its terminal event. No tool arguments were executed.")],replies:[answer("complete")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, final = await session.snapshot()
        XCTAssertEqual(requests, 2, "the cut stream is retried once and the reply lands")
        XCTAssertEqual(final["state"].text, "idle"); XCTAssertEqual(final["messages"].list.last?["text"].text, "complete")
        XCTAssertEqual(final["messages"].list.filter { $0["stopReason"].text == "interrupted" }.count, 1, "the partial reply stays inspectable")
        await session.close()
    }

    /// Stop while the retried request is in flight: the run is cancelled and
    /// the notice of the retry it was making goes with it.
    func testStopDuringARetriedRequestClearsTheRetryNotice() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=HeldRetryClient()
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { await session.snapshot()["runStatus"].text == "retrying" }
        try await eventually { let status = await session.snapshot()["runStatus"].text, requests = await client.requests; return status == "running" && requests == 2 }
        let during = await session.snapshot()
        XCTAssertEqual(during["retry"]["attempt"].int, 2, "the retried request says which attempt it is while it runs")
        await session.stop()
        try await eventually { !(await session.isRunning) }
        let final = await session.snapshot()
        XCTAssertEqual(final["runStatus"].text, "cancelled"); XCTAssertEqual(final["state"].text, "paused")
        XCTAssertTrue(final["retry"].isNull, "a stopped run is not retrying: \(final["retry"].encoded())")
        await session.close()
    }

    /// Model time is time spent in model requests: the back-off between a
    /// failed attempt and its retry is waiting, and the failed attempt is not
    /// the reply's own request.
    func testModelTimeCountsRequestsNotTheBackoffBetweenThem() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlakyClient(failures:[AgentError("provider_transport","stream dropped")],replies:[answer("done")])
        let session=try session(client,root:root)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        try await eventually { !(await session.isRunning) }
        let state=await session.snapshot()
        let reply=try XCTUnwrap(state["messages"].list.last { $0["role"].text == "assistant" && $0["text"].text == "done" })
        let replyMs=try XCTUnwrap(reply["modelMs"].double), turnMs=try XCTUnwrap(state["turnMetrics"]["modelMs"].double)
        print("PERF model-time-with-retry replyModelMs=\(replyMs) turnModelMs=\(turnMs)")
        XCTAssertLessThan(replyMs, 500, "the reply's model time is its own request, not the one-second back-off before it")
        XCTAssertLessThan(turnMs, 500, "the turn's model time sums its requests, not the waits between them")
        await session.close()
    }

    func testRetryPolicy() {
        XCTAssertTrue(AgentSession.isRetryable(AgentError("incomplete_stream", "The stream ended without its terminal event. No tool arguments were executed.")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_failed", "Overloaded (529)")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("provider_transport", "x")))
        XCTAssertTrue(AgentSession.isRetryable(AgentError("stream_backpressure", "Consumer could not keep up")), "a dropped stream is retried, never reported as the model's failure")
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
