import XCTest
@testable import PiAgentCore

/// The per-attempt record: independent model and HTTP boundaries, timings
/// that stay null until they are observed, masked headers and hashed bodies.
final class CaptureTraceTests: XCTestCase {
    func testTimingNullsAndIndependentModelHTTPBoundaries() async throws {
        let traces=TraceStore()
        let id=await traces.begin(session:"timing",turn:"t",profile:try fixtureProfile(),purpose:"turn",body:Data(),headers:[:])
        let initial=await traces.latest("timing")
        XCTAssertTrue(initial["timings"]["dispatch"].isNull); XCTAssertTrue(initial["timings"]["lastContent"].isNull)
        await traces.dispatched(id,at:100)
        await traces.content(id,text:false,at:150); await traces.content(id,text:true,at:175)
        await traces.terminal(id,at:200)
        await traces.transport(id,observation:["dispatch":100,"firstHTTPByte":110,"firstBodyByte":120,"httpEnd":300,"transportOutcome":"eof"])
        await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        let m=await traces.latest("timing")
        XCTAssertEqual(m["metrics"]["observedTTFTms"].double,50)
        XCTAssertEqual(m["metrics"]["firstTextMs"].double,75)
        XCTAssertEqual(m["metrics"]["streamDurationMs"].double,25, "the stream is first output → last output, not → the terminal")
        XCTAssertEqual(m["timings"]["lastContent"].double,175)
        XCTAssertEqual(m["metrics"]["httpDurationMs"].double,200)
        XCTAssertEqual(m["timings"]["modelComplete"].double,200)
        XCTAssertTrue(m["metrics"]["decodeTokensPerSecond"].isNull, "no reported usage, no rate")
    }
    func testCaptureBytesHashesHeadersAndClear() async throws {
        let traces=TraceStore(),request=Data("{\"x\":1}".utf8),response=Data("data: {}\r\n\r\n".utf8)
        let id=await traces.begin(session:"s",turn:"t",profile:try fixtureProfile(),purpose:"turn",body:request,headers:["Authorization":"secret","Content-Type":"application/json"])
        await traces.append(id,data:response);await traces.finish(id,outcome:"cancelled",modelOutcome:"interrupted")
        let metadata=try await traces.command("debug.attempt",session:"s",params:["attemptId":JSON(id)])
        XCTAssertEqual(metadata["requestHash"]["sha256"].text,sha256(request));XCTAssertEqual(metadata["response"]["state"].text,"partial")
        XCTAssertEqual(metadata["requestHeaders"]["authorization"].text,"********")
        let body=try await traces.command("debug.body",session:"s",params:["attemptId":JSON(id),"body":"response"])
        XCTAssertEqual(Data(base64Encoded:body["bytes"].text!),response)
        _ = try await traces.command("debug.clear",session:"s",params:[:])
        let empty=try await traces.command("debug.list",session:"s",params:[:]);XCTAssertEqual(empty["total"].int,0)
    }

    /// A session snapshot's `latestAttempt` (4 Hz while busy, every idle
    /// poll) leaves out the context and output id lists, which nothing reads
    /// from it; the inspector's own reads of the attempt still carry them.
    func testLatestAttemptLeavesOutMessageIDs() async throws {
        let traces = TraceStore(), ids = (0..<1000).map { "message-\($0)-0123456789abcdef" }
        let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:], messageIDs: ids)
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let latest = await traces.latest("s")
        XCTAssertEqual(latest["attemptId"].text, id)
        XCTAssertNil(latest.map["messageIds"]); XCTAssertNil(latest.map["outputMessageIds"])
        let attempt = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(id)])
        XCTAssertEqual(attempt["messageIds"].list.count, 1000, "the inspector's attempt read still links its context")
        let listed = try await traces.command("debug.list", session: "s", params: [:])
        XCTAssertEqual(listed["attempts"].list.first?["messageIds"].list.count, 1000)
        let slim = try latest.data().count, full = try attempt.removing(["boundary", "requestHash", "responseHash"]).data().count
        print("PERF latestAttempt contextIds=1000 bytesBefore=\(full) bytesAfter=\(slim)")
        XCTAssertLessThan(slim, full - 20_000)
    }

    /// A request goes out without waiting for the app's log: its record and
    /// its context links (every message id it carries, one packet per 512)
    /// are queued, and the request is dispatched while the log still holds
    /// the first packet. A request that never went out still links its context.
    func testCaptureNeverHoldsUpDispatch() async throws {
        let recorder = HeldRecorder(), traces = TraceStore(sink: { await recorder.accept($0) })
        let ids = (0..<2000).map { "message-\($0)" }
        let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:], messageIDs: ids)
        await traces.dispatched(id, at: nowMS())
        try await eventually { await recorder.types == ["begin"] }
        await recorder.open()
        await traces.delivered()
        let types = await recorder.types
        XCTAssertEqual(types, ["begin", "metadata", "links", "links", "links", "links"])
        let linked = await recorder.packets.filter { $0["type"].text == "links" }.flatMap { $0["messageIds"].list }.count
        XCTAssertEqual(linked, 2000, "every context id is still linked")
        let failed = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:], messageIDs: ["a", "b"])
        await traces.finish(failed, outcome: "failed", modelOutcome: "interrupted")
        await traces.delivered()
        let packets = await recorder.packets.filter { $0["attemptId"].text == failed || $0["metadata"]["attemptId"].text == failed }.compactMap { $0["type"].text }
        XCTAssertEqual(packets, ["begin", "links", "finish"], "an attempt that never dispatched links its context before it finishes")
    }
}

