import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderClient: ModelClient {
    public let traces: TraceStore
    public init(traces: TraceStore) { self.traces=traces }
    /// Error text is shown outside the raw capture inspector. Reuse capture's
    /// credential replacement before bounding it so a clipped secret cannot leak.
    static func safeFailure(_ error: AgentError, credentials: CaptureCredentials) -> AgentError {
        let safe = credentials.requestBody(Data(error.message.utf8))
        let message = safe.omitted ? "Provider error details exceeded the display safety limit." : String(decoding: safe.bytes, as: UTF8.self)
        return AgentError(error.code, preview(message) + (message.utf8.count > 16_384 ? "\n[Error details truncated; inspect the retained request for more.]" : ""))
    }
    /// Profile custom headers can never replace transport, authentication or
    /// session/turn correlation headers.
    public static let transportOwnedHeaders: Set<String> = ["host","content-length","transfer-encoding","connection","authorization","x-api-key","x-session-id","x-turn-id"]
    /// Identities are already restricted to `[A-Za-z0-9._:-]`; anything else
    /// (a synthetic auxiliary id, for example) is reduced to that header-safe
    /// alphabet so a value can never inject a header line.
    public static func correlationValue(_ identity: String) -> String {
        var safe = String.UnicodeScalarView()
        for scalar in identity.unicodeScalars where scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar)) {
            safe.append(scalar); if safe.count >= 128 { break }
        }
        return safe.isEmpty ? "unknown" : String(safe)
    }
    public static func requestBody(profile p:Profile, messages:[ChatMessage], instructions:String, tools:[ToolDefinition], sessionID:String) throws -> JSON {
        let history=messages.filter(\.replayEligible)
        var body:JSON=["model":JSON(p.model),"stream":true]
        let sampling=p.raw["samplingParams"].map
        for key in ["temperature","top_p"] { if let value=sampling[key] { body[key]=value } }
        if p.api=="openai-responses" {
            body["store"]=false;body["instructions"]=JSON(instructions)
            // LiteLLM correlates Responses requests through body metadata as well as
            // the x-session-id header; both carry the same native session identity.
            body["metadata"]=["session_id":JSON(Self.correlationValue(sessionID))]
            // LiteLLM would otherwise answer a failing route from a fallback model;
            // the app wants the requested model or a visible error.
            if p.raw["compat"]["allowFallbacks"].flag != true { body["disable_fallbacks"]=true }
            // The cap on the wire is the model's own ceiling (or a bounded task's
            // explicit cap), never the output budget: a reply runs as far as the
            // model can take it.
            if let cap=p.wireOutputLimit { body["max_output_tokens"]=JSON(cap) }
            var input:[JSON]=[]
            for message in history {
                if message.role=="assistant", let items=try replayItems(message,profile:p) { input += items; continue }
                if message.role=="toolResult" {
                    guard let call=message.toolCallId else { throw AgentError("invalid_context","Tool result has no call identity") }
                    input.append(["type":"function_call_output","call_id":JSON(call),"output":JSON(message.text)]); continue
                }
                let content=message.content.compactMap { block -> JSON? in
                    if block["type"].text=="text" { return ["type":message.role=="assistant" ? "output_text":"input_text","text":block["text"]] }
                    if block["type"].text=="image",let data=block["data"].text,let mime=block["mimeType"].text { return ["type":"input_image","image_url":JSON("data:\(mime);base64,\(data)")] }
                    return nil
                }
                if !content.isEmpty { input.append(["type":"message","role":JSON(message.role=="assistant" ? "assistant":"user"),"content":.array(content)]) }
                if message.role == "assistant" {
                    for call in message.content where call["type"].text == "toolCall" {
                        input.append(["type":"function_call","call_id":call["id"],"name":call["name"],"arguments":JSON(call["arguments"].encoded())])
                    }
                }
            }
            body["input"] = .array(input)
            if !tools.isEmpty {
                body["tools"] = .array(tools.map { tool in
                    var value:JSON=["type":"function","name":JSON(tool.name),"description":JSON(tool.description),"parameters":tool.schema]
                    if p.raw["compat"]["supportsStrictMode"].flag != false { value["strict"]=false };return value
                })
                body["parallel_tool_calls"]=false
            }
            if p.raw["reasoning"].flag==true {
                body["include"]=["reasoning.encrypted_content"]
                if let level=p.raw["thinkingLevel"].text,level != "default" {
                    let effort=p.raw["thinkingLevelMap"][level].text ?? (level=="off" ? "none":level)
                    body["reasoning"]=["effort":JSON(effort),"summary":"auto"]
                }
            }
        } else {
            let messagesCap=p.outputCap ?? p.modelOutputLimit ?? p.maxOutput
            body["max_tokens"]=JSON(messagesCap);body["system"]=JSON(instructions)
            body["messages"] = .array(try history.compactMap { message -> JSON? in
                if message.role=="toolResult" { return ["role":"user","content":[["type":"tool_result","tool_use_id":JSON(message.toolCallId ?? ""),"content":JSON(message.text),"is_error":JSON(message.isError)]]] }
                let blocks: [JSON]
                if message.role=="assistant",let items=try replayItems(message,profile:p) { blocks=items }
                else { blocks=message.content.compactMap { block in
                    if block["type"].text=="text" { return block }
                    if block["type"].text=="toolCall", message.role == "assistant" { return ["type":"tool_use","id":block["id"],"name":block["name"],"input":block["arguments"]] }
                    if block["type"].text=="image" { return ["type":"image","source":["type":"base64","media_type":block["mimeType"],"data":block["data"]]] }
                    return nil
                } }
                guard !blocks.isEmpty else { return nil }
                return ["role":JSON(message.role=="assistant" ? "assistant":"user"),"content":.array(blocks)]
            })
            if !tools.isEmpty { body["tools"] = .array(tools.map{["name":JSON($0.name),"description":JSON($0.description),"input_schema":$0.schema]}) }
            if p.raw["reasoning"].flag==true, let level=p.raw["thinkingLevel"].text,level != "default" {
                if level=="off" { body["thinking"]=["type":"disabled"] }
                else if p.raw["compat"]["forceAdaptiveThinking"].flag==true {
                    body["thinking"]=["type":"adaptive"]
                    body["output_config"]=["effort":p.raw["thinkingLevelMap"][level].text.map { JSON($0) } ?? JSON(level)]
                    body=body.removing(["temperature","top_p"])
                } else {
                    guard messagesCap>1024 else { throw AgentError("thinking_budget","Messages thinking requires max output greater than 1024") }
                    let budgets=["minimal":1024,"low":2048,"medium":4096,"high":8192,"xhigh":16384,"max":32768]
                    body["thinking"]=["type":"enabled","budget_tokens":JSON(min(messagesCap-1,budgets[level] ?? 4096))]
                    body=body.removing(["temperature","top_p"])
                }
            }
        }
        return body
    }
    public func complete(profile:Profile, apiKey:String, messages:[ChatMessage], instructions:String, tools:[ToolDefinition], sessionID:String, turnID:String, purpose:String, onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        try Task.checkCancellation()
        let body=try Self.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID)
        let bytes=try body.data()
        guard bytes.count<=32*1024*1024 else { throw AgentError("request_limit","Serialized request exceeds 32 MiB") }
        var request=URLRequest(url:profile.endpoint);request.httpMethod="POST";request.httpBody=bytes
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        // Every gateway request names its native session and turn (a compaction or
        // auxiliary request carries that purpose's identity) for LiteLLM correlation.
        request.setValue(Self.correlationValue(sessionID),forHTTPHeaderField:"x-session-id")
        request.setValue(Self.correlationValue(turnID),forHTTPHeaderField:"x-turn-id")
        // LiteLLM authenticates both API routes with the configured proxy key.
        // The Messages route also accepts x-api-key for its native protocol.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if profile.api == "anthropic-messages" { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        if profile.api=="anthropic-messages" { request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version") }
        for (name,value) in profile.raw["headers"].map {
            guard !Self.transportOwnedHeaders.contains(name.lowercased()) else { throw AgentError("invalid_header","Transport-owned header cannot be overridden") }
            request.setValue(value.text,forHTTPHeaderField:name)
        }
        let credentials = CaptureCredentials(headers: request.allHTTPHeaderFields ?? [:], configuredNames: Set(profile.raw["headers"].map.keys))
        let attempt=await traces.begin(session:sessionID,turn:turnID,profile:profile,purpose:purpose,body:bytes,headers:request.allHTTPHeaderFields ?? [:],messageIDs:messages.flatMap { $0.sourceMessageIDs ?? [$0.id] })
        let stream=HTTPStream();var parser=SSEParser(), accumulator=ProviderAccumulator(api:profile.api)
        var status=0,jsonBody=false,nonSSE=Data(),receivedBytes=0
        var lastBodyAt:Double?
        var providerFailure:AgentError?
        do {
            try Task.checkCancellation()
            let parts = stream.start(request)
            let dispatch = stream.observation()
            await traces.dispatched(attempt, at: dispatch["dispatch"].double ?? nowMS(), wall: dispatch["dispatchWallTimestamp"].double ?? Date().timeIntervalSince1970)
            for try await part in parts {
                try Task.checkCancellation()
                switch part {
                case .head(let code,let headers): status=code;jsonBody=headers["content-type"]?.contains("application/json") == true;await traces.head(attempt,status:code,headers:headers)
                case .bytes(let data, let receivedAt):
                    defer { stream.consumed(data.count) }
                    lastBodyAt=receivedAt
                    await traces.append(attempt,data:data)
                    receivedBytes += data.count
                    guard receivedBytes <= 64*1024*1024 else { throw AgentError("response_limit","Response exceeded the 64 MiB safety limit; capture is explicitly partial") }
                    if status<200 || status>=300 { nonSSE.append(data.prefix(max(0, 65_536 - nonSSE.count))); continue }
                    if jsonBody { nonSSE.append(data);guard nonSSE.count<=16*1024*1024 else { throw AgentError("response_limit","JSON response exceeds 16 MiB") };continue }
                    for event in try parser.feed(data) {
                        await traces.event(attempt,event)
                        if event.data=="[DONE]" { continue }
                        let value=try JSON.parse(Data(event.data.utf8))
                        await traces.reported(attempt,value:value,streaming:true)
                        if ["response.failed", "error"].contains(value["type"].text ?? "") {
                            await traces.terminal(attempt,at:receivedAt)
                            providerFailure=ProviderAccumulator.failure(value)
                        }
                        if providerFailure != nil { continue }
                        for delta in try accumulator.consume(value) {
                            switch delta {
                            case .text(let text): if !text.isEmpty { await traces.content(attempt,text:true,at:receivedAt) }
                            case .thinking(let text): if !text.isEmpty { await traces.content(attempt,text:false,at:receivedAt) }
                            case .tool(_,let name,let args): if !name.isEmpty || !args.isEmpty { await traces.content(attempt,text:false,at:receivedAt) }
                            }
                            try await onDelta(delta)
                        }
                        if accumulator.terminal {
                            // Some gateways emit only final output. Its bytes
                            // are content evidence even without delta events.
                            if let reply=try? accumulator.result() {
                                if !reply.message.thinking.isEmpty || !reply.calls.isEmpty { await traces.content(attempt,text:false,at:receivedAt) }
                                if !reply.message.text.isEmpty { await traces.content(attempt,text:true,at:receivedAt) }
                            }
                            await traces.terminal(attempt,at:receivedAt)
                        }
                    }
                }
            }
            guard (200..<300).contains(status) else {
                let detail = (try? JSON.parse(nonSSE)).map { ProviderAccumulator.failure($0).message }
                throw AgentError("provider_http", "Provider returned HTTP \(status). " + Self.guidance(status: status, detail: detail, attempt: attempt))
            }
            if let providerFailure { throw providerFailure }
            if jsonBody {
                let value=try JSON.parse(nonSSE)
                await traces.reported(attempt,value:value,streaming:false)
                try accumulator.acceptJSON(value)
                let reply=try accumulator.result()
                if let time=lastBodyAt {
                    if !reply.message.thinking.isEmpty || !reply.calls.isEmpty { await traces.content(attempt,text:false,at:time) }
                    if !reply.message.text.isEmpty { await traces.content(attempt,text:true,at:time);try await onDelta(.text(reply.message.text)) }
                    await traces.terminal(attempt,at:time)
                }
            }
            var result=try accumulator.result(); result.message.requestAttemptIDs=[attempt]
            result.message.providerIdentity=await traces.identity(attempt)
            result.message.providerBinding=try Self.replayBinding(profile); await traces.usage(attempt,result.usage)
            await traces.transport(attempt,observation:await stream.endObservation())
            await traces.finish(attempt,outcome:result.truncated ? "truncated":"completed",modelOutcome:result.truncated ? "truncated":"completed")
            return result
        } catch {
            stream.cancel()
            let cancelled=Task.isCancelled || (error as? URLError)?.code == .cancelled
            await traces.transport(attempt,observation:await stream.endObservation())
            await traces.finish(attempt,outcome:cancelled ? "cancelled":"failed",modelOutcome:providerFailure != nil ? "failed":"interrupted")
            if cancelled { throw CancellationError() }
            if let e=error as? AgentError { throw Self.safeFailure(e, credentials: credentials) }
            throw AgentError("provider_transport", Self.transportGuidance(error, attempt: attempt))
        }
    }
    /// What to do about a gateway status, after the status itself: the
    /// provider's own detail when it sent one, then the likely cause in the
    /// reader's terms, then where the captured body is when nothing else helps.
    public static func guidance(status: Int, detail: String?, attempt: String) -> String {
        let hint: String
        switch status {
        case 401, 403: hint = "The gateway rejected the API key or this model's access; check the key in Settings."
        case 404: hint = "The gateway has no such route or model; check the base URL and the model alias in Settings."
        case 429: hint = "The gateway is rate limiting or out of quota; try again shortly."
        case 300...399: hint = "The gateway redirected the request; use its final Responses URL in Settings."
        case 500...599: hint = "The gateway failed on its side; try again, and check the gateway if it keeps failing."
        default: hint = ""
        }
        var parts: [String] = []
        if let detail, !detail.isEmpty { parts.append(detail.hasSuffix(".") ? detail : detail + ".") }
        if !hint.isEmpty { parts.append(hint) }
        if detail == nil || detail?.isEmpty == true { parts.append("Inspect request \(attempt) for the captured body.") }
        return parts.joined(separator: " ")
    }
    /// A transport failure named by its cause: an unknown host, a refused
    /// connection, a timeout or an untrusted certificate, each with what to check.
    public static func transportGuidance(_ error: Error, attempt: String) -> String {
        let cause: String
        switch (error as? URLError)?.code {
        case .cannotFindHost?, .dnsLookupFailed?: cause = "The gateway's host could not be found; check the base URL in Settings."
        case .cannotConnectToHost?, .networkConnectionLost?, .notConnectedToInternet?: cause = "The gateway could not be reached; check the base URL, that the gateway is running, and your network."
        case .timedOut?: cause = "The gateway did not answer in time."
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?, .serverCertificateNotYetValid?:
            cause = "The gateway's TLS certificate was not trusted; check the URL and the certificate."
        default: cause = "The provider request failed or its stream was malformed."
        }
        return cause + " Inspect request \(attempt)."
    }
}

