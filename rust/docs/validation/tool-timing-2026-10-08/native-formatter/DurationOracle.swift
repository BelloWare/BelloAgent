import Foundation

enum FixtureOutcome { case running, completed }
struct ToolView {
    let durationMs: Double?
    let fixtureOutcome: FixtureOutcome
}

enum DurationObservation {
    static func valid(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(Int.max) else { return nil }
        return milliseconds
    }
}

enum TranscriptActivity {
    static func formatDuration(_ ms: Double) -> String {
        guard DurationObservation.valid(ms) != nil else { return "" }
        // A tenth that rounds up to the second is written as the second:
        // 990 ms is "1s", never "1.0s".
        if (ms / 100).rounded() < 10 { return String(format: "%.1fs", ms / 1000) }
        // Retained history can contain finite values outside Int's range.
        guard let seconds = Int(exactly: (ms / 1000).rounded()) else { return "" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
    }
    static func outcome(of tool: ToolView) -> FixtureOutcome { tool.fixtureOutcome }
}
enum RowOracle {
    nonisolated static func elapsed(of tool: ToolView) -> String? {
        guard TranscriptActivity.outcome(of: tool) != .running, let ms = tool.durationMs, ms >= 50 else { return nil }
        return TranscriptActivity.formatDuration(ms)
    }
}

func hex(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }
func valueFor(_ input: [String: Any]) -> Double? {
    switch input["kind"] as! String {
    case "decimal": return Double(input["value"] as! String)!
    case "negativeZero": return -Double.zero
    case "nan": return Double.nan
    case "positiveInfinity": return Double.infinity
    case "negativeInfinity": return -Double.infinity
    case "doubleIntMax": return Double(Int.max)
    case "doubleIntMaxNextDown": return Double(Int.max).nextDown
    case "doubleIntMaxNextUp": return Double(Int.max).nextUp
    case "greatestFinite": return Double.greatestFiniteMagnitude
    case "missing": return nil
    default: fatalError("unknown fixture kind")
    }
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let fixtures = input["fixtures"] as! [[String: Any]]
var results = [[String: Any]]()
for fixture in fixtures {
    let ms = valueFor(fixture)
    let formatted = ms.map { TranscriptActivity.formatDuration($0) }
    let terminal = RowOracle.elapsed(of: ToolView(durationMs: ms, fixtureOutcome: .completed))
    let running = RowOracle.elapsed(of: ToolView(durationMs: ms, fixtureOutcome: .running))
    var result: [String: Any] = [
        "id": fixture["id"]!, "kind": fixture["kind"]!,
        "input_decimal_ms": fixture["value"] ?? NSNull(),
        "native_double_description": ms.map { String(describing: $0) } ?? NSNull(),
        "native_double_17g": ms.map { String(format: "%.17g", $0) } ?? NSNull(),
        "native_double_binary64_hex": ms.map { hex($0) } ?? NSNull(),
        "display_validator_accepts": DurationObservation.valid(ms) != nil,
        "formatted": formatted ?? NSNull(),
        "terminal_row": terminal ?? NSNull(), "running_row": running ?? NSNull(),
        "checked_microseconds": fixture["checked_microseconds"] ?? NSNull(),
        "integer_half_up_reference": fixture["integer_half_up_reference"] ?? NSNull()
    ]
    if let text = fixture["checked_microseconds"] as? String, let microseconds = UInt64(text), let ms {
        let reconstructed = Double(microseconds) / 1000
        let reconstructedFormat = TranscriptActivity.formatDuration(reconstructed)
        result["microseconds_to_double_integer_is_exact"] = Double(exactly: microseconds) != nil
        result["reconstructed_ms_binary64_hex"] = hex(reconstructed)
        result["reconstructed_ms_equals_input_bitwise"] = reconstructed.bitPattern == ms.bitPattern
        result["reconstructed_formatted"] = reconstructedFormat
        result["reconstructed_format_matches"] = reconstructedFormat == formatted
        result["native_equals_integer_half_up_reference"] = formatted == (fixture["integer_half_up_reference"] as? String)
    }
    results.append(result)
}
let localeEnvironment = ["LANG", "LC_ALL", "LC_NUMERIC"].reduce(into: [String: Any]()) {
    $0[$1] = ProcessInfo.processInfo.environment[$1] ?? NSNull()
}
let output: [String: Any] = [
    "schema_version": 1, "int_max_decimal": String(Int.max), "uint64_max_decimal": String(UInt64.max),
    "double_int_max_description": String(describing: Double(Int.max)), "double_int_max_binary64_hex": hex(Double(Int.max)),
    "locale_identifier": Locale.current.identifier, "locale_environment": localeEnvironment,
    "elapsed_fixture_scope": "Exact production elapsed body with controlled ToolView/outcome shims: verifies threshold/running guard, not full outcome classification or UI rendering.",
    "results": results
]
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data([10]))
