import XCTest
@testable import PiApp

final class ContextScopeTests: XCTestCase {
    private func request(_ generation: Double = 1, attempt: String = "a", phase: String = "awaiting", input: Double? = nil) -> [String: WireValue] {
        ["sessionID":.string("s"),"runtimeEpoch":.string("epoch"),"generation":.number(generation),"replayRevision":.number(1),
         "attemptID":.string(attempt),"requestFingerprint":.string("body-"+attempt),"purpose":.string("turn"),"phase":.string(phase),
         "requestedModel":.string("original-model"),"contextWindow":.number(100000),
         "estimate":.object(["tokens":.number(42000),"estimated":.bool(true),"method":.string("heuristic")]),
         "usage":.object(["input":input.map(WireValue.number) ?? .null,"output":.number(1000),"cacheRead":.number(500),"reasoning":.number(900)]),
         "status":.object(["input":.string(input == nil ? "unreported":"reported")])]
    }
    private func state(_ phase: String = "current-request", generation: Double = 1, replay: Double = 1, current: [String: WireValue]? = nil, last: [String: WireValue]? = nil) -> [String: WireValue] {
        ["version":.number(1),"sessionID":.string("s"),"runtimeEpoch":.string("epoch"),"replayRevision":.number(replay),
         "generation":.number(generation),"phase":.string(phase),"turnID":.string("turn"),"reason":.string("input-changed"),
         "currentRequest":current.map(WireValue.object) ?? .null,"lastRequest":last.map(WireValue.object) ?? .null]
    }
    @MainActor private func apply(_ state: [String: WireValue], to view: SessionDisplay, baseline: Bool = false) {
        view.observeContext(["contextStateRevision":.string(UUID().uuidString),"contextState":.object(state)],baseline:baseline)
    }
    @MainActor private func resolve(_ view: SessionDisplay, preview: [String: WireValue]? = nil) -> ContextPresentation {
        ContextPresentation.resolve(state:view.footer.contextState,observation:view.footer.requestObservation,preview:preview,fallback:view.context,
            preparing:view.footer.preparingContext,submissionPending:view.footer.pendingContextSubmission != nil,busy:view.busy,runStatus:view.runStatus)
    }
    @MainActor func testNewSubmissionCannotPromoteOldRequestBeforeHelperReplyAndRejectionReconciles() {
        let view=SessionDisplay(id:"s"), old=request(phase:"final",input:12000)
        apply(state("next-input",last:old),to:view)
        view.beginContextSubmission("new-turn"); view.state="running"
        XCTAssertNil(resolve(view)["tokens"]?.number)
        XCTAssertEqual(resolve(view).reason,"new-request-preparing")
        apply(state("preparing",current:nil,last:old),to:view)
        XCTAssertNil(resolve(view)["tokens"]?.number)
        view.rejectContextSubmission("new-turn"); view.state="idle"
        XCTAssertNil(view.footer.pendingContextSubmission)
        XCTAssertEqual(view.footer.lastRequestObservation,old)
    }
    @MainActor func testLowerReportAndZeroReplaceEstimateWithoutDoubleCountingOrCapacitySwitch() {
        let view=SessionDisplay(id:"s"); view.state="running"
        apply(state(current:request()),to:view)
        XCTAssertEqual(resolve(view)["tokens"]?.number,42000)
        for input in [40000.0,0.0] {
            apply(state(current:request(phase:"interim",input:input)),to:view)
            let shown=resolve(view)
            XCTAssertEqual(shown["tokens"]?.number,input)
            XCTAssertEqual(shown.scope,"current-request")
            XCTAssertEqual(ContextMeterPresentation(context:shown.context,capacity:200000).fraction,input/100000)
            XCTAssertEqual(shown.reason,"usage-observed")
        }
    }
    @MainActor func testToolsRetriesLateGenerationsAndCrossPaneIdentity() {
        let view=SessionDisplay(id:"s"); view.state="running"
        let old=request(phase:"final",input:12000)
        apply(state("last-request",replay:2,last:old),to:view)
        XCTAssertEqual(resolve(view).scope,"last-request")
        XCTAssertEqual(resolve(view)["tokens"]?.number,12000)
        let fresh=state("preparing",generation:2,replay:2,current:request(2,attempt:"b",phase:"preparing"),last:old)
        apply(fresh,to:view)
        XCTAssertEqual(resolve(view)["tokens"]?.number,42000)
        apply(state(generation:1,replay:2,current:old),to:view)
        XCTAssertEqual(view.footer.contextState,fresh,"Late generation cannot replace retry/current attempt")
        var foreign=fresh; foreign["sessionID"] = .string("side")
        apply(foreign,to:view); XCTAssertEqual(view.footer.contextState,fresh)
        foreign=fresh; var other=request(2); other["sessionID"] = .string("side"); foreign["currentRequest"] = .object(other)
        apply(foreign,to:view); XCTAssertNil(resolve(view)["tokens"]?.number)
    }
    @MainActor func testChangedDraftPendingWinsAndActiveBoundInputIgnoresNextPreview() {
        let view=SessionDisplay(id:"s"), old=request(phase:"final",input:12000)
        apply(state("next-input",last:old),to:view)
        view.footer.preparingContext=true
        XCTAssertNil(resolve(view)["tokens"]?.number)
        let next:[String:WireValue] = ["tokens":.number(47000),"contextWindow":.number(200000)]
        XCTAssertEqual(resolve(view,preview:next).scope,"next-input")
        view.state="running"; apply(state(current:request(input:40000)),to:view)
        XCTAssertEqual(resolve(view,preview:next)["tokens"]?.number,40000)
        XCTAssertEqual(resolve(view,preview:next)["contextWindow"]?.number,100000)
        view.beginContextSubmission("queued")
        XCTAssertNil(view.footer.pendingContextSubmission,"Queue/steering cannot reset the active request")
    }
    @MainActor func testCompactionResetEpochResetOmissionAndExplicitNull() {
        let view=SessionDisplay(id:"s"), old=request(phase:"final",input:42000)
        apply(state(current:old),to:view)
        view.observeContext(["seq":.number(10000)])
        XCTAssertEqual(resolve(view)["tokens"]?.number,42000)
        var reset=state("next-input",generation:2,replay:2,last:old)
        reset["reason"] = .string("compaction-committed"); reset["count"] = .object(["state":.string("pending"),"tokens":.null])
        apply(reset,to:view)
        XCTAssertNil(resolve(view)["tokens"]?.number)
        XCTAssertEqual(resolve(view).reason,"compaction-committed")
        XCTAssertTrue(view.footer.requestObservation.isEmpty)
        let new:[String:WireValue] = ["tokens":.number(5000),"contextWindow":.number(100000)]
        XCTAssertEqual(resolve(view,preview:new)["tokens"]?.number,5000)
        var restart=state("next-input"); restart["runtimeEpoch"] = .string("new-epoch")
        apply(restart,to:view,baseline:true)
        apply(reset,to:view)
        XCTAssertEqual(view.footer.contextInputIdentity?.epoch,"new-epoch")
        XCTAssertTrue(view.context.isEmpty)
        XCTAssertNil(resolve(view)["tokens"]?.number)
    }
    @MainActor func testRequestPreparationWithoutFingerprintAndNoTranscriptPublication() {
        let view=SessionDisplay(id:"s"); view.state="running"
        var preparing=request(phase:"preparing"); preparing["requestFingerprint"] = .null; preparing["attemptID"] = .null
        var publications=0
        let subscription=view.transcriptChanges.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        apply(state("preparing",current:preparing),to:view)
        XCTAssertEqual(resolve(view)["tokens"]?.number,42000)
        XCTAssertEqual(resolve(view)["source"]?.string,"Preparing request input…")
        XCTAssertEqual(publications,0)
        preparing["estimate"] = .null
        apply(state("preparing",current:preparing),to:view)
        XCTAssertNil(resolve(view)["tokens"]?.number)
        XCTAssertEqual(resolve(view)["state"]?.string,"pending")
    }
    @MainActor func testSameKeyPartialPayloadRetainsObservationButExplicitNullClearsIt() {
        let view=SessionDisplay(id:"s")
        apply(state(current:request(input:40000)),to:view)
        var omitted=state(); omitted.removeValue(forKey:"currentRequest"); omitted.removeValue(forKey:"lastRequest")
        apply(omitted,to:view)
        XCTAssertEqual(resolve(view)["tokens"]?.number,40000)
        var reset=state(generation:2); reset["count"] = .null
        apply(reset,to:view)
        XCTAssertTrue(view.context.isEmpty); XCTAssertTrue(view.footer.requestObservation.isEmpty)
        XCTAssertNil(resolve(view)["tokens"]?.number)
    }
    @MainActor func testAcceptedSubmissionThatFailsBeforeDeliveryStopsPreparing() {
        let view=SessionDisplay(id:"s")
        view.beginContextSubmission("rejected-during-validation"); view.state="running"
        view.acknowledgeContextSubmission("rejected-during-validation")
        view.state="error"; apply(state("next-input"),to:view)
        XCTAssertNil(view.footer.pendingContextSubmission)
        XCTAssertEqual(resolve(view).reason,"input-changed")
    }
    @MainActor func testDiagnosticsAreOptInBoundedAndOnlySelectionMetadata() async {
        let off=ContextDiagnostics(output:nil)
        let view=SessionDisplay(id:"s"); apply(state(current:request()),to:view)
        off.record(sessionID:"s",state:view.footer.contextState,presentation:resolve(view))
        XCTAssertTrue(off.events.isEmpty)
        let output=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let on=ContextDiagnostics(output:output)
        for index in 0..<300 {
            var state=state(current:request(input:Double(index))); state["secret"] = .string("never log this")
            apply(state,to:view)
            on.record(sessionID:"s",state:state,presentation:resolve(view))
            on.record(sessionID:"s",state:state,presentation:resolve(view))
        }
        XCTAssertEqual(on.events.count,256)
        XCTAssertFalse(String(decoding:try! JSONEncoder().encode(on.events),as:UTF8.self).contains("never log"))
        try? await Task.sleep(for:.milliseconds(800)); try? FileManager.default.removeItem(at:output)
    }
}
private extension ContextPresentation {
    subscript(_ key: String) -> WireValue? { context[key] }
}
