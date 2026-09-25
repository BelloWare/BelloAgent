import Foundation

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
    /// CONTEXT_SAFETY_TOKENS of clampMaxTokensToContext (packages/ai).
    static let contextSafetyTokens = 4_096

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
    /// image counted as 4,800 characters. A hidden note counts as the user
    /// message of its own it is sent as.
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
        return sum([tokens(chars: chars), message.contextNote.map { tokens(chars: $0.text.utf16.count) } ?? 0])
    }
    /// Math.ceil(chars / 4).
    static func tokens(chars: Int) -> Int { chars / 4 + (chars % 4 == 0 ? 0 : 1) }
    /// clampMaxTokensToContext: the room a reply has beside the estimated input,
    /// at least one token; an unknown window clamps nothing.
    static func outputRoom(contextWindow: Int, requestTokens: Int) -> Int {
        guard contextWindow > 0 else { return Int.max }
        return max(1, contextWindow - requestTokens - contextSafetyTokens)
    }

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

/// `tokens` preserves the conversation meter's last-usage semantics.
/// `requestTokens` sizes the actual next provider projection, with a compatible
/// usage anchor when available. Both are estimates; ciphertext is not visible
/// text, and unknown images use the existing fixed allowance.
struct RequestContextCount: Sendable {
    static let method = "pi-estimate"
    static let usageSource = "Last reply's reported tokens, plus about 4 characters per token for the messages since"
    static let characterSource = "About 4 characters per token for every message; no reply has reported its tokens yet"
    static let pendingSource = "Pending until the next reply"
    let tokens: Int?
    let requestTokens: Int
    let estimate: PiContext.Estimate
    /// How `requestTokens` was reached: "last-reply-usage" or "characters".
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
    /// is, the model ceiling clipped to the room the input leaves, or nothing;
    /// never below the 16 tokens Responses accepts, as pi sends it.
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
    var replyRoom: Int { PiContext.outputRoom(contextWindow: contextWindow, requestTokens: requestTokens) }
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
        var measured = reportedUsage ? PiContext.contextUsage(messages) : nil
        var invalidBaseline = false
        // A usage total from another instruction/tool prefix or replay policy
        // does not measure this request. Older journals without a binding fall
        // back to the lightweight projection estimate.
        if let request, let index = measured?.lastUsageIndex,
           messages[index].contextUsageBinding != (try Self.usageBinding(request, profile: profile)) {
            let estimated=PiContext.messageTokens(messages)
            measured=PiContext.Estimate(tokens:estimated,usageTokens:0,trailingTokens:estimated,lastUsageIndex:nil)
            invalidBaseline=true
        }
        let unmeasured = measured == nil ? PiContext.messageTokens(messages) : 0
        let anchor = measured?.lastUsageIndex.map { messages[$0] }
        var warnings: [String] = [], requestTokens: Int, requestMethod: String
        // Reuse reported usage only for the same prefix/configuration, then
        // add the provider items that follow it. Otherwise size the complete
        // projection, including checkpoint wrappers, instructions and schemas.
        if let measured, let index = measured.lastUsageIndex {
            if let request {
                let projection = try ProviderClient.responsesProjection(messages.filter(\.replayEligible), instructions: Self.systemPrompt(request) ?? "", profile: profile)
                let end = projection.ranges[messages[index].id]?.upperBound ?? projection.items.count
                requestTokens = PiContext.sum([measured.usageTokens, Self.inputTokens(Array(projection.items.dropFirst(end)))])
            } else { requestTokens = measured.tokens }
            requestMethod = "last-reply-usage"
        }
        else {
            requestTokens = request.map(Self.projectedTokens) ?? (measured?.tokens ?? unmeasured)
            requestMethod = "characters"
        }
        if invalidBaseline || (reportedUsage && measured == nil) {
            warnings.append("No compatible usage baseline measures this request; its projected input is estimated.")
        } else if anchor == nil {
            warnings.append("Input is estimated from the complete provider projection, including instructions and tool schemas.")
        }
        if profile.api == "openai-responses", profile.wireOutputLimit == nil {
            warnings.append(profile.raw["compat"]["supportsMaxOutputTokens"].flag == false
                ? "The gateway compatibility setting omits the output limit; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap."
                : "The model catalog gave no output ceiling for this model, so no output limit is sent; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap.")
        }
        let room = PiContext.outputRoom(contextWindow: profile.contextWindow, requestTokens: requestTokens)
        let identity = anchor?.providerIdentity
        return RequestContextCount(tokens: reportedUsage ? measured?.tokens : unmeasured, requestTokens: requestTokens,
            estimate: measured ?? PiContext.Estimate(tokens: unmeasured, usageTokens: 0, trailingTokens: unmeasured, lastUsageIndex: nil),
            requestMethod: requestMethod, lastUsageID: anchor?.id, countedModel: identity?["status"].text == "reported" ? identity?["effectiveModel"].text : nil,
            requestedModel: profile.model, requestFingerprint: try request.map { try Self.fingerprint($0, profile: profile) },
            warnings: warnings, contextWindow: profile.contextWindow, outputBudget: profile.maxOutput, modelOutputLimit: profile.modelOutputLimit,
            outputCap: profile.wireOutputLimit.map { max(ProviderClient.minimumOutputTokens, profile.outputCap != nil ? $0 : min($0, room)) }, reserveTokens: reserveTokens)
    }
    /// Counts the actual model-facing projection, not capture bytes. Images
    /// use the existing allowance; opaque ciphertext is never treated as text.
    static func projectedTokens(_ request: JSON) -> Int {
        PiContext.sum([prefixTokens(request), inputTokens(request["input"].list.filter {
            !["system", "developer"].contains($0["role"].text ?? "")
        })])
    }
    static func inputTokens(_ items: [JSON]) -> Int {
        func content(_ value: JSON) -> Int {
            if let text = value.text { return PiContext.tokens(chars: text.utf16.count) }
            if !value.list.isEmpty { return PiContext.sum(value.list.map(content)) }
            guard value.isObject else { return 0 }
            if value["type"].text == "input_image" { return PiContext.tokens(chars: PiContext.estimatedImageChars) }
            return PiContext.sum(["text", "refusal", "content", "summary", "arguments", "output"].map { content(value[$0]) })
        }
        return PiContext.sum(items.map { PiContext.sum([8, content($0)]) })
    }
    static func usageBinding(_ request: JSON, profile: Profile) throws -> String {
        // Budgets and cache/correlation identifiers do not alter the rendered
        // prefix. Model, route, credentials' header scope and replay settings do.
        let value: JSON = ["profile": profile.raw.removing(["maxOutputTokens", "outputCap", "modelOutputLimit", "contextWindow"]),
            "instructions": JSON(systemPrompt(request) ?? ""), "tools": request["tools"],
            "reasoning": request["reasoning"], "include": request["include"], "text": request["text"]]
        return sha256(try value.data())
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
    /// The system prompt pi sends as the first input item.
    static func systemPrompt(_ request: JSON) -> String? {
        guard let first = request["input"].list.first, ["developer", "system"].contains(first["role"].text ?? "") else { return nil }
        return first["content"].text
    }
    /// estimateTextTokens(systemPrompt) + estimateToolsTokens(tools).
    static func prefixTokens(_ request: JSON) -> Int {
        var system = systemPrompt(request) ?? request["instructions"].text ?? request["system"].text ?? ""
        if system.isEmpty { system = request["system"].list.compactMap { $0["text"].text }.joined() }
        if system.isEmpty {
            system = request["messages"].list.filter { ["system", "developer"].contains($0["role"].text ?? "") }.compactMap { $0["content"].text }.joined()
        }
        let tools = request["tools"].list.isEmpty ? 0 : PiContext.tokens(chars: request["tools"].encoded().utf16.count)
        return PiContext.sum([PiContext.tokens(chars: system.utf16.count), tools])
    }
}
