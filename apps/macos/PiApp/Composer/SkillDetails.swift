import Foundation

// What a skill pill says about its skill — in the composer, where a token is
// about to be sent, and in a sent message, where it was — worked out without
// any view. The pill, its hover card, its popover and its accessibility label
// all read the same `SkillDetail`.

/// The words a pill shows after its name: the arguments on one line, cut
/// short. The whole text is in the card and the popover.
enum SkillPillLabel {
    static let argumentLimit = 24
    static func arguments(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard line.count > argumentLimit else { return line }
        // Cut at the last word that fits, unless that throws most of it away.
        var kept = line.prefix(argumentLimit - 1)
        if let space = kept.lastIndex(of: " "), kept.distance(from: kept.startIndex, to: space) >= argumentLimit / 2 { kept = kept[..<space] }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }
    /// What a copied pill puts on the pasteboard.
    static func copied(_ name: String) -> String { "/" + name }
}

/// Where a skill comes from, in words.
struct SkillPlace: Equatable, Sendable {
    enum Kind: String, Sendable { case project, personal, codex, added, file }
    let kind: Kind
    /// The skills folder the skill was found in, in full.
    let root: String

    var title: String {
        switch kind {
        case .project: "Project skill"
        case .personal: "Your skill"
        case .codex: "Codex skill"
        case .added: "Added skill folder"
        case .file: "Skill file"
        }
    }
    /// The folder, short: a project's is named after the project, the rest
    /// are shortened with a tilde.
    var location: String {
        guard !root.isEmpty else { return "" }
        let parts = (root as NSString).pathComponents
        if kind == .project, parts.count >= 3, parts[parts.count - 2] == ".agents" {
            return NSString.path(withComponents: Array(parts.suffix(3)))
        }
        return (root as NSString).abbreviatingWithTildeInPath
    }
    /// One line for the card and for assistive technology.
    var sentence: String { location.isEmpty ? title : title + " · " + location }
    /// The file, from its skills folder down: "review/SKILL.md".
    func file(_ path: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return String(path.dropFirst(root.count + 1))
    }

    /// The helper's scopes are "project", "user" (Codex's skills and your
    /// own ~/.agents/skills alike) and "approved additional"; the root a skill
    /// was found under tells the two user folders apart. Records without a
    /// scope are placed from their path.
    static func of(scope: String?, path: String, sourceRoot: String? = nil,
                   home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> SkillPlace {
        let personal = (home as NSString).appendingPathComponent(".agents/skills")
        let root = sourceRoot.map { ($0 as NSString).standardizingPath } ?? Self.root(of: path) ?? ""
        func isPersonal() -> Bool { (root.isEmpty ? path : root).hasPrefix(personal) }
        switch scope {
        case "project": return SkillPlace(kind: .project, root: root)
        case "user": return SkillPlace(kind: isPersonal() ? .personal : .codex, root: root)
        case "approved additional": return SkillPlace(kind: .added, root: root)
        default:
            if path.hasPrefix(personal + "/") { return SkillPlace(kind: .personal, root: root) }
            if path.contains("/.codex/skills/") { return SkillPlace(kind: .codex, root: root) }
            if path.contains("/.agents/skills/") { return SkillPlace(kind: .project, root: root) }
            return SkillPlace(kind: .file, root: path.isEmpty ? "" : (path as NSString).deletingLastPathComponent)
        }
    }
    /// The skills folder a path sits in: everything up to its last `skills`
    /// component, which every discovery root ends with.
    static func root(of path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard let index = parts.lastIndex(of: "skills"), index > 0, index < parts.count - 1 else { return nil }
        return NSString.path(withComponents: Array(parts[...index]))
    }
}

/// A skill's invocation policy, in words.
enum SkillPolicyWords {
    static func title(_ policy: String?) -> String? {
        switch policy {
        case "explicitOnly": "Explicit only"
        case "implicitAllowed": "Implicit allowed"
        case "disabled": "Disabled"
        case "needsAttention": "Needs attention"
        default: nil
        }
    }
    static func detail(_ policy: String?) -> String? {
        switch policy {
        case "explicitOnly": "Runs only when you select it"
        case "implicitAllowed": "The model may also load it on its own when it is relevant"
        case "disabled": "Turned off in Bello Agent"
        case "needsAttention": "Its metadata could not be read; fix the file before using it"
        default: nil
        }
    }
}

/// How a pill's version compares with the skill as it is installed now.
enum SkillRevision: Equatable, Sendable {
    /// The current skill list is still being read.
    case checking
    /// There is no current list to compare with.
    case unknown
    case current
    /// Installed with different content: `now` is the current short version.
    case changed(now: String)
    /// Not in the current list at all.
    case removed

