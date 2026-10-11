// Runs Swift 0.1.122's own declarations (Extracted.swift) over a fixed
// corpus and prints what they say, as JSON, for the Rust checks.
import Foundation

var out: [String: Any] = [:]

// TranscriptCardMetrics: every split of a capped list.
var splits: [[String: Any]] = []
for maxLines in [7, 12] {
    for total in 0...40 {
        for expanded in [false, true] {
            let cap = TranscriptCardMetrics.headTail(total: total, maxLines: maxLines, expanded: expanded)
            splits.append(["total": total, "maxLines": maxLines, "expanded": expanded,
                           "hidden": cap.hidden, "capped": cap.capped, "head": cap.head, "tail": cap.tail,
                           "collapses": TranscriptCardMetrics.collapses(hidden: cap.hidden),
                           "moreLines": TranscriptCardMetrics.moreLines(cap.hidden)])
        }
    }
}
out["splits"] = splits
out["caps"] = ["diffLines": TranscriptCardMetrics.diffLines, "readLines": TranscriptCardMetrics.readLines,
               "terminalCap": Double(TranscriptCardMetrics.terminalCap), "sectionCap": Double(TranscriptCardMetrics.sectionCap)]

// A read card's window label.
var windows: [[String: Any]] = []
for total in [0, 1, 2, 12, 13, 14, 340] {
    for shown in [0, 1, 12, 13, total] {
        windows.append(["shown": shown, "total": total, "label": TranscriptReadCardText.window(shown: shown, total: total)])
    }
}
out["windows"] = windows

// Numbers as the cards write them, in the en_US locale.
let locale = Locale(identifier: "en_US")
out["numbers"] = [0, 7, 999, 1000, 9000, 12345, 1234567, 10000000].map { ["value": $0, "text": transcriptNumber($0, locale)] }

// The end-of-turn fold's line and the display modes.
var folds: [[String: Any]] = []
for calls in 0...3 { for messages in 0...3 { for subagents in 0...3 {
    let spec = TurnFoldSpec(group: "g", answerResponseID: "a", toolCalls: calls, messages: messages, subagents: subagents)
    folds.append(["toolCalls": calls, "messages": messages, "subagents": subagents, "label": spec.label])
} } }
out["folds"] = folds
out["subagents"] = ["subagent", "subagent_review", "subagents", "sub_agent", "bash", ""].map { ["name": $0, "subagent": TurnFoldSpec.isSubagent($0)] }
out["modes"] = TranscriptDisplayMode.allCases.map { ["mode": $0.rawValue, "label": $0.label, "detail": $0.detail] }
out["fallback"] = TranscriptDisplayMode.fallback.rawValue

// A response header's work words: `TaskTranscriptPlan.responseLine`'s
// `calls.label(reasoned:) ?? (visible(text) ? "Answered" : "Response")`.
let states = ["completed", "failed", "cancelled", "skipped", "unknown", "recorded", "interrupted", "running", "prepared", "preparing"]
var works: [[String: Any]] = []
for thinking in ["", "  \n", "Plan."] {
    for text in ["", " ", "Done."] {
        for tools in [[], ["completed"], ["completed", "failed"], ["running", "preparing"], states] {
            let views = tools.enumerated().map { ToolView(id: "t\($0.offset)", name: "bash", state: $0.element, input: "{}", output: "", durationMs: nil, truncated: false) }
            let reasoned = TaskTranscriptPlan.visible(thinking)
            let calls = ToolCallSummary(tools: views)
            let work = calls.label(reasoned: reasoned) ?? (TaskTranscriptPlan.visible(text) ? "Answered" : "Response")
            works.append(["thinking": thinking, "text": text, "states": tools, "work": work])
        }
    }
}
out["works"] = works

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
