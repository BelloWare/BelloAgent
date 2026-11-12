import Foundation

/// Settings › a connection › Reasoning continuation: whether the reasoning a
/// model returned is sent back to it with later requests (owner, 2026-11-11:
/// "encrypted reasoning should be not ignored… unless it got rejected by
/// litellm due to model switch, which then we need user confirmation").
///
/// What is stored (`ProfileRecord.reasoningReplay`, `routing.replayPolicy`)
/// stays readable by 0.1.137, which knows three policy values and nothing
/// else: "send" and "never" are both saved as its `portable`, and "never"
/// adds the record's own field.
enum ReasoningReplayChoice {
    static let send = "send", never = "never", pinned = "pinned"
    static let options = [(send, "Send reasoning back"), (never, "Never send reasoning back"), (pinned, "Preserve native state on a fixed route")]
    static let footer = "Reasoning a model returns (encrypted or signed) is sent back with later requests, also after a model or connection change, starting with replies made from Bello Agent 0.1.138 on. If a provider refuses it, the turn stops and its notice offers to continue without the earlier reasoning. Never sends text and tool calls only. A fixed route sends native state only while your gateway reports the expected model."
    /// The choice a saved or new connection shows.
    static func shown(_ profile: ProfileRecord, routing: [String: WireValue]) -> String {
        if routing["replayPolicy"]?.string == "pinned" { return pinned }
        return profile.reasoningReplay == "never" ? never : send
    }
}
