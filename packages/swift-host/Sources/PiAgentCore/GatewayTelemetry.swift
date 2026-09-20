import Foundation

/// Per-attempt gateway reports, never local price estimates. In particular,
/// an HTTP header sent before a stream is generated cannot prove final cost.
/// See docs/LiteLLM-Accounting-Contract.md for the observed upstream contracts.
struct GatewayTelemetry: Sendable {
    let api: String, cacheHeader: String?
    private var costs: [JSON] = [], cacheValues: Set<Bool> = []
    private var invalidCost = false, invalidCache = false, streaming = true
    private var headerCost: JSON = .null, callID: String?, version: String?
    // Owner-supplied LiteLLM response headers. Components are observations,
    // never extra charges added to the reported total. In particular reasoning
    // is an output-cost subset, and classifier cost may already be included.
    private static let componentHeaders = ["input":"x-litellm-response-cost-input", "output":"x-litellm-response-cost-output", "reasoning":"x-litellm-response-cost-reasoning", "toolUsage":"x-litellm-response-cost-tool-usage", "classifier":"x-litellm-classifier-cost", "original":"x-litellm-response-cost-original", "discount":"x-litellm-response-cost-discount-amount", "margin":"x-litellm-response-cost-margin-amount"]
    private var componentCosts: [String:[JSON]] = [:], invalidComponents = Set<String>()
    init(profile: Profile) { api = profile.api; cacheHeader = profile.raw["routing"]["cacheHeader"].text?.lowercased() }
    var headers: Set<String> { Set(["x-litellm-response-cost", "x-litellm-call-id", "x-litellm-version", "x-litellm-response-cost-margin-percent"] + Array(Self.componentHeaders.values) + (cacheHeader.map { [$0] } ?? [])) }
    mutating func head(_ headers: [String: String], excluding credential: (String) -> Bool) {
        streaming = !(headers["content-type"]?.lowercased().contains("application/json") ?? false)
        if let text = headers["x-litellm-response-cost"] {
            // Keep a bounded numeric observation for Inspector, but do not count
            // streaming header placeholders as a completed zero-cost request.
            if let cost = Self.number(JSON(text)), !credential(text) { headerCost = JSON(cost) }
            else if !streaming { invalidCost = true }
        }
        for (component,name) in Self.componentHeaders {
            guard let text=headers[name] else { continue }
            guard let amount=Self.number(JSON(text)), !credential(text) else { invalidComponents.insert(component); continue }
            let evidence:JSON=["usd":JSON(amount),"source":JSON("header:"+name)]
            guard !(componentCosts[component] ?? []).contains(evidence) else { continue }
            guard (componentCosts[component]?.count ?? 0)<16 else { invalidComponents.insert(component); continue }
            componentCosts[component,default:[]].append(evidence)
        }
        for (name, field) in [("x-litellm-call-id", 0), ("x-litellm-version", 1)] {
            guard let text = headers[name], !text.isEmpty, text.utf8.count <= 128, !text.utf8.contains(where: { $0 < 32 || $0 > 126 }), !credential(text) else { continue }
            if field == 0 { callID = text } else { version = text }
        }
        if let name = cacheHeader, let value = headers[name] {
            guard value.utf8.count <= 16, !credential(value) else { invalidCache = true; return }
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "hit": cacheValues.insert(true)
            case "false", "miss": cacheValues.insert(false)
            default: invalidCache = true
            }
        }
    }
    mutating func body(_ value: JSON, streaming: Bool, excluding credential: (String) -> Bool) {
        self.streaming = streaming
        let usage: JSON, source: String
        if !streaming { usage = value["usage"]; source = "body.usage" }
        else if api == "openai-responses", ["response.completed", "response.incomplete", "response.failed"].contains(value["type"].text ?? "") {
            usage = value["response"]["usage"]; source = (value["type"].text ?? "") + ".response.usage"
        } else if api == "anthropic-messages", value["type"].text == "message_delta", let stop = value["delta"]["stop_reason"].text, !stop.isEmpty {
            usage = value["usage"]; source = "message_delta.usage"
        } else { return }
        // Current upstream stamps usage.cost. Accept usage.response_cost as
        // a compatibility field, preserving provenance and disagreement.
        // Explicit JSON null means no amount was reported, not zero or an
        // invalid number; another final numeric source may still supply it.
        for field in ["cost", "response_cost"] where !usage[field].isNull {
            guard let cost = Self.number(usage[field]), !credential(usage[field].text ?? "") else { invalidCost = true; continue }
            let evidence: JSON = ["usd":JSON(cost), "source":JSON(source + "." + field)]
            guard !costs.contains(evidence) else { continue }
            guard costs.count < 16 else { invalidCost = true; continue }
            costs.append(evidence)
        }
    }
    private static func number(_ value: JSON) -> Double? {
        let number: Double?
        if let text = value.text { guard text.utf8.count <= 64 else { return nil }; number = Double(text) }
        else { number = value.double }
        guard let number, number.isFinite, number >= 0, number <= 1_000_000_000_000 else { return nil }
        return number
    }
    var json: JSON {
        var evidence = costs
        if !streaming, !headerCost.isNull { evidence.append(["usd":headerCost,"source":"header:x-litellm-response-cost"]) }
        let amounts = Set(evidence.compactMap { $0["usd"].double })
        let costState = invalidCost ? "invalid" : amounts.count > 1 ? "conflict" : amounts.isEmpty ? "unreported" : "reported"
        let cacheState = invalidCache ? "invalid" : cacheValues.count > 1 ? "conflict" : cacheValues.first.map { $0 ? "hit" : "miss" } ?? "unreported"
        var breakdown:[String:JSON]=[:]
        for component in Self.componentHeaders.keys {
            let observations=componentCosts[component] ?? [], values=Set(observations.compactMap { $0["usd"].double })
            let observedState=invalidComponents.contains(component) ? "invalid" : values.count>1 ? "conflict" : values.isEmpty ? "unreported" : "reported"
            let state=streaming ? "unreported":observedState
            breakdown[component]=["status":JSON(state),"usd":state=="reported" ? values.first.map { JSON($0) } ?? .null : .null,
                                  "source":streaming || observations.isEmpty ? .null : JSON(observations.compactMap { $0["source"].text }.sorted().joined(separator:", ")),
                                  "evidence":.array(streaming ? []:observations),
                                  "streamingHeaderUSD":streaming && observedState=="reported" ? values.first.map { JSON($0) } ?? .null : .null,
                                  "streamingHeaderStatus":streaming ? JSON(observedState):.null]
        }
        if var reasoning=breakdown["reasoning"], reasoning["status"].text=="reported", let amount=reasoning["usd"].double {
            let total=costState=="reported" ? amounts.first:nil
            let output=breakdown["output"]?["status"].text=="reported" ? breakdown["output"]?["usd"].double:nil
            // Allow normal floating-point serialization noise, not a reasoning
            // subset larger than an independently reported output/total cost.
            if [total,output].compactMap({$0}).contains(where:{amount > $0+max(1e-12,abs($0)*1e-9)}) {
                reasoning["status"]="conflict"; reasoning["usd"] = .null; breakdown["reasoning"]=reasoning
            }
        }
        return ["version":1,
                "cost":["usd":costState == "reported" ? amounts.first.map { JSON($0) } ?? .null : .null,"status":JSON(costState),"source":evidence.isEmpty ? .null : JSON(evidence.compactMap { $0["source"].text }.sorted().joined(separator:", ")),"evidence":.array(evidence),"streamingHeaderUSD":streaming ? headerCost : .null],
                "cache":["status":JSON(cacheState),"source":cacheState == "unreported" ? .null : cacheHeader.map { JSON("header:" + $0) } ?? .null],
                "costBreakdown":.object(breakdown),
                "callId":callID.map { JSON($0) } ?? .null,"gatewayVersion":version.map { JSON($0) } ?? .null,
                "boundary":"Gateway-reported USD per local HTTP attempt; not a bill or estimate. Components are not added to total; reasoning is an output subset and classifier cost is separate evidence. Pre-stream cost headers and components are excluded from final cost. Response-cache HIT/MISS requires an explicit gateway header contract; provider prompt-cache tokens are separate."]
    }
}
