import XCTest
@testable import PiApp

final class ResponseTimelinePresentationTests: XCTestCase {
    private func parts() -> ResponseTimeline {
        var timeline=ResponseTimeline()
        for (i,kind) in ["text","reasoningSummary","text","toolArguments"].enumerated() {
            timeline.consume(ResponsePartEvent(attemptID:"attempt",ordinal:i,itemID:i==2 ? "0":"\(i)",kind:kind,update:"append",text:"Part \(i)"))
        }
        return timeline
    }
    func testChronologyAndMetadataCannotReorderOrChangeProseHosts() {
        var reply=TranscriptMessage(id:"reply",role:"assistant",text:"joined",state:"streaming")
        reply.responseTimeline=parts()
        let rows=[TranscriptMessage(id:"user",role:"user",text:"Ask"),reply]
        let before=TaskTranscriptPlan.items(rows,lifecycle:nil)
        let segments=before.compactMap { if case .block(let block)=$0 { return block.part };return nil }
        XCTAssertEqual(segments.map(\.part.kind),["text","reasoningSummary","text","toolArguments"])
        reply.accounting=GatewayTotals();reply.modelMs=30;reply.accounting?.costUSD=0
        let after=TaskTranscriptPlan.items([rows[0],reply],lifecycle:nil)
        XCTAssertEqual(before.compactMap { if case .block(let b)=$0{return b};return nil },after.compactMap { if case .block(let b)=$0{return b};return nil })
    }
    func testCosmeticPlannerPatchMatchesFullChronologyWithoutRebuildingOtherResponses() throws {
        var response = TranscriptMessage(id:"r",role:"assistant",text:"First",state:"streaming")
        response.responseTimeline = parts()
        let earlier = TranscriptMessage(id:"old",role:"assistant",text:"Earlier answer",thinking:"Earlier reasoning")
        let before = [TranscriptMessage(id:"u",role:"user",text:"Ask"),earlier,response]
        let items = TaskTranscriptPlan.items(before,lifecycle:nil)
        var after = before
        after[2].responseTimeline?.segments[3].text += " growing arguments"
        after[2].responseTimeline?.segments[3].revision += 1
        let patch = try XCTUnwrap(TranscriptActivity.patched(items,from:before,to:after))
        XCTAssertEqual(patch,TaskTranscriptPlan.items(after,lifecycle:nil))
        after[2].accounting = GatewayTotals()
        XCTAssertNil(TranscriptActivity.patched(items,from:before,to:after),"Late totals take the complete planner")
    }
    func testPartPatchUpdatesOnlyItsStableSegment() throws {
        var reply=TranscriptMessage(id:"r",role:"assistant",text:"")
        reply.responseTimeline=parts()
        let first=reply.responseTimeline!.segments.first!
        var changed=reply.responseTimeline!.segments.last!;changed.text += " suffix";changed.revision += 1
        let encoded=try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode([changed]))
        let patch:WireValue = .object(["parts":.array([.object(["id":.string("r"),"version":.number(1),"segments":encoded,"coverage":.string("observed"),"omittedEvents":.number(0)])])])
        let result=try XCTUnwrap(TranscriptRowUpdates.apply(patch,to:[reply]))
        XCTAssertEqual(result[0].responseTimeline?.segments.first,first)
        XCTAssertEqual(result[0].responseTimeline?.segments.last,changed)
        XCTAssertEqual(result[0].responseTimeline?.segments.map(\.id),reply.responseTimeline?.segments.map(\.id))
    }
    func testLedgerDoesNotDuplicateFinalResponseOrCompactionMarker() {
        var ledger=TranscriptMessage(id:"ledger",role:"system",text:"",kind:"requestLedger")
        ledger.presentationSourceID="reply";ledger.responseTimeline=parts()
        var reply=TranscriptMessage(id:"reply",role:"assistant",text:"");reply.responseTimeline=parts()
        var operation=TranscriptMessage(id:"operation",role:"system",text:"",kind:"execution");operation.operationID="op"
        var checkpoint=TranscriptMessage(id:"summary",role:"system",text:"summary",kind:"compaction");checkpoint.operationID="op"
        let items=TaskTranscriptPlan.items([ledger,reply,operation,checkpoint],lifecycle:nil)
        XCTAssertEqual(items.compactMap { if case .block(let b)=$0{return b.part};return nil }.count,4)
        XCTAssertFalse(items.contains { if case .message(let m)=$0{return m.id=="ledger" || m.id=="summary"};return false })
    }
    func testHistoryAppliesPresentationRevisionAtOriginalPosition() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("test.jsonl")
        var timeline=parts();timeline.finish("completed")
        let raw=try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(timeline))
        let message:WireValue = .object(["role":.string("system"),"content":.array([]),"nativeReplayEligible":.bool(false),"nativeKind":.string("execution"),"nativeResponseTimeline":raw,"nativeDetail":.string("Checkpoint adopted")])
        var initial = message.object!
        var initialTimeline = parts(); initialTimeline.segments = Array(initialTimeline.segments.prefix(1))
        initial["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(initialTimeline))
        initial["nativeDetail"] = .string("Started")
        let records:[WireValue]=[
            .object(["type":.string("session"),"version":.number(3),"id":.string("s")]),
            .object(["type":.string("message"),"id":.string("op"),"message":.object(initial)]),
            .object(["type":.string("message"),"id":.string("u"),"parentId":.string("op"),"message":.object(["role":.string("user"),"content":.string("Later input")])]),
            .object(["type":.string("custom"),"customType":.string("pi-app.presentation.update.v1"),"id":.string("revision"),"parentId":.string("u"),"data":.object(["id":.string("op")]),"message":message])]
        var bytes=Data();for record in records { bytes.append(try JSONEncoder().encode(record));bytes.append(10) };try bytes.write(to:file)
        let reader = HistoryReader()
        let page=try await reader.read(path:file.path)
        XCTAssertNil(page.notice);XCTAssertEqual(page.messages.map(\.id),["op","u"])
        XCTAssertEqual(page.messages.first?.responseTimeline?.segments.map(\.id),timeline.segments.map(\.id))
        XCTAssertEqual(page.messages.first?.responseTimeline?.terminal,"completed")
        let indexed = try await reader.message(path:file.path,id:"op",field:"text",offset:0).0
        let unindexed = try await HistoryReader().message(path:file.path,id:"op",field:"text",offset:0).0
        XCTAssertEqual(indexed,unindexed)
        XCTAssertTrue(indexed.contains("Part 3")); XCTAssertTrue(indexed.contains("Checkpoint adopted"))
    }
    func testLaterReasoningIsNotRelocatedBeforeEarlierProse() {
        let rows = [TranscriptMessage(id: "u", role: "user", text: "Task"),
                    TranscriptMessage(id: "a", role: "assistant", text: "First answer"),
                    TranscriptMessage(id: "b", role: "assistant", text: "Second answer", thinking: "Later returned reasoning")]
        let items = TaskTranscriptPlan.items(rows, lifecycle: nil)
        let prose = items.firstIndex { if case .block(let b) = $0 { return b.message?.text == "First answer" }; return false }
        let reasoning = items.firstIndex { if case .block(let b) = $0 { return b.replies.contains { $0.thinking == "Later returned reasoning" } }; return false }
        XCTAssertNotNil(prose); XCTAssertNotNil(reasoning)
        if let prose, let reasoning { XCTAssertGreaterThan(reasoning, prose) }
    }
    @MainActor func testClosedPreparationKeepsItsMeasuredGeometryAndLatestEvidence() throws {
        var message = TranscriptMessage(id:"response",role:"assistant",text:"",state:"streaming")
        message.responseTimeline = parts()
        let item = try XCTUnwrap(TaskTranscriptPlan.items([message],lifecycle:nil).first { if case .block(let b)=$0 {return b.part?.part.kind == "toolArguments"};return false })
        let row = TranscriptRowContainer(item:item,fresh:false,actions:TranscriptActions())
        message.responseTimeline?.segments[3].text += " arguments continue"
        let next = try XCTUnwrap(TaskTranscriptPlan.items([message],lifecycle:nil).first { if case .block(let b)=$0 {return b.part?.part.kind == "toolArguments"};return false })
        XCTAssertFalse(row.update(item:next,fresh:false,actions:TranscriptActions()),"Closed arguments cannot change their header height")
        XCTAssertEqual(row.item,next,"Opening must still show the latest source")
        let part = try XCTUnwrap(message.responseTimeline?.segments[0])
        let operation = TranscriptMessage(id:"operation",role:"system",text:"",kind:"execution")
        let rendered = TimelinePartRow(part:part,message:operation,actions:TranscriptActions(),open:true,toggle:{}).source
        XCTAssertEqual(rendered.text,part.text); XCTAssertEqual(rendered.role,"assistant"); XCTAssertNil(rendered.kind)
    }
    func testUnknownOrDuplicateTimelineCannotReplaceLegacyContent() {
        var message = TranscriptMessage(id:"response",role:"assistant",text:"Retained answer")
        var timeline = parts(); timeline.version = 99; message.responseTimeline = timeline
        let fallback = TaskTranscriptPlan.items([message],lifecycle:nil)
        XCTAssertTrue(fallback.contains { if case .block(let b)=$0{return b.message?.text == "Retained answer"};return false })
        timeline.version=1;timeline.segments.append(timeline.segments[0]);message.responseTimeline=timeline
        XCTAssertFalse(timeline.supported)
        XCTAssertTrue(TaskTranscriptPlan.items([message],lifecycle:nil).contains { if case .block(let b)=$0{return b.message?.text == "Retained answer"};return false })
    }

    func testTerminalReceiptAfterToolResultStaysAtTheEnd() {
        var task = TaskPresentationRecord(rootID:"u",executionID:"e",startedAt:10)
        task.outcome="cancelled";task.phase="terminal";task.endedAt=20;task.lastSourceID="result"
        let projection=TaskPresentationProjection(sessionID:"s",epoch:"epoch",timeline:"root",sequence:1,sourceRevision:"1",active:nil,recent:[task])
        let rows=[TranscriptMessage(id:"u",role:"user",text:"Ask",taskRootID:"u",taskExecutionID:"e"),
                  TranscriptMessage(id:"result",role:"tool",text:"Partial result",kind:"toolResult",taskRootID:"u",taskExecutionID:"e")]
        let items=TaskTranscriptPlan.items(rows,lifecycle:projection)
        guard case .block(let last)=items.last else { return XCTFail("A terminal tool result must keep its task receipt") }
        XCTAssertEqual(last.presentation,.summary);XCTAssertEqual(last.turn?.outcome,"cancelled")
        XCTAssertEqual(items.filter { if case .block(let b)=$0{return b.presentation == .summary};return false }.count,1)
    }

}
