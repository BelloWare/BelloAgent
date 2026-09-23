import Foundation

/// A response body as the Response tab reads it: what the model said, what it
/// reasoned (as far as the provider shared it), the tools it called, why it
/// stopped and what it reported using. Built off the main actor from the
/// retained bytes: a JSON response, a Responses event stream through
/// `CombinedResponse`, or a Messages event stream.
struct ResponseDocument: Sendable {
    var status: String?
    /// Why it stopped, when the provider said: `max_output_tokens`, `tool_use`…
    var finish: String?
    var model: String?
    var items: [RequestDocument.Item]
    var usage: [RequestDocument.Entry]
    /// Reconstructed without a terminal response object.
    var partial: Bool
    var notice: String?
    var outputTokens: Double?
    var reasoningTokens: Double?
    let full: ResponseDocumentStorage

    static func parse(_ data: Data) throws -> ResponseDocument? {
        try Task.checkCancellation()
        guard !data.isEmpty else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] {
            return build(response: object)
        }
        guard let stream = try CapturedEventStream.parse(data) else { return nil }
        if stream.frames.contains(where: \.mightBeResponseEvent) {
            guard let combined = try CombinedResponse.parse(stream), let value = combined.json.value as? [String: Any] else { return nil }
            return build(response: value, partial: combined.isPartial, notice: combined.isPartial ? combined.notice : nil)
        }
        return try messages(stream)
    }

    /// A Responses object or a Messages message.
    static func build(response value: Any, partial: Bool = false, notice: String? = nil) -> ResponseDocument? {
        guard let object = value as? [String: Any] else { return nil }
        if object["output"] == nil, let content = object["content"] as? [Any] {
            return message(object, content: content, partial: partial, notice: notice)
        }
        var calls: [String: String] = [:]
        if object["output"] == nil, let error = object["error"] {
            // A gateway or provider error in place of a response.
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String
            let raw: [String: Any] = ["type": "error", "error": error]
            return ResponseDocument(status: "failed", finish: message.map { String($0.prefix(240)) }, model: object["model"] as? String,
                                    items: [item(0, raw, api: .responses, calls: &calls)], usage: [], partial: false, notice: nil,
                                    outputTokens: nil, reasoningTokens: nil, full: ResponseDocumentStorage(items: [raw], api: .responses))
        }
        guard object["output"] != nil || object["status"] != nil else { return nil }
        let output = object["output"] as? [Any] ?? []
        let items = output.enumerated().map { index, raw in item(index, raw, api: .responses, calls: &calls) }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = RequestDocument.number(usage["input_tokens"])
        let cached = RequestDocument.number((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        let outputTokens = RequestDocument.number(usage["output_tokens"])
        let reasoning = RequestDocument.number((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        let total = RequestDocument.number(usage["total_tokens"])
        var entries: [RequestDocument.Entry] = []
        func add(_ name: String, _ value: Double?) {
            if let value { entries.append(RequestDocument.Entry(id: entries.count, name: name, value: TranscriptActivity.grouped(value))) }
        }
        add("Input", input); add("Cached input", cached); add("Output", outputTokens); add("Reasoning", reasoning); add("Total", total)
        let status = object["status"] as? String
        let finish = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
            ?? (status == "failed" ? ((object["error"] as? [String: Any])?["code"] as? String ?? (object["error"] as? [String: Any])?["message"] as? String) : nil)
        return ResponseDocument(status: status, finish: finish, model: object["model"] as? String, items: items, usage: entries,
                                partial: partial, notice: notice, outputTokens: outputTokens, reasoningTokens: reasoning,
                                full: ResponseDocumentStorage(items: output, api: .responses))
    }

    private static func message(_ object: [String: Any], content: [Any], partial: Bool, notice: String?) -> ResponseDocument {
        let blocks: [Any] = content.map { ["role": "assistant", "block": $0] }
        var calls: [String: String] = [:]
        let items = blocks.enumerated().map { index, raw in item(index, raw, api: .messages, calls: &calls) }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let base = RequestDocument.number(usage["input_tokens"])
        let read = RequestDocument.number(usage["cache_read_input_tokens"]), write = RequestDocument.number(usage["cache_creation_input_tokens"])
        let input = base.map { $0 + (read ?? 0) + (write ?? 0) }
        let output = RequestDocument.number(usage["output_tokens"])
        var entries: [RequestDocument.Entry] = []
        func add(_ name: String, _ value: Double?) {
            if let value { entries.append(RequestDocument.Entry(id: entries.count, name: name, value: TranscriptActivity.grouped(value))) }
        }
        add("Input", input); add("Cached input", read); add("Cache write", write); add("Output", output)
        let stop = object["stop_reason"] as? String
        return ResponseDocument(status: partial ? "in_progress" : "completed", finish: stop, model: object["model"] as? String, items: items,
                                usage: entries, partial: partial, notice: notice ?? (partial ? "The capture ends before the message stopped; this view shows what arrived." : nil),
                                outputTokens: output, reasoningTokens: nil, full: ResponseDocumentStorage(items: blocks, api: .messages))
    }

    /// Rebuilds a Messages response from its events: each content block from
    /// its start and deltas, the stop reason and the final output count.
    private static func messages(_ stream: CapturedEventStream) throws -> ResponseDocument? {
        var message: [String: Any] = [:], started: [Int: [String: Any]] = [:]
        var texts: [Int: String] = [:], arguments: [Int: String] = [:], thinking: [Int: String] = [:]
        var stop: String?, output: Double?, sawStart = false, sawStop = false
        for frame in stream.frames {
            try Task.checkCancellation()
            guard let event = frame.content.json as? [String: Any], let type = event["type"] as? String ?? frame.event else { continue }
            let index = RequestDocument.number(event["index"]).map { Int($0) }
            switch type {
            case "message_start": message = event["message"] as? [String: Any] ?? [:]; sawStart = true
            case "content_block_start":
                if let index, let block = event["content_block"] as? [String: Any] { started[index] = block }
            case "content_block_delta":
                guard let index, let delta = event["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta": texts[index, default: ""] += delta["text"] as? String ?? ""
                case "input_json_delta": arguments[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta": thinking[index, default: ""] += delta["thinking"] as? String ?? ""
                default: break
                }
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stop = reason }
                if let count = RequestDocument.number((event["usage"] as? [String: Any])?["output_tokens"]) { output = count }
            case "message_stop": sawStop = true
            default: break
            }
        }
        guard sawStart || !started.isEmpty else { return nil }
        var content: [Any] = []
        for index in started.keys.sorted() {
            var block = started[index] ?? [:]
            switch block["type"] as? String {
            case "text": block["text"] = (block["text"] as? String ?? "") + (texts[index] ?? "")
            case "thinking": block["thinking"] = (block["thinking"] as? String ?? "") + (thinking[index] ?? "")
            case "tool_use":
                if let text = arguments[index] {
                    block["input"] = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
                }
            default: break
            }
            content.append(block)
        }
        if let stop { message["stop_reason"] = stop }
        var usage = message["usage"] as? [String: Any] ?? [:]
        if let output { usage["output_tokens"] = output }
        message["usage"] = usage
        return Self.message(message, content: content, partial: !sawStop, notice: nil)
    }

    private static func item(_ index: Int, _ raw: Any, api: RequestDocument.API, calls: inout [String: String]) -> RequestDocument.Item {
        let described = RequestDocument.describe(raw, api: api, calls: &calls, response: true)
        let canonical = RequestDocument.canonicalData(raw), text = described.text as NSString
        let preview = RequestDocument.prefix(text, limit: RequestDocument.previewLimit)
        return RequestDocument.Item(id: index, kind: described.kind, title: described.title, detail: described.detail, size: canonical.count,
                                    characters: text.length, preview: preview, lines: RequestDocument.wrap(preview),
                                    digest: RequestDocument.digest(canonical), callID: described.callID, monospaced: described.monospaced)
    }

    /// The whole readable text of one item. Call on the worker.
    func fullText(item index: Int) throws -> String {
        try Task.checkCancellation()
        guard full.items.indices.contains(index) else { return "" }
        var calls: [String: String] = [:]
        return RequestDocument.describe(full.items[index], api: full.api, calls: &calls, response: true).text
    }

    /// `Completed · 1,104 output tokens (640 reasoning)`.
    var summary: String {
        var parts: [String] = []
        switch status {
        case "completed"?: parts.append("Completed")
        case "incomplete"?: parts.append("Incomplete")
        case "failed"?: parts.append("Failed")
        case "in_progress"?, "queued"?: parts.append("In progress")
        case .some(let other): parts.append(other.prefix(1).uppercased() + other.dropFirst())
        case nil: parts.append(partial ? "Partial" : "Response")
        }
        if let finish { parts.append(finish) }
        if partial, status != nil, status != "in_progress" { parts.append("partial") }
        if let outputTokens {
            parts.append(TranscriptActivity.grouped(outputTokens) + " output tokens" + (reasoningTokens.map { " (" + TranscriptActivity.grouped($0) + " reasoning)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// The response's parsed items, for "Show all". Immutable once built.
final class ResponseDocumentStorage: @unchecked Sendable {
    let items: [Any]
    let api: RequestDocument.API
    init(items: [Any], api: RequestDocument.API) { self.items = items; self.api = api }
}
