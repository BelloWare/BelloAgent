import XCTest
@testable import PiAgentCore

private final class ContentReadGate: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var steps = 0
    let holding: Bool
    init(holding: Bool = true) { self.holding = holding }
    var count: Int { lock.withLock { steps } }
    func step(_ stage: String) {
        guard stage == "content" else { return }
        let first = lock.withLock { steps += 1; return steps == 1 }
        if first && holding { _ = release.wait(timeout: .now() + 10) }
    }
    func open() { release.signal() }
}

final class ConversationReadTests: XCTestCase {
    private func fixture(rows: Int = 130) async throws -> AgentSession {
        let root = try temporaryDirectory(), path = root.appendingPathComponent("copy.jsonl"), profile = try fixtureProfile()
        do {
            let journal = try SessionJournal(url: path, id: "copy", cwd: root, binding: profile.binding, create: true)
            for index in 0..<rows {
                try journal.append(["type": "message", "message": ["role": "assistant", "content": [
                    textBlock("Answer \(index)"), ["type": "thinking", "thinking": JSON("REASONING-\(index)")]]]], id: "r\(index)", flush: false)
            }
            try journal.synchronize()
        }
        let session = try AgentSession(id: "copy", profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true,
            resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path)
        addTeardownBlock { await session.close(); try? FileManager.default.removeItem(at: root) }
        return session
    }

    func testEmptyAndUncoveredTimelinesKeepCanonicalAnswer() throws {
        var accumulator = ProviderAccumulator(api: "openai-responses"), display = ProviderDisplayEvents(api: "openai-responses", attempt: "fixture")
        for event: JSON in [
            ["type": "response.output_item.done", "output_index": 0, "item": ["id": "answer", "type": "message", "content": [["type": "output_text", "text": "COLLECTED-ANSWER"]]]],
            ["type": "response.completed", "response": ["status": "completed", "output": []]]
        ] {
            _ = try accumulator.consume(event); _ = display.consume(event, at: 1)
        }
        var message = try accumulator.result().message
        XCTAssertEqual(message.text, "COLLECTED-ANSWER")
        XCTAssertTrue(display.timeline.supported); XCTAssertTrue(display.timeline.segments.isEmpty)
        for timeline in [display.timeline, ResponseTimeline.canonical([("reasoningText", "OTHER-EVIDENCE", nil, nil)], sourceID: "fixture")] {
            message.responseTimeline = timeline
            XCTAssertTrue(message.retainedConversationText.contains("COLLECTED-ANSWER"), "Timeline evidence cannot erase the canonical answer")
        }
    }

    func testSearchIncludesTheSameReasoningAndArgumentsAsCopy() async throws {
        let session = try await fixture(rows: 1)
        await session.copyFixtureContent([textBlock("ordinary"), ["type": "thinking", "thinking": "ONLY-REASONING"],
            ["type": "toolCall", "name": "echo", "arguments": ["needle": "ONLY-ARGUMENT"]]])
        for query in ["ONLY-REASONING", "ONLY-ARGUMENT"] {
            let result = try await session.contentSearch(["query": JSON(query), "retained": true])
            XCTAssertEqual(result["hits"].list.map { $0["id"].text }, ["r0"], query)
        }
    }

    func testFormattingDoesNotOccupyTheSessionActor() async throws {
        let session = try await fixture(), gate = ContentReadGate()
        await session.noteHistoryPageSteps { gate.step($0) }
        let search = Task { try await session.contentSearch(["retained": true]) }
        defer { gate.open(); search.cancel() }
        try await eventually { gate.count > 0 }
        let responsive = expectation(description: "The session processes Stop while copy formatting is held")
        let stop = Task { _ = await session.stop(); responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 0.5)
        gate.open(); await stop.value
        _ = try await search.value
    }

