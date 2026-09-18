import Foundation

struct SkillChip: Codable, Sendable, Hashable, Identifiable {
    var id: String; var name: String; var path: String; var contentHash: String; var metadataHash: String
    var arguments = ""; var intent = "picker"
    var sourceCharacters: Int?
    var wire: WireValue { .object(["id": .string(id), "contentHash": .string(contentHash), "metadataHash": .string(metadataHash), "arguments": .string(arguments), "intent": .string(intent)]) }
}
struct SkillDescriptor: Codable, Sendable, Identifiable {
    var id: String; var name: String; var path: String; var description: String; var scope: String
    var contentHash: String; var metadataHash: String; var policy: String; var reasons: [String]
    var missingDependencies: [[String: String]]
    var sourceCharacters: Int?
    var canSelect: Bool { ["implicitAllowed", "explicitOnly"].contains(policy) && missingDependencies.isEmpty }
    var chip: SkillChip { SkillChip(id: id, name: name, path: path, contentHash: contentHash, metadataHash: metadataHash, sourceCharacters: sourceCharacters) }
}
struct LeadingCommand: Equatable {
    static let reserved = ["side", "fork", "debug", "compact"]
    let name: String; let arguments: String
    static func parse(_ text: String, directInput: Bool) -> LeadingCommand? {
        guard directInput, text.hasPrefix("/"), let first = text.dropFirst().first, first.isASCII && (first.isLetter || first.isNumber) else { return nil }
        let name = String(text.dropFirst().prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        guard !name.isEmpty, name.count <= 64 else { return nil }
        let rest = text.dropFirst(name.count + 1)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return LeadingCommand(name: name, arguments: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
