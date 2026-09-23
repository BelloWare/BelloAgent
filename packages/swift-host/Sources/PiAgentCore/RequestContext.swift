import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Pi 0.85.1's context estimate (coding-agent/src/core/compaction/compaction.ts
/// and agent-session.ts), ported onto the helper's messages: the last valid
/// reply's reported tokens, plus about four characters per token for every
/// message after it. A JavaScript string's length is its UTF-16 code units.
enum PiContext {
    /// The compaction defaults of settings-manager.ts.
    struct Settings: Sendable, Equatable {
        var enabled = true
        var reserveTokens = 16_384
        var keepRecentTokens = 20_000
    }
    /// ESTIMATED_IMAGE_CHARS.
    static let estimatedImageChars = 4_800

    struct Estimate: Sendable, Equatable {
        let tokens: Int
        let usageTokens: Int
        let trailingTokens: Int
        let lastUsageIndex: Int?
    }

    /// pi-ai's usage for one reply, read from the provider's own usage object
    /// as pi reads it, so the count equals pi's for the same response. The
    /// Responses API's input_tokens includes cached and cache-write tokens;
    /// pi's input does not. Without the provider object, the helper's
    /// normalized fields map the same way (their inputIncludingCache holds
    /// both caches on either API).
    static func usage(_ reported: JSON, api: String) -> JSON? {
        func count(_ value: JSON) -> Int { UsageObservation.count(value) ?? 0 }
        func excluding(_ whole: Int, _ parts: Int...) -> Int { parts.reduce(whole) { $0 - min($0, $1) } }
        let raw = reported["raw"]
        if raw.isObject {
            if api == "anthropic-messages" {
                let input = count(raw["input_tokens"]), output = count(raw["output_tokens"])
                let read = count(raw["cache_read_input_tokens"]), write = count(raw["cache_creation_input_tokens"])
                return shape(input: input, output: output, cacheRead: read, cacheWrite: write, total: sum([input, output, read, write]))
            }
            let details = raw["input_tokens_details"]
            let read = count(details["cached_tokens"]), write = count(details["cache_write_tokens"])
            return shape(input: excluding(count(raw["input_tokens"]), read, write), output: count(raw["output_tokens"]),
                         cacheRead: read, cacheWrite: write, total: count(raw["total_tokens"]))
        }
        guard ["input", "inputIncludingCache", "output", "total"].contains(where: { !reported[$0].isNull }) else { return nil }
        let read = count(reported["cacheRead"]), write = count(reported["cacheWrite"])
        let input = UsageObservation.count(reported["inputIncludingCache"]) ?? count(reported["input"])
        return shape(input: excluding(input, read, write), output: count(reported["output"]), cacheRead: read, cacheWrite: write, total: count(reported["total"]))
    }
    private static func shape(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) -> JSON {
        ["input": JSON(input), "output": JSON(output), "cacheRead": JSON(cacheRead), "cacheWrite": JSON(cacheWrite), "totalTokens": JSON(total)]
    }

    /// calculateContextTokens: the reported total, else the sum of its parts.
    /// Parts whose sum no integer holds are malformed usage, which counts as
    /// zero and so, like pi's all-zero usage, anchors nothing.
    static func contextTokens(_ usage: JSON) -> Int {
        let total = UsageObservation.count(usage["totalTokens"]) ?? 0
        if total > 0 { return total }
        var parts = 0
        for key in ["input", "output", "cacheRead", "cacheWrite"] {
            let (result, overflow) = parts.addingReportingOverflow(UsageObservation.count(usage[key]) ?? 0)
            if overflow { return 0 }
            parts = result
        }
        return parts
    }

    /// getAssistantUsage: a replayed reply's usage, unless the reply was
    /// aborted (the helper's "interrupted") or failed, or its usage is all zero.
    static func assistantUsage(_ message: ChatMessage) -> JSON? {
        guard message.role == "assistant", message.replayEligible, let usage = message.usage,
              !["aborted", "error", "interrupted"].contains(message.stopReason ?? ""), contextTokens(usage) > 0 else { return nil }
        return usage
    }

