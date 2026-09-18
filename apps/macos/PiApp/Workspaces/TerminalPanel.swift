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
        emulator.onBell = { NSSound.beep() }
        view.onInput = { [weak self] data in self?.process.write(data) }
        view.onResize = { [weak self] columns, rows in self?.process.resize(columns: columns, rows: rows) }
        process.onData = { [weak self] data in
            guard let self else { return }
            self.emulator.feed(data)
            self.view.refresh()
        }
        process.onExit = { [weak self] _ in self?.exited = true; self?.view.refresh() }
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

    func focus() { view.window?.makeFirstResponder(view) }
    func applyColors() { view.needsDisplay = true }
}

@MainActor final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var sessions: [String: TerminalSession] = [:]
    func session(for workspace: WorkspaceRecord) -> TerminalSession {
        if let existing = sessions[workspace.id] { return existing }
        let session = TerminalSession(workspaceID: workspace.id, directory: workspace.path)
        sessions[workspace.id] = session
        return session
    }
    func restart(for workspace: WorkspaceRecord) -> TerminalSession {
        if let old = sessions.removeValue(forKey: workspace.id) { old.process.terminate(); old.view.removeFromSuperview() }
        return session(for: workspace)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
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
    private var height: CGFloat { min(700, max(120, dragging ?? CGFloat(storedHeight))) }

    @MainActor final class SessionHolder: ObservableObject {
        @Published var session: TerminalSession?
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.piHairline).frame(height: 1)
                .overlay {
                    Rectangle().fill(Color.clear).frame(height: 9).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startHeight ?? height
                                if startHeight == nil { startHeight = height }
                                dragging = min(700, max(120, base - value.translation.height))
                            }
                            .onEnded { value in
                                storedHeight = Double(min(700, max(120, (startHeight ?? height) - value.translation.height)))
                                startHeight = nil; dragging = nil
                            })
                        .accessibilityLabel("Resize terminal")
                }.zIndex(1)
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
                Color.piSurfaceSunken.frame(height: height)
            }
        }
        .onAppear {
            holder.session = TerminalRegistry.shared.session(for: workspace)
            DispatchQueue.main.async { holder.session?.focus() }
        }
        .onChange(of: workspace.id) { _, _ in holder.session = TerminalRegistry.shared.session(for: workspace) }
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
