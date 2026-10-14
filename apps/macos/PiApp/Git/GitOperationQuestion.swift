import AppKit
import GitView

/// One preparation/question per panel. Neither a late answer nor a double
/// activation can submit it twice, and moving or hiding its panel cancels it.
@MainActor final class GitOperationQuestion {
    private(set) var pending = true
    private var cancelled = false
    private var answered = false
    private var dispatched = false
    private(set) var task: Task<Void, Never>?
    private var alert: NSAlert?

    func start(_ request: GitCommitRequest, controller: GitController, questions: PiQuestion, window: NSWindow) {
        task = Task { [self] in
            guard let result = await controller.checkCommit(request), !cancelled, !Task.isCancelled,
                  controller.accepts(request), result.canCommit else { pending = false; task = nil; return }
            if request.kind == .commit, !result.hasWarnings {
                dispatched = true
                await controller.submitCommit(request)
                pending = false; task = nil
                return
            }
            let alert = Self.alert(for: request, preflight: result)
            self.alert = alert
            let asked = questions.ask(alert, over: window) { [self] response in
                guard !answered else { return }
                answered = true
                guard !cancelled, response == .alertFirstButtonReturn else { pending = false; return }
                dispatched = true
                task = Task { [self] in
                    await controller.submitCommit(request, allowingWhitespace: result.hasWarnings)
                    pending = false; task = nil
                }
            }
            if !asked { pending = false }
        }
    }

    static func alert(for request: GitCommitRequest, preflight: GitCommitPreflight) -> NSAlert {
        var lines = [request.target.map { "Target: " + $0.description }, request.scopeDescription,
                     "Repository: " + request.root, "Message: " + String(request.message.prefix(500))].compactMap { $0 }
        if request.signOff { lines.append("Add Signed-off-by using the Git committer identity.") }
        if request.kind != .commit { lines.append("This replaces the last commit. Published history may need coordination with collaborators.") }
        if preflight.hasWarnings { lines.append("Git check warnings:\n" + String(preflight.detail.prefix(1_500))) }
        return PiQuestion.alert(title: request.kind == .commit ? "Commit with Git check warnings?" : "\(request.kind.title) the last commit?",
                                detail: lines.joined(separator: "\n\n"), action: request.kind.title, cancel: "Cancel",
                                destructive: request.kind != .commit, cancelIsDefault: true)
    }

    func cancel() {
        guard !cancelled, !dispatched else { return }
        cancelled = true; pending = false
        task?.cancel(); task = nil
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
    }
}

extension GitPanelPlace {
    func requestCommit(_ controller: GitController, context: GitController.RepositoryContext?, reword: Bool, questions: PiQuestion) {
        guard operation?.pending != true, !questions.asking, let window, controller.accepts(context),
              let request = controller.commitRequest(context: context, reword: reword) else { return }
        let operation = GitOperationQuestion()
        self.operation = operation
        operation.start(request, controller: controller, questions: questions, window: window)
    }
}
