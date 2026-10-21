import Foundation

/// Credentials are used only while observing a request. Headers retain a masked
/// identifier; known credential literals in bodies retain fingerprints instead.
/// Full values never cross the capture IPC boundary in headers or captured bodies.
/// Body replacement operates on submitted bytes, not JSON reconstruction.
struct CaptureCredentials: Sendable {
    // Session and turn identities are transport-owned correlation values, not
    // credentials; hashing them would also transform the Responses metadata body
    // and pi's prompt_cache_key. session_id and x-client-request-id are pi's
    // session affinity headers and carry the same identity.
    static let ordinaryHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "accept", "accept-encoding", "user-agent", "host", "connection", "anthropic-version", "anthropic-beta", "openai-version", "x-request-id", "request-id", "retry-after", "openai-processing-ms", "x-session-id", "x-turn-id", "session_id", "x-client-request-id"]
    let values: [String]
    let configuredNames: Set<String>
    private let literals: [Data]

    init(headers: [String: String], configuredNames: Set<String>) {
        let names = Set(configuredNames.map { $0.lowercased() })
        self.configuredNames = names
        values = Array(Set(headers.compactMap { name, value -> String? in
            let name = name.lowercased()
            guard !value.isEmpty, names.contains(name) || !Self.ordinaryHeaders.contains(name) else { return nil }
            return Self.credential(value, header: name).value
        })).sorted { $0.utf8.count > $1.utf8.count }
        literals = values.filter { !$0.isEmpty }.map { Data($0.utf8) }
    }
    static func fingerprint(_ value: String) -> String { "[sha256:" + sha256(Data(value.utf8)) + "]" }
    static func masked(_ value: String, showSuffix: Bool = true) -> String {
        // Keep at most one third of a token and never expose a short secret.
        // A fixed mask deliberately does not disclose the credential's length.
        "********" + (showSuffix && value.count >= 12 ? String(value.suffix(4)) : "")
    }
    private static func sensitiveHeader(_ name: String) -> Bool {
        if ["x-litellm-cache-key", "x-litellm-key-spend"].contains(name) { return false }
        // Parts end at "-" bytes: a "-" before a combining mark, ZWJ or
        // variation selector is one Character with it, not a separator.
        let parts = name.lowercased().utf8.split(separator: UInt8(ascii: "-")).map { String(decoding: $0, as: UTF8.self) }
        return ["authorization", "proxy-authorization", "cookie", "set-cookie"].contains(name) ||
            parts.contains(where: { ["auth", "authorization", "key", "token", "secret", "credential", "password"].contains($0) })
    }
    private static func credential(_ value: String, header: String) -> (prefix: String, value: String) {
        // The scheme ends at the first space byte, also where the token's
        // first scalar joins that space into one Character.
        if ["authorization", "proxy-authorization"].contains(header), let space = value.utf8.firstIndex(of: UInt8(ascii: " ")) {
            let scheme = String(decoding: value.utf8[..<space], as: UTF8.self)
            if scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]{0,31}$", options: .regularExpression) != nil {
                return (scheme + " ", String(decoding: value.utf8[value.utf8.index(after: space)...], as: UTF8.self))
            }
        }
        return ("", value)
    }
    /// Byte search, as the body maskers match: a credential can end inside a
    /// grapheme cluster ("…=" then a combining mark, ZWJ or variation selector
    /// is one Character), where String matching finds nothing or depends on
    /// the string's storage. String matching still catches a canonically
    /// equivalent spelling.
    func contains(_ value: String) -> Bool {
        guard !values.isEmpty else { return false }
        let bytes = Data(value.utf8)
        return literals.contains { bytes.range(of: $0) != nil } || values.contains { value.contains($0) }
    }
    func requestHeaders(_ headers: [String: String]) -> JSON {
        .object(Dictionary(headers.map { name, value in
            let name = name.lowercased(), credential = Self.credential(value, header: name)
            let safe = Self.ordinaryHeaders.contains(name) && !configuredNames.contains(name) && !Self.sensitiveHeader(name) && !contains(value)
            return (metadataText(name), JSON(safe ? value : credential.prefix + Self.masked(credential.value, showSuffix: name != "cookie" && name != "set-cookie")))
        }, uniquingKeysWith: { _, last in last }))
    }
    func responseHeaders(_ headers: [String: String], metadataHeaders _: Set<String>) -> JSON {
        .object(Dictionary(headers.map { name, value in
            let name = name.lowercased()
            // Retain normal response headers, including routing, billing,
            // caching and debugging fields not known to the gateway parser.
            // A gateway echo must not reintroduce a captured request credential.
            let safe = !Self.sensitiveHeader(name) && !configuredNames.contains(name) && !contains(value)
            guard safe else { return (metadataText(name), JSON("********")) }
            guard value.utf8.count <= 16_384, !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                return (metadataText(name), JSON("[omitted: header exceeds capture safety limits]"))
            }
            return (metadataText(name), JSON(value))
        }, uniquingKeysWith: { _, last in last }))
    }
    func metadataText(_ value: String) -> String {
        guard contains(value) else { return value }
        // Hash the complete field rather than replace repeatedly inside a hash.
        return Self.fingerprint(value)
    }
    // Fixed schema keys are protocol, even when a configured header happens
    // to contain one. Only provider-controlled dictionaries opt into key masking.
    func resourceMetadata(_ value: JSON) -> JSON {
        var safe = value
        for field in ["path", "text"] where !value[field].isNull { safe[field] = metadata(value[field]) }
        return safe
    }
    /// The prepared request has protocol discriminators beside model-facing
    /// payloads. Mask the payloads without turning its roles/types into hashes.
    func requestMetadata(_ value: JSON, definitions: [ToolDefinition] = []) -> JSON {
        func item(_ value: JSON) -> JSON {
            var safe = metadata(value)
            let enums: [String: Set<String>] = ["type":["message", "function_call", "function_call_output", "reasoning", "input_text", "output_text", "input_image", "summary_text", "refusal"],
                "role":["system", "developer", "user", "assistant"], "status":["completed"], "phase":["commentary", "final_answer"], "detail":["auto"]]
            for (field, values) in enums where value[field].text.map(values.contains) == true { safe[field] = value[field] }
            for field in ["content", "output", "summary"] { if case .array(let values) = value[field] { safe[field] = .array(values.map(item)) } }
            return safe
        }
        func schema(_ value: JSON) -> JSON {
            var safe = metadata(value)
            let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
            if value["type"].text.map(types.contains) == true { safe["type"] = value["type"] }
            if case .array(let values) = value["type"], values.allSatisfy({ $0.text.map(types.contains) == true }) { safe["type"] = value["type"] }
            for field in ["properties", "$defs", "definitions"] where value[field].isObject {
                safe[field] = .object(Dictionary(value[field].map.map { (metadataText($0.key), schema($0.value)) },uniquingKeysWith:{ _, last in last }))
            }
            for field in ["items", "additionalProperties", "not"] where value[field].isObject { safe[field] = schema(value[field]) }
            for field in ["allOf", "anyOf", "oneOf", "prefixItems"] { if case .array(let values) = value[field] { safe[field] = .array(values.map(schema)) } }
            return safe
        }
        func configuredModels(_ value: JSON) -> JSON {
            var safe = value
            if !value["properties"]["model"]["enum"].isNull { safe["properties"]["model"]["enum"] = metadata(value["properties"]["model"]["enum"]) }
            for field in ["allOf", "anyOf", "oneOf"] { if case .array(let variants) = value[field] { safe[field] = .array(variants.map(configuredModels)) } }
            return safe
        }
        var safe = metadata(value)
        if case .array(let inputs) = value["input"] { safe["input"] = .array(inputs.map(item)) }
        if case .array(let tools) = value["tools"] {
            safe["tools"] = .array(tools.map { tool in
                // Native and delegation tool definitions are helper-owned.
                // Only offered model names come from configuration. A body
                // override must match the actual definition before trusting it.
                if tool["type"].text == "function", let definition = definitions.first(where: { $0.name == tool["name"].text }),
                   tool["description"].text == definition.description, tool["parameters"] == definition.schema {
                    var safe = metadata(tool)
                    safe["type"] = "function"; safe["name"] = JSON(definition.name); safe["description"] = JSON(definition.description)
                    safe["parameters"] = configuredModels(definition.schema); return safe
                }
                var safe = metadata(tool)
                if tool["type"].text == "function" { safe["type"] = "function"; safe["parameters"] = schema(tool["parameters"]) }
                return safe
            })
        }
        if value["include"] == ["reasoning.encrypted_content"] { safe["include"] = value["include"] }
        if value["reasoning"]["summary"].text == "auto" { safe["reasoning"]["summary"] = "auto" }
        return safe
    }
    func metadata(_ value: JSON) -> JSON { metadata(value, includingKeys: false) }
    func metadata(_ value: JSON, includingKeys: Bool) -> JSON {
        switch value {
        case .string(let text): return JSON(metadataText(text))
        case .array(let array): return .array(array.map { metadata($0, includingKeys: includingKeys) })
        case .object(let object): return .object(Dictionary(object.map { (includingKeys ? metadataText($0.key) : $0.key, metadata($0.value, includingKeys: includingKeys)) }, uniquingKeysWith: { _, last in last }))
        default: return value
        }
    }
    struct Body: Sendable {
        let bytes: Data, replacements: Int
        let omitted: Bool
    }
    /// Mask only the capture copy. Keeping a suffix prevents a credential split
    /// across HTTP callbacks from leaking into either memory or persistent IPC.
    /// Replacements have the original byte length so captured SSE event offsets
    /// still describe the observed stream. Parsing receives the original bytes.
    struct ResponseMasker: Sendable {
        private struct Pattern: Sendable {
            let literal: Data
            let scalars: [(value: UInt32, bytes: [UInt8])]
            let maximumBytes: Int
            init(_ value: String) {
                literal = Data(value.utf8)
                scalars = value.unicodeScalars.map { ($0.value, Array(String($0).utf8)) }
                maximumBytes = value.utf16.count * 6
            }
            /// Match decoded JSON characters, but return the original span.
            /// A scalar may use literal UTF-8, a short escape or UTF-16 escapes.
            func escapedLength(in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
                var offset = start, escaped = false
                for scalar in scalars {
                    guard offset < bytes.count else { return nil }
                    if bytes[offset] == 92 {
                        guard let decoded = Self.escape(in: bytes, at: offset), decoded.value == scalar.value else { return nil }
                        offset = decoded.end; escaped = true
                    } else {
                        guard offset + scalar.bytes.count <= bytes.count else { return nil }
                        for (index, byte) in scalar.bytes.enumerated() where bytes[offset + index] != byte { return nil }
                        offset += scalar.bytes.count
                    }
                }
                return escaped ? offset - start : nil
            }
            private static func escape(in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> (value: UInt32, end: Int)? {
                guard start + 1 < bytes.count else { return nil }
                let value: UInt32
                switch bytes[start + 1] {
                case 34, 47, 92: value = UInt32(bytes[start + 1])
                case 98: value = 8
                case 102: value = 12
                case 110: value = 10
                case 114: value = 13
                case 116: value = 9
                case 117:
                    func unit(at offset: Int) -> UInt32? {
                        guard offset + 6 <= bytes.count, bytes[offset] == 92, bytes[offset + 1] == 117 else { return nil }
                        var unit: UInt32 = 0
                        for index in (offset + 2)..<(offset + 6) {
                            let digit: UInt32
                            switch bytes[index] {
                            case 48...57: digit = UInt32(bytes[index] - 48)
                            case 65...70: digit = UInt32(bytes[index] - 55)
                            case 97...102: digit = UInt32(bytes[index] - 87)
                            default: return nil
                            }
                            unit = unit * 16 + digit
                        }
                        return unit
                    }
                    guard let high = unit(at: start) else { return nil }
                    if (0xD800...0xDBFF).contains(high) {
                        guard let low = unit(at: start + 6), (0xDC00...0xDFFF).contains(low) else { return nil }
                        return (0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00, start + 12)
                    }
                    guard !(0xDC00...0xDFFF).contains(high) else { return nil }
                    return (high, start + 6)
                default: return nil
                }
                return (value, start + 2)
            }
        }
        private let patterns: [Pattern]
        private let suffixLength: Int
        private var pending = Data(), masked = Data()
        private(set) var replacements = 0

        init(_ credentials: CaptureCredentials) {
            patterns = credentials.values.filter { !$0.isEmpty }.map(Pattern.init)
            suffixLength = max(0, (patterns.map(\.maximumBytes).max() ?? 1) - 1)
        }

        mutating func feed(_ bytes: Data, final: Bool = false) -> Data {
            guard !patterns.isEmpty else { return bytes }
            pending.append(bytes); masked.append(bytes)
            let count = final ? pending.count : max(0, pending.count - suffixLength)
            guard count > 0 else { return Data() }
            for pattern in patterns {
                var offset = 0
                while offset < count, let range = pending.range(of: pattern.literal, in: offset..<pending.count), range.lowerBound < count {
                    // Search against original bytes, including overlapping
                    // matches; otherwise masking one key can expose another.
                    masked.replaceSubrange(range, with: repeatElement(UInt8(42), count: range.count))
                    replacements += 1; offset = range.lowerBound + 1
                }
            }
            if pending.contains(92) {
                pending.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for pattern in patterns {
                        for offset in 0..<count where bytes[offset] == 92 || bytes[offset] == pattern.literal.first {
                            guard let length = pattern.escapedLength(in: bytes, at: offset) else { continue }
                            masked.replaceSubrange(offset..<(offset + length), with: repeatElement(UInt8(42), count: length))
                            replacements += 1
                        }
                    }
                }
            }
            let result = Data(masked.prefix(count))
            pending = Data(pending.dropFirst(count)); masked = Data(masked.dropFirst(count))
            return result
        }
    }
    func requestBody(_ body: Data) -> Body {
        struct Match { let range: Range<Int>, replacement: Data }
        var patterns: [Data: Data] = [:], matches: [Match] = []
        for value in values where !value.isEmpty {
            let replacement = Data(Self.fingerprint(value).utf8)
            patterns[Data(value.utf8)] = replacement
            // Same encoder/settings as the one producing the submitted body.
            if let quoted = try? JSON(value).data(), quoted.count >= 2 {
                patterns[quoted.subdata(in: 1..<quoted.count - 1)] = replacement
            }
        }
        for (pattern, replacement) in patterns where !pattern.isEmpty {
            var offset = 0
            while offset < body.count, let range = body.range(of: pattern, in: offset..<body.count) {
                guard matches.count < 65_536 else { return Body(bytes: Data(), replacements: matches.count, omitted: true) }
                matches.append(Match(range: range, replacement: replacement)); offset = range.upperBound
            }
        }
        guard !matches.isEmpty else { return Body(bytes: body, replacements: 0, omitted: false) }
        matches.sort { $0.range.lowerBound == $1.range.lowerBound ? $0.range.count > $1.range.count : $0.range.lowerBound < $1.range.lowerBound }
        var output = Data(), offset = 0, count = 0
        for match in matches where match.range.lowerBound >= offset {
            guard output.count + match.range.lowerBound - offset + match.replacement.count <= 32 * 1024 * 1024 else { return Body(bytes: Data(), replacements: count, omitted: true) }
            output.append(body.subdata(in: offset..<match.range.lowerBound)); output.append(match.replacement)
            offset = match.range.upperBound; count += 1
        }
        guard output.count + body.count - offset <= 32 * 1024 * 1024 else { return Body(bytes: Data(), replacements: count, omitted: true) }
        output.append(body.subdata(in: offset..<body.count))
        return Body(bytes: output, replacements: count, omitted: false)
    }
}
