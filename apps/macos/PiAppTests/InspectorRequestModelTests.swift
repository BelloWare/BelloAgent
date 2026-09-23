import XCTest
@testable import PiApp

/// The request page's reads: only the tab on screen reads, only while the
/// window is visible, a running response is read once while its metadata
/// grows, and a slow read of another request never lands on this one.
final class InspectorRequestModelTests: XCTestCase {
    /// A Responses stream of `words` output deltas, with or without its end.
    static func stream(_ words: Int, finished: Bool = false) -> Data {
        var events = [
            ("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp","status":"in_progress","model":"gpt-5.4","output":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg","type":"message","role":"assistant","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}"#)
        ]
        for index in 0..<words {
            events.append(("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":\#(3 + index),"item_id":"msg","output_index":0,"content_index":0,"delta":"word\#(index) "}"#))
        }
        if finished {
            events.append(("response.completed", #"{"type":"response.completed","sequence_number":\#(3 + words),"response":{"id":"resp","status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}"#))
        }
        return Data(events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }
    static func requestBody(_ items: Int) -> Data {
        let input = (0..<items).map { ["type": "message", "role": "user", "content": [["type": "input_text", "text": "message \($0)"]]] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["model": "gpt-5.4", "input": input])
    }
    @MainActor static func source(_ bytes: @escaping () -> Data, state: @escaping () -> String = { "complete" }, reads: @escaping () -> Void = {}) -> CapturedBodySource {
        CapturedBodySource(metadata: {
            let data = bytes()
            return CapturedBodyMetadata(body: ["state": .string(state()), "retainedBytes": .number(Double(data.count)), "observedBytes": .number(Double(data.count))], hash: nil)
        }, page: { offset in
            reads()
            let data = bytes()
            return (data.subdata(in: min(offset, data.count)..<min(data.count, offset + 32_768)), data.count)
        })
    }
    @MainActor private func model(_ root: URL) -> InspectorRequestModel {
        InspectorRequestModel(archive: PayloadArchive(root: root), sessionID: "session", workspace: nil, cache: InspectorDocumentCache())
    }
    private func row(_ id: String, outcome: String = "completed") -> InspectorRequestRow {
        InspectorRequestRow(id: id, wall: 10, turn: "t", purpose: "turn", api: "openai-responses", alias: "ui-fixture", model: "gpt-5.4", outcome: outcome)
    }
    @MainActor private func wait(_ what: String, seconds: Double = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for " + what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Ported from the Turn Info popup: a streaming response grows between
    /// the metadata polls. Growth is offered with "Load latest", never read on
    /// every poll, and the finished request is not polled any more.
    @MainActor func testAResponseStillStreamingIsReadOnceWhileItsMetadataReportsGrowth() async throws {
        let root = scratchRoot("inspector-request"); defer { try? FileManager.default.removeItem(at: root) }
        let request = model(root)
        var words = 6, finished = false, metadataReads = 0, bodyPages = 0
        request.metadataPollInterval = .milliseconds(40)
        request.metadataOverride = { _ in
            metadataReads += 1
            if !finished { words += 3 }
            let bytes = Double(Self.stream(words, finished: finished).count)
            return ["outcome": .string(finished ? "completed" : "running"),
                    "response": .object(["state": .string(finished ? "complete" : "partial"), "retainedBytes": .number(bytes), "observedBytes": .number(bytes)])]
        }
        request.sourceOverride = { _, kind in
            kind == "response" ? Self.source({ Self.stream(words, finished: finished) }, state: { finished ? "complete" : "partial" }, reads: { bodyPages += 1 }) : nil
        }
        request.tab = .response
        request.open(row("r", outcome: "running"), predecessor: nil, previousLabel: nil)
        request.setActive(true)
        defer { request.setActive(false) }
        try await wait("the first response document") { request.response.value != nil }
        XCTAssertEqual(request.bodyReads, 1)
        XCTAssertTrue(request.response.value?.partial == true, "A stream without its end is shown as what arrived")
        let firstBytes = request.responseBytes
        let polled = metadataReads
        try await wait("several metadata polls") { metadataReads >= polled + 4 }
        XCTAssertEqual(request.bodyReads, 1, "Growth a poll reports is offered, not read")
        XCTAssertGreaterThan(request.growingBytes ?? 0, firstBytes, "The page knows the response grew")
        request.loadLatest()
        try await wait("the latest bytes") { request.bodyReads == 2 && request.response.value != nil }
        XCTAssertGreaterThan(request.responseBytes, firstBytes)

        finished = true
        try await wait("the finished record") { request.growingBytes == nil }
        let settled = metadataReads
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(metadataReads, settled, "A finished request's metadata is not polled")
        XCTAssertGreaterThan(bodyPages, 0)
    }

    /// Only the tab on screen reads its body, and a hidden page reads nothing.
    @MainActor func testATabThatIsNotOnScreenReadsNothing() async throws {
        let root = scratchRoot("inspector-tabs"); defer { try? FileManager.default.removeItem(at: root) }
        let request = model(root)
        var requestPages = 0, responsePages = 0
        request.metadataOverride = { _ in ["outcome": .string("completed")] }
        request.sourceOverride = { _, kind in
            kind == "request" ? Self.source({ Self.requestBody(3) }, reads: { requestPages += 1 })
                : Self.source({ Self.stream(2, finished: true) }, reads: { responsePages += 1 })
        }
        request.open(row("a"), predecessor: nil, previousLabel: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requestPages + responsePages, 0, "A request page that is not on screen reads nothing")
        request.setActive(true)
        try await wait("the conversation") { request.conversation.value != nil && request.delta != nil }
        XCTAssertEqual(request.conversation.value?.items.count, 3)
        XCTAssertEqual(request.delta?.first, true, "The session's first request is all new")
        XCTAssertGreaterThan(requestPages, 0); XCTAssertEqual(responsePages, 0, "The response tab is not on screen")
        request.tab = .response
        try await wait("the response") { request.response.value != nil }
        XCTAssertGreaterThan(responsePages, 0)
        let pages = requestPages
        request.tab = .conversation
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requestPages, pages, "A document already read is kept, not read again")
        request.setActive(false)
        let hidden = (requestPages, responsePages)
        request.tab = .raw; request.tab = .response; request.loadLatest()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(requestPages, hidden.0); XCTAssertEqual(responsePages, hidden.1, "A hidden window reads nothing")
    }

    /// Ported from the Turn Info popup: a slow read of the request the reader
    /// left must not replace the one they opened since.
    @MainActor func testASlowReadOfAnotherRequestNeverLandsOnTheOneOnScreen() async throws {
        let root = scratchRoot("inspector-superseded"); defer { try? FileManager.default.removeItem(at: root) }
        let request = model(root)
        var release: CheckedContinuation<Void, Never>?
        request.metadataOverride = { _ in ["outcome": .string("completed")] }
        request.sourceOverride = { row, kind in
            guard kind == "request" else { return nil }
            if row.id == "slow" {
                return CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(Self.requestBody(9).count))], hash: nil) },
                                          page: { offset in
                    await withCheckedContinuation { release = $0 }
                    let data = Self.requestBody(9)
                    return (data.subdata(in: offset..<min(data.count, offset + 32_768)), data.count)
                })
            }
            return Self.source({ Self.requestBody(2) })
        }
        request.setActive(true)
        request.open(row("slow"), predecessor: nil, previousLabel: nil)
        try await wait("the slow read to start") { release != nil }
        request.open(row("fast"), predecessor: nil, previousLabel: nil)
        try await wait("the fast request") { request.conversation.value != nil }
        XCTAssertEqual(request.conversation.value?.items.count, 2)
        release?.resume()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(request.row?.id, "fast")
        XCTAssertEqual(request.conversation.value?.items.count, 2, "The slow request's document never replaced the fast one's")
        request.setActive(false)
    }

