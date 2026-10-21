import Foundation
import XCTest
@testable import PiAgentCore

private actor CredentialPackets {
    var values: [JSON] = []
    func append(_ packet: JSON) -> Bool { values.append(packet); return true }
}

final class CredentialCaptureTests: HelperTestCase {
    func testRoutingFixedValuesAndKeysSurviveMatchingCredentials() async throws {
        let base = RoutingIdentity(profile:try fixtureProfile()).json
        let labels = Array(base.map.keys) + ["reported", "unreported", "incomplete", "conflict", "model", "deployment", "group", "ask", "portable", "pinned", "header:x-litellm-model-name", "header:x-litellm-model-group", "body.model", base["boundary"].text!]
        for key in labels { for mode in ["off", "memory", "persist"] {
            var raw = try fixtureProfile().raw; raw["headers"] = ["X-Region":JSON(key)]
            let profile = try Profile(raw), traces = TraceStore()
            _ = try await traces.command("debug.mode",session:"s",params:["mode":JSON(mode)])
            let id = await traces.begin(session:"s",turn:"t",profile:profile,purpose:"turn",body:Data(),headers:["X-Region":key])
            let headers = ["x-litellm-model-name":"actual-a", "x-litellm-model-group":"group-a"]
            var identity = RoutingIdentity(profile:profile); identity.head(headers,excluding:{$0.contains(key)})
            await traces.head(id,status:200,headers:headers)
            let expected = identity.json, actual = await traces.identity(id)
            for field in ["status", "replayPolicy", "boundary", "omittedEvidence"] { XCTAssertEqual(actual[field],expected[field],"\(key), \(mode), \(field)") }
            XCTAssertEqual(Set(actual.map.keys),Set(expected.map.keys))
            for (a,b) in zip(actual["evidence"].list,expected["evidence"].list) {
                XCTAssertEqual(a["kind"],b["kind"],key); XCTAssertEqual(a["source"],b["source"],key)
                XCTAssertEqual(Set(a.map.keys),Set(b.map.keys),key)
            }
            await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        } }
    }

