import Foundation

/// A reference to the retained journal, not an export of the visible transcript.
/// Building it requires no journal reads, history loading or helper startup.
struct SessionReference {
    let chat: ChatRecord
    var usage: GatewayTotals = GatewayTotals()

    var text: String {
        var lines = [
            "Bello Agent session",
            "App session ID: \(chat.id)",
            "Title: \(chat.title)",
            "Project ID: \(chat.workspaceID)"
        ]
        if let parent = chat.parentSessionID { lines.append("Parent session ID: \(parent)") }
        lines += usageLines + [""]
        if let path = chat.path, !path.isEmpty {
            lines += [
                "Conversation file (JSONL): \(path)",
                "",
                "Read with Bash:",
                "cat -- \(Self.shellQuote(path))",
                "",
                "Retained JSONL history includes messages, tool results, prior branches and compaction metadata, not just the current model context. Live streaming output appears after it is saved; unsaved drafts are not included. Read the file without modifying it."
            ]
            if chat.imported {
                lines.append("Imported original: the app session ID above may differ from the session ID in the file header.")
            }
        } else {
            lines.append("Conversation file: not created yet. This session has no saved journal to inspect.")
        }
        return lines.joined(separator: "\n")
    }

    /// Same inclusive accounting as the report: cache is part of input and
    /// reasoning is part of output. Missing observations must not become zero.
    private var usageLines: [String] {
        let tokens = usage.tokens ?? GatewayTokenTotals()
        func count(_ value: Double?, _ samples: Int) -> String {
            guard samples > 0, let value, value.isFinite, value >= 0 else { return "not reported" }
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) + coverage(samples)
        }
        func cost(_ value: Double?, _ samples: Int) -> String {
            guard samples > 0, let value, value.isFinite, value >= 0 else { return "not reported" }
            return gatewayUSD(value) + coverage(samples)
        }
        func coverage(_ samples: Int) -> String { " (\(samples)/\(usage.requests) requests reported)" }
        var lines = [
            "Gateway-reported usage (retained requests): \(usage.requests) requests",
            "Total tokens (input + output): \(count(tokens.total, tokens.samples))",
            "Input tokens (includes cache): \(count(tokens.input, tokens.inputSamples))",
            "Output tokens (includes reasoning): \(count(tokens.output, tokens.outputSamples))",
            "Cached input tokens: \(count(usage.cacheReadTokens, usage.cacheReadSamples))",
            "Cache-write input tokens: \(count(usage.cacheWriteTokens, usage.cacheWriteSamples))",
            "Reasoning tokens (part of output): \(count(tokens.reasoning, tokens.reasoningSamples ?? 0))",
            "Reported cost: \(cost(usage.costUSD, usage.costSamples))",
            "Reasoning cost (part of reported cost): \(cost(usage.reasoningCostUSD, usage.reasoningCostSamples ?? 0))"
        ]
        if usage.expiredRecords > 0 { lines.append("Expired request records excluded: \(usage.expiredRecords)") }
        lines.append("Usage is a snapshot of this session's own retained requests; inherited conversation history and unreported in-flight usage are not added.")
        return lines
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