    /// estimateTokens: characters over four, rounded up. A reply counts its
    /// text, thinking, and each call's name and JSON arguments; every other
    /// row (user, tool result, a summary or custom row) its text, with each
    /// image counted as 4,800 characters.
    static func estimateTokens(_ message: ChatMessage) -> Int {
        var chars = 0
        for block in message.content {
            switch (block["type"].text ?? "", message.role == "assistant") {
            case ("text", _): chars = sum([chars, length(block["text"])])
            case ("thinking", true): chars = sum([chars, length(block["thinking"])])
            case ("toolCall", true): chars = sum([chars, length(block["name"]), block["arguments"].encoded().utf16.count])
            case ("image", false): chars = sum([chars, estimatedImageChars])
            default: break
            }
        }
        return tokens(chars: chars)
    }
    /// Math.ceil(chars / 4).
    static func tokens(chars: Int) -> Int { chars / 4 + (chars % 4 == 0 ? 0 : 1) }

    /// estimateContextTokens over the rows the next request replays.
    static func estimateContextTokens(_ messages: [ChatMessage]) -> Estimate {
        guard let index = messages.lastIndex(where: { assistantUsage($0) != nil }) else {
            let estimated = messageTokens(messages)
            return Estimate(tokens: estimated, usageTokens: 0, trailingTokens: estimated, lastUsageIndex: nil)
        }
        let usageTokens = contextTokens(messages[index].usage ?? [:]), trailing = messageTokens(messages[(index + 1)...])
        return Estimate(tokens: sum([usageTokens, trailing]), usageTokens: usageTokens, trailingTokens: trailing, lastUsageIndex: index)
    }
    /// The estimate of the replayed rows alone, with no reply's usage.
    static func messageTokens<Rows: Sequence>(_ messages: Rows) -> Int where Rows.Element == ChatMessage {
        sum(messages.filter(\.replayEligible).map(estimateTokens))
    }

    /// The latest compaction among `messages`. A row after its summary that it
    /// did not keep was appended after the compaction, so only such a reply's
    /// usage measures the compacted context (getLatestCompactionEntry).
    struct Compaction { let index: Int; let kept: Set<String> }
    static func latestCompaction(_ messages: [ChatMessage]) -> Compaction? {
        guard let index = messages.lastIndex(where: { $0.kind == "compaction" }) else { return nil }
        return Compaction(index: index, kept: Set(messages[index].compaction?["keptIDs"].list.compactMap(\.text) ?? []))
    }
    static func isAfter(_ compaction: Compaction?, _ position: Int, in messages: [ChatMessage]) -> Bool {
        guard let compaction else { return true }
        return position > compaction.index && !compaction.kept.contains(messages[position].id)
    }

    /// getContextUsage: pi's figure, or nil after a compaction until a reply
    /// that came after it reports usage.
    static func contextUsage(_ messages: [ChatMessage]) -> Estimate? {
        if let compaction = latestCompaction(messages),
           !messages.indices.reversed().contains(where: { isAfter(compaction, $0, in: messages) && assistantUsage(messages[$0]) != nil }) { return nil }
        return estimateContextTokens(messages)
    }

    /// Case 3 of _checkCompaction: the figure pi compares with the threshold
    /// after the reply at `position`, or nil when pi returns without compacting
    /// because that reply, or the usage its estimate rests on, predates the
    /// latest compaction. A reply with valid usage is measured by it directly.
    static func thresholdTokens(after position: Int, in messages: [ChatMessage]) -> Int? {
        let compaction = latestCompaction(messages)
        guard isAfter(compaction, position, in: messages) else { return nil }
        let reply = messages[position], direct = reply.usage.map(contextTokens) ?? 0
        guard reply.stopReason == "error" || direct == 0 else { return direct }
        let estimate = estimateContextTokens(messages)
        if let index = estimate.lastUsageIndex, !isAfter(compaction, index, in: messages) { return nil }
        return estimate.tokens
    }
    /// Before a new prompt joins the context, pi runs the same check on the
    /// last reply, aborted or not; with no reply there is nothing to check.
    static func promptThresholdTokens(_ messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { $0.role == "assistant" }).flatMap { thresholdTokens(after: $0, in: messages) }
    }
    /// shouldCompact.
    static func shouldCompact(_ tokens: Int, contextWindow: Int, settings: Settings) -> Bool {
        settings.enabled && tokens > contextWindow - settings.reserveTokens
    }

    private static func length(_ value: JSON) -> Int { value.text?.utf16.count ?? 0 }
    /// Sums saturate: a count past Int.max stays over every budget.
    static func sum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (result, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : result
        }
    }
}

