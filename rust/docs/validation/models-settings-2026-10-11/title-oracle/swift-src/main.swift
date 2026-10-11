import Foundation

// Reads cases.json (argv[1]) and prints what Swift's TitleGenerationPlan
// makes of each: plans, single titles and suggestion lists.
struct Cases: Decodable {
    struct Plan: Decodable {
        var contextWindow: Int; var maxOutputTokens: Int; var miniModelId: String?
        var descriptors: [ModelDescriptor]; var input: String; var variants: Int
    }
    var plans: [Plan]; var replies: [String]
}
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONDecoder().decode(Cases.self, from: data)
var plans: [Any] = []
for item in cases.plans {
    let profile = ProfileRecord(modelId: "conversation-model", contextWindow: item.contextWindow, maxOutputTokens: item.maxOutputTokens, miniModelId: item.miniModelId)
    if let plan = TitleGenerationPlan(profile: profile, descriptors: item.descriptors, input: item.input, variants: item.variants) {
        plans.append(["model": plan.model, "contextWindow": plan.contextWindow, "maxOutputTokens": plan.maxOutputTokens,
                      "modelOutputLimit": plan.modelOutputLimit as Any? ?? NSNull(), "thinkingLevel": plan.thinkingLevel, "prompt": plan.prompt])
    } else { plans.append(NSNull()) }
}
let titles: [Any] = cases.replies.map { TitleGenerationPlan.title(from: [TranscriptMessage(role: "assistant", text: $0)]).map { $0 as Any } ?? NSNull() }
let suggestions = cases.replies.map { TitleGenerationPlan.titles(from: [TranscriptMessage(role: "assistant", text: $0)], limit: 3) }
let output = try! JSONSerialization.data(withJSONObject: ["plans": plans, "titles": titles, "suggestions": suggestions], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(decoding: output, as: UTF8.self))
