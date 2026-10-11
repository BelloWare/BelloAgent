// The two types the unchanged app sources need from files this oracle does
// not compile, copied verbatim (Host/WireValue.swift's accessors in use,
// Storage/CaptureArchive/CaptureDatabase.swift's value enum), and the chat
// record a SessionReference names.
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
    var number: Double? { if case .number(let value) = self { value } else { nil } }
}

enum CaptureSQLValue: Sendable {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var string: String? { if case .text(let value) = self { value } else { nil } }
    var number: Int64? { if case .integer(let value) = self { value } else { nil } }
    var double: Double? { switch self { case .real(let value): value; case .integer(let value): Double(value); default: nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
}

struct ChatRecord {
    var id = "chat-id", title = "Oracle chat", workspaceID = "project-id"
    var parentSessionID: String? = nil, path: String? = nil, imported = false
}
