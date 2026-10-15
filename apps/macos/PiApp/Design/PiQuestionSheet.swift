import AppKit

/// One custom question's lifetime, including AppKit's closing animation.
/// Late or repeated answers cannot act again. Closing the parent cancels.
@MainActor final class PiQuestionPresentation {
    private var content: NSView?
    private var sheet: PiSheetWindow?
    private var result: Bool?
    private var finished = false
    private var parentObserver: NSObjectProtocol?
    var onFinished: ((Bool) -> Void)?

    init(make: (@escaping (Bool) -> Void) -> NSView) {
        content = make { [weak self] in self?.respond($0) }
    }

    func present(on parent: NSWindow, using presenter: ((NSView, NSWindow, @escaping (Bool) -> Void) -> Void)?) {
        guard let content else { return }
        if let presenter {
            presenter(content, parent) { [weak self] in self?.respond($0) }
            return
        }
        let sheet = PiSheetWindow(content: content,
            inherited: PiSheetWindowInherited(reduceMotion: parent.contentView?.piReducesMotion ?? false, enabled: true),
            close: { [weak self] in self?.respond(false) })
        self.sheet = sheet
        // An owner can go away during the closing animation. The sheet
        // retains its presentation until release; finish breaks this cycle.
        sheet.onEnded = { [self] _ in finish() }
        parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        sheet.present(on: parent)
    }

    func respond(_ accepted: Bool) {
        guard result == nil, !finished else { return }
        result = accepted
        if let sheet { sheet.end(animated: true, requested: true) }
        else { finish() }
    }

    /// The owner/window going away revokes an answer even while the sheet is
    /// sliding closed. No action has been dispatched until finish calls back.
    func cancel() {
        guard !finished else { return }
        result = false
        if let sheet { sheet.end(animated: false, requested: true) }
        else { finish() }
    }

    private func finish() {
        guard !finished else { return }
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        finished = true; content = nil; sheet = nil
        let completed = onFinished; onFinished = nil
        completed?(result ?? false)
    }
}