extension CaptureTraceTests {
    /// Every server-sent event is indexed: a long reply's 5,000th event is
    /// kept like its first, in the helper and in the app's log.
    func testEveryEventIsIndexed() async throws {
        for mode in ["memory", "persist"] {
            let recorder = HeldRecorder(); await recorder.open()
            let traces = TraceStore(sink: { await recorder.accept($0) })
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:])
            for index in 0..<5_000 { await traces.event(id, SSEEvent(event: "delta", data: "", start: index * 10, end: index * 10 + 10)) }
            let page = try await traces.command("debug.raw-events", session: "s", params: ["attemptId": JSON(id), "offset": 4_990])
            XCTAssertEqual(page["total"].int, 5_000); XCTAssertEqual(page["events"].list.count, 10)
            XCTAssertEqual(page["events"].list.last?["start"].int, 49_990)
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let attempt = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(id)])
            XCTAssertEqual(attempt["rawEventIndexCount"].int, 5_000); XCTAssertEqual(attempt["rawEventsOmitted"].int, 0)
            let pages = await recorder.packets.filter { $0["type"].text == "events" }
            if mode == "persist" {
                XCTAssertEqual(pages.map { $0["offset"].int ?? -1 }, Array(stride(from: 0, to: 5_000, by: 128)))
                XCTAssertEqual(pages.flatMap { $0["events"].list }.count, 5_000)
            } else { XCTAssertTrue(pages.isEmpty, "a session-memory chat keeps its events in the helper") }
        }
    }

    /// A persisted chat's request stays in the helper until the app has saved
    /// all of it; one whose pages the log refused keeps its only complete copy
    /// here. A saved request goes once a later one of the chat is saved, and
    /// a session-memory chat keeps every request.
    func testHelperLetsGoOnlyOfWhatTheLogSaved() async throws {
        let profile = try fixtureProfile(), response = Data("data: {}\n\n".utf8)
        for mode in ["persist", "memory"] {
            let recorder = SelectiveRecorder(), traces = TraceStore(sink: { await recorder.accept($0) })
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            var ids: [String] = []
            for index in 0..<3 {
                let id = await traces.begin(session: "s", turn: "t\(index)", profile: profile, purpose: "turn", body: Data("{\"n\":\(index)}".utf8), headers: [:])
                if index == 0 { await recorder.refuse(id) }
                await traces.append(id, data: response)
                await traces.transport(id, observation: ["transportOutcome": "eof"])
                await traces.finish(id, outcome: "completed", modelOutcome: "completed")
                await traces.delivered()
                ids.append(id)
            }
            let listed = try await traces.command("debug.list", session: "s", params: [:])["attempts"].list.compactMap { $0["attemptId"].text }
            if mode == "persist" {
                XCTAssertEqual(Set(listed), [ids[0], ids[2]])
                let kept = try await traces.command("debug.body", session: "s", params: ["attemptId": JSON(ids[0]), "body": "response"])
                XCTAssertEqual(Data(base64Encoded: kept["bytes"].text ?? ""), response, "the helper's copy is the only complete one")
                let attempt = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(ids[0])])
                XCTAssertFalse(attempt["persistenceError"].isNull); XCTAssertEqual(attempt["response"]["savedToLog"].flag, false)
                let latest = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(ids[2])])
                XCTAssertEqual(latest["response"]["savedToLog"].flag, true)
            } else {
                XCTAssertEqual(Set(listed), Set(ids))
            }
        }
    }
}

