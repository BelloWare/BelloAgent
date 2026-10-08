import Foundation

// The draft marker (0.1.122): a chat whose composer holds something unsent
// shows a small pencil on its sidebar row. It follows the saved draft, not
// the keystrokes: the store tells of every committed draft write
// (`DraftWriteEvents`), which the composer makes behind the typing
// (`WorkspaceDrafts.swift`), and the set of marked chats changes, and the
// sidebar redraws, only when a chat gains or loses its draft. Drafts are kept,
// so the marker comes back with them after a relaunch. A side that was never
// kept has no saved draft by design, so it never shows one.

extension WorkspaceModel {
    /// Starts following the store's draft writes. Called once, at creation.
    func observeDraftWrites() {
        store?.draftWrites.observe { [weak self] id, holds, sequence in
            Task { @MainActor [weak self] in self?.applyDraftMark(id, holds: holds, sequence: sequence) }
        }
    }
    /// One committed write, applied in the order the store made them.
    func applyDraftMark(_ id: String, holds: Bool, sequence: Int) {
        guard sequence > max(draftMarkSequences[id] ?? 0, draftMarksRestoredAt) else { return }
        draftMarkSequences[id] = sequence
        setDraftMark(id, holds)
    }
    private func setDraftMark(_ id: String, _ holds: Bool) {
        guard draftChatIDs.contains(id) != holds else { return }
        if holds { draftChatIDs.insert(id) } else { draftChatIDs.remove(id) }
    }
    /// At launch: which saved drafts hold unsent work. A write the store made
    /// after its reading is newer and stands.
    func restoreDraftMarks() async {
        guard let store, let (ids, sequence) = try? await store.draftMarks() else { return }
        draftMarksRestoredAt = sequence
        // Every chat the reading names too: one committed just now may be
        // listed a moment later (`showsDraftMark` decides what shows).
        // One change to the sidebar for the whole reading.
        var next = draftChatIDs
        for id in Set(chats.map(\.id)).union(draftChatIDs).union(ids) where (draftMarkSequences[id] ?? 0) <= sequence {
            if ids.contains(id) { next.insert(id) } else { next.remove(id) }
        }
        if next != draftChatIDs { draftChatIDs = next }
    }
    /// Whether a chat's row shows the draft marker.
    func showsDraftMark(_ id: String) -> Bool {
        guard draftChatIDs.contains(id), let chat = record(id), !chat.isUtilityChat else { return false }
        return !isEphemeral(id) && !pendingChatIDs.contains(id)
    }
}
