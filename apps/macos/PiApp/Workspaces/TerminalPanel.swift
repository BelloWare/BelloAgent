import SwiftUI
import AppKit

/// One shell per project, kept alive while hidden so a toggled panel returns
/// to the same session. The view is re-parented when the panel shows again.
@MainActor final class TerminalSession: ObservableObject {
    let workspaceID: String
    let emulator = TerminalEmulator(columns: 100, rows: 24)
    let view: TerminalView
    let process = PseudoTerminal()
    @Published var title = "Terminal"
    @Published var exited = false
    @Published var failure: String?
    private let directory: String

    init(workspaceID: String, directory: String) {
        self.workspaceID = workspaceID; self.directory = directory
        view = TerminalView(emulator: emulator)
        emulator.onOutput = { [weak self] data in self?.process.write(data) }
        emulator.onTitleChange = { [weak self] title in self?.title = title.isEmpty ? "Terminal" : title }
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

@MainActor final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var sessions: [String: TerminalSession] = [:]
    /// Open shells, for tests and for the panel's own bookkeeping.
    var openWorkspaceIDs: Set<String> { Set(sessions.keys) }
    func session(for workspace: WorkspaceRecord) -> TerminalSession {
        if let existing = sessions[workspace.id] { return existing }
        let session = TerminalSession(workspaceID: workspace.id, directory: workspace.path)
        sessions[workspace.id] = session
        return session
    }
    func restart(for workspace: WorkspaceRecord) -> TerminalSession {
        close(workspaceID: workspace.id)
        return session(for: workspace)
    }
    /// Ends one project's shell and gives up its scrollback. A project that is
    /// no longer configured must not keep a shell and its history for the rest
    /// of the app's life.
    func close(workspaceID: String) {
        guard let old = sessions.removeValue(forKey: workspaceID) else { return }
        old.process.terminate(); old.view.removeFromSuperview()
    }
    /// Ends every shell, on the way out of the app.
    func shutdown() {
        for session in sessions.values { session.process.terminate(); session.view.removeFromSuperview() }
        sessions.removeAll()
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

/// The panel under the transcript: title bar with the shell's title, restart
/// and close, then the terminal. Height drags on its top edge and is remembered.
struct TerminalPanel: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: WorkspaceRecord
    @AppStorage("terminalHeight") private var storedHeight: Double = 240
    @State private var dragging: CGFloat?
    @State private var startHeight: CGFloat?
    @StateObject private var holder = SessionHolder()
    static let minimumHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 700
    static func clampHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 240 }
        return min(maximumHeight, max(minimumHeight, value))
    }
    private var height: CGFloat { Self.clampHeight(dragging ?? CGFloat(storedHeight)) }

    @MainActor final class SessionHolder: ObservableObject {
        @Published var session: TerminalSession?
    }

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
            HStack(spacing: PiSpacing.sm) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                TerminalTitle(session: holder.session)
                Text((workspace.path as NSString).lastPathComponent).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                Spacer()
                PiIconButton(symbol: "arrow.clockwise", label: "Restart the shell", size: 22) { holder.session = TerminalRegistry.shared.restart(for: workspace); holder.session?.focus() }
                PiIconButton(symbol: "xmark", label: "Hide terminal (⌃`)", size: 22) { model.toggleTerminal() }
            }.padding(.horizontal, PiSpacing.md).padding(.vertical, 5).background(Color.piWindow)
            if let session = holder.session {
                TerminalHost(session: session).frame(height: height)
            } else {
                Color.piTerminalSurface.frame(height: height)
            }
        }
        .onAppear {
            holder.session = TerminalRegistry.shared.session(for: workspace)
            DispatchQueue.main.async { holder.session?.focus() }
        }
        .onChange(of: workspace.id) { _, _ in
            // The old project's view leaves the window with the keyboard, so
            // the new project's shell has to be given it back.
            holder.session = TerminalRegistry.shared.session(for: workspace)
            DispatchQueue.main.async { holder.session?.focus() }
        }
        .accessibilityIdentifier("terminal-panel")
    }
}

/// The shell's title and state, observed on the session itself so the panel
/// header updates as the shell renames its window or exits.
private struct TerminalTitle: View {
    let session: TerminalSession?
    var body: some View {
        if let session { Observed(session: session) } else { Text("Terminal").font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk) }
    }
    private struct Observed: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            Text(session.title).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk).lineLimit(1)
            if let failure = session.failure { PiBadge(text: failure, tone: .danger) }
            else if session.exited { PiBadge(text: "Shell exited", tone: .warning) }
        }
    }
}