    func testEveryFixedMetadataLabelSurvivesAnEqualConfiguredCredential() async throws {
        func literals(_ value: JSON) -> Set<String> {
            if let text = value.text { return [text] }
            return Set(value.map.keys).union(value.map.values.reduce(into:Set<String>()) { $0.formUnion(literals($1)) }).union(value.list.reduce(into:Set<String>()) { $0.formUnion(literals($1)) })
        }
        func fixedIdentity(_ value: JSON) -> JSON {
            var fixed = value.removing(["requestedAlias", "effectiveModel", "reportedModels", "contractReference"])
            fixed["evidence"] = .array(value["evidence"].list.map { $0.removing(["value"]) })
            return fixed
        }
        for policy in ["ask", "portable", "pinned"] {
            var raw = try fixtureProfile().raw
            raw["routing"] = ["replayPolicy":JSON(policy),"expectedModel":"actual-a","replayContract":"fixture", "reference":"fixture", "deploymentHeader":"x-fixture-deployment"]
            let profile = try Profile(raw)
            var examples: [RoutingIdentity] = [RoutingIdentity(profile:profile)]
            var reported = RoutingIdentity(profile:profile)
            reported.head(["x-litellm-model-name":"actual-a", "x-litellm-model-group":"actual-b", "x-fixture-deployment":"actual-c"])
            examples.append(reported)
            var conflict = reported; conflict.body(["model":"actual-d","router_model_name":"actual-e"],streaming:false); examples.append(conflict)
            var incomplete = reported; incomplete.head(["x-litellm-model-name":"\n"]); examples.append(incomplete)
            for type in ["response.created", "response.in_progress", "response.completed", "response.incomplete", "response.failed"] {
                var streamed = RoutingIdentity(profile:profile); streamed.body(["type":JSON(type),"response":["model":"actual-a","router_model_name":"actual-b"]],streaming:true); examples.append(streamed)
            }
            for identity in examples {
                // A configured provenance string is data; fixed sources and
                // every kind/status/policy/key are protocol.
                var fixed = fixedIdentity(identity.json)
                fixed["evidence"] = .array(fixed["evidence"].list.map { item in item["source"].text == "header:x-fixture-deployment" ? item.removing(["source"]) : item })
                for key in literals(fixed) {
                    let credentials = CaptureCredentials(headers:["X-Region":key],configuredNames:["X-Region"])
                    var actual = fixedIdentity(identity.captured(credentials))
                    actual["evidence"] = .array(actual["evidence"].list.enumerated().map { index, item in identity.json["evidence"].list[index]["source"].text == "header:x-fixture-deployment" ? item.removing(["source"]) : item })
                    XCTAssertEqual(actual,fixed,key)
                }
            }
        }
        let types = ["object", "array", "string", "number", "integer", "boolean", "null"]
        var inputs: [JSON] = ["message", "function_call", "function_call_output", "reasoning"].map { ["type":JSON($0)] }
        inputs += ["system", "developer", "user", "assistant"].map { ["role":JSON($0)] }
        inputs += ["input_text", "output_text", "input_image", "summary_text", "refusal"].map { ["content":[["type":JSON($0),"detail":"auto"]]] }
        inputs += [["status":"completed","phase":"commentary"],["status":"completed","phase":"final_answer"]]
        var definitions: [JSON] = types.map { ["type":"function","parameters":["type":JSON($0)]] }
        definitions.append(["type":"function","parameters":["type":["string","null"]]])
        let request: JSON = ["input":.array(inputs),"tools":.array(definitions),"reasoning":["summary":"auto"],"include":["reasoning.encrypted_content"]]
        for key in literals(request) {
            let credentials = CaptureCredentials(headers:["X-Region":key],configuredNames:["X-Region"])
            XCTAssertEqual(credentials.requestMetadata(request),request,key)
        }
        let grant = SubagentModelGrant(model:"configured-model-secret"), profile = try fixtureProfile()
        let delegated = SubagentSteeringContract.definitions(child:false,models:[grant],profile:profile,connectionSupportsReasoning:true) + SubagentSteeringContract.definitions(child:true,connectionSupportsReasoning:true) + [SubagentSpec.definition(models:[grant])]
        let helperBody = try ProviderClient.requestBody(profile:profile,messages:[],instructions:"",tools:delegated,sessionID:"s")
        for key in literals(helperBody["tools"]).subtracting([grant.model]) {
            let credentials = CaptureCredentials(headers:["X-Region":key],configuredNames:["X-Region"])
            func expected(_ value: JSON) -> JSON {
                if value.text == grant.model { return JSON(credentials.metadataText(grant.model)) }
                if case .array(let values) = value { return .array(values.map(expected)) }
                if value.isObject { return .object(value.map.mapValues(expected)) }
                return value
            }
            XCTAssertEqual(credentials.requestMetadata(helperBody,definitions:delegated)["tools"],expected(helperBody["tools"]),key)
        }
        let configuredCredential = CaptureCredentials(headers:["X-Region":grant.model],configuredNames:["X-Region"])
        for tool in configuredCredential.requestMetadata(helperBody,definitions:delegated)["tools"].list where ["subagent", "subagent_start"].contains(tool["name"].text ?? "") {
            XCTAssertEqual(tool["parameters"]["properties"]["model"]["enum"],[JSON(CaptureCredentials.fingerprint(grant.model))])
        }
        var overridden = helperBody
        overridden["tools"] = .array(helperBody["tools"].list.map { tool in var value = tool; value["configurationEcho"] = JSON(grant.model); return value })
        for tool in configuredCredential.requestMetadata(overridden,definitions:delegated)["tools"].list {
            XCTAssertEqual(tool["configurationEcho"].text,CaptureCredentials.fingerprint(grant.model),"Additional configuration fields are not helper-owned")
        }
        let configuredSchema: JSON = ["tools":[["type":"function","name":"configured-function","description":"Configured schema","parameters":["type":"object","properties":.object([grant.model:["type":"string"]])]]]]
        let maskedSchema = configuredCredential.requestMetadata(configuredSchema,definitions:delegated)["tools"].list[0]["parameters"]
        XCTAssertEqual(Set(maskedSchema["properties"].map.keys),[CaptureCredentials.fingerprint(grant.model)],"Configuration-controlled schema names remain data")
        XCTAssertEqual(maskedSchema["type"].text,"object")
        for scope in ["global", "project", "approved additional"] { for state in ["included", "truncated"] {
            let source: JSON = ["scope":JSON(scope),"state":JSON(state),"reason":"Selected by Codex precedence","hash":JSON(sha256(Data("fixture".utf8))),"bytes":7,"includedBytes":7,"truncated":false]
            for key in literals(source) {
                let credentials = CaptureCredentials(headers:["X-Region":key],configuredNames:["X-Region"])
                XCTAssertEqual(credentials.resourceMetadata(source),source,key)
            }
        } }
        let operation: JSON = ["kind":"execution", "phase":"planning", "reason":"manual", "recovery":["failure":"contextOverflow"], "outputAllowanceSource":"local-reserve-only"]
        var gateway = GatewayTelemetry(profile:try fixtureProfile())
        gateway.head(["content-type":"application/json","x-litellm-response-cost":"0.5","x-litellm-response-cost-input":"0.2"],excluding:{_ in false})
        gateway.body(["usage":["cost":0.5]],streaming:false,excluding:{_ in false})
        let usage = UsageObservation.normalized(["input_tokens":2,"output_tokens":1,"input_tokens_details":["cached_tokens":5]],api:"openai-responses")
        let fixedUsage = usage.removing(["raw"]), fixedGateway = gateway.json
        let labels = literals(operation).union(literals(fixedUsage)).union(literals(fixedGateway)).union(["invalid","conflict","unreported","hit","miss","cancelled","failed","completed","summary-generation-cap","threshold","context-rejection"])
        for key in labels { for mode in ["off", "memory", "persist"] {
            var raw = try fixtureProfile().raw; raw["headers"] = ["X-Region":JSON(key)]
            let traces = TraceStore()
            _ = try await traces.command("debug.mode",session:"s",params:["mode":JSON(mode)])
            let id = await traces.begin(session:"s",turn:"t",profile:try Profile(raw),purpose:"turn",body:Data(),headers:["X-Region":key])
            await traces.head(id,status:200,headers:["content-type":"application/json","x-litellm-response-cost":"0.5","x-litellm-response-cost-input":"0.2"])
            await traces.reported(id,value:["usage":["cost":0.5]],streaming:false)
            await traces.usage(id,usage); await traces.operation(id,operation)
            let metadata = await traces.latest("s")
            XCTAssertEqual(metadata["operation"],operation,key); XCTAssertEqual(metadata["usage"].removing(["raw"]),fixedUsage,key); XCTAssertEqual(metadata["gateway"],fixedGateway,key)
            await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        } }
        for status in ["reported", "unreported", "invalid", "conflict", "hit", "miss", "overflow", "execution", "planning", "completed", "failed", "cancelled", "manual", "threshold", "context-rejection", "summary-generation-cap"] {
            var raw = try fixtureProfile().raw
            raw["headers"] = ["X-Region":JSON(status)]; raw["routing"] = ["reference":"fixture","cacheHeader":"x-cache"]
            let profile = try Profile(raw), traces = TraceStore()
            let id = await traces.begin(session:"statuses",turn:"t",profile:profile,purpose:"turn",body:Data(),headers:["X-Region":status])
            var headers = ["content-type":"application/json"]
            if status == "reported" || status == "conflict" { headers["x-litellm-response-cost"] = "0.5" }
            if status == "invalid" { headers["x-litellm-response-cost"] = "oops"; headers["x-cache"] = "oops" }
            if status == "hit" || status == "conflict" { headers["x-cache"] = "HIT" }
            if status == "miss" { headers["x-cache"] = "MISS" }
            await traces.head(id,status:200,headers:headers)
            if status == "conflict" {
                await traces.head(id,status:200,headers:["content-type":"application/json","x-cache":"MISS"])
                await traces.reported(id,value:["usage":["cost":0.6]],streaming:false)
            }
            let normalized = UsageObservation.normalized(["input_tokens":9_223_372_036_854_774_784,"cache_read_input_tokens":4096,"output_tokens":1],api:"anthropic-messages")
            await traces.usage(id,normalized)
            for phase in ["planning", "completed", "failed", "cancelled"] {
                let operation: JSON = ["kind":"execution","phase":JSON(phase),"reason":JSON(["manual", "threshold", "context-rejection"].contains(status) ? status : "context-rejection"),"outputAllowanceSource":"summary-generation-cap"]
                await traces.operation(id,operation)
                let actual = await traces.latest("statuses")
                XCTAssertEqual(actual["operation"],operation)
                XCTAssertEqual(actual["usage"].removing(["raw"]),normalized.removing(["raw"]))
                if ["reported", "unreported", "invalid", "conflict"].contains(status) { XCTAssertEqual(actual["gateway"]["cost"]["status"].text,status) }
                if ["hit", "miss", "invalid", "conflict", "unreported"].contains(status) { XCTAssertEqual(actual["gateway"]["cache"]["status"].text,status) }
            }
            await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        }
    }

