import XCTest
@testable import PiAgentCore

final class CompactionRequestShapeTests: XCTestCase {
    func testPrefixEqualityWithReasoningImagesToolsAndSideAffinity() throws {
        var raw=try fixtureProfile().raw
        raw["reasoning"]=true; raw["thinkingLevel"]="high"; raw["input"]=["text","image"]
        raw["modelOutputLimit"]=100000
        raw["routing"]=["replayPolicy":"pinned","expectedModel":"fixture-model","replayContract":"synthetic fixed route"]
        raw["samplingParams"]=["temperature":0.5,"prompt_cache_retention":"24h","text":["verbosity":"low","format":["type":"text"]]]
        let profile=try Profile(raw), policy=CompactionPolicy()
        let user=ChatMessage(role:"user",content:[textBlock("Keep the image intact"),["type":"image","mimeType":"image/png","data":"c3ludGhldGlj"]])
        var assistant=ChatMessage(role:"assistant",content:[textBlock("Observed"),["type":"toolCall","id":"repeated","name":"read","arguments":["path":"a"]]])
        assistant.providerItems=[["type":"reasoning","id":"rs-a","encrypted_content":"opaque-original","summary":[]],
            ["type":"message","id":"msg-a","content":[["type":"output_text","text":"Observed"]]],
            ["type":"function_call","id":"fc-a","call_id":"repeated","name":"read","arguments":"{\"path\":\"a\"}"]]
        assistant.providerBinding=try ProviderClient.replayBinding(profile)
        assistant.providerIdentity=["status":"reported","effectiveModel":"fixture-model"]
        var result=ChatMessage(role:"toolResult",content:[textBlock("Full result, including a late failure")]); result.toolCallId="repeated"
        let messages=[user,assistant,result]
        let tools=[ToolDefinition("read","Read a file",["type":"object","properties":["path":["type":"string"]]])]
        let ordinary=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:"Normal leading policy",tools:tools,sessionID:"child",cacheSessionID:"parent")
        let projection=try ProviderClient.responsesProjection(messages,instructions:"Normal leading policy",profile:profile)
        let boundary=try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:[assistant.id,result.id])
        let instruction=CompactionSourceBuilder.instruction(boundary:boundary,focus:"Keep negative constraints",visibleTarget:3000)
        let summary=try ProviderClient.requestBody(profile:policy.summaryProfile(profile,cap:policy.summaryTokens(for:profile)),messages:messages+[instruction],instructions:"Normal leading policy",tools:tools,sessionID:"child",cacheSessionID:"parent",compaction:true)
        XCTAssertEqual(Array(summary["input"].list.dropLast()),ordinary["input"].list)
        for key in ["model","tools","reasoning","include","text","prompt_cache_key","prompt_cache_retention","temperature","store"] { XCTAssertEqual(summary[key],ordinary[key],key) }
        XCTAssertEqual(summary["metadata"]["session_id"].text,"child")
        XCTAssertEqual(summary["prompt_cache_key"].text,"parent")
        XCTAssertEqual(summary["tool_choice"].text,"none")
        XCTAssertEqual(summary["max_output_tokens"].int,16384)
        XCTAssertEqual(summary["input"].list[2]["encrypted_content"].text,"opaque-original")
        XCTAssertEqual(boundary["retainedRanges"].list.first?["start"].int,2)
    }

    func testSamplingCannotReplaceHistoryToolsModelOrExecutionControls() throws {
        let policy=CompactionPolicy()
        for conflict:JSON in [["input":[]],["model":"other"],["tools":[["type":"web_search"]]],
                             ["tool_choice":"auto"],["truncation":"auto"],["context_management":[["type":"compaction"]]],
                             ["previous_response_id":"resp-other"],["store":true],["background":true],
                             ["text":["format":["type":"json_object"]]],["response_format":["type":"json_object"]],
                             ["metadata":["session_id":"another-session"]]] {
            var raw=try fixtureProfile().raw; raw["samplingParams"]=conflict
            let profile=try Profile(raw), bounded=try policy.summaryProfile(profile,cap:policy.summaryTokens(for:profile))
            XCTAssertThrowsError(try ProviderClient.requestBody(profile:bounded,messages:[ChatMessage(role:"user",content:[textBlock("summary instruction")])],instructions:"policy",tools:[],sessionID:"test",compaction:true))
        }
        var raw=try fixtureProfile().raw; raw["samplingParams"]=["max_output_tokens":900000,"temperature":0.3]
        let p=try policy.summaryProfile(Profile(raw),cap:16384)
        let body=try ProviderClient.requestBody(profile:p,messages:[],instructions:"",tools:[],sessionID:"test",compaction:true)
        XCTAssertEqual(body["max_output_tokens"].int,16384); XCTAssertEqual(body["temperature"].double,0.3)
    }

    func testWindowBudgetsAndTinyConfigurations() throws {
        for (window,cap) in [(32768,8192),(128000,16384),(1000000,16384)] {
            var raw=try fixtureProfile().raw;raw["contextWindow"]=JSON(window);raw["modelOutputLimit"]=100000
            let profile=try Profile(raw), policy=CompactionPolicy()
            XCTAssertEqual(policy.summaryTokens(for:profile),cap)
            let threshold=try policy.trigger(profile:profile,instructionTokens:500)
            XCTAssertLessThan(threshold,window-cap-500)
            XCTAssertEqual(try policy.summaryProfile(profile,cap:cap).maxOutput,cap)
        }
        var raw=try fixtureProfile().raw;raw["contextWindow"]=40;raw["maxOutputTokens"]=16
        let tiny=try Profile(raw)
        XCTAssertThrowsError(try CompactionPolicy().summaryProfile(tiny,cap:CompactionPolicy().summaryTokens(for:tiny)))
        XCTAssertThrowsError(try CompactionPolicy().trigger(profile:tiny,instructionTokens:500))
    }

    func testSteeringKeepsCurrentTaskSkillSelectionsAuthoritative() throws {
        var selected=ChatMessage(role:"user",content:[textBlock("Use the explicitly selected review skill.")])
        selected.id="task"; selected.taskRootID="task"; selected.userInput=["skills":[["id":"review"]]]
        var old=selected;old.id="old-task";old.taskRootID="old-task"
        let evidence=ChatMessage(role:"assistant",content:[textBlock("Observed evidence.")])
        var steering=ChatMessage(role:"user",content:[textBlock("Continue and verify the correction.")])
        steering.taskRootID="task";steering.userInput=["skills":[]]
        let context=[old,evidence,selected,ChatMessage(role:"assistant",content:[textBlock("Working.")]),steering]
        let source=try CompactionPlanner.source(context:context,taskRoot:"task")
        let plan=CompactionPlanner.plan(source,cut:source.body.count)
        XCTAssertEqual(plan.keptMessages.map(\.id),[selected.id,steering.id])
        XCTAssertTrue(plan.summarized.contains { $0.id == old.id })
        XCTAssertEqual(plan.keptMessages.first?.userInput,selected.userInput)
    }

    func testUsageBindingInvalidatesModelPrefixSchemaAndReplays() throws {
        let profile=try fixtureProfile(), user=ChatMessage(role:"user",content:[textBlock("Question")])
        let original=try ProviderClient.requestBody(profile:profile,messages:[user],instructions:"Policy",tools:[],sessionID:"test")
        var reply=ChatMessage(role:"assistant",content:[textBlock("Answer")]);reply.usage=["input":100,"output":200,"totalTokens":300]
        reply.contextUsageBinding=try RequestContextCounter.usageBinding(original,profile:profile)
        let roundTrip=try ChatMessage(id:reply.id,pi:reply.pi)
        let counter=RequestContextCounter(), messages=[user,roundTrip]
        let same=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:"Policy",tools:[],sessionID:"test")
        XCTAssertEqual(try counter.count(messages:messages,profile:profile,request:same).requestMethod,"last-reply-usage")
        for key in ["instructions","tools","model","replay"] {
            var raw=profile.raw
            if key == "model" { raw["modelId"]="different" }
            if key == "replay" { raw["routing"]=["replayPolicy":"portable"] }
            let p=try Profile(raw)
            let body=try ProviderClient.requestBody(profile:p,messages:messages,instructions:key == "instructions" ? "Changed":"Policy",tools:key == "tools" ? [ToolDefinition("new","New",[:])]:[],sessionID:"test")
            let count=try counter.count(messages:messages,profile:p,request:body)
            XCTAssertEqual(count.requestMethod,"characters",key)
            XCTAssertNotNil(count.tokens,"An invalid old baseline falls back to an estimate, not a false post-compaction state")
            XCTAssertTrue(count.json["state"].isNull,key)
        }
    }

    func testProjectionCountsWrapperAndImagesButNeverCiphertextBytes() throws {
        var raw=try fixtureProfile().raw;raw["input"]=["text","image"]
        let p=try Profile(raw)
        var checkpoint=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+"Summary")]);checkpoint.kind="compaction"
        let body=try ProviderClient.requestBody(profile:p,messages:[checkpoint],instructions:"",tools:[],sessionID:"test")
        XCTAssertEqual(RequestContextCounter.projectedTokens(body),8+PiContext.tokens(chars:(ProviderClient.compactionSummaryPrefix+"Summary"+ProviderClient.compactionSummarySuffix).utf16.count))
        XCTAssertEqual(RequestContextCounter.inputTokens([["type":"input_image","image_url":JSON(String(repeating:"A",count:100000))]]),1208)
        XCTAssertEqual(RequestContextCounter.inputTokens([["type":"reasoning","encrypted_content":JSON(String(repeating:"A",count:100000)),"summary":[]]]),8)
        XCTAssertEqual(RequestContextCounter.inputTokens([.null]),8)
    }
}
