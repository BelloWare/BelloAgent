import Foundation

/// Validate observations independently of the retained raw journal/HTTP data.
/// Unknown or invalid cumulative values stay unknown after subsequent work.
enum ObservedDuration {
    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return value
    }
    static func adding(_ previous: Double?, _ delta: Double) -> Double? {
        guard let previous = valid(previous), let delta = valid(delta) else { return nil }
        return valid(previous + delta)
    }
}

enum UsageObservation {
    static func count(_ value: JSON) -> Int? {
        guard let value = value.int, value >= 0 else { return nil }; return value
    }
    static func normalized(_ raw: JSON, api: String) -> JSON {
        var fields: [String: JSON] = ["input": raw["input_tokens"], "output": raw["output_tokens"],
            "cacheRead": api == "openai-responses" ? raw["input_tokens_details"]["cached_tokens"] : raw["cache_read_input_tokens"],
            "cacheWrite": api == "openai-responses" ? raw["input_tokens_details"]["cache_write_tokens"] : raw["cache_creation_input_tokens"],
            "reasoning": raw["output_tokens_details"]["reasoning_tokens"], "total": raw["total_tokens"]]
        var status: JSON = [:]
        for (key, value) in fields {
            status[key] = value.isNull ? "unreported" : count(value) == nil ? "invalid" : "reported"
            if count(value) == nil { fields[key] = .null }
        }
        for (detail, parent) in [("cacheRead", "input"), ("cacheWrite", "input"), ("reasoning", "output")] {
            if (api == "openai-responses" || detail == "reasoning"), let part = count(fields[detail] ?? .null), let whole = count(fields[parent] ?? .null), part > whole {
                fields[detail] = .null; status[detail] = "invalid"
            }
        }
        if api == "openai-responses", let input=count(fields["input"] ?? .null),
           let read=count(fields["cacheRead"] ?? .null), let write=count(fields["cacheWrite"] ?? .null) {
            let (sum, overflow)=read.addingReportingOverflow(write)
            if overflow || sum>input {
                for key in ["cacheRead","cacheWrite"] { fields[key] = .null; status[key]="invalid" }
            }
        }
        if api == "openai-responses", let input=count(fields["input"] ?? .null), let output=count(fields["output"] ?? .null) {
            let (sum, overflow)=input.addingReportingOverflow(output)
            if overflow || (count(fields["total"] ?? .null).map { $0 != sum } ?? false) { fields["total"] = .null; status["total"]="invalid" }
        }
        fields["inputIncludingCache"] = fields["input"]
        status["inputIncludingCache"] = status["input"]
        if api == "anthropic-messages", var total = count(fields["input"] ?? .null) {
            for detail in ["cacheRead", "cacheWrite"] {
                if status[detail].text == "invalid" { fields["inputIncludingCache"] = .null; status["inputIncludingCache"] = "invalid"; break }
                let (sum, overflow) = total.addingReportingOverflow(count(fields[detail] ?? .null) ?? 0)
                if overflow { fields["inputIncludingCache"] = .null; status["inputIncludingCache"] = "overflow"; break }
                total = sum; fields["inputIncludingCache"] = JSON(sum)
            }
        }
        fields["status"] = status; fields["raw"] = raw
        return .object(fields)
    }
}

/// A missing/invalid sample poisons only its component, never the answer or
/// tool workflow. Checked addition also protects valid but enormous samples.
struct CumulativeUsage: Sendable {
    private(set) var input: Int? = 0, output: Int? = 0
    private(set) var inputStatus = "reported", outputStatus = "reported"
    mutating func observe(_ usage: JSON) {
        let inputKey = usage.map["inputIncludingCache"] == nil ? "input" : "inputIncludingCache"
        Self.add(usage[inputKey], status: usage["status"][inputKey].text, to: &input, state: &inputStatus)
        Self.add(usage["output"], status: usage["status"]["output"].text, to: &output, state: &outputStatus)
    }
    private static func add(_ sample: JSON, status: String?, to total: inout Int?, state: inout String) {
        guard let previous = total else { return }
        guard let count = UsageObservation.count(sample) else {
            total = nil; state = status ?? (sample.isNull ? "unreported" : "invalid"); return
        }
        let (sum, overflow) = previous.addingReportingOverflow(count)
        let unrepresentable = overflow || Double(sum) >= Double(Int.max)
        total = unrepresentable ? nil : sum
        if unrepresentable { state = "overflow" }
    }
    var json: JSON { ["input": input.map { JSON($0) } ?? .null, "output": output.map { JSON($0) } ?? .null,
                      "inputStatus": JSON(inputStatus), "outputStatus": JSON(outputStatus)] }
}
