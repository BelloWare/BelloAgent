import Foundation

struct RequestContextObservation {
    let value: [String: WireValue]
    init(_ value: [String: WireValue]) { self.value=value }
    var context: [String: WireValue]? {
        guard let fingerprint=value["requestFingerprint"]?.string,
              let capacity=value["contextWindow"]?.number, capacity.isFinite, capacity>0 else { return nil }
        let phase=value["phase"]?.string ?? "awaiting"
        let usage=value["usage"]?.object ?? [:], status=value["status"]?.object ?? [:]
        let input=usage["input"]?.number
        let reported=status["input"]?.string == "reported" && input.map { $0.isFinite && $0>=0 && $0.rounded()==$0 } == true
        var result=value["estimate"]?.object ?? [:]
        result["contextWindow"] = .number(capacity)
        if reported {
            result["tokens"] = .number(input!); result["estimated"] = .bool(false)
            result["method"] = .string("gateway-reported"); result["requestFingerprint"] = .string(fingerprint)
            result["requestedModel"] = value["requestedModel"]; result["countedModel"] = value["effectiveModel"]
            let inputPhase=value["fieldPhase"]?.object?["input"]?.string
            result["source"] = .string("LiteLLM reported request input" + (phase == "final" && inputPhase != "interim" ? " · last request" : phase == "interrupted" ? " · incomplete request" : " · interim"))
            result["warnings"] = .array(input!>capacity ? [.string("Reported input exceeds configured capacity; routing capacity may differ.")] : [])
        } else {
            result["source"] = .string(phase == "interrupted" ? "Request estimate; usage incomplete" : "Request estimate; awaiting LiteLLM usage")
            result["awaitingUsage"] = .bool(phase != "interrupted")
        }
        result["preparation"] = .string("Request " + (value["generation"]?.number.map { String(format: "%.0f", $0) } ?? "") + " · " + (value["attemptID"]?.string ?? ""))
        return result
    }
    var details: String {
        let usage=value["usage"]?.object ?? [:], status=value["status"]?.object ?? [:], phases=value["fieldPhase"]?.object ?? [:]
        var rows=["Request \(value["attemptID"]?.string ?? "—") · \(value["phase"]?.string ?? "awaiting")",
                  "Requested \(value["requestedModel"]?.string ?? "—") · returned \(value["effectiveModel"]?.string ?? "unreported")"]
        for (key, name) in [("input","Input"),("output","Output"),("cacheRead","Cached input (included in input)"),("cacheWrite","Cache write (included in input)"),("reasoning","Reasoning (included in output)"),("total","Request total")] {
            let count=usage[key]?.number?.formatted(.number.precision(.fractionLength(0))) ?? "—"
            rows.append("\(name): \(count) · \(status[key]?.string ?? "unreported") · \(phases[key]?.string ?? "awaiting")")
        }
        rows.append("Generation usage does not measure the next replayed request.")
        return rows.joined(separator: "\n")
    }
}
