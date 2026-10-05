import AppKit
import Combine

/// The app owns one workspace, its windows, menus and update lifetime.
@main @MainActor final class BelloAgentApplication: ApplicationLifecycle {
    let workspaceModel: WorkspaceModel
    let updates: UpdateController
    let menuBar = MenuBarController()
    private(set) var workspaceWindow: NSWindowController?
    private(set) var settingsWindow: NSWindowController?
    private var menus: ApplicationMenus?
    private var observer: ShellObserver!
    private var configurationKey: ConfigurationKey?
    private struct ConfigurationKey: Equatable {
        let loaded: Bool
        let automaticChecks: Bool
        let transcript: String?
    }

    static func main() {
        registerDrawingPolicy()
        let app = NSApplication.shared
        let delegate = BelloAgentApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func registerDrawingPolicy() {
        // AppKit draws a large view's content (over 768×768 pixels: the
        // transcript's long Markdown text) asynchronously: Core Animation
        // rasterizes its glyphs on four or five threads of its own. SwiftUI
        // rasterizes its text's glyphs on the main thread, and every glyph
        // takes the process's one font-cache lock, so the main thread waited
        // on those threads, up to 620 ms, as a long reply began streaming
        // (8 of 9 replays of the soak's seed 1790822043708). AppKit reads
        // this undocumented default once, before the first view draws; off,
        // it draws those views on the main thread like any other, and none
        // of 9 replays paused. What is drawn differs only in antialiasing
        // (under 16 of 255 for 99.8% of the pixels that differ). It goes in
        // the registration domain, so a default the reader sets still wins.
        // `PI_APP_ASYNC_DRAWING=1` keeps AppKit's way, for comparing the two
        // (WindowCaptureParityTests, scripts/compare-captures.py).
        let environment = ProcessInfo.processInfo.environment
        let asynchronous = (environment["PI_APP_ASYNC_DRAWING"] ?? environment["TEST_RUNNER_PI_APP_ASYNC_DRAWING"]) == "1"
        UserDefaults.standard.register(defaults: ["NSViewCanUseGPUAcceleration": asynchronous])
    }

    override convenience init() {
        self.init(model: WorkspaceModel(launching: ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1"))
    }
    init(model: WorkspaceModel) {
        workspaceModel = model
        updates = UpdateController()
        super.init()
        self.model = workspaceModel
        let model = workspaceModel
        updates.hasActiveWork = { [weak model] in model?.hasActiveWork ?? false }
        updates.acquireBarrier = { [weak model] in model?.acquireUpdateBarrier() ?? false }
        updates.prepareForInstall = { [weak model] in try await model?.prepareForInstall() }
        updates.releaseBarrier = { [weak model] in model?.releaseUpdateBarrier() }
        updates.reportFailure = { [weak model] in model?.error = $0 }
        observer = ShellObserver { [weak self] in self?.configurationChanged() }
        observer.observe(model)
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
        // The XCTest host gets no reader data, menu bar item or app windows.
        guard ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1" else { return }
        menus = ApplicationMenus(model: workspaceModel, updates: updates,
                                 workspaceWindow: { [weak self] in self?.workspaceWindow?.window },
                                 revealWorkspace: { [weak self] in self?.revealWorkspace() },
                                 showSettings: { [weak self] in self?.showSettings() })
        menus?.install()
        installMenuBar()
        revealWorkspace()
        configurationChanged()
        Task { await workspaceModel.restore() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealWorkspace()
        return false
    }

    func revealWorkspace() {
        menuBar.close()
        if workspaceWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowPresentationController.defaultSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Bello Agent"
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.isReleasedWhenClosed = false
            window.contentMinSize = WorkspaceRootView.minimumWindowSize
            window.applyPiWindowChrome()
            window.contentView = WorkspaceRootView(model: workspaceModel)
            window.center()
            window.setFrameAutosaveName("main")
            workspaceWindow = NSWindowController(window: window)
        }
        if workspaceWindow?.window?.isMiniaturized == true { workspaceWindow?.window?.deminiaturize(nil) }
        workspaceWindow?.showWindow(nil)
        workspaceWindow?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsWindowView(model: workspaceModel)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.intrinsicContentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Settings"
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.applyPiWindowChrome()
            window.center()
            window.setFrameAutosaveName("settings")
            settingsWindow = NSWindowController(window: window)
        }
        if settingsWindow?.window?.isMiniaturized == true { settingsWindow?.window?.deminiaturize(nil) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configurationChanged() {
        let model = workspaceModel
        let next = ConfigurationKey(loaded: model.configurationLoaded, automaticChecks: model.configuration.automaticUpdateChecks,
                                    transcript: model.configuration.transcriptView)
        guard configurationKey != next else { return }
        let before = configurationKey
        configurationKey = next
        if before?.loaded != next.loaded || before?.automaticChecks != next.automaticChecks {
            updates.configure(automaticChecks: next.automaticChecks, configurationAvailable: next.loaded)
        }
        if next.loaded, before?.loaded != next.loaded || before?.transcript != next.transcript { model.applyTranscriptDisplay() }
    }

    private func installMenuBar() {
        let model = workspaceModel
        menuBar.install { [weak self] in
            MenuBarMetricsView(load: { period, until, offset in
                try await model.ensureConfiguration()
                return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset)
            }, scopedLoad: { period, until, offset, from, workspace in
                try await model.ensureConfiguration()
                return try await model.traces.menuBarMetrics(period: period, until: until, offset: offset, from: from, workspaceID: workspace)
            }, projects: { model.workspaces.map { MonitorProject(id: $0.id, title: URL(fileURLWithPath: $0.path).lastPathComponent) } },
               activity: { model.menuBarActivity() }, activityChanges: { model.menuBarActivityChanges }, live: model.liveActivity,
               openApp: { [weak self] in self?.revealWorkspace() },
               openReport: { [weak self] in self?.revealWorkspace(); model.openReport() },
               openSession: { [weak self] id in
                   self?.revealWorkspace()
                   Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
               })
        }
    }
}
