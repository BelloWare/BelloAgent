import XCTest
@testable import PiAgentCore

func fixtureProfile(_ api: String = "openai-responses") throws -> Profile {
    try Profile(["id":"test","revision":"1","providerId":"litellm","modelId":"fixture-model","api":JSON(api),"baseUrl":"http://127.0.0.1:12345/v1","contextWindow":100000,"maxOutputTokens":4096,"reasoning":true,"thinkingLevel":"default"])
}
func temporaryDirectory() throws -> URL {
    let path=FileManager.default.temporaryDirectory.appendingPathComponent("pi-native-tests-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
    return path
}
func eventually(_ predicate: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(nanoseconds:10_000_000) }
    XCTFail("Condition did not become true",file:file,line:line)
    throw AgentError("test_timeout","Condition did not become true")
}
func answer(_ text:String) -> ModelReply { ModelReply(message:ChatMessage(role:"assistant",content:[textBlock(text)]),usage:["input":100,"output":5,"inputIncludingCache":100]) }
func toolReply(_ names: [String]) -> ModelReply {
    let calls=names.enumerated().map { ToolCall(id:"call-\($0.offset)",name:$0.element,arguments:["value":JSON($0.offset)]) }
    var message=ChatMessage(role:"assistant",content:calls.map { ["type":"toolCall","id":JSON($0.id),"name":JSON($0.name),"arguments":$0.arguments] })
    message.providerItems=calls.map { ["type":"function_call","id":JSON("item-"+$0.id),"call_id":JSON($0.id),"name":JSON($0.name),"arguments":JSON($0.arguments.encoded())] }
    return ModelReply(message:message,calls:calls,usage:["input":100,"output":10])
}
actor ScriptClient: ModelClient {
    var replies:[ModelReply], holdFirst:Bool, requests:[[ChatMessage]]=[], purposes:[String]=[], profiles:[Profile]=[], instructions:[String]=[]
    init(_ replies:[ModelReply],holdFirst:Bool=false) { self.replies=replies;self.holdFirst=holdFirst }
    func release() { holdFirst=false }
    var count:Int { requests.count }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests.append(messages);purposes.append(purpose);profiles.append(profile);self.instructions.append(instructions);let index=requests.count-1
        while index==0 && holdFirst { try await Task.sleep(nanoseconds:5_000_000) }
        try Task.checkCancellation()
        guard index<replies.count else { throw AgentError("fixture_exhausted","Unexpected model request") }
        try await onDelta(.text(replies[index].message.text))
        return replies[index]
    }
}
actor RecordingTools: ToolExecuting {
    var calls:[String]=[]
    func definitions(readOnly:Bool)->[ToolDefinition] { [ToolDefinition("first","test",[:]),ToolDefinition("second","test",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON { calls.append(call.name);return resultText("done "+call.name) }
}
actor FakeMCP: MCPTransport {
    var calls:[JSON]=[],active=0,maximum=0,failCall=false
    func failNext() { failCall=true }
    func request(_ method:String,params:JSON) async throws -> JSON {
        if method=="initialize" { return ["protocolVersion":"2025-11-25","capabilities":["tools":[:]]] }
        if method=="tools/list" { return ["tools":[["name":"echo","description":"Echo","inputSchema":["type":"object","properties":["text":["type":"string"]]],"outputSchema":["type":"object"]]]] }
        guard method=="tools/call" else { throw AgentError("unexpected","Unexpected MCP method") }
        calls.append(params);active += 1;maximum=max(maximum,active);defer { active -= 1 }
        try await Task.sleep(nanoseconds:20_000_000)
        if failCall { failCall=false;throw AgentError("transport_lost","Outcome unknown") }
        return resultText(params["arguments"]["text"].text ?? "echo")
    }
    func notify(_ method:String,params:JSON) async throws {}
    func close() async {}
}

final class CoreTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha256(Data(repeating:97,count:1000000)),"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testJSONAndUTF16Pages() throws {
        let json:JSON=["boolean":true,"a":[1,"汉字🙂"],"null":.null]
        XCTAssertEqual(try JSON.parse(json.data()),json)
        let value=try textPage("a🙂b",offset:1)
        XCTAssertEqual(value["text"].text,"🙂b")
        XCTAssertThrowsError(try textPage("a🙂b",offset:2))
    }
    func testNDJSONSplitEveryByteAndTruncatedTail() throws {
        let source=Data("{\"text\":\"中文🙂\"}\n{\"a\":1}\n".utf8)
        var decoder=NDJSONDecoder(),result:[JSON]=[]
        for b in source { result += try decoder.feed(Data([b])) }
        try decoder.finish();XCTAssertEqual(result.count,2)
        XCTAssertEqual(result[0]["text"].text,"中文🙂")
        var incomplete=NDJSONDecoder();_ = try incomplete.feed(Data("{\"a\":1}".utf8));XCTAssertThrowsError(try incomplete.finish())
        var empty=NDJSONDecoder();XCTAssertThrowsError(try empty.feed(Data([10])))
    }
    func testSSEEverySplitIncludesCRLFAndUnicode() throws {
        let source=Data("\u{FEFF}event: delta\r\ndata: {\"text\":\"你好🙂\"}\r\n\r\ndata: first\ndata: second\n\n".utf8)
        for split in 0...source.count {
            var parser=SSEParser();let events=try parser.feed(Data(source.prefix(split)))+parser.feed(Data(source.dropFirst(split)))
            XCTAssertEqual(events.count,2,"split \(split)")
            XCTAssertEqual(events[0].data,"{\"text\":\"你好🙂\"}")
            XCTAssertEqual(events[1].data,"first\nsecond")
        }
    }
    func testSSEDoesNotInventTerminalOrInvalidUTF8() throws {
        var parser=SSEParser();XCTAssertTrue(try parser.feed(Data("data: unfinished".utf8)).isEmpty)
        var bad=SSEParser();XCTAssertThrowsError(try bad.feed(Data([100,97,116,97,58,32,255,10,10])))
    }
    func testEndpointsAndUnsafeURLs() throws {
        XCTAssertEqual(try fixtureProfile().endpoint.absoluteString,"http://127.0.0.1:12345/v1/responses")
        XCTAssertThrowsError(try fixtureProfile("anthropic-messages")) { XCTAssertEqual(($0 as? AgentError)?.code, "unsupported_api") }
        var raw=try fixtureProfile().raw;raw["baseUrl"]="http://remote.example/v1";XCTAssertThrowsError(try Profile(raw))
        raw["baseUrl"]="https://user:pass@example.com/v1";XCTAssertThrowsError(try Profile(raw))
    }
    func testResponsesOpaqueReplayAndUsage() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        let opaque:JSON=["type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque-test"]
        let item:JSON=["type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"README.md\"}"]
        _ = try accumulator.consume(["type":"response.completed","response":["status":"completed","output":.array([opaque,item]),"usage":["input_tokens":10,"output_tokens":8,"input_tokens_details":["cached_tokens":6],"output_tokens_details":["reasoning_tokens":3]]]])
        let reply=try accumulator.result();XCTAssertEqual(reply.calls.count,1);XCTAssertEqual(reply.calls[0].arguments["path"].text,"README.md")
        XCTAssertEqual(reply.usage["output"].int,8);XCTAssertEqual(reply.usage["inputIncludingCache"].int,10)
        var result=ChatMessage(role:"toolResult",content:[textBlock("hello")]);result.toolCallId="call_1"
        var raw=try fixtureProfile().raw
        raw["routing"]=["replayPolicy":"pinned","expectedModel":"fixture-actual","replayContract":"Fixture route is fixed and native-state compatible"]
        let profile=try Profile(raw)
        var message=reply.message
        message.providerIdentity=["status":"reported","effectiveModel":"fixture-actual"]
        message.providerBinding=try ProviderClient.replayBinding(profile)
        let body=try ProviderClient.requestBody(profile:profile,messages:[message,result],instructions:"test",tools:[],sessionID:"s")
        XCTAssertEqual(body["input"].list[0],opaque);XCTAssertEqual(body["input"].list[2]["call_id"].text,"call_1")
        XCTAssertEqual(body["include"], ["reasoning.encrypted_content"])
    }
    func testResponsesMalformedArgumentsAndAbsentTerminal() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        XCTAssertThrowsError(try accumulator.result())
        _ = try accumulator.consume(["type":"response.completed","response":["status":"completed","output":[["type":"function_call","call_id":"c","name":"read","arguments":"{" ]]]])
        XCTAssertThrowsError(try accumulator.result())
    }
    func testMessagesStreamingSignaturesAndCumulativeUsage() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        let events:[JSON]=[
            ["type":"message_start","message":["type":"message","usage":["input_tokens":5,"output_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3]]],
            ["type":"content_block_start","index":0,"content_block":["type":"thinking","thinking":"","signature":""]],
            ["type":"content_block_delta","index":0,"delta":["type":"thinking_delta","thinking":"visible"]],
            ["type":"content_block_delta","index":0,"delta":["type":"signature_delta","signature":"opaque-sig"]],
            ["type":"content_block_stop","index":0],
            ["type":"content_block_start","index":1,"content_block":["type":"tool_use","id":"tool1","name":"read","input":[:]]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"{\"path\":"]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"\"a\"}"]],
            ["type":"content_block_stop","index":1],
            ["type":"message_delta","delta":["stop_reason":"tool_use"],"usage":["output_tokens":9]],
            ["type":"message_stop"]]
        for event in events { _ = try a.consume(event) }
        let reply=try a.result();XCTAssertEqual(reply.usage["output"].int,9);XCTAssertEqual(reply.usage["inputIncludingCache"].int,10)
        XCTAssertEqual(reply.message.providerItems?[0]["signature"].text,"opaque-sig")
        XCTAssertEqual(reply.calls[0].arguments["path"].text,"a")
    }
    func testMessagesUnfinishedToolBlockIsNotExecuted() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        _ = try a.consume(["type":"content_block_start","index":0,"content_block":["type":"tool_use","id":"t","name":"read","input":[:]]])
        _ = try a.consume(["type":"content_block_delta","index":0,"delta":["type":"input_json_delta","partial_json":"{"]])
        XCTAssertThrowsError(try a.consume(["type":"message_stop"]))
    }
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
    func testCodexInstructionsExplicitSkillAndRevocation() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let cwd=root.appendingPathComponent("repo/sub"),home=root.appendingPathComponent("home"),skill=home.appendingPathComponent(".codex/skills/review")
        for p in [cwd,root.appendingPathComponent("repo/.git"),skill.appendingPathComponent("agents")] { try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true) }
        try Data("GLOBAL".utf8).write(to:home.appendingPathComponent(".codex/AGENTS.md"))
        try Data("ROOT".utf8).write(to:root.appendingPathComponent("repo/AGENTS.md"))
        try Data("IGNORED".utf8).write(to:cwd.appendingPathComponent("AGENTS.md"))
        try Data("OVERRIDE".utf8).write(to:cwd.appendingPathComponent("AGENTS.override.md"))
        try Data("---\nname: review\ndescription: Review files\n---\nDo the review.".utf8).write(to:skill.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to:skill.appendingPathComponent("agents/openai.yaml"))
        let resources=Resources(cwd:cwd,home:home),snapshot=try await resources.resolve()
        XCTAssertTrue(snapshot.prompt.contains("GLOBAL"));XCTAssertTrue(snapshot.prompt.contains("ROOT"));XCTAssertTrue(snapshot.prompt.contains("OVERRIDE"));XCTAssertFalse(snapshot.prompt.contains("IGNORED"))
        XCTAssertEqual(snapshot.skills.count,1);XCTAssertEqual(snapshot.skills[0]["policy"].text,"explicitOnly");XCTAssertFalse(snapshot.prompt.contains("Review files"))
        var selection=snapshot.skills[0];selection["intent"]="leading-command";selection["arguments"]="changes"
        let frozen=try await resources.freeze([selection],text:"",tools:[])
        XCTAssertEqual(frozen.count,1)
        try await resources.configure(["disabled":[snapshot.skills[0]["id"]]])
        do { try await resources.validate(frozen);XCTFail("Revoked skill was accepted") } catch {}
    }
    func testMetadataDuplicateAndAliasFailClosed() throws {
        var a=try MetadataYAML("policy:\n  allow_implicit_invocation: true\n  allow_implicit_invocation: false\n");XCTAssertThrowsError(try a.parse())
        var b=try MetadataYAML("name: &anchor abc\n");XCTAssertThrowsError(try b.parse())
    }
    func testMCPListDescribeSerialInvokeAndUnknownOutcome() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let manager=MCPManager(cwd:root),transport=FakeMCP();await manager.installForTesting(name:"test",transport:transport)
        let list=try await manager.perform(["action":"list","server":"test"])
        XCTAssertTrue(list["tools"].list[0]["inputSchema"].isNull)
        let schema=try await manager.perform(["action":"describe","targets":[["server":"test","tool":"echo"],["server":"test","tool":"echo"]]])
        XCTAssertEqual(schema["tools"].list.count,2);XCTAssertEqual(schema["tools"].list[0]["schema"]["inputSchema"]["type"].text,"object")
        try await withThrowingTaskGroup(of:JSON.self) { group in
            for i in 0..<5 { group.addTask { try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":["text":JSON(String(i))]]) } }
            for try await _ in group {}
        }
        let maximum=await transport.maximum;XCTAssertEqual(maximum,1)
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]],readOnly:true);XCTFail("Readonly invocation accepted") } catch {}
        do { _ = try await manager.perform(["action":"invoke","targets":[]]);XCTFail("Batch accepted") } catch {}
        await transport.failNext()
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Failure expected") } catch {}
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Unknown outcome did not quarantine") } catch { XCTAssertEqual((error as? AgentError)?.code,"mcp_outcome_unknown") }
        try await manager.acknowledgeUnknown()
        _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]])
    }
    func testSteeringBeforeFollowUpAndCompleteToolBatch() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([toolReply(["first","second"]),answer("steered"),answer("followup")],holdFirst:true),tools=RecordingTools(),traces=TraceStore()
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"initial"),steer:false)
        try await eventually { await client.count==1 }
        _ = try await session.submit(Submission(commandID:"c2",turnID:"t2",text:"queued"),steer:false)
        _ = try await session.submit(Submission(commandID:"c3",turnID:"t3",text:"steer"),steer:true)
        await client.release();try await eventually { !(await session.isRunning) }
        let requests=await client.requests,executed=await tools.calls
        XCTAssertEqual(executed,["first","second"]);XCTAssertEqual(requests.count,3)
        XCTAssertEqual(requests[1].filter{$0.role=="user"}.map(\.text),["initial","steer"])
        XCTAssertEqual(requests[1].filter{$0.role=="toolResult"}.count,2)
        XCTAssertEqual(requests[2].filter{$0.role=="user"}.map(\.text),["initial","steer","queued"])
        await session.close()
    }
    func testCancelPausesQueueAndResumeDoesNotReplayInitialRequest() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer("cancelled"),answer("queued result")],holdFirst:true),tools=RecordingTools(),traces=TraceStore()
        let s=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await s.submit(Submission(commandID:"a",turnID:"a",text:"first"),steer:false);try await eventually { await client.count==1 }
        _ = try await s.submit(Submission(commandID:"b",turnID:"b",text:"second"),steer:false)
        await s.stop();try await eventually { !(await s.isRunning) }
        let paused=await s.snapshot();XCTAssertEqual(paused["queueCount"].int,1);XCTAssertEqual(paused["state"].text,"paused")
        await client.release();try await s.resumeQueue();try await eventually { !(await s.isRunning) }
        let requests=await client.requests;XCTAssertEqual(requests.count,2);XCTAssertEqual(requests[1].filter{$0.role=="user"}.map(\.text),["first","second"])
        await s.close()
    }
    func testTruncatedCallsAreNotExecutedAndSideSnapshotIsIndependent() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        var cut=toolReply(["first"]);cut.truncated=true
        let client=ScriptClient([cut,answer("recovered")]),tools=RecordingTools(),traces=TraceStore()
        let s=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await s.submit(Submission(commandID:"a",turnID:"a",text:"hello"),steer:false);try await eventually { !(await s.isRunning) }
        let calls=await tools.calls;XCTAssertTrue(calls.isEmpty)
        let seed=await s.sideSeed(),sideClient=ScriptClient([answer("side result")])
        let side=try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:sideClient,tools:tools,traces:traces,seed:seed.messages,parent:seed.info,autoCompaction:false)
        _ = try await side.submit(Submission(commandID:"s1",turnID:"s1",text:"side question"),steer:false);try await eventually { !(await side.isRunning) }
        let parent=await s.snapshot();XCTAssertFalse(parent["messages"].encoded().contains("side question"))
        let saved=try await side.keep(whenFinished:false);XCTAssertNotNil(saved["path"].text)
        await side.close();await s.close()
    }
    func testNativeShellAndFileTools() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let tools=NativeTools(cwd:root,outputs:root.appendingPathComponent("out"),mcp:MCPManager(cwd:root))
        let written = try await tools.invoke(ToolCall(id:"w",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        XCTAssertEqual(written["stats"]["added"].int, 1); XCTAssertEqual(written["stats"]["removed"].int, 0)
        XCTAssertEqual(written["stats"]["path"].text, root.resolvingSymlinksInPath().appendingPathComponent("file.txt").path)
        let read=try await tools.invoke(ToolCall(id:"r",name:"read",arguments:["path":"file.txt"]),readOnly:true)
        XCTAssertTrue(read.encoded().contains("abc"))
        let edited = try await tools.invoke(ToolCall(id:"e2",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"line one\nline two"]),readOnly:false)
        XCTAssertEqual(edited["stats"]["added"].int, 2, "the replaced line became two"); XCTAssertEqual(edited["stats"]["removed"].int, 1)
        XCTAssertTrue(edited["content"].list.first?["text"].text?.contains("(+2 -1)") ?? false)
        _ = try await tools.invoke(ToolCall(id:"w2",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        do { _ = try await tools.invoke(ToolCall(id:"e",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"x"]),readOnly:true);XCTFail("Readonly edit accepted") } catch {}
        let shell=try await tools.invoke(ToolCall(id:"b",name:"bash",arguments:["command":"printf hello; printf error >&2","timeout":2]),readOnly:false)
        XCTAssertTrue(shell.encoded().contains("hello"));XCTAssertTrue(shell.encoded().contains("error"))
    }
}


