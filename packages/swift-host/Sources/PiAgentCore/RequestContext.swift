import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// One count contract for preview, dispatch preflight and compaction. The input
/// is the actual provider request builder's output, never transcript blocks.
struct RequestContextCount: Sendable {
    let tokens: Int
    let method: String
    let requestedModel: String
    let countedModel: String?
    let requestFingerprint: String
    let source: String
    let warnings: [String]
    let contextWindow: Int
    let outputBudget: Int
    let modelOutputLimit: Int?
    var safetyMargin: Int { min(1024, max(1, contextWindow / 100)) }
    var inputBudget: Int { max(0, contextWindow - outputBudget - safetyMargin) }
    var fits: Bool { tokens <= inputBudget }
    var json: JSON {
        ["tokens":JSON(tokens), "method":JSON(method), "requestedModel":JSON(requestedModel),
         "countedModel":countedModel.map { JSON($0) } ?? .null, "requestFingerprint":JSON(requestFingerprint),
         "estimated":true, "source":JSON(source), "warnings":.array(warnings.map { JSON($0) }),
         "contextWindow":JSON(contextWindow), "outputBudget":JSON(outputBudget), "outputReserve":JSON(outputBudget),
         "modelOutputLimit":modelOutputLimit.map { JSON($0) } ?? .null, "safetyMargin":JSON(safetyMargin),
         "inputBudget":JSON(inputBudget), "fits":JSON(fits), "percent":JSON(Double(tokens) / Double(contextWindow) * 100),
         "countEndpointStatus":"unverified-request-compatibility"]
    }
}

/// Usage applies only to the exact previous input prefix and a declared stable
/// route. Previous output usage is never added: only items actually replayed by
/// the next request builder contribute to the new-input estimate.
struct RequestUsageBaseline: Sendable {
    let template: String
    let itemHashes: [String]
    let inputTokens: Int
    let model: String
    init?(request: JSON, profile: Profile, reply: ModelReply) throws {
        guard profile.raw["routing"]["replayPolicy"].text == "pinned",
              let expected = profile.raw["routing"]["expectedModel"].text,
              let identity = reply.message.providerIdentity, identity["status"].text == "reported",
              let model = identity["effectiveModel"].text,
              RequestContextCounter.modelName(model) == RequestContextCounter.modelName(expected),
              let input = reply.usage["input"].int, input >= 0 else { return nil }
        template = try RequestContextCounter.template(request, profile:profile)
        itemHashes = try RequestContextCounter.items(request).map { sha256(try $0.data()) }
        inputTokens = input + (profile.api == "anthropic-messages" ? (reply.usage["cacheRead"].int ?? 0) + (reply.usage["cacheWrite"].int ?? 0) : 0)
        self.model = model
    }
}

struct RequestContextCounter: Sendable {
    private struct Cached: Sendable { let value: RequestContextCount; let at: Date }
    private var cache: [String: Cached] = [:]

    mutating func count(request: JSON, profile: Profile, baseline: RequestUsageBaseline? = nil, now: Date = Date()) throws -> RequestContextCount {
        let fingerprint = try Self.fingerprint(request, profile:profile)
        // A new measured baseline is new evidence even for the same request.
        let cacheKey = fingerprint + (baseline.map { ":\($0.template):\($0.inputTokens):\(sha256(Data($0.itemHashes.joined().utf8))):\($0.model)" } ?? "")
        if let cached = cache[cacheKey], now.timeIntervalSince(cached.at) < 300 { return cached.value }
        let input = Self.items(request)
        var counter = InputHeuristic(model:profile.raw["routing"]["replayPolicy"].text == "pinned" ? profile.raw["routing"]["expectedModel"].text.map(Self.modelName) : nil)
        var method = "heuristic", countedModel: String?, tokens: Int
        if let baseline, baseline.template == (try Self.template(request, profile:profile)), input.count >= baseline.itemHashes.count,
           try Array(input.prefix(baseline.itemHashes.count)).map({ sha256(try $0.data()) }) == baseline.itemHashes {
            method = "usage-baseline"; countedModel = baseline.model
            tokens = baseline.inputTokens + counter.count(.array(Array(input.dropFirst(baseline.itemHashes.count))))
        } else {
            tokens = counter.count(Self.modelInput(request))
        }
        var warnings = ["Estimate, not an exact tokenizer or independently verified billing usage."]
        if profile.raw["routing"]["replayPolicy"].text != "pinned" {
            warnings.append("The next routed model is not fixed. This estimate cannot establish capacity for every possible backend.")
        }
        if profile.api == "openai-responses", request["max_output_tokens"].isNull {
            warnings.append("The gateway compatibility setting omits the output limit. The configured output budget is reserved locally but is not sent as a server-enforced cap.")
        }
        warnings += counter.warnings
        warnings.append("LiteLLM counting endpoints are not used without a request-compatible counting and routing contract.")
        let result = RequestContextCount(tokens:tokens, method:method, requestedModel:profile.model, countedModel:countedModel,
            requestFingerprint:fingerprint,
            source:method == "usage-baseline" ? "Gateway-reported input for an unchanged prefix, plus an estimate of newly replayed request items" : "Prepared request UTF-8/3 estimate, including actual instructions, tools and replayed items",
            warnings:warnings, contextWindow:profile.contextWindow, outputBudget:profile.maxOutput, modelOutputLimit:profile.modelOutputLimit)
        cache = cache.filter { now.timeIntervalSince($0.value.at) < 300 }
        if cache.count >= 32, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache.removeValue(forKey:oldest) }
        cache[cacheKey] = Cached(value:result,at:now)
        return result
    }
    static func modelName(_ name: String) -> String { name.hasPrefix("openai/") ? String(name.dropFirst(7)) : name }
    static func items(_ request: JSON) -> [JSON] { request["input"].isNull ? request["messages"].list : request["input"].list }
    private static func configuration(_ profile: Profile) -> JSON {
        // Header/credential-dependent routing is part of the hash, never of the
        // displayed metadata. Profile revision also invalidates all old counts.
        ["profile":profile.raw, "endpoint":JSON(profile.endpoint.absoluteString), "version":1]
    }
    static func fingerprint(_ request: JSON, profile: Profile) throws -> String {
        sha256(try JSON.object(["request":request,"configuration":configuration(profile)]).data())
    }
    static func template(_ request: JSON, profile: Profile) throws -> String {
        sha256(try JSON.object(["request":request.removing(["input","messages"]),"configuration":configuration(profile)]).data())
    }
    static func modelInput(_ request: JSON) -> JSON {
        .object(request.map.filter { ["instructions","input","messages","system","tools","text","tool_choice"].contains($0.key) })
    }
}