/// The count for the next request. `tokens` is pi's context figure: the meter
/// shows it and the compaction threshold reads it, and it is unknown (nil)
/// after a compaction until a reply reports usage. `requestTokens` sizes the
/// request itself (its output cap, whether it can be sent at all, how much a
/// summary request can carry): the prepared request's own UTF-8 bytes over
/// three, instructions and tool schemas included, as before. Pi sizes no
/// request, so that conservative bound stays the helper's, and a reply's
/// report, however wrong, never stops a request the gateway could take.
/// Without a request body (the idle reading) it is pi's figure, or the
/// messages' characters over four after a compaction.
struct RequestContextCount: Sendable {
    static let method = "pi-estimate"
    static let usageSource = "Last reply's reported tokens, plus about 4 characters per token for the messages since"
    static let characterSource = "About 4 characters per token for every message; no reply has reported its tokens yet"
    static let pendingSource = "Pending until the next reply"
    let tokens: Int?
    let requestTokens: Int
    let estimate: PiContext.Estimate
    /// How `requestTokens` was reached: "request-utf8-bytes", "last-reply-usage" or "characters".
    let requestMethod: String
    let lastUsageID: String?
    let countedModel: String?
    let requestedModel: String
    let requestFingerprint: String?
    let warnings: [String]
    let contextWindow: Int
    /// The output budget: a local reserve, never a cap on the wire.
    let outputBudget: Int
    let modelOutputLimit: Int?
    /// The output limit the request carries: a bounded task's explicit cap as
    /// is, the model ceiling clipped to the room the input leaves, or nothing.
    let outputCap: Int?
    let reserveTokens: Int
    var method: String { Self.method }
    var source: String { tokens == nil ? Self.pendingSource : lastUsageID == nil ? Self.characterSource : Self.usageSource }
    static func safetyMargin(contextWindow: Int) -> Int { min(1024, max(1, contextWindow / 100)) }
    var safetyMargin: Int { Self.safetyMargin(contextWindow: contextWindow) }
    var inputBudget: Int { max(0, contextWindow - outputBudget - safetyMargin) }
    /// The reserve says the reply may not fit beside this input.
    var fits: Bool { requestTokens <= inputBudget }
    /// The input itself fits the window; only when it does not is a turn stopped.
    var inputFits: Bool { requestTokens <= contextWindow - safetyMargin }
    /// Room for the reply once the input and the safety margin are in the window.
    var replyRoom: Int { requestTokens >= contextWindow - safetyMargin ? 1 : max(1, contextWindow - safetyMargin - requestTokens) }
    var json: JSON {
        var value: JSON = ["tokens": tokens.map { JSON($0) } ?? .null, "method": JSON(method), "requestedModel": JSON(requestedModel),
            "countedModel": countedModel.map { JSON($0) } ?? .null, "requestFingerprint": requestFingerprint.map { JSON($0) } ?? .null,
            "estimated": true, "source": JSON(source), "warnings": .array(warnings.map { JSON($0) }),
            "contextWindow": JSON(contextWindow), "outputBudget": JSON(outputBudget), "outputReserve": JSON(outputBudget),
            "modelOutputLimit": modelOutputLimit.map { JSON($0) } ?? .null, "outputCap": outputCap.map { JSON($0) } ?? .null,
            "safetyMargin": JSON(safetyMargin), "inputBudget": JSON(inputBudget), "fits": JSON(fits), "inputFits": JSON(inputFits),
            "percent": tokens.map { JSON(Double($0) / Double(contextWindow) * 100) } ?? .null,
            "requestTokens": JSON(requestTokens), "requestMethod": JSON(requestMethod), "reserveTokens": JSON(reserveTokens), "compactionThreshold": JSON(contextWindow - reserveTokens),
            "lastUsageMessageID": lastUsageID.map { JSON($0) } ?? .null,
            "countEndpointStatus": "unverified-request-compatibility"]
        if tokens == nil { value["state"] = "post-compaction" }
        else { value["usageTokens"] = JSON(estimate.usageTokens); value["trailingTokens"] = JSON(estimate.trailingTokens) }
        return value
    }
}

