import XCTest
@testable import PiApp

/// Resume (0.1.125), with the real helper and the synthetic gateway: a run
/// stopped by Stop, by a quit and relaunch, or by an update's pause goes on
/// from the chat's history with no new message, once, and only when the
/// reader presses Resume. Serial with the rest of `LifecycleHelperTests`.
extension LifecycleHelperTests {
    /// The gateway's captured requests, in order, as their JSON bodies.
    static func capturedBodies(_ base: String) async throws -> [[String: WireValue]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        let records = try JSONDecoder().decode([[String: WireValue]].self, from: data)
        return records.filter { $0["connectionTest"]?.bool != true }.compactMap { record in
            guard let encoded = record["request"]?.string, let raw = Data(base64Encoded: encoded) else { return nil }
            return try? JSONDecoder().decode([String: WireValue].self, from: raw)
        }
    }
    /// The roles of a Responses request's input messages, in order.
    static func inputRoles(_ body: [String: WireValue]) -> [String] {
        (body["input"]?.array ?? []).compactMap { $0.object?["role"]?.string ?? $0.object?["type"]?.string }
    }

    @MainActor private func streaming(_ bench: Bench, _ model: WorkspaceModel, _ chat: ChatRecord, settle: () async -> Void) async throws -> SessionDisplay {
        await model.select(chat.id)
        let session = try XCTUnwrap(model.displays[chat.id])
        session.draft = "slow: walk through the retry loop step by step"
        model.send(sessionID: chat.id)
        try await Self.waitUntil("No text streamed", settle: settle) { session.busy && session.messages.contains { $0.role == "assistant" && !$0.text.isEmpty } }
        return session
    }

