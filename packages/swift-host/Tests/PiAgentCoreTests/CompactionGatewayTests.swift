import XCTest
@testable import PiAgentCore

private actor GoldenCompactionTools: ToolExecuting {
    let root: URL
    private(set) var calls: [String]=[]
    init(_ root:URL) { self.root=root }
    func definitions(readOnly:Bool) -> [ToolDefinition] {
        [ToolDefinition("write","Append the counter once",["type":"object","properties":["path":["type":"string"],"content":["type":"string"]],"required":["path","content"]]),
         ToolDefinition("read","Read deterministic evidence",["type":"object","properties":["part":["type":"integer"]],"required":["part"]])]
    }
    func invoke(_ call:ToolCall,readOnly:Bool) throws -> JSON {
        calls.append(call.name)
        if call.name=="write" {
            guard call.arguments == ["path":"counter.txt","content":"once\n"] else { throw AgentError("fixture_contract","Invalid mutation arguments") }
            let path=root.appendingPathComponent("counter.txt")
            var data=(try? Data(contentsOf:path)) ?? Data();data.append(Data("once\n".utf8));try data.write(to:path)
            return resultText("COUNTER_APPENDED_ONCE")
        }
        guard call.name=="read", let part=call.arguments["part"].int, [1,2,3].contains(part) else { throw AgentError("fixture_contract","Invalid read arguments") }
        return resultText("READ_STAGE_COMPLETE part \(part) "+String(repeating:"observed ",count:part==3 ? 300:1800))
    }
}