extension CaptureTraceTests {
    /// While the app is busy saving, a stream's small chunks join the page
    /// still waiting, up to 32 KiB, instead of costing one acknowledgment
    /// each; offsets and bytes are unchanged.
    func testSmallChunksJoinTheWaitingPageWhileTheLogIsBusy() async throws {
        let recorder = HeldRecorder(), traces = TraceStore(sink: { await recorder.accept($0) })
        _ = try await traces.command("debug.mode", session: "s", params: ["mode": "persist"])
        let request = Data("{\"input\":\"question\"}".utf8)
        let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: request, headers: [:])
        try await eventually { await recorder.types == ["begin"] }
        var expected = Data()
        for index in 0..<2_000 {
            let chunk = Data("data: {\"delta\":\"\(index)\"}\n\n".utf8)
            expected.append(chunk); await traces.append(id, data: chunk)
        }
        await traces.transport(id, observation: ["transportOutcome": "eof"])
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        await recorder.open()
        await traces.delivered()
        let pages = await recorder.packets.filter { $0["type"].text == "bytes" && $0["body"].text == "response" }
        var durable = Data()
        for page in pages {
            XCTAssertEqual(page["offset"].int, durable.count)
            let bytes = try XCTUnwrap(Data(base64Encoded: page["bytes"].text ?? "")); XCTAssertLessThanOrEqual(bytes.count, 32_768)
            durable.append(bytes)
        }
        XCTAssertEqual(durable, expected)
        XCTAssertEqual(pages.count, (expected.count + 32_767) / 32_768, "\(expected.count) bytes in 2,000 chunks travel as full pages")
        let requestPages = await recorder.packets.filter { $0["type"].text == "bytes" && $0["body"].text == "request" }
        XCTAssertEqual(requestPages.count, 1); XCTAssertEqual(Data(base64Encoded: requestPages.first?["bytes"].text ?? ""), request)
    }

    /// Twenty streams interleave in one helper's queue: each request's chunks
    /// still join its own waiting page. A packet of that request queued after
    /// the page (here the credential-masking notice) closes it, so nothing of a
    /// request is ever reordered.
    func testInterleavedStreamsJoinTheirOwnPagesWithoutReordering() async throws {
        let recorder = HeldRecorder(), traces = TraceStore(sink: { await recorder.accept($0) })
        let profile = try fixtureProfile(), key = "private-fixture-key"
        var ids: [String] = []
        for index in 0..<20 {
            _ = try await traces.command("debug.mode", session: "s\(index)", params: ["mode": "persist"])
            ids.append(await traces.begin(session: "s\(index)", turn: "t", profile: profile, purpose: "turn", body: Data("{}".utf8), headers: ["Authorization": "Bearer " + key]))
        }
        try await eventually { await recorder.types == ["begin"] }
        var expected = Array(repeating: Data(), count: 20)
        for round in 0..<200 {
            for (index, id) in ids.enumerated() {
                // Session zero echoes the credential halfway: its response is masked from there on.
                let text = index == 0 && round == 100 ? "data: \(key)\n\n" : "data: {\"delta\":\"\(round)\"}\n\n"
                let chunk = Data(text.utf8)
                expected[index].append(index == 0 && round == 100 ? Data(("data: " + String(repeating: "*", count: key.utf8.count) + "\n\n").utf8) : chunk)
                await traces.append(id, data: chunk)
            }
        }
        for id in ids {
            await traces.transport(id, observation: ["transportOutcome": "eof"])
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        }
        await recorder.open()
        await traces.delivered()
        let packets = await recorder.packets
        for (index, id) in ids.enumerated() {
            let own = packets.enumerated().filter { $0.element["attemptId"].text == id || $0.element["metadata"]["attemptId"].text == id }
            let pages = own.filter { $0.element["type"].text == "bytes" && $0.element["body"].text == "response" }
            var durable = Data()
            for page in pages {
                XCTAssertEqual(page.element["offset"].int, durable.count)
                durable.append(try XCTUnwrap(Data(base64Encoded: page.element["bytes"].text ?? "")))
            }
            XCTAssertEqual(durable, expected[index], "session \(index)")
            XCTAssertLessThanOrEqual(pages.count, 3, "session \(index): \(pages.count) pages for 200 chunks")
            if index == 0 {
                let notice = try XCTUnwrap(own.first { $0.element["type"].text == "metadata" && $0.element["metadata"]["response"]["byteExact"].flag == false })
                let masked = try XCTUnwrap(pages.first { Data(base64Encoded: $0.element["bytes"].text ?? "")?.contains(42) ?? false })
                XCTAssertLessThan(notice.offset, masked.offset, "The masking notice still precedes the masked bytes")
            }
        }
    }
}

/// Refuses the body pages of the requests it is told to, like a full disk.
private actor SelectiveRecorder {
    var packets: [JSON] = [], refused: Set<String> = []
    func refuse(_ id: String) { refused.insert(id) }
    func accept(_ packet: JSON) -> Bool {
        packets.append(packet)
        return !(packet["type"].text == "bytes" && refused.contains(packet["attemptId"].text ?? ""))
    }
}

/// Holds every packet until opened, like an app busy saving a large one.
private actor HeldRecorder {
    var packets: [JSON] = []
    private var held: [CheckedContinuation<Void, Never>] = [], opened = false
    var types: [String] { packets.compactMap { $0["type"].text } }
    func accept(_ packet: JSON) async -> Bool {
        packets.append(packet)
        if !opened { await withCheckedContinuation { held.append($0) } }
        return true
    }
    func open() { opened = true; let waiting = held; held.removeAll(); for waiter in waiting { waiter.resume() } }
}
