import XCTest
@testable import PiAgentCore

final class ResponseTimelineTests: XCTestCase {
    private func part(_ ordinal: Int, _ index: Int, _ kind: String, _ update: String, _ text: String = "", attempt: String = "a") -> ResponsePartEvent {
        ResponsePartEvent(attemptID:attempt,ordinal:ordinal,itemID:"item-\(index)",outputIndex:index,partIndex:0,
                          kind:kind,update:update,text:text,callID:kind == "toolArguments" ? "call-\(index)" : nil,
                          name:kind == "toolArguments" ? "read" : nil)
    }
    func testGeneratedLiveStreamsMatchOriginalReconcilerAfterEveryEvent() throws {
        let kinds=["text","reasoningText","reasoningSummary","toolArguments","opaque","correction","",":0:text"]
        let texts=["","a","e","\u{301}","é","🙂\n漢字","{}","corrected"]
        let updates=["begin","append","end","replace","append","replace","unknown"]
        for seed in 0..<16 {
            var actual=ResponseTimeline(), expected=ResponseTimeline(), random=UInt64(seed+1)
            // Exercise empty replacement, interleaving, continuations, repeated
            // corrections and canonically equivalent text split across segments.
            var events=[
                part(0,0,"text","begin"),part(1,0,"text","replace","e"),
                part(2,1,"reasoningText","append","thought"),part(3,0,"text","append","\u{301}"),
                part(4,0,"text","replace","é"),part(5,0,"text","replace","new"),
                part(6,0,"text","replace","new"),part(7,0,"text","replace",""),
                part(8,0,"text","end"),part(9,0,"text","append","tail"),
                part(10,2,"toolArguments","begin"),part(11,2,"toolArguments","append","{}"),
                part(12,2,"toolArguments","replace","{}"),part(13,2,"toolArguments","end")]
            for ordinal in 14..<310 {
                random=random &* 6364136223846793005 &+ 1442695040888963407
                var event=part(ordinal,Int((random >> 16) % 9),kinds[Int((random >> 24) % UInt64(kinds.count))],
                               updates[Int((random >> 32) % UInt64(updates.count))],texts[Int((random >> 40) % UInt64(texts.count))],
                               attempt:ordinal % 11 == 0 ? "a:0" : "a")
                if ordinal % 3 == 0 { event.outputIndex=nil }
                if ordinal % 5 == 0 { event.partIndex=nil }
                if ordinal % 7 == 0 { event.evidence="canonical"; event.observedAt=Double(ordinal); event.sessionOrdinal=ordinal+100 }
                if ordinal % 13 == 0 { event.reconcilesPartKey=events[ordinal % events.count].partKey }
                events.append(event)
            }
            for event in events {
                XCTAssertEqual(actual.consume(event),expected.consumeOriginal(event),"seed=\(seed) event=\(event.ordinal)")
                XCTAssertEqual(actual,expected,"seed=\(seed) event=\(event.ordinal)")
                guard actual == expected else { return }
                if event.ordinal % 67 == 0 {
                    let outcome=["completed","interrupted","streaming"][seed % 3]
                    actual.finish(outcome); expected.finishOriginal(outcome)
                    XCTAssertEqual(actual,expected)
                }
            }
            actual.finish("interrupted"); expected.finishOriginal("interrupted")
            XCTAssertEqual(actual,expected)
            XCTAssertEqual(try JSON.parse(JSONEncoder().encode(actual)),try JSON.parse(JSONEncoder().encode(expected)))
        }
    }
    func testReconciliationSurvivesValueCopiesDecodingAndExternalSegmentEdits() throws {
        var original=ResponseTimeline()
        original.consume(part(0,0,"text","append","prefix"))
        original.consume(part(1,1,"toolArguments","begin"))
        let data=try JSONEncoder().encode(original)
        for source in [original,original.projected(),try JSONDecoder().decode(ResponseTimeline.self,from:data)] {
            for mutation in 0..<8 {
                var actual=source, expected=source
                func edit(_ timeline: inout ResponseTimeline) {
                    switch mutation {
                    case 0: timeline.segments.reverse()
                    case 1: timeline.segments[0].part.outputIndex=1
                    case 2: timeline.segments[0].text=""
                    case 3: timeline.segments.removeAll()
                    case 4: timeline.segments += timeline.segments
                    case 5: timeline.segments=ResponseTimeline.canonical([("text","other",nil,nil)],sourceID:"copy").segments
                    case 6: timeline.finish("streaming")
                    default: break
                    }
                }
                edit(&actual); edit(&expected)
                for event in [part(2,0,"text","replace","changed"),part(3,1,"toolArguments","append","{}"),
                              part(4,1,"toolArguments","end"),part(5,0,"text","replace","changed")] {
                    XCTAssertEqual(actual.consume(event),expected.consumeOriginal(event))
                    XCTAssertEqual(actual,expected)
                }
                actual.finish("completed"); expected.finishOriginal("completed")
                XCTAssertEqual(actual,expected)
            }
        }
        XCTAssertEqual(try JSON.parse(JSONEncoder().encode(original)),try JSON.parse(data),"Mutating a copy must not alter its source")
    }
    func testExternalTextEditsInvalidateReconciliationLookups() {
        for assignment in [false,true] {
            var timeline=ResponseTimeline()
            timeline.consume(part(0,0,"text","append","before"))
            if assignment {
                var edited=timeline.segments; edited[0].text="after"; timeline.segments=edited
            } else { timeline.segments[0].text="after" }
            let expected=timeline
            XCTAssertFalse(timeline.consume(part(1,0,"text","replace","after")))
            XCTAssertEqual(timeline,expected,"An external edit must not produce a spurious terminal correction")
        }
    }
    func testPartKeyAliasesKeepOriginalMatchingAndCorrectionScope() {
        let a=part(0,0,"text:tail","append","a",attempt:"one")
        var b=part(1,0,"tail","append","b",attempt:"one:0"); b.outputIndex=nil; b.itemID="text"
        XCTAssertEqual(a.partKey,b.partKey)
        var correctionA=a, correctionB=b
        correctionA.update="replace"; correctionA.text="corrected"; correctionA.ordinal=2
        correctionB.update="replace"; correctionB.text="corrected"; correctionB.ordinal=3
        var actual=ResponseTimeline(), expected=ResponseTimeline()
        for event in [a,b,correctionA,correctionB,correctionA,correctionB] {
            XCTAssertEqual(actual.consume(event),expected.consumeOriginal(event))
            XCTAssertEqual(actual,expected)
        }
    }
    func testFiveThousandTerminalProviderItemsReconcileWithinBudget() {
        let output: [JSON]=(0..<5000).map {
            ["type":"function_call","id":JSON("item-\($0)"),"call_id":JSON("call-\($0)"),"name":"read","arguments":"{}"]
        }
        for json in [true,false] {
            var adapter=ProviderDisplayEvents(api:"openai-responses",attempt:"generated")
            let response: JSON=["status":"completed","output":.array(output)]
            let value: JSON=json ? response : ["type":"response.completed","response":response]
            let start=nowMS(), events=adapter.consume(value,at:nil,json:json), elapsed=nowMS()-start
            print("LIVE-TERMINAL items=5000 json=\(json) ms=\(elapsed)")
            XCTAssertEqual(events.count,5000); XCTAssertEqual(adapter.timeline.segments.count,5000)
            XCTAssertLessThan(elapsed,100,"Terminal reconciliation must not stall a large tool batch")
        }
    }
    func testFiveThousandStreamedPartsReconcileWithinBudget() {
        let events=(0..<5000).flatMap { index in
            [part(index*4,index,"toolArguments","begin"),part(index*4+1,index,"toolArguments","append","{}"),
             part(index*4+2,index,"toolArguments","replace","{}"),part(index*4+3,index,"toolArguments","end")]
        }
        var timeline=ResponseTimeline()
        let start=nowMS()
        for event in events { timeline.consume(event) }
        let elapsed=nowMS()-start
        print("LIVE-STREAM items=5000 events=\(events.count) ms=\(elapsed)")
        XCTAssertEqual(timeline.segments.count,5000)
        XCTAssertTrue(timeline.segments.allSatisfy { $0.text == "{}" && $0.state == "completed" })
        XCTAssertLessThan(elapsed,100,"Begin/delta/replace/end must not rescan the preceding parts")
    }
    func testRepeatedEmptyCorrectionsDoNotRescanInterleavedParts() {
        var timeline=ResponseTimeline()
        for index in 0..<5000 { timeline.consume(part(index,0,index % 2 == 0 ? "text" : "reasoningText","append","x")) }
        timeline.consume(part(5000,0,"text","replace","corrected"))
        let event=part(5001,0,"text","replace","")
        let start=nowMS()
        var changes=0
        for _ in 0..<5000 { if timeline.consume(event) { changes += 1 } }
        let elapsed=nowMS()-start
        print("LIVE-CORRECTIONS segments=5001 replacements=5000 ms=\(elapsed)")
        XCTAssertEqual(changes,0); XCTAssertEqual(timeline.segments.count,5001)
        XCTAssertLessThan(elapsed,100,"Repeated corrections must not join the same earlier fragments again")
    }
    private typealias CanonicalPart = (kind:String,text:String,callID:String?,name:String?)
    /// The original algorithm is the equivalence oracle for legacy records.
    private func originalCanonical(_ parts: [CanonicalPart], sourceID: String) -> ResponseTimeline {
        var result=ResponseTimeline(); result.coverage="canonical"
        for (index,part) in parts.enumerated() {
            result.consumeOriginal(ResponsePartEvent(attemptID:"canonical:"+sourceID,ordinal:index,itemID:"part-\(index)",outputIndex:index,partIndex:0,kind:part.kind,update:"replace",text:part.text,callID:part.callID,name:part.name,evidence:"canonical"))
        }
        result.finishOriginal("completed"); return result
    }
    func testCanonicalMatchesOriginalAlgorithmForGeneratedParts() throws {
        let kinds=["text","reasoningText","reasoningSummary","opaque","toolArguments","correction","",":0:text"]
        let texts=["","plain","🙂\n漢字","e\u{301}","{}"]
        for count in [0,1,2,17,128] {
            let parts: [CanonicalPart]=(0..<count).map { index in
                (kinds[index % kinds.count],texts[(index / 3) % texts.count],index % 3 == 0 ? nil : "same-call",index % 2 == 0 ? "read" : nil)
            }
            for source in ["","legacy",":0:canonical:🙂"] {
                let actual=ResponseTimeline.canonical(parts,sourceID:source), expected=originalCanonical(parts,sourceID:source)
                XCTAssertEqual(actual,expected)
                XCTAssertTrue(actual.supported)
                XCTAssertEqual(try JSON.parse(JSONEncoder().encode(actual)),try JSON.parse(JSONEncoder().encode(expected)))
            }
        }
    }
    func testFiveThousandLegacyPartsCanonicalizeWithinPagingBudget() {
        let parts: [CanonicalPart]=(0..<5000).map { ("toolArguments","{}", "call-\($0)","read") }
        let start=nowMS(), timeline=ResponseTimeline.canonical(parts,sourceID:"generated")
        let elapsed=nowMS()-start
        print("LEGACY-CANONICAL parts=5000 ms=\(elapsed)")
        XCTAssertEqual(timeline.segments.count,5000)
        XCTAssertLessThan(elapsed,2000,"One legacy row must not stall history paging")
    }