    /// Stop, then Resume: the paused row offers Resume; after a quit and
    /// relaunch the chat offers it again when opened, and nothing runs until
    /// it is pressed; a double press runs the continuation once; the
    /// continuation's request carries the history without the cut-off reply.
    @MainActor func testAStoppedRunResumesOnceAfterARelaunch() async throws {
        let bench = try await Bench("resume-relaunch"); defer { bench.tearDown() }
        var model = bench.model
        let chat = try await bench.newChat("Retry loop")
        func settle() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(25)) }
        let session = try await streaming(bench, model, chat, settle: settle)
        model.stop(sessionID: chat.id)
        try await Self.waitUntil("The run never paused", settle: settle) { session.runState == .paused && !session.busy && session.continuable == true }
        XCTAssertTrue(session.offersResume)
        let row = try XCTUnwrap(session.presentedMessages.last)
        XCTAssertEqual(row.id, "paused:run:" + chat.id); XCTAssertEqual(row.failureCode, SessionDisplay.pausedCode)
        XCTAssertEqual(model.runHolds[chat.id]?.state, "paused")
        let sent = try await Self.modelRequests(bench.fixture.base)
        let other = try await bench.newChat("Other")
        await model.select(other.id); await model.flushSelection()

        model = try await bench.relaunch()
        await model.runHoldVerification?.value
        XCTAssertEqual(model.heldRunState(chat.id), "paused")
        await model.select(chat.id)
        let reopened = try XCTUnwrap(model.displays[chat.id])
        try await Self.waitUntil("The chat never read its state", settle: settle) { reopened.runStateKnown && reopened.runState == .paused }
        XCTAssertTrue(reopened.offersResume, "Resume is offered after the relaunch")
        XCTAssertTrue(reopened.presentedMessages.contains { $0.failureCode == SessionDisplay.pausedCode })
        for _ in 0..<40 { await settle() }
        let afterOpen = try await Self.modelRequests(bench.fixture.base)
        XCTAssertEqual(afterOpen, sent, "nothing resumes by itself")

        // A double press: one continuation.
        model.resumeRun(sessionID: chat.id); model.resumeRun(sessionID: chat.id)
        try await Self.waitUntil("Resume never ran", seconds: 90, settle: settle) { reopened.busy }
        model.resumeRun(sessionID: chat.id)
        try await Self.waitUntil("The resumed run never finished", seconds: 90, settle: settle) { !reopened.busy && reopened.runState == .idle && !reopened.resuming }
        let afterResume = try await Self.modelRequests(bench.fixture.base)
        XCTAssertEqual(afterResume, sent + 1, "Resume runs the model once")
        let bodies = try await Self.capturedBodies(bench.fixture.base)
        let roles = Self.inputRoles(try XCTUnwrap(bodies.last))
        XCTAssertEqual(roles.last, "user", "the continuation answers the question; no new user message")
        XCTAssertFalse(roles.contains("assistant"), "the cut-off reply is never sent again: \(roles)")
        XCTAssertFalse(reopened.offersResume)
        XCTAssertNil(model.runHolds[chat.id], "Resume cleared the hold")
        XCTAssertNil(model.error, model.error ?? "")
        let replies = reopened.messages.filter { $0.role == "assistant" }
        XCTAssertGreaterThanOrEqual(replies.count, 2, "the cut-off reply stays, and the continuation is a new reply")
        await bench.close()
    }

    /// Resume racing a Send: never two runs at once, the message is
    /// delivered once, and at most one continuation goes.
    @MainActor func testResumeRacingSendRunsOneThingAtATime() async throws {
        let bench = try await Bench("resume-race"); defer { bench.tearDown() }
        let model = bench.model
        let chat = try await bench.newChat("Race")
        func settle() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(25)) }
        let session = try await streaming(bench, model, chat, settle: settle)
        model.stop(sessionID: chat.id)
        try await Self.waitUntil("The run never paused", settle: settle) { session.runState == .paused && !session.busy && session.continuable == true }
        let sent = try await Self.modelRequests(bench.fixture.base)
        session.draft = "Quick question instead"
        model.resumeRun(sessionID: chat.id); model.send(sessionID: chat.id)
        try await Self.waitUntil("Nothing ran", seconds: 90, settle: settle) { session.busy }
        try await Self.waitUntil("The work never finished", seconds: 120, settle: settle) {
            !session.busy && !session.resuming && session.queue.isEmpty && session.runState == .idle
        }
        let bodies = Array(try await Self.capturedBodies(bench.fixture.base).dropFirst(sent))
        XCTAssertGreaterThanOrEqual(bodies.count, 1); XCTAssertLessThanOrEqual(bodies.count, 2)
        let continuations = bodies.filter { body in
            let input = body["input"]?.array ?? []
            return !input.contains { ($0.object?["content"].map { "\($0)" } ?? "").contains("Quick question instead") }
        }
        XCTAssertLessThanOrEqual(continuations.count, 1, "never two continuations")
        let delivered = session.messages.filter { $0.role == "user" && $0.text == "Quick question instead" }
        XCTAssertEqual(delivered.count, 1, "the message is delivered once")
        XCTAssertNil(model.error, model.error ?? "")
        await bench.close()
    }

    /// Check for Updates while a chat runs, confirmed, and no update found:
    /// the chat is paused as a quit pauses it (its helper stopped, its hold
    /// saved, not "outcome uncertain"), offers Resume, and Resume starts its
    /// helper again and goes on once.
    @MainActor func testAChatPausedForAnUpdateOffersResumeAndResumes() async throws {
        let bench = try await Bench("resume-update"); defer { bench.tearDown() }
        let model = bench.model
        let chat = try await bench.newChat("Update pause")
        func settle() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(25)) }
        let session = try await streaming(bench, model, chat, settle: settle)
        XCTAssertTrue(model.hasActiveWork)
        try await model.pauseRunsForUpdate()
        XCTAssertEqual(session.runState, .paused); XCTAssertFalse(session.uncertain, "a pause is not a crash")
        XCTAssertFalse(model.hasActiveWork, "nothing holds the update any more")
        XCTAssertTrue(session.offersResume)
        XCTAssertEqual(model.runHolds[chat.id]?.state, "paused")
        XCTAssertFalse(model.opened.contains(chat.id))
        let sent = try await Self.modelRequests(bench.fixture.base)
        for _ in 0..<20 { await settle() }
        let quiet = try await Self.modelRequests(bench.fixture.base)
        XCTAssertEqual(quiet, sent, "no update was found: nothing resumes by itself")
        model.resumeRun(sessionID: chat.id)
        try await Self.waitUntil("The resumed run never finished", seconds: 90, settle: settle) {
            model.opened.contains(chat.id) && !session.busy && session.runState == .idle && !session.resuming
        }
        let afterResume = try await Self.modelRequests(bench.fixture.base)
        XCTAssertEqual(afterResume, sent + 1)
        XCTAssertNil(model.runHolds[chat.id])
        XCTAssertNil(model.error, model.error ?? "")
        await bench.close()
    }
}
