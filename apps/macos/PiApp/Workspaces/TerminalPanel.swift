import SwiftUI
import AppKit

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
    @Published fileprivate(set) var customName: String?
    @Published var exited = false
    @Published var failure: String?
    let directory: String
    var displayName: String { customName ?? "Terminal \(number)" }

    init(workspaceID: String, directory: String, id: UUID = UUID(), number: Int = 1, customName: String? = nil, generation: Int = 0) {
        self.workspaceID = workspaceID; self.directory = directory
        self.id = id; self.number = number; self.customName = customName; self.generation = generation
        view = TerminalView(emulator: emulator)
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

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
        // Switching projects used to leave the previous project's terminal
        // stacked underneath this one, still in the window and still drawing.
        for other in container.subviews where other !== view { other.removeFromSuperview() }
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds; view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        session.applyColors()
    }
}

/// The panel under the transcript: the project's terminals as tabs, a new
/// one, and the shown one's name, shell title, rename, restart and close,
/// then the terminal. Height drags on its top edge and is remembered.
struct TerminalPanel: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: WorkspaceRecord
    @ObservedObject private var registry = TerminalRegistry.shared
    @AppStorage("terminalHeight") private var storedHeight: Double = 240
    @State private var dragging: CGFloat?
    @State private var startHeight: CGFloat?
    /// The window this panel is in, for its questions.
    @State private var window: NSWindow?
    @State private var tabsWidth: CGFloat = 0
    @State private var headerWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0
    /// Widest the tab row grows before it scrolls.
    static let tabsLimit: CGFloat = 360
    private struct TabsWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct HeaderWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct ControlsWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    static let minimumHeight: CGFloat = 120
    /// The panel's title bar above the terminal itself.
    static let chromeHeight: CGFloat = 32
    static let maximumHeight: CGFloat = 700
    static func clampHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 240 }
        return min(maximumHeight, max(minimumHeight, value))
    }
    private var height: CGFloat { Self.clampHeight(dragging ?? CGFloat(storedHeight)) }
    private var session: TerminalSession? { registry.selected(for: workspace.id) }
    private var sessions: [TerminalSession] { registry.sessions(for: workspace.id) }
    /// What the keyboard follows: the shown terminal, and its restarts.
    private var shown: String { session.map { "\($0.id)/\($0.generation)" } ?? "none" }

    var body: some View {
        VStack(spacing: 0) {
            PiResizeHandle(orientation: .horizontal, label: "Resize terminal",
                           hint: "Drag up or down",
                           dragging: dragging != nil,
                           changed: { translation in
                               let base = startHeight ?? height
                               if startHeight == nil { startHeight = height }
                               dragging = Self.clampHeight(base - translation)
                           },
                           ended: { translation in
                               storedHeight = Double(Self.clampHeight((startHeight ?? height) - translation))
                               startHeight = nil; dragging = nil
                           })
            header.padding(.horizontal, PiSpacing.md).padding(.vertical, 5).background(Color.piWindow)
            if let session {
                TerminalHost(session: session).frame(height: height)
            } else {
                ZStack {
                    Color.piTerminalSurface
                    VStack(spacing: PiSpacing.sm) {
                        Text("No terminals in this project").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        Button { registry.create(for: workspace) } label: { Label("New Terminal", systemImage: "plus") }
                            .buttonStyle(.piSecondaryCompact)
                    }
                }.frame(height: height)
            }
        }
        .background(HostingWindowReader { window = $0 })
        .onAppear {
            registry.ensureInitialSession(for: workspace)
            DispatchQueue.main.async { session?.focus() }
        }
        .onChange(of: workspace.id) { _, _ in
            // The old project's view leaves the window with the keyboard, so
            // the new project's shell has to be given it back.
            registry.ensureInitialSession(for: workspace)
            DispatchQueue.main.async { session?.focus() }
        }
        .onChange(of: shown) { _, _ in DispatchQueue.main.async { session?.focus() } }
        .accessibilityIdentifier("terminal-panel")
    }

    private var projectName: some View {
        Text((workspace.path as NSString).lastPathComponent).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
    }
    @ViewBuilder private var header: some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                .accessibilityHidden(true)
            if !sessions.isEmpty {
                ScrollViewReader { proxy in
                    // As wide as the tabs, up to a limit past which they scroll,
                    // so the buttons after them always stay in reach.
                    ScrollView(.horizontal, showsIndicators: false) {
                        PiTabs(selection: Binding(get: { session?.id ?? UUID() }, set: { registry.select($0, in: workspace.id) }),
                               items: sessions.map { ($0.id, $0.displayName) })
                            .accessibilityLabel("Terminals in \((workspace.path as NSString).lastPathComponent)")
                            .background(GeometryReader { Color.clear.preference(key: TabsWidth.self, value: $0.size.width) })
                    }
                    .frame(width: min(max(tabsWidth, 1), tabsRoom))
                    // A row that scrolls fades at its end, so it reads as more.
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            if tabsWidth > tabsRoom { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24) }
                        }
                    }
                    .onPreferenceChange(TabsWidth.self) { tabsWidth = $0 }
                    .onChange(of: session?.id) { _, id in if let id { withAnimation(PiMotion.quick) { proxy.scrollTo(id) } } }
                    // Shown again with a terminal past the row's end chosen: in view.
                    .onAppear { if let id = session?.id { DispatchQueue.main.async { proxy.scrollTo(id) } } }
                }
            }
            PiIconButton(symbol: "plus", label: "New terminal", size: 22) { registry.create(for: workspace) }
                .help("Open another terminal in this project")
            // The shell's title and the project folder give way, whole, to
            // the buttons when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                // The folder name may shorten, down to a few letters, before it goes.
                HStack(spacing: PiSpacing.sm) { ShellTitle(session: session); projectName.frame(minWidth: 40, idealWidth: 40, maxWidth: 320, alignment: .leading) }
                ShellTitle(session: session)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: PiSpacing.sm) {
                ShellState(session: session)
                if let session {
                    // The terminal as it is when clicked: a click that waited
                    // behind a restart doesn't act on the new shell.
                    let id = session.id, generation = session.generation
                    PiIconButton(symbol: "pencil", label: "Rename terminal", size: 22) {
                        Task { await registry.requestRename(id, generation: generation, in: workspace.id, over: window) }
                    }.help("Give this terminal a name of your own")
                    PiIconButton(symbol: "arrow.clockwise", label: "Restart terminal", size: 22) {
                        Task { await registry.requestEnding(.restart, id, generation: generation, in: workspace, over: window) }
                    }.help("Starts a new shell in this terminal. Its scrollback is removed. Asks first while the shell is running.")
                    PiIconButton(symbol: "trash", label: "Close terminal", size: 22) {
                        Task { await registry.requestEnding(.close, id, generation: generation, in: workspace, over: window) }
                    }.help("Ends this terminal's shell and removes its output. Asks first while the shell is running.")
                }
                PiIconButton(symbol: "xmark", label: "Hide terminal (⌃`)", size: 22) { model.toggleTerminal() }
                    .help("Hide the terminals; they keep running")
            }
            .fixedSize()
            .background(GeometryReader { Color.clear.preference(key: ControlsWidth.self, value: $0.size.width) })
        }
        .background(GeometryReader { Color.clear.preference(key: HeaderWidth.self, value: $0.size.width) })
        .onPreferenceChange(ControlsWidth.self) { controlsWidth = $0 }
        .onPreferenceChange(HeaderWidth.self) { headerWidth = $0 }
    }
    /// How wide the tab row may be: its tabs, but never more than leaves room
    /// for the icon, New and the controls after it; at least one tab's worth.
    private var tabsRoom: CGFloat {
        let others = controlsWidth + 16 + 22 + PiSpacing.sm * 5
        let room = headerWidth > 0 ? headerWidth - others : Self.tabsLimit
        return max(72, min(Self.tabsLimit, room))
    }
}

/// The shown terminal's shell title, observed on the session itself so the
/// header follows the shell as it renames its window.
private struct ShellTitle: View {
    let session: TerminalSession?
    var body: some View { if let session { Observed(session: session) } }
    private struct Observed: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            if !session.shellTitle.isEmpty {
                Text(session.shellTitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
            }
        }
    }
}

/// Whether the shown terminal's shell exited or failed, which always shows.
private struct ShellState: View {
    let session: TerminalSession?
    var body: some View { if let session { Observed(session: session) } }
    private struct Observed: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            // A short badge, so the buttons beside it stay in reach in a narrow
            // pane; the whole message is its help and what VoiceOver reads.
            if let failure = session.failure {
                PiBadge(text: "Terminal error", tone: .danger).help(failure)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Terminal error: " + failure)
            }
            else if session.exited { PiBadge(text: "Shell exited", tone: .warning) }
        }
    }
}
