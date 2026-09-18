import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// JSON values are retained independently of the lossy transcript projection.
public enum JSON: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var map: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var list: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
    public var double: Double? { if case .number(let v) = self { return v }; return nil }
    public var int: Int? { guard let n = double, n.isFinite, n.rounded() == n, n >= Double(Int.min), n < Double(Int.max) else { return nil }; return Int(n) }
    public var flag: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }
    public var isObject: Bool { if case .object = self { return true }; return false }
    public subscript(_ key: String) -> JSON {
        get { map[key] ?? .null }
        set { var v = map; v[key] = newValue; self = .object(v) }
    }
    public static func parse(_ bytes: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: bytes) }
    public func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }
    public func encoded() -> String { String(data: (try? data()) ?? Data(), encoding: .utf8) ?? "null" }
    public func removing(_ keys: Set<String>) -> JSON { .object(map.filter { !keys.contains($0.key) }) }
}
public struct AgentError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    public var json: JSON { ["code": JSON(code), "message": JSON(message)] }
}
func required(_ value: JSON, _ name: String, maximum: Int = 4096) throws -> String {
    guard let s = value.text, !s.isEmpty, s.utf8.count <= maximum else { throw AgentError("invalid_params", "Invalid \(name)") }
    return s
}
func identity(_ value: JSON) throws -> String {
    let s = try required(value, "identity", maximum: 128)
    guard s.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil, s != ".", s != ".." else { throw AgentError("invalid_identity", "Invalid identity") }
    return s
}
func boundedInt(_ value: JSON, fallback: Int = 0, maximum: Int = 1_000_000) throws -> Int {
    if value.isNull { return fallback }
    guard let n = value.int, n >= 0, n <= maximum else { throw AgentError("invalid_range", "Invalid numeric range") }; return n
}
func nowMS() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func textBlock(_ text: String) -> JSON { ["type": "text", "text": JSON(text)] }
func preview(_ s: String, bytes: Int = 16384) -> String { String(decoding: Array(s.utf8.prefix(bytes)), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{fffd}")) }
func textPage(_ text: String, offset: Int, count: Int = 16_384) throws -> JSON {
    let ns = text as NSString
    guard offset >= 0, offset <= ns.length else { throw AgentError("invalid_range", "Text offset is outside the retained content") }
    if offset > 0, offset < ns.length, (0xDC00...0xDFFF).contains(ns.character(at: offset)) { throw AgentError("invalid_range", "Offset splits a Unicode character") }
    var end = min(ns.length, offset + count)
    if end < ns.length, end > offset, (0xD800...0xDBFF).contains(ns.character(at: end - 1)) { end -= 1 }
    return ["text": JSON(ns.substring(with: NSRange(location: offset, length: end - offset))), "offset": JSON(offset), "total": JSON(ns.length), "totalCharacters": JSON(ns.length), "next": end < ns.length ? JSON(end) : .null]
}
func canonical(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath() }
func within(_ path: URL, _ root: URL) -> Bool { path.path == root.path || path.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") }
func readBounded(_ url: URL, maximum: Int) throws -> Data {
    // Nonblocking open and fstat reject FIFOs/devices without hanging discovery.
    let fd=open(url.path,O_RDONLY|O_NONBLOCK|O_CLOEXEC)
    guard fd>=0 else { throw AgentError("file_unavailable","Cannot open \(url.path)") }
    let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? file.close() }
    var info=stat()
    guard fstat(fd,&info)==0, info.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG) else { throw AgentError("not_regular_file","Only regular files can be read") }
    guard info.st_size<=maximum else { throw AgentError("file_too_large","File exceeds the supported size limit") }
    let bytes=try file.read(upToCount:maximum+1) ?? Data()
    guard bytes.count<=maximum else { throw AgentError("file_too_large","File exceeds the supported size limit") };return bytes
}

/// Dependency-free SHA-256 for content identities; never used as encryption.
public func sha256(_ data: Data) -> String {
    let k: [UInt32] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    var bytes = Array(data); let bits = UInt64(bytes.count) * 8
    bytes.append(0x80); while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
    func r(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for start in stride(from: 0, to: bytes.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { let p = start + i * 4; w[i] = (UInt32(bytes[p]) << 24) | (UInt32(bytes[p+1]) << 16) | (UInt32(bytes[p+2]) << 8) | UInt32(bytes[p+3]) }
        for i in 16..<64 { let a = w[i-15], b = w[i-2]; w[i] = w[i-16] &+ (r(a,7) ^ r(a,18) ^ (a >> 3)) &+ w[i-7] &+ (r(b,17) ^ r(b,19) ^ (b >> 10)) }
        var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], z=h[7]
        for i in 0..<64 { let t = z &+ (r(e,6)^r(e,11)^r(e,25)) &+ ((e&f)^((~e)&g)) &+ k[i] &+ w[i]; let u = (r(a,2)^r(a,13)^r(a,22)) &+ ((a&b)^(a&c)^(b&c)); z=g; g=f; f=e; e=d &+ t; d=c; c=b; b=a; a=t &+ u }
        h = zip(h,[a,b,c,d,e,f,g,z]).map { $0 &+ $1 }
    }
    return h.map { String(format: "%08x", $0) }.joined()
}

public struct Profile: Sendable {
    public let raw: JSON
    public let id: String, api: String, model: String, provider: String
    public let endpoint: URL
    /// maxOutput is the requested generation budget, independent of the model's ceiling.
    public let contextWindow: Int, maxOutput: Int
    public let modelOutputLimit: Int?
    public init(_ value: JSON) throws {
        guard value.isObject else { throw AgentError("invalid_profile", "Profile must be an object") }
        id = try required(value["id"], "profile id", maximum: 128)
        api = try required(value["api"], "API")
        guard api == "openai-responses" else { throw AgentError("unsupported_api", "Only the Responses API is supported for new requests. Existing Messages history is preserved; choose or create a Responses connection in Settings.") }
        model = try required(value["modelId"], "model", maximum: 256)
        provider = try required(value["providerId"], "provider", maximum: 128)
        contextWindow = try boundedInt(value["contextWindow"], maximum: 10_000_000)
        let requestedOutput = try boundedInt(value["maxOutputTokens"], maximum: 1_000_000)
        maxOutput = requestedOutput
        modelOutputLimit = value["modelOutputLimit"].isNull ? nil : try boundedInt(value["modelOutputLimit"], maximum: 1_000_000)
        guard maxOutput > 0, contextWindow > maxOutput,
              modelOutputLimit.map({ $0 > 0 && requestedOutput <= $0 }) ?? true else {
            throw AgentError("invalid_profile", "The positive output budget must fit below context capacity and within the model's supported output limit")
        }
        let url = try required(value["baseUrl"], "endpoint")
        guard !url.contains(where: \.isWhitespace) else { throw AgentError("invalid_endpoint", "Endpoint contains whitespace") }
        guard var c = URLComponents(string: url), let host = c.host, ["http", "https"].contains(c.scheme), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              !c.percentEncodedPath.lowercased().contains("%2f"), !c.percentEncodedPath.lowercased().contains("%2e") else { throw AgentError("invalid_endpoint", "Use HTTPS, or loopback HTTP, without URL credentials, query or fragment") }
        var path = c.path; while path.hasSuffix("/") { path.removeLast() }
        let leaf = "/responses"
        let fullRoute = path.hasSuffix(leaf)
        if fullRoute { path.removeLast(leaf.count) }
        guard !path.hasSuffix("/responses"), !path.hasSuffix("/messages"), !path.hasSuffix("/completions"),
              !path.contains("/v1/v1"), !path.contains("//"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AgentError("invalid_endpoint", "Mixed or repeated API routes")
        }
        if !fullRoute && !path.hasSuffix("/v1") { path += "/v1" }
        path += leaf
        c.path = path; guard let endpoint = c.url else { throw AgentError("invalid_endpoint", "Invalid URL") }; self.endpoint = endpoint
        for (key, v) in value["headers"].map {
            guard key.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil, let v = v.text, !v.utf8.contains(13), !v.utf8.contains(10), v.utf8.count <= 16384 else { throw AgentError("invalid_profile", "Invalid header") }
        }
        if let level = value["thinkingLevel"].text, !Self.thinkingLevels.contains(level) { throw AgentError("invalid_profile", "Unsupported thinking level") }
        _ = try RoutingContract(value["routing"])
        raw = value
    }
    public static let thinkingLevels = ["default","off","minimal","low","medium","high","xhigh","max"]
    public var binding: JSON { ["api": JSON(api), "model": JSON(model), "provider": JSON(provider), "endpointSHA256": JSON(sha256(Data(endpoint.absoluteString.utf8)))] }
    public var publicValue: JSON { raw.removing(["headers","apiKey","key","token","authorization"]) }
    /// A per-turn override changes the model, thinking and declared capacity.
    /// A different alias leaves the configured pinned route, so opaque
    /// reasoning produced by that turn is recorded portably rather than replayed
    /// into another model later.
    public func overriding(model: String?, thinkingLevel: String?, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, modelOutputLimit: Int? = nil) throws -> Profile {
        guard model != nil || thinkingLevel != nil || contextWindow != nil || maxOutputTokens != nil || modelOutputLimit != nil else { return self }
        var value = raw
        let capacity=contextWindow ?? self.contextWindow, output=maxOutputTokens ?? maxOutput
        let ceiling = modelOutputLimit ?? (model == nil || model == self.model ? self.modelOutputLimit : nil)
        guard capacity > 0, capacity <= 10_000_000, output > 0, output <= 1_000_000, capacity > output,
              ceiling.map({ $0 > 0 && $0 <= 1_000_000 && output <= $0 }) ?? true else {
            throw AgentError("invalid_params", "The turn output budget must fit below context capacity and within the model's supported output limit")
        }
        if let contextWindow { value["contextWindow"]=JSON(contextWindow) }
        if let maxOutputTokens { value["maxOutputTokens"]=JSON(maxOutputTokens) }
        if let ceiling { value["modelOutputLimit"] = JSON(ceiling) }
        else { value = value.removing(["modelOutputLimit"]) }
        if let model {
            guard !model.isEmpty, model.utf8.count <= 200, !model.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw AgentError("invalid_params", "Invalid model override") }
            value["modelId"] = JSON(model)
            if model != self.model { value=value.removing(["thinkingLevelMap"]) }
            if model != self.model, !value["routing"].isNull { var routing = value["routing"]; routing["replayPolicy"] = "portable"; value["routing"] = routing.removing(["expectedModel","replayContract"]) }
        }
        if let thinkingLevel {
            guard Self.thinkingLevels.contains(thinkingLevel) else { throw AgentError("invalid_params", "Unsupported thinking level override") }
            value["thinkingLevel"] = JSON(thinkingLevel)
            // Explicit choices must not be silently ignored by a profile that
            // omitted reasoning support. Model default omits inherited options.
            value["reasoning"] = JSON(thinkingLevel != "default")
        }
        return try Profile(value)
    }
}

