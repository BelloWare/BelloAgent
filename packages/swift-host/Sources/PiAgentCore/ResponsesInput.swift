import Foundation

/// Pi 0.85.1's Responses input (openai-responses-shared.ts
/// convertResponsesMessages, after transform-messages.ts transformMessages),
/// over the helper's messages.
extension ProviderClient {
    /// OPENAI_RESPONSES_MIN_OUTPUT_TOKENS.
    static let minimumOutputTokens = 16
    /// What pi reports when a Responses stream ends without its terminal event.
    static let piIncompleteStream = "OpenAI Responses stream ended before a terminal response event"
    /// messages.ts COMPACTION_SUMMARY_PREFIX and COMPACTION_SUMMARY_SUFFIX.
    static let compactionSummaryPrefix = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
    static let compactionSummarySuffix = "\n</summary>"
    /// transform-messages.ts placeholders for a model without image input.
    static let userImagePlaceholder = "(image omitted: model does not support images)"
    static let toolImagePlaceholder = "(tool image omitted: model does not support images)"

    /// clampOpenAIPromptCacheKey: the session id, at most 64 characters.
    static func promptCacheKey(_ sessionID: String) -> String { String(String.UnicodeScalarView(sessionID.unicodeScalars.prefix(64))) }

    /// shortHash (utils/hash.ts), over UTF-16 code units as JavaScript reads them.
    static func shortHash(_ text: String) -> String {
        var h1: UInt32 = 0xdeadbeef, h2: UInt32 = 0x41c6ce57
        for unit in text.utf16 {
            h1 = (h1 ^ UInt32(unit)) &* 2654435761
            h2 = (h2 ^ UInt32(unit)) &* 1597334677
        }
        h1 = ((h1 ^ (h1 >> 16)) &* 2246822507) ^ ((h2 ^ (h2 >> 13)) &* 3266489909)
        h2 = ((h2 ^ (h2 >> 16)) &* 2246822507) ^ ((h1 ^ (h1 >> 13)) &* 3266489909)
        return String(h2, radix: 36) + String(h1, radix: 36)
    }