/// JSON overhead scales with the actual schema rather than a fixed 2,048-token
/// allowance. Image bytes are never mistaken for model-facing base64 text.
private struct InputHeuristic {
    let model: String?
    var warnings: [String] = []
    private var imageTokens = 0
    init(model: String?) { self.model = model }
    mutating func count(_ value: JSON) -> Int {
        if value.list.isEmpty && value.map.isEmpty && value.text == nil { return 0 }
        let projected = project(value)
        return (projected.encoded().utf8.count + 2) / 3 + imageTokens
    }
    private mutating func warn(_ warning: String) { if !warnings.contains(warning) { warnings.append(warning) } }
    private mutating func project(_ value: JSON) -> JSON {
        if case .array(let items) = value { return .array(items.map { project($0) }) }
        guard case .object(let fields) = value else { return value }
        if ["input_image","image"].contains(value["type"].text ?? "") {
            let url = value["image_url"].text, encoded = value["source"]["data"].text ?? url.flatMap { $0.hasPrefix("data:") ? $0.components(separatedBy:",").dropFirst().joined(separator:",") : nil }
            let size = encoded.flatMap { Self.dimensions($0) }
            imageTokens += imageCost(width:size?.0,height:size?.1,detail:value["detail"].text ?? "auto")
            return ["type":value["type"],"detail":value["detail"],"width":size.map { JSON($0.0) } ?? .null,"height":size.map { JSON($0.1) } ?? .null]
        }
        if !value["encrypted_content"].isNull || ["reasoning","redacted_thinking"].contains(value["type"].text ?? "") {
            warn("Opaque reasoning replay uses a ciphertext-size allowance; its real context cost is unknown and is not inferred from previous output tokens.")
        }
        return .object(fields.mapValues { project($0) })
    }
    private mutating func imageCost(width: Int?, height: Int?, detail: String) -> Int {
        guard let width, let height else {
            warn("Image dimensions are unavailable; a 16,384-token image allowance is uncertain, not a capacity guarantee.")
            return 16_384
        }
        let w = Double(width), h = Double(height)
        if let model, ["gpt-4o","gpt-4.1","gpt-4o-mini"].contains(model) {
            let base = model == "gpt-4o-mini" ? 2833 : 85, tile = model == "gpt-4o-mini" ? 5667 : 170
            if detail == "low" { return base }
            let scale = min(1, 2048 / max(w,h), 768 / min(w,h))
            return base + Int(ceil(w * scale / 512) * ceil(h * scale / 512)) * tile
        }
        warn("Image cost is a dimension-based 32-pixel-patch allowance for an unverified model policy; actual image tokens may differ.")
        // No model-identity guessing for aliases or automatic routing. Keep the
        // dimensions visible in the request and uncertainty visible in count.
        return Int(ceil(w / 32) * ceil(h / 32)) + 256
    }
    private static func dimensions(_ base64: String) -> (Int, Int)? {
        #if canImport(ImageIO)
        guard let bytes = Data(base64Encoded:base64),
              let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...100_000).contains(width), (1...100_000).contains(height) else { return nil }
        return (width,height)
        #else
        return nil
        #endif
    }
}
