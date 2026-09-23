import Foundation

/// A skill a sent message used, as the helper recorded it with the message
/// (`nativeUserInput.skills` in the journal, `skills` on the display row):
/// the explicit selection the model received ahead of the message's text.
///
/// The identity and the two hashes are what the helper froze when the message
/// was sent, so they say which version the reply used. The description, scope
/// and policy are what the catalog said at that moment; helpers before 0.1.86
/// did not record them, and a reader falls back to the current catalog.
struct TranscriptSkillUse: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var path: String
    var contentHash: String
    var metadataHash: String
    var arguments: String
    var description: String? = nil
    var scope: String? = nil
    var policy: String? = nil

    /// A selection about to be sent, as its row will show it once the helper
    /// has recorded it. A row drawn before the helper answers carries these,
    /// so the one that replaces it has the same height.
    init(chip: SkillChip) {
        self.init(id: chip.id, name: chip.name, path: chip.path, contentHash: chip.contentHash, metadataHash: chip.metadataHash,
                  arguments: chip.arguments, description: chip.description, scope: chip.scope, policy: chip.policy)
    }
    init(id: String, name: String, path: String, contentHash: String, metadataHash: String, arguments: String,
         description: String? = nil, scope: String? = nil, policy: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.contentHash = contentHash; self.metadataHash = metadataHash
        self.arguments = arguments; self.description = description; self.scope = scope; self.policy = policy
    }

    /// The skills a journal's user message records. A journal is read as it
    /// is: an entry without an identity or a name is left out rather than
    /// failing the page, and a missing field reads as empty.
    static func recorded(_ value: WireValue?) -> [TranscriptSkillUse]? {
        let uses: [TranscriptSkillUse] = (value?.array ?? []).compactMap { item in
            guard let fields = item.object, let id = fields["id"]?.string, let name = fields["name"]?.string else { return nil }
            return TranscriptSkillUse(id: id, name: name, path: fields["path"]?.string ?? "",
                                      contentHash: fields["contentHash"]?.string ?? "", metadataHash: fields["metadataHash"]?.string ?? "",
                                      arguments: fields["arguments"]?.string ?? "", description: fields["description"]?.string,
                                      scope: fields["scope"]?.string, policy: fields["policy"]?.string)
        }
        return uses.isEmpty ? nil : uses
    }
}
