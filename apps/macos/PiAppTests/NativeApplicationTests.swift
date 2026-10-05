import AppKit
import QuartzCore
import XCTest
@testable import PiApp

final class NativeApplicationTests: XCTestCase, SerialTestLane {
    @MainActor private func fixture() throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("native-application-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.selectedWorkspaceID = "project"
        return (model, root)
    }

    @MainActor func testDockReopenUsesTheSameNativeWorkspaceWindow() async throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let application = BelloAgentApplication(model: model)
        application.revealWorkspace()
        let first = try XCTUnwrap(application.workspaceWindow?.window)
        defer { first.close() }
        XCTAssertTrue(first.contentView is WorkspaceRootView)
        XCTAssertEqual(first.contentMinSize, NSSize(width: 920, height: 600))
        first.miniaturize(nil)
        try await eventually("workspace to minimize") { first.isMiniaturized }
        XCTAssertFalse(application.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        try await eventually("Dock reopen to restore the minimized workspace") { !first.isMiniaturized && first.isVisible }
        first.close()
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(application.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(application.workspaceWindow?.window === first)
        XCTAssertTrue(first.isVisible)
    }

    @MainActor func testSettingsReopensWithTheSameEditorAndWindow() async throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let application = BelloAgentApplication(model: model)
        application.showSettings()
        let first = try XCTUnwrap(application.settingsWindow?.window)
        let content = try XCTUnwrap(first.contentView as? SettingsWindowView)
        defer { first.close() }
        first.close()
        try await eventually("closed Settings form to detach") { content.subviewsOfType(ProfileSettingsView.self).isEmpty }
        application.showSettings()
        try await eventually("Settings form to return") { !content.subviewsOfType(ProfileSettingsView.self).isEmpty }
        XCTAssertTrue(application.settingsWindow?.window === first)
        XCTAssertTrue(first.contentView === content)
        XCTAssertTrue((first.contentView as? SettingsWindowView)?.controller === content.controller)
    }