public struct ChatMessage: Codable, Sendable {
    public var id: String = UUID().uuidString
    public var role: String
    public var content: [JSON]
    public var providerItems: [JSON]? = nil
    public var providerIdentity: JSON? = nil
    public var providerBinding: JSON? = nil
    public var toolCallId: String? = nil
    public var toolName: String? = nil
    public var isError: Bool = false
    public var replayEligible: Bool = true
    public var displayText: String? = nil
    public var sourceMessageIDs: [String]? = nil
    public var requestAttemptIDs: [String]? = nil
    /// Display-only classification: "compaction" for a summary written by
    /// compaction, "branch" for the marker left by turn.edit. Nil for ordinary rows.
    public var kind: String? = nil
    public var detail: String? = nil
    /// Milliseconds since 1970 when the message was appended; journals written
    /// before this field carried the same key, so old history keeps its clock.
    public var timestamp: Double? = nil
    /// For tool results: durationMs plus, for file tools, path/added/removed.
    public var toolStats: JSON? = nil
    /// The turn this row was appended under: the id of the user message that
    /// started the run. The transcript groups work by it instead of guessing
    /// at boundaries from row order. Nil for rows journaled before 0.1.34.
    public var turn: String? = nil
    /// Assistant rows: how long the model request that produced the row took,
    /// in milliseconds, measured by the host around the request.
    public var modelMs: Double? = nil
    public var text: String { content.filter { $0["type"].text == "text" }.compactMap { $0["text"].text }.joined() }
    public var thinking: String { content.filter { $0["type"].text == "thinking" }.compactMap { $0["thinking"].text }.joined() }
    public var pi: JSON {
        var value: JSON = ["role": JSON(role), "content": .array(content), "timestamp": JSON(timestamp ?? Date().timeIntervalSince1970 * 1000), "nativeReplayEligible": JSON(replayEligible)]
        if let toolStats { value["nativeToolStats"] = toolStats }
        if let turn { value["nativeTurn"] = JSON(turn) }
        if let modelMs { value["nativeModelMs"] = JSON(modelMs) }
        if let providerItems { value["nativeProviderItems"] = .array(providerItems) }
        if let providerIdentity { value["nativeProviderIdentity"] = providerIdentity }
        if let providerBinding { value["nativeProviderBinding"] = providerBinding }
        if let toolCallId { value["toolCallId"] = JSON(toolCallId) }
        if let toolName { value["toolName"] = JSON(toolName) }
        if let displayText { value["nativeDisplayText"] = JSON(displayText) }
        if let requestAttemptIDs { value["nativeRequestAttemptIds"] = .array(requestAttemptIDs.map { JSON($0) }) }
        if let kind { value["nativeKind"] = JSON(kind) }
        if let detail { value["nativeDetail"] = JSON(detail) }
        value["isError"] = JSON(isError)
        return value
    }
    public init(role: String, content: [JSON]) { self.role = role; self.content = content }
    public init(id: String, pi: JSON) throws {
        guard let role = pi["role"].text, ["user","assistant","toolResult","system"].contains(role) else { throw AgentError("invalid_session", "Unsupported message role") }
        self.id=id; self.role=role
        content = pi["content"].text.map { [textBlock($0)] } ?? pi["content"].list
        providerItems = pi["nativeProviderItems"].isNull ? nil : pi["nativeProviderItems"].list
        providerIdentity = pi["nativeProviderIdentity"].isNull ? nil : pi["nativeProviderIdentity"]
        providerBinding = pi["nativeProviderBinding"].isNull ? nil : pi["nativeProviderBinding"]
        toolCallId = pi["toolCallId"].text; toolName = pi["toolName"].text; isError = pi["isError"].flag ?? false
        replayEligible = pi["nativeReplayEligible"].flag ?? true; displayText = pi["nativeDisplayText"].text
        requestAttemptIDs = pi["nativeRequestAttemptIds"].isNull ? nil : pi["nativeRequestAttemptIds"].list.compactMap(\.text)
        kind = pi["nativeKind"].text; detail = pi["nativeDetail"].text
        timestamp = pi["timestamp"].double; toolStats = pi["nativeToolStats"].isNull ? nil : pi["nativeToolStats"]
        turn = pi["nativeTurn"].text; modelMs = pi["nativeModelMs"].double
    }
    public func view(toolStates: [String: JSON] = [:], state: String = "complete") -> JSON {
        let tools = content.filter { $0["type"].text == "toolCall" }.map { block -> JSON in
            let id = block["id"].text ?? "unknown"
            return toolStates[id] ?? ["id": JSON(id), "name": block["name"], "state": "prepared", "input": JSON(preview(block["arguments"].encoded(), bytes: 4096)), "output": "", "durationMs": .null, "truncated": false]
        }
        let full = displayText ?? text
        var value: JSON = ["id": JSON(id), "role": JSON(role == "toolResult" ? "tool" : role), "text": JSON(preview(full)), "thinking": JSON(preview(thinking, bytes: 8192)), "tools": .array(Array(tools.prefix(32))), "state": JSON(state), "truncated": JSON(full.utf8.count > 16384 || thinking.utf8.count > 8192 || tools.count > 32)]
        if let kind { value["kind"] = JSON(kind) }
        if let detail { value["detail"] = JSON(preview(detail, bytes: 1024)) }
        if let timestamp { value["at"] = JSON(timestamp) }
        if let turn { value["turn"] = JSON(turn) }
        if let modelMs { value["modelMs"] = JSON(modelMs) }
        return value
    }
}
public struct ToolDefinition: Sendable {
    public let name: String, description: String
    public let schema: JSON
    public init(_ name: String, _ description: String, _ schema: JSON) { self.name=name; self.description=description; self.schema=schema }
}
public struct ToolCall: Sendable {
    public let id: String, name: String
    public let arguments: JSON
    public init(id: String, name: String, arguments: JSON) { self.id=id; self.name=name; self.arguments=arguments }
}
public struct ModelReply: Sendable {
    public var message: ChatMessage
    public var calls: [ToolCall]
    public var usage: JSON
    public var truncated: Bool
    public init(message: ChatMessage, calls: [ToolCall] = [], usage: JSON = [:], truncated: Bool = false) { self.message=message; self.calls=calls; self.usage=usage; self.truncated=truncated }
}
public enum StreamDelta: Sendable { case text(String), thinking(String), tool(String, String, String) }
public protocol ModelClient: Sendable {
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply
}
public protocol ToolExecuting: Sendable {
    func definitions(readOnly: Bool) async -> [ToolDefinition]
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON
    func capabilityIDs(readOnly: Bool) async -> [String]
}
public extension ToolExecuting {
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON { try await invoke(call,readOnly:readOnly) }
    func capabilityIDs(readOnly: Bool) async -> [String] { await definitions(readOnly:readOnly).map(\.name) }
}
public struct DisabledTools: ToolExecuting {
    public init() {}
    public func definitions(readOnly: Bool) -> [ToolDefinition] { [] }
    public func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("tools_disabled","Tools are disabled for connection tests") }
}
