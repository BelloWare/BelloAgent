import AppKit
import UniformTypeIdentifiers

/// What came back from a question asked in the middle of a task.
enum ChatAnswer: Equatable, Sendable {
    case yes
    case no
    /// Another question was already on screen, so this one was never asked.
    case busy
}

/// A question a chat has to ask before it acts.
struct ChatQuestion: Equatable, Sendable {
    let title: String
    let detail: String
    /// The label on the button that goes ahead.
    let action: String
}

/// The one way the app asks a question or offers a file chooser: on a sheet
/// over a window, never in a modal run loop.
///
/// A modal loop stops the main thread. Every other window freezes, git reads
/// and terminal output stop being delivered, and AppKit re-enters its own
/// window and application callbacks from inside the one that is running. The
/// answer arrives through a completion or a continuation instead, so a caller
/// reads exactly as it did before with an `await` in front of it.
///
/// One question at a time per asker: a second request while one is up is
/// refused rather than stacked behind it, so an error cannot bury the question
/// the reader is already answering. With no window to attach a sheet to — a
/// menu-bar-only launch, a closed main window — the alert runs
/// application-modal, which is all that is left and is safe there because
/// nothing is mid-decision.
///
/// `shared` is the app-wide asker, used by the screens that keep no state of
/// their own: the inspectors, the updater, the folder chooser. A chat holds
/// its own (`WorkspaceModel.questions`) and so does the Changes panel, so a
/// question about one is only ever refused by another question about the same
/// thing.
@MainActor final class PiQuestion: ObservableObject {
    static let shared = PiQuestion()

    /// True while a question of this asker's is on screen.
    @Published private(set) var asking = false
    /// The window the last sheet went onto: a panel takes its own question
    /// down with it, and a test can see where the sheet was attached.
    private(set) weak var askedIn: NSWindow?

    /// What to say when a caller's question was refused because one is up.
    static let busyNotice = "Answer the question already on screen first."

    // MARK: Test seams
    //
    // Each of these answers a question without putting one on the screen, and
    // each is nil (or the real presenter) in the app. Nothing else in this
    // type branches on whether a test is running.

    /// Answers a `ChatQuestion` — the form whose title and detail a test reads.
    var answer: ((ChatQuestion) -> Bool)?
    /// Answers a prepared `NSAlert`, for callers that build their own.
    var answerAlert: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Answers a file chooser; an empty array is a cancellation.
    var chooseFiles: (() -> [URL])?
    /// Answers the single-file chooser, given the message it would have shown.
    var chooseFile: ((String) -> URL?)?
    /// Answers the one-line text question, given its title and current value.
    var enterText: ((String, String) -> String?)?
    /// How an alert reaches the screen, so a test can drive a real sheet's
    /// completion by hand without an event loop.
    typealias Present = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    var present: Present = { alert, window, answer in alert.beginSheetModal(for: window, completionHandler: answer) }

    // MARK: Which window the question belongs to

