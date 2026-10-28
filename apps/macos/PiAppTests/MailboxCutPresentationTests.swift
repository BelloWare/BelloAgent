import AppKit
import XCTest
@testable import PiApp

final class MailboxCutPresentationTests: XCTestCase {
    static let cut: WireValue = .object(["version":.number(1),"cutId":.string("cut-1"),"attemptId":.string("attempt-1"),"responseId":.string("response-1"),"itemId":.string("reasoning-1")])
    static let cancelled: WireValue = .object(["version":.number(1),"cutId":.string("cut-1"),"reason":.string("agent_message")])
    static func row(text: String = "Retained commentary before the agent message.", tool: Bool = false) -> TranscriptMessage {
        var row = TranscriptMessage(id:"cut-reply",role:"assistant",text:text,thinking:text.isEmpty ? "A completed reasoning item." : nil,state:"complete",turn:"question",taskRootID:"question")
        row.nativeMailboxCut = cut; row.mailboxCutin = true
        if tool {
            var call = ToolView(id:"call-1",name:"bash",state:"cancelled",input:"{\"command\":\"swift test\"}",output:"Not executed: agent message arrived before dispatch.",truncated:false)
            call.nativeAgentCallCancellation = cancelled; call.mailboxCutin = true
            row.tools = [call]
        }
        return row
    }
    func testMarkerRequiresCapabilityAndKnownTypedVersion() {
        var row = Self.row()
        XCTAssertEqual(MailboxCutPresentation.marker(row),"Reply cut for agent message")
        row.mailboxCutin = false; XCTAssertNil(MailboxCutPresentation.marker(row))
        row.mailboxCutin = true; row.nativeMailboxCut = .object(["version":.number(2)])
        XCTAssertNil(MailboxCutPresentation.marker(row))
        row.nativeMailboxCut = nil; row.text = "Reply cut for agent message"
        XCTAssertNil(MailboxCutPresentation.marker(row))
    }
    func testThinkingOnlyAndCommentaryHaveExactlyOneMarker() {
        for text in ["", "Retained note"] {
            let items = TaskTranscriptPlan.items([Self.row(text:text)],lifecycle:nil)
            let markers = items.compactMap { item -> TranscriptMessage? in if case .message(let row) = item, row.id == "mailbox-cut:cut-reply" { return row }; return nil }
            XCTAssertEqual(markers.count,1); XCTAssertEqual(markers.first?.text,"Reply cut for agent message")
        }
    }
    @MainActor func testPermanentCutMarkerHasNoActivitySpinner() throws {
        let items = TaskTranscriptPlan.items([Self.row(text:"")],lifecycle:nil)
        let item = try XCTUnwrap(items.first { if case .message(let row) = $0 { return row.id == "mailbox-cut:cut-reply" }; return false })
        let inputs = TranscriptRowInputs(item:item,fresh:false,actions:TranscriptActions(),width:600,environment:TranscriptRowEnvironment())
        let view = TranscriptRowRenderer.content(for:item,inputs:inputs)
        XCTAssertTrue(view.subviews.filter { $0 is TranscriptSpinner }.allSatisfy(\.isHidden))
        XCTAssertEqual(view.accessibilityLabel(),"Reply cut for agent message")
    }
    func testCancelledCallUsesTypedStateAndInspectableResult() {
        var call = Self.row(tool:true).tools![0]
        XCTAssertEqual(TranscriptToolRow.model(of:call).title,"Not run · agent message arrived")
        XCTAssertEqual(TranscriptToolRow.model(of:call).state,.stopped)
        if case .io(_,_,let output,let failed,let note) = TranscriptToolRow.card(of:call,fetched:nil,model:TranscriptToolRow.model(of:call),linked:false) {
            XCTAssertEqual(output,call.output); XCTAssertFalse(failed); XCTAssertEqual(note,"Not run · agent message arrived")
        } else { XCTFail("Cancelled call must show its retained result") }
        call.mailboxCutin = false; XCTAssertNil(MailboxCutPresentation.cancelled(call))
        call.mailboxCutin = true; call.nativeAgentCallCancellation = nil
        XCTAssertNil(MailboxCutPresentation.cancelled(call),"Text cannot forge cancellation metadata")
    }
    func testHistoryRetainsCutAndCancellationMetadata() throws {
        let row = TranscriptMessage.project(id:"a",message:["role":.string("assistant"),"content":.array([]),"nativeMailboxCut":Self.cut])
        XCTAssertEqual(row.nativeMailboxCut,Self.cut)
        let result = try XCTUnwrap(ToolResultRecord.of(["role":.string("toolResult"),"toolCallId":.string("call-1"),"content":.string("Not executed: agent message arrived before dispatch."),"isError":.bool(true),"nativeToolStats":.object(["outcome":.string("not_executed")]),"nativeAgentCallCancellation":Self.cancelled]))
        XCTAssertEqual(result.record.nativeAgentCallCancellation,Self.cancelled); XCTAssertEqual(result.record.cardState,"cancelled")
    }
    @MainActor func testDisplayCapabilityAndTransientStatus() {
        let session = SessionDisplay(id:"fixture"); session.historyState = .ready
        session.messages = [Self.row(tool:true)]
        XCTAssertNil(MailboxCutPresentation.marker(session.presentedMessages[0]))
        session.supportsMailboxCutin = true
        XCTAssertEqual(MailboxCutPresentation.marker(session.presentedMessages[0]),"Reply cut for agent message")
        XCTAssertEqual(MailboxCutPresentation.cancelled(session.presentedMessages[0].tools![0]),"Not run · agent message arrived")
        session.runState = .running; session.receivingAgentMessage = true
        XCTAssertEqual(SessionRunLine.action(session),"Receiving agent message")
        session.receivingAgentMessage = false
        XCTAssertNotEqual(SessionRunLine.action(session),"Receiving agent message")
    }
}