    func testNextResultsAndCopyReuseTheSnapshotFormatting() async throws {
        let session = try await fixture(), count = ContentReadGate(holding: false)
        await session.noteHistoryPageSteps { count.step($0) }
        let first = try await session.contentSearch(["retained": true])
        XCTAssertEqual(first["hits"].list.count, 100)
        XCTAssertEqual(count.count, 130)
        let next = try await session.contentSearch(["retained": true, "start": first["next"]])
        XCTAssertEqual(next["hits"].list.count, 30)
        let page = try await session.contentPage(["revision": next["revision"], "first": 1, "last": 1])
        XCTAssertTrue(page["text"].text?.contains("REASONING-0") == true)
        XCTAssertEqual(first["digest"], next["digest"])
        XCTAssertEqual(count.count, 130, "Next Results and Copy must reuse formatted rows and their digest")
    }
    func testChangedRowsCannotPublishOrReuseAnObsoleteDigest() async throws {
        let session = try await fixture(), gate = ContentReadGate()
        await session.noteHistoryPageSteps { gate.step($0) }
        let old = Task { try await session.contentSearch(["retained": true]) }
        defer { gate.open(); old.cancel() }
        try await eventually { gate.count > 0 }
        await session.copyFixtureContent([textBlock("REPLACED-ROW")])
        gate.open()
        do { _ = try await old.value; XCTFail("Published a stale snapshot after equal-count content changed") }
        catch let error as AgentError { XCTAssertEqual(error.code, "history_changed") }
        let fresh = try await session.contentSearch(["query": "REPLACED-ROW", "retained": true])
        XCTAssertEqual(fresh["hits"].list.map { $0["id"].text }, ["r0"])
        let built = gate.count
        await session.streamedForTesting()
        _ = try await session.contentSearch(["retained": true, "start": 100])
        XCTAssertEqual(gate.count, built, "Unsaved streaming does not change retained rows")
        await session.copyFixtureContent([textBlock("REPLACED-AGAIN")])
        let newer = try await session.contentSearch(["retained": true])
        XCTAssertNotEqual(newer["digest"], fresh["digest"])
    }
    func testCancellationAndCloseNeverPublishAnIncompleteCache() async throws {
        for closing in [false, true] {
            let session = try await fixture(), gate = ContentReadGate()
            await session.noteHistoryPageSteps { gate.step($0) }
            let task = Task { try await session.contentSearch(["retained": true]) }
            defer { gate.open(); task.cancel() }
            try await eventually { gate.count > 0 }
            if closing { await session.close() } else { task.cancel() }
            gate.open()
            do { _ = try await task.value; XCTFail("Published a cancelled or closed snapshot") }
            catch {
                if closing { XCTAssertEqual((error as? AgentError)?.code, "session_closed") }
                else { XCTAssertTrue(error is CancellationError) }
            }
            if !closing {
                await session.noteHistoryPageSteps(nil)
                let fresh = try await session.contentSearch(["retained": true])
                XCTAssertEqual(fresh["total"].int, 130)
            }
        }
    }
    func testConcurrentReadersShareFormattingAndCancellationIsIndependent() async throws {
        let session = try await fixture(), gate = ContentReadGate()
        await session.noteHistoryPageSteps { gate.step($0) }
        let first = Task { try await session.contentSearch(["retained": true]) }
        defer { gate.open(); first.cancel() }
        try await eventually { gate.count > 0 }
        let second = Task { try await session.contentSearch(["retained": true, "start": 100]) }
        defer { second.cancel() }
        try await eventually { await session.historyLoadJoins > 0 }
        first.cancel(); gate.open()
        do { _ = try await first.value; XCTFail("The retired reader published") } catch { XCTAssertTrue(error is CancellationError) }
        let found = try await second.value
        XCTAssertEqual(found["hits"].list.count, 30)
        XCTAssertEqual(gate.count, 130, "One reader's cancellation does not discard another's snapshot")
    }
}

private extension AgentSession {
    func copyFixtureContent(_ blocks: [JSON]) {
        visible[0].content = blocks; history[0].content = blocks
        invalidateDisplay()
    }
}
