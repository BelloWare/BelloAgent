import AppKit
import Combine

/// One shell of a project, kept alive while hidden so a toggled panel, or
/// another terminal chosen and then this one again, returns to the same
/// session. The view is re-parented when it shows again.
@MainActor final class TerminalSession: ObservableObject {
    let workspaceID: String
    /// Which terminal of the project this is: the same through a restart.
    let id: UUID
    /// "Terminal N": numbered per project, never reused while the app runs.
    let number: Int
    /// Bumped by each restart, which makes a new session in this one's place.
    let generation: Int
    let emulator = TerminalEmulator(columns: 100, rows: 24)
    let view: TerminalView
    let process = PseudoTerminal()
    /// The title the shell sets with escape sequences. A name the reader
    /// gave the terminal is kept apart, in `customName`, and wins.
    @Published var shellTitle = ""
    /// The reader's own name for the terminal; nil for "Terminal N".
    @Published fileprivate(set) var customName: String? { didSet { view.accessibilityName = displayName } }
    @Published var exited = false
    @Published var failure: String?
    let directory: String
    var displayName: String { customName ?? "Terminal \(number)" }

    init(workspaceID: String, directory: String, id: UUID = UUID(), number: Int = 1, customName: String? = nil, generation: Int = 0) {
        self.workspaceID = workspaceID; self.directory = directory
        self.id = id; self.number = number; self.customName = customName; self.generation = generation
        view = TerminalView(emulator: emulator)
        view.accessibilityName = displayName
        emulator.onOutput = { [weak self] data in self?.process.write(data) }
        emulator.onTitleChange = { [weak self] title in self?.shellTitle = title }
        // `cat` on a binary file writes thousands of BEL bytes. Ringing once per
        // byte costs the main thread seconds and sounds like an alarm, so the
        // bell is coalesced the way every terminal coalesces it.
        emulator.onBell = { [weak self] in self?.ringBell() }
        view.onInput = { [weak self] data in self?.process.write(data) }
        view.onResize = { [weak self] columns, rows in self?.process.resize(columns: columns, rows: rows) }
        process.onData = { [weak self] data in
            guard let self else { return }
            self.emulator.feed(data)
            self.view.refresh()
        }
        process.onExit = { [weak self] _ in self?.exited = true; self?.view.refresh() }
        process.onNotice = { [weak self] in self?.failure = $0 }
        emulator.onTextLimit = { [weak self] in self?.failure = "A terminal character exceeded the 64-byte combining-mark limit and was replaced with �." }
        start()
    }

    func start() {
        exited = false; failure = nil
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"; environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TERM_PROGRAM"] = "BelloAgent"; environment["TERM_PROGRAM_VERSION"] = ReleaseConfiguration.current.version
        environment["BELLO_AGENT"] = "1"
        // Provider credentials never reach the shell; the app only passes its own login environment.
        for key in environment.keys where key.hasPrefix("LITELLM") || key.hasSuffix("_API_KEY") { environment.removeValue(forKey: key) }
        do {
            try process.start(executable: shell, arguments: ["-" + (shell as NSString).lastPathComponent, "-l"], environment: environment, directory: directory, columns: emulator.columns, rows: emulator.rows)
        } catch {
            failure = error.localizedDescription; exited = true
        }
    }

    /// Bells actually rung, for the test that feeds a binary file's worth of them.
    private(set) var bellsRung = 0
    private var lastBell = -Double.greatestFiniteMagnitude
    private static let bellInterval = 0.25
    private func ringBell() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBell >= Self.bellInterval else { return }
        lastBell = now; bellsRung += 1
        NSSound.beep()
    }

    /// Gives the shell the keyboard: now if its view is in a window, else as
    /// soon as the panel puts it in one. The panel asks right after swapping
    /// sessions (another project, Restart), which can be before SwiftUI has
    /// added the new view; asking only then used to leave the keyboard nowhere.
    func focus() {
        if let window = view.window { window.makeFirstResponder(view) } else { view.focusWhenInWindow = true }
    }
    func applyColors() { view.needsDisplay = true }
}

