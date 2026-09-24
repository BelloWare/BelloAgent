import Foundation
import CryptoKit

/// A request body as the Conversation tab reads it: its system prompt, tools
/// and settings as three quiet sections, then every conversation item in the
/// order the model received it. Built once, off the main actor, from the
/// retained bytes; every string a row shows is prepared here.
struct RequestDocument: Sendable {
    enum API: String, Sendable { case responses, messages, unknown }

    /// One line of a section: a tool, or a setting.
    struct Entry: Sendable, Equatable, Identifiable {
        var id: Int
        var name: String
        var value: String
        var detail: String? = nil
    }

    struct Section: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable { case system, tools, settings }
        var id: Kind
        var title: String
        /// `8.2K chars`, `12 tools · 18.4 KB`, `gpt-5.4 · reasoning high`.
        var summary: String
        var size: Int
        /// The system prompt's opening, wrapped for display.
        var lines: [String] = []
        var entries: [Entry] = []
        var digest: String
    }

    struct Item: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable { case user, assistant, system, developer, toolCall, toolResult, reasoning, image, other }
        /// The item's position in the conversation.
        var id: Int
        var kind: Kind
        var title: String
        /// `path: README.md`, `3.9K chars`, `encrypted`.
        var detail: String?
        /// Bytes of the item as JSON.
        var size: Int
        /// Characters of its readable text.
        var characters: Int
        /// At most `previewLimit` characters of that text.
        var preview: String
        /// The preview wrapped for display, at most `lineLimit` lines.
        var lines: [String]
        var digest: String
        var callID: String? = nil
        var monospaced = false
        var truncated: Bool { characters > (preview as NSString).length }
    }

    static let previewLimit = 2_000
    static let lineLimit = 24
    static let wrapColumns = 100
    static let notJSON = "This body is not a JSON request. Raw shows its bytes."

    var api: API
    var model: String?
    var bytes: Int
    var sections: [Section]
    var items: [Item]
    /// Why the body could not be read as a conversation, when it could not.
    var notice: String?
    var totalCharacters: Int
    var digests: RequestDigests
    /// The retained bytes, for "Show all" — rendered on the worker, never here.
    let full: RequestDocumentStorage
    /// A compaction's summary request: what it summarizes, and the
    /// instruction its prompt ends with. Nil for any other request.
    var summary: SummaryRequestInfo? = nil

    func section(_ kind: Section.Kind) -> Section? { sections.first { $0.id == kind } }

    /// Bodies up to this size keep their parsed values with the document.
    static let keptParseLimit = 2_097_152

    static func parse(_ data: Data) throws -> RequestDocument {
        try Task.checkCancellation()
        let storage = RequestDocumentStorage(data: data)
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return RequestDocument(api: .unknown, model: nil, bytes: data.count, sections: [], items: [], notice: notJSON,
                                   totalCharacters: 0, digests: RequestDigests(), full: storage)
        }
        // A small body keeps its parsed values for "Show all". A large one
        // does not: its tree of values is several times its bytes, it is
        // freed here, on the worker, and "Show all" parses it again.
        if data.count <= Self.keptParseLimit { storage.adopt(root) }
        try Task.checkCancellation()
        let api: API = root["input"] != nil ? .responses : root["messages"] != nil ? .messages : .unknown
        var sections: [Section] = []
        if let system = systemSection(root, api: api) { sections.append(system) }
        if let tools = toolsSection(root) { sections.append(tools) }
        if let settings = settingsSection(root) { sections.append(settings) }
        try Task.checkCancellation()
        var items: [Item] = [], calls: [String: String] = [:]
        // A summary request's prompt is its last user message, whole.
        let summarizes = SummaryRequestInfo.isSummary(system: systemText(root, api: api))
        var prompt: String?
        for (index, raw) in storage.itemValues(root: root, api: api).enumerated() {
            if index % 16 == 0 { try Task.checkCancellation() }
            let described = describe(raw, api: api, calls: &calls, response: false)
            if summarizes, described.kind == .user { prompt = described.text }
            let canonical = canonicalData(raw)
            let text = described.text as NSString
            let preview = prefix(text, limit: previewLimit)
            items.append(Item(id: index, kind: described.kind, title: described.title, detail: described.detail,
                              size: canonical.count, characters: text.length, preview: preview,
                              lines: wrap(preview), digest: digest(canonical), callID: described.callID, monospaced: described.monospaced))
        }
        try Task.checkCancellation()
        let digests = RequestDigests(items: items.map(\.digest), characters: items.map(\.characters),
                                     instructions: sections.first { $0.id == .system }?.digest,
                                     tools: sections.first { $0.id == .tools }?.digest)
        return RequestDocument(api: api, model: root["model"] as? String, bytes: data.count, sections: sections, items: items,
                               notice: nil, totalCharacters: items.reduce(0) { $0 + $1.characters }, digests: digests, full: storage,
                               summary: prompt.flatMap(SummaryRequestInfo.read(prompt:)))
    }

    /// The digests alone, for the request a delta compares with: no preview,
    /// no wrapping, nothing kept. Nil for a body that is not a JSON request.
    static func digests(_ data: Data) throws -> RequestDigests? {
        try Task.checkCancellation()
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else { return nil }
        let api: API = root["input"] != nil ? .responses : root["messages"] != nil ? .messages : .unknown
        var items: [String] = []
        for (index, raw) in RequestDocumentStorage(data: data).itemValues(root: root, api: api).enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            items.append(digest(canonicalData(raw)))
        }
        let system = systemValue(root, api: api)
        let tools = (root["tools"] as? [Any]).flatMap { $0.isEmpty ? nil : $0 }
        return RequestDigests(items: items, characters: [], instructions: system.map { digest(canonicalData($0)) },
                              tools: tools.map { digest(canonicalData($0)) })
    }

    /// The whole readable text of one item. Call on the worker.
    func fullText(item index: Int) throws -> String {
        guard items.indices.contains(index), let root = try full.root() else { return "" }
        let values = full.itemValues(root: root, api: api)
        guard values.indices.contains(index) else { return "" }
        var calls: [String: String] = [:]
        return Self.describe(values[index], api: api, calls: &calls, response: false).text
    }

    /// The whole of one section. Call on the worker.
    func fullText(section: Section.Kind) throws -> String {
        guard let root = try full.root() else { return "" }
        switch section {
        case .system: return Self.systemText(root, api: api) ?? ""
        case .tools: return Self.pretty(root["tools"] ?? [])
        case .settings: return Self.pretty(Self.settingsValues(root))
        }
    }

    // MARK: Sections

    private static let conversationKeys: Set<String> = ["input", "messages", "instructions", "system", "tools"]

    /// Pi's system prompt as the first input item: a system message, or a
    /// developer message to a reasoning model, whose content is the prompt.
    /// A request that carries `instructions` has none.
    static func leadingSystemPrompt(_ root: [String: Any]) -> String? {
        guard root["instructions"] == nil, let first = (root["input"] as? [Any])?.first as? [String: Any],
              let role = first["role"] as? String, role == "system" || role == "developer", first["type"] == nil,
              let content = first["content"] as? String else { return nil }
        return content
    }

    /// The system prompt, wherever the request carries it.
    static func systemValue(_ root: [String: Any], api: API) -> Any? {
        api == .messages ? root["system"] : root["instructions"] ?? root["system"] ?? leadingSystemPrompt(root)
    }

    private static func systemText(_ root: [String: Any], api: API) -> String? {
        guard let value = systemValue(root, api: api) else { return nil }
        if let text = value as? String { return text }
        if let blocks = value as? [Any] {
            let texts = blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n\n") }
        }
        return pretty(value)
    }

    private static func systemSection(_ root: [String: Any], api: API) -> Section? {
        guard let text = systemText(root, api: api), let raw = systemValue(root, api: api) else { return nil }
        let canonical = canonicalData(raw), length = (text as NSString).length
        return Section(id: .system, title: "System prompt", summary: charactersLabel(length), size: canonical.count,
                       lines: wrap(prefix(text as NSString, limit: previewLimit)), digest: digest(canonical))
    }

    private static func toolsSection(_ root: [String: Any]) -> Section? {
        guard let tools = root["tools"] as? [Any], !tools.isEmpty else { return nil }
        let canonical = canonicalData(tools)
        let entries = tools.enumerated().map { offset, value -> Entry in
            let tool = value as? [String: Any] ?? [:]
            let function = tool["function"] as? [String: Any]
            let name = tool["name"] as? String ?? function?["name"] as? String ?? tool["type"] as? String ?? "tool"
            let description = (tool["description"] as? String ?? function?["description"] as? String ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let schema = tool["parameters"] as? [String: Any] ?? tool["input_schema"] as? [String: Any] ?? function?["parameters"] as? [String: Any]
            let count = (schema?["properties"] as? [String: Any])?.count
            return Entry(id: offset, name: name, value: description, detail: count.map { "\($0) parameter" + ($0 == 1 ? "" : "s") })
        }
        return Section(id: .tools, title: "Tools", summary: "\(tools.count) tool" + (tools.count == 1 ? "" : "s"),
                       size: canonical.count, entries: entries, digest: digest(canonical))
    }

    private static func settingsValues(_ root: [String: Any]) -> [String: Any] { root.filter { !conversationKeys.contains($0.key) } }

    private static func settingsSection(_ root: [String: Any]) -> Section? {
        let values = settingsValues(root)
        guard !values.isEmpty else { return nil }
        let canonical = canonicalData(values)
        let entries = values.keys.sorted().enumerated().map { offset, key -> Entry in
            let value = values[key] as Any
            let text = value as? String ?? compact(value)
            return Entry(id: offset, name: key, value: String(text.prefix(240)))
        }
        var parts: [String] = []
        if let model = root["model"] as? String { parts.append(model) }
        if let effort = (root["reasoning"] as? [String: Any])?["effort"] as? String { parts.append("reasoning " + effort) }
        else if let thinking = root["thinking"] as? [String: Any], let type = thinking["type"] as? String, type != "disabled" {
            parts.append(number(thinking["budget_tokens"]).map { "thinking " + TranscriptActivity.grouped($0) } ?? "thinking " + type)
        }
        if let cap = number(root["max_output_tokens"] ?? root["max_tokens"]) { parts.append("max output " + TranscriptActivity.grouped(cap)) }
        return Section(id: .settings, title: "Settings", summary: parts.isEmpty ? "\(values.count) settings" : parts.joined(separator: " · "),
                       size: canonical.count, entries: entries, digest: digest(canonical))
    }

    // MARK: Items

    struct Description {
        var kind: Item.Kind
        var title: String
        var detail: String?
        var text: String
        var callID: String?
        var monospaced: Bool
    }

    /// What one conversation item says, and how it is named. `raw` is a
    /// Responses input or output item, a Messages block as `{role, block}`, or
    /// a plain string (a Responses `input` given as text).
    static func describe(_ raw: Any, api: API, calls: inout [String: String], response: Bool) -> Description {
        if let text = raw as? String { return Description(kind: .user, title: "User", detail: nil, text: text, callID: nil, monospaced: false) }
        guard let value = raw as? [String: Any] else { return Description(kind: .other, title: "Item", detail: nil, text: pretty(raw), callID: nil, monospaced: true) }
        if api == .messages, let role = value["role"] as? String, let block = value["block"] as? [String: Any] {
            return describeBlock(block, role: role, calls: &calls, response: response)
        }
        let type = value["type"] as? String
        switch type {
        case nil, "message":
            guard let role = value["role"] as? String else { break }
            return describeMessage(role: role, content: value["content"])
        case "function_call":
            let name = value["name"] as? String ?? "tool"
            let call = value["call_id"] as? String ?? value["id"] as? String
            if let call { calls[call] = name }
            let arguments = value["arguments"]
            let parsed = (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) } ?? arguments
            let text = parsed.map { $0 is String ? $0 as! String : pretty($0) } ?? ""
            return Description(kind: .toolCall, title: name, detail: argumentSummary(parsed), text: text, callID: call, monospaced: true)
        case "function_call_output":
            let call = value["call_id"] as? String
            let text = outputText(value["output"])
            return Description(kind: .toolResult, title: call.flatMap { calls[$0] }.map { "Result of " + $0 } ?? "Tool result",
                               detail: text.isEmpty ? "empty" : nil, text: text, callID: call, monospaced: true)
        case "reasoning":
            let summary = (value["summary"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }
            let content = (value["content"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }
            let encrypted = (value["encrypted_content"] as? String).map { ($0 as NSString).length }
            var detail: [String] = []
            if !summary.isEmpty { detail.append("summary") }
            if let encrypted { detail.append("encrypted " + MetricFormat.tokens(Double(encrypted))) }
            let text = (summary.isEmpty ? content : summary).joined(separator: "\n\n")
            return Description(kind: .reasoning, title: response ? "Reasoning summary" : "Reasoning",
                               detail: detail.isEmpty ? nil : detail.joined(separator: " · "), text: text, callID: nil, monospaced: false)
        default: break
        }
        return Description(kind: .other, title: type ?? "Item", detail: nil, text: pretty(value), callID: nil, monospaced: true)
    }

    private static func describeMessage(role: String, content: Any?) -> Description {
        var texts: [String] = [], images = 0, files = 0
        if let text = content as? String { texts.append(text) }
        for part in content as? [Any] ?? [] {
            guard let part = part as? [String: Any] else { continue }
            switch part["type"] as? String {
            case "input_text", "output_text", "text": if let text = part["text"] as? String { texts.append(text) }
            case "refusal": if let text = part["refusal"] as? String { texts.append("Refusal: " + text) }
            case "input_image", "image": images += 1
            case "input_file", "file", "document": files += 1
            default: texts.append(pretty(part))
            }
        }
        var detail: [String] = []
        if images > 0 { detail.append("\(images) image" + (images == 1 ? "" : "s")) }
        if files > 0 { detail.append("\(files) file" + (files == 1 ? "" : "s")) }
        let kind: Item.Kind = role == "user" ? .user : role == "assistant" ? .assistant : role == "developer" ? .developer : role == "system" ? .system : .other
        return Description(kind: kind, title: role.prefix(1).uppercased() + role.dropFirst(), detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                           text: texts.joined(separator: "\n\n"), callID: nil, monospaced: false)
    }

    private static func describeBlock(_ block: [String: Any], role: String, calls: inout [String: String], response: Bool) -> Description {
        switch block["type"] as? String {
        case "text":
            return describeMessage(role: role, content: block["text"] as? String ?? "")
        case "image":
            let media = ((block["source"] as? [String: Any])?["media_type"] as? String)
            return Description(kind: .image, title: "Image", detail: media, text: "", callID: nil, monospaced: false)
        case "tool_use":
            let name = block["name"] as? String ?? "tool", id = block["id"] as? String
            if let id { calls[id] = name }
            let input = block["input"]
            return Description(kind: .toolCall, title: name, detail: argumentSummary(input), text: input.map(pretty) ?? "", callID: id, monospaced: true)
        case "tool_result":
            let id = block["tool_use_id"] as? String, text = outputText(block["content"])
            let error = block["is_error"] as? Bool == true
            return Description(kind: .toolResult, title: id.flatMap { calls[$0] }.map { "Result of " + $0 } ?? "Tool result",
                               detail: error ? "error" : text.isEmpty ? "empty" : nil, text: text, callID: id, monospaced: true)
        case "thinking":
            return Description(kind: .reasoning, title: response ? "Reasoning summary" : "Reasoning", detail: nil, text: block["thinking"] as? String ?? "", callID: nil, monospaced: false)
        case "redacted_thinking":
            return Description(kind: .reasoning, title: "Reasoning", detail: "redacted", text: "", callID: nil, monospaced: false)
        case let type:
            return Description(kind: .other, title: type ?? "Block", detail: nil, text: pretty(block), callID: nil, monospaced: true)
        }
    }

    /// `path: README.md` — the argument a reader recognizes a call by.
    static func argumentSummary(_ value: Any?) -> String? {
        guard let object = value as? [String: Any], !object.isEmpty else {
            if let text = value as? String, !text.isEmpty { return oneLine(text) }
            return nil
        }
        let preferred = ["path", "file_path", "filePath", "command", "cmd", "pattern", "query", "url", "name", "file"]
        let key = preferred.first { object[$0] != nil } ?? object.keys.sorted().first!
        let value = object[key] as Any
        return key + ": " + oneLine(value as? String ?? compact(value))
    }

    private static func oneLine(_ text: String, limit: Int = 80) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    private static func outputText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let parts = value as? [Any] {
            let texts = parts.compactMap { part -> String? in
                guard let part = part as? [String: Any] else { return nil }
                return part["text"] as? String ?? part["output"] as? String
            }
            if texts.count == parts.count { return texts.joined(separator: "\n\n") }
        }
        return pretty(value)
    }

    // MARK: Text

    static func charactersLabel(_ count: Int) -> String {
        (count < 1_000 ? "\(count)" : MetricFormat.tokens(Double(count))) + " chars"
    }
    static func byteLabel(_ count: Int) -> String {
        if count < 1_024 { return "\(count) B" }
        let kilobytes = Double(count) / 1_024
        if kilobytes < 1_024 { return String(format: kilobytes < 100 ? "%.1f KB" : "%.0f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1_024)
    }
    /// At most `limit` UTF-16 units, never ending inside a character.
    static func prefix(_ text: NSString, limit: Int) -> String {
        guard text.length > limit else { return text as String }
        let cut = text.rangeOfComposedCharacterSequence(at: limit).location
        return text.substring(to: cut)
    }

    /// `text` in lines of at most `columns` characters, broken between words
    /// where it can be, keeping the text's own line breaks; at most `limit` lines.
    static func wrap(_ text: String, columns: Int = wrapColumns, limit: Int = lineLimit) -> [String] {
        guard !text.isEmpty, columns > 0, limit > 0 else { return [] }
        var lines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        for paragraph in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            guard lines.count < limit else { break }
            var remaining = paragraph
            if remaining.isEmpty { lines.append(""); continue }
            while !remaining.isEmpty, lines.count < limit {
                if remaining.count <= columns { lines.append(String(remaining)); break }
                let window = remaining.prefix(columns + 1)
                var breakAt: Substring.Index?
                var index = window.endIndex
                while index > window.startIndex {
                    index = window.index(before: index)
                    if window[index] == " ", window[window.startIndex..<index].contains(where: { $0 != " " }) { breakAt = index; break }
                }
                if let breakAt {
                    lines.append(String(remaining[remaining.startIndex..<breakAt]))
                    remaining = remaining[remaining.index(after: breakAt)...]
                } else {
                    let cut = remaining.index(remaining.startIndex, offsetBy: columns)
                    lines.append(String(remaining[remaining.startIndex..<cut]))
                    remaining = remaining[cut...]
                }
            }
        }
        return lines
    }

    // MARK: JSON

    static func canonicalData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
    static func compact(_ value: Any) -> String { String(decoding: canonicalData(value), as: UTF8.self) }
    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

/// A request's input by digest, for comparing it with the request before it.
struct RequestDigests: Sendable, Equatable {
    var items: [String] = []
    var characters: [Int] = []
    var instructions: String? = nil
    var tools: String? = nil
}

/// The retained bytes behind a document, and the values parsed from them once
/// "Show all" asks. Foundation containers from JSONSerialization are never
/// mutated after parsing; the lock guards only the memo.
final class RequestDocumentStorage: @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var parsed: [String: Any]?
    init(data: Data) { self.data = data }
    /// Parse keeps what it already has, so a document just built needs no second parse.
    func adopt(_ root: [String: Any]) { lock.withLock { parsed = root } }
    /// Drops the parsed values; "Show all" parses the bytes again when asked.
    func release() { lock.withLock { parsed = nil } }
    func root() throws -> [String: Any]? {
        if let parsed = lock.withLock({ parsed }) { return parsed }
        try Task.checkCancellation()
        guard let value = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else { return nil }
        lock.withLock { parsed = value }
        return value
    }
    /// The conversation items as `describe` reads them.
    func itemValues(root: [String: Any], api: RequestDocument.API) -> [Any] {
        switch api {
        case .responses:
            if let text = root["input"] as? String { return [text] }
            // Pi's system prompt leads the input; it is the System section, not an item.
            let values = root["input"] as? [Any] ?? []
            return RequestDocument.leadingSystemPrompt(root) != nil ? Array(values.dropFirst()) : values
        case .messages:
            var values: [Any] = []
            for message in root["messages"] as? [Any] ?? [] {
                guard let message = message as? [String: Any] else { values.append(message); continue }
                let role = message["role"] as? String ?? "user"
                if let text = message["content"] as? String {
                    values.append(["role": role, "block": ["type": "text", "text": text]])
                } else {
                    for block in message["content"] as? [Any] ?? [] { values.append(["role": role, "block": block]) }
                }
            }
            return values
        case .unknown: return []
        }
    }
}
