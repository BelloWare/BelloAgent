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
            input.append(["role": JSON(p.instructionRole), "content": JSON(instructions)])
        }
        let images = p.raw["input"].list.contains("image")
        var msgIndex = 0
        // A call whose result never arrived gets pi's synthetic error result
        // before the next assistant or user message.
        var pending: [String] = [], answered = Set<String>()
        // How the calls that are waiting were named: their outputs, real or
        // synthetic, go under the very id the calls were sent with (`sentCallID`).
        var naming = CallNaming.own
        let signed = takesSignedCallIDs(history, profile: p)
        func settle() {
            for call in pending where !answered.contains(call) {
                input.append(["type": "function_call_output", "call_id": JSON(sentCallID(call, naming)), "output": "No result provided"])
            }
            pending = []; answered = []
        }
        for message in history {
            let start = input.count
            defer { ranges[message.id] = start..<input.count }
            switch message.role {
            case "assistant":
                settle()
                let replay = try replay(of: message, profile: p, signed: signed)
                let items = assistantItems(message, replay: replay, msgIndex: msgIndex)
                let calls = message.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text }
                if !calls.isEmpty { pending = calls; answered = []; naming = replay.calls }
                if items.isEmpty { continue }
                input += items
            case "toolResult":
                guard let call = message.toolCallId else { throw AgentError("invalid_context", "Tool result has no call identity") }
                answered.insert(call)
                input.append(["type": "function_call_output", "call_id": JSON(sentCallID(call, naming)), "output": toolOutput(message, images: images)])
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
            var text = compactionSummaryPrefix + CompactionCheckpoint.summaryText(message) + compactionSummarySuffix
            // Ours: the framing a mid-task checkpoint recorded, after pi's wrapper.
            if let continuation = message.compaction?["continuationText"].text, !continuation.isEmpty { text += "\n\n" + continuation }
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

    /// Whether `p`'s model wrote `message`: a reply that names no model is
    /// taken as its own.
    static func sameModel(_ message: ChatMessage, profile p: Profile) -> Bool {
        let recorded = message.providerBinding?["profile"]["model"].text
        return recorded == nil || recorded == p.model
    }

    /// The longest call ID every provider accepts: OpenAI's Responses limit.
    static let portableCallIDBytes = 64

    /// The ID a request names a call by, for the call and for its output. The
    /// model that made the call gets its ID back byte for byte: LiteLLM keeps
    /// a Gemini thought signature in it and pairs an output with its call by
    /// equality. Another model cannot use that signature and may refuse the
    /// ID (OpenAI: "string too long. Expected a string with maximum length
    /// 64"), so a longer ID goes to it as a short name derived from it, the
    /// same every time. The journal keeps the original either way.
    static func sentCallID(_ id: String, own: Bool) -> String { sentCallID(id, own ? .own : .portable) }

    /// How a request names one reply's calls.
    /// - `own`: byte for byte, to the model that made them.
    /// - `portable`: a short name for an ID over 64 bytes, to another model.
    /// - `unsigned`: also a short name for any ID that carries a thought
    ///   signature (`…__thought__<signature>`, a LiteLLM direct Gemini
    ///   route), whatever its length and whichever model reads it: for a
    ///   reply whose reasoning is not sent.
    enum CallNaming: Sendable { case own, portable, unsigned }
    /// What LiteLLM puts between a Gemini call's ID and its thought signature.
    static let thoughtSignatureMark = "__thought__"
    static func sentCallID(_ id: String, _ naming: CallNaming) -> String {
        let short = { "call_" + sha256(Data(id.utf8)).prefix(32) }
        switch naming {
        case .own: return id
        case .portable: return id.utf8.count <= portableCallIDBytes ? id : short()
        case .unsigned: return id.utf8.count <= portableCallIDBytes && !id.contains(thoughtSignatureMark) ? id : short()
        }
    }

    /// How one reply is sent back.
    struct ReplyReplay: Sendable {
        /// The provider items to replay, reasoning first as received; nil
        /// for a reply rebuilt from its text and tool calls.
        var items: [JSON]?
        var calls: CallNaming
        /// A rebuilt reply of another model carries its reasoning summary as
        /// text (pi's rule). Not when the reasoning is withheld.
        var thinkingAsText: Bool
        /// Whether a call keeps an `fc_` item ID over 64 bytes (its own model only).
        var longItemIDs: Bool
    }
    /// The one rule for what a request carries of a reply (`Profile.reasoning`).
    /// `signed`: the request's model is a Gemini one, which takes another
    /// Gemini model's call IDs as they are (`takesSignedCallIDs`).
    static func replay(of message: ChatMessage, profile p: Profile, signed: Bool = false) throws -> ReplyReplay {
        let same = sameModel(message, profile: p)
        let rebuilt = ReplyReplay(items: nil, calls: same ? .own : .portable, thinkingAsText: !same, longItemIDs: false)
        // The owner agreed that this model goes on without this reply's
        // reasoning, whatever the connection's policy (a pinned route's own
        // state can be refused too): no item, no signature in a call ID, no
        // `fc_` ID (OpenAI refuses one whose reasoning item is gone), and no
        // summary as text.
        if p.reasoningWithheld.contains(message.id) { return ReplyReplay(items: nil, calls: .unsigned, thinkingAsText: false, longItemIDs: false) }
        switch p.reasoning {
        case .pinned, .legacy:
            // 0.1.137's rules, unchanged: a pinned route's own replies with
            // their state, everything else from its text and calls.
            guard same, let items = try replayItems(message, profile: p) else { return rebuilt }
            return ReplyReplay(items: items, calls: .own, thinkingAsText: false, longItemIDs: true)
        case .never:
            return ReplyReplay(items: nil, calls: .unsigned, thinkingAsText: !same, longItemIDs: false)
        case .send:
            // Stored under this rule: its reasoning goes back as received,
            // also to another model, alias or connection. Most gateways drop
            // what the target cannot use; one that refuses it is asked about.
            if message.reasoningReplay == true, let items = message.providerItems {
                // The 64-byte limit on a call ID is OpenAI's. Another Gemini
                // model reads the signature LiteLLM keeps in a Gemini call's
                // ID (3.5 and 3.1 took each other's), so it gets the ID whole;
                // if it does refuse the signature, that is the owner's question.
                let whole = same || signed
                return ReplyReplay(items: items, calls: whole ? .own : .portable, thinkingAsText: false, longItemIDs: whole)
            }
            // Any other reply (every one stored before 0.1.138) goes exactly
            // as that build sent it: from its text and calls, or, where the
            // connection was not set to portable history, from its own items
            // when they hold nothing but messages and calls. What 0.1.137
            // refused to send (`opaque_replay_policy`) goes from text and calls.
            let plain: Set<String> = ["message", "function_call"]
            guard same, p.routing.policy != "portable", let items = message.providerItems, items.allSatisfy({ plain.contains($0["type"].text ?? "") }) else { return rebuilt }
            return ReplyReplay(items: items, calls: .own, thinkingAsText: false, longItemIDs: true)
        }
    }

    /// Whether a request of `p` goes to a Gemini model: its name says so, or,
    /// for an alias such as `flash-lite` that says nothing by its name, the
    /// gateway reported a Gemini model for that alias's own replies in this
    /// chat, or one of them made a call whose ID carries a thought signature,
    /// as only LiteLLM's direct Gemini routes do.
    static func takesSignedCallIDs(_ history: [ChatMessage], profile p: Profile) -> Bool {
        if p.model.lowercased().contains("gemini") { return true }
        return history.contains { reply in
            guard reply.role == "assistant", reply.providerBinding?["profile"]["model"].text == p.model else { return false }
            // What the gateway reported for that alias's own replies
            // (`x-litellm-model-name: gemini/gemini-3.5-flash-lite`), or an id it minted.
            if reply.providerIdentity?["reportedModels"].list.contains(where: { $0.text?.lowercased().contains("gemini") == true }) == true { return true }
            return reply.content.contains { $0["type"].text == "toolCall" && $0["id"].text?.contains(thoughtSignatureMark) == true }
        }
    }

    /// Whether an input item carries reasoning only its maker can read: an
    /// encrypted or signed reasoning item, or a call named by an ID with a
    /// thought signature in it.
    static func carriesReasoning(_ item: JSON) -> Bool {
        switch item["type"].text {
        case "reasoning":
            return !(item["encrypted_content"].text ?? "").isEmpty || !item["signature"].isNull || item["content"].list.contains { !$0["signature"].isNull }
        case "function_call": return [item["call_id"].text, item["id"].text].contains { $0?.contains(thoughtSignatureMark) == true }
        case "function_call_output": return item["call_id"].text?.contains(thoughtSignatureMark) == true
        default: return false
        }
    }
    /// The replies a request built from `history` sends reasoning of.
    /// `signedOnly`: only those that name a call by an id with a thought
    /// signature in it.
    static func reasoningCarriers(_ history: [ChatMessage], profile p: Profile, signedOnly: Bool = false) throws -> [String] {
        let projection = try responsesProjection(history, instructions: "", profile: p)
        func carries(_ item: JSON) -> Bool { carriesReasoning(item) && (!signedOnly || item["type"].text == "function_call") }
        return history.filter { $0.role == "assistant" }.compactMap { message in
            projection.ranges[message.id].flatMap { projection.items[$0].contains(where: carries) ? message.id : nil }
        }
    }

    /// One assistant message's items. A message whose provider items are
    /// replayed (see `replay(of:profile:)`) replays them as pi replays a reply
    /// of the same model: its reasoning items as received, one message item
    /// per output message, its calls with their fc_ ids. Otherwise it replays
    /// from its content without provider state: pi's conversion for a reply
    /// whose state is not replayed, where a reply of another model also turns
    /// its reasoning summary into text.
    static func assistantItems(_ message: ChatMessage, profile p: Profile, msgIndex: Int) throws -> [JSON] {
        assistantItems(message, replay: try replay(of: message, profile: p), msgIndex: msgIndex)
    }
    static func assistantItems(_ message: ChatMessage, replay: ReplyReplay, msgIndex: Int) -> [JSON] {
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
        if let items = replay.items {
            for item in items {
                switch item["type"].text {
                case "reasoning": output.append(item)
                case "message":
                    let joined = item["content"].list.map { $0["type"].text == "output_text" ? ($0["text"].text ?? "") : ($0["refusal"].text ?? "") }.joined()
                    output.append(text(joined, id: item["id"].text, phase: item["phase"]))
                case "function_call":
                    let arguments = message.content.first { $0["type"].text == "toolCall" && $0["id"] == item["call_id"] }?["arguments"]
                        ?? PiProviderRules.parseArguments(item["arguments"].text)
                    let name = item["call_id"].text.map { JSON(sentCallID($0, replay.calls)) } ?? item["call_id"]
                    var call: JSON = ["type": "function_call", "call_id": name, "name": item["name"], "arguments": JSON(arguments.encoded())]
                    // Another model is not sent an item ID it would refuse for
                    // its length (`fc_call_…__thought__…`).
                    if let id = item["id"].text, id.hasPrefix("fc_"), replay.longItemIDs || id.utf8.count <= portableCallIDBytes { call["id"] = JSON(id) }
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
                guard replay.thinkingAsText, let thinking = block["thinking"].text, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                output.append(text(thinking, id: nil))
            case "text": output.append(text(block["text"].text ?? "", id: nil))
            case "toolCall":
                let call = block["id"].text.map { JSON(sentCallID($0, replay.calls)) } ?? block["id"]
                output.append(["type": "function_call", "call_id": call, "name": block["name"], "arguments": JSON(block["arguments"].encoded())])
            default: continue
            }
        }
        return output
    }
}