    private func text(_ index: Int, _ text: String) -> JSON { ["type":"response.output_text.delta","item_id":JSON("m\(index)"),"output_index":JSON(index),"content_index":0,"delta":JSON(text)] }
    func testInterleavedPartsKeepObservedOrderThroughCanonicalCompletion() {
        var adapter=ProviderDisplayEvents(api:"openai-responses",attempt:"attempt")
        _=adapter.consume(text(0,"First "),at:1)
        _=adapter.consume(["type":"response.reasoning_summary_text.delta","output_index":1,"item_id":"r","summary_index":0,"sequence_number":7,"delta":"Returned summary"],at:2)
        _=adapter.consume(text(0,"continued"),at:3)
        _=adapter.consume(["type":"response.output_item.added","output_index":2,"item":["id":"fc","type":"function_call","call_id":"same","name":"read","arguments":""]],at:4)
        _=adapter.consume(["type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc","delta":"{}"],at:5)
        let before=adapter.timeline.segments.map(\.id)
        XCTAssertEqual(adapter.timeline.segments.map(\.part.kind),["text","reasoningSummary","text","toolArguments"])
        XCTAssertEqual(adapter.timeline.segments.map(\.text),["First ","Returned summary","continued","{}"])
        XCTAssertEqual(adapter.timeline.segments[1].part.providerSequence,7)
        _=adapter.consume(["type":"response.completed","response":["status":"completed","output":[
            ["type":"message","id":"m0","content":[["type":"output_text","text":"First continued"]]],
            ["type":"reasoning","id":"r","summary":[["type":"summary_text","text":"Returned summary"]]],
            ["type":"function_call","id":"fc","call_id":"same","name":"read","arguments":"{}"]]]],at:6)
        XCTAssertEqual(adapter.timeline.segments.map(\.id),before)
        XCTAssertEqual(adapter.timeline.segments.map(\.text),["First ","Returned summary","continued","{}"])
        XCTAssertEqual(adapter.timeline.terminal,"completed")
    }
    func testReasoningFirstMultipartAndTerminalCorrectionStayLocal() {
        var adapter=ProviderDisplayEvents(api:"openai-responses",attempt:"a")
        _=adapter.consume(["type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":1,"delta":"Summary"],at:1)
        _=adapter.consume(text(1,"Draft"),at:2)
        let ids=adapter.timeline.segments.map(\.id)
        _=adapter.consume(["type":"response.output_text.done","output_index":1,"content_index":0,"text":"Corrected"],at:3)
        XCTAssertEqual(adapter.timeline.segments.prefix(2).map(\.id),ids)
        XCTAssertEqual(adapter.timeline.segments.last?.part.kind,"correction")
        XCTAssertEqual(adapter.timeline.segments.last?.text,"Corrected")
        XCTAssertEqual(adapter.timeline.segments.first?.part.partIndex,1)
    }
    func testAnthropicOpaqueSignatureNeverBecomesInventedThinking() throws {
        var adapter=ProviderDisplayEvents(api:"anthropic-messages",attempt:"a"), accumulator=ProviderAccumulator(api:"anthropic-messages")
        let events:[JSON]=[
            ["type":"message_start","message":["type":"message"]],
            ["type":"content_block_start","index":0,"content_block":["type":"text","text":"Answer"]],
            ["type":"content_block_stop","index":0],
            ["type":"content_block_start","index":1,"content_block":["type":"thinking","thinking":"Returned reasoning"]],
            ["type":"content_block_delta","index":1,"delta":["type":"signature_delta","signature":"secret-opaque-signature"]],
            ["type":"content_block_stop","index":1],
            ["type":"content_block_start","index":2,"content_block":["type":"redacted_thinking","data":"opaque"]],
            ["type":"content_block_stop","index":2],
            ["type":"message_delta","delta":["stop_reason":"end_turn"]], ["type":"message_stop"]]
        for event in events { _=try accumulator.consume(event); _=adapter.consume(event,at:1) }
        XCTAssertEqual(adapter.timeline.segments.map(\.part.kind),["text","reasoningText","opaque"])
        XCTAssertFalse(adapter.timeline.segments.map(\.text).joined().contains("secret-opaque-signature"))
        XCTAssertEqual(try accumulator.result().message.providerItems?[1]["signature"].text,"secret-opaque-signature")
    }
    func testPreparationFailureHasNoExecutionAndDuplicateCallIDsHaveDistinctAttempts() throws {
        var a=ProviderDisplayEvents(api:"openai-responses",attempt:"a"), b=ProviderDisplayEvents(api:"openai-responses",attempt:"b"), accumulator=ProviderAccumulator(api:"openai-responses")
        let begin:JSON=["type":"response.output_item.added","output_index":0,"item":["type":"function_call","id":"fc","call_id":"same","name":"read","arguments":""]]
        _=try accumulator.consume(begin);_=a.consume(begin,at:1);_=b.consume(begin,at:1)
        _=a.consume(["type":"response.function_call_arguments.delta","output_index":0,"delta":"{"],at:2)
        XCTAssertThrowsError(try accumulator.result())
        XCTAssertEqual(a.timeline.segments[0].part.kind,"toolArguments")
        XCTAssertNotEqual(a.timeline.segments[0].id,b.timeline.segments[0].id)
    }
    func testProjectionKeepsEveryPartAndItsCompleteText() {
        var timeline=ResponseTimeline()
        timeline.consume(ResponsePartEvent(attemptID:"a",ordinal:0,itemID:"first",kind:"text",update:"append",text:String(repeating:"prefix 🙂 ",count:3000)))
        let first=timeline.projected().segments[0]
        for i in 1..<100 { timeline.consume(ResponsePartEvent(attemptID:"a",ordinal:i,itemID:"\(i)",kind:i%2==0 ? "toolArguments":"reasoningText",update:"append",text:"Part \(i)")) }
        XCTAssertEqual(timeline.projected().segments[0].text,first.text)
        XCTAssertEqual(timeline.projected().segments[0].id,first.id)
        XCTAssertEqual(timeline.segments.count,100)
        XCTAssertEqual(first.text,String(repeating:"prefix 🙂 ",count:3000))
        XCTAssertFalse(timeline.segments.contains(where: \.truncated))
        XCTAssertEqual(timeline.omittedEvents,0);XCTAssertEqual(timeline.coverage,"observed")
        XCTAssertTrue(timeline.segments.contains { $0.part.kind=="toolArguments" && $0.text=="Part 2" })
    }
    func testTimelineMetadataDoesNotChangeReplayOrUsage() throws {
        let profile=try fixtureProfile()
        var reply=answer("Answer").message
        let original=try ProviderClient.requestBody(profile:profile,messages:[reply],instructions:"stable",tools:[],sessionID:"s")
        reply.responseTimeline=ResponseTimeline.canonical([("text","Answer",nil,nil)],sourceID:reply.id)
        XCTAssertEqual(try ProviderClient.requestBody(profile:profile,messages:[reply],instructions:"stable",tools:[],sessionID:"s"),original)
        let restored=try ChatMessage(id:reply.id,pi:reply.pi)
        XCTAssertEqual(restored.responseTimeline,reply.responseTimeline)
    }
}

