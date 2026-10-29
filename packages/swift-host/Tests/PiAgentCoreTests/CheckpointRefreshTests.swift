import XCTest
@testable import PiAgentCore

final class CheckpointRefreshTests: HelperTestCase {
    private struct Fixture {
        let root: URL, profile: Profile, session: AgentSession
    }

    private func fixture() async throws -> Fixture {
        let root = try temporaryDirectory(), profile = try fixtureProfile()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var policy = CompactionPolicy(); policy.keepRecentTokens = 1
        let replies = (0..<6).map { answer("Answer \($0) " + String(repeating: "evidence ", count: 60)) }
            + [answer("Summary of the generated conversation."), answer("A settled durable suffix")]
        let session = try AgentSession(id: "refresh", profile: profile, apiKey: "synthetic-only", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient(replies), tools: RecordingTools(),
            traces: TraceStore(), autoCompaction: false, compactionPolicy: policy)
        addTeardownBlock { await session.close() }
        for n in 0..<6 {
            _ = try await session.submit(Submission(commandID: "c\(n)", turnID: "t\(n)", text: "Question \(n)"), steer: false)
            try await eventually { !(await session.isRunning) }
        }
        try await session.compact(commandID: "compact")
        try await eventually { !(await session.isRunning) }
        return Fixture(root: root, profile: profile, session: session)
    }

    func testSettledDurableSuffixRefreshesBeforeCloseAndSurvivesACrashCopy() async throws {
        let fixture = try await fixture(), session = fixture.session
        let path = await session.path, url = URL(fileURLWithPath: try XCTUnwrap(path))
        let before = try XCTUnwrap(JournalCheckpoint.read(for: url))
        // A journal-backed row that the live projection does not hold is
        // deliberate: a refresh must use replay state, not that projection.
        try await session.appendRefreshSuffixForTesting()
        _ = try await session.submit(Submission(commandID: "suffix", turnID: "suffix", text: "Finish the durable turn"), steer: false)
        try await eventually { !(await session.isRunning) }
        try await eventually { (JournalCheckpoint.read(for: url)?.start ?? 0) > before.start }
        let refreshed = try XCTUnwrap(JournalCheckpoint.read(for: url))
        XCTAssertTrue(refreshed.context.contains("journal-only"))
        // Copy while the runtime is alive: close cannot create the checkpoint
        // being tested. The durable journal and its cache survive a crash.
        let copied = fixture.root.appendingPathComponent("crash-copy.jsonl")
        try FileManager.default.copyItem(at: url, to: copied)
        try FileManager.default.copyItem(at: JournalCheckpoint.url(for: url), to: JournalCheckpoint.url(for: copied))
        let reopened = try AgentSession(id: "refresh", profile: fixture.profile, apiKey: "synthetic-only", cwd: fixture.root,
            directory: fixture.root, readOnly: true, resources: Resources(cwd: fixture.root, home: fixture.root),
            client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: copied.path, autoCompaction: false)
        let resumed = await reopened.durable?.r.resumedFrom?.start
        XCTAssertEqual(resumed, refreshed.start)
        let commands = await reopened.snapshot()["commands"].list
        XCTAssertTrue(commands.contains { $0["commandId"].text == "suffix" && $0["status"].text == "completed" })
        let context = await reopened.context.map(\.id)
        XCTAssertTrue(context.contains("journal-only"))
        await reopened.close()
    }

