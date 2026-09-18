import SwiftUI
import AppKit
import SwiftTerm

/// One shell per project, kept alive while hidden so a toggled panel returns
/// to the same session. The view is re-parented when the panel shows again.
@MainActor final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate, ObservableObject {
    let workspaceID: String
    let view: LocalProcessTerminalView
    @Published var title = "Terminal"
    @Published var exited = false
    private let directory: String

    init(workspaceID: String, directory: String) {
        self.workspaceID = workspaceID; self.directory = directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyColors()
        start()
    }

    func applyColors() {
        view.nativeBackgroundColor = NSColor(Color.piSurfaceSunken)
        view.nativeForegroundColor = NSColor(Color.piInk)
        view.caretColor = NSColor(Color.piBrandOrange)
    }

    func start() {
        exited = false
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"; environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["BELLO_AGENT"] = "1"
        // Provider credentials never reach the shell; the app only passes its own login environment.
        for key in environment.keys where key.hasPrefix("LITELLM") || key.hasSuffix("_API_KEY") { environment.removeValue(forKey: key) }
        let pairs = environment.map { "\($0.key)=\($0.value)" }
        FileManager.default.changeCurrentDirectoryPath(directory)
        view.startProcess(executable: shell, args: ["-l"], environment: pairs, execName: "-" + (shell as NSString).lastPathComponent)
    }

    func focus() { view.window?.makeFirstResponder(view) }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title.isEmpty ? "Terminal" : title }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.exited = true }
    }
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
        sessions.removeValue(forKey: workspace.id)
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
                Text(holder.session?.title ?? "Terminal").font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk).lineLimit(1)
                Text((workspace.path as NSString).lastPathComponent).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                if holder.session?.exited == true { PiBadge(text: "Shell exited", tone: .warning) }
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