    /// A pill's version against the catalog. A partial or failed catalog can
    /// say a skill changed, never that it is gone: the source that would
    /// have listed it may be the one that failed.
    static func of(id: String, contentHash: String, in catalog: SkillCatalog) -> SkillRevision {
        if let match = catalog.entries.first(where: { $0.skill.id == id })?.skill {
            return match.contentHash == contentHash ? .current : .changed(now: SkillDetail.shortVersion(match.contentHash))
        }
        switch catalog.state {
        case .ready: return .removed
        // A read under way says so; a list nobody has asked for yet is unknown.
        case .loading: return catalog.notice.isEmpty && catalog.entries.isEmpty ? .unknown : .checking
        case .failed, .partial: return .unknown
        }
    }
}

/// Everything a pill, its card and its popover show.
struct SkillDetail: Equatable, Sendable {
    enum Context: Equatable, Sendable {
        /// A token in the composer, not yet sent.
        case composer
        /// A pill in a message that was sent.
        case sent
    }
    var context: Context
    var id: String
    var name: String
    var description: String
    var arguments: String
    var path: String
    var place: SkillPlace
    var policy: String?
    var contentHash: String
    var revision: SkillRevision

    static func shortVersion(_ hash: String) -> String { String(hash.prefix(8)) }
    var version: String { Self.shortVersion(contentHash) }
    var policyTitle: String? { SkillPolicyWords.title(policy) }
    var policyDetail: String? { SkillPolicyWords.detail(policy) }
    var shortArguments: String { SkillPillLabel.arguments(arguments) }

    static func composer(_ chip: SkillChip, catalog: SkillCatalog) -> SkillDetail {
        let current = catalog.entries.first { $0.skill.id == chip.id }?.skill
        return SkillDetail(context: .composer, id: chip.id, name: chip.name,
                           description: current?.description ?? chip.description ?? "", arguments: chip.arguments, path: chip.path,
                           place: .of(scope: chip.scope ?? current?.scope, path: chip.path, sourceRoot: chip.sourceRoot ?? current?.sourceRoot),
                           policy: current?.policy ?? chip.policy, contentHash: chip.contentHash,
                           revision: .of(id: chip.id, contentHash: chip.contentHash, in: catalog))
    }
    /// A sent message's skill: what was recorded when it was sent comes
    /// first, since that is what the reply used; the current catalog fills in
    /// what older helpers did not record.
    static func sent(_ use: TranscriptSkillUse, catalog: SkillCatalog) -> SkillDetail {
        let current = catalog.entries.first { $0.skill.id == use.id }?.skill
        return SkillDetail(context: .sent, id: use.id, name: use.name,
                           description: use.description ?? current?.description ?? "", arguments: use.arguments, path: use.path,
                           place: .of(scope: use.scope ?? current?.scope, path: use.path, sourceRoot: current?.sourceRoot),
                           policy: use.policy ?? current?.policy, contentHash: use.contentHash,
                           revision: .of(id: use.id, contentHash: use.contentHash, in: catalog))
    }

    /// The line that says how this version compares with what is installed.
    var revisionNote: (text: String, warns: Bool)? {
        switch (context, revision) {
        case (.sent, .changed): ("Changed since this message: the reply used the earlier version", true)
        case (.sent, .removed): ("No longer installed: this skill is not in the current skill list", true)
        case (.sent, .current): ("Unchanged since this message", false)
        case (.sent, .checking): ("Checking the current skill list…", false)
        case (.composer, .changed): ("Changed since you selected it. Remove it and select it again to send the current version.", true)
        case (.composer, .removed): ("No longer installed. Remove it before sending.", true)
        default: nil
        }
    }

    /// The pill's name for assistive technology.
    var accessibilityLabel: String { "Skill \(name), explicit for this message" }
    /// What the hover card shows, for readers who never hover.
    var accessibilityHelp: String {
        var parts: [String] = []
        if !description.isEmpty { parts.append(description) }
        parts.append(place.sentence)
        if !arguments.isEmpty { parts.append("Arguments: " + arguments) }
        if let note = revisionNote, note.warns { parts.append(note.text) }
        return parts.joined(separator: ". ")
    }
}