extension Profile {
    /// The profile a conversation request is sent with: the model ceiling
    /// clipped to the room the estimate leaves, so a long chat never asks for
    /// more output than its window can hold. Explicit task caps are kept.
    func dispatching(_ count: RequestContextCount) throws -> Profile {
        guard let cap = count.outputCap, cap != wireOutputLimit else { return self }
        return try capped(cap)
    }
}

struct RequestContextCounter: Sendable {
    /// `messages` is the context as the helper stores it; rows the request does
    /// not replay count nothing. `request` is the body built from them. A
    /// hypothetical context (a compaction candidate or a summary request) passes
    /// `reportedUsage: false`, so no reply's usage, which measured a different
    /// context, anchors it.
    func count(messages: [ChatMessage], profile: Profile, request: JSON? = nil, reportedUsage: Bool = true,
               reserveTokens: Int = PiContext.Settings().reserveTokens) throws -> RequestContextCount {
        let measured = reportedUsage ? PiContext.contextUsage(messages) : nil
        let unmeasured = measured == nil ? PiContext.messageTokens(messages) : 0
        let anchor = measured?.lastUsageIndex.map { messages[$0] }
        var warnings: [String] = [], requestTokens: Int, requestMethod: String
        if let request {
            var heuristic = InputHeuristic(model: profile.raw["routing"]["replayPolicy"].text == "pinned" ? profile.raw["routing"]["expectedModel"].text.map(Self.modelName) : nil)
            requestTokens = heuristic.count(Self.modelInput(request)); warnings += heuristic.warnings; requestMethod = "request-utf8-bytes"
        } else if let measured, measured.lastUsageIndex != nil { requestTokens = measured.tokens; requestMethod = "last-reply-usage" }
        else { requestTokens = measured?.tokens ?? unmeasured; requestMethod = "characters" }
        if reportedUsage && measured == nil {
            warnings.append("The last reported tokens predate the compaction, so the context is unknown until the next reply reports usage.")
        } else if anchor == nil {
            warnings.append("Instructions and tool schemas are not in this figure until a reply reports its tokens.")
        }
        if profile.api == "openai-responses", profile.wireOutputLimit == nil {
            warnings.append(profile.raw["compat"]["supportsMaxOutputTokens"].flag == false
                ? "The gateway compatibility setting omits the output limit; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap."
                : "The model catalog gave no output ceiling for this model, so no output limit is sent; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap.")
        }
        let available = profile.contextWindow - RequestContextCount.safetyMargin(contextWindow: profile.contextWindow)
        let room = requestTokens >= available ? 1 : max(1, available - requestTokens)
        let identity = anchor?.providerIdentity
        return RequestContextCount(tokens: reportedUsage ? measured?.tokens : unmeasured, requestTokens: requestTokens,
            estimate: measured ?? PiContext.Estimate(tokens: unmeasured, usageTokens: 0, trailingTokens: unmeasured, lastUsageIndex: nil),
            requestMethod: requestMethod, lastUsageID: anchor?.id, countedModel: identity?["status"].text == "reported" ? identity?["effectiveModel"].text : nil,
            requestedModel: profile.model, requestFingerprint: try request.map { try Self.fingerprint($0, profile: profile) },
            warnings: warnings, contextWindow: profile.contextWindow, outputBudget: profile.maxOutput, modelOutputLimit: profile.modelOutputLimit,
            outputCap: profile.wireOutputLimit.map { profile.outputCap != nil ? $0 : min($0, room) }, reserveTokens: reserveTokens)
    }
    private static func configuration(_ profile: Profile) -> JSON {
        // Header/credential-dependent routing is part of the hash, never of the
        // displayed metadata. Profile revision also invalidates all old counts.
        ["profile":profile.raw, "endpoint":JSON(profile.endpoint.absoluteString), "version":1]
    }
    static func fingerprint(_ request: JSON, profile: Profile) throws -> String {
        sha256(try JSON.object(["request":request,"configuration":configuration(profile)]).data())
    }
    static func modelName(_ name: String) -> String { name.hasPrefix("openai/") ? String(name.dropFirst(7)) : name }
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