    /// The caller's own window wins. Then, for a question about one chat, the
    /// window actually showing that chat's composer, so with two windows open
    /// the question appears over the conversation it is about. Then the key
    /// window, the main window, and finally any window that can take a sheet.
    ///
    /// A window already wearing a sheet cannot take another; a sheet itself
    /// can host one, which is how Settings asks from inside its own sheet.
    static func host(_ preferred: NSWindow? = nil, showing sessionID: String? = nil) -> NSWindow? {
        func free(_ window: NSWindow) -> Bool { window.isVisible && window.attachedSheet == nil }
        // A window the caller named is taken as given: the only thing that can
        // stop a sheet going onto it is a sheet already there.
        if let preferred, preferred.attachedSheet == nil { return preferred }
        if let sessionID {
            let owners = NSApp.windows.filter { free($0) && $0.canBecomeMain && $0.sheetParent == nil }
            if let owner = owners.first(where: { window in
                window.contentView.map { shows(sessionID, in: $0) } == true
            }) { return owner }
        }
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let candidate, free(candidate) { return candidate }
        }
        return NSApp.windows.first { free($0) && ($0.canBecomeMain || $0.isSheet) }
    }
    private static func shows(_ sessionID: String, in view: NSView) -> Bool {
        if let editor = view as? ComposerTextView { return editor.sessionID == sessionID && !editor.isHiddenOrHasHiddenAncestor }
        return view.subviews.contains { shows(sessionID, in: $0) }
    }

    /// The window went away under the question; nothing was chosen.
    func cancel() { asking = false }

    // MARK: Asking

    /// Puts `alert` on a sheet and calls back with what the reader pressed.
    /// False when a question of this asker's is already on screen, so the
    /// caller can say why nothing happened.
    @discardableResult
    func ask(_ alert: NSAlert, over window: NSWindow? = nil, about sessionID: String? = nil,
             answered: @escaping (NSApplication.ModalResponse) -> Void) -> Bool {
        if let answerAlert { answered(answerAlert(alert)); return true }
        guard !asking else { return false }
        guard let host = Self.host(window, showing: sessionID) else { answered(alert.runModal()); return true }
        asking = true; askedIn = host
        present(alert, host) { [weak self] response in
            MainActor.assumeIsolated {
                self?.asking = false
                answered(response)
            }
        }
        return true
    }

    /// The awaited form of the same question. `.cancel` when one is already up.
    func ask(_ alert: NSAlert, over window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            let asked = ask(alert, over: window) { continuation.resume(returning: $0) }
            if !asked { continuation.resume(returning: .cancel) }
        }
    }

    /// A two-button question. True when the reader chose to go ahead.
    func confirm(_ title: String, _ detail: String, action: String = "Continue", cancel: String = "Cancel",
                 destructive: Bool = false, over window: NSWindow? = nil) async -> Bool {
        await ask(Self.alert(title: title, detail: detail, action: action, cancel: cancel, destructive: destructive),
                  over: window) == .alertFirstButtonReturn
    }

    /// A chat's own question, over the window showing that chat. False when
    /// another is already up, so the caller can say why nothing happened.
    @discardableResult
    func ask(_ question: ChatQuestion, about sessionID: String? = nil, destructive: Bool = false,
             answered: @escaping (Bool) -> Void) -> Bool {
        if let answer { answered(answer(question)); return true }
        let alert = Self.alert(title: question.title, detail: question.detail, action: question.action,
                               cancel: "Cancel", destructive: destructive, warn: false)
        return ask(alert, about: sessionID) { answered($0 == .alertFirstButtonReturn) }
    }

    /// The awaited form, for a question that comes up in the middle of a task:
    /// the task suspends on the sheet and resumes with the answer instead of
    /// stopping the run loop for every other chat while it is up.
    func confirm(_ question: ChatQuestion, about sessionID: String? = nil, destructive: Bool = false) async -> ChatAnswer {
        await withCheckedContinuation { continuation in
            let asked = ask(question, about: sessionID, destructive: destructive) { continuation.resume(returning: $0 ? .yes : .no) }
            if !asked { continuation.resume(returning: .busy) }
        }
    }

    /// Asks for one line of text, seeded with what is there now. Text longer
    /// than `limit` bytes is dropped rather than truncated.
    @discardableResult
    func askText(_ title: String, value: String, action: String, limit: Int, about sessionID: String? = nil,
                 entered: @escaping (String) -> Void) -> Bool {
        if let enterText { if let text = enterText(title, value), text.utf8.count <= limit { entered(text) }; return true }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 480, height: 28)
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return ask(alert, about: sessionID) { response in
            guard response == .alertFirstButtonReturn, field.stringValue.utf8.count <= limit else { return }
            entered(field.stringValue)
        }
    }

    // MARK: Choosing files

    /// Where to write a file, or nil when the reader cancelled or a question
    /// of this asker's is already on screen.
    func save(_ panel: NSSavePanel, over window: NSWindow? = nil) async -> URL? {
        if let chooseFiles { return chooseFiles().first }
        guard let response = await run(panel, over: window, about: nil) else { return nil }
        return response == .OK ? panel.url : nil
    }

    /// What the reader chose, or an empty array when they cancelled.
    func open(_ panel: NSOpenPanel, over window: NSWindow? = nil) async -> [URL] {
        if let chooseFiles { return chooseFiles() }
        guard let response = await run(panel, over: window, about: nil) else { return [] }
        return response == .OK ? panel.urls : []
    }

    /// Chooses one folder or file. `directories` picks a working directory;
    /// otherwise a single file to read.
    @discardableResult
    func chooseOne(message: String, directories: Bool, about sessionID: String? = nil,
                   _ chosen: @escaping (URL) -> Void) -> Bool {
        if let chooseFile { if let url = chooseFile(message) { chosen(url) }; return true }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return runPanel(panel, over: nil, about: sessionID) { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url)
        }
    }

    /// Chooses image files to attach.
    @discardableResult
    func chooseImageFiles(about sessionID: String? = nil, _ chosen: @escaping ([URL]) -> Void) -> Bool {
        if let chooseFiles { chosen(chooseFiles()); return true }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to attach to this message."
        return runPanel(panel, over: nil, about: sessionID) { response in
            if response == .OK { chosen(panel.urls) }
        }
    }

    /// A panel on a sheet, or application-modal when nothing can host it.
    /// False when a question of this asker's is already on screen.
    @discardableResult
    private func runPanel(_ panel: NSSavePanel, over window: NSWindow?, about sessionID: String?,
                          answered: @escaping (NSApplication.ModalResponse) -> Void) -> Bool {
        guard !asking else { return false }
        guard let host = Self.host(window, showing: sessionID) else { answered(panel.runModal()); return true }
        asking = true; askedIn = host
        panel.beginSheetModal(for: host) { [weak self] response in
            MainActor.assumeIsolated {
                self?.asking = false
                answered(response)
            }
        }
        return true
    }

    /// The awaited form of `runPanel`; nil when the question was refused.
    private func run(_ panel: NSSavePanel, over window: NSWindow?, about sessionID: String?) async -> NSApplication.ModalResponse? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse?, Never>) in
            let asked = runPanel(panel, over: window, about: sessionID) { continuation.resume(returning: $0) }
            if !asked { continuation.resume(returning: nil) }
        }
    }

    /// The shape every two-button question takes: the action first, Cancel
    /// second, and a destructive action marked as one.
    static func alert(title: String, detail: String, action: String, cancel: String,
                      destructive: Bool, warn: Bool = true) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if destructive && warn { alert.alertStyle = .warning }
        let confirmButton = alert.addButton(withTitle: action)
        if destructive { confirmButton.hasDestructiveAction = true }
        alert.addButton(withTitle: cancel)
        return alert
    }
}
