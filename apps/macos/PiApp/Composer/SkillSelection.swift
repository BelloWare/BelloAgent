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
    /// The longest a command name may be. A draft whose first word is longer
    /// than this is prose, and must not be scanned to its end to find out.
    static let maximumNameLength = 64
    let name: String; let arguments: String

    /// The command a draft opens with, and the text after it, without copying
    /// the draft. Whether a draft is a command at all is asked on every
    /// footer pass while a reply streams, and the answer used to cost a copy
    /// of everything the user had typed.
    static func leading(_ text: String, directInput: Bool) -> (name: String, rest: Substring)? {
        guard directInput, text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        guard let first = body.first, first.isASCII, first.isLetter || first.isNumber else { return nil }
        let name = body.prefix(maximumNameLength + 1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard !name.isEmpty, name.count <= maximumNameLength else { return nil }
        let rest = body.dropFirst(name.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return (String(name), rest)
    }
    /// Whether a draft is a command at all — all the context preview and the
    /// skill picker need to know.
    static func begins(_ text: String, directInput: Bool) -> Bool { leading(text, directInput: directInput) != nil }
    static func parse(_ text: String, directInput: Bool) -> LeadingCommand? {
        guard let found = leading(text, directInput: directInput) else { return nil }
        return LeadingCommand(name: found.name, arguments: found.rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
