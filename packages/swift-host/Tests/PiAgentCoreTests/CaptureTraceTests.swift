import XCTest
@testable import PiAgentCore

/// The per-attempt record: independent model and HTTP boundaries, timings
/// that stay null until they are observed, masked headers and hashed bodies.
final class CaptureTraceTests: XCTestCase {
    func testTimingNullsAndIndependentModelHTTPBoundaries() async throws {
        let traces=TraceStore()
        let id=await traces.begin(session:"timing",turn:"t",profile:try fixtureProfile(),purpose:"turn",body:Data(),headers:[:])
        let initial=await traces.latest("timing")
        XCTAssertTrue(initial["timings"]["dispatch"].isNull)
        await traces.dispatched(id,at:100)
        await traces.content(id,text:false,at:150); await traces.content(id,text:true,at:175)
        await traces.terminal(id,at:200)
        await traces.transport(id,observation:["dispatch":100,"firstHTTPByte":110,"firstBodyByte":120,"httpEnd":300,"transportOutcome":"eof"])
        await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        let m=await traces.latest("timing")
        XCTAssertEqual(m["metrics"]["observedTTFTms"].double,50)
        XCTAssertEqual(m["metrics"]["firstTextMs"].double,75)
        XCTAssertEqual(m["metrics"]["streamDurationMs"].double,50)
        XCTAssertEqual(m["metrics"]["httpDurationMs"].double,200)
        XCTAssertEqual(m["timings"]["modelComplete"].double,200)
        XCTAssertTrue(m["metrics"]["outputTokensPerSecond"].isNull)
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
}
