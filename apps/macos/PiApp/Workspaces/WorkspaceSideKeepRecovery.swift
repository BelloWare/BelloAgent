import AppKit

/// Failed registrations remain named and actionable together. No journal bodies.
struct SideKeepIssue: Equatable, Identifiable {
    var chat: ChatRecord
    var parentTitle: String?
    var reason: String
    var id: String { chat.id }
}

extension WorkspaceModel {
    func reportSideKeepFailure(id: String, title: String, error: Error) async {
        // A late receipt for a dismissed or already registered copy is settled,
        // not a new failure. A superseded attempt cannot describe its replacement.
        if case StoreError.staleRevision = error { return }
        do {
            guard let store else { throw StoreError.unavailable }
            while true {
                let revision = sideKeepResolutionRevision
                let state = try await store.sideKeepState(id: id)
                // Another copy's report must not discard this unresolved one.
                // Re-read after any resolution, including dismissal of this
                // copy, rather than publishing a snapshot that may be stale.
                guard revision == sideKeepResolutionRevision else { continue }
                let intent: SideKeepIntent
                switch state {
                case .pending(let pending): intent = pending
                case .registered: return
                case .missing:
                    if sideKeepDismissals[id] == nil, !chats.contains(where: { $0.id == id }) {
                        self.error = "Could not add “\(title)” to saved chats. \(error.localizedDescription)"
                    }
                    return
                }
                let issue = sideKeepIssue(intent, error: error)
                sideKeepResolutionRevision &+= 1
                sideKeepIssues.removeAll { $0.id == id }
                sideKeepIssues.append(issue); sideKeepIssues.sort { $0.id < $1.id }
                return
            }
        } catch { self.error = "Could not check the saved copy of “\(title)”. \(error.localizedDescription)" }
    }

    func sideKeepIssue(_ intent: SideKeepIntent, error: Error) -> SideKeepIssue {
        let parent = intent.chat.parentSessionID.map { record($0)?.title ?? "Original chat no longer listed" }
        let reason: String
        if case StoreError.missingJournal = error {
            reason = "The file is missing. It may not have finished saving, or it may have been moved or deleted."
        } else { reason = error.localizedDescription }
        return SideKeepIssue(chat: intent.chat, parentTitle: parent, reason: reason)
    }

    /// Explicit inspection only: never bypass identity admission into a chat
    /// or start a helper for the file. File tabs keep their existing trust gates.
    @discardableResult func openSideKeepFile(_ issue: SideKeepIssue) -> FileTab? {
        guard sideKeepIssues.contains(issue), let path = issue.chat.path else { return nil }
        page = .chats
        let file = openFile(URL(fileURLWithPath: path)); file.showTop()
        return file
    }

    func showSideKeepFile(_ issue: SideKeepIssue, reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        guard sideKeepIssues.contains(issue), let path = issue.chat.path else { return }
        var url = URL(fileURLWithPath: path)
        // A missing file cannot be selected; show its nearest remaining folder.
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        reveal(url)
    }

    func dismissSideKeep(_ issue: SideKeepIssue, over window: NSWindow) {
        guard sideKeepIssues.contains(issue) else { return }
        let asked = questions.askSheet(over: window, make: { answer in
            SideKeepDismissSheet(issue: issue, parentSize: window.contentView?.bounds.size ?? window.frame.size, answer: answer)
        }) { [weak self] accepted in
            guard let self, accepted else { return }
            let dismissal = UUID()
            self.sideKeepDismissals[issue.id, default: []].insert(dismissal)
            Task {
                do {
                    guard let store = self.store else { throw StoreError.unavailable }
                    try await store.dismissSideKeep(issue.chat)
                    self.sideKeepResolutionRevision &+= 1
                    self.sideKeepIssues.removeAll { $0.chat == issue.chat }
                } catch {
                    self.sideKeepDismissals[issue.id]?.remove(dismissal)
                    if self.sideKeepDismissals[issue.id]?.isEmpty == true { self.sideKeepDismissals.removeValue(forKey: issue.id) }
                    self.error = "Could not dismiss “\(issue.chat.title)”. \(error.localizedDescription)"
                }
            }
        }
        if !asked { error = PiQuestion.busyNotice }
    }
}
