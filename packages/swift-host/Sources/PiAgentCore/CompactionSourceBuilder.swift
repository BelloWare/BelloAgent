import Foundation

/// Pi's summary source and prompts (compaction/utils.ts and compaction.ts,
/// v0.85.1): the conversation serialized as text so the model summarizes it
/// instead of continuing it, with each tool result cut to 2,000 characters.
enum CompactionSourceBuilder {
    static let systemPrompt = """
    You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

    Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
    """
    static let summarizationPrompt = """
    The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

    Use this EXACT format:

    ## Goal
    [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

    ## Constraints & Preferences
    - [Any constraints, preferences, or requirements mentioned by user]
    - [Or "(none)" if none were mentioned]

    ## Progress
    ### Done
    - [x] [Completed tasks/changes]

    ### In Progress
    - [ ] [Current work]

    ### Blocked
    - [Issues preventing progress, if any]

    ## Key Decisions
    - **[Decision]**: [Brief rationale]

    ## Next Steps
    1. [Ordered list of what should happen next]

    ## Critical Context
    - [Any data, examples, or references needed to continue]
    - [Or "(none)" if not applicable]

    Keep each section concise. Preserve exact file paths, function names, and error messages.
    """
    static let updateInstructions = """
    Update the existing structured summary with new information. RULES:
    - PRESERVE all existing information from the previous summary
    - ADD new progress, decisions, and context from the new messages
    - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    - UPDATE "Next Steps" based on what was accomplished
    - PRESERVE exact file paths, function names, and error messages
    - If something is no longer relevant, you may remove it

    Use this EXACT format:

    ## Goal
    [Preserve existing goals, add new ones if the task expanded]

    ## Constraints & Preferences
    - [Preserve existing, add new ones discovered]

    ## Progress
    ### Done
    - [x] [Include previously done items AND newly completed items]

    ### In Progress
    - [ ] [Current work - update based on progress]

    ### Blocked
    - [Current blockers - remove if resolved]

    ## Key Decisions
    - **[Decision]**: [Brief rationale] (preserve all previous, add new)

    ## Next Steps
    1. [Update based on current state]

    ## Critical Context
    - [Preserve important context, add new if needed]

    Keep each section concise. Preserve exact file paths, function names, and error messages.
    """
    static let turnPrefixPrompt = """
    This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

    Summarize the prefix to provide context for the retained suffix:

    ## Original Request
    [What did the user ask for in this turn?]

    ## Early Progress
    - [Key decisions and work done in the prefix]

    ## Context for Suffix
    - [Information needed to understand the retained recent work]

    Be concise. Focus on what's needed to understand the kept suffix.
    """
    static let updatePrompt = "The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.\n\n" + updateInstructions
    /// Ours: a turn prefix too large for one request continues in the next,
    /// the way pi's update prompt continues a summary.
    static let turnPrefixUpdatePrompt = "The messages above are NEW messages from the same turn prefix, to incorporate into the existing prefix summary provided in <previous-summary> tags.\n\n" + turnPrefixPrompt
    static let toolResultMaxChars = 2000
    static let noPriorHistory = "No prior history."
    static let splitTurnSeparator = "\n\n---\n\n**Turn Context (split turn):**\n\n"

