import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalPageFocusTests: XCTestCase, SerialTestLane {
    func testTerminalMenuCannotSendTypingBehindReportOrBackground() async throws {
        let fixture = try await TerminalPageFixture()
        defer { fixture.close() }
        let model = fixture.model, window = fixture.window
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { window }, revealWorkspace: {}, showSettings: {})
        menus.install()
        let toggle = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Show Terminal" })
        XCTAssertTrue(menus.validateMenuItem(toggle))
        var input = Data()
        fixture.session.view.onInput = { input.append($0) }
        for report in [true, false] {
            model.terminalVisible = false
            if report { model.openReport() } else { model.toggleBackgroundRequests() }
            await fixture.settle()
            XCTAssertFalse(menus.validateMenuItem(toggle), "terminal command belongs to Chats")
            // Dispatch the actual menu selector too, so validation alone
            // cannot hide an unguarded action.
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            await fixture.settle()
            XCTAssertEqual(model.page, report ? .report : .background)
            XCTAssertFalse(model.terminalVisible)
            XCTAssertFalse(window.firstResponder === fixture.session.view, "covered shell must never take focus")
            try fixture.typeProbe()
            XCTAssertTrue(input.isEmpty, "typing on the report must send no terminal bytes: \(String(decoding: input, as: UTF8.self))")
            model.page = .chats
            await fixture.settle()
        }
    }

    func testDeferredTerminalFocusRechecksPageEnabledAndAttachment() async throws {
        let fixture = try await TerminalPageFixture()
        defer { fixture.close() }
        let model = fixture.model, window = fixture.window
        for reason in ["page", "disabled", "hidden", "detached"] {
            model.page = .chats
            let panel = TerminalPanelView(model: model, workspace: fixture.project)
            window.contentView = panel
            switch reason {
            case "page": model.page = .report
            case "disabled": panel.inheritedEnabled = false
            case "hidden": panel.isHidden = true
            default: window.contentView = NSView()
            }
            window.makeFirstResponder(nil)
            await fixture.settle()
            XCTAssertFalse(window.firstResponder === fixture.session.view, "deferred focus survived \(reason)")
            XCTAssertFalse(fixture.session.view.focusWhenInWindow, "detached panels must not leave a future focus request")
        }
    }

    func testAnAlreadyShownTerminalIsHiddenByTheReportAndRestoredOnReturn() async throws {
        let fixture = try await TerminalPageFixture()
        defer { fixture.close() }
        fixture.model.toggleTerminal()
        try await eventually("terminal focused on Chats") { fixture.window.firstResponder === fixture.session.view }
        fixture.model.openReport()
        await fixture.settle()
        XCTAssertTrue(fixture.session.view.isHiddenOrHasHiddenAncestor, "native terminal belongs to page visibility")
        XCTAssertFalse(fixture.window.firstResponder === fixture.session.view)
        fixture.model.closeReport()
        await fixture.settle()
        XCTAssertFalse(fixture.session.view.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(fixture.window.firstResponder === fixture.session.view)
    }
}

@MainActor final class TerminalPageFixture {
    let root: URL
    let project: WorkspaceRecord
    let model: WorkspaceModel
    let window: NSWindow
    let session: TerminalSession
    init() async throws {
        root = scratchRoot("terminal-page")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "terminal-page-" + UUID().uuidString, path: root.path, trusted: true)
        self.project = project
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        self.model = model
        _ = try await model.vault.update(expectedRevision: 0) { $0.workspaces = [project] }
        try await model.reloadConfiguration()
        model.selectedWorkspaceID = project.id
        let chat = ChatRecord(id: "chat", workspaceID: project.id, title: "Terminal page fixture", path: nil, profileID: "fixture")
        model.chats = [chat]; model.selectedID = chat.id; model.displays[chat.id] = SessionDisplay(id: chat.id)
        model.selected = model.displays[chat.id]; model.focusedSessionID = chat.id
        session = try XCTUnwrap(TerminalRegistry.shared.ensureInitialSession(for: project))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
    }
    func settle() async {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func typeProbe() throws {
        for (text, code) in [("echo BELLO_UI_PROBE", UInt16(14)), ("\r", UInt16(36))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            window.firstResponder?.keyDown(with: event)
        }
    }
    func close() {
        window.contentView = nil; window.close()
        TerminalRegistry.shared.close(workspaceID: project.id)
        model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
