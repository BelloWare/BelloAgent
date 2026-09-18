import Foundation

/// Credentials are used only while observing a request. Headers retain a masked
/// identifier; known credential literals in bodies retain fingerprints instead.
/// Full values never cross the capture IPC boundary in headers or captured bodies.
/// Body replacement operates on submitted bytes, not JSON reconstruction.
struct CaptureCredentials: Sendable {
    // Session and turn identities are transport-owned correlation values, not
    // credentials; hashing them would also transform the Responses metadata body.
    static let ordinaryHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "accept", "accept-encoding", "user-agent", "host", "connection", "anthropic-version", "anthropic-beta", "openai-version", "x-request-id", "request-id", "retry-after", "openai-processing-ms", "x-session-id", "x-turn-id"]
    let values: [String]
    let configuredNames: Set<String>

    init(headers: [String: String], configuredNames: Set<String>) {
        let names = Set(configuredNames.map { $0.lowercased() })
        self.configuredNames = names
        values = Array(Set(headers.compactMap { name, value -> String? in
            let name = name.lowercased()
            guard !value.isEmpty, names.contains(name) || !Self.ordinaryHeaders.contains(name) else { return nil }
            return Self.credential(value, header: name).value
        })).sorted { $0.utf8.count > $1.utf8.count }
    }
    static func fingerprint(_ value: String) -> String { "[sha256:" + sha256(Data(value.utf8)) + "]" }
    static func masked(_ value: String, showSuffix: Bool = true) -> String {
        // Keep at most one third of a token and never expose a short secret.
        // A fixed mask deliberately does not disclose the credential's length.
        "********" + (showSuffix && value.count >= 12 ? String(value.suffix(4)) : "")
    }
    private static func sensitiveHeader(_ name: String) -> Bool {
        if ["x-litellm-cache-key", "x-litellm-key-spend"].contains(name) { return false }
        let parts = name.lowercased().split(separator: "-").map(String.init)
        return ["authorization", "proxy-authorization", "cookie", "set-cookie"].contains(name) ||
            parts.contains(where: { ["auth", "authorization", "key", "token", "secret", "credential", "password"].contains($0) })
    }
    private static func credential(_ value: String, header: String) -> (prefix: String, value: String) {
        if ["authorization", "proxy-authorization"].contains(header), let space = value.firstIndex(of: " "),
           value[..<space].range(of: "^[A-Za-z][A-Za-z0-9+.-]{0,31}$", options: .regularExpression) != nil {
            return (String(value[...space]), String(value[value.index(after: space)...]))
        }
        return ("", value)
    }
    func contains(_ value: String) -> Bool { values.contains { value.contains($0) } }
    func requestHeaders(_ headers: [String: String]) -> JSON {
        .object(Dictionary(headers.map { name, value in
            let name = name.lowercased(), credential = Self.credential(value, header: name)
            let safe = Self.ordinaryHeaders.contains(name) && !configuredNames.contains(name) && !Self.sensitiveHeader(name) && !contains(value)
            return (name, JSON(safe ? value : credential.prefix + Self.masked(credential.value, showSuffix: name != "cookie" && name != "set-cookie")))
        }, uniquingKeysWith: { _, last in last }))
    }
    func responseHeaders(_ headers: [String: String], metadataHeaders _: Set<String>) -> JSON {
        .object(Dictionary(headers.map { name, value in
            let name = name.lowercased()
            // Retain normal response headers, including routing, billing,
            // caching and debugging fields not known to the gateway parser.
            // A gateway echo must not reintroduce a captured request credential.
            let safe = !Self.sensitiveHeader(name) && !configuredNames.contains(name) && !contains(value)
            guard safe else { return (name, JSON("********")) }
            guard value.utf8.count <= 16_384, !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                return (name, JSON("[omitted: header exceeds capture safety limits]"))
            }
            return (name, JSON(value))
        }, uniquingKeysWith: { _, last in last }))
    }
    func metadataText(_ value: String) -> String {
        guard contains(value) else { return value }
        // Hash the complete field rather than replace repeatedly inside a hash.
        return Self.fingerprint(value)
    }
    func metadata(_ value: JSON) -> JSON {
        switch value {
        case .string(let text): return JSON(metadataText(text))
        case .array(let array): return .array(array.map(metadata))
        case .object(let object): return .object(object.mapValues(metadata))
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
        private let patterns: [Data]
        private let suffixLength: Int
        private var pending = Data(), masked = Data()
        private(set) var replacements = 0

        init(_ credentials: CaptureCredentials) {
            var patterns = Set<Data>()
            for value in credentials.values where !value.isEmpty {
                patterns.insert(Data(value.utf8))
                if let quoted = try? JSON(value).data(), quoted.count >= 2 {
                    let escaped = quoted.subdata(in: 1..<quoted.count - 1)
                    patterns.insert(escaped)
                    // JSON permits either spelling for a slash. Gateways need
                    // not use our request encoder's withoutEscapingSlashes flag.
                    if let text = String(data: escaped, encoding: .utf8) {
                        patterns.insert(Data(text.replacingOccurrences(of: "/", with: "\\/").utf8))
                    }
                }
            }
            self.patterns = patterns.filter { !$0.isEmpty }
            suffixLength = max(0, (patterns.map(\.count).max() ?? 1) - 1)
        }

        mutating func feed(_ bytes: Data, final: Bool = false) -> Data {
            guard !patterns.isEmpty else { return bytes }
            pending.append(bytes); masked.append(bytes)
            let count = final ? pending.count : max(0, pending.count - suffixLength)
            guard count > 0 else { return Data() }
            for pattern in patterns {
                var offset = 0
                while offset < count, let range = pending.range(of: pattern, in: offset..<pending.count), range.lowerBound < count {
                    // Search against original bytes, including overlapping
                    // matches; otherwise masking one key can expose another.
                    masked.replaceSubrange(range, with: repeatElement(UInt8(42), count: range.count))
                    replacements += 1; offset = range.lowerBound + 1
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
