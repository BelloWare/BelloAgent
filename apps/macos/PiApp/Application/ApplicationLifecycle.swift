import AppKit

@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    private var terminating = false
    /// True while the stop-and-quit question is on screen. AppKit may ask again
    /// (a second ⌘Q, the Dock menu) before the first answer arrives.
    private var asking = false
    /// Tests drive a quit without asking AppKit to end the test host.
    var answerTermination: ((Bool) -> Void)?
    /// Asks AppKit to quit again, once Settings' unsaved edits are settled.
    var retryTermination: () -> Void = { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // History index files an earlier launch left behind, once nothing holds them.
        Task.detached(priority: .utility) { HistoryIndexFiles.removeStale() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || asking { return .terminateLater }
        guard let model else { return .terminateNow }
        // Settings first: a save under way finishes before anything else, and
        // unsaved edits are saved or discarded on purpose, never dropped by
        // the windows closing.
        let editors = model.settingsEditors.allObjects
        if editors.contains(where: \.busy) {
            model.error = "Settings are still being saved. Quit again once the save finishes."
            return .terminateCancel
        }
        if let editor = editors.first(where: \.isDirty) {
            asking = true
            Task { @MainActor [weak self] in
                let proceed = await editor.resolveForQuit()
                guard let self else { return }
                self.asking = false
                self.answer(sender, false)
                // Ask again: the next editor with edits, then active work and
                // the shutdown flush, as for any other quit.
                if proceed { DispatchQueue.main.async { [weak self] in self?.retryTermination() } }
            }
            return .terminateLater
        }
        guard model.hasActiveWork else { beginShutdown(sender, model: model); return .terminateLater }
        // A modal run loop inside AppKit's own terminate decision re-enters
        // window and application callbacks from within this one. Ask in a sheet
        // and answer through reply(toApplicationShouldTerminate:) instead.
        let alert = NSAlert()
        alert.messageText = "Stop active work and quit?"
        alert.informativeText = "Saved chats and side conversations remain available when you reopen Bello Agent."
        alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Cancel")
        asking = true
        guard let host = PiQuestion.host() else {
            // Menu-bar only: there is no window to host a sheet, and nothing is
            // mid-close, so an application-modal question is safe here.
            asking = false
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            beginShutdown(sender, model: model)
            return .terminateLater
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            guard let self else { return }
            self.asking = false
            guard response == .alertFirstButtonReturn, let model = self.model else { self.answer(sender, false); return }
            self.beginShutdown(sender, model: model)
        }
        return .terminateLater
    }

    private func beginShutdown(_ sender: NSApplication, model: WorkspaceModel) {
        // Settings edited while the stop-and-quit question was up are asked
        // about first, as at the start of any quit.
        if model.settingsEditors.allObjects.contains(where: { $0.busy || $0.isDirty }) {
            answer(sender, false)
            DispatchQueue.main.async { [weak self] in self?.retryTermination() }
            return
        }
        terminating = true
        let wasPreparing = model.installPreparing
        model.installPreparing = true
        Task {
            do {
                // Sides that were never saved end with the app; what was typed
                // into them is kept in their parents' drafts.
                try await model.moveUnsavedSideDraftsToParents()
                try await model.flushDrafts()
                guard await model.flushReadStates(), await model.flushProjectSidebarState(), await model.flushTopicChanges() else { throw StoreError.unavailable }
                // Which chat to reopen goes last: flushing the drafts can turn
                // an unsent New chat into a saved one, and then it is the chat
                // to reopen. Failing to write it is no reason to stay open.
                await model.flushSelection()
                // Saved: from here the app is going. Its helpers stop the way
                // Stop does and are waited for, so a reply cut off mid-stream
                // stays in the chat as an interrupted one.
                await model.stopHostsAndWait()
                // History indexes have files in the temporary folder.
                await model.history.releaseIndexes()
                model.shutdown()
                answer(sender, true)
            } catch {
                terminating = false
                model.installPreparing = wasPreparing
                model.error = "Bello Agent stayed open because your drafts or preferences could not be saved. Resolve the storage error and try quitting again. \(error.localizedDescription)"
                answer(sender, false)
            }
        }
    }
    private func answer(_ sender: NSApplication, _ value: Bool) {
        if let answerTermination { answerTermination(value) } else { sender.reply(toApplicationShouldTerminate: value) }
    }
}
