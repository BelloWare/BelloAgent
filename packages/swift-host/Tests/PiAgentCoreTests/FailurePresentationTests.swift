import XCTest
@testable import PiAgentCore

private actor FailedResponseClient: ModelClient {
    private(set) var count = 0
    private var held = true
    func release() { held = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        count += 1
        if count == 1 {
            while held { try await Task.sleep(nanoseconds: 1_000_000) }
            // A named request problem, as a gateway reports it; transient conditions are retried instead (RetryTests).
            throw AgentError("provider_failed", "The requested model is unavailable.\nChoose another model. (model_not_found)")
        }
        return answer("Explicit retry completed")
    }
}

final class FailurePresentationTests: XCTestCase {
    func testFailureIsAnErrorWithDetailsAndRestoresWithoutReplayingQueuedWork() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), profile = try fixtureProfile(), client = FailedResponseClient()
        let session = try AgentSession(id: "failed", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "next", turnID: "next", text: "Follow-up"), steer: false)
        await client.release(); try await eventually { !(await session.isRunning) }
        let failed = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(failed["state"].text, "error")
        XCTAssertEqual(failed["runStatus"].text, "failed")
        XCTAssertEqual(failed["activity"]["phase"].text, "error")
        XCTAssertEqual(failed["queuePaused"].flag, true)
        XCTAssertEqual(failed["queueCount"].int, 1)
        XCTAssertTrue(failed["preflightError"].text?.contains("requested model is unavailable") == true)
        let originalCount = await client.count; XCTAssertEqual(originalCount, 1)
        let path = try XCTUnwrap(failed["path"].text)
        await session.close()

        let replay = ScriptClient([answer("Follow-up completed")])
        let reopened = try AgentSession(id: "failed", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: Resources(cwd: root, home: root), client: replay, tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false)
        let restored = await reopened.snapshot(["includeMessages": false]), beforeResume = await replay.count
        XCTAssertEqual(restored["state"].text, "error")
        XCTAssertEqual(restored["preflightError"], failed["preflightError"])
        XCTAssertEqual(restored["queuePaused"].flag, true)
        XCTAssertEqual(beforeResume, 0, "Opening retained failure must not retry its request or follow-ups")
        do {
            _ = try await reopened.submit(Submission(commandID: "new", turnID: "new", text: "Another question"), steer: false)
            XCTFail("Paused follow-ups require an explicit resume or removal")
        } catch let error as AgentError { XCTAssertEqual(error.code, "queue_paused") }
        try await reopened.resumeQueue(); try await eventually { !(await reopened.isRunning) }
        let completed = await reopened.snapshot(["includeMessages": false]), afterResume = await replay.count
        XCTAssertEqual(completed["state"].text, "idle"); XCTAssertTrue(completed["preflightError"].isNull)
        XCTAssertEqual(afterResume, 1)
        await reopened.close()
    }

    func testRemovingPendingFollowupKeepsFailureVisibleAndAllowsANewSubmission() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = FailedResponseClient()
        let session = try AgentSession(id: "retry", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "next", turnID: "next", text: "Follow-up"), steer: false)
        await client.release(); try await eventually { !(await session.isRunning) }
        try await session.removeQueued("next")
        let removed = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(removed["state"].text, "error"); XCTAssertNotNil(removed["preflightError"].text)
        XCTAssertEqual(removed["queueCount"].int, 0)
        _ = try await session.submit(Submission(commandID: "retry", turnID: "retry", text: "Try again"), steer: false)
        try await eventually { !(await session.isRunning) }
        let retried = await session.snapshot(["includeMessages": false]), count = await client.count
        XCTAssertEqual(retried["state"].text, "idle"); XCTAssertTrue(retried["preflightError"].isNull)
        XCTAssertEqual(count, 2)
        await session.close()
    }

    func testDeliberateStopRemainsPausedAndCancelled() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = FailedResponseClient()
        let session = try AgentSession(id: "cancel", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Question"), steer: false)
        try await eventually { await client.count == 1 }
        await session.stop(); try await eventually { !(await session.isRunning) }
        let stopped = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(stopped["state"].text, "paused"); XCTAssertEqual(stopped["runStatus"].text, "cancelled")
        XCTAssertEqual(stopped["activity"]["phase"].text, "paused")
        await session.close()
    }

    func testResponsesAndGatewayErrorsKeepTheirUsefulMessageAndCode() throws {
        let detail: JSON = ["code": "model_not_found", "message": "Requested model is unavailable.\nCheck the route."]
        for event: JSON in [["type": "response.failed", "response": ["error": detail]], ["type": "error", "error": detail], ["type": "error", "code": detail["code"], "message": detail["message"]]] {
            var accumulator = ProviderAccumulator(api: "openai-responses")
            XCTAssertThrowsError(try accumulator.consume(event)) {
                XCTAssertEqual(($0 as? AgentError)?.message, "Requested model is unavailable.\nCheck the route. (model_not_found)")
            }
        }
        var accumulator = ProviderAccumulator(api: "openai-responses")
        XCTAssertThrowsError(try accumulator.acceptJSON(["status": "failed", "error": detail])) {
            XCTAssertEqual(($0 as? AgentError)?.message, "Requested model is unavailable.\nCheck the route. (model_not_found)")
        }
    }

    func testVisibleProviderErrorsMaskCredentialEchoesBeforeApplyingDisplayBound() {
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer synthetic-secret", "x-route-key": "route-secret"], configuredNames: ["x-route-key"])
        let error = AgentError("provider_failed", "Route rejected synthetic-secret and route-secret. Check this model.")
        let safe = ProviderClient.safeFailure(error, credentials: credentials)
        XCTAssertFalse(safe.message.contains("synthetic-secret")); XCTAssertFalse(safe.message.contains("route-secret"))
        XCTAssertTrue(safe.message.contains("Check this model.")); XCTAssertTrue(safe.message.contains("[sha256:"))
        let long = ProviderClient.safeFailure(AgentError("provider_failed", String(repeating: "x", count: 16_380) + "synthetic-secret"), credentials: credentials)
        XCTAssertFalse(long.message.contains("synthetic")); XCTAssertTrue(long.message.contains("Error details truncated"))
        XCTAssertLessThan(long.message.utf8.count, 17_000)
    }

    func testActualHTTP429ErrorPreservesDetailsAndCaptureWithoutLeakingCredentials() async throws {
        try await checkGatewayError(model: "http-failure", status: 429, errorCode: "provider_http")
    }

    func testActualFailedResponseSSEPreservesDetailsAndCaptureWithoutLeakingCredentials() async throws {
        try await checkGatewayError(model: "sse-failure", status: 200, errorCode: "provider_failed")
    }

    private func checkGatewayError(model: String, status: Int, errorCode: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("gateway.py")
        try Data(ConnectionProbeTests.gatewayScript.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, root.path, "errors"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: ready))["port"].int)
        var raw = try fixtureProfile().raw
        raw["baseUrl"] = JSON("http://127.0.0.1:\(port)"); raw["modelId"] = JSON(model)
        raw["headers"] = ["x-route-key": "synthetic-route-key"]
        let traces = TraceStore(), client = ProviderClient(traces: traces), session = "failure-integration"
        do {
            _ = try await client.complete(profile: Profile(raw), apiKey: "synthetic-error-key", messages: [ChatMessage(role: "user", content: [textBlock("Test this response failure")])], instructions: "Failure transport test", tools: [], sessionID: session, turnID: "failure-turn", purpose: "turn", onDelta: { _ in XCTFail("An error response must not publish successful content") })
            XCTFail("The gateway failure must reach the caller")
        } catch let error as AgentError {
            XCTAssertEqual(error.code, errorCode)
            XCTAssertTrue(error.message.contains("Rate limit reached. Retry later."))
            XCTAssertTrue(error.message.contains("rate_limit_exceeded"))
            XCTAssertFalse(error.message.contains("synthetic-error-key")); XCTAssertFalse(error.message.contains("synthetic-route-key"))
            XCTAssertTrue(error.message.contains("[sha256:"))
            if status == 429 { XCTAssertTrue(error.message.contains("HTTP 429")) }
        }
        let attempts = try await traces.command("debug.list", session: session, params: [:])["attempts"].list
        XCTAssertEqual(attempts.count, 1, "A failed response is never retried automatically")
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt["outcome"].text, "failed")
        let metadata = try await traces.command("debug.attempt", session: session, params: ["attemptId": attempt["attemptId"]])
        XCTAssertEqual(metadata["status"].int, status)
        XCTAssertFalse(metadata.encoded().contains("synthetic-error-key")); XCTAssertFalse(metadata.encoded().contains("synthetic-route-key"))
        let recorded = try JSON.parse(Data(contentsOf: root.appendingPathComponent("record.json")))
        for kind in ["request", "response"] {
            let captured = try await traces.command("debug.body", session: session, params: ["attemptId": attempt["attemptId"], "body": JSON(kind)])
            let original = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(recorded[kind].text)))
            if kind == "response" {
                var expected = String(decoding: original, as: UTF8.self)
                for credential in ["synthetic-error-key", "synthetic-route-key"] {
                    expected = expected.replacingOccurrences(of: credential, with: String(repeating: "*", count: credential.utf8.count))
                }
                XCTAssertEqual(Data(base64Encoded: captured["bytes"].text!), Data(expected.utf8))
                XCTAssertEqual(captured["byteExact"].flag, false)
                XCTAssertEqual(captured["state"].text, "credential-masked")
                XCTAssertEqual(captured["observedBytes"].int, original.count)
            } else { XCTAssertEqual(captured["bytes"], recorded[kind], "An unchanged request remains byte-exact") }
        }
    }

    /// A gateway failure names its likely cause in the reader's terms, keeping the
    /// status the retry policy and the connection test read.
    func testGatewayFailuresSayWhatToCheck() {
        let unauthorized = ProviderClient.guidance(status: 401, detail: nil, attempt: "3")
        XCTAssertTrue(unauthorized.contains("API key"), unauthorized); XCTAssertTrue(unauthorized.contains("Inspect request 3"), unauthorized)
        let missing = ProviderClient.guidance(status: 404, detail: "No such model: gpt-x", attempt: "1")
        XCTAssertTrue(missing.hasPrefix("No such model: gpt-x."), missing); XCTAssertTrue(missing.contains("model alias"), missing)
        XCTAssertFalse(missing.contains("Inspect request"), "a provider detail replaces the pointer to the captured body")
        XCTAssertTrue(ProviderClient.guidance(status: 429, detail: nil, attempt: "2").contains("rate limiting"))
        XCTAssertTrue(ProviderClient.guidance(status: 502, detail: nil, attempt: "2").contains("failed on its side"))
        XCTAssertTrue(ProviderClient.guidance(status: 400, detail: nil, attempt: "4").hasPrefix("Inspect request 4"))
        XCTAssertTrue(ProviderClient.transportGuidance(URLError(.cannotFindHost), attempt: "1").contains("host could not be found"))
        XCTAssertTrue(ProviderClient.transportGuidance(URLError(.cannotConnectToHost), attempt: "1").contains("could not be reached"))
        XCTAssertTrue(ProviderClient.transportGuidance(URLError(.timedOut), attempt: "1").contains("did not answer in time"))
        XCTAssertTrue(ProviderClient.transportGuidance(URLError(.serverCertificateUntrusted), attempt: "1").contains("certificate"))
        XCTAssertTrue(ProviderClient.transportGuidance(NSError(domain: "x", code: 1), attempt: "5").hasSuffix("Inspect request 5."))
        XCTAssertEqual(AgentSession.httpStatus(in: "Provider returned HTTP 401. " + unauthorized), 401, "the status stays parseable")
    }
}
