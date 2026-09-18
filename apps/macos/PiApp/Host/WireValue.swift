import Foundation

indirect enum WireValue: Codable, Sendable, Equatable {
    case object([String: WireValue]), array([WireValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([WireValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: WireValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: WireValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [WireValue]? { if case .array(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var pretty: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "Unavailable" }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
}

struct HostFrameDecoder {
    static let maximum = 1_048_576
    private var pending = Data()
    mutating func append(_ bytes: Data) throws -> [[String: WireValue]] {
        var frames: [[String: WireValue]] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 10 {
            guard pending.count + bytes.distance(from: start, to: index) <= Self.maximum else { throw WireError.oversized }
            pending.append(bytes[start..<index])
            guard !pending.isEmpty else { throw WireError.invalid }
            frames.append(try JSONDecoder().decode([String: WireValue].self, from: pending))
            pending.removeAll(keepingCapacity: true)
            start = bytes.index(after: index)
        }
        guard pending.count + bytes.distance(from: start, to: bytes.endIndex) <= Self.maximum else { throw WireError.oversized }
        pending.append(bytes[start...])
        return frames
    }
    func finish() throws { if !pending.isEmpty { throw WireError.truncated } }
}
enum WireError: Error { case oversized, invalid, truncated }
