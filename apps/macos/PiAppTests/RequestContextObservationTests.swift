import XCTest
@testable import PiApp

final class RequestContextObservationTests: XCTestCase {
    @MainActor func testFreshBusyHeuristicAndExplicitPendingDoNotReviveOldCount() {
        let view=SessionDisplay(id:"s"); view.state="running"
        view.context=["tokens":.number(12000),"contextWindow":.number(100000)]
        view.observeContext(["context":.object(["tokens":.number(42000),"contextWindow":.number(100000),"method":.string("heuristic")])])
        XCTAssertEqual(view.context["tokens"]?.number,42000)
        view.observeContext(["context":.object(["tokens":.null,"state":.string("pending")])])
        XCTAssertNil(view.context["tokens"]?.number,"An explicit reset must not retain the pre-reset count")
        view.context=["tokens":.number(12000)]
        view.observeContext([:],baseline:true)
        XCTAssertTrue(view.context.isEmpty,"A reopened runtime must clear the old fallback")
    }
    @MainActor func testStatusOnlyEventDoesNotErasePreparedInput() {
        let view=SessionDisplay(id:"s")
        let item=ChatRecord(id:"s",workspaceID:"w",title:"Title",path:nil,profileID:"p")
        view.footer.preparedContext=PreparedContextMetrics(summary:["seq":.number(1),"contextWindow":.number(100000),"count":.object(["tokens":.number(42000)])],binding:ContextPreviewBinding(item),params:[:],configurationRevision:0,directCommand:false)
        view.observeContext(["seq":.number(200)])
        XCTAssertEqual(view.footer.preparedContext?.context["tokens"]?.number,42000)
    }
    private func observation(input: Double?, phase: String = "final") -> [String: WireValue] {
        ["attemptID":.string("a"),"requestFingerprint":.string("hash"),"contextWindow":.number(1000),"requestedModel":.string("auto-router"),"effectiveModel":.string("served"),"phase":.string(phase),
         "usage":.object(["input":input.map(WireValue.number) ?? .null,"output":.number(20),"cacheRead":.number(100),"reasoning":.number(10)]),
         "status":.object(["input":.string(input == nil ? "unreported":"reported")]),
         "estimate":.object(["tokens":.number(300),"estimated":.bool(true),"method":.string("heuristic")])]
    }
    func testReportedInputRetainsDispatchCapacityAndDoesNotAddOutputOrCache() {
        let value=RequestContextObservation(observation(input:1200))
        let meter=ContextMeterPresentation(context:value.context!,capacity:99999)
        XCTAssertFalse(meter.estimated); XCTAssertEqual(meter.fraction,1.2)
        XCTAssertTrue(meter.compactLabel.contains("reported")); XCTAssertFalse(meter.warnings.isEmpty)
        XCTAssertTrue(value.details.contains("included in input")); XCTAssertTrue(value.details.contains("included in output"))
        let pending=ContextMeterPresentation(context:RequestContextObservation(observation(input:nil,phase:"awaiting")).context!)
        XCTAssertTrue(pending.estimated); XCTAssertTrue(pending.compactLabel.contains("awaiting usage"))
        XCTAssertEqual(pending.fraction,0.3)
    }
    @MainActor func testUsageOnlySnapshotChangesFooterWithoutTranscriptPublication() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        let model=WorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        let view=SessionDisplay(id:"s"); model.displays[view.id]=view
        view.state="running"; view.context=["tokens":.number(999),"contextWindow":.number(9999)]
        var publications=0
        let subscription=view.transcriptChanges.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        view.observeContext(["contextObservationRevision":.string("epoch:1"),"requestObservation":.object(observation(input:100))])
        XCTAssertEqual(model.displayedContext(view)["tokens"]?.number,100)
        XCTAssertEqual(model.displayedContext(view)["contextWindow"]?.number,1000)
        XCTAssertEqual(publications,0)
        view.observeContext(["contextObservationRevision":.string("epoch:2"),"requestObservation":.object(observation(input:nil,phase:"awaiting"))])
        XCTAssertEqual(model.displayedContext(view)["tokens"]?.number,300,"New dispatch can replace the last reported count with its honest estimate")
        view.observeContext(["contextObservationRevision":.string("epoch:3"),"requestObservation":.null],baseline:true)
        XCTAssertTrue(view.footer.requestObservation.isEmpty)
    }
}
