import AppKit
import Combine
import SwiftUI

/// The Session Inspector's window: the app's own chrome, the frame it was last
/// left at, and reads that stop whenever it is minimised, covered or closed.
@MainActor final class SessionInspectorWindowController: NSWindowController, NSWindowDelegate {
    static let identifier = "session-inspector-window"
    let inspector: SessionInspectorModel
    private(set) var isClosed = false
    private var observations: Set<AnyCancellable> = []
    var onClose: (() -> Void)?
    /// The Inspector opens where it was last left, at that size. Test runs
    /// use no name, so they neither read nor write the reader's frame.
    static var frameAutosaveName: String? = ProcessInfo.processInfo.environment["PI_APP_TESTING"] == "1" ? nil : "SessionInspector"
    static let defaultSize = NSSize(width: 1_120, height: 820)
    static let minimumSize = NSSize(width: 700, height: 520)

    init(inspector: SessionInspectorModel) {
        self.inspector = inspector
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        window.applyPiWindowChrome()
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        window.contentView = NSHostingView(rootView: SessionInspectorView(inspector: inspector))
        super.init(window: window)
        window.delegate = self
        updateTitle(inspector.title)
        if let name = Self.frameAutosaveName {
            if !window.setFrameUsingName(name) { window.center() }
            // A second Inspector open at the same time cannot share the name:
            // it opens just below and right of the first.
            if !window.setFrameAutosaveName(name) { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)) }
        } else { window.center() }
    }

    required init?(coder: NSCoder) { return nil }

    func present(_ focus: InspectorFocus) {
        guard !isClosed, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        inspector.setVisible(isOnScreen || window.isVisible)
        inspector.focus(focus)
    }

    func updateTitle(_ title: String) {
        guard !isClosed else { return }
        let title = title.isEmpty ? "Untitled session" : title
        if inspector.title != title { inspector.title = title }
        window?.title = "\(title) — Session Inspector"
    }

    /// Follows the chat the window belongs to, never the selected one.
    func observe(model: WorkspaceModel) {
        observations.removeAll()
        guard !isClosed else { return }
        let scope = inspector.scope
        model.$chats.combineLatest(model.$sides).sink { [weak self] chats, sides in
            let record = chats.first { $0.id == scope.sessionID && $0.workspaceID == scope.workspaceID }
                ?? sides.values.first { $0.id == scope.sessionID && $0.workspaceID == scope.workspaceID }?.chat
            if let record { self?.updateTitle(record.title) }
        }.store(in: &observations)
        if let display = model.displays[scope.sessionID] { inspector.observe(footer: display.footer, display: display) }
    }

    /// Follows the chat's display as the workspace holds it now.
    func follow(_ display: SessionDisplay?) {
        guard !isClosed else { return }
        inspector.follow(display)
    }

    func windowDidMiniaturize(_ notification: Notification) { guard !isClosed else { return }; inspector.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { guard !isClosed else { return }; inspector.setVisible(isOnScreen) }
    func windowDidChangeOcclusionState(_ notification: Notification) { guard !isClosed else { return }; inspector.setVisible(isOnScreen) }
    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        if let window, !window.frameAutosaveName.isEmpty { window.saveFrame(usingName: window.frameAutosaveName); window.setFrameAutosaveName("") }
        inspector.setVisible(false)
        observations.removeAll()
        DispatchQueue.main.async { [weak self] in self?.window?.contentView = nil }
        let closed = onClose; onClose = nil
        closed?()
    }
}

/// One Inspector per owner and session; another session opens alongside it.
@MainActor final class SessionInspectorWindows {
    static let shared = SessionInspectorWindows()
    /// The owner is held weakly and compared by identity, so a project
    /// window that closed never hands its Inspector to a new one.
    private struct Entry {
        weak var owner: WorkspaceModel?
        let scope: SessionUsageScope
        let controller: SessionInspectorWindowController
    }
    private var entries: [Entry] = []
    var count: Int { entries.count }
    var controllers: [SessionInspectorWindowController] { entries.map(\.controller) }

    func controller(sessionID: String) -> SessionInspectorWindowController? {
        entries.first { $0.scope.sessionID == sessionID }?.controller
    }

    @discardableResult
    func show(model: WorkspaceModel, sessionID: String, workspaceID: String, title: String, focus: InspectorFocus) -> SessionInspectorWindowController {
        // An Inspector whose project window is gone has nothing to follow.
        for entry in entries where entry.owner == nil { entry.controller.close() }
        let scope = SessionUsageScope(sessionID: sessionID, workspaceID: workspaceID)
        let controller: SessionInspectorWindowController
        if let existing = entries.first(where: { $0.owner === model && $0.scope == scope })?.controller {
            controller = existing
            controller.updateTitle(title)
        } else {
            let inspector = SessionInspectorModel(scope: scope, title: title, archive: model.traces, workspace: model,
                                                  usageLoader: { [archive = model.traces] scope, until, offset in
                try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset)
            })
            controller = SessionInspectorWindowController(inspector: inspector)
            controller.onClose = { [weak self, weak controller] in self?.entries.removeAll { $0.controller === controller } }
            entries.append(Entry(owner: model, scope: scope, controller: controller))
        }
        controller.observe(model: model)
        controller.present(focus)
        return controller
    }

    /// A project window's displays changed: each Inspector follows its chat's
    /// display as it is now, on the next turn, never from inside the change,
    /// which can come from anywhere the workspace installs or evicts one.
    func displaysChanged() {
        guard !entries.isEmpty, !following else { return }
        following = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.following = false
            for entry in self.entries {
                if let owner = entry.owner { entry.controller.follow(owner.displays[entry.scope.sessionID]) }
            }
        }
    }
    private var following = false

    func closeAll(owner: AnyObject) {
        for entry in entries where entry.owner == nil || entry.owner === owner { entry.controller.close() }
    }

    /// Every Inspector, whoever owns it: the end of a test.
    func closeAll() {
        for entry in entries { entry.controller.close() }
    }
}