public struct ProviderAccumulator: Sendable {
    let api:String
    var root:JSON=[:], items:[Int:JSON]=[:], arguments:[Int:String]=[:], terminal=false
    var openBlocks=Set<Int>()
    public init(api:String) { self.api=api }
    static func failure(_ value: JSON, fallback: String = "Provider reported an error without a message.") -> AgentError {
        let detail = value["response"]["error"].isNull ? value["error"] : value["response"]["error"]
        let message = [detail["message"].text, detail.text, value["message"].text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let code = [detail["code"].text, detail["type"].text, value["code"].text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return AgentError("provider_failed", (message ?? fallback) + (code.map { " (\($0))" } ?? ""))
    }
    public mutating func acceptJSON(_ value:JSON) throws {
        root=value;terminal=true
        if api=="openai-responses", !["completed","incomplete"].contains(value["status"].text ?? "") { throw Self.failure(value, fallback: "Responses JSON did not contain a successful terminal status") }
        if api=="anthropic-messages",value["type"].text != "message" { throw Self.failure(value, fallback: "Messages JSON did not contain a message") }
    }
    public mutating func consume(_ value:JSON) throws -> [StreamDelta] {
        guard let type=value["type"].text else { return [] }
        if type=="error" || type=="response.failed" { throw Self.failure(value) }
        if api=="openai-responses" {
            switch type {
            case "response.output_item.added","response.output_item.done":
                guard let index=value["output_index"].int else { throw AgentError("invalid_stream","Missing output item index") };items[index]=value["item"]
                if value["item"]["type"].text=="function_call" { return [.tool(value["item"]["call_id"].text ?? "",value["item"]["name"].text ?? "","")] }
            case "response.output_text.delta","response.refusal.delta": return [.text(value["delta"].text ?? "")]
            case "response.reasoning_summary_text.delta","response.reasoning_text.delta":return [.thinking(value["delta"].text ?? "")]
            case "response.function_call_arguments.delta":
                let index=value["output_index"].int ?? items.first(where:{$0.value["id"]==value["item_id"]})?.key
                guard let index,let item=items[index] else { throw AgentError("invalid_stream","Tool argument delta preceded its item") }
                let delta=value["delta"].text ?? "";arguments[index,default:""] += delta
                guard (arguments[index]?.utf8.count ?? 0) <= 2*1024*1024 else { throw AgentError("tool_argument_limit","Tool arguments exceed 2 MiB") }
                return [.tool(item["call_id"].text ?? "",item["name"].text ?? "",delta)]
            case "response.completed","response.incomplete": try acceptJSON(value["response"])
            default:break
            }
        } else {
            switch type {
            case "message_start":root=value["message"]
            case "content_block_start":
                guard let index=value["index"].int else { throw AgentError("invalid_stream","Missing block index") };guard !openBlocks.contains(index), items[index] == nil else { throw AgentError("invalid_stream","Duplicate content block index") }; openBlocks.insert(index);items[index]=value["content_block"]
                if value["content_block"]["type"].text=="text", let text=value["content_block"]["text"].text, !text.isEmpty { return [.text(text)] }
                if value["content_block"]["type"].text=="thinking", let text=value["content_block"]["thinking"].text, !text.isEmpty { return [.thinking(text)] }
                if value["content_block"]["type"].text=="tool_use" { return [.tool(value["content_block"]["id"].text ?? "",value["content_block"]["name"].text ?? "","")] }
            case "content_block_delta":
                guard let index=value["index"].int,var block=items[index] else { throw AgentError("invalid_stream","Delta preceded its content block") }
                let delta=value["delta"],kind=delta["type"].text
                if kind=="text_delta" { let t=delta["text"].text ?? "";block["text"]=JSON((block["text"].text ?? "")+t);items[index]=block;return [.text(t)] }
                if kind=="thinking_delta" { let t=delta["thinking"].text ?? "";block["thinking"]=JSON((block["thinking"].text ?? "")+t);items[index]=block;return [.thinking(t)] }
                if kind=="signature_delta" { block["signature"]=JSON((block["signature"].text ?? "")+(delta["signature"].text ?? ""));items[index]=block }
                if kind=="input_json_delta" {
                    let t=delta["partial_json"].text ?? "";arguments[index,default:""] += t
                    guard (arguments[index]?.utf8.count ?? 0) <= 2*1024*1024 else { throw AgentError("tool_argument_limit","Tool arguments exceed 2 MiB") }
                    return [.tool(block["id"].text ?? "",block["name"].text ?? "",t)]
                }
            case "content_block_stop":
                guard let index=value["index"].int, openBlocks.remove(index) != nil else { throw AgentError("invalid_stream","Unknown or duplicate content block stop") }
                if let text=arguments.removeValue(forKey:index),var block=items[index] {
                    block["input"]=try JSON.parse(Data(text.utf8));items[index]=block
                }
            case "message_delta":
                for (k,v) in value["delta"].map { root[k]=v }
                var usage=root["usage"];for (k,v) in value["usage"].map { usage[k]=v };root["usage"]=usage
            case "message_stop":
                guard openBlocks.isEmpty, arguments.isEmpty, root["stop_reason"].text != nil else { throw AgentError("incomplete_stream","Messages ended before all blocks and stop reason completed") }
                root["content"] = .array(items.keys.sorted().compactMap{items[$0]});terminal=true
            default:break
            }
        }
        return []
    }
    public func result() throws -> ModelReply {
        guard terminal else { throw AgentError("incomplete_stream","The stream ended without its terminal event. No tool arguments were executed.") }
        var message=ChatMessage(role:"assistant",content:[]),calls:[ToolCall]=[]
        let rawContent=api=="openai-responses" ? root["output"]:root["content"]
        guard case .array(let raw)=rawContent else { throw AgentError("invalid_stream","Missing terminal output array") }
        message.providerItems=raw
        let truncated=api=="openai-responses" ? root["status"].text=="incomplete":root["stop_reason"].text=="max_tokens"
        for item in raw {
            switch item["type"].text {
            case "message":
                for part in item["content"].list {
                    if let text=part["text"].text { message.content.append(textBlock(text)) }
                    else if let refusal=part["refusal"].text { message.content.append(textBlock(refusal)) }
                }
            case "text":message.content.append(textBlock(item["text"].text ?? ""))
            case "reasoning":
                let text=item["summary"].list.compactMap{$0["text"].text}.joined(separator:"\n")
                if !text.isEmpty { message.content.append(["type":"thinking","thinking":JSON(text)]) }
            case "thinking":message.content.append(["type":"thinking","thinking":item["thinking"]])
            case "function_call","tool_use":
                let id=try required(item[api=="openai-responses" ? "call_id":"id"],"tool call id",maximum:512),name=try required(item["name"],"tool name",maximum:256)
                let args:JSON
                if api=="openai-responses" {
                    if truncated { args=(try? JSON.parse(Data((item["arguments"].text ?? "{}").utf8))) ?? [:] }
                    else { guard let text=item["arguments"].text else { throw AgentError("invalid_tool_arguments","Missing serialized function arguments") }; args=try JSON.parse(Data(text.utf8)) }
                } else { args=item["input"] }
                guard truncated || args.isObject else { throw AgentError("invalid_tool_arguments","Tool arguments must be a complete JSON object") }
                calls.append(ToolCall(id:id,name:name,arguments:args));message.content.append(["type":"toolCall","id":JSON(id),"name":JSON(name),"arguments":args])
            default:break // Opaque and future content remains retained in providerItems.
            }
        }
        guard Set(calls.map(\.id)).count==calls.count,calls.count<=64 else { throw AgentError("invalid_tool_calls","Duplicate tool identities or excessive tool calls") }
        let usage = UsageObservation.normalized(root["usage"], api: api)
        return ModelReply(message:message,calls:calls,usage:usage,truncated:truncated)
    }
}
