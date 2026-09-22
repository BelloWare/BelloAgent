import XCTest
@testable import PiAgentCore

final class FullDisplayTests: XCTestCase {
    func testLongMultipartReplyAndReasoningSurviveProjectionAndJournalRoundTrip() throws {
        let prose = String(repeating:"## Content 🙂\n\nFull response paragraph.\n",count:2000) + "END OF RESPONSE"
        let reasoning = String(repeating:"Returned reasoning. ",count:3000) + "END OF REASONING"
        var message = ChatMessage(role:"assistant",content:[["type":"thinking","thinking":JSON(reasoning)],textBlock(prose)])
        message.responseTimeline = .canonical([("reasoningText",reasoning,nil,nil),("text",prose,nil,nil)],sourceID:message.id)
        let restored = try ChatMessage(id:message.id,pi:JSON.parse(message.pi.data()))
        let row = restored.view()
        XCTAssertEqual(row["text"].text,prose); XCTAssertEqual(row["thinking"].text,reasoning)
        XCTAssertEqual(row["truncated"].flag,false)
        XCTAssertEqual(row["responseTimeline"]["segments"].list.map { $0["text"].text },[reasoning,prose])
    }

    func testOldTruncatedTimelineRecoversCompleteSavedContentWithoutInventingArrivalOrder() {
        let text = String(repeating:"long response ",count:4000) + "TAIL"
        var message = ChatMessage(role:"assistant",content:[textBlock(text)])
        var old = ResponseTimeline.canonical([("text","long response",nil,nil)],sourceID:message.id)
        old.segments[0].truncated=true; old.omittedEvents=3; old.coverage="partial"
        message.responseTimeline=old
        let view=message.view()
        XCTAssertEqual(view["responseTimeline"]["segments"].list.first?["text"].text,text)
        XCTAssertEqual(view["responseTimeline"]["coverage"].text,"canonical")
        XCTAssertEqual(view["responseTimeline"]["omittedEvents"].int,0)
        XCTAssertTrue(message.responseTimeline!.segments[0].truncated,"Reading must not rewrite the journal")
    }

    func testTransferReassemblesEscapedUnicodeBeyondFrameLimitAndExpiresExplicitly() throws {
        let text = String(repeating:"🙂\u{0001}\\\"\n",count:150_000) + "COMPLETE TAIL"
        let value: JSON = ["text":JSON(text)]
        let data = try value.data()
        XCTAssertGreaterThan(data.count,1_048_576)
        var transfers=DisplayResultTransfers()
        let marker=try transfers.insert(data,now:10), id=try XCTUnwrap(marker["id"].text)
        var bytes=Data()
        while bytes.count < data.count {
            let page=try transfers.read(id,offset:bytes.count,now:11)
            XCTAssertLessThan(try page.data().count,1_048_576)
            XCTAssertEqual(page["offset"].int,bytes.count)
            XCTAssertEqual(page["totalBytes"].int,data.count)
            bytes.append(try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(page["data"].text))))
            XCTAssertEqual(page["next"],bytes.count == data.count ? .null : JSON(bytes.count))
        }
        XCTAssertEqual(bytes,data); XCTAssertEqual(try JSON.parse(bytes)["text"].text,text)
        XCTAssertThrowsError(try transfers.read(id,offset:data.count,now:11))
        XCTAssertThrowsError(try transfers.read(id,offset:0,now:131))
    }

    func testLargeHistoryRowIsCompleteAndEveryPageRemainsReachable() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let large=String(repeating:"Complete saved response 🙂\n",count:25_000)+"TAIL"
        var first=ChatMessage(role:"user",content:[textBlock("Question")]); first.id="u"
        var reply=ChatMessage(role:"assistant",content:[textBlock(large)]); reply.id="a"
        let session=try AgentSession(id:"full",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),seed:[first,reply],autoCompaction:false)
        addTeardownBlock { await session.close() }
        let page=try await session.historyWindow([:])
        XCTAssertEqual(page["messages"].list.count,1)
        XCTAssertEqual(page["messages"].list.first?["text"].text,large)
        let prior=try await session.historyWindow(["cursor":page["older"]])
        XCTAssertEqual(prior["messages"].list.map { $0["id"].text },["u"])
        let again=try await session.historyWindow(["cursor":prior["newer"],"direction":"newer"])
        XCTAssertEqual(again["messages"].list.first?["text"].text,large)
        let snapshot=await session.snapshot(["includeMetrics":false])
        XCTAssertEqual(snapshot["messages"].list.last?["text"].text,large)
    }
}
