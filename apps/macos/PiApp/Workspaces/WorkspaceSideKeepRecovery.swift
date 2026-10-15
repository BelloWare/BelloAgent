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
        if let intent = try? await store?.get(SideKeepIntent.self, kind: "side-keep", id: id) {
            let issue = sideKeepIssue(intent, error: error)
            sideKeepResolutionRevision &+= 1
            sideKeepIssues.removeAll { $0.id == id }
            sideKeepIssues.append(issue); sideKeepIssues.sort { $0.id < $1.id }
        } else { self.error = "Could not add “\(title)” to saved chats. \(error.localizedDescription)" }
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
            Task {
                do {
                    guard let store = self.store else { throw StoreError.unavailable }
                    try await store.dismissSideKeep(issue.chat)
                    self.sideKeepResolutionRevision &+= 1
                    self.sideKeepIssues.removeAll { $0 == issue }
                } catch { self.error = "Could not dismiss “\(issue.chat.title)”. \(error.localizedDescription)" }
            }
        }
        if !asked { error = PiQuestion.busyNotice }
    }
}
