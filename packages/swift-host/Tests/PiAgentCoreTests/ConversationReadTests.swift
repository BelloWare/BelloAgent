import CryptoKit
import XCTest
@testable import PiAgentCore

private final class ContentReadGate: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var steps = 0
    let holding: Bool, stage: String
    init(holding: Bool = true, stage: String = "content") { self.holding = holding; self.stage = stage }
    var count: Int { lock.withLock { steps } }
    func step(_ stage: String) {
        guard stage == self.stage else { return }
        let first = lock.withLock { steps += 1; return steps == 1 }
        if first && holding { _ = release.wait(timeout: .now() + 10) }
    }
    func open() { release.signal() }
}

private final class ContentReadBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    var total: Int { lock.withLock { bytes } }
    func add(_ count: Int) { lock.withLock { bytes += count } }
}

private actor ContentStreamClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while true { try await Task.sleep(for: .milliseconds(10)) }
    }
}

final class ConversationReadTests: XCTestCase {
    func testSearchSendsFingerprintsOnlyWhenTheReaderNeedsTheSnapshot() async throws {
        let session = try await fixture(rows: 26_000)
        let first = try await session.contentSearch(["retained": true])
        XCTAssertGreaterThan(try first.data().count, HostProtocol.frameBytes)
        let params: JSON = ["retained": true, "start": first["next"], "knownRevision": first["revision"], "knownIncarnation": first["incarnation"]]
        let next = try await session.contentSearch(params)
        XCTAssertTrue(next["rowHashes"].isNull)
        XCTAssertLessThan(try next.data().count, 65_536)
        let independent = try await session.contentSearch(["retained": true, "start": first["next"]])
        XCTAssertEqual(independent["rowHashes"], first["rowHashes"], "An independent reader needs its own manifest")
        await session.copyFixtureContent([textBlock("Changed outside the selection")], index: 1)
        let changed = try await session.contentSearch(params)
        XCTAssertNotEqual(changed["revision"], first["revision"]); XCTAssertFalse(changed["rowHashes"].isNull)
        let otherRuntime = try await session.contentSearch(["retained": true, "knownRevision": changed["revision"], "knownIncarnation": "retired"])
        XCTAssertFalse(otherRuntime["rowHashes"].isNull)
        print("Search fingerprint bytes: initial=\(try first.data().count) next=\(try next.data().count)")
    }
    func testValidatedCopyPageReturnsWhileUnselectedRowsChange() async throws {
        let session = try await fixture(rows: 2)
        let found = try await session.contentSearch(["retained": true])
        let hashes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(found["rowHashes"].text)))
        let digest = try XCTUnwrap(RetainedConversation.rangeDigest(hashes, first: 1, last: 1))
        let gate = ContentReadGate(stage: "contentPage")
        await session.noteHistoryPageSteps { gate.step($0) }
        let copy = Task { try await session.contentPage(["first": 1, "last": 1, "revision": found["revision"],
            "incarnation": found["incarnation"], "digest": JSON(digest)]) }
        defer { gate.open(); copy.cancel() }
        try await eventually { gate.count > 0 }
        await session.copyFixtureContent([textBlock("Unselected append/update")], index: 1)
        gate.open()
        let page = try await copy.value
        XCTAssertTrue(page["text"].text?.contains("Answer 0") == true)
        XCTAssertEqual(gate.count, 1, "An already validated immutable page must not rebuild and re-page")
    }
    private func fixture(rows: Int = 130, client: (any ModelClient)? = nil) async throws -> AgentSession {
        let root = try temporaryDirectory(), path = root.appendingPathComponent("copy.jsonl"), profile = try fixtureProfile()
        do {
            let journal = try SessionJournal(url: path, id: "copy", cwd: root, binding: profile.binding, create: true)
            for index in 0..<rows {
                try journal.append(["type": "message", "message": ["role": "assistant", "content": [
                    textBlock("Answer \(index)"), ["type": "thinking", "thinking": JSON("REASONING-\(index)")]]]], id: "r\(index)", flush: false)
            }
            try journal.synchronize()
        }
        let session = try AgentSession(id: "copy", profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: client == nil,
            resources: Resources(cwd: root, home: root), client: client ?? ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path)
        addTeardownBlock { await session.close(); try? FileManager.default.removeItem(at: root) }
        return session
    }

    func testStreamingDeltaBetweenSearchAndFirstCopyPageKeepsSelection() async throws {
        try await copyWhileStreaming(betweenPages: false)
    }
    func testStreamingDeltaBetweenCopyPagesKeepsSelection() async throws {
        try await copyWhileStreaming(betweenPages: true)
    }
    private func copyWhileStreaming(betweenPages: Bool) async throws {
        let client = ContentStreamClient(), session = try await fixture(rows: 2, client: client)
        let body = String(repeating: "Retained 🌍 text ", count: 4000), expected = "## assistant\n\n" + body + "\n\n"
        await session.copyFixtureContent([textBlock(body)])
        _ = try await session.submit(Submission(commandID: "stream", turnID: "stream", text: "Continue"), steer: false)
        try await eventually { await client.ready }
        let found = try await session.contentSearch(["retained": true]), generation = await session.contentGeneration
        let row = Data("2:r0\(expected.utf8.count):\(expected)".utf8)
        let digest = sha256(Data(SHA256.hash(data: row)))
        var params: JSON = ["first": 1, "last": 1, "index": 1, "offset": 0, "revision": found["revision"],
            "incarnation": found["incarnation"], "digest": JSON(digest)]
        var copied = ""
        if betweenPages {
            let first = try await session.contentPage(params)
            copied = first["text"].text ?? ""
            params["offset"] = first["next"]["offset"]
            XCTAssertFalse(first["next"].isNull)
        }
        let sequence = await session.sequence
        try await client.emit(.text("A real unretained streaming delta"))
        let advanced = await session.sequence, retained = await session.contentGeneration
        XCTAssertGreaterThan(advanced, sequence); XCTAssertEqual(retained, generation)
        while true {
            let page = try await session.contentPage(params)
            copied += page["text"].text ?? ""
            if page["next"].isNull { break }
            params["offset"] = page["next"]["offset"]
        }
        XCTAssertEqual(copied, expected)
    }
    func testRangeIdentityIgnoresOtherRowsAndRejectsSelectedEdits() async throws {
        let session = try await fixture(rows: 2)
        let found = try await session.contentSearch(["retained": true])
        let page = try await session.contentPage(["first": 1, "last": 1, "revision": found["revision"]])
        let text = try XCTUnwrap(page["text"].text), row = Data("2:r0\(text.utf8.count):\(text)".utf8)
        let digest = sha256(Data(SHA256.hash(data: row)))
        let params: JSON = ["first": 1, "last": 1, "revision": found["revision"], "incarnation": found["incarnation"], "digest": JSON(digest)]
        await session.copyFixtureContent([textBlock("Outside the selection")], index: 1)
        let unchanged = try await session.contentPage(params)
        XCTAssertEqual(unchanged["text"], page["text"])
        await session.copyFixtureContent([textBlock("Changed selected row")])
        do { _ = try await session.contentPage(params); XCTFail("Accepted changed selected text") }
        catch let error as AgentError { XCTAssertEqual(error.code, "history_changed") }
    }
    func testSupersededSnapshotLoadRetriesAnUnchangedSelectedRange() async throws {
        let session = try await fixture(rows: 2)
        let found = try await session.contentSearch(["retained": true])
        let page = try await session.contentPage(["first": 1, "last": 1, "revision": found["revision"]])
        let text = try XCTUnwrap(page["text"].text), row = Data("2:r0\(text.utf8.count):\(text)".utf8)
        let params: JSON = ["first": 1, "last": 1, "revision": found["revision"],
            "incarnation": found["incarnation"], "digest": JSON(sha256(Data(SHA256.hash(data: row))))]
        await session.copyFixtureContent([textBlock("Other row changes")], index: 1)
        let gate = ContentReadGate()
        await session.noteHistoryPageSteps { gate.step($0) }
        let copy = Task { try await session.contentPage(params) }
        defer { gate.open(); copy.cancel() }
        try await eventually { gate.count > 0 }
        await session.copyFixtureContent([textBlock("Other row changes again")], index: 1)
        let search = Task { try await session.contentSearch(["retained": true]) }
        defer { search.cancel() }
        try await eventually { gate.count > 1 }
        gate.open()
        _ = try await search.value
        let result = try await copy.value
        XCTAssertEqual(result["text"], page["text"])
    }
    func testLargeRangeIdentityUsesBoundedDisplayTransfer() throws {
        let messages = (0..<25_000).map { _ in ChatMessage(role: "assistant", content: [textBlock("fixture")]) }
        let content = try RetainedContent.build(key: .init(generation: 0, revision: "fixture"), older: nil,
            visible: messages, url: nil, cancellation: BlockingWorkCancellation(), step: nil)
        let payload: JSON = ["rowHashes": JSON(content.encodedRowHashes), "revision": JSON(content.revision)]
        XCTAssertGreaterThan(try payload.data().count, HostProtocol.frameBytes)
        var transfers = DisplayResultTransfers()
        let output = NativeHostService.boundedReply(epoch: "fixture", "copy", .success(payload), transfer: { try transfers.insert($0) })
        guard case .encoded(let frame) = output else { return XCTFail("Expected a bounded encoded reply") }
        XCTAssertLessThanOrEqual(frame.count, HostProtocol.frameBytes)
        let result = try JSON.parse(frame)["result"], id = try XCTUnwrap(result["id"].text)
        var offset = 0, bytes = Data()
        while true {
            let part = try transfers.read(id, offset: offset)
            XCTAssertLessThan(try part.data().count, HostProtocol.frameBytes)
            bytes.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(part["data"].text))))
            if part["next"].isNull { break }
            offset = try XCTUnwrap(part["next"].int)
        }
        XCTAssertEqual(try JSON.parse(bytes), payload)
        XCTAssertEqual(Data(base64Encoded: content.encodedRowHashes)?.count, messages.count * 32)
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
    func testSixteenMiBRowExportReadsItsBytesOnce() throws {
        let message = ChatMessage(role: "assistant", content: [textBlock(String(repeating: "x", count: 16 * 1_048_576))])
        let expected = message.retainedConversationText, reads = ContentReadBytes(), cancellation = BlockingWorkCancellation()
        let content = try RetainedContent.build(key: .init(generation: 0, revision: "fixture"), older: nil,
            visible: [message], url: nil, cancellation: cancellation, step: nil, readObserver: { reads.add($0) })
        let began = Date()
        var offset = 0, pages = 0, exported = 0, hash = SHA256()
        while true {
            let page = try autoreleasepool { try content.page(first: 1, last: 1, index: 1, offset: offset, cancellation: cancellation) }
            let bytes = Data((page["text"].text ?? "").utf8)
            hash.update(data: bytes); exported += bytes.count; pages += 1
            // Stop a broken implementation early instead of reading 16 GiB.
            guard reads.total <= expected.utf8.count * 2 else {
                return XCTFail("Paged export reread \(reads.total) bytes after \(pages) pages of one \(expected.utf8.count)-byte row")
            }
            if page["next"].isNull { break }
            offset = try XCTUnwrap(page["next"]["offset"].int)
        }
        XCTAssertEqual(exported, expected.utf8.count)
        XCTAssertEqual(hash.finalize(), SHA256.hash(data: Data(expected.utf8)))
        XCTAssertEqual(reads.total, expected.utf8.count, "The same decoded row serves every bounded page")
        XCTAssertGreaterThan(pages, 1000)
        print("16 MiB export: \(pages) pages, \(exported) exported bytes, \(reads.total) read bytes, \(Date().timeIntervalSince(began)) s")
    }
    func testCopyCacheEvictsRowsAndKeepsUTF16Boundaries() throws {
        let prefix = String(repeating: "a", count: 16_383 - "## assistant\n\n".utf16.count)
        let messages = [ChatMessage(role: "assistant", content: [textBlock(prefix + "🌍e\u{301} tail")]),
                        ChatMessage(role: "toolResult", content: [textBlock(String(repeating: "工具é", count: 10_000))])]
        let expected = messages.map(\.retainedConversationText), reads = ContentReadBytes(), cancellation = BlockingWorkCancellation()
        let content = try RetainedContent.build(key: .init(generation: 0, revision: "fixture"), older: nil,
            visible: messages, url: nil, cancellation: cancellation, step: nil, readObserver: { reads.add($0) })
        let first = try content.page(first: 1, last: 1, index: 1, offset: 0, cancellation: cancellation)
        XCTAssertEqual(first["next"]["offset"].int, 16_383)
        XCTAssertThrowsError(try content.page(first: 1, last: 1, index: 1, offset: 16_384, cancellation: cancellation)) {
            XCTAssertEqual(($0 as? AgentError)?.code, "invalid_range")
        }
        for row in [1, 1, 2, 1] {
            var offset = 0, copied = ""
            while true {
                let page = try content.page(first: row, last: row, index: row, offset: offset, cancellation: cancellation)
                copied += page["text"].text ?? ""
                if page["next"].isNull { break }
                offset = try XCTUnwrap(page["next"]["offset"].int)
            }
            XCTAssertEqual(copied, expected[row - 1])
        }
        XCTAssertEqual(reads.total, expected[0].utf8.count * 2 + expected[1].utf8.count, "Only one decoded row is retained")
        cancellation.cancel()
        XCTAssertThrowsError(try content.page(first: 1, last: 1, index: 1, offset: 0, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
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
    func copyFixtureContent(_ blocks: [JSON], index: Int = 0) {
        visible[index].content = blocks; history[index].content = blocks
        invalidateDisplay()
    }
}
