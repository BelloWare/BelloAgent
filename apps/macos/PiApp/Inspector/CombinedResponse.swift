import Foundation
import CoreFoundation

/// A convenience view derived from retained Responses SSE events. The original
/// event stream is still the capture; this value is never exported as raw HTTP.
struct CombinedResponse: Sendable {
    let json: CapturedJSON
    let notice: String
    let isPartial: Bool

    static func parse(_ stream: CapturedEventStream) throws -> Self? {
        var builder = ResponseCombination()
        for frame in stream.frames {
            try Task.checkCancellation()
            builder.consume(frame)
        }
        return try builder.result()
    }
}

private struct ResponseCombination {
    // Sparse provider indices must not turn a small capture into a huge array.
    private static let maximumIndex = 16_383
    private static let maximumSlots = 65_536
    private static let maximumTextBytes = 67_108_864
    private var root: [String: Any] = [:]
    private var items: [Int: ResponseCombinedItem] = [:]
    private var responseID: String?
    private var itemIndices: [String: Int] = [:]
    private var terminal: [String: Any]?
    private var terminalType: String?
    private var recognized = false
    private var hasIssue = false
    private var unsupported = false
    private var unfinished = false
    private var slotCount = 0
    private var textBytes = 0
    private var lastSequence: Int?
    private var lastSequencedEvent: [String: Any]?