extension CoreTests {
    func testMCPUnknownOutcomeSurvivesManagerRestart() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let marker=folder.appendingPathComponent("unknown.json"),first=MCPManager(cwd:folder,outcomeMarker:marker),transport=FakeMCP()
        await first.installForTesting(name:"test",transport:transport);await transport.failNext()
        do { _=try await first.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Expected transport failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        let second=MCPManager(cwd:folder,outcomeMarker:marker);await second.installForTesting(name:"test",transport:FakeMCP())
        let list=try await second.perform(["action":"list"]);XCTAssertEqual(list["outcomeUnknown"].flag,true)
        do { _=try await second.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Must remain blocked") }
        catch let error as AgentError { XCTAssertEqual(error.code,"mcp_outcome_unknown") }
        try await second.acknowledgeUnknown();XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        _=try await second.perform(["action":"invoke","server":"test","tool":"echo","arguments":["text":"once"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testShellTimeoutTerminatesOrphanHoldingPipes() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let start=nowMS()
        let result=try await ShellRun(command:"sleep 4 & exit 0",cwd:folder,outputDirectory:folder,onUpdate:{_ in}).run(timeoutSeconds:1)
        XCTAssertLessThan(nowMS()-start,3500,"Descendants must not keep the result hanging after timeout")
        XCTAssertEqual(result["isError"].flag,true,"A timeout is a failed tool result the model can act on, not a cancellation")
        XCTAssertTrue(result["content"].list.first?["text"].text?.contains("timed out after 1 seconds") ?? false)
    }
    func testMCPConfigurationComesFromPrivateIPCAndRejectsExternalFiles() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("mcp.json"),initial=Data("{\"servers\":{}}".utf8)
        try initial.write(to:file)
        let host=NativeHostService(emit:{_ in})
        _=try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(folder.path),"directory":JSON(folder.appendingPathComponent("state").path),"mcp":["servers":[:]]])
        do { _=try await host.command("mcp.configure",sessionID:nil,params:["path":JSON(file.path)]); XCTFail("External files must be rejected") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "vault_configuration_required") }
        let approved=try await host.command("mcp.configure",sessionID:nil,params:["config":["servers":[:]]])
        XCTAssertEqual(approved["configurationSource"].text,"native vault via private IPC")
        XCTAssertEqual(try Data(contentsOf:file),initial);await host.shutdown()
    }

}