    /// The delta compares with the request before, parsed once: its digests are kept.
    @MainActor func testTheRequestBeforeIsParsedOnceForItsDigests() async throws {
        let root = scratchRoot("inspector-delta"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = InspectorDocumentCache()
        let request = InspectorRequestModel(archive: PayloadArchive(root: root), sessionID: "session", workspace: nil, cache: cache)
        var previousPages = 0
        request.metadataOverride = { _ in ["outcome": .string("completed")] }
        request.sourceOverride = { row, _ in
            row.id == "first" ? Self.source({ Self.requestBody(2) }, reads: { previousPages += 1 }) : Self.source({ Self.requestBody(5) })
        }
        request.setActive(true)
        request.open(row("second"), predecessor: row("first"), previousLabel: "request 1")
        try await wait("the delta") { request.delta != nil }
        XCTAssertEqual(request.delta?.shared, 2); XCTAssertEqual(request.delta?.added, 3)
        XCTAssertEqual(request.delta?.banner(previous: request.previousLabel, cachedShare: nil).hasPrefix("New since request 1: +3 items"), true)
        let pages = previousPages
        request.open(row("third"), predecessor: row("first"), previousLabel: "request 1")
        try await wait("the second delta") { request.delta != nil }
        XCTAssertEqual(previousPages, pages, "The earlier request's digests were kept, not read again")
        request.setActive(false)
    }
}
