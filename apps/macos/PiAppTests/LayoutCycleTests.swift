import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// What was written to standard error while `body` ran: it goes to a file
/// meanwhile, where SwiftUI's and AttributeGraph's reports can be read.
@MainActor func standardError(while body: () async throws -> Void) async throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-" + UUID().uuidString + ".log")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    fflush(stderr)
    let saved = dup(STDERR_FILENO)
    dup2(handle.fileDescriptor, STDERR_FILENO)
    var failure: Error?
    do { try await body() } catch { failure = error }
    fflush(stderr)
    dup2(saved, STDERR_FILENO); close(saved); try? handle.close()
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: file)
    if let failure { throw failure }
    return text
}

/// The layout cycles SwiftUI reported while `body` ran, as AttributeGraph
/// wrote them to standard error.
@MainActor func layoutCycles(_ body: () async throws -> Void) async throws -> Int {
    try await standardError(while: body).components(separatedBy: "AttributeGraph: cycle detected").count - 1
}

/// SwiftUI reports a dependency cycle in a view graph as
/// "=== AttributeGraph: cycle detected through attribute … ===" on standard
/// error: it broke the cycle with a stale value, and the view laid out again.
/// These count them while the window, its sheets and its other windows are
/// shown and the appearance changes, as the screenshot gallery does.
final class LayoutCycleTests: XCTestCase, SerialTestLane {
    @MainActor func cycles(_ body: () async throws -> Void) async throws -> Int { try await layoutCycles(body) }

    @MainActor private func settle(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    /// SwiftUI presents `.sheet` in a window class of its own, and keeps each
    /// one it has presented, with its views, after it closes (macOS 14). The
    /// app presents its sheets in windows of its own instead (`piSheetWindow`).
    nonisolated static func presentedBySwiftUI(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("SheetPresentationWindow")
    }

    /// Light, then dark, then light again, each drawn.
    @MainActor private func switchAppearance(_ window: NSWindow) async throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            NSApp.appearance = NSAppearance(named: name)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await settle(0.3)
        }
    }

    /// The window and its sheets, opened and closed as a reader does, with the
    /// appearance switched. The screenshot gallery reported 2,948 cycles: most
    /// from closed sheets, still laid out whenever anything changed, and one
    /// each time a sheet with a lazy list was presented. Every sheet is now a
    /// window of the app's own, let go of whole once closed (`piSheetWindow`),
    /// and short lists are plain stacks.
    /// The lists that can be long (search results, skills, changes) keep their
    /// lazy stacks and SwiftUI's one report as their sheet opens.
    @MainActor func testTheWindowAndItsSheetsLayOutWithoutCycles() async throws {
        let root = scratchRoot("layout-cycles")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "cycles-project", path: project.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "cycles-profile"; profile.name = "Cycles"
        profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "cycles-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-cycles-key")]
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        let chat = ChatRecord(id: "cycles-chat", workspaceID: workspace.id, title: "Cycles", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            NSApp.appearance = nil
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            try? await model.traces.close(); await model.store?.close()
        }
        try await settle(0.5)

        let alone = try await cycles { try await self.switchAppearance(window) }
        XCTAssertEqual(alone, 0, "The window alone")
        let rename = try await cycles { model.presentRename(chat.id); try await self.settle(1.0); model.renameTarget = nil; try await self.settle(0.5) }
        XCTAssertEqual(rename, 0, "The rename sheet")
        let projects = try await cycles { model.showWorkspaceManager = true; try await self.settle(1.0); model.showWorkspaceManager = false; try await self.settle(0.5) }
        XCTAssertEqual(projects, 0, "The Projects sheet: its list is a plain stack")
        for section in [SettingsSection.connections, .usage, .chats, .app] {
            model.settingsSection = section; model.showProfiles = true; try await settle(1.0); model.showProfiles = false; try await settle(0.5)
        }
        model.settingsSection = .connections
        model.inspectResources(chat.id); try await settle(1.0); model.showResources = false; try await settle(0.5)
        model.inspectConversation(chat.id); try await settle(1.0); model.showConversationContent = false; try await settle(0.5)
        let after = try await cycles { try await self.switchAppearance(window) }
        XCTAssertEqual(after, 0, "Sheets opened and closed are not laid out again when the appearance changes")
    }
}