    mutating func consume(_ frame: CapturedEventFrame) {
        let content = frame.content
        guard let data = content.data, !data.isEmpty else { return }
        if !frame.terminated { unfinished = true }
        guard data != "[DONE]" else {
            return
        }
        guard let event = content.json as? [String: Any] else { hasIssue = true; return }
        let bodyType = event["type"] as? String
        let headerType = frame.event.flatMap { $0 == "message" || $0.isEmpty ? nil : $0 }
        guard let type = bodyType ?? headerType else { hasIssue = true; return }
        if let bodyType, let headerType, bodyType != headerType { hasIssue = true; return }

        let lifecycle = ["response.created", "response.queued", "response.in_progress"]
        let terminalTypes = ["response.completed", "response.incomplete", "response.failed"]
        let supported = lifecycle.contains(type) || terminalTypes.contains(type) || Self.itemEvents.contains(type)
        guard supported else {
            if type == "error" { hasIssue = true }
            else { unsupported = true }
            return
        }
        recognized = true
        if let id = event["response_id"] as? String, !acceptResponseID(id) { return }
        if let number = event["sequence_number"] {
            guard let sequence = Self.index(number, maximum: Int.max - 1) else { hasIssue = true; return }
            if let lastSequence, sequence <= lastSequence {
                if sequence == lastSequence, let previous = lastSequencedEvent,
                   NSDictionary(dictionary: previous).isEqual(to: event) { return }
                hasIssue = true
                // A canonical terminal remains useful even if event delivery
                // was out of order. Never append a replayed/out-of-order delta.
                if !terminalTypes.contains(type) { return }
            }
            lastSequence = sequence; lastSequencedEvent = event
        }

        if lifecycle.contains(type) || terminalTypes.contains(type) {
            guard let response = event["response"] as? [String: Any] else { hasIssue = true; return }
            if let id = response["id"] as? String, !acceptResponseID(id) { return }
            if terminalTypes.contains(type) {
                if let terminal {
                    if !NSDictionary(dictionary: terminal).isEqual(to: response) || terminalType != type { hasIssue = true }
                    return
                }
                terminal = response; terminalType = type
                let expected = String(type.dropFirst("response.".count))
                if response["status"] as? String != expected || !(response["output"] is [Any]) { hasIssue = true }
            } else {
                guard terminal == nil else { hasIssue = true; return }
                for (key, value) in response where key != "output" { root[key] = value }
                if let output = response["output"] as? [Any] {
                    root["output"] = output
                    for (index, value) in output.enumerated() {
                        guard let value = value as? [String: Any] else { hasIssue = true; continue }
                        putItem(value, index: index, done: false, snapshot: true)
                    }
                } else if response["output"] != nil { hasIssue = true }
            }
            return
        }

        guard terminal == nil else { hasIssue = true; return }
        if type == "response.output_item.added" || type == "response.output_item.done" {
            guard let index = validIndex(event["output_index"]), let item = event["item"] as? [String: Any] else { hasIssue = true; return }
            putItem(item, index: index, done: type.hasSuffix(".done"), snapshot: false)
            return
        }
        guard let index = resolveItem(event), var item = items.removeValue(forKey: index) else { return }
        defer { items[index] = item }
        guard !item.done else { hasIssue = true; return }

        if type.hasPrefix("response.function_call_arguments.") {
            guard ensureType(&item.value, type: "function_call") else { return }
            let done = type.hasSuffix(".done"), key = done ? "arguments" : "delta"
            guard let text = event[key] as? String, reserveText(text) else { hasIssue = true; return }
            if done, let name = event["name"] as? String {
                if let previous = item.value["name"] as? String, previous != name { hasIssue = true; return }
                item.value["name"] = name
            }
            if item.arguments == nil { item.arguments = ResponseCombinedText(initial: item.value["arguments"] as? String ?? "") }
            if item.arguments?.receive(text, done: done) == false { hasIssue = true }
            return
        }

        let summary = type.hasPrefix("response.reasoning_summary_")
        let collection = summary ? "summary" : "content"
        let indexKey = summary ? "summary_index" : "content_index"
        guard let partIndex = validIndex(event[indexKey]) else { hasIssue = true; return }
        guard reservePart(&item, collection: collection, index: partIndex) else { return }
        // `reservePart` above has just made this slot exist.
        guard var part = item.parts[collection]?.removeValue(forKey: partIndex) else { hasIssue = true; return }
        defer { item.parts[collection]?[partIndex] = part }

        if type == "response.content_part.added" || type == "response.content_part.done"
            || type == "response.reasoning_summary_part.added" || type == "response.reasoning_summary_part.done" {
            guard let value = event["part"] as? [String: Any] else { hasIssue = true; return }
            if let previous = part.value["type"] as? String, let incoming = value["type"] as? String, previous != incoming { hasIssue = true; return }
            if type.hasSuffix(".done") {
                if part.done, !NSDictionary(dictionary: part.value).isEqual(to: value) { hasIssue = true; return }
                part = ResponseCombinedPart(value: value, done: true)
            } else if part.hasContent {
                // Late/replayed "added" cannot reset already accumulated data.
                hasIssue = true
            } else { part = ResponseCombinedPart(value: value) }
            return
        }
        guard !part.done else { hasIssue = true; return }

        if type == "response.output_text.annotation.added" {
            guard ensureType(&part.value, type: "output_text") else { return }
            guard let annotation = event["annotation"], let annotationIndex = validIndex(event["annotation_index"]) else { hasIssue = true; return }
            var annotations = part.value["annotations"] as? [Any] ?? []
            let needed = max(0, annotationIndex + 1 - annotations.count)
            guard reserveSlots(needed) else { return }
            if needed > 0 { annotations += Array(repeating: NSNull(), count: needed) }
            if !(annotations[annotationIndex] is NSNull) { hasIssue = true; return }
            annotations[annotationIndex] = annotation; part.value["annotations"] = annotations
            return
        }

        let refusal = type.hasPrefix("response.refusal.")
        let reasoning = type.hasPrefix("response.reasoning_text.")
        let partType = refusal ? "refusal" : summary ? "summary_text" : reasoning ? "reasoning_text" : "output_text"
        guard ensureType(&part.value, type: partType) else { return }
        let textKey = refusal ? "refusal" : "text"
        let done = type.hasSuffix(".done")
        guard let text = event[done ? textKey : "delta"] as? String, reserveText(text) else { hasIssue = true; return }
        if part.text == nil { part.text = ResponseCombinedText(initial: part.value[textKey] as? String ?? "") }
        if !part.text!.receive(text, done: done) { hasIssue = true }
        part.textKey = textKey
        if let logprobs = event["logprobs"] as? [Any] {
            if done { part.value["logprobs"] = logprobs }
            else { part.value["logprobs"] = (part.value["logprobs"] as? [Any] ?? []) + logprobs }
        }
    }