/// Every project's terminals: an ordered list per project, which one is
/// shown, and the next number to give a new one.
@MainActor final class TerminalRegistry: ObservableObject {
    static let shared = TerminalRegistry()
    struct Project {
        var sessions: [TerminalSession] = []
        var selectedID: UUID?
        var nextNumber = 1
    }
    @Published private(set) var projects: [String: Project] = [:]
    /// Projects with at least one shell, for tests and for the panel's bookkeeping.
    var openWorkspaceIDs: Set<String> { Set(projects.filter { !$0.value.sessions.isEmpty }.keys) }
    func sessions(for workspaceID: String) -> [TerminalSession] { projects[workspaceID]?.sessions ?? [] }
    func selected(for workspaceID: String) -> TerminalSession? {
        guard let project = projects[workspaceID] else { return nil }
        return project.sessions.first { $0.id == project.selectedID } ?? project.sessions.first
    }
    func find(_ id: UUID, in workspaceID: String) -> TerminalSession? { projects[workspaceID]?.sessions.first { $0.id == id } }
    /// The terminal the panel shows for a project. A project shown for the
    /// first time gets Terminal 1; one whose terminals were all closed stays
    /// empty until the reader asks for a new one.
    @discardableResult
    func ensureInitialSession(for workspace: WorkspaceRecord) -> TerminalSession? {
        if projects[workspace.id] != nil { return selected(for: workspace.id) }
        return create(for: workspace)
    }
    /// The project's shown terminal, starting one if it has none.
    func session(for workspace: WorkspaceRecord) -> TerminalSession { ensureInitialSession(for: workspace) ?? create(for: workspace) }
    /// A new terminal for the project, shown at once.
    @discardableResult
    func create(for workspace: WorkspaceRecord) -> TerminalSession {
        var project = projects[workspace.id] ?? Project()
        let session = TerminalSession(workspaceID: workspace.id, directory: workspace.path, number: project.nextNumber)
        project.nextNumber += 1
        project.sessions.append(session); project.selectedID = session.id
        projects[workspace.id] = project
        return session
    }
    func select(_ id: UUID, in workspaceID: String) {
        guard var project = projects[workspaceID], project.sessions.contains(where: { $0.id == id }), project.selectedID != id else { return }
        project.selectedID = id; projects[workspaceID] = project
    }
    /// Longest name a terminal can be given, in characters.
    static let nameLimit = 64
    /// Gives a terminal the reader's name: trimmed, at most `nameLimit`
    /// characters, and empty for its "Terminal N" name back.
    func rename(_ id: UUID, in workspaceID: String, to name: String) {
        guard let session = find(id, in: workspaceID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
        session.customName = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.nameLimit))
    }
    /// A fresh shell in this terminal's place: same name and number, new
    /// emulator and scrollback. Only that terminal; nothing else changes.
    /// Nil when that terminal, at that generation, is no longer there.
    @discardableResult
    func restart(_ id: UUID, in workspaceID: String, generation: Int) -> TerminalSession? {
        guard var project = projects[workspaceID], let index = project.sessions.firstIndex(where: { $0.id == id }),
              project.sessions[index].generation == generation else { return nil }
        let old = project.sessions[index]
        let fresh = TerminalSession(workspaceID: workspaceID, directory: old.directory, id: old.id, number: old.number,
                                    customName: old.customName, generation: old.generation + 1)
        project.sessions[index] = fresh
        projects[workspaceID] = project
        end(old)
        return fresh
    }
    /// Ends one terminal and gives up its output. The one after it is shown,
    /// or the one before; the shown terminal stays shown when another closes.
    func close(_ id: UUID, in workspaceID: String, generation: Int) {
        guard var project = projects[workspaceID], let index = project.sessions.firstIndex(where: { $0.id == id }),
              project.sessions[index].generation == generation else { return }
        let old = project.sessions.remove(at: index)
        if project.selectedID == id {
            project.selectedID = project.sessions.isEmpty ? nil : project.sessions[min(index, project.sessions.count - 1)].id
        }
        projects[workspaceID] = project
        end(old)
    }
    /// Ends every shell of a project and gives up their scrollback. A project
    /// that is no longer configured must not keep shells and their history
    /// for the rest of the app's life.
    func close(workspaceID: String) {
        guard let project = projects.removeValue(forKey: workspaceID) else { return }
        for session in project.sessions { end(session) }
    }
    /// Ends every shell, on the way out of the app.
    func shutdown() {
        let all = projects.values.flatMap(\.sessions)
        projects.removeAll()
        for session in all { end(session) }
    }
    private func end(_ session: TerminalSession) { session.process.terminate(); session.view.removeFromSuperview() }

    // MARK: Asking before ending a shell

    /// True while a restart or close question is up, so repeated clicks ask once.
    private(set) var asking = false
    enum Ending { case restart, close }
    /// The question asked before ending a live shell.
    static func endingQuestion(_ ending: Ending, name: String, project: String, directory: String) -> (title: String, detail: String, action: String) {
        let ends = "This ends the shell in this terminal and may interrupt a command it is running."
        switch ending {
        case .restart:
            return ("Restart “\(name)” in “\(project)”?", ends + " Its scrollback is removed, and a new shell starts in \(directory).", "Restart Terminal")
        case .close:
            return ("Close “\(name)” in “\(project)”?", ends + " Its output is removed. The project's other terminals keep running.", "Close Terminal")
        }
    }
    /// Restarts or closes one terminal, the one captured when asked. A live
    /// shell asks first, with Cancel the default; one that has exited goes
    /// at once. Nothing happens if that terminal was closed or restarted
    /// meanwhile. Returns the terminal now in its place, if any.
    @discardableResult
    func requestEnding(_ ending: Ending, _ id: UUID, generation: Int, in workspace: WorkspaceRecord, over window: NSWindow?) async -> TerminalSession? {
        guard !asking, let session = find(id, in: workspace.id), session.generation == generation else { return nil }
        if session.process.running {
            asking = true; defer { asking = false }
            let question = Self.endingQuestion(ending, name: session.displayName, project: (workspace.path as NSString).lastPathComponent, directory: workspace.path)
            guard await PiQuestion.shared.confirm(question.title, question.detail, action: question.action, destructive: true,
                                                  cancelIsDefault: true, over: window) else { return nil }
        }
        switch ending {
        case .restart: return restart(id, in: workspace.id, generation: generation)
        case .close: close(id, in: workspace.id, generation: generation); return nil
        }
    }
    /// Asks for a terminal's name, then gives it. Cancel changes nothing.
    func requestRename(_ id: UUID, generation: Int, in workspaceID: String, over window: NSWindow?) async {
        guard !asking, let session = find(id, in: workspaceID), session.generation == generation else { return }
        asking = true; defer { asking = false }
        guard let name = await PiQuestion.shared.enterText("Rename “\(session.displayName)”", detail: "Up to \(Self.nameLimit) characters. Leave it empty for “Terminal \(session.number)”.",
                                                           value: session.customName ?? "", action: "Rename", over: window),
              // Still the terminal that was asked about, not one restarted or closed meanwhile.
              find(id, in: workspaceID)?.generation == generation else { return }
        rename(id, in: workspaceID, to: name)
    }
}

/// The terminal panel's measures (`TerminalPanelView` draws it).
enum TerminalPanel {
    /// Widest the tab row grows before it scrolls.
    static let tabsLimit: CGFloat = 360
    static let minimumHeight: CGFloat = 120
    /// The panel's resize handle and title bar above the terminal itself.
    static let chromeHeight: CGFloat = 42
    static let maximumHeight: CGFloat = 700
    static func clampHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 240 }
        return min(maximumHeight, max(minimumHeight, value))
    }
}
