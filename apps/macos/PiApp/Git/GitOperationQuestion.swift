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
    private var cancelSheet: (() -> Void)?

    func start(_ request: GitCommitRequest, controller: GitController, questions: PiQuestion, window: NSWindow, repositoryName: String?) {
        task = Task { [self] in
            guard let result = await controller.checkCommit(request), !cancelled, !Task.isCancelled,
                  controller.accepts(request), result.canCommit else { pending = false; task = nil; return }
            if request.kind == .commit, !result.hasWarnings {
                dispatched = true
                await controller.submitCommit(request)
                pending = false; task = nil
                return
            }
            let asked = questions.askSheet(over: window, make: { [self] answer in
                cancelSheet = { answer(false) }
                return GitOperationSheet(request: request, preflight: result, repositoryName: repositoryName,
                    parentSize: window.contentView?.bounds.size ?? window.frame.size, answer: answer)
            }) { [self] accepted in
                guard !answered else { return }
                answered = true; cancelSheet = nil
                guard !cancelled, accepted else { pending = false; return }
                dispatched = true
                task = Task { [self] in
                    await controller.submitCommit(request, allowingWhitespace: result.hasWarnings)
                    pending = false; task = nil
                }
            }
            if !asked { pending = false }
        }
    }

    func cancel() {
        guard !cancelled, !dispatched else { return }
        cancelled = true; pending = false
        task?.cancel(); task = nil
        cancelSheet?(); cancelSheet = nil
    }
}

extension GitPanelPlace {
    func requestCommit(_ controller: GitController, context: GitController.RepositoryContext?, reword: Bool, questions: PiQuestion) {
        guard operation?.pending != true, !questions.asking, let window, controller.accepts(context),
              let request = controller.commitRequest(context: context, reword: reword) else { return }
        let operation = GitOperationQuestion()
        self.operation = operation
        operation.start(request, controller: controller, questions: questions, window: window, repositoryName: projectName)
    }
}