    private static let itemEvents: Set<String> = [
        "response.output_item.added", "response.output_item.done",
        "response.content_part.added", "response.content_part.done",
        "response.output_text.delta", "response.output_text.done", "response.output_text.annotation.added",
        "response.refusal.delta", "response.refusal.done",
        "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
        "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
        "response.reasoning_text.delta", "response.reasoning_text.done",
        "response.function_call_arguments.delta", "response.function_call_arguments.done"
    ]

    private mutating func acceptResponseID(_ id: String) -> Bool {
        guard !id.isEmpty else { hasIssue = true; return false }
        if let responseID, responseID != id { hasIssue = true; return false }
        responseID = id
        if root["id"] == nil { root["id"] = id }
        return true
    }

    private static func index(_ value: Any?, maximum: Int = maximumIndex) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number >= 0, number.rounded() == number, number < Double(Int.max), number <= Double(maximum) else { return nil }
        return Int(number)
    }

    private func validIndex(_ value: Any?) -> Int? { Self.index(value) }

    private mutating func reserveSlots(_ count: Int) -> Bool {
        guard count >= 0, count <= Self.maximumSlots - slotCount else { hasIssue = true; return false }
        slotCount += count; return true
    }

    private mutating func reserveText(_ value: String) -> Bool {
        let count = value.utf8.count
        guard count <= Self.maximumTextBytes - textBytes else { hasIssue = true; return false }
        textBytes += count; return true
    }

    private mutating func ensureType(_ value: inout [String: Any], type: String) -> Bool {
        if let existing = value["type"] as? String, existing != type { hasIssue = true; return false }
        value["type"] = type; return true
    }

    private mutating func putItem(_ value: [String: Any], index: Int, done: Bool, snapshot: Bool) {
        guard index <= Self.maximumIndex else { hasIssue = true; return }
        if let id = value["id"] as? String {
            if let other = itemIndices[id], other != index { hasIssue = true; return }
            if let oldID = items[index]?.value["id"] as? String, id != oldID { hasIssue = true; return }
            itemIndices[id] = index
        }
        if let existing = items[index] {
            if let before = existing.value["type"] as? String, let after = value["type"] as? String, before != after { hasIssue = true; return }
            if existing.done {
                if !NSDictionary(dictionary: existing.value).isEqual(to: value) { hasIssue = true }
                return
            }
            if !done {
                // Lifecycle snapshots may repeat the same output prefix; they
                // must not rewind later deltas.
                if !snapshot { hasIssue = true }
                return
            }
        } else {
            let previousMaximum = items.keys.max().map { $0 + 1 } ?? 0
            guard reserveSlots(max(0, index + 1 - previousMaximum)) else { return }
        }
        items[index] = ResponseCombinedItem(value: value, done: done)
    }

    private mutating func resolveItem(_ event: [String: Any]) -> Int? {
        let suppliedIndex = event["output_index"]
        let id = event["item_id"] as? String
        let index = suppliedIndex == nil ? id.flatMap { itemIndices[$0] } : validIndex(suppliedIndex)
        guard let index else { hasIssue = true; return nil }
        if let id, let other = itemIndices[id], other != index { hasIssue = true; return nil }
        if let id, let old = items[index]?.value["id"] as? String, id != old { hasIssue = true; return nil }
        if items[index] == nil {
            let previousMaximum = items.keys.max().map { $0 + 1 } ?? 0
            guard reserveSlots(max(0, index + 1 - previousMaximum)) else { return nil }
            items[index] = ResponseCombinedItem(value: id.map { ["id": $0] } ?? [:])
        }
        if let id { itemIndices[id] = index; items[index]?.value["id"] = id }
        return index
    }

    private mutating func reservePart(_ item: inout ResponseCombinedItem, collection: String, index: Int) -> Bool {
        if item.parts[collection] == nil {
            let source = item.value[collection] as? [Any] ?? []
            guard source.count <= Self.maximumIndex + 1 else { hasIssue = true; return false }
            guard reserveSlots(source.count) else { return false }
            var parts: [Int: ResponseCombinedPart] = [:]
            for (index, part) in source.enumerated() {
                guard let part = part as? [String: Any] else { hasIssue = true; continue }
                parts[index] = ResponseCombinedPart(value: part)
            }
            item.parts[collection] = parts
        }
        if item.parts[collection]?[index] == nil {
            let previousMaximum = item.parts[collection]?.keys.max().map { $0 + 1 } ?? 0
            guard reserveSlots(max(0, index + 1 - previousMaximum)) else { return false }
            item.parts[collection]?[index] = ResponseCombinedPart(value: [:])
        }
        return true
    }

    mutating func result() throws -> CombinedResponse? {
        guard recognized else { return nil }
        try Task.checkCancellation()
        let value: [String: Any]
        if let terminal { value = terminal }
        else {
            if let last = items.keys.max() {
                var output: [Any] = Array(repeating: NSNull(), count: last + 1)
                for (index, item) in items {
                    try Task.checkCancellation()
                    output[index] = item.result()
                }
                root["output"] = output
            }
            value = root
        }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Task.checkCancellation()
        let isPartial = terminal == nil || hasIssue || unfinished
        var notice: String
        if let terminalType {
            notice = "Combined JSON uses the \(terminalType) response object."
            if terminalType == "response.incomplete" { notice += " The provider reported an incomplete response." }
            if terminalType == "response.failed" { notice += " The provider reported a failed response." }
        } else {
            notice = "Partial combined JSON reconstructed from retained events; no terminal response object was captured."
        }
        if hasIssue { notice += " Malformed, conflicting or out-of-order events were excluded; this view may be incomplete." }
        if unfinished { notice += " The capture ends within an unfinished event frame." }
        if unsupported { notice += " Additional event types remain available in Events" + (terminal == nil ? " and may contain data absent from this partial view." : "; the terminal response object remains authoritative.") }
        notice += " This is a derived view. Events, UTF-8 and Hex preserve the captured stream."
        return CombinedResponse(json: CapturedJSON(value: value, formatted: String(decoding: bytes, as: UTF8.self), rootLabel: "Combined response"), notice: notice, isPartial: isPartial)
    }
}

