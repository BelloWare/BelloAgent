import Foundation

/// A deliberately conservative YAML metadata reader. Anchors, tags, duplicate keys,
/// directives and ambiguous constructs fail closed instead of changing skill policy.
struct MetadataYAML {
    struct Line { var indent: Int; var text: String }
    var lines: [Line]; var index = 0
    init(_ text: String) throws {
        guard text.utf8.count <= 65536, !text.contains("\t") else { throw AgentError("invalid_metadata", "Metadata exceeds 64 KiB or contains tabs") }
        lines = text.components(separatedBy: .newlines).map { raw in
            Line(indent: raw.prefix(while: { $0 == " " }).count, text: raw.trimmingCharacters(in: .whitespaces))
        }
    }
    static func unquote(_ s: String) throws -> String {
        if s.hasPrefix("\"") { guard let v = try? JSON.parse(Data(s.utf8)).text else { throw AgentError("invalid_metadata", "Invalid quoted string") }; return v }
        if s.hasPrefix("'") { guard s.count >= 2, s.hasSuffix("'") else { throw AgentError("invalid_metadata", "Unclosed string") }; return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return s
    }
    static func withoutComment(_ s: String) -> String {
        var quote: Character?, escaped = false
        for i in s.indices {
            let c = s[i]
            if escaped { escaped = false; continue }
            if c == "\\", quote == "\"" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#", i == s.startIndex || s[s.index(before: i)].isWhitespace { return String(s[..<i]).trimmingCharacters(in: .whitespaces) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
    static func scalar(_ raw: String) throws -> JSON {
        let s = withoutComment(raw)
        if s.hasPrefix("\"") || s.hasPrefix("'") { return JSON(try unquote(s)) }
        if s == "true" { return true }; if s == "false" { return false }; if s == "null" || s == "~" { return .null }
        if s.hasPrefix("[") || s.hasPrefix("{") { return try JSON.parse(Data(s.utf8)) }
        if s.hasPrefix("&") || s.hasPrefix("*") || s.hasPrefix("!") || s.hasPrefix("%") || s.contains(": ") { throw AgentError("invalid_metadata", "Unsupported YAML construct; quote literal values") }
        if let n = Double(s), n.isFinite { return JSON(n) }
        return JSON(s)
    }
    mutating func skip() { while index < lines.count && (lines[index].text.isEmpty || lines[index].text.hasPrefix("#")) { index += 1 } }
    mutating func parse() throws -> JSON { skip(); if index == lines.count { return [:] }; let result = try node(lines[index].indent, depth: 0); skip(); guard index == lines.count else { throw AgentError("invalid_metadata", "Unexpected YAML indentation") }; return result }
    mutating func value(_ rest: String, parentIndent: Int, depth: Int) throws -> JSON {
        let s = Self.withoutComment(rest)
        if ["|", "|-", "|+", ">", ">-", ">+"].contains(s) {
            var parts: [String] = []; var blockIndent: Int?
            while index < lines.count {
                let line = lines[index]
                if !line.text.isEmpty && line.indent <= parentIndent { break }
                if !line.text.isEmpty { blockIndent = blockIndent ?? line.indent }
                parts.append(String(repeating: " ", count: max(0, line.indent - (blockIndent ?? line.indent))) + line.text); index += 1
            }
            return JSON(parts.joined(separator: s.hasPrefix(">") ? " " : "\n") + (s.hasSuffix("-") ? "" : "\n"))
        }
        if !s.isEmpty { return try Self.scalar(s) }
        skip(); if index < lines.count && lines[index].indent > parentIndent { return try node(lines[index].indent, depth: depth + 1) }; return [:]
    }
    func pair(_ s: String) throws -> (String, String) {
        guard let colon = s.firstIndex(of: ":") else { throw AgentError("invalid_metadata", "Expected metadata key") }
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        guard key.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else { throw AgentError("invalid_metadata", "Unsupported metadata key") }
        return (key, String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }
    mutating func node(_ indent: Int, depth: Int) throws -> JSON {
        guard depth < 16 else { throw AgentError("invalid_metadata", "Metadata nesting exceeds limit") }
        skip(); let sequence = index < lines.count && lines[index].text.hasPrefix("- ")
        var array: [JSON] = [], object: [String: JSON] = [:]
        while index < lines.count {
            skip(); if index == lines.count || lines[index].indent < indent { break }
            guard lines[index].indent == indent else { throw AgentError("invalid_metadata", "Unexpected metadata indentation") }
            let line = lines[index].text; index += 1
            if sequence {
                guard line.hasPrefix("- ") else { throw AgentError("invalid_metadata", "Mixed metadata collection") }
                let item = String(line.dropFirst(2))
                if item.contains(": ") || item.hasSuffix(":") {
                    let (key, rest) = try pair(item); var v: [String: JSON] = [key: try value(rest, parentIndent: indent + 2, depth: depth)]
                    skip()
                    if index < lines.count && lines[index].indent > indent {
                        let more = try node(lines[index].indent, depth: depth + 1)
                        guard more.isObject else { throw AgentError("invalid_metadata", "Expected mapping continuation") }
                        for (k, value) in more.map { guard v[k] == nil else { throw AgentError("invalid_metadata", "Duplicate metadata key") }; v[k] = value }
                    }
                    array.append(.object(v))
                } else { array.append(try Self.scalar(item)) }
            } else {
                let (key, rest) = try pair(line); guard object[key] == nil else { throw AgentError("invalid_metadata", "Duplicate metadata key") }
                object[key] = try value(rest, parentIndent: indent, depth: depth)
            }
        }
        return sequence ? .array(array) : .object(object)
    }
}