extension LayoutCycleTests {
    /// What a model change costs before any sheet was opened, and after the
    /// Settings sheet was opened and closed ten times.
    /// Ten Settings sheets opened and closed used to leave ten windows with
    /// their views in them, each redrawing with every change to the model: a
    /// hundred changes cost 4.9 s instead of 1.0 s in a Debug build. SwiftUI
    /// presents no sheet of its own any more, and a closed sheet's window,
    /// which AppKit may keep a while, holds nothing.
    @MainActor func testClosedSheetsAndTheCostOfAModelChange() async throws {
        let root = scratchRoot("layout-cycles-cost")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "cost-project", path: project.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "cost-profile"; profile.name = "Cost"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "cost-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-cost-key")]; $0.automaticUpdateChecks = false }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        let chat = ChatRecord(id: "cost-chat", workspaceID: workspace.id, title: "Cost", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close(); model.report.suspend(); model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        try await Task.sleep(for: .milliseconds(600))
        func cost() async -> Double {
            var total = 0.0
            for index in 0..<100 {
                let started = ProcessInfo.processInfo.systemUptime
                model.error = index.isMultiple(of: 2) ? "Probe notice" : nil
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield()
                total += ProcessInfo.processInfo.systemUptime - started
            }
            model.error = nil
            return total * 1000
        }
        let before = await cost()
        for _ in 0..<10 {
            model.showProfiles = true; try await Task.sleep(for: .milliseconds(700))
            model.showProfiles = false; try await Task.sleep(for: .milliseconds(400))
        }
        let after = await cost()
        try await Task.sleep(for: .milliseconds(300))
        let swiftUISheets = NSApp.windows.filter(Self.presentedBySwiftUI).count
        let holding = NSApp.windows.filter { $0.styleMask.contains(.docModalWindow) && !$0.isVisible && $0.contentView != nil }.count
        print(String(format: "COST before %.1f ms, after ten Settings sheets %.1f ms, closed sheets holding views %d, SwiftUI sheet windows %d", before, after, holding, swiftUISheets))
        XCTAssertEqual(swiftUISheets, 0, "Every sheet is a window of the app's own (`piSheetWindow`), not one SwiftUI keeps")
        XCTAssertEqual(holding, 0, "A closed sheet's window lets go of its views")
        XCTAssertLessThan(after, before * 1.6, "Closed sheets no longer redraw with every change to the model (before \(Int(before)) ms, after \(Int(after)) ms)")
    }
}

extension LayoutCycleTests {
    /// The Settings window from the app menu takes its form down while it is
    /// closed, and puts it back when it opens again.
    @MainActor func testTheSettingsWindowLetsGoOfItsFormWhileClosed() async throws {
        func views(_ view: NSView?) -> Int { guard let view else { return 0 }; return 1 + view.subviews.reduce(0) { $0 + views($1) } }
        // The native XCTest host deliberately has no app windows or menus.
        // Install the production menu against an isolated application model.
        let root = scratchRoot("settings-menu-lifecycle")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let application = BelloAgentApplication(model: model)
        let previousMenu = NSApp.mainMenu
        let previousServices = NSApp.servicesMenu, previousWindows = NSApp.windowsMenu
        let previousDisplay = TranscriptDisplay.mode
        let menus = ApplicationMenus(model: model, updates: application.updates,
                                     workspaceWindow: { application.workspaceWindow?.window },
                                     revealWorkspace: { application.revealWorkspace() },
                                     showSettings: { application.showSettings() })
        menus.install()
        defer {
            application.settingsWindow?.close(); application.workspaceWindow?.close()
            NSApp.mainMenu = previousMenu
            NSApp.servicesMenu = previousServices; NSApp.windowsMenu = previousWindows
            TranscriptDisplay.use(previousDisplay)
            withExtendedLifetime(menus) {}
        }
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu, "The app menu is missing")
        let item = try XCTUnwrap(appMenu.items.first { $0.keyEquivalent == "," }, "The app menu has no Settings item")
        func open() async throws -> NSWindow {
            let before = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            appMenu.performActionForItem(at: appMenu.index(of: item))
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(50))
                if let window = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) }) { return window }
            }
            XCTFail("The installed Settings menu must open its native window")
            throw CancellationError()
        }
        let settings = try await open()
        try await Task.sleep(for: .milliseconds(800))
        let shown = views(settings.contentView)
        settings.close(); try await Task.sleep(for: .milliseconds(600))
        let closed = views(settings.contentView)
        let again = try await open()
        try await Task.sleep(for: .milliseconds(800))
        let reopened = views(again.contentView)
        again.close(); try await Task.sleep(for: .milliseconds(300))
        print("SETTINGSWINDOW shown \(shown) closed \(closed) reopened \(reopened)")
        XCTAssertGreaterThan(shown, 40, "The form is in the window")
        XCTAssertLessThan(closed, shown / 4, "Closed, the window holds no form")
        XCTAssertGreaterThan(reopened, 40, "and it is back when the window opens again")
    }
}