    func testFailedReplacementKeepsThePreviousCheckpointAndRemovesStagingFile() async throws {
        let fixture = try await fixture(), session = fixture.session
        let path = await session.path, url = URL(fileURLWithPath: try XCTUnwrap(path))
        let before = try Data(contentsOf: JournalCheckpoint.url(for: url))
        await session.failRefreshReplacementForTesting()
        _ = try await session.submit(Submission(commandID: "suffix", turnID: "suffix", text: "Another durable turn"), steer: false)
        try await eventually { !(await session.isRunning) }
        try await eventually { await session.refreshAttemptFinishedForTesting() }
        XCTAssertEqual(try Data(contentsOf: JournalCheckpoint.url(for: url)), before)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { JournalCheckpoint.isTemporary($0, for: url) })
    }

    func testOnlyTheExactSettledDurablePrefixCanBeCaptured() throws {
        for variant in ["settled", "active", "delivering", "queued", "delivered", "tail", "attempt"] {
            let fixture = try RefreshJournalFixture(root: temporaryDirectory(), profile: fixtureProfile())
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if variant == "attempt" { try fixture.appendAttempt() }
            var state = RefreshJournalFixture.settledState
            if variant == "active" { state["active"] = true }
            if variant == "delivering" { state["delivering"] = ["lane":"queue"] }
            if ["queued", "delivered"].contains(variant) { state["commands"] = [["commandId":"c", "turnId":"turn", "status":JSON(variant)]] }
            try fixture.state(state)
            if variant == "tail" { try fixture.journal.append(["type":"message", "message":ChatMessage(role:"assistant", content:[textBlock("Unsettled reply")]).pi]) }
            var replay = try fixture.replay()
            let checkpoint = try replay.captureSettledCheckpoint(policy: CheckpointRefreshPolicy())
            XCTAssertEqual(checkpoint != nil, variant == "settled", variant)
        }
    }

    func testPartialCutsCannotBeCapturedAndCompleteFamilyReceiptsSurvive() throws {
        for projected in [-1, 0, 1, 2] {
            let fixture = try RefreshJournalFixture(root: temporaryDirectory(), profile: fixtureProfile(), cuts: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.appendCut(projected: projected)
            try fixture.state(RefreshJournalFixture.settledState)
            var replay = try fixture.replay()
            let captured = try replay.captureSettledCheckpoint(policy: CheckpointRefreshPolicy())
            guard projected == 2 else { XCTAssertNil(captured, "Partial cut \(projected)"); continue }
            let checkpoint = try XCTUnwrap(captured)
            try checkpoint.write(for: fixture.url)
            let loaded = try XCTUnwrap(AgentSession.loadCheckpoint(checkpoint, url: fixture.url))
            var resumed = JournalReplayConsumer(id:"refresh", header:fixture.journal.headerCheck, marker:fixture.journal.markerCheck, spendTracked:false)
            resumed.resume(from:checkpoint, loaded:loaded)
            let before = try replay.finished(), after = try resumed.finished()
            XCTAssertEqual(checkpoint.version, 3)
            XCTAssertEqual(after.subagents, before.subagents)
            XCTAssertNotNil(after.subagents.family)
            XCTAssertEqual(after.subagents.cuts?.commits.count, 1)
            XCTAssertEqual(after.accounting, before.accounting)
            XCTAssertEqual(after.spend, before.spend)
            XCTAssertEqual(after.context.map(\.pi), before.context.map(\.pi))
            XCTAssertEqual(after.stateRecord?["commands"], before.stateRecord?["commands"])
        }
    }

    func testMetadataAndContextBudgetsSkipWithoutTruncatingThePreviousCheckpoint() throws {
        let fixture = try RefreshJournalFixture(root: temporaryDirectory(), profile: fixtureProfile())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state(RefreshJournalFixture.settledState)
        var replay = try fixture.replay()
        let good = try XCTUnwrap(replay.captureSettledCheckpoint(policy: CheckpointRefreshPolicy()))
        for tinyRows in [false, true] {
            var policy = CheckpointRefreshPolicy()
            if tinyRows { policy.rows = 1 } else { policy.metadataBytes = 8 }
            XCTAssertNil(try? replay.captureSettledCheckpoint(policy: policy))
            XCTAssertEqual(try replay.capturedCheckpoint(), good)
        }
        XCTAssertThrowsError(try CheckpointEncodingBudget(bytes: 64).check(String(repeating:"雪\n", count:1_000_000)))
    }

    func testOpeningDefersSettledCheckpointPublicationUntilAfterAdoption() async throws {
        let fixture = try await fixture(), session = fixture.session
        let path = await session.path, url = URL(fileURLWithPath: try XCTUnwrap(path))
        let before = try XCTUnwrap(JournalCheckpoint.read(for: url))
        try await session.appendRefreshSuffixForTesting()
        try await session.persistRefreshStateForTesting()
        let copy = fixture.root.appendingPathComponent("replay-copy.jsonl")
        try FileManager.default.copyItem(at: url, to: copy)
        try before.write(for: copy)
        let opened = try AgentSession(id:"refresh", profile:fixture.profile, apiKey:"synthetic-only", cwd:fixture.root,
            directory:fixture.root, readOnly:true, resources:Resources(cwd:fixture.root, home:fixture.root),
            client:ScriptClient([]), tools:RecordingTools(), traces:TraceStore(), resumePath:copy.path, autoCompaction:false)
        let atReturn = try XCTUnwrap(JournalCheckpoint.read(for:copy))
        XCTAssertEqual(atReturn.start, before.start, "Construction must not capture or publish the settled EOF checkpoint")
        let covered = await opened.durable?.r.coveredBytes
        XCTAssertEqual(covered, try FileManager.default.attributesOfItem(atPath:copy.path)[.size] as? UInt64)
        await opened.scheduleCheckpointRefresh()
        try await eventually { (JournalCheckpoint.read(for:copy)?.start ?? 0) > before.start }
        let published = try XCTUnwrap(JournalCheckpoint.read(for:copy))
        XCTAssertEqual(published.start, covered)
        XCTAssertTrue(published.context.contains("journal-only"))
        await opened.close()

        // The production host schedules this only after it owns the runtime.
        try before.write(for:copy)
        let host = NativeHostService(emit:{ _ in })
        _ = try await host.command("workspace.open", sessionID:nil, params:["cwd":JSON(fixture.root.path), "directory":JSON(fixture.root.path)])
        _ = try await host.command("session.open", sessionID:"refresh", params:["profile":fixture.profile.raw, "apiKey":"synthetic-only", "path":JSON(copy.path)])
        try await eventually { (JournalCheckpoint.read(for:copy)?.start ?? 0) > before.start }
        let adopted = await host.loadedSession("refresh")
        XCTAssertNotNil(adopted)
        await host.shutdown()
    }

    func testLongReplayPublishesIntermediatePrefixesButDefersTheEOF() throws {
        let fixture = try RefreshJournalFixture(root:temporaryDirectory(), profile:fixtureProfile())
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        try fixture.journal.append(["type":"custom", "customType":JSON(JournalRecordKind.context), "data":["ids":["turn","answer"]]])
        try fixture.state(RefreshJournalFixture.settledState)
        try fixture.journal.append(["type":"message", "message":ChatMessage(role:"assistant",content:[textBlock("Durable suffix")]).pi],id:"tail")
        try fixture.state(RefreshJournalFixture.settledState)
        var policy = CheckpointRefreshPolicy()
        policy.bytes = 1; policy.replayBytes = 1; policy.longReplayBytes = 1
        // Inline execution makes interval selection deterministic; the next
        // test exercises the production worker and its stop fence.
        let publisher = ReplayCheckpointPublisher(url:fixture.url, policy:policy, enqueue:{ $0() })
        let replay = try AgentSession.replayConsumer(fixture.journal, url:fixture.url, id:"refresh", binding:fixture.profile.binding,
            spendTracked:false, resume:true, policy:policy, checkpointPublisher:publisher)
        let checkpoint = try XCTUnwrap(JournalCheckpoint.read(for:fixture.url))
        XCTAssertGreaterThan(checkpoint.start, 0)
        XCTAssertLessThan(checkpoint.start, replay.r.coveredBytes, "The last state is EOF work, even when an interval is due")
        XCTAssertEqual(replay.publishedCheckpointThrough, checkpoint.start, "Construction must not write this intermediate cache again")
    }

    func testWireOpeningDefersEOFRefreshUntilReplyDelivery() async throws {
        for inParams in [false, true] {
            let fixture = try await fixture(), session = fixture.session
            let path = await session.path, url = URL(fileURLWithPath:try XCTUnwrap(path))
            let previous = try XCTUnwrap(JournalCheckpoint.read(for:url))
            try await session.appendRefreshSuffixForTesting()
            try await session.persistRefreshStateForTesting()
            let copy = fixture.root.appendingPathComponent("wire-opening.jsonl")
            try FileManager.default.copyItem(at:url, to:copy); try previous.write(for:copy)
            let entered = expectation(description:"opening reply delivery"), delivered = expectation(description:"reply delivered")
            let gate = DispatchSemaphore(value:0)
            let writer = DispatchQueue(label:"checkpoint.test.writer")
            defer { gate.signal() }
            let host = NativeHostService(output:{ output in
                let frame: JSON
                switch output {
                case .frame(let value): frame = value
                case .encoded(let bytes): frame = (try? JSON.parse(bytes)) ?? .null
                }
                guard frame["kind"].text == "reply", frame["commandId"].text == "opening-reply" else { return }
                writer.async { entered.fulfill(); _ = gate.wait(timeout:.now()+5); delivered.fulfill() }
            }, afterOutput:{ writer.async(execute:$0) })
            _ = try await host.command("workspace.open", sessionID:nil, params:["cwd":JSON(fixture.root.path), "directory":JSON(fixture.root.path)])
            await host.receive(["v":1,"kind":"hello","major":1,"displayTransfers":true])
            var params: JSON = ["profile":fixture.profile.raw,"apiKey":"synthetic-only","path":JSON(copy.path),"connectionTest":true]
            if inParams { params["sessionId"] = "refresh" }
            var command: JSON = ["v":1,"kind":"command","hostEpoch":JSON(await host.epoch),"commandId":"opening-reply",
                "method":"session.open","params":params]
            if !inParams { command["sessionId"] = "refresh" }
            await host.receive(command)
            await fulfillment(of:[entered],timeout:3)
            try await Task.sleep(for:.milliseconds(100))
            XCTAssertEqual(JournalCheckpoint.read(for:copy)?.start, previous.start,
                           "EOF capture must not compete with encoding or delivery of the opening reply")
            gate.signal()
            await fulfillment(of:[delivered],timeout:2)
            try await eventually { (JournalCheckpoint.read(for:copy)?.start ?? 0) > previous.start }
            await host.shutdown()
        }
    }

    func testIntermediateCaptureCannotBlockReplayOrPublishAfterStop() async throws {
        let fixture = try RefreshJournalFixture(root:temporaryDirectory(), profile:fixtureProfile())
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        try fixture.state(RefreshJournalFixture.settledState)
        var old = try fixture.replay()
        let previous = try XCTUnwrap(old.captureSettledCheckpoint(policy:CheckpointRefreshPolicy()))
        try previous.write(for:fixture.url)
        try fixture.journal.append(["type":"message", "message":ChatMessage(role:"assistant",content:[textBlock("New durable reply")]).pi],id:"tail")
        try fixture.state(RefreshJournalFixture.settledState)
        let replay = try fixture.replay(), gate = DispatchSemaphore(value:0)
        let entered = expectation(description:"capture entered"), returned = expectation(description:"replay continues")
        entered.assertForOverFulfill = true
        let publisher = ReplayCheckpointPublisher(url:fixture.url, policy:CheckpointRefreshPolicy(), beforeCapture:{
            entered.fulfill(); _ = gate.wait(timeout:.now()+5)
        })
        defer { publisher.stop(); gate.signal() }
        DispatchQueue.global().async { publisher.schedule(replay); returned.fulfill() }
        await fulfillment(of:[entered], timeout:2)
        publisher.schedule(replay) // The in-flight snapshot coalesces later requests.
        await fulfillment(of:[returned], timeout:0.2)
        XCTAssertEqual(publisher.stop(), 0)
        gate.signal()
        try await eventually { !publisher.isBusy }
        XCTAssertEqual(JournalCheckpoint.read(for:fixture.url)?.start, previous.start,
                       "A stopped worker must not overwrite the checkpoint after EOF or cancellation")
        let names = try FileManager.default.contentsOfDirectory(atPath:fixture.root.path)
        XCTAssertFalse(names.contains { JournalCheckpoint.isTemporary($0, for:fixture.url) })
    }

    func testRefreshKeepsTheLineageOutsideTheLoadedRows() throws {
        let fixture = try RefreshJournalFixture(root: temporaryDirectory(), profile: fixtureProfile())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state(RefreshJournalFixture.settledState)
        var full = try fixture.replay()
        var checkpoint = try XCTUnwrap(full.captureSettledCheckpoint(policy: CheckpointRefreshPolicy()))
        // The earlier marker is outside this checkpoint's loaded suffix.
        checkpoint.lineage = "older-edit-marker"; checkpoint.rowsBefore = 10
        let loaded = try XCTUnwrap(AgentSession.loadCheckpoint(checkpoint, url: fixture.url))
        var resumed = JournalReplayConsumer(id:"refresh", header:fixture.journal.headerCheck, marker:fixture.journal.markerCheck, spendTracked:false)
        resumed.resume(from:checkpoint, loaded:loaded)
        try fixture.journal.append(["type":"custom", "customType":JSON(JournalRecordKind.context), "data":["ids":["turn", "answer"]]])
        try fixture.state(RefreshJournalFixture.settledState)
        let reader = try fixture.journal.recordReader(from:checkpoint.start)
        while true {
            let start = reader.completeBytes
            guard let line = try reader.nextLine() else { break }
            try resumed.consume(line, at:start)
        }
        let refreshed = try XCTUnwrap(resumed.captureSettledCheckpoint(policy: CheckpointRefreshPolicy()))
        XCTAssertEqual(refreshed.lineage, checkpoint.lineage)
        XCTAssertEqual(refreshed.rowsBefore, checkpoint.rowsBefore)
    }

    func testTimeThresholdWaitsForASettledSuffix() async throws {
        let fixture = try await fixture(), session = fixture.session
        let path = await session.path, url = URL(fileURLWithPath: try XCTUnwrap(path))
        let before = try XCTUnwrap(JournalCheckpoint.read(for:url))
        await session.configureRefreshClockForTesting(now:100)
        try await session.persistRefreshStateForTesting()
        await session.tickRefreshClockForTesting(now:159)
        let early = await session.checkpointRefreshTask != nil
        XCTAssertFalse(early)
        await session.tickRefreshClockForTesting(now:160)
        try await eventually { (JournalCheckpoint.read(for:url)?.start ?? 0) > before.start }
    }
}

private extension AgentSession {
    func appendRefreshSuffixForTesting() throws {
        try journal?.append(["type":"message", "message":["role":"assistant",
            "content":JSON(String(repeating: "ordinary diagnostic\n", count: 500_000))]], id: "journal-only")
    }
    func failRefreshReplacementForTesting() {
        checkpointRefreshPolicy.bytes = 1
        beforeCheckpointReplacement = { throw AgentError("fixture", "Replacement failed") }
    }
    func refreshAttemptFinishedForTesting() -> Bool { checkpointRefreshAttemptedThrough > 0 && checkpointRefreshTask == nil }
    func persistRefreshStateForTesting() throws { try persistState(active:false, durable:true) }
    func configureRefreshClockForTesting(now: Double) {
        checkpointRefreshPolicy.bytes = .max
        checkpointRefreshAttemptedAt = now
        checkpointRefreshClock = { now }
    }
    func tickRefreshClockForTesting(now: Double) {
        checkpointRefreshClock = { now }; scheduleCheckpointRefresh()
    }
}
