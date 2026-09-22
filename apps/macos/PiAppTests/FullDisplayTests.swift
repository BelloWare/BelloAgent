import XCTest
@testable import PiApp

final class FullDisplayTests: XCTestCase {
    private let prose = String(repeating:"## Complete response 🙂\n\nParagraph with **formatting** and `code`.\n\n",count:2400) + "LAST PARAGRAPH"

    func testSavedProjectionAndTimelineKeepCompleteTextAndRecoverOldPrefixes() throws {
        let reasoning=String(repeating:"Returned reasoning. ",count:1000)
        var old=ResponseTimeline.canonical([("text","prefix",nil,nil)],sourceID:"a")
        old.segments[0].truncated=true; old.omittedEvents=4
        let raw=try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(old))
        let row=TranscriptMessage.project(id:"a",message:["role":.string("assistant"),"nativeResponseTimeline":raw,
            "content":.array([.object(["type":.string("thinking"),"thinking":.string(reasoning)]),.object(["type":.string("text"),"text":.string(prose)])])])
        XCTAssertEqual(row.text,prose); XCTAssertEqual(row.thinking,reasoning); XCTAssertEqual(row.truncated,false)
        XCTAssertEqual(row.responseTimeline?.coverage,"canonical")
        let items=TaskTranscriptPlan.items([TranscriptMessage(id:"u",role:"user",text:"Ask"),row],lifecycle:nil)
        let parts=items.compactMap { if case .block(let b)=$0 { return b.part }; return nil }
        XCTAssertEqual(parts.map(\.text),[reasoning,prose]); XCTAssertFalse(parts.contains(where:\.truncated))
    }

    func testTimelineAppendBeyondOldLimitsRetainsIdentityAndRejectsStaleBase() throws {
        var row=TranscriptMessage(id:"a",role:"assistant",text:prose,state:"streaming")
        row.responseTimeline=ResponseTimeline.canonical([("text",prose,nil,nil)],sourceID:"a")
        let part=try XCTUnwrap(row.responseTimeline?.segments.first)
        let patch:WireValue = .object(["parts":.array([.object(["id":.string("a"),"version":.number(1),"segments":.array([]),
            "appends":.array([.object(["id":.string(part.id),"baseRevision":.number(Double(part.revision)),"revision":.number(Double(part.revision+1)),"state":.string("streaming"),"text":.string("\nTAIL 🙂")])])])])])
        let updated=try XCTUnwrap(TranscriptRowUpdates.apply(patch,to:[row]))
        XCTAssertEqual(updated[0].responseTimeline?.segments[0].text,prose+"\nTAIL 🙂")
        XCTAssertEqual(updated[0].responseTimeline?.segments[0].id,part.id)
        XCTAssertNil(TranscriptRowUpdates.apply(patch,to:updated),"A duplicated append must request resync, not duplicate text")
    }

    func testLargeTransferDecodesEveryByteAndRejectsShortOrCancelledReads() async throws {
        let original:WireValue = .object(["text":.string(String(repeating:"\u{0001}🙂",count:240_000)+"TAIL")])
        let data=try JSONEncoder().encode(original)
        let marker:WireValue = .object(["_displayTransfer":.number(1),"id":.string(UUID().uuidString),"bytes":.number(Double(data.count))])
        let result=try await DisplayResultReader.read(marker) { _,offset in
            let end=min(data.count,offset+192*1024)
            return .object(["data":.string(data.subdata(in:offset..<end).base64EncodedString()),"offset":.number(Double(offset)),"totalBytes":.number(Double(data.count)),"next":end==data.count ? .null : .number(Double(end))])
        }
        XCTAssertEqual(result,original)
        do {
            _=try await DisplayResultReader.read(marker) { _,offset in .object(["data":.string(""),"offset":.number(Double(offset)),"totalBytes":.number(Double(data.count)),"next":.null]) }
            XCTFail("A short transfer must not masquerade as the full reply")
        } catch { }
        let task=Task { try await DisplayResultReader.read(marker) { _,_ in try await Task.sleep(for:.seconds(10)); return .null } }
        task.cancel()
        do { _=try await task.value; XCTFail("Cancelled transfers must not publish") } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testRealHelperOpensLargeSavedReplyAndHistoryWithoutFrameOverflow() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent("full-display-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"), host=HostSupervisor()
        defer { host.shutdown() }
        var profile=ProfileRecord(); profile.modelId="fixture"; profile.baseUrl="https://gateway.example/v1"
        try await host.connect(cwd:root,state:state)
        _=try await host.request("workspace.open",params:["cwd":.string(root.path),"directory":.string(state.path),"mcp":.object(["servers":.object([:])])])
        let opened=try await host.request("session.open",sessionID:"full",params:["profile":profile.wire,"apiKey":.string("synthetic-only"),"connectionTest":.bool(true)])
        let path=try XCTUnwrap(opened.object?["path"]?.string)
        try await host.shutdownAndWait()
        let bytes=try Data(contentsOf:URL(fileURLWithPath:path))
        let last=try XCTUnwrap(bytes.split(separator:10).last)
        let parent=try XCTUnwrap(try JSONDecoder().decode(WireValue.self,from:Data(last)).object?["id"])
        let complete=String(repeating:"Full answer 🙂\u{0001}\n",count:70_000)+"EXACT FINAL TAIL"
        let record:WireValue = .object(["type":.string("message"),"id":.string("large-answer"),"parentId":parent,
            "message":.object(["role":.string("assistant"),"content":.array([.object(["type":.string("text"),"text":.string(complete)])])])])
        var appended=try JSONEncoder().encode(record); appended.append(10)
        let writer=try FileHandle(forWritingTo:URL(fileURLWithPath:path)); try writer.seekToEnd(); try writer.write(contentsOf:appended); try writer.close()
        // Cold file reader and live helper must agree without an inspector click.
        let cold=try await HistoryReader().window(path:path)
        XCTAssertEqual(cold.messages.last?.text,complete)
        XCTAssertEqual(cold.messages.last?.responseTimeline?.segments.last?.text,complete)
        try await host.connect(cwd:root,state:state)
        _=try await host.request("workspace.open",params:["cwd":.string(root.path),"directory":.string(state.path)])
        let reopened=try await host.request("session.open",sessionID:"full",params:["profile":profile.wire,"apiKey":.string("synthetic-only"),"path":.string(path)])
        XCTAssertEqual(reopened.object?["messages"]?.array?.last?.object?["text"]?.string,complete)
        let history=try ConversationHistoryPage(await host.request("session.history",sessionID:"full",params:["version":.number(2)]))
        XCTAssertEqual(history.messages.last?.text,complete); XCTAssertEqual(history.messages.last?.truncated,false)
        XCTAssertTrue(host.isReady,"Large content must never terminate the helper")
        try await host.shutdownAndWait()
    }
}
