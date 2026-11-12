import Foundation

/// A provider's refusal of reasoning that a request sent back from earlier
/// replies (owner, 2026-11-11: "encrypted reasoning should be not ignored…
/// unless it got rejected by litellm due to model switch, which then we need
/// user confirmation to proceed with previous encrypted reasoning removed").
///
/// LiteLLM never refuses reasoning itself: it passes on the provider's text
/// inside `error.message`, with `error.code` "400" and escaping that varies
/// by route (pretty JSON, compact JSON, escaped twice inside OpenRouter's
/// `raw`, a Python `b'…'`). So the rules below read substrings of the
/// message, case-insensitively, never a parsed structure. The texts and the
/// routes they came from are in `docs/Reasoning-Replay.md`.
struct ReasoningRejection: Equatable, Sendable {
    enum Rule: String, Sendable {
        /// OpenAI, Azure: `invalid_encrypted_content`.
        case encryptedContent
        /// "…organization_id did not match the target organization": another
        /// key, organization or region. The route changed, certainly.
        case organization
        /// "…could not be decrypted or parsed": foreign or damaged.
        case undecryptable
        /// Anthropic: "Invalid `signature` in `thinking` block".
        case thinkingSignature
        /// Gemini: "Corrupted thought signature" (AI Studio), "Invalid thought signature" (Vertex).
        case thoughtSignature
        /// LiteLLM's own help text about deployments with different keys.
        case affinity
        /// OpenAI: a call id over 64 characters. A refusal of reasoning only
        /// when the request named a call by an id with a thought signature in
        /// it (`…__thought__…`), which the session checks.
        case signedCallID
    }
    let rule: Rule
    /// The provider's own sentence, for the owner: unescaped and bounded.
    let sentence: String
    /// Whether the provider's own words say the route changed (another organization).
    let routeChanged: Bool
    /// Whether LiteLLM's help about deployments with different keys came with it.
    let affinity: Bool

    /// The longest sentence shown to the owner.
    static let sentenceLimit = 300
    private static let thinkingBlock = try! NSRegularExpression(pattern: "invalid .?signature.? in .?thinking.? block", options: [.caseInsensitive])

    /// `message` is a gateway's `error.message`; `code` the provider's own
    /// code where a failure event still carries it.
    static func match(message: String, code: String? = nil) -> ReasoningRejection? {
        // The provider's JSON is quoted inside the message once or twice:
        // read it with those quotings undone, which changes no rule's words.
        let text = unescaped(message), lower = text.lowercased()
        func has(_ words: String) -> Bool { lower.contains(words) }
        let affinity = has("encrypted_content_affinity") || has("this error occurs when load balancing responses api across deployments with different api keys")
        let organization = has("organization_id did not match the target organization")
        let rule: Rule
        if organization { rule = .organization }
        else if has("could not be decrypted or parsed") { rule = .undecryptable }
        // "could not be verified" alone is said of keys and accounts too.
        else if has("invalid_encrypted_content") || (has("could not be verified") && has("encrypted content")) || code?.lowercased() == "invalid_encrypted_content" { rule = .encryptedContent }
        else if thinkingBlock.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { rule = .thinkingSignature }
        else if has("corrupted thought signature") || has("invalid thought signature") { rule = .thoughtSignature }
        else if affinity { rule = .affinity }
        else if has("string too long"), has("call_id"), has("maximum length 64") { rule = .signedCallID }
        else { return nil }
        // LiteLLM adds its help about deployments to any refusal of this
        // kind, a damaged blob's too: only the provider's own words about
        // the organization say the route changed.
        return ReasoningRejection(rule: rule, sentence: sentence(text, rule: rule), routeChanged: organization, affinity: affinity)
    }
    /// A failure frame of a stream, or a parsed HTTP error body.
    static func match(_ value: JSON) -> ReasoningRejection? {
        let detail = value["response"]["error"].isNull ? value["error"] : value["response"]["error"]
        let message = [detail["message"].text, detail.text, value["message"].text].compactMap { $0 }.first { !$0.isEmpty }
        let code = [detail["code"].text, value["code"].text].compactMap { $0 }.first { $0.lowercased() == "invalid_encrypted_content" }
        guard message != nil || code != nil else { return nil }
        return match(message: message ?? "", code: code)
    }
    /// An HTTP error body, of which at most 64 KiB is kept: one that does
    /// not parse is read as text.
    static func match(body: Data) -> ReasoningRejection? {
        if let value = try? JSON.parse(body), let found = match(value) { return found }
        return (try? JSON.parse(body)) == nil ? match(message: String(decoding: body, as: UTF8.self)) : nil
    }

    /// Undoes JSON string quoting (`\"`, `\n`, `\\`) until none is left.
    private static func unescaped(_ text: String) -> String {
        var value = text
        for _ in 0..<4 {
            let next = value.replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\u{0}", with: "\\")
            if next == value { break }
            value = next
        }
        return value
    }
    /// The provider's sentence around the words that matched: from the quote
    /// or line that opens it to the one that closes it.
    private static func sentence(_ text: String, rule: Rule) -> String {
        let lower = text.lowercased()
        let anchors: [String]
        switch rule {
        case .encryptedContent, .organization, .undecryptable: anchors = ["the encrypted content for item", "could not be verified", "invalid_encrypted_content"]
        case .thinkingSignature: anchors = ["signature"]
        case .thoughtSignature: anchors = ["corrupted thought signature", "invalid thought signature"]
        case .affinity: anchors = ["this error occurs when load balancing", "encrypted_content_affinity"]
        case .signedCallID: anchors = ["string too long"]
        }
        var found: Range<String.Index>?
        if rule == .thinkingSignature, let match = thinkingBlock.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) { found = Range(match.range, in: text) }
        else if let anchor = anchors.first(where: { lower.contains($0) }), let range = lower.range(of: anchor) {
            // `lowercased()` keeps these ASCII words at the same offsets.
            let start = lower.distance(from: lower.startIndex, to: range.lowerBound), length = lower.distance(from: range.lowerBound, to: range.upperBound)
            if let lowerBound = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex), let upperBound = text.index(lowerBound, offsetBy: length, limitedBy: text.endIndex) { found = lowerBound..<upperBound }
        }
        guard let found else { return clipped(text) }
        let closing: Set<Character> = ["\"", "\n"]
        var start = found.lowerBound, end = found.upperBound
        while start > text.startIndex, !closing.contains(text[text.index(before: start)]) { start = text.index(before: start) }
        while end < text.endIndex, !closing.contains(text[end]) { end = text.index(after: end) }
        return clipped(String(text[start..<end]))
    }
    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= sentenceLimit ? trimmed : String(trimmed.prefix(sentenceLimit - 1)) + "…"
    }
}
