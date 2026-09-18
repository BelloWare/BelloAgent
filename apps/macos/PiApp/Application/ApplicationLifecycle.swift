import AppKit

@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        if model?.hasActiveWork == true {
            let alert = NSAlert()
            alert.messageText = "Stop active work and quit?"
            alert.informativeText = "Saved chats and side conversations remain available when you reopen Bello Agent."
            alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard let model else { return .terminateNow }
        terminating = true
        let wasPreparing = model.installPreparing
        model.installPreparing = true
        Task {
            do {
                try await model.flushDrafts()
                guard await model.flushReadStates(), await model.flushProjectSidebarState() else { throw StoreError.unavailable }
                model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                model.installPreparing = wasPreparing
                model.error = "Bello Agent stayed open because your drafts or preferences could not be saved. Resolve the storage error and try quitting again. \(error.localizedDescription)"
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
