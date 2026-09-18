import XCTest
@testable import PiAgentCore

/// Minimal synthetic adaptation of the owner's Responses example. The opaque
/// provider payload is deliberately synthetic; token/cost/model fields retain
/// the supplied shape. These are parsing/capture tests, not a live gateway.
final class ResponsesSampleTests: XCTestCase {
    private func fixtureData(_ name:String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("fixtures/native/"+name))
    }

    private func sampleData() throws -> Data { try fixtureData("responses-owner-sample.json") }
    private func billingData() throws -> Data { try fixtureData("responses-owner-billing-sample.json") }
    private func billingHeaders() throws -> [String:String] { try JSON.parse(fixtureData("responses-owner-billing-headers.json")).map.compactMapValues(\.text) }

    private func sample() throws -> JSON { try JSON.parse(sampleData()) }

    private func profile(routing: JSON = ["replayPolicy":"portable"]) throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["modelId"] = "auto-router"; raw["routing"] = routing
        return try Profile(raw)
    }

    /// Exercise the same accumulator, telemetry and exact-byte recorder used by
    /// ProviderClient. An odd chunk size crosses JSON strings and SSE delimiters.
    private func parse(_ source: Data, streaming: Bool, headers: [String:String] = [:]) async throws -> (ModelReply, JSON) {
        let profile = try profile(), traces = TraceStore()
        let request = try ProviderClient.requestBody(profile: profile, messages: [ChatMessage(role:"user",content:[textBlock("9.1 + 32.1/3211.212")])], instructions:"", tools:[], sessionID:"sample").data()
        let attempt = await traces.begin(session:"sample",turn:"turn",profile:profile,purpose:"turn",body:request,headers:["Authorization":"Bearer fixture-secret"])
        await traces.dispatched(attempt,at:100)
        var responseHeaders = headers
        responseHeaders["content-type"] = streaming ? "text/event-stream" : "application/json"
        await traces.head(attempt,status:200,headers:responseHeaders)
        var accumulator = ProviderAccumulator(api:"openai-responses"), parser = SSEParser()
        for start in stride(from:0,to:source.count,by:13) {
            let chunk = source.subdata(in:start..<min(start+13,source.count))
            await traces.append(attempt,data:chunk)
            if streaming {
                for event in try parser.feed(chunk) {
                    await traces.event(attempt,event)
                    let value = try JSON.parse(Data(event.data.utf8))
                    await traces.reported(attempt,value:value,streaming:true)
                    _ = try accumulator.consume(value)
                }
            }
        }
        if !streaming {
            let value = try JSON.parse(source)
            await traces.reported(attempt,value:value,streaming:false)
            try accumulator.acceptJSON(value)
        }
        let reply = try accumulator.result()
        await traces.usage(attempt,reply.usage)
        await traces.terminal(attempt,at:200)
        await traces.transport(attempt,observation:["dispatch":100,"httpEnd":210,"transportOutcome":"eof"])
        await traces.finish(attempt,outcome:"completed",modelOutcome:"completed")
        let metadata = try await traces.command("debug.attempt",session:"sample",params:["attemptId":JSON(attempt)])
        let capture = try await traces.command("debug.body",session:"sample",params:["attemptId":JSON(attempt),"body":"response"])
        XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(capture["bytes"].text)),source)
        XCTAssertEqual(metadata["responseHash"]["sha256"].text,sha256(source))
        XCTAssertEqual(metadata["response"]["state"].text,"complete")
        return (reply,metadata)
    }

    private func stream(_ response: JSON) -> Data {
        let start:JSON = ["type":"response.created","response":["id":"resp_owner_sample","model":"auto-router","status":"in_progress"]]
        let final:JSON = ["type":"response.completed","response":response]
        return Data("event: response.created\r\ndata: \(start.encoded())\r\n\r\nevent: response.completed\r\ndata: \(final.encoded())\r\n\r\n".utf8)
    }

    private func assertSample(_ reply: ModelReply, metadata: JSON, source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(reply.message.text,"9.109996226",file:file,line:line)
        XCTAssertEqual(reply.message.thinking,"A short calculation.",file:file,line:line)
        XCTAssertEqual(reply.message.providerItems?.first?["encrypted_content"].text,"synthetic-opaque-fixture",file:file,line:line)
        XCTAssertEqual(reply.usage["input"].int,38,file:file,line:line)
        XCTAssertEqual(reply.usage["inputIncludingCache"].int,38,file:file,line:line)
        XCTAssertEqual(reply.usage["cacheRead"].int,0,file:file,line:line)
        XCTAssertEqual(reply.usage["cacheWrite"].int,0,file:file,line:line)
        XCTAssertEqual(reply.usage["output"].int,423,file:file,line:line)
        XCTAssertEqual(reply.usage["reasoning"].int,326,file:file,line:line)
        XCTAssertEqual((reply.usage["inputIncludingCache"].int ?? -1)+(reply.usage["output"].int ?? -1),461,file:file,line:line)
        XCTAssertEqual(reply.usage["raw"],try sample()["usage"],file:file,line:line)
        XCTAssertEqual(metadata["usage"],reply.usage,file:file,line:line)
        XCTAssertEqual(metadata["identity"]["requestedAlias"].text,"auto-router",file:file,line:line)
        XCTAssertEqual(metadata["identity"]["effectiveModel"].text,"gpt-5.4-mini",file:file,line:line)
        XCTAssertEqual(metadata["identity"]["status"].text,"reported",file:file,line:line)
        XCTAssertTrue(metadata["identity"]["evidence"].list.contains(["kind":"model","source":JSON(source),"value":"gpt-5.4-mini"]),file:file,line:line)
        XCTAssertEqual(metadata["gateway"]["cost"]["status"].text,"unreported",file:file,line:line)
        XCTAssertTrue(metadata["gateway"]["cost"]["usd"].isNull,file:file,line:line)
        XCTAssertEqual(metadata["gateway"]["cache"]["status"].text,"unreported",file:file,line:line)
    }

    func testOwnerJSONSamplePreservesUsageModelAndExactCapture() async throws {
        let (reply,metadata) = try await parse(sampleData(),streaming:false)
        try assertSample(reply,metadata:metadata,source:"body.router_model_name")
    }

    func testOwnerTerminalSSESamplePreservesUsageModelAndExactCapture() async throws {
        let (reply,metadata) = try await parse(stream(sample()),streaming:true,headers:["x-litellm-response-cost":"0"])
        try assertSample(reply,metadata:metadata,source:"response.completed.response.router_model_name")
        XCTAssertEqual(metadata["gateway"]["cost"]["streamingHeaderUSD"].double,0)
        XCTAssertEqual(metadata["rawEventIndexCount"].int,2)
    }

    func testFinalNumericCostIncludesExplicitZeroWithJSONAndSSEProvenance() async throws {
        for streaming in [false,true] {
            for amount in [0.0,0.00123] {
                var response = try sample(); response["usage"]["cost"] = JSON(amount)
                let bytes = streaming ? stream(response) : try response.data()
                let (_,metadata) = try await parse(bytes,streaming:streaming)
                XCTAssertEqual(metadata["gateway"]["cost"]["status"].text,"reported")
                XCTAssertEqual(metadata["gateway"]["cost"]["usd"].double,amount)
                XCTAssertEqual(metadata["gateway"]["cost"]["source"].text,streaming ? "response.completed.response.usage.cost" : "body.usage.cost")
            }
        }
    }

    func testNullBodyCostAllowsFinalJSONHeaderButNotProvisionalSSEHeader() async throws {
        let headers = ["x-litellm-response-cost":"0.0042"]
        let (_,json) = try await parse(sampleData(),streaming:false,headers:headers)
        XCTAssertEqual(json["gateway"]["cost"]["status"].text,"reported")
        XCTAssertEqual(json["gateway"]["cost"]["usd"].double,0.0042)
        XCTAssertEqual(json["gateway"]["cost"]["source"].text,"header:x-litellm-response-cost")
        let (_,sse) = try await parse(stream(sample()),streaming:true,headers:headers)
        XCTAssertEqual(sse["gateway"]["cost"]["status"].text,"unreported")
        XCTAssertTrue(sse["gateway"]["cost"]["usd"].isNull)
        XCTAssertEqual(sse["gateway"]["cost"]["streamingHeaderUSD"].double,0.0042)
    }

    func testNonzeroCacheDetailsAndReasoningAreSubsetsNotExtraConsumedTokens() async throws {
        var response = try sample()
        response["usage"]["input_tokens_details"]["cached_tokens"] = 11
        response["usage"]["input_tokens_details"]["cache_write_tokens"] = 7
        for streaming in [false,true] {
            let bytes = streaming ? stream(response) : try response.data()
            let (reply,_) = try await parse(bytes,streaming:streaming)
            XCTAssertEqual(reply.usage["cacheRead"].int,11)
            XCTAssertEqual(reply.usage["cacheWrite"].int,7)
            XCTAssertEqual(reply.usage["inputIncludingCache"].int,38)
            XCTAssertEqual(reply.usage["output"].int,423)
            XCTAssertEqual((reply.usage["inputIncludingCache"].int ?? -1)+(reply.usage["output"].int ?? -1),461)
            XCTAssertEqual(reply.usage["raw"]["total_tokens"].int,461)
        }
    }

    func testRouterModelConflictsWithDifferentExplicitModelOrContractHeader() throws {
        let profile = try profile(routing:["replayPolicy":"portable","reference":"fixture-v1","modelHeader":"x-fixture-model"])
        for streaming in [false,true] {
            var response = try sample(); response["model"] = "a-different-model"
            var identity = RoutingIdentity(profile:profile)
            identity.body(streaming ? ["type":"response.completed","response":response] : response,streaming:streaming)
            XCTAssertEqual(identity.json["status"].text,"conflict")
            XCTAssertEqual(identity.json["reportedModels"],["a-different-model","gpt-5.4-mini"])
            XCTAssertTrue(identity.json["effectiveModel"].isNull)
        }
        var identity = RoutingIdentity(profile:profile)
        identity.head(["x-fixture-model":"a-different-model"])
        identity.body(try sample(),streaming:false)
        XCTAssertEqual(identity.json["status"].text,"conflict")
        XCTAssertTrue(identity.json["effectiveModel"].isNull)
    }

    func testRouterModelIsBoundedCredentialFilteredAndOnlyReadFromResponseObjects() throws {
        for invalid:JSON in [true,12,"",JSON(String(repeating:"x",count:257)),"line\nbreak"] {
            var response = try sample(); response["router_model_name"] = invalid
            var identity = RoutingIdentity(profile:try profile())
            identity.body(response,streaming:false)
            XCTAssertEqual(identity.json["status"].text,"incomplete")
            XCTAssertTrue(identity.json["effectiveModel"].isNull)
        }
        var identity = RoutingIdentity(profile:try profile())
        identity.body(["type":"response.output_text.delta","delta":"hello","router_model_name":"invented"],streaming:true)
        XCTAssertEqual(identity.json["status"].text,"unreported")
        identity.body(["model":"auto-router","router_model_name":"fixture-secret"],streaming:false,excluding: { $0.contains("fixture-secret") })
        XCTAssertEqual(identity.json["status"].text,"incomplete")
        XCTAssertFalse(identity.json.encoded().contains("fixture-secret"))
    }

    func testOwnerJSONBillingHeadersSupplyFinalTotalAndReasoningSubset() async throws {
        let (reply,metadata)=try await parse(billingData(),streaming:false,headers:billingHeaders())
        XCTAssertEqual(reply.usage["inputIncludingCache"].int,38)
        XCTAssertEqual(reply.usage["output"].int,302)
        XCTAssertEqual(reply.usage["reasoning"].int,253)
        XCTAssertEqual(reply.usage["raw"]["total_tokens"].int,340)
        let gateway=metadata["gateway"], components=gateway["costBreakdown"]
        XCTAssertEqual(gateway["cost"]["status"].text,"reported")
        XCTAssertEqual(gateway["cost"]["usd"].double,0.0013875)
        XCTAssertEqual(gateway["cost"]["source"].text,"header:x-litellm-response-cost")
        XCTAssertEqual(components["reasoning"]["status"].text,"reported")
        XCTAssertEqual(components["reasoning"]["usd"].double,0.0011385)
        XCTAssertEqual(components["reasoning"]["source"].text,"header:x-litellm-response-cost-reasoning")
        XCTAssertEqual(components["input"]["usd"].double,0.0000285)
        XCTAssertEqual(components["output"]["usd"].double,0.001359)
        XCTAssertEqual(components["classifier"]["usd"].double,0.0000904)
        XCTAssertEqual(components["toolUsage"]["usd"].double,0)
        XCTAssertEqual(gateway["gatewayVersion"].text,"1.99.0")
        XCTAssertEqual(metadata["identity"]["effectiveModel"].text,"gpt-5.4-mini")
        XCTAssertEqual(metadata["identity"]["status"].text,"reported")
        XCTAssertTrue(metadata["identity"]["evidence"].list.contains(["kind":"model","source":"header:x-litellm-model-name","value":"openai/gpt-5.4-mini"]))
        XCTAssertEqual(metadata["responseHeaders"]["x-litellm-model-name"].text,"openai/gpt-5.4-mini")
    }

    func testSSEBillingHeadersAreProvisionalEvenWhenBodyProvidesFinalTotal() async throws {
        var response=try JSON.parse(billingData())
        for bodyCost:JSON in [.null,0.0013875] {
            response["usage"]["cost"]=bodyCost
            let (_,metadata)=try await parse(stream(response),streaming:true,headers:billingHeaders())
            let gateway=metadata["gateway"], reasoning=gateway["costBreakdown"]["reasoning"]
            XCTAssertEqual(gateway["cost"]["status"].text,bodyCost.isNull ? "unreported":"reported")
            XCTAssertEqual(gateway["cost"]["usd"],bodyCost)
            XCTAssertEqual(reasoning["status"].text,"unreported")
            XCTAssertTrue(reasoning["usd"].isNull)
            XCTAssertEqual(reasoning["streamingHeaderUSD"].double,0.0011385)
            XCTAssertEqual(reasoning["streamingHeaderStatus"].text,"reported")
        }
    }

    func testMissingInvalidAndConflictingReasoningHeaderCostsAreNotReported() throws {
        var missing=GatewayTelemetry(profile:try profile())
        missing.head(["content-type":"application/json"],excluding:{_ in false})
        XCTAssertEqual(missing.json["costBreakdown"]["reasoning"]["status"].text,"unreported")
        for invalid in ["null","-1","NaN","1e100","secret"] {
            var report=GatewayTelemetry(profile:try profile())
            report.head(["content-type":"application/json","x-litellm-response-cost-reasoning":invalid],excluding:{$0=="secret"})
            XCTAssertEqual(report.json["costBreakdown"]["reasoning"]["status"].text,"invalid")
            XCTAssertTrue(report.json["costBreakdown"]["reasoning"]["usd"].isNull)
            XCTAssertFalse(report.json.encoded().contains("secret"))
        }
        for bound in ["x-litellm-response-cost","x-litellm-response-cost-output"] {
            var report=GatewayTelemetry(profile:try profile())
            report.head(["content-type":"application/json",bound:"0.001","x-litellm-response-cost-reasoning":"0.002"],excluding:{_ in false})
            XCTAssertEqual(report.json["costBreakdown"]["reasoning"]["status"].text,"conflict")
            XCTAssertTrue(report.json["costBreakdown"]["reasoning"]["usd"].isNull)
        }
        var report=GatewayTelemetry(profile:try profile())
        for amount in ["0.001","0.002"] { report.head(["content-type":"application/json","x-litellm-response-cost-reasoning":amount],excluding:{_ in false}) }
        XCTAssertEqual(report.json["costBreakdown"]["reasoning"]["status"].text,"conflict")
        var free=GatewayTelemetry(profile:try profile())
        free.head(["content-type":"application/json","x-litellm-response-cost":"0","x-litellm-response-cost-reasoning":"0"],excluding:{_ in false})
        XCTAssertEqual(free.json["costBreakdown"]["reasoning"]["status"].text,"reported")
        XCTAssertEqual(free.json["costBreakdown"]["reasoning"]["usd"].double,0)
    }

    func testOwnerModelHeaderAloneResolvesButDifferentModelsRemainConflicting() throws {
        var identity=RoutingIdentity(profile:try profile())
        identity.head(try billingHeaders())
        identity.body(["model":"auto-router"],streaming:false)
        XCTAssertEqual(identity.json["effectiveModel"].text,"gpt-5.4-mini")
        XCTAssertEqual(identity.json["reportedModels"],["gpt-5.4-mini"])
        identity.body(["model":"auto-router","router_model_name":"gpt-other"],streaming:false)
        XCTAssertEqual(identity.json["status"].text,"conflict")
        XCTAssertTrue(identity.json["effectiveModel"].isNull)
        var otherNamespace=RoutingIdentity(profile:try profile())
        otherNamespace.head(["x-litellm-model-name":"unknown/gpt-5.4-mini"])
        otherNamespace.body(["router_model_name":"gpt-5.4-mini"],streaming:false)
        XCTAssertEqual(otherNamespace.json["status"].text,"conflict","An undeclared provider namespace must not be stripped")
    }

    func testPinnedReplayAcceptsKnownOpenAINamespaceWithoutIgnoringOtherBindings() throws {
        let profile=try profile(routing:["replayPolicy":"pinned","expectedModel":"openai/gpt-5.4-mini","replayContract":"Fixture fixes a compatible model"])
        var identity=RoutingIdentity(profile:profile)
        identity.body(try JSON.parse(billingData()),streaming:false)
        var accumulator=ProviderAccumulator(api:"openai-responses")
        try accumulator.acceptJSON(JSON.parse(billingData()))
        var message=try accumulator.result().message
        message.providerIdentity=identity.json; message.providerBinding=try ProviderClient.replayBinding(profile)
        XCTAssertEqual(try ProviderClient.replayItems(message,profile:profile),message.providerItems)
        message.providerIdentity=["status":"reported","effectiveModel":"other/gpt-5.4-mini"]
        XCTAssertThrowsError(try ProviderClient.replayItems(message,profile:profile))
    }
}
