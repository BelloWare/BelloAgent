import XCTest
@testable import PiAgentCore

// Fixtures every test file in this target shares: a profile that points at a
// port nothing listens on, a temporary directory, a poll-until helper, and the
// scripted model, tool and MCP doubles. A fixture used by one file belongs in
// that file; these are here because several do.
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
    var replies:[ModelReply], holdFirst:Bool, requests:[[ChatMessage]]=[], purposes:[String]=[], profiles:[Profile]=[], instructions:[String]=[], keys:[String]=[]
    init(_ replies:[ModelReply],holdFirst:Bool=false) { self.replies=replies;self.holdFirst=holdFirst }
    func release() { holdFirst=false }
    var count:Int { requests.count }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        requests.append(messages);purposes.append(purpose);profiles.append(profile);self.instructions.append(instructions);keys.append(apiKey);let index=requests.count-1
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
