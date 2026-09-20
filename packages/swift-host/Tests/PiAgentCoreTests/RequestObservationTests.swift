import XCTest
@testable import PiAgentCore

final class RequestObservationTests: XCTestCase {
    private func observation(_ attempt: String = "a", purpose: String = "turn", session: String = "s") throws -> RequestObservation {
        RequestObservation(sessionID:session,turnID:"t",attemptID:attempt,purpose:purpose,fingerprint:"request-body-hash",profile:try fixtureProfile())
    }
    private func event(_ usage: JSON, type: String = "response.in_progress", sequence: Int = 1) -> JSON {
        ["type":JSON(type),"sequence_number":JSON(sequence),"response":["id":"resp","model":"auto-router","router_model_name":"served-model","usage":usage]]
    }
    func testCumulativeSnapshotsMissingAndFinalFields() throws {
        var observed=try observation()
        XCTAssertTrue(observed.consume(event(.null,type:"response.created"),streaming:true,at:1))
        XCTAssertTrue(observed.fields["input"].isNull)
        XCTAssertEqual(observed.fieldStatus["input"].text,"unreported")
        XCTAssertTrue(observed.consume(event(["input_tokens":1000,"output_tokens":100,"input_tokens_details":["cached_tokens":800],"output_tokens_details":["reasoning_tokens":80]],sequence:2),streaming:true,at:2))
        _=observed.consume(event(["output_tokens":120],sequence:3),streaming:true,at:3)
        _=observed.consume(event(["output_tokens":120],sequence:4),streaming:true,at:4)
        XCTAssertEqual(observed.fields["output"].int,120); XCTAssertEqual(observed.fields["input"].int,1000)
        XCTAssertFalse(observed.consume(event(["input_tokens":99999],sequence:2),streaming:true,at:5))
        _=observed.consume(event(["output_tokens":130],type:"response.completed",sequence:5),streaming:true,at:6)
        XCTAssertEqual(observed.phase,"final"); XCTAssertEqual(observed.fieldPhase["output"].text,"final")
        XCTAssertEqual(observed.fieldPhase["input"].text,"interim"); XCTAssertEqual(observed.fields["input"].int,1000)
        XCTAssertEqual(observed.fields["cacheRead"].int,800); XCTAssertEqual(observed.fields["reasoning"].int,80)
        XCTAssertEqual(observed.effectiveModel,"served-model"); XCTAssertEqual(observed.configuredContextWindow,100000)
        XCTAssertFalse(observed.consume(event(["output_tokens":99999],sequence:6),streaming:true,at:7))
    }
    func testInvalidOptionalUsageAndInterruptionDoNotFabricateFinalCounts() throws {
        var observed=try observation()
        _=observed.consume(event(["input_tokens":20,"output_tokens":10,"input_tokens_details":["cached_tokens":21],"output_tokens_details":["reasoning_tokens":11],"total_tokens":40]),streaming:true,at:1)
        XCTAssertEqual(observed.fieldStatus["cacheRead"].text,"invalid"); XCTAssertEqual(observed.fieldStatus["reasoning"].text,"invalid")
        XCTAssertEqual(observed.fieldStatus["total"].text,"invalid"); XCTAssertEqual(observed.fields["input"].int,20)
        _=observed.consume(event(["input_tokens":-1,"output_tokens":1.5],sequence:2),streaming:true,at:2)
        XCTAssertTrue(observed.fields["input"].isNull); XCTAssertEqual(observed.fieldStatus["output"].text,"invalid")
        observed.interrupt(at:3); XCTAssertEqual(observed.phase,"interrupted")
        XCTAssertNotEqual(observed.fieldPhase["output"].text,"final")
        let invalid=UsageObservation.normalized(["input_tokens":10,"input_tokens_details":["cached_tokens":8,"cache_write_tokens":8]],api:"openai-responses")
        XCTAssertEqual(invalid["status"]["cacheRead"].text,"invalid")
        XCTAssertEqual(invalid["status"]["cacheWrite"].text,"invalid")
        var json=try observation()
        _=json.consume(["status":"completed","usage":["input_tokens":38,"output_tokens":302,"total_tokens":340,"output_tokens_details":["reasoning_tokens":253]]],streaming:false,at:4)
        XCTAssertEqual(json.fields["total"].int,340); XCTAssertEqual(json.fields["reasoning"].int,253)
        XCTAssertEqual(json.phase,"final")
    }
    func testGenerationIsolationMetricsOnlyProjectionAndCaptureIndependentSnapshot() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:DisabledTools(),traces:TraceStore(),autoCompaction:false)
        addTeardownBlock { await session.close() }
        await session.setObservationTestTurn()
        let first=await session.beginObservationGeneration()
        var observed=try observation(); _=observed.consume(event(["input_tokens":100,"output_tokens":10],type:"response.completed"),streaming:true,at:1)
        await session.observe(observed,generation:first)
        let before=await session.snapshot()
        let revision=before["displayRevision"]
        XCTAssertEqual(before["requestObservation"]["usage"]["input"].int,100)
        let next=await session.beginObservationGeneration()
        await session.observe(observed,generation:first)
        for purpose in ["title","compaction"] { await session.observe(try observation("foreign",purpose:purpose),generation:next) }
        await session.observe(try observation("foreign",session:"side"),generation:next)
        let empty=await session.snapshot(["includeMetrics":false,"displayRevision":revision],traceSnapshot:{ XCTFail("Usage-only status must not wait on capture reporting"); return (.null,"off") })
        XCTAssertEqual(empty["requestObservation"]["phase"].text,"preparing"); XCTAssertTrue(empty["requestObservation"]["attemptID"].isNull); XCTAssertEqual(empty["lastRequestObservation"],before["requestObservation"])
        XCTAssertEqual(empty["displayRevision"],revision); XCTAssertTrue(empty["messages"].isNull)
        await session.observe(try observation("b"),generation:next)
        await session.clearRequestObservation()
        await session.observe(observed,generation:next)
        let compacted=await session.snapshot(["includeMetrics":false]); XCTAssertTrue(compacted["requestObservation"].isNull)
    }
}
private extension AgentSession { func setObservationTestTurn() { currentTurnID="t" } }