// Frozen pre-index reconciler: keep this independent of the production lookup path.
private extension ResponseTimeline {
    @discardableResult mutating func consumeOriginal(_ event: ResponsePartEvent) -> Bool {
        if event.update == "end" {
            var ended = false
            for index in segments.indices where segments[index].part.partKey == event.partKey && segments[index].state == "streaming" {
                segments[index].state = "completed"; segments[index].revision += 1; ended = true
            }
            // A second `.done` for a part already closed changes nothing.
            return ended
        }
        if event.update == "replace" {
            if let corrected=segments.last(where: { $0.part.kind == "correction" && $0.part.attemptID == event.attemptID && $0.part.reconcilesPartKey == event.partKey }), corrected.text == event.text { return false }
            let existing = segments.filter { $0.part.partKey == event.partKey }
            if !existing.isEmpty, existing.map(\.text).joined() == event.text { return false }
            if let index = segments.firstIndex(where: { $0.part.partKey == event.partKey }), existing.allSatisfy({ $0.text.isEmpty }) {
                segments[index].text=event.text
                segments[index].truncated=false
                segments[index].state="completed"; segments[index].revision += 1
                return true
            }
            if !existing.isEmpty {
                var correction = event; correction.kind = "correction"; correction.update = "begin"
                correction.evidence = "terminal-correction"; correction.reconcilesPartKey = event.partKey
                return consumeOriginal(correction)
            }
        }
        if event.update == "begin", segments.contains(where: { $0.part.partKey == event.partKey }), event.text.isEmpty { return false }
        if event.update == "append", event.text.isEmpty { return false }
        if let index = segments.indices.last, segments[index].part.partKey == event.partKey,
           segments[index].state == "streaming", event.update == "append" {
            segments[index].text += event.text
            segments[index].revision += 1
            return true
        }
        // A continuation is a new segment. The earlier native text owner no
        // longer has a streaming caret, even while its provider part is open.
        if let last = segments.indices.last, segments[last].state == "streaming" { segments[last].state = "continued"; segments[last].revision += 1 }
        var metadata = event; metadata.text = ""
        segments.append(Segment(id: "\(event.attemptID):\(event.ordinal)", part: metadata,
                                text: event.text,
                                state: event.update == "replace" ? "completed" : "streaming"))
        if event.evidence != "observed", coverage == "observed" { coverage = event.evidence }
        return true
    }
    mutating func finishOriginal(_ outcome: String) {
        terminal = outcome
        for index in segments.indices where segments[index].state == "streaming" { segments[index].state = outcome; segments[index].revision += 1 }
    }
}