    func testConfiguredHeaderMatchingUsageSchemaPreservesNormalizedAccounting() async throws {
        for key in ["status", "input", "output", "raw", "reported", "unreported", "invalid", "us"] {
            let raw: JSON = ["input_tokens": 12, "output_tokens": 3, "output_tokens_details": ["reasoning_tokens": -1], "diagnostic": .array([.object([key: JSON(key)])])]
            let usage = UsageObservation.normalized(raw, api: "openai-responses")
            for mode in ["off", "memory", "persist"] { for outcome in ["completed", "cancelled", "failed"] {
                let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
                var profile = try fixtureProfile().raw; profile["headers"] = ["X-Region": JSON(key)]
                _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
                let id = await traces.begin(session: "s", turn: "t", profile: try Profile(profile), purpose: "turn", body: Data(), headers: ["X-Region": key])
                await traces.usage(id, usage)
                let label = "\(key), \(mode), \(outcome)", running = await traces.latest("s")
                XCTAssertEqual(running["usage"].removing(["raw"]), usage.removing(["raw"]), label)
                await traces.finish(id, outcome: outcome, modelOutcome: outcome == "completed" ? "completed" : "interrupted")
                await traces.delivered()
                let settled = await traces.latest("s")
                XCTAssertEqual(settled["usage"].removing(["raw"]), usage.removing(["raw"]), label)
                let diagnostic = settled["usage"]["raw"]["diagnostic"].list.first ?? .null
                XCTAssertEqual(diagnostic[CaptureCredentials.fingerprint(key)].text, CaptureCredentials.fingerprint(key), label)
                for packet in await packets.values where !packet["metadata"]["usage"].map.isEmpty {
                    XCTAssertEqual(packet["metadata"]["usage"].removing(["raw"]), usage.removing(["raw"]), label)
                }
            } }
        }
    }

    func testConfiguredHeaderMatchingGatewaySchemaPreservesReportedAccounting() async throws {
        for key in ["status", "cost", "usd", "reported", "hit", "source", "us"] {
            var raw = try fixtureProfile().raw
            raw["headers"] = ["X-Region": JSON(key)]
            raw["routing"] = ["replayPolicy": "portable", "reference": "fixture-v1", "cacheHeader": "x-cache"]
            let profile = try Profile(raw)
            for mode in ["off", "memory", "persist"] { for streaming in [false, true] {
                let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
                _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
                let id = await traces.begin(session: "s", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["X-Region": key])
                let headers = ["content-type": streaming ? "text/event-stream" : "application/json", "x-litellm-response-cost": "0.5", "x-cache": "HIT"]
                let body: JSON = streaming ? ["type": "response.completed", "response": ["usage": ["cost": 0.5]]] : ["usage": ["cost": 0.5]]
                var expected = GatewayTelemetry(profile: profile)
                expected.head(headers, excluding: { $0.contains(key) }); expected.body(body, streaming: streaming, excluding: { $0.contains(key) })
                await traces.head(id, status: 200, headers: headers)
                await traces.reported(id, value: body, streaming: streaming)
                let label = "\(key), \(mode), streaming=\(streaming)", running = await traces.latest("s")
                XCTAssertEqual(running["gateway"], expected.json, label)
                XCTAssertEqual(running["gateway"]["cost"]["status"].text, "reported", label)
                XCTAssertEqual(running["gateway"]["cache"]["status"].text, "hit", label)
                await traces.finish(id, outcome: "completed", modelOutcome: "completed")
                await traces.delivered()
                let settled = await traces.latest("s")
                XCTAssertEqual(settled["gateway"], expected.json, label)
                for packet in await packets.values where packet["type"].text == "finish" {
                    XCTAssertEqual(packet["metadata"]["gateway"], expected.json, label)
                }
            } }
        }
    }