private struct ResponseCombinedText {
    private var initial: String
    private var deltas: [String] = []
    private var done = false
    init(initial: String) { self.initial = initial }
    mutating func receive(_ text: String, done: Bool) -> Bool {
        if self.done { return done && initial == text }
        if done { initial = text; deltas.removeAll(); self.done = true }
        else { deltas.append(text) }
        return true
    }
    var value: String { initial + deltas.joined() }
}

private struct ResponseCombinedPart {
    var value: [String: Any]
    var done = false
    var text: ResponseCombinedText?
    var textKey = "text"
    var hasContent: Bool { !value.isEmpty || text != nil || done }
    func result() -> [String: Any] {
        var result = value
        if let text { result[textKey] = text.value }
        return result
    }
}

private struct ResponseCombinedItem {
    var value: [String: Any]
    var done = false
    var parts: [String: [Int: ResponseCombinedPart]] = [:]
    var arguments: ResponseCombinedText?
    func result() -> [String: Any] {
        guard !done else { return value }
        var result = value
        if let arguments { result["arguments"] = arguments.value }
        for (collection, parts) in parts {
            guard let maximum = parts.keys.max() else { continue }
            var values: [Any] = Array(repeating: NSNull(), count: maximum + 1)
            for (index, part) in parts { values[index] = part.result() }
            result[collection] = values
        }
        return result
    }
}