    @MainActor func testMenusKeepShortcutsAndConversationFocus() async throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let workspace = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let inspector = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        workspace.isReleasedWhenClosed = false; inspector.isReleasedWhenClosed = false
        defer { workspace.close(); inspector.close() }
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "fixture")
        model.chats = [chat]; model.selectedID = chat.id; model.displays[chat.id] = SessionDisplay(id: chat.id)
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { workspace }, revealWorkspace: {}, showSettings: {})
        menus.install()
        func item(_ title: String) throws -> NSMenuItem {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                if let value = menu.items.first(where: { $0.title == title }) { return value }
            }
            throw XCTUnwrapError(title)
        }
        let steer = try item("Send / Steer Current Run"), stop = try item("Stop")
        XCTAssertEqual(steer.keyEquivalent, "\r"); XCTAssertEqual(steer.keyEquivalentModifierMask, .command)
        XCTAssertEqual(stop.keyEquivalent, "."); XCTAssertEqual(stop.keyEquivalentModifierMask, .command)
        XCTAssertEqual(try item("Settings…").keyEquivalent, ",")
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace.makeKeyAndOrderFront(nil)
        workspace.makeKey()
        try await eventually("workspace to own the keyboard") { NSApp.keyWindow === workspace }
        XCTAssertTrue(model.conversationCommandsEnabled)
        XCTAssertTrue(menus.validateMenuItem(steer)); XCTAssertTrue(menus.validateMenuItem(stop))
        inspector.makeKeyAndOrderFront(nil)
        inspector.makeKey()
        try await eventually("Inspector to own the keyboard") { NSApp.keyWindow === inspector }
        XCTAssertFalse(menus.validateMenuItem(steer)); XCTAssertFalse(menus.validateMenuItem(stop))
        model.setArchivedChatsShown(true)
        let archive = try item("Show Archived Chats")
        menus.menuNeedsUpdate(try XCTUnwrap(archive.menu))
        XCTAssertEqual(archive.title, "Hide Archived Chats")
    }

    @MainActor func testLeavingATextFieldDoesNotSubmitButReturnDoes() async throws {
        var submissions = 0
        let field = PiKit.TextField(placeholder: "Search", onSubmit: { submissions += 1 })
        let other = NSTextField(string: "")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        field.frame = NSRect(x: 20, y: 80, width: 280, height: 30)
        other.frame = NSRect(x: 20, y: 20, width: 280, height: 24)
        content.addSubview(field); content.addSubview(other)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field.field))
        let editor = try XCTUnwrap(field.field.currentEditor())
        editor.insertText("Find this")
        XCTAssertTrue(window.makeFirstResponder(other))
        await Task.yield()
        XCTAssertEqual(submissions, 0, "Clicking another field must not submit a search")
        XCTAssertTrue(window.makeFirstResponder(field.field))
        field.field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await Task.yield()
        XCTAssertEqual(submissions, 1, "Return submits exactly once")
    }

    @MainActor func testPlainNativeSheetChildrenInheritReducedMotion() {
        let previous = PiKit.Motion.reducedOverride
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = previous }
        let host = PiSheetContentHost()
        defer { host.clear() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let child = NSView(frame: root.bounds)
        child.wantsLayer = true
        let layer = CALayer(); child.layer = layer; root.addSubview(child)
        host.show(root, inherited: .init(reduceMotion: true, enabled: true), close: {})
        XCTAssertTrue(root.piReducesMotion); XCTAssertTrue(child.piReducesMotion)
        PiKit.fadeIn(child); XCTAssertNil(layer.animation(forKey: "fade-in"))
        host.inherit(.init(reduceMotion: false, enabled: true))
        XCTAssertFalse(root.piReducesMotion); XCTAssertFalse(child.piReducesMotion)
        PiKit.fadeIn(child); XCTAssertNotNil(layer.animation(forKey: "fade-in"))
        layer.removeAllAnimations()
        PiKit.Motion.reducedOverride = true
        XCTAssertTrue(child.piReducesMotion)
        PiKit.fadeIn(child); XCTAssertNil(layer.animation(forKey: "fade-in"))
        PiKit.Motion.reducedOverride = false
        host.inherit(.init(reduceMotion: true, enabled: true))
        XCTAssertTrue(child.piReducesMotion)
        host.clear()
        XCTAssertNil(root.superview); XCTAssertFalse(host.inheritedReduceMotion)
        XCTAssertFalse(child.piReducesMotion)
        let replacement = NSView(frame: root.bounds)
        host.show(replacement, inherited: .init(reduceMotion: false, enabled: true), close: {})
        XCTAssertFalse(replacement.piReducesMotion)
    }

    @MainActor func testOnboardingComposesFolderLimitsAndBusyStateThroughRepeatedRefreshes() async throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.workspaces[0].paths = (1..<WorkspaceModel.maximumRoots).map { root.appendingPathComponent("folder-\($0)").path }
        let view = OnboardingContentView(model: model)
        view.setup.step = .workspace
        view.refresh()
        let folders = try XCTUnwrap(view.subviewsOfType(WorkspaceFolderListView.self).first)
        for _ in 0..<3 { view.refresh(); XCTAssertFalse(folders.addFolders.isEnabled, "The root limit survives the outer form's refresh") }
        model.workspaces[0].paths = []
        view.refresh()
        XCTAssertTrue(folders.addFolders.isEnabled)
        view.setup.profile.baseUrl = "https://gateway.example.com"
        view.setup.profile.modelId = "fixture-model"
        view.setup.key = "fixture-key"
        let save = Task { await view.setup.save { profile, _ in
            try await Task.sleep(for: .seconds(30))
            return profile
        } }
        defer { save.cancel() }
        try await eventually("onboarding save to hold the form disabled") { view.setup.saving }
        for _ in 0..<3 { view.refresh(); XCTAssertFalse(folders.addFolders.isEnabled, "Busy state combines with the folder list's own state") }
        save.cancel()
        _ = await save.value
        view.refresh()
        XCTAssertTrue(folders.addFolders.isEnabled, "Cancellation restores eligible controls")
        model.workspaces[0].paths = (1..<WorkspaceModel.maximumRoots).map { root.appendingPathComponent("folder-\($0)").path }
        view.refresh(); view.refresh()
        XCTAssertFalse(folders.addFolders.isEnabled)
    }

    @MainActor func testNativeSheetRoutesEditingKeysAndDismissalThroughItsWindow() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        for (characters, modifiers, code) in [("\u{1b}", NSEvent.ModifierFlags(), UInt16(53)), (".", .command, UInt16(47))] {
            var submissions = 0, dismissed = false
            let first = PiKit.TextField(placeholder: "First", onSubmit: { submissions += 1 })
            let second = PiKit.TextField(placeholder: "Second")
            let body = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
            first.frame = NSRect(x: 20, y: 100, width: 280, height: 30)
            second.frame = NSRect(x: 20, y: 50, width: 280, height: 30)
            body.addSubview(first); body.addSubview(second)
            first.field.nextKeyView = second.field; second.field.nextKeyView = first.field
            let sheet = PiKit.Sheet("Editing", content: body)
            sheet.width = 420; sheet.height = 260
            var presentation: PiSheetWindow?
            sheet.dismiss = { dismissed = true; presentation?.end(animated: false, requested: true) }
            presentation = PiSheetWindow(content: sheet, inherited: .init(reduceMotion: true, enabled: true), close: {})
            defer { presentation?.end(animated: false, requested: true); sheet.dismiss = nil }
            presentation?.present(on: parent)
            let window = try XCTUnwrap(parent.attachedSheet)
            window.makeKeyAndOrderFront(nil)
            func send(_ text: String, _ modifiers: NSEvent.ModifierFlags, _ code: UInt16) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            XCTAssertTrue(window.makeFirstResponder(first.field))
            try send("\r", [], 36)
            XCTAssertEqual(submissions, 1)
            try send("\t", [], 48)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === second.field)
            try send("\t", .shift, 48)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === first.field)
            try send(characters, modifiers, code)
            try await eventually("editing sheet to dismiss through window events") { dismissed && parent.attachedSheet == nil }
        }
    }

    private struct XCTUnwrapError: Error { let title: String; init(_ title: String) { self.title = title } }

    func testShippedSourceHasNoSwiftUIImportOrHostingView() throws {
        let macOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = macOS.appendingPathComponent("PiApp")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Sources are not beside this test bundle") }
        let imports = try NSRegularExpression(pattern: "(?m)^\\s*(?:@[^\\n]+\\s+)?import\\s+SwiftUI\\b|\\bNSHosting(?:View|Controller)\\s*[<(]")
        var violations: [String] = []
        let package = macOS.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packages/bello-views/Sources")
        for root in [source, package] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if imports.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    violations.append(root.lastPathComponent + "/" + String(file.path.dropFirst(root.path.count + 1)))
                }
            }
        }
        XCTAssertEqual(violations.sorted(), [], "The shipped app must use native AppKit throughout")
    }
}