    func testSSEEventTypesMaskCredentialsBeforePreviewInMemoryAndPersistedPages() async throws {
        let key = "sk-generated-event-secret"
        var names = Array(repeating: "response.output_text.delta", count: 130)
        names[0] = key; names[1] = String(repeating: "x", count: 124) + key
        names[128] = key; names[129] = String(repeating: "y", count: 160)
        let response = Data(names.map { "event: \($0)\ndata: {}\n\n" }.joined().utf8)
        for mode in ["memory", "persist"] {
            let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
            var parser = SSEParser(), parsed: [SSEEvent] = []
            for byte in response {
                let chunk = Data([byte])
                await traces.append(id, data: chunk)
                for event in try parser.feed(chunk) { parsed.append(event); await traces.event(id, event) }
            }
            XCTAssertEqual(parsed.map(\.event), names, "The parser still receives the original stream")
            var indexed: [JSON] = []
            for offset in [0, 128] {
                let page = try await traces.command("debug.raw-events", session: "s", params: ["attemptId": JSON(id), "offset": JSON(offset)])
                XCTAssertEqual(page["total"].int, names.count)
                indexed += page["events"].list
            }
            XCTAssertEqual(indexed.count, names.count)
            for (index, entry) in indexed.enumerated() {
                let expected = names[index].contains(key) ? CaptureCredentials.fingerprint(names[index]) : preview(names[index], bytes: 128)
                XCTAssertEqual(entry["type"].text, expected, "\(mode), event \(index)")
                XCTAssertEqual(entry["start"].int, parsed[index].start); XCTAssertEqual(entry["end"].int, parsed[index].end)
            }
            await traces.transport(id, observation: ["transportOutcome": "eof"])
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let emitted = await packets.values, pages = emitted.filter { $0["type"].text == "events" }
            let retained: Data
            if mode == "persist" {
                XCTAssertEqual(pages.map { $0["offset"].int }, [0, 128])
                XCTAssertEqual(pages.flatMap { $0["events"].list }, indexed)
                retained = emitted.filter { $0["type"].text == "bytes" && $0["body"].text == "response" }.reduce(into: Data()) { $0.append(Data(base64Encoded: $1["bytes"].text!)!) }
            } else {
                XCTAssertTrue(pages.isEmpty)
                let body = try await traces.command("debug.body", session: "s", params: ["attemptId": JSON(id), "body": "response"])
                retained = try XCTUnwrap(Data(base64Encoded: body["bytes"].text ?? ""))
            }
            XCTAssertEqual(retained.count, response.count); XCTAssertFalse(String(decoding: retained, as: UTF8.self).contains(key))
            let attempt = await traces.latest("s")
            XCTAssertEqual(attempt["response"]["credentialRedactions"].int, 3)
            XCTAssertEqual(attempt["rawEventIndexCount"].int, names.count)
            for packet in emitted where packet["type"].text != "bytes" { XCTAssertFalse(packet.encoded().contains(key), mode) }
        }
    }

