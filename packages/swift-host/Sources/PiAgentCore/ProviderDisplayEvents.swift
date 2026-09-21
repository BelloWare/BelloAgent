import Foundation

/// Observes the validated provider boundary without taking over accumulation,
/// tool validation, retry policy, or canonical replay items.
struct ProviderDisplayEvents {
    let api: String
    let attempt: String
    init(api: String, attempt: String) { self.api = api; self.attempt = attempt }
    private var ordinal = 0
    private var items: [Int: JSON] = [:]
    var timeline = ResponseTimeline()
    private mutating func make(index: Int?, item: String?, part: Int?, kind: String, update: String, text: String = "", call: String? = nil, name: String? = nil, sequence: Int? = nil, at: Double?, evidence: String = "observed") -> ResponsePartEvent {
        ordinal += 1
        return ResponsePartEvent(attemptID: attempt, ordinal: ordinal, itemID: ResponseTimeline.prefix(item ?? index.map { "output-\($0)" } ?? "unknown", bytes: 256), outputIndex: index, partIndex: part, providerSequence: sequence, kind: kind, update: update, text: text, callID: call.map { ResponseTimeline.prefix($0, bytes: 256) }, name: name.map { ResponseTimeline.prefix($0, bytes: 128) }, observedAt: at, evidence: evidence)
    }
    mutating func consume(_ value: JSON, at: Double?, json: Bool = false) -> [ResponsePartEvent] {
        var events: [ResponsePartEvent] = []
        let type = value["type"].text ?? "", sequence = value["sequence_number"].int
        if json || type == "response.completed" || type == "response.incomplete" || type == "message_stop" {
            let root = json ? value : value["response"]
            if api == "openai-responses" { events = canonical(root["output"].list, at: at) }
            else if json { events = canonical(root["content"].list, at: at) }
        } else if api == "openai-responses" {
            let index = value["output_index"].int
            let itemID = value["item_id"].text ?? index.flatMap { items[$0]?["id"].text }
            let part = value["content_index"].int ?? value["summary_index"].int ?? 0
            if type == "response.output_item.added" || type == "response.output_item.done", let index {
                let item = value["item"]; items[index] = item
                let kind = item["type"].text ?? "unknown"
                if kind == "function_call" {
                    events.append(make(index:index,item:item["id"].text,part:0,kind:"toolArguments",update:type.hasSuffix("added") ? "begin":"replace",text:item["arguments"].text ?? "",call:item["call_id"].text,name:item["name"].text,sequence:sequence,at:at))
                } else if !["message","reasoning"].contains(kind) {
                    events.append(make(index:index,item:item["id"].text,part:0,kind:"opaque",update:type.hasSuffix("added") ? "begin":"end",text:"Provider item: \(kind) (opaque)",sequence:sequence,at:at))
                }
            } else {
                let kind: String?
                if type.hasPrefix("response.content_part.") {
                    switch value["part"]["type"].text {
                    case "output_text": kind = "text"
                    case "refusal": kind = "refusal"
                    default: kind = "opaque"
                    }
                }
                else if type.contains("output_text") { kind = "text" }
                else if type.contains("refusal") { kind = "refusal" }
                else if type.contains("reasoning_summary") { kind = "reasoningSummary" }
                else if type.contains("reasoning_text") { kind = "reasoningText" }
                else if type.contains("function_call_arguments") { kind = "toolArguments" }
                else { kind = nil }
                if let kind {
                    let update = type.hasSuffix(".delta") ? "append" : type.hasSuffix(".done") ? "replace" : "begin"
                    let text = value["delta"].text ?? value["text"].text ?? value["arguments"].text ?? value["refusal"].text ?? value["part"]["text"].text ?? value["part"]["refusal"].text ?? ""
                    let item = index.flatMap { items[$0] } ?? .null
                    events.append(make(index:index,item:itemID,part:part,kind:kind,update:update,text:text,call:item["call_id"].text,name:item["name"].text,sequence:sequence,at:at))
                    if update == "replace" { events.append(make(index:index,item:itemID,part:part,kind:kind,update:"end",sequence:sequence,at:at)) }
                }
            }
        } else if let index = value["index"].int {
            if type == "content_block_start" { items[index] = value["content_block"] }
            let item = items[index] ?? .null, delta = value["delta"]
            let blockType = item["type"].text ?? "unknown"
            let kind = blockType == "text" ? "text" : blockType == "thinking" ? "reasoningText" : blockType == "tool_use" ? "toolArguments" : "opaque"
            if type == "content_block_start" || type == "content_block_stop" || (type == "content_block_delta" && delta["type"].text != "signature_delta") {
                let text = type == "content_block_start" ? (item["text"].text ?? item["thinking"].text ?? (kind == "opaque" ? "Provider item: \(blockType) (opaque)":"")) : delta["text"].text ?? delta["thinking"].text ?? delta["partial_json"].text ?? ""
                events.append(make(index:index,item:item["id"].text,part:0,kind:kind,update:type == "content_block_start" ? "begin" : type == "content_block_stop" ? "end":"append",text:text,call:item["id"].text,name:item["name"].text,at:at))
            }
        }
        for event in events { timeline.consume(event) }
        if json || ["response.completed","response.incomplete","message_stop"].contains(type) { timeline.finish(json ? (value["status"].text ?? "completed") : value["response"]["status"].text ?? "completed") }
        return events
    }
    private mutating func canonical(_ output: [JSON], at: Double?) -> [ResponsePartEvent] {
        var events: [ResponsePartEvent] = []
        for (index,item) in output.enumerated() {
            let itemID = item["id"].text
            func parts(_ parts: [JSON], kind: String?) {
                for (partIndex,part) in parts.enumerated() {
                    let text = part["text"].text ?? part["refusal"].text ?? ""
                    events.append(make(index:index,item:itemID,part:partIndex,kind:kind ?? (part["type"].text == "refusal" ? "refusal":"text"),update:"replace",text:text,at:at,evidence:"canonical"))
                }
            }
            switch item["type"].text {
            case "message": parts(item["content"].list, kind:nil)
            case "reasoning":
                parts(item["summary"].list,kind:"reasoningSummary"); parts(item["content"].list,kind:"reasoningText")
                if item["summary"].list.isEmpty && item["content"].list.isEmpty { events.append(make(index:index,item:itemID,part:0,kind:"opaque",update:"replace",text:"Opaque reasoning item · no returned reasoning text",at:at,evidence:"canonical")) }
            case "text", "thinking":
                events.append(make(index:index,item:itemID,part:0,kind:item["type"].text == "text" ? "text":"reasoningText",update:"replace",text:item["text"].text ?? item["thinking"].text ?? "",at:at,evidence:"canonical"))
            case "function_call", "tool_use":
                events.append(make(index:index,item:itemID,part:0,kind:"toolArguments",update:"replace",text:item["arguments"].text ?? item["input"].encoded(),call:item["call_id"].text ?? item["id"].text,name:item["name"].text,at:at,evidence:"canonical"))
            default: events.append(make(index:index,item:itemID,part:0,kind:"opaque",update:"replace",text:"Provider item: \(item["type"].text ?? "unknown") (opaque)",at:at,evidence:"canonical"))
            }
        }
        return events
    }
}
