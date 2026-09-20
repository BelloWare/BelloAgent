import Foundation

// The JSON value the wire protocol, the journal and every provider body
// are expressed in.

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