    func testCapturedRequestAndResponseHeaderNamesCannotEchoCredentials() async throws {
        let key = "sk-generated-header-value", requestName = "X-Request-" + key, responseName = "x-response-" + key
        for mode in ["memory", "persist"] {
            let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let headers = ["Authorization": "Bearer " + key, requestName: "fixture-header-value", "Content-Type": "application/json"]
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: headers)
            await traces.head(id, status: 200, headers: [responseName: "diagnostic", "x-hidden-" + key: key, "x-long-" + key: String(repeating: "x", count: 16_385), "content-type": "text/event-stream", "retry-after": key])
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let attempt = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(id)])
            XCTAssertNotNil(attempt["requestHeaders"].map[CaptureCredentials.fingerprint(requestName.lowercased())], mode)
            XCTAssertEqual(attempt["responseHeaders"][CaptureCredentials.fingerprint(responseName)].text, "diagnostic", mode)
            XCTAssertEqual(attempt["responseHeaders"][CaptureCredentials.fingerprint("x-hidden-" + key)].text, "********", mode)
            XCTAssertEqual(attempt["responseHeaders"][CaptureCredentials.fingerprint("x-long-" + key)].text, "[omitted: header exceeds capture safety limits]", mode)
            XCTAssertEqual(attempt["requestHeaders"]["content-type"].text, "application/json")
            XCTAssertEqual(attempt["responseHeaders"]["content-type"].text, "text/event-stream")
            XCTAssertEqual(attempt["responseHeaders"]["retry-after"].text, "********")
            XCTAssertEqual(headers["Authorization"], "Bearer " + key, "Wire headers remain unchanged")
            XCTAssertFalse(attempt.encoded().contains(key), mode)
            for packet in await packets.values { XCTAssertFalse(packet.encoded().contains(key), mode) }
        }
    }

    func testGatewayCacheHeaderSourceCannotEchoCredentials() async throws {
        let key = "sk-generated-cache-value", name = "x-cache-sk-generated-cache-value"
        var raw = try fixtureProfile().raw
        raw["routing"] = ["replayPolicy": "portable", "reference": "fixture-v1", "cacheHeader": JSON(name)]
        let profile = try Profile(raw)
        for mode in ["memory", "persist"] {
            let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let id = await traces.begin(session: "s", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
            await traces.head(id, status: 200, headers: [name: "HIT"])
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let attempt = await traces.latest("s")
            XCTAssertEqual(attempt["gateway"]["cache"]["status"].text, "hit")
            XCTAssertEqual(attempt["gateway"]["cache"]["source"].text, CaptureCredentials.fingerprint("header:" + name), mode)
            for packet in await packets.values { XCTAssertFalse(packet["metadata"]["gateway"].encoded().contains(key), mode) }
        }
    }

    func testCapturedRawUsageSanitizesNestedCredentialValuesAndFieldNames() async throws {
        let key = "sk-generated-usage-value"
        let raw: JSON = ["input_tokens": 12, "output_tokens": 3, "diagnostic": .array([["message": JSON(key), "nested": .object([key: "marker"])]]), "ordinary": "retained"]
        var accumulator = ProviderAccumulator(api: "openai-responses")
        try accumulator.acceptJSON(["status": "completed", "output": [], "usage": raw])
        let usage = try accumulator.result().usage
        XCTAssertEqual(usage["raw"], raw, "The provider's result remains unchanged")
        for mode in ["memory", "persist"] {
            let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
            await traces.usage(id, usage)
            await traces.finish(id, outcome: "completed", modelOutcome: "completed")
            await traces.delivered()
            let attempt = await traces.latest("s"), captured = attempt["usage"]
            XCTAssertEqual(captured["input"].int, 12); XCTAssertEqual(captured["output"].int, 3)
            XCTAssertEqual(captured["raw"]["ordinary"].text, "retained")
            let diagnostic = try XCTUnwrap(captured["raw"]["diagnostic"].list.first)
            XCTAssertEqual(diagnostic["message"].text, CaptureCredentials.fingerprint(key), mode)
            XCTAssertEqual(diagnostic["nested"][CaptureCredentials.fingerprint(key)].text, "marker", mode)
            XCTAssertFalse(attempt.encoded().contains(key), mode)
            for packet in await packets.values { XCTAssertFalse(packet.encoded().contains(key), mode) }
        }
    }

    func testLoopbackErrorIDsAndRetryFieldsDoNotEscapeCaptureMasking() async throws {
        let source = #"""
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        key = self.headers['Authorization'].removeprefix('Bearer ')
        payload = json.dumps({'error': {'message': 'Rejected ' + key, 'code': key, 'type': key, key: 'diagnostic'}})
        streaming = self.path.startswith('/sse/')
        body = (('id: ' + key + '\nretry: ' + key + '\nevent: error\ndata: ' + payload + '\n\n') if streaming else payload).encode()
        self.send_response(200 if streaming else 401)
        self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for name in ['Retry-After', 'X-Request-Id', 'X-Litellm-Call-Id', 'X-Litellm-Version']:
            self.send_header(name, key)
        self.end_headers(); self.wfile.write(body); self.wfile.flush()
server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
"""#
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try await PythonGateway.start(source: source, root: root); defer { gateway.stop() }
        let key = "sk-generated-audit-value"
        for mode in ["memory", "persist"] { for kind in ["http", "sse"] {
            let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
            var raw = try fixtureProfile().raw
            raw["baseUrl"] = JSON("http://127.0.0.1:\(gateway.port)/\(kind)")
            let client = ProviderClient(traces: traces)
            do {
                _ = try await client.complete(profile: Profile(raw), apiKey: key, messages: [ChatMessage(role: "user", content: [textBlock("fixture")])], instructions: "fixture", tools: [], sessionID: "s", turnID: "t", purpose: "compaction", onDelta: { _ in })
                XCTFail("The generated error must fail the request")
            } catch let error as AgentError {
                XCTAssertEqual(error.code, kind == "sse" ? "provider_failed" : "provider_http")
                XCTAssertFalse(error.message.contains(key)); XCTAssertFalse(error.providerMessage?.contains(key) == true)
                let id = try XCTUnwrap(error.attemptID)
                await traces.operation(id, ["phase": "failed", "errorCode": JSON(error.code), "error": JSON(error.message)])
            }
            await traces.delivered()
            let attempt = await traces.latest("s"), emitted = await packets.values
            XCTAssertFalse(attempt.encoded().contains(key))
            XCTAssertEqual(attempt["responseHeaders"]["retry-after"].text, "********")
            XCTAssertTrue(attempt["gateway"]["callId"].isNull); XCTAssertTrue(attempt["gateway"]["gatewayVersion"].isNull)
            let retained: Data, events: [JSON]
            if mode == "persist" {
                retained = emitted.filter { $0["type"].text == "bytes" && $0["body"].text == "response" }.reduce(into: Data()) { $0.append(Data(base64Encoded: $1["bytes"].text!)!) }
                events = emitted.filter { $0["type"].text == "events" }.flatMap { $0["events"].list }
            } else {
                let id = try XCTUnwrap(attempt["attemptId"].text)
                let body = try await traces.command("debug.body", session: "s", params: ["attemptId": JSON(id), "body": "response"])
                retained = try XCTUnwrap(Data(base64Encoded: body["bytes"].text ?? ""))
                events = try await traces.command("debug.raw-events", session: "s", params: ["attemptId": JSON(id)])["events"].list
            }
            XCTAssertFalse(retained.isEmpty); XCTAssertFalse(String(decoding: retained, as: UTF8.self).contains(key))
            XCTAssertEqual(events.count, kind == "sse" ? 1 : 0)
            for event in events { XCTAssertEqual(Set(event.map.keys), ["type", "start", "end", "observedAt"]); XCTAssertEqual(event["type"].text, "error") }
            for packet in emitted where packet["type"].text != "bytes" { XCTAssertFalse(packet.encoded().contains(key)) }
        } }
    }

    func testJSONEscapeEquivalentCredentialsAreMaskedAtEveryCaptureSplit() async throws {
        let fixtures = [("sk-test-secret", #"\u0073k-test-secret"#),
                        ("sk-test-secret", #"s\u006B-test-\u0073ecret"#),
                        ("key/\"\\\n🙂", #"key\u002f\u0022\u005C\n\uD83d\uDE42"#)]
        for (key, escaped) in fixtures { for mode in ["memory", "persist"] {
            let prefix = "{\"error\":{\"message\":\"Rejected ", suffix = "\"},\"padding\":\"" + String(repeating: ".", count: 100) + "\"}"
            let response = Data((prefix + escaped + suffix).utf8)
            XCTAssertTrue(try JSON.parse(response)["error"]["message"].text?.contains(key) == true)
            let expected = Data((prefix + String(repeating: "*", count: escaped.utf8.count) + suffix).utf8)
            for split in -1...response.count {
                let packets = CredentialPackets(), traces = TraceStore { await packets.append($0) }
                _ = try await traces.command("debug.mode", session: "s", params: ["mode": JSON(mode)])
                let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
                await traces.head(id, status: 401, headers: ["content-type": "application/json"])
                if split < 0 {
                    for byte in response { await traces.append(id, data: Data([byte])) }
                } else {
                    await traces.append(id, data: Data(response.prefix(split)))
                    await traces.append(id, data: Data(response.dropFirst(split)))
                }
                await traces.transport(id, observation: ["transportOutcome": "eof"])
                await traces.finish(id, outcome: "failed", modelOutcome: "interrupted")
                let retained: Data
                if mode == "persist" {
                    await traces.delivered()
                    var bytes = Data()
                    for packet in await packets.values where packet["type"].text == "bytes" && packet["body"].text == "response" {
                        XCTAssertEqual(packet["offset"].int, bytes.count)
                        bytes.append(try XCTUnwrap(Data(base64Encoded: packet["bytes"].text ?? "")))
                    }
                    retained = bytes
                } else {
                    let body = try await traces.command("debug.body", session: "s", params: ["attemptId": JSON(id), "body": "response"])
                    retained = try XCTUnwrap(Data(base64Encoded: body["bytes"].text ?? ""))
                }
                let label = "\(mode), split \(split), \(escaped)"
                XCTAssertEqual(retained, expected, label)
                XCTAssertFalse(try JSON.parse(retained)["error"]["message"].text?.contains(key) == true, label)
                let metadata = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(id)])["response"]
                XCTAssertEqual(metadata["credentialRedactions"].int, 1, label)
                XCTAssertEqual(metadata["byteExact"].flag, false, label)
                XCTAssertEqual(metadata["observedBytes"].int, retained.count, label)
            }
        } }
    }

    func testJSONEscapeMaskingLeavesMalformedAndUnrelatedEscapesUnchanged() {
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer key/🙂"], configuredNames: [])
        for text in [#"key\u002g🙂"#, #"key\u002f\uD83D"#, #"key\u002f\uDE42\uD83D"#,
                     #"key\u002f\uD83D\u0041"#, #"key\u002f\uD83D\uDE43"#, #"key\x2f🙂"#] {
            let original = Data(text.utf8)
            for split in 0...original.count {
                var masker = CaptureCredentials.ResponseMasker(credentials)
                var retained = masker.feed(Data(original.prefix(split)))
                retained.append(masker.feed(Data(original.dropFirst(split)), final: true))
                XCTAssertEqual(retained, original); XCTAssertEqual(masker.replacements, 0)
            }
        }
    }

    func testHeaderCaptureKeepsOrdinaryResponseFieldsAndMasksShortTokensCookiesAndCustomSecrets() {
        let headers = ["Authorization": "Bearer small", "Cookie": "session=private-cookie-value", "X-Custom-Credential": "custom-private-key", "X-Session-Id": "session-123"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: ["X-Custom-Credential"])
        let request = privacy.requestHeaders(headers)
        XCTAssertEqual(request["authorization"].text, "Bearer ********")
        XCTAssertEqual(request["cookie"].text, "********")
        XCTAssertEqual(request["x-custom-credential"].text, "********-key")
        XCTAssertEqual(request["x-session-id"].text, "session-123")
        let ordinary = ["date": "Wed, 16 Sep 2026 01:23:24 GMT", "content-length": "5105",
                        "x-provider-build": "v1.99.0", "x-litellm-cache-key": "cache-fixture-key", "x-litellm-key-spend": "12.345",
                        "x-litellm-response-cost-reasoning": "0.0011385", "cache-control": "no-cache"]
        var response = ordinary
        response["Set-Cookie"] = "new-session=fresh-secret"
        response["Authorization"] = "Bearer fresh-private-key"
        response["x-custom-credential"] = "another-private-value"
        response["x-echo"] = "echo: custom-private-key"
        let captured = privacy.responseHeaders(response, metadataHeaders: [])
        for (name, value) in ordinary { XCTAssertEqual(captured[name].text, value) }
        for name in ["set-cookie", "authorization", "x-custom-credential", "x-echo"] { XCTAssertEqual(captured[name].text, "********") }
        for secret in ["small", "private-cookie-value", "custom-private-key", "fresh-secret", "fresh-private-key", "another-private-value"] {
            XCTAssertFalse(request.encoded().contains(secret)); XCTAssertFalse(captured.encoded().contains(secret))
        }
        let excessive = privacy.responseHeaders(["x-debug": String(repeating: "x", count: 16_385)], metadataHeaders: [])
        XCTAssertEqual(excessive["x-debug"].text, "[omitted: header exceeds capture safety limits]")
    }
    func testMaskingNeverRevealsShortTokensAndPreservesSchemeWithoutChangingWireHeaders() {
        for size in 0...16 {
            let token = String(repeating: "a", count: size)
            XCTAssertEqual(CaptureCredentials.masked(token), size < 12 ? "********" : "********aaaa")
        }
        let headers = ["Authorization": "Token original-private-token"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: [])
        XCTAssertEqual(privacy.requestHeaders(headers)["authorization"].text, "Token ********oken")
        XCTAssertEqual(headers["Authorization"], "Token original-private-token")
        XCTAssertEqual(privacy.requestBody(Data("original-private-token".utf8)).bytes,
                       Data(CaptureCredentials.fingerprint("original-private-token").utf8))
    }
    func testCredentialsAreMaskedAtHeaderBoundaryAndSafeHeadersRemainReadable() {
        let headers = ["aUtHoRiZaTiOn": "Bearer fixture-secret", "x-api-key": "fixture-secret", "X-Organization-Key": "custom-secret", "Content-Type": "application/json", "Accept": "custom-secret"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: ["X-Organization-Key", "Accept"])
        let retained = privacy.requestHeaders(headers)
        XCTAssertEqual(retained["authorization"].text, "Bearer ********cret")
        XCTAssertEqual(retained["x-api-key"].text, "********cret")
        XCTAssertEqual(retained["x-organization-key"].text, "********cret")
        XCTAssertEqual(retained["accept"].text, "********cret")
        XCTAssertEqual(retained["content-type"].text, "application/json")
        XCTAssertFalse(retained.encoded().contains("fixture-secret")); XCTAssertFalse(retained.encoded().contains("custom-secret"))
        let response = privacy.responseHeaders(["x-request-id":"echo-fixture-secret", "x-model":"custom-secret", "set-cookie":"unknown-secret", "content-type":"text/event-stream"], metadataHeaders: ["x-model"])
        XCTAssertEqual(response["x-request-id"].text,"********"); XCTAssertEqual(response["x-model"].text,"********")
        XCTAssertEqual(response["set-cookie"].text,"********"); XCTAssertEqual(response["content-type"].text,"text/event-stream")
    }
    func testByteReplacementPreservesFormattingUnicodeAndEscapedCredentials() throws {
        let secret = "secret-\"quoted\\path/🙂", other = "custom-token"
        let privacy = CaptureCredentials(headers: ["Authorization":"Bearer " + secret,"x-custom":other], configuredNames: ["x-custom"])
        let quoted = JSON(secret).encoded()
        let original = Data(("{ \"p\" : " + quoted + ",\n\"q\":\"custom-token\",\"z\":\"中文\" }\n").utf8)
        let retained = privacy.requestBody(original)
        let expected = Data(("{ \"p\" : \"" + CaptureCredentials.fingerprint(secret) + "\",\n\"q\":\"" + CaptureCredentials.fingerprint(other) + "\",\"z\":\"中文\" }\n").utf8)
        XCTAssertEqual(retained.bytes,expected); XCTAssertEqual(retained.replacements,2); XCTAssertFalse(retained.omitted)
        let ordinary = Data("{ \"unrelated\" : \"中文🙂\" }".utf8)
        XCTAssertEqual(privacy.requestBody(ordinary).bytes,ordinary)
    }
    func testReplacementFloodIsExplicitlyOmittedWithoutLeakingBody() async throws {
        let privacy = CaptureCredentials(headers:["Authorization":"Bearer x"],configuredNames:[])
        let result = privacy.requestBody(Data(repeating:120,count:65_537))
        XCTAssertTrue(result.omitted); XCTAssertTrue(result.bytes.isEmpty)
        let packets = CredentialPackets()
        let traces = TraceStore { await packets.append($0) }
        _ = try await traces.command("debug.mode",session:"s",params:["mode":"persist"])
        let profile = try Profile(["id":"p","api":"openai-responses","providerId":"litellm","modelId":"alias","baseUrl":"http://127.0.0.1","contextWindow":100000,"maxOutputTokens":4096])
        let id = await traces.begin(session:"s",turn:"t",profile:profile,purpose:"turn",body:Data(repeating:120,count:65_537),headers:["Authorization":"Bearer x"])
        let body = try await traces.command("debug.body",session:"s",params:["attemptId":JSON(id),"body":"request"])
        XCTAssertEqual(body["state"].text,"credential-omitted"); XCTAssertEqual(body["captureBytes"].int,0); XCTAssertEqual(body["bytes"].text,"")
        XCTAssertTrue(body["transformations"].list.first?.text?.contains("No request-body bytes were retained") == true)
        await traces.delivered()
        let retained = await packets.values
        XCTAssertFalse(retained.contains { $0["type"].text == "bytes" })
    }
    func testDurablePacketsAndMetadataDistinguishHashedRequestFromOriginalResponse() async throws {
        let key = "private-fixture-key", packets = CredentialPackets()
        let traces = TraceStore { await packets.append($0) }
        _ = try await traces.command("debug.mode",session:"s",params:["mode":"persist"])
        let profile = try Profile(["id":"p","api":"openai-responses","providerId":"litellm","modelId":"alias","baseUrl":JSON("http://127.0.0.1/" + key),"contextWindow":100000,"maxOutputTokens":4096,"routing":["replayPolicy":"portable","reference":"fixture-v1","modelHeader":"x-actual-model"]])
        let original = Data(("{\"prompt\":\"" + key + "\"}").utf8)
        let id = await traces.begin(session:"s",turn:"t",profile:profile,purpose:"turn",body:original,headers:["Authorization":"Bearer " + key])
        await traces.head(id,status:200,headers:["x-request-id":key,"x-actual-model":key])
        await traces.reported(id,value:["model":JSON(key)],streaming:false)
        // Ordinary response bytes remain raw. Only known credential echoes are
        // an explicit, length-preserving capture exception.
        let response = Data("data: {\"ok\":true}\n\n".utf8)
        await traces.append(id,data:response)
        await traces.transport(id,observation:["transportOutcome":"eof"])
        // The helper's own copy, read before the app has saved the request.
        let retained = try await traces.command("debug.attempt",session:"s",params:["attemptId":JSON(id)])
        XCTAssertFalse(retained.encoded().contains(key))
        await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        await traces.delivered()
        let metadata = try await traces.command("debug.attempt",session:"s",params:["attemptId":JSON(id)])
        XCTAssertFalse(metadata.encoded().contains(key)); XCTAssertEqual(metadata["request"]["state"].text,"credential-hashed")
        XCTAssertEqual(metadata["request"]["observedBytes"].int,original.count); XCTAssertEqual(metadata["request"]["credentialRedactions"].int,1)
        XCTAssertEqual(metadata["request"]["byteExact"].flag,false); XCTAssertEqual(metadata["identity"]["status"].text,"incomplete")
        XCTAssertEqual(metadata["request"]["savedToLog"].flag,true)
        let all = await packets.values
        let requestBytes = all.filter { $0["type"].text == "bytes" && $0["body"].text == "request" }.reduce(into:Data()) { $0.append(Data(base64Encoded:$1["bytes"].text!)!) }
        XCTAssertEqual(String(decoding:requestBytes,as:UTF8.self),"{\"prompt\":\"" + CaptureCredentials.fingerprint(key) + "\"}")
        XCTAssertEqual(retained["requestHash"]["sha256"].text,sha256(requestBytes))
        for packet in all where packet["type"].text != "bytes" { XCTAssertFalse(packet.encoded().contains(key)) }
        let responseBytes = all.filter { $0["type"].text == "bytes" && $0["body"].text == "response" }.reduce(into:Data()) { $0.append(Data(base64Encoded:$1["bytes"].text!)!) }
        XCTAssertEqual(responseBytes,response)
        XCTAssertEqual(metadata["response"]["byteExact"].flag, true)
    }

    func testResponseMaskingAtEveryByteBoundaryKeepsUnicodeFormattingAndEscapedKeys() throws {
        let secret = "secret-\"quoted\\path/🙂", other = "private-api-key"
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer " + secret, "x-key": other], configuredNames: [])
        let escaped = String(JSON(secret).encoded().dropFirst().dropLast()).replacingOccurrences(of: "/", with: "\\/")
        let before = "data: {\"text\":\"中文🙂 ", middle = "\",\"other\":\"", after = "\"}\r\n\r\n"
        let original = Data((before + escaped + middle + other + after).utf8)
        let expected = Data((before + String(repeating: "*", count: escaped.utf8.count) + middle + String(repeating: "*", count: other.utf8.count) + after).utf8)
        for split in 0...original.count {
            var masker = CaptureCredentials.ResponseMasker(credentials)
            var captured = masker.feed(Data(original.prefix(split)))
            captured.append(masker.feed(Data(original.dropFirst(split))))
            captured.append(masker.feed(Data(), final: true))
            XCTAssertEqual(captured, expected, "split \(split)")
            XCTAssertEqual(masker.replacements, 2)
            XCTAssertEqual(captured.count, original.count, "SSE offsets must remain valid")
        }
        var oneByte = CaptureCredentials.ResponseMasker(credentials), captured = Data()
        for byte in original { captured.append(oneByte.feed(Data([byte]))) }
        captured.append(oneByte.feed(Data(), final: true))
        XCTAssertEqual(captured, expected)
    }

    func testResponseMaskingCoversOverlappingCredentialsAndLeavesUnrelatedBytesExact() {
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer ababa", "x-key": "bababa"], configuredNames: [])
        var masker = CaptureCredentials.ResponseMasker(credentials), captured = Data()
        for byte in Data("prefix ababababa suffix🙂".utf8) { captured.append(masker.feed(Data([byte]))) }
        captured.append(masker.feed(Data(), final: true))
        XCTAssertEqual(captured, Data("prefix ********* suffix🙂".utf8))
        XCTAssertEqual(masker.replacements, 5)
        var ordinary = CaptureCredentials.ResponseMasker(credentials)
        XCTAssertEqual(ordinary.feed(Data("中文 without credentials".utf8), final: true), Data("中文 without credentials".utf8))
        XCTAssertEqual(ordinary.replacements, 0)
    }

    func testCancelledAndFailedResponseCaptureFlushesMaskedTailWithContiguousDurableOffsets() async throws {
        for outcome in ["cancelled", "failed"] {
            let key = "private-fixture-key", packets = CredentialPackets()
            let traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": "persist"])
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
            let before = Data("{\"error\":\"Rejected ".utf8), response = before + Data(key.utf8)
            for byte in response { await traces.append(id, data: Data([byte])) }
            await traces.transport(id, observation: ["transportOutcome": JSON(outcome == "cancelled" ? "cancelled" : "error")])
            await traces.finish(id, outcome: outcome, modelOutcome: "interrupted")
            await traces.delivered()
            // The app saved it all, so it is read from the log: the durable
            // pages below are the capture.
            let captured = try await traces.command("debug.attempt", session: "s", params: ["attemptId": JSON(id)])["response"]
            let expected = before + Data(repeating: 42, count: key.utf8.count)
            XCTAssertEqual(captured["savedToLog"].flag, true); XCTAssertEqual(captured["retainedBytes"].int, expected.count)
            XCTAssertEqual(captured["state"].text, "partial"); XCTAssertEqual(captured["byteExact"].flag, false)
            XCTAssertEqual(captured["credentialRedactions"].int, 1)
            XCTAssertEqual(captured["observedBytes"].int, response.count)
            XCTAssertEqual(captured["captureBytes"].int, response.count)
            let emitted = await packets.values
            var durable = Data()
            for packet in emitted where packet["type"].text == "bytes" && packet["body"].text == "response" {
                XCTAssertEqual(packet["offset"].int, durable.count)
                durable.append(Data(base64Encoded: packet["bytes"].text!)!)
                XCTAssertFalse(String(decoding: durable, as: UTF8.self).contains(key))
            }
            XCTAssertEqual(durable, expected)
            let finish = try XCTUnwrap(emitted.last { $0["type"].text == "finish" })
            XCTAssertEqual(finish["metadata"]["response"]["byteExact"].flag, false)
            XCTAssertFalse(finish["metadata"]["response"]["transformations"].list.isEmpty)
            let announcement = try XCTUnwrap(emitted.firstIndex { $0["type"].text == "metadata" && $0["metadata"]["response"]["byteExact"].flag == false })
            let maskedPacket = try XCTUnwrap(emitted.firstIndex { $0["body"].text == "response" && (Data(base64Encoded: $0["bytes"].text ?? "")?.contains(42) ?? false) })
            XCTAssertLessThan(announcement, maskedPacket, "The live inspector must learn the exception before receiving transformed bytes")
        }
    }

    func testBufferedLiveResponseIsPartialNotTruncatedAndEmptyEOFFinalizes() async throws {
        let traces = TraceStore(), profile = try fixtureProfile()
        let id = await traces.begin(session: "live", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["Authorization": "Bearer private-fixture-key"])
        let original = Data(String(repeating: "ordinary text ", count: 10).utf8)
        await traces.append(id, data: original)
        let live = try await traces.command("debug.body", session: "live", params: ["attemptId": JSON(id), "body": "response"])
        XCTAssertEqual(live["state"].text, "partial")
        XCTAssertTrue(live["reason"].isNull, "A bounded masking suffix is not an 8 MiB overflow")
        await traces.transport(id, observation: ["transportOutcome": "eof"])
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let finished = try await traces.command("debug.body", session: "live", params: ["attemptId": JSON(id), "body": "response"])
        XCTAssertEqual(Data(base64Encoded: finished["bytes"].text!), original)
        XCTAssertEqual(finished["state"].text, "complete")
        let empty = await traces.begin(session: "empty", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["Authorization": "Bearer private-fixture-key"])
        await traces.transport(empty, observation: ["transportOutcome": "eof"])
        await traces.finish(empty, outcome: "failed", modelOutcome: "interrupted")
        let emptyBody = try await traces.command("debug.body", session: "empty", params: ["attemptId": JSON(empty), "body": "response"])
        XCTAssertEqual(emptyBody["state"].text, "complete"); XCTAssertEqual(emptyBody["captureBytes"].int, 0)
    }
}
