import AppKit
import Combine
import SwiftUI

/// A small presentation model avoids a window -> hosting view -> controller
/// retain cycle while letting renames update both native chrome and content.
@MainActor final class SessionUsageWindowTitle: ObservableObject {
    @Published var value: String
    init(_ value: String) { self.value = value }
}

private struct SessionUsageWindowContent: View {
    @ObservedObject var title: SessionUsageWindowTitle
    let usage: SessionUsageController
    var body: some View { SessionUsageView(title: title.value, controller: usage) }
}

/// Windows retain the scope with which they were opened, independently of the
/// selected chat. Closing stops reads immediately, including late actor replies.
@MainActor final class SessionUsageWindowController: NSWindowController, NSWindowDelegate {
    let scope: SessionUsageScope
    let usage: SessionUsageController
    let sessionTitle: SessionUsageWindowTitle
    private(set) var isClosed = false
    private var observations: Set<AnyCancellable> = []
    var onClose: (() -> Void)?

    init(scope: SessionUsageScope, title: String, load: @escaping SessionUsageLoader,
         interval: Duration = .seconds(10)) {
        self.scope = scope
        usage = SessionUsageController(scope: scope, load: load, interval: interval)
        sessionTitle = SessionUsageWindowTitle(title)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 560)
        // The app's own chrome, not the system title bar; the content's header
        // carries the name and leaves room for the window buttons.
        window.applyPiWindowChrome()
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("session-usage-window")
        window.contentView = NSHostingView(rootView: SessionUsageWindowContent(title: sessionTitle, usage: usage))
        super.init(window: window)
        window.delegate = self
        updateTitle(title)
        window.center()
    }

    required init?(coder: NSCoder) { return nil }

    func present(initialBreakdown: SessionUsageBreakdown) {
        guard !isClosed, let window else { return }
        usage.breakdown = initialBreakdown
        usage.setVisible(true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func updateTitle(_ title: String) {
        guard !isClosed else { return }
        let title = title.isEmpty ? "Untitled session" : title
        if sessionTitle.value != title { sessionTitle.value = title }
        window?.title = "\(title) — Session Info"
    }

    /// Publishers belong to the opened session, never the currently selected
    /// conversation. The fallback poll also catches retained/archive changes.
    func observe(model: WorkspaceModel, footer: SessionMetrics) {
        observations.removeAll()
        guard !isClosed else { return }
        model.$chats.combineLatest(model.$sides).sink { [weak self] chats, sides in
            guard let self else { return }
            let record = chats.first { $0.id == self.scope.sessionID && $0.workspaceID == self.scope.workspaceID }
                ?? sides.values.first { $0.id == self.scope.sessionID && $0.workspaceID == self.scope.workspaceID }?.chat
            if let record { self.updateTitle(record.title) }
        }.store(in: &observations)
        footer.$gateway.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.usage.refresh()
        }.store(in: &observations)
        footer.$timing.removeDuplicates().sink { [weak self] timing in
            self?.usage.timing = timing
        }.store(in: &observations)
        footer.$turnTiming.removeDuplicates().sink { [weak self] work in
            self?.usage.work = work
        }.store(in: &observations)
    }

    /// A minimised or fully covered Session Info window has nothing to show,
    /// and kept re-reading the archive every ten seconds for it.
    func windowDidMiniaturize(_ notification: Notification) { guard !isClosed else { return }; usage.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { guard !isClosed else { return }; usage.setVisible(isOnScreen) }
    func windowDidChangeOcclusionState(_ notification: Notification) { guard !isClosed else { return }; usage.setVisible(isOnScreen) }
    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        usage.setVisible(false)
        observations.removeAll()
        DispatchQueue.main.async { [weak self] in self?.window?.contentView = nil }
        let closed = onClose; onClose = nil
        closed?()
    }
}

/// Header and footer share one ordinary native window per owner/project/session.
/// A different session can open alongside it for comparison.
@MainActor final class SessionUsageWindows {
    static let shared = SessionUsageWindows()
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let scope: SessionUsageScope
    }
    private var windows: [Key: SessionUsageWindowController] = [:]
    var count: Int { windows.count }

    @discardableResult
    func show(model: WorkspaceModel, chat: ChatRecord, footer: SessionMetrics,
              initialBreakdown: SessionUsageBreakdown) -> SessionUsageWindowController {
        let controller = show(owner: model, scope: SessionUsageScope(sessionID: chat.id, workspaceID: chat.workspaceID),
                              title: chat.title, load: { [archive = model.traces] scope, until, offset in
            try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset)
        }, initialBreakdown: initialBreakdown)
        controller.observe(model: model, footer: footer)
        return controller
    }

    @discardableResult
    func show(owner: AnyObject, scope: SessionUsageScope, title: String, load: @escaping SessionUsageLoader,
              initialBreakdown: SessionUsageBreakdown = .models,
              interval: Duration = .seconds(10)) -> SessionUsageWindowController {
        let key = Key(owner: ObjectIdentifier(owner), scope: scope)
        let controller: SessionUsageWindowController
        if let existing = windows[key] {
            controller = existing
            controller.updateTitle(title)
        } else {
            controller = SessionUsageWindowController(scope: scope, title: title, load: load, interval: interval)
            controller.onClose = { [weak self] in self?.windows.removeValue(forKey: key) }
            windows[key] = controller
        }
        controller.present(initialBreakdown: initialBreakdown)
        return controller
    }

    func closeAll(owner: AnyObject) {
        let owner = ObjectIdentifier(owner)
        let matching = windows.filter { $0.key.owner == owner }.map(\.value)
        for controller in matching { controller.close() }
    }
}
