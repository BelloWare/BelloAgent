import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class WindowPresentationTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor private func waitFor(_ condition: () -> Bool, message: String) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
    }

    @MainActor private func fixtureWindow() -> (NSWindow, WindowChromeView, WindowPresentationController) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 130, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = WindowChromeView(frame: .zero), controller = WindowPresentationController()
        controller.attach(window, chrome: chrome)
        if let content = window.contentView {
            chrome.frame = NSRect(x: 0, y: content.bounds.maxY - WindowChrome.height, width: content.bounds.width, height: WindowChrome.height)
            chrome.autoresizingMask = [.width, .minYMargin]
            content.addSubview(chrome)
        }
        return (window, chrome, controller)
    }

    @MainActor private func event(_ type: NSEvent.EventType, clicks: Int, window: NSWindow, chrome: WindowChromeView, point: NSPoint? = nil) throws -> NSEvent {
        let rect = chrome.convert(chrome.bounds, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point ?? NSPoint(x: 240, y: rect.midY), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }

    @MainActor private func assertChromeLayout(_ chrome: WindowChromeView, in window: NSWindow, sidebarOnly: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        content.layoutSubtreeIfNeeded()
        let frame = chrome.convert(chrome.bounds, to: nil), contentFrame = content.convert(content.bounds, to: nil)
        XCTAssertTrue(window.styleMask.contains(.titled), "Native key-window and traffic-light behavior must remain available", file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), file: file, line: line)
        XCTAssertEqual(window.titleVisibility, .hidden, file: file, line: line)
        XCTAssertTrue(window.titlebarAppearsTransparent, file: file, line: line)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none, file: file, line: line)
        XCTAssertNil(window.toolbar, file: file, line: line)
        XCTAssertEqual(window.tabbingMode, .disallowed, "App-owned navigation must not gain a second macOS tab strip", file: file, line: line)
        XCTAssertEqual(frame.height, WindowChrome.height, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame.minX, contentFrame.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame.width, sidebarOnly ? WindowChrome.sidebarWidth : contentFrame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame.maxY, contentFrame.maxY, accuracy: 0.5, "SwiftUI must not reintroduce a titlebar inset above the custom row", file: file, line: line)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind), file: file, line: line)
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            XCTAssertFalse(button.isHidden, file: file, line: line)
            XCTAssertTrue(frame.contains(center), "The native button belongs inside the reserved custom header", file: file, line: line)
        }
    }

    @MainActor func testCustomHeaderPreservesNativeControlsAndExcludesContentFromDragging() throws {
        let (window, chrome, controller) = fixtureWindow()
        defer { controller.detach(); window.close() }
        try assertChromeLayout(chrome, in: window)
        let rect = chrome.convert(chrome.bounds, to: nil)
        XCTAssertTrue(WindowPresentationController.isTitleBarBackground(NSPoint(x: 240, y: rect.midY), in: window, chrome: chrome))
        XCTAssertFalse(WindowPresentationController.isTitleBarBackground(NSPoint(x: 240, y: rect.minY - 5), in: window, chrome: chrome), "Conversation and report headers must remain ordinary interactive content")
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            XCTAssertFalse(WindowPresentationController.isTitleBarBackground(center, in: window, chrome: chrome))
            let click = try event(.leftMouseDown, clicks: 2, window: window, chrome: chrome, point: center)
            XCTAssertTrue(controller.handle(click) === click)
        }
        let accessory = NSButton(frame: NSRect(x: 300, y: 7, width: 70, height: 22))
        chrome.addSubview(accessory)
        let center = accessory.convert(NSPoint(x: accessory.bounds.midX, y: accessory.bounds.midY), to: nil)
        XCTAssertFalse(WindowPresentationController.isTitleBarBackground(center, in: window, chrome: chrome), "Custom-header controls must receive their own clicks")
    }

    @MainActor func testDoubleClickZoomsAndRestoresWithoutLosingFocusOrEnteringFullScreen() throws {
        let (window, chrome, controller) = fixtureWindow()
        defer { controller.detach(); window.close() }
        let editor = NSTextView(frame: NSRect(x: 100, y: 100, width: 300, height: 100))
        editor.string = "Unsent draft"; window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let original = window.frame, screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let normal = try event(.leftMouseDown, clicks: 1, window: window, chrome: chrome)
        XCTAssertTrue(controller.handle(normal) === normal, "Single clicks and drag initiation stay native")
        XCTAssertEqual(window.frame, original)
        XCTAssertNil(controller.handle(try event(.leftMouseDown, clicks: 2, window: window, chrome: chrome)))
        XCTAssertNil(controller.handle(try event(.leftMouseUp, clicks: 2, window: window, chrome: chrome)))
        XCTAssertEqual(window.frame, screen.visibleFrame)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertNil(controller.handle(try event(.leftMouseDown, clicks: 2, window: window, chrome: chrome)))
        XCTAssertNil(controller.handle(try event(.leftMouseUp, clicks: 2, window: window, chrome: chrome)))
        XCTAssertEqual(window.frame, WindowPresentationController.constrained(original, to: screen.visibleFrame))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Unsent draft"); XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        let unhandledUp = try event(.leftMouseUp, clicks: 1, window: window, chrome: chrome)
        XCTAssertTrue(controller.handle(unhandledUp) === unhandledUp)
    }

    @MainActor func testDetachedControllerDoesNotHandleItsOldHeader() throws {
        let (window, chrome, controller) = fixtureWindow()
        defer { controller.detach(); window.close() }
        controller.detach()
        let original = window.frame, click = try event(.leftMouseDown, clicks: 2, window: window, chrome: chrome)
        XCTAssertTrue(controller.handle(click) === click)
        XCTAssertEqual(window.frame, original)
    }

    /// Bare NSWindow fixtures previously passed while WindowGroup restored a
    /// conflicting native strip afterward. Exercise the application's real
    /// scene after SwiftUI has had time to apply its own style and safe areas.
    @MainActor func testProductionWindowGroupKeepsCustomHeaderAtTopAfterSwiftUILayoutAndResize() async throws {
        var sceneWindow: NSWindow?
        try await waitFor({
            sceneWindow = NSApp.windows.first { window in
                guard window.windowController != nil, let content = window.contentView else { return false }
                return !self.descendants(WindowChromeView.self, in: content).isEmpty
            }
            return sceneWindow != nil
        }, message: "The application-hosted SwiftUI WindowGroup did not create its custom header")
        let window = try XCTUnwrap(sceneWindow), content = try XCTUnwrap(window.contentView)
        let chrome = try XCTUnwrap(descendants(WindowChromeView.self, in: content).first)
        let original = window.frame
        defer { window.setFrame(original, display: true, animate: false) }
        try await Task.sleep(for: .milliseconds(50))
        try assertChromeLayout(chrome, in: window, sidebarOnly: true)
        window.setContentSize(NSSize(width: 1020, height: 680))
        try await Task.sleep(for: .milliseconds(50))
        try assertChromeLayout(chrome, in: window, sidebarOnly: true)
        XCTAssertTrue(chrome.controller != nil)
    }

    @MainActor func testWorkspaceHeaderReservesSpaceAcrossChatReportAndWindowSizes() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("window-chrome-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.modelId = "auto-router"; profile.baseUrl = "https://fixture.invalid"
        let project = WorkspaceRecord(id: "chrome-project", path: root.path, trusted: true)
        let chat = ChatRecord(id: "chrome-chat", workspaceID: project.id, title: "Improve the session header", path: nil, profileID: profile.id)
        let session = SessionDisplay(id: chat.id); session.draft = "Keep this unsent draft while moving the window."
        session.messages = [TranscriptMessage(id: "chrome-user", role: "user", text: "Keep the title and controls fully visible."), TranscriptMessage(id: "chrome-answer", role: "assistant", text: "The custom window header keeps the controls above the conversation.")]
        // No connection exists in this MemoryVault. Picker discovery stops at
        // the credential boundary without network traffic or production data.
        model.profiles = [profile]; model.workspaces = [project]; model.chats = [chat]
        model.selectedID = chat.id; model.selected = session; model.displays[chat.id] = session
        model.focusedSessionID = chat.id; model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Bello Agent — Synthetic Window Fixture"
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer {
            model.report.suspend(); model.shutdown(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        try await waitFor({ self.descendants(WindowChromeView.self, in: hosted).count == 1 && self.descendants(ComposerTextView.self, in: hosted).count == 1 }, message: "The synthetic workspace did not finish its native layout")
        let chrome = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first)
        let composer = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let transcript = try XCTUnwrap(marker.enclosingScrollView, "The native transcript draws inside a scroll view")
        for (name, size, appearance) in [("chat-light", NSSize(width: 1240, height: 800), NSAppearance.Name.aqua), ("chat-compact-dark", NSSize(width: 920, height: 640), NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(80))
            try assertChromeLayout(chrome, in: window, sidebarOnly: true)
            let chromeFrame = chrome.convert(chrome.bounds, to: nil)
            // There is no conversation header: the transcript starts beside the
            // window controls, without an empty strip above it.
            XCTAssertTrue(descendants(ConversationHeaderMarkerView.self, in: hosted).isEmpty, "The chat pane has no header bar")
            let transcriptFrame = transcript.convert(transcript.bounds, to: nil)
            XCTAssertEqual(transcriptFrame.maxY, chromeFrame.maxY, accuracy: 1, "The transcript must start beside window controls, without an empty strip above it")
            XCTAssertGreaterThanOrEqual(transcriptFrame.minX, chromeFrame.maxX)
            XCTAssertLessThanOrEqual(composer.convert(composer.bounds, to: nil).maxY, chromeFrame.minY)
            try await captureIfRequested(window, name: name)
        }
        window.setContentSize(NSSize(width: 1240, height: 800)); window.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(window.makeFirstResponder(composer))
        model.openReport()
        try await waitFor({ composer.isHidden && model.report.snapshot != nil }, message: "The synthetic report did not finish opening")
        try assertChromeLayout(chrome, in: window, sidebarOnly: true)
        try await captureIfRequested(window, name: "report-light")
        model.closeReport()
        try await waitFor({ !composer.isHidden }, message: "The conversation did not return from the report")
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertEqual(session.draft, "Keep this unsent draft while moving the window.")
        XCTAssertTrue(model.hosts.isEmpty)
        model.report.suspend(); model.shutdown()
        await model.flushReadStates(); await model.flushProjectSidebarState()
        try await model.traces.close(); await model.store?.close()
    }

    /// Opt-in, own-window-only JPEGs keep visual evidence small and prevent a
    /// different application's window from entering the synthetic captures.
    @MainActor private func captureIfRequested(_ window: NSWindow, name: String) async throws {
        guard let path = testEnvironment("PI_APP_CHROME_CAPTURE_ROOT") else { return }
        // Snapshot readiness is separate from the functional assertions. Let
        // SwiftUI's 0.24s page/appearance transition and the window compositor
        // finish only when optional visual evidence is being requested.
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue())
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        try jpeg.write(to: folder.appendingPathComponent(name + ".jpg"), options: .atomic)
    }

    @MainActor func testPlainTypingRedirectsToTheComposerButShortcutsAndTextInputsDoNot() {
        let plain: NSEvent.ModifierFlags = []
        XCTAssertTrue(WindowPresentationController.shouldRedirectTyping(characters: "a", modifiers: plain, responderTakesText: false))
        XCTAssertTrue(WindowPresentationController.shouldRedirectTyping(characters: "É", modifiers: [.shift, .option], responderTakesText: false), "Shifted and option-typed characters are still typing")
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "a", modifiers: [.command], responderTakesText: false), "Shortcuts stay shortcuts")
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "a", modifiers: [.control], responderTakesText: false))
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: " ", modifiers: plain, responderTakesText: false), "Space scrolls whatever is focused")
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "\r", modifiers: plain, responderTakesText: false))
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "\u{1B}", modifiers: plain, responderTakesText: false))
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "\u{F702}", modifiers: [.function], responderTakesText: false), "Arrow keys navigate")
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "\u{7F}", modifiers: plain, responderTakesText: false))
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: nil, modifiers: plain, responderTakesText: false))
        XCTAssertFalse(WindowPresentationController.shouldRedirectTyping(characters: "a", modifiers: plain, responderTakesText: true), "A text field or the terminal keeps what is typed into it")
        XCTAssertTrue(WindowPresentationController.takesText(NSTextView(frame: .zero)))
        XCTAssertTrue(WindowPresentationController.takesText(NSTextField(frame: .zero)))
        XCTAssertFalse(WindowPresentationController.takesText(NSView(frame: .zero)))
        XCTAssertFalse(WindowPresentationController.takesText(nil))
    }

    @MainActor func testTypingWithNothingFocusedMovesTheCursorIntoTheFocusedChatsComposer() throws {
        let (window, _, controller) = fixtureWindow()
        let content = try XCTUnwrap(window.contentView)
        let main = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40)), side = ComposerTextView(frame: NSRect(x: 300, y: 0, width: 200, height: 40))
        main.sessionID = "main"; side.sessionID = "side"
        content.addSubview(main); content.addSubview(side)
        window.makeFirstResponder(nil)
        let typed = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        controller.focusedSessionID = "side"
        XCTAssertNotNil(controller.redirectTyping(typed), "The keystroke itself still goes through, into the composer")
        XCTAssertTrue(window.firstResponder === side, "Typing lands in the focused chat's composer")
        window.makeFirstResponder(nil)
        controller.focusedSessionID = "main"
        _ = controller.redirectTyping(typed)
        XCTAssertTrue(window.firstResponder === main)
        // A composer that already has the cursor is left alone, and so is a text field.
        _ = controller.redirectTyping(typed)
        XCTAssertTrue(window.firstResponder === main)
        let field = NSTextField(frame: NSRect(x: 0, y: 100, width: 200, height: 24)); content.addSubview(field)
        window.makeFirstResponder(field)
        _ = controller.redirectTyping(typed)
        XCTAssertFalse(window.firstResponder === main, "Typing into the sidebar filter stays there")
        // A shortcut never moves focus.
        window.makeFirstResponder(nil)
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        _ = controller.redirectTyping(shortcut)
        XCTAssertFalse(window.firstResponder === main || window.firstResponder === side)
        controller.detach()
    }

    @MainActor func testEveryWindowWearsTheAppsChromeInsteadOfTheSystemTitleBar() throws {
        XCTAssertGreaterThan(PiWindowBar.trafficLightInset, 60, "content must clear the window buttons")
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "Session info"
        panel.applyPiWindowChrome()
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.styleMask.contains(.titled), "native key handling and the window buttons stay")
        XCTAssertEqual(panel.titleVisibility, .hidden); XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titlebarSeparatorStyle, .none); XCTAssertNil(panel.toolbar)
        XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, false, "the traffic lights remain native")
        XCTAssertEqual(panel.title, "Session info", "the title still names the window in the Window menu")
        // A window with no title bar to replace is left alone.
        let borderless = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        borderless.isReleasedWhenClosed = false
        borderless.applyPiWindowChrome()
        XCTAssertFalse(borderless.styleMask.contains(.fullSizeContentView))
        // Hosting the bar applies the same chrome, and the strip never lets the background drag the window by itself.
        let bar = PiWindowBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        XCTAssertFalse(bar.mouseDownCanMoveWindow); XCTAssertTrue(bar.acceptsFirstMouse(for: nil))
        let hosted = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        hosted.isReleasedWhenClosed = false
        hosted.contentView?.addSubview(bar)
        XCTAssertEqual(hosted.titleVisibility, .hidden, "a window that hosts the bar loses the system title bar")
        XCTAssertTrue(hosted.titlebarAppearsTransparent)
    }
}
