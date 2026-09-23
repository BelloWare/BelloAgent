import Foundation

/// A read-only, immutable rendering of the provider request builder. This is
/// deliberately separate from the transport archive: it was never dispatched.
struct ContextPreview: Sendable {
    let revision: String
    let createdAt: Date
    let body: JSON
    let metadata: JSON
    let sources: [JSON]

    init(body: JSON, metadata: JSON, sources: [JSON]) throws {
        guard try body.data().count <= 32 * 1024 * 1024 else {
            throw AgentError("request_limit", "The prepared context exceeds the 32 MiB request limit")
        }
        self.revision = UUID().uuidString; self.createdAt = Date()
        self.body = body; self.metadata = metadata; self.sources = sources
    }
    /// The request's messages; pi's system prompt, the first input item, is shown as the instructions.
    var inputs: [JSON] {
        if body["input"].isNull { return body["messages"].list }
        return RequestContextCounter.systemPrompt(body) == nil ? body["input"].list : Array(body["input"].list.dropFirst())
    }
    func summary(offset: Int = 0) throws -> JSON {
        let fixed: [JSON] = [
            ["id":"instructions", "title":"Instructions", "kind":"instructions"],
            ["id":"tools", "title":"Available tools", "kind":"tools"],
            ["id":"sources", "title":"Instruction sources", "kind":"sources"],
            ["id":"request", "title":"Complete prepared request", "kind":"request"]
        ]
        let total = fixed.count + inputs.count
        guard offset <= total else { throw AgentError("invalid_range", "Context item offset is out of range") }
        let end = min(total, offset + 32)
        let entries: [JSON] = (offset..<end).map { index in
            if index < fixed.count { return fixed[index] }
            let inputIndex = index - fixed.count, item = inputs[inputIndex]
            let kind = item["type"].text ?? "message"
            let title = item["role"].text ?? (kind == "function_call_output" ? "Tool result" : kind == "function_call" ? "Tool call" : kind == "reasoning" ? "Reasoning / provider state" : kind)
            return ["id":JSON("input:\(inputIndex)"), "title":JSON("\(inputIndex + 1). \(title)"), "kind":JSON(kind)]
        }
        var result = metadata
        result["revision"] = JSON(revision); result["createdAt"] = JSON(ISO8601DateFormatter().string(from: createdAt))
        result["items"] = .array(entries); result["totalItems"] = JSON(total)
        result["inputItems"] = JSON(inputs.count); result["next"] = end < total ? JSON(end) : .null
        return result
    }
    func read(section: String, offset: Int) throws -> JSON {
        let value: JSON
        switch section {
        case "instructions": value = RequestContextCounter.systemPrompt(body).map { JSON($0) } ?? (body["instructions"].isNull ? body["system"] : body["instructions"])
        case "tools": value = body["tools"].isNull ? [] : body["tools"]
        case "sources": value = .array(sources)
        case "request": value = body
        default:
            guard section.hasPrefix("input:"), let index = Int(section.dropFirst(6)), inputs.indices.contains(index) else {
                throw AgentError("invalid_range", "Unknown context item")
            }
            value = inputs[index]
        }
        let text: String
        if let plain = value.text { text = plain }
        else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            text = String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var page = try textPage(text, offset: offset)
        page["revision"] = JSON(revision); page["section"] = JSON(section)
        return page
    }
}
