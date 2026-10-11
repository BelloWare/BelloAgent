// Threshold oracle: Swift 0.1.122's own CompactionPolicy, CompactionPlanner,
// CompactionSourceBuilder, ProviderClient and RequestContextCounter, unchanged.
// The glue below repeats AgentSession.compactionPlan/compactionKeep/
// compactionThreshold (SessionCompaction.swift) line for line for a session
// with no task root.
import Foundation

func toJSON(_ value: Any) -> JSON {
    switch value {
    case let v as String: return JSON(v)
    case let v as NSNumber:
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return JSON(v.boolValue) }
        return JSON(v.intValue)
    case let v as [Any]: return .array(v.map(toJSON))
    case let v as [String: Any]: return .object(v.mapValues(toJSON))
    default: return .null
    }
}
func threshold(_ messages: [ChatMessage], instructions: String, profile: Profile) throws -> Int {
    let compactionPolicy = CompactionPolicy()
    let source = try CompactionPlanner.source(context:messages,taskRoot:nil)
    let keep = compactionPolicy.keepRecentTokens(contextWindow:profile.contextWindow)
    let cut = CompactionPlanner.cut(source.body,keepRecentTokens:keep,previous:CompactionPlanner.previousPosition(source))
    let planned = (source:source,cut:cut,plan:CompactionPlanner.plan(source,cut:cut),keep:keep)
    let projection = try ProviderClient.responsesProjection(messages.filter(\.replayEligible),instructions:instructions,profile:profile)
    let boundary = try CompactionSourceBuilder.boundary(projection,messages:messages,keptIDs:Set(planned.plan.keptMessages.map(\.id)))
    let instruction = CompactionSourceBuilder.instruction(boundary:boundary,focus:nil,visibleTarget:compactionPolicy.visibleTarget(for:profile))
    let items = ProviderClient.userContent(instruction,images:false)
    return try compactionPolicy.trigger(profile:profile,instructionTokens:RequestContextCounter.inputTokens([["role":"user","content":.array(items)]]))
}
/// The compact case spec: `chat` rounds of a question and an answer twice its
/// size (the last left unanswered when `answered` is false), or one `huge` user row.
func expand(_ spec: [String: Any]) -> [(id: String, role: String, text: String)] {
    if let huge = spec["huge"] as? Int { return [("u0", "user", String(repeating: "x", count: huge))] }
    let n = spec["chat"] as! Int, size = spec["size"] as! Int
    let unicode = spec["unicode"] as? Bool ?? false, answered = spec["answered"] as? Bool ?? true
    let t = String(repeating: unicode ? "Objective and progress évidence 😀 " : "Objective and progress evidence ", count: size)
    var rows: [(id: String, role: String, text: String)] = []
    for i in 0..<n {
        rows.append(("u\(i)", "user", "Question \(i): " + t))
        if answered || i < n - 1 { rows.append(("a\(i)", "assistant", "Answer \(i): " + t + t)) }
    }
    return rows
}
let input = try JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: CommandLine.arguments[1])!) as! [[String: Any]]
var results: [JSON] = []
for c in input {
    let profile = try Profile(toJSON(c["profile"]!))
    let instructions = c["instructions"] as! String
    var messages: [ChatMessage] = expand(c["rows"] as! [String: Any]).map { row in
        var m = ChatMessage(role: row.role, content: [textBlock(row.text)]); m.id = row.id; return m
    }
    var out: JSON = ["name": JSON(c["name"] as! String)]
    do { out["threshold"] = JSON(try threshold(messages, instructions: instructions, profile: profile)) }
    catch let e as AgentError { out["thresholdError"] = JSON(e.code) }
    let body = try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:[],sessionID:"oracle-session")
    // Usage baseline (added 2026-10-11): replies keep their usage in pi's
    // shape and the binding of the request that produced them, as
    // SessionRun does; the count is RequestContextCounter's own.
    for usage in (c["rows"] as! [String: Any])["usage"] as? [[String: Any]] ?? [] {
        let index = messages.firstIndex { $0.id == usage["id"] as! String }!
        messages[index].usage = PiContext.usage(UsageObservation.normalized(toJSON(usage["raw"]!), api: profile.api), api: profile.api)
        switch usage["binding"] as? String {
        case "match": messages[index].contextUsageBinding = try RequestContextCounter.usageBinding(body, profile: profile)
        case "stale": messages[index].contextUsageBinding = "stale"
        default: break
        }
        if usage["interrupted"] as? Bool == true { messages[index].stopReason = "interrupted" }
    }
    let count = try RequestContextCounter().count(messages: messages, profile: profile, request: body)
    out["baselineRequestTokens"] = JSON(count.requestTokens)
    out["baselineMethod"] = JSON(count.requestMethod)
    out["contextTokens"] = count.tokens.map { JSON($0) } ?? .null
    // The meter's own reading, counted without a request (`contextInfo`).
    out["meterTokens"] = (try RequestContextCounter().count(messages: messages, profile: profile)).tokens.map { JSON($0) } ?? .null
    out["requestTokens"] = JSON(RequestContextCounter.projectedTokens(body))
    out["safetyMargin"] = JSON(RequestContextCount.safetyMargin(contextWindow: profile.contextWindow))
    out["summaryTokens"] = JSON(CompactionPolicy().summaryTokens(for: profile))
    results.append(out)
}
print(JSON.array(results).encoded())
