import Foundation

// A message the helper refused because a skill it carries changed since it
// was chosen (`skill_changed`), was revoked (`skill_revoked`) or is gone
// (`skill_unavailable`). Only an explicit selection activates a skill, pinned
// to the content the reader chose, so the helper is right to refuse it; what
// the reader needs is a way on. The skill list is read again, each chip whose
// skill is still there and allowed is pinned to its current version, one
// whose skill is gone is taken off, and a notice says which. Nothing is sent
// again on its own: the reader's next Send is the confirmation.

extension WorkspaceModel {
    /// The helper's codes for a refused skill selection.
    nonisolated static let skillRefusalCodes: Set<String> = ["skill_changed", "skill_revoked", "skill_unavailable"]

    /// What a refused message's skills look like after the skill list is read
    /// again, and the notice that says so.
    struct SkillRefresh: Equatable {
        /// Chips pinned to their skill's current version.
        var updated: [String] = []
        /// Chips taken off: their skill is gone, or no longer allowed.
        var removed: [String] = []
        /// Chips pinned once already that were refused again: the skill is
        /// changing while it is sent.
        var again: [String] = []
        /// The skill list could not be read; nothing was changed.
        var failure: String?
        /// Whether anything is left to send.
        var sendable = true
        /// What the reader wrote for a removed skill (`/name request`) was
        /// put back in the draft's text.
        var keptArguments = false

        var notice: String {
            if let failure {
                let reason = failure.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
                return "A selected skill changed, and the skill list could not be read again (\(reason)). Remove the skill and choose it again, then press Send."
            }
            var parts: [String] = []
            let changing = again.filter { !removed.contains($0) }
            let fresh = updated.filter { !changing.contains($0) }
            if !changing.isEmpty {
                let one = changing.count == 1
                parts.append("\(Self.quoted(changing)) changed again while it was being sent, so \(one ? "it seems" : "they seem") to be changing right now. Wait until \(one ? "the skill file stops" : "the skill files stop") changing, then press Send.")
            }
            if !fresh.isEmpty {
                let one = fresh.count == 1
                parts.append("\(Self.quoted(fresh)) changed since you chose \(one ? "it" : "them").")
            }
            if !removed.isEmpty {
                let one = removed.count == 1
                parts.append("\(Self.quoted(removed)) \(one ? "is" : "are") no longer available, so \(one ? "it was" : "they were") removed from your message"
                             + (keptArguments ? "; what you wrote for \(one ? "it" : "them") is kept in the text." : "."))
            }
            if changing.isEmpty {
                if !sendable { parts.append("Add a message or choose another skill to send.") }
                else if !fresh.isEmpty { parts.append("Press Send to use the updated version\(fresh.count == 1 ? "" : "s").") }
                else if !removed.isEmpty { parts.append("Press Send to send the rest of it.") }
                else { parts.append("The selected skills are current again. Press Send to try once more.") }
            }
            return parts.joined(separator: " ")
        }

        /// Names as the notice says them: “a”, “a” and “b”, “a”, “b” and “c”.
        static func quoted(_ names: [String]) -> String {
            let quoted = names.map { "\u{201C}\($0)\u{201D}" }
            guard quoted.count > 1 else { return quoted.first ?? "" }
            return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
        }
    }

    /// The pin a chip holds: what `skillRepins` remembers of a chip it set.
    nonisolated static func skillPin(_ chip: SkillChip) -> String { chip.contentHash + "|" + chip.metadataHash }

    /// Reads the skill list again for a message the helper refused and puts
    /// the composer's chips right: each of `sent` still in the composer is
    /// pinned to its skill's current version, or taken off if the skill is
    /// gone or can no longer be selected. The draft's text, its images and
    /// its other chips stay as they are. Nothing is sent.
    func refreshRefusedSkills(_ view: SessionDisplay, sent: [SkillChip]) async -> SkillRefresh {
        await loadSkillCatalog(refresh: true, sessionID: view.id)
        // A load already on its way when the send was refused is joined, and
        // may have read the files before they changed: when it shows every
        // refused chip as current, the list is read once more.
        func stale() -> Bool {
            let entries = view.skillCatalog.entries
            return sent.allSatisfy { chip in entries.contains { $0.skill.id == chip.id && $0.skill.contentHash == chip.contentHash && $0.skill.metadataHash == chip.metadataHash } }
        }
        if view.skillCatalog.authorizes, stale() {
            await Task.yield()
            await loadSkillCatalog(refresh: true, sessionID: view.id)
        }
        var result = SkillRefresh()
        guard let workspaceID = record(view.id)?.workspaceID, view.skillCatalog.authorizes,
              view.skillCatalog.scope == skillScope(sessionID: view.id, workspaceID: workspaceID) else {
            result.failure = view.skillCatalog.notice.isEmpty ? "the skill list is unavailable" : view.skillCatalog.notice
            return result
        }
        let current = Dictionary(view.skillCatalog.entries.map { ($0.skill.id, $0.skill) }, uniquingKeysWith: { first, _ in first })
        var chips = view.skills, written: [String] = []
        for chip in sent {
            // A chip the reader took off, or chose again, since is theirs.
            guard let index = chips.firstIndex(where: { $0.id == chip.id }), chips[index] == chip else { continue }
            if view.skillRepins[chip.id] == Self.skillPin(chip) { result.again.append(chip.name) }
            guard let skill = current[chip.id], canSelectSkill(skill, view: view) else {
                chips.remove(at: index); view.skillRepins[chip.id] = nil
                result.removed.append(chip.name)
                // A `/name request` keeps the request only in its chip: it
                // stays in the draft rather than going with the chip.
                if !chip.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { written.append(chip.arguments) }
                continue
            }
            guard skill.contentHash != chip.contentHash || skill.metadataHash != chip.metadataHash else { continue }
            var pinned = skill.chip
            pinned.arguments = chip.arguments; pinned.intent = chip.intent
            chips[index] = pinned
            view.skillRepins[chip.id] = Self.skillPin(pinned)
            result.updated.append(chip.name)
        }
        if !written.isEmpty {
            view.draft = (written + (view.draft.isEmpty ? [] : [view.draft])).joined(separator: "\n\n")
            view.directCommand = false; result.keptArguments = true
        }
        if chips != view.skills || !written.isEmpty { view.skills = chips; draftChanged(view) }
        result.sendable = !view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.attachments.isEmpty || !view.skills.isEmpty
        return result
    }
}