    /// The input array: the system prompt first, then every replayed message.
    static func responsesInput(_ history: [ChatMessage], instructions: String, profile p: Profile) throws -> [JSON] {
        try responsesProjection(history, instructions: instructions, profile: p).items
    }
    struct InputProjection {
        var items: [JSON]
        var ranges: [String: Range<Int>]
    }
    /// The same conversion, with local source ownership for describing a
    /// compaction boundary. No marker or metadata is added to wire items.
    static func responsesProjection(_ history: [ChatMessage], instructions: String, profile p: Profile) throws -> InputProjection {
        var input: [JSON] = []
        var ranges: [String: Range<Int>] = [:]
        // Pi puts the system prompt in the input: as a developer message to a
        // reasoning model, unless the gateway declares no developer role.
        if !instructions.isEmpty {
            let developer = p.raw["reasoning"].flag == true && p.raw["compat"]["supportsDeveloperRole"].flag != false
            input.append(["role": JSON(developer ? "developer" : "system"), "content": JSON(instructions)])
        }
        let images = p.raw["input"].list.contains("image")
        var msgIndex = 0
        // A call whose result never arrived gets pi's synthetic error result
        // before the next assistant or user message.
        var pending: [String] = [], answered = Set<String>()
        func settle() {
            for call in pending where !answered.contains(call) {
                input.append(["type": "function_call_output", "call_id": JSON(call), "output": "No result provided"])
            }
            pending = []; answered = []
        }
        for message in history {
            let start = input.count
            defer { ranges[message.id] = start..<input.count }
            switch message.role {
            case "assistant":
                settle()
                let items = try assistantItems(message, profile: p, msgIndex: msgIndex)
                let calls = message.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text }
                if !calls.isEmpty { pending = calls; answered = [] }
                if items.isEmpty { continue }
                input += items
            case "toolResult":
                guard let call = message.toolCallId else { throw AgentError("invalid_context", "Tool result has no call identity") }
                answered.insert(call)
                input.append(["type": "function_call_output", "call_id": JSON(call), "output": toolOutput(message, images: images)])
            default:
                settle()
                // Ours: a hidden note is a user message of its own, sent just
                // before the message that carries it (ChatMessage.contextNote).
                if let note = message.contextNote {
                    input.append(["role": "user", "content": [["type": "input_text", "text": JSON(note.text)]]])
                }
                let content = userContent(message, images: images)
                if content.isEmpty { continue }
                input.append(["role": "user", "content": .array(content)])
            }
            msgIndex += 1
        }
        settle()
        return InputProjection(items: input, ranges: ranges)
    }

    /// A user message's content. A compaction checkpoint replays as pi's
    /// compactionSummary message; an image goes to a model that declares
    /// image input, else pi's placeholder text takes its place.
    static func userContent(_ message: ChatMessage, images: Bool) -> [JSON] {
        if message.kind == "compaction" {
            let text = compactionSummaryPrefix + CompactionCheckpoint.summaryText(message) + compactionSummarySuffix
            return [["type": "input_text", "text": JSON(text)]]
        }
        var content: [JSON] = [], previousWasPlaceholder = false
        for block in message.content {
            switch block["type"].text {
            case "text":
                let text = block["text"].text ?? ""
                content.append(["type": "input_text", "text": JSON(text)])
                previousWasPlaceholder = text == userImagePlaceholder
            case "image":
                guard let data = block["data"].text, let mime = block["mimeType"].text else { continue }
                if images {
                    content.append(["type": "input_image", "detail": "auto", "image_url": JSON("data:\(mime);base64,\(data)")])
                } else if !previousWasPlaceholder {
                    content.append(["type": "input_text", "text": JSON(userImagePlaceholder)]); previousWasPlaceholder = true
                }
            default: continue
            }
        }
        return content
    }

    /// convertToolResultOutput: the text blocks joined by newlines, or with
    /// images for a model that takes them, the text and each image.
    static func toolOutput(_ message: ChatMessage, images supported: Bool) -> JSON {
        var texts: [String] = [], images: [JSON] = [], previousWasPlaceholder = false
        for block in message.content {
            switch block["type"].text {
            case "text":
                let text = block["text"].text ?? ""
                texts.append(text); previousWasPlaceholder = text == toolImagePlaceholder
            case "image":
                guard let data = block["data"].text, let mime = block["mimeType"].text else { continue }
                if supported { images.append(["type": "input_image", "detail": "auto", "image_url": JSON("data:\(mime);base64,\(data)")]) }
                else if !previousWasPlaceholder { texts.append(toolImagePlaceholder); previousWasPlaceholder = true }
            default: continue
            }
        }
        let text = texts.joined(separator: "\n")
        guard !images.isEmpty else { return JSON(text.isEmpty ? "(no tool output)" : text) }
        return .array((text.isEmpty ? [] : [["type": "input_text", "text": JSON(text)]]) + images)
    }

    /// One assistant message's items. A message whose provider items this
    /// route replays (see `replayItems`) replays them as pi replays a reply of
    /// the same model: its reasoning items as received, one message item per
    /// output message, its calls with their fc_ ids. Otherwise it replays from
    /// its content without provider state: pi's conversion for a reply whose
    /// state is not replayed, where a reply of another model also turns its
    /// reasoning summary into text.
    static func assistantItems(_ message: ChatMessage, profile p: Profile, msgIndex: Int) throws -> [JSON] {
        let replayed = try replayItems(message, profile: p)
        let recorded = message.providerBinding?["profile"]["model"].text
        let sameModel = recorded == nil || recorded == p.model
        var output: [JSON] = [], textIndex = 0
        func messageID(_ id: String?) -> String {
            let fallback = textIndex == 0 ? "msg_pi_\(msgIndex)" : "msg_pi_\(msgIndex)_\(textIndex)"
            textIndex += 1
            guard let id, !id.isEmpty else { return fallback }
            return id.count > 64 ? "msg_" + shortHash(id) : id
        }
        func text(_ value: String, id: String?, phase: JSON = .null) -> JSON {
            var item: JSON = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": JSON(value), "annotations": []]],
                              "status": "completed", "id": JSON(messageID(id))]
            if let phase = phase.text, ["commentary", "final_answer"].contains(phase) { item["phase"] = JSON(phase) }
            return item
        }
        if sameModel, let items = replayed {
            for item in items {
                switch item["type"].text {
                case "reasoning": output.append(item)
                case "message":
                    let joined = item["content"].list.map { $0["type"].text == "output_text" ? ($0["text"].text ?? "") : ($0["refusal"].text ?? "") }.joined()
                    output.append(text(joined, id: item["id"].text, phase: item["phase"]))
                case "function_call":
                    let arguments = message.content.first { $0["type"].text == "toolCall" && $0["id"] == item["call_id"] }?["arguments"]
                        ?? PiProviderRules.parseArguments(item["arguments"].text)
                    var call: JSON = ["type": "function_call", "call_id": item["call_id"], "name": item["name"], "arguments": JSON(arguments.encoded())]
                    if let id = item["id"].text, id.hasPrefix("fc_") { call["id"] = JSON(id) }
                    output.append(call)
                default: continue
                }
            }
            return output
        }
        for block in message.content {
            switch block["type"].text {
            case "thinking":
                // Reasoning without its replayable item is dropped for the same
                // model and becomes plain text for another one.
                guard !sameModel, let thinking = block["thinking"].text, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                output.append(text(thinking, id: nil))
            case "text": output.append(text(block["text"].text ?? "", id: nil))
            case "toolCall":
                output.append(["type": "function_call", "call_id": block["id"], "name": block["name"], "arguments": JSON(block["arguments"].encoded())])
            default: continue
            }
        }
        return output
    }
}