final class CompactionGatewayTests: XCTestCase {
    func testStreamingChainedSummaryAndOutputExhaustionRetainEveryAttemptAndEffort() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        var repo=URL(fileURLWithPath:#filePath);for _ in 0..<5 { repo.deleteLastPathComponent() }
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=[repo.appendingPathComponent("fixtures/native/compaction_gateway.py").path,root.path]
        server.standardOutput=FileHandle.nullDevice;server.standardError=FileHandle.nullDevice;try server.run()
        defer { stopFixtureProcess(server) }
        let ready=root.appendingPathComponent("ready.json");try await eventually { FileManager.default.fileExists(atPath:ready.path) }
        let port=try XCTUnwrap(JSON.parse(Data(contentsOf:ready))["port"].int)
        var raw=try fixtureProfile().raw;raw["baseUrl"]=JSON("http://127.0.0.1:\(port)");raw["contextWindow"]=16000;raw["modelOutputLimit"]=32768;raw["thinkingLevel"]="high"
        var user=ChatMessage(role:"user",content:[textBlock("Preserve the objective.")]);user.id="root";user.taskRootID="root"
        // Two answers of 6,750 tokens each: more than one 16,000-token request can summarize.
        let seed=[user]+(0..<2).map { _ in var evidence=ChatMessage(role:"assistant",content:[textBlock(String(repeating:"observed ",count:3000))]);evidence.taskRootID="root";return evidence }
        let traces=TraceStore()
        func attempts(_ id: String) async throws -> [JSON] { try await traces.command("debug.list",session:id,params:[:])["attempts"].list }
        func records() throws -> [JSON] { try String(contentsOf:root.appendingPathComponent("records.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) } }
        // A body longer than one 32,768-byte page is read page by page.
        func body(_ id: String, _ attempt: JSON, _ which: String) async throws -> Data {
            var data=Data(), offset: JSON=0
            while true {
                let page=try await traces.command("debug.body",session:id,params:["attemptId":attempt["attemptId"],"body":JSON(which),"offset":offset])
                data.append(Data(base64Encoded:page["bytes"].text ?? "") ?? Data())
                guard !page["next"].isNull else { return data }
                offset=page["next"]
            }
        }
        func captured(_ id: String, _ attempt: JSON) async throws {
            let request=try await body(id,attempt,"request").base64EncodedString(), response=try await body(id,attempt,"response").base64EncodedString()
            XCTAssertTrue(try records().contains { $0["request"].text==request && $0["response"].text==response })
            XCTAssertFalse(attempt["operation"]["lastAttempt"].isNull)
        }

        let s=try AgentSession(id:"compaction-budget",profile:Profile(raw),apiKey:"synthetic-compaction-key",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ProviderClient(traces:traces),tools:RecordingTools(),traces:traces,seed:seed)
        try await s.compact();try await eventually { !(await s.isRunning) }
        let state=await s.snapshot(),context=await s.context,chained=try await attempts("compaction-budget")
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(context.first?.kind,"compaction");XCTAssertTrue(context.filter { $0.role=="user" }.isEmpty,"Pi replays no input verbatim")
        XCTAssertGreaterThan(chained.count,1,"Each chunk updates the summary so far, each packed to leave its summary room")
        XCTAssertTrue(try records().allSatisfy { $0["status"].int==200 })
        var output=0
        for attempt in chained { try await captured("compaction-budget",attempt); output += attempt["usage"]["output"].int ?? 0 }
        let total=await s.cumulativeUsage
        XCTAssertEqual(total.output,output);XCTAssertEqual(state["compaction"]["attemptOutcomes"].list.count,chained.count)
        XCTAssertTrue(state["requestObservation"].isNull,"Summary usage must not replace normal-request context usage")
        let operations = await s.history.filter { $0.kind == "execution" && $0.operationID != nil }
        XCTAssertEqual(operations.count,1)
        let operation = try XCTUnwrap(operations.first)
        XCTAssertEqual(operation.responseTimeline?.terminal,"completed")
        XCTAssertEqual(operation.operationID,context.first?.operationID)
        XCTAssertTrue(operation.responseTimeline?.segments.contains { $0.part.kind == "text" && !$0.text.isEmpty } == true)
        XCTAssertTrue(operation.responseTimeline?.segments.contains { $0.part.kind == "status" && $0.text.contains("validated") } == true)
        XCTAssertGreaterThan(operation.responseTimeline?.segments.filter { $0.part.kind == "status" }.count ?? 0,4)
        let retained = try await s.messageRead(id:operation.id,field:"text",offset:0)
        XCTAssertTrue(retained["text"].text?.contains("Timeline evidence") == true)
        await s.close()

        // A summary stopped at the model's output limit is incomplete and never a checkpoint.
        let exhausted=try AgentSession(id:"compaction-budget-exhausted",profile:Profile(raw),apiKey:"synthetic-compaction-key",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ProviderClient(traces:traces),tools:RecordingTools(),traces:traces,seed:seed)
        try await exhausted.compact();try await eventually { !(await exhausted.isRunning) }
        let failed=await exhausted.snapshot(),unchanged=await exhausted.context,stopped=try await attempts("compaction-budget-exhausted")
        XCTAssertEqual(failed["compaction"]["errorCode"].text,"compaction_output_exhausted")
        XCTAssertEqual(unchanged.map(\.id),seed.map(\.id));XCTAssertEqual(stopped.count,1)
        for attempt in stopped { try await captured("compaction-budget-exhausted",attempt) }
        XCTAssertEqual(failed["compaction"]["lastAttempt"]["reason"].text,"max_output_tokens")
        // The whole limit the request carried went to reasoning.
        let spent=await exhausted.cumulativeUsage;XCTAssertEqual(spent.output,stopped.first?["usage"]["output"].int ?? -1)
        await exhausted.close()
    }
    func testOneTaskCompactsRecoversAgainstIndependentGatewayAndReopensWithoutRepeatingTools() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        var repo=URL(fileURLWithPath:#filePath);for _ in 0..<5 { repo.deleteLastPathComponent() }
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=[repo.appendingPathComponent("fixtures/native/compaction_gateway.py").path,root.path]
        server.standardOutput=FileHandle.nullDevice;server.standardError=FileHandle.nullDevice;try server.run()
        defer { stopFixtureProcess(server) }
        let ready=root.appendingPathComponent("ready.json")
        try await eventually { FileManager.default.fileExists(atPath:ready.path) }
        let port=try XCTUnwrap(JSON.parse(Data(contentsOf:ready))["port"].int)
        var raw=try fixtureProfile().raw;raw["baseUrl"]=JSON("http://127.0.0.1:\(port)");raw["contextWindow"]=8000;raw["maxOutputTokens"]=512
        let profile=try Profile(raw),traces=TraceStore(),tools=GoldenCompactionTools(root),state=root.appendingPathComponent("state")
        let s=try AgentSession(id:"compaction-golden",profile:profile,apiKey:"synthetic-compaction-key",cwd:root,directory:state,readOnly:false,resources:Resources(cwd:root,home:root),client:ProviderClient(traces:traces),tools:tools,traces:traces)
        let sibling=try AgentSession(id:"compaction-sibling",profile:profile,apiKey:"synthetic-compaction-key",cwd:root,directory:state,readOnly:true,resources:Resources(cwd:root,home:root),client:ProviderClient(traces:traces),tools:tools,traces:traces)
        _=try await s.submit(Submission(commandID:"root",turnID:"root",text:"ORIGINAL GOLDEN OBJECTIVE: append the counter once, inspect both reads, finish."),steer:false)
        _=try await sibling.submit(Submission(commandID:"sibling",turnID:"sibling",text:"sibling independent"),steer:false)
        try await eventually { let a=await s.isRunning,b=await sibling.isRunning;return !a && !b }
        let snapshot=await s.snapshot(),other=await sibling.snapshot(),context=await s.context,path=await s.path!
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded());XCTAssertEqual(other["state"].text,"idle",other["preflightError"].encoded())
        XCTAssertEqual(snapshot["messages"].list.last?["text"].text,"Golden complete without repeated effects")
        XCTAssertEqual(snapshot["queueCount"].int,0)
        XCTAssertTrue(snapshot["taskPresentation"]["active"].isNull)
        XCTAssertEqual(snapshot["taskPresentation"]["recent"].list.count,1,"Automatic compaction/recovery never create another task")
        XCTAssertEqual(snapshot["taskPresentation"]["recent"].list.first?["issuedCalls"].int,4)
        XCTAssertEqual(snapshot["taskPresentation"]["recent"].list.first?["outcome"].text,"completed")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("counter.txt"),encoding:.utf8),"once\n")
        let called=await tools.calls;XCTAssertEqual(called,["write","read","read","read"])
        let journal=try String(contentsOf:URL(fileURLWithPath:path),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(journal.filter { $0["type"].text=="compaction" }.count,2)
        XCTAssertEqual(journal.filter { $0["customType"].text=="pi-app.context-recovery.v1" }.count,1)
        let attempts=try await traces.command("debug.list",session:"compaction-golden",params:[:])["attempts"].list
        let records=try String(contentsOf:root.appendingPathComponent("records.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }.filter { $0["session"].text=="compaction-golden" }
        // Two turns, the threshold summary, the third read, its rejected
        // request, the recovery summary and the final answer.
        XCTAssertEqual(attempts.count,7);XCTAssertEqual(records.filter { $0["status"].int==400 }.count,1);XCTAssertFalse(records.contains { $0["status"].int==422 })
        for attempt in attempts {
            let request=try await traces.command("debug.body",session:"compaction-golden",params:["attemptId":attempt["attemptId"],"body":"request"])
            let response=try await traces.command("debug.body",session:"compaction-golden",params:["attemptId":attempt["attemptId"],"body":"response"])
            XCTAssertTrue(records.contains { $0["request"]==request["bytes"] && $0["response"]==response["bytes"] },"Raw HTTP bytes must match; normalized events are not capture")
            XCTAssertFalse(attempt["operation"].isNull,"Every physical attempt has operation linkage")
        }
        let defs=await s.sessionDefinitions(),request=try ProviderClient.requestBody(profile:profile,messages:context,instructions:"",tools:defs,sessionID:"compaction-golden")
        XCTAssertNoThrow(try CompactionPlanner.validateRequest(request))
        let originalHistory = await s.history
        let ordered = originalHistory.filter { $0.responseTimeline != nil }
        XCTAssertFalse(ordered.isEmpty)
        for message in ordered where message.kind == nil {
            XCTAssertTrue(message.responseTimeline!.segments.allSatisfy { $0.part.sessionOrdinal != nil })
        }
        let presentation = originalHistory.filter { ["execution", "requestLedger"].contains($0.kind ?? "") }
        XCTAssertTrue(presentation.allSatisfy { !$0.replayEligible })
        XCTAssertTrue(context.allSatisfy { !["execution", "requestLedger"].contains($0.kind ?? "") })
        for operation in presentation where operation.operationID != nil {
            XCTAssertEqual(operation.responseTimeline?.terminal,"completed")
            let start = try XCTUnwrap(originalHistory.firstIndex { $0.id == operation.id })
            let adopted = try XCTUnwrap(originalHistory.firstIndex { $0.kind == "compaction" && $0.operationID == operation.operationID })
            XCTAssertLessThan(start,adopted,"Operation is located before adoption, not relocated to the summary's replay position")
        }
        await s.close();await sibling.close()
        let noReplay=ScriptClient([]),reopened=try AgentSession(id:"compaction-golden",profile:profile,apiKey:"synthetic-compaction-key",cwd:root,directory:state,readOnly:false,resources:Resources(cwd:root,home:root),client:noReplay,tools:tools,traces:traces,resumePath:path)
        let restored=await reopened.context,calls=await noReplay.count
        XCTAssertEqual(restored.map(\.id),context.map(\.id));XCTAssertEqual(restored.map(\.text),context.map(\.text));XCTAssertEqual(calls,0)
        let historyAfter = await reopened.history.filter { $0.responseTimeline != nil }
        XCTAssertEqual(historyAfter.map(\.id),ordered.map(\.id))
        XCTAssertEqual(historyAfter.map(\.responseTimeline),ordered.map(\.responseTimeline))
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("counter.txt"),encoding:.utf8),"once\n")
        await reopened.close()
    }
}
