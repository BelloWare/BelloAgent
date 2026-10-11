// Helper-side oracle: Swift 0.1.122's own UsageObservation.normalized
// (TelemetryValues.swift) and GatewayTelemetry (GatewayTelemetry.swift),
// unchanged, over the observations in usage-cases.json. Compiled into one
// module with every PiAgentCore source.
import Foundation

let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
let cases = try JSON.parse(data).list
let profile = try Profile(["id": "oracle", "api": "openai-responses", "providerId": "litellm", "modelId": "oracle-model",
                           "baseUrl": "http://127.0.0.1:1234", "contextWindow": 65536, "maxOutputTokens": 4096])
var results: [JSON] = []
for c in cases {
    let api = c["api"].text ?? "openai-responses"
    var out: JSON = ["name": c["name"]]
    out["usage"] = UsageObservation.normalized(c["raw"], api: api)
    var gateway = GatewayTelemetry(profile: profile)
    let streaming = c["streaming"].flag ?? true
    var headers: [String: String] = [:]
    for (key, value) in c["headers"].map { headers[key] = value.text }
    gateway.head(headers.merging(["content-type": streaming ? "text/event-stream" : "application/json"]) { a, _ in a }, excluding: { _ in false })
    for event in c["events"].list { gateway.body(event, streaming: streaming, excluding: { _ in false }) }
    out["gateway"] = gateway.json
    results.append(out)
}
print(JSON.array(results).encoded())
