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

    /// A request's context links (every message id it carries) are sent to
    /// the recorder after the request is dispatched, not awaited before it:
    /// the recorder acknowledges each packet, and a long chat's context takes
    /// several. A request that never went out still links its context.
    func testContextLinksDoNotHoldUpDispatch() async throws {
        let recorder = SlowRecorder(delay: 20_000_000), traces = TraceStore(sink: { await recorder.accept($0) })
        let ids = (0..<2000).map { "message-\($0)" }
        let start = nowMS()
        let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:], messageIDs: ids)
        let untilDispatch = nowMS() - start
        let before = await recorder.types
        await traces.dispatched(id, at: nowMS())
        let linked = await recorder.packets.filter { $0["type"].text == "links" }.flatMap { $0["messageIds"].list }.count
        print("PERF capture-before-dispatch contextIds=2000 packetsBeforeDispatch=\(before.count) msBeforeDispatch=\(Int(untilDispatch))")
        XCTAssertEqual(before, ["begin"], "only the attempt itself is recorded before the request goes out")
        XCTAssertLessThan(untilDispatch, 80, "four link packets (~20 ms each) no longer precede dispatch")
        XCTAssertEqual(linked, 2000, "every context id is still linked")
        let failed = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data("{}".utf8), headers: [:], messageIDs: ["a", "b"])
        await traces.finish(failed, outcome: "failed", modelOutcome: "interrupted")
        let packets = await recorder.packets.filter { $0["attemptId"].text == failed || $0["metadata"]["attemptId"].text == failed }.compactMap { $0["type"].text }
        XCTAssertEqual(packets, ["begin", "links", "finish"], "an attempt that never dispatched links its context before it finishes")
    }
}

private actor SlowRecorder {
    let delay: UInt64
    var packets: [JSON] = []
    init(delay: UInt64) { self.delay = delay }
    var types: [String] { packets.compactMap { $0["type"].text } }
    func accept(_ packet: JSON) async -> Bool { packets.append(packet); try? await Task.sleep(nanoseconds: delay); return true }
}