extension CoreTests {
    func testLiteLLMOnlyCredentialsAndEndpointRoutes() throws {
        let original = try fixtureProfile().raw
        let leaf = "responses"
        for prefix in ["", "/prefix"] {
            var value = original; value["baseUrl"] = JSON("https://gateway.example" + prefix + "/" + leaf)
            XCTAssertEqual(try Profile(value).endpoint.path, prefix + "/" + leaf)
        }
        for route in ["/v1/v1", "/chat/completions", "/a%2fb", "/a/../b", "/messages/responses"] {
            var value = original; value["baseUrl"] = JSON("https://gateway.example" + route)
            XCTAssertThrowsError(try Profile(value))
        }
        XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(original), supplied: nil))
        for field in ["source", "apiKeyEnv", "authHeader"] {
            var value = original; value[field] = "external-reference"
            XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(value), supplied: "synthetic"))
        }
        var direct = original; direct["providerId"] = "openai"
        XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(direct), supplied: "synthetic"))
        for separator in ["\r", "\n", "\r\n", "\0"] {
            XCTAssertThrowsError(try ProfileFiles.credentials(profile: Profile(original), supplied: "synthetic" + separator + "injection"))
        }
    }
    func testInvalidWorkspaceConfigurationCannotPartiallyBindAHost() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeHostService(emit: { _ in })
        var parameters: JSON = ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("first-state").path), "mcp": ["servers": ["bad": ["transport": "stdio", "command": "/usr/bin/true", "inheritEnv": ["SECRET"]]]]]
        do { _ = try await host.command("workspace.open", sessionID: nil, params: parameters); XCTFail("Reject inherited credentials") } catch { }
        parameters["directory"] = JSON(root.appendingPathComponent("second-state").path)
        parameters["mcp"] = ["servers": [:]]
        let opened = try await host.command("workspace.open", sessionID: nil, params: parameters)
        XCTAssertEqual(opened["directory"].text, root.appendingPathComponent("second-state").path)
        parameters["resources"] = ["mcpConfigPath": "retired.json"]
        do { _ = try await host.command("workspace.open", sessionID: nil, params: parameters); XCTFail("Even already-open hosts reject retired configuration") } catch { }
        await host.shutdown()
    }
    func testMCPConfigurationRejectsHeaderInjectionAndAmbiguousTransports() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = MCPManager(cwd: root)
        for config: JSON in [
            ["url": "https://gateway.example/mcp", "headers": ["x-test": "ok\r\ninjected"]],
            ["url": "https://gateway.example/mcp", "headers": ["Transfer-Encoding": "chunked"]],
            ["command": "/usr/bin/true", "env": ["INVALID=KEY": "value"]],
            ["transport": "stdio", "command": "/usr/bin/true", "url": "https://gateway.example/mcp"]
        ] {
            do { try await manager.configure(["servers": ["fixture": config]]); XCTFail("Invalid explicit configuration must fail before connecting") } catch { }
        }
        let names = await manager.serverNames(); XCTAssertTrue(names.isEmpty)
    }
    func testCompactionReceiptAndNativeResumePreserveSummary() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"),profile=try fixtureProfile(),resources=Resources(cwd:root,home:root),traces=TraceStore()
        let client=ScriptClient([answer("first answer"),answer("second answer"),answer("Summary: first task was completed.")])
        let s=try AgentSession(id:"compact-session",profile:profile,apiKey:"test",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first question"),steer:false)
        try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"second question"),steer:false)
        try await eventually { !(await s.isRunning) }
        try await s.compact(commandID:"manual-compact")
        try await eventually { !(await s.isRunning) }
        let snapshot=await s.snapshot(),path=await s.path
        XCTAssertEqual(snapshot["commands"].list.last?["commandId"].text,"manual-compact")
        XCTAssertEqual(snapshot["commands"].list.last?["state"].text,"completed")
        await s.close()
        let next=ScriptClient([answer("continued")])
        let resumed=try AgentSession(id:"compact-session",profile:profile,apiKey:"test",cwd:root,directory:state,readOnly:true,resources:resources,client:next,tools:RecordingTools(),traces:traces,resumePath:path,autoCompaction:false)
        _=try await resumed.submit(Submission(commandID:"c3",turnID:"t3",text:"continue"),steer:false)
        try await eventually { !(await resumed.isRunning) }
        let request=await next.requests[0]
        XCTAssertTrue(request.contains{$0.text.contains("Summary: first task was completed.")})
        XCTAssertTrue(request.contains{$0.text=="second question"})
        XCTAssertFalse(request.contains{$0.text=="first question"})
        await resumed.close()
    }
}