    /// serializeConversation, one entry per part pi writes; pi joins them
    /// with a blank line.
    static func serialize(_ messages: [ChatMessage]) -> [String] {
        var parts: [String]=[]
        for message in messages {
            switch message.role {
            case "assistant":
                let thinking=message.content.filter { $0["type"].text == "thinking" }.compactMap { $0["thinking"].text }.filter { !$0.isEmpty }
                let calls=message.content.filter { $0["type"].text == "toolCall" }.map { ($0["name"].text ?? "")+"("+arguments($0["arguments"])+")" }
                if !thinking.isEmpty { parts.append("[Assistant thinking]: "+thinking.joined(separator:"\n")) }
                if message.content.contains(where: { $0["type"].text == "text" }) { parts.append("[Assistant]: "+text(message,separator:"\n")) }
                if !calls.isEmpty { parts.append("[Assistant tool calls]: "+calls.joined(separator:"; ")) }
            case "toolResult":
                let content=text(message,separator:"")
                guard !content.isEmpty else { continue }
                parts.append("[Tool result]: "+truncate(content).0)
            default:
                // Ours: a hidden note is the user message it was sent as.
                if let note=message.contextNote { parts.append("[User]: "+note.text) }
                let content=text(message,separator:"")
                if !content.isEmpty { parts.append("[User]: "+content) }
            }
        }
        return parts
    }
    static func text(_ message: ChatMessage, separator: String) -> String {
        message.content.filter { $0["type"].text == "text" }.compactMap { $0["text"].text }.joined(separator:separator)
    }
    /// `k=JSON.stringify(v)` per argument, in a stable key order.
    static func arguments(_ value: JSON) -> String {
        guard case .object(let fields)=value else { return value.isNull ? "" : value.encoded() }
        return fields.keys.sorted().map { $0+"="+fields[$0]!.encoded() }.joined(separator:", ")
    }
    /// truncateForSummary: the first 2,000 UTF-16 units, as JavaScript counts
    /// them, without splitting a character's surrogate pair.
    static func truncate(_ text: String, maxChars: Int = toolResultMaxChars) -> (String, Bool) {
        let length=text.utf16.count
        guard length > maxChars else { return (text,false) }
        var used=0, end=text.unicodeScalars.startIndex
        for scalar in text.unicodeScalars {
            guard used+scalar.utf16.count <= maxChars else { break }
            used += scalar.utf16.count; end=text.unicodeScalars.index(after:end)
        }
        return (String(text.unicodeScalars[..<end])+"\n\n[... \(length-used) more characters truncated]",true)
    }

    /// generateSummaryWithUsage's prompt text; the turn prefix's when `turnPrefix`.
    static func prompt(_ parts: ArraySlice<String>, previous: String?, turnPrefix: Bool, focus: String? = nil) -> String {
        var text="<conversation>\n"+parts.joined(separator:"\n\n")+"\n</conversation>\n\n"
        if let previous { text += "<previous-summary>\n"+previous+"\n</previous-summary>\n\n" }
        text += turnPrefix ? (previous == nil ? turnPrefixPrompt : turnPrefixUpdatePrompt) : (previous == nil ? summarizationPrompt : updatePrompt)
        // Pi's customInstructions.
        if let focus { text += "\n\nAdditional focus: "+focus }
        return text
    }
    /// A part too long for the room left is cut after `fraction` of it and
    /// continues in the next request; nothing is dropped.
    static func split(_ part: String, fraction: Double) -> [String]? {
        let scalars=part.unicodeScalars, count=scalars.count, head=Int(Double(count)*min(max(fraction,0),1))
        guard head > 0, head < count else { return nil }
        let middle=scalars.index(scalars.startIndex,offsetBy:head)
        return [String(scalars[..<middle]),"[continued]: "+String(scalars[middle...])]
    }

    /// extractFileOperations and computeFileLists: paths read, written or
    /// edited, merged with the previous checkpoint's lists.
    static func fileLists(_ messages: [ChatMessage], previous: JSON?) -> (read: [String], modified: [String]) {
        var read=Set(previous?["readFiles"].list.compactMap(\.text) ?? []), modified=Set(previous?["modifiedFiles"].list.compactMap(\.text) ?? [])
        for message in messages where message.role == "assistant" {
            for call in message.content where call["type"].text == "toolCall" {
                guard let path=call["arguments"]["path"].text, !path.isEmpty else { continue }
                switch call["name"].text {
                case "read": read.insert(path)
                case "write", "edit": modified.insert(path)
                default: break
                }
            }
        }
        // JavaScript's default sort: UTF-16 code unit order.
        func sorted(_ paths: Set<String>) -> [String] { paths.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }
        return (sorted(read.subtracting(modified)),sorted(modified))
    }
    /// formatFileOperations.
    static func fileOperations(read: [String], modified: [String]) -> String {
        var sections: [String]=[]
        if !read.isEmpty { sections.append("<read-files>\n\(read.joined(separator:"\n"))\n</read-files>") }
        if !modified.isEmpty { sections.append("<modified-files>\n\(modified.joined(separator:"\n"))\n</modified-files>") }
        return sections.isEmpty ? "" : "\n\n"+sections.joined(separator:"\n\n")
    }
}
