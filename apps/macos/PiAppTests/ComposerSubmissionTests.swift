import XCTest
import AppKit
import SwiftUI
@testable import PiApp

final class ComposerSubmissionTests: XCTestCase {
    @MainActor private func key(_ code: UInt16 = 36, _ flags: NSEvent.ModifierFlags = [], editor: ComposerTextView) {
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!)
    }
    @MainActor func testNativeEnterModifiersCompletionAndIME() {
        let editor = ComposerTextView(); editor.isRichText = false
        var intents: [ComposerSubmissionIntent] = [], completions = 0
        editor.send = { intents.append($0) }
        editor.completionKey = { _, flags in
            guard flags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            completions += 1; return true
        }
        for code: UInt16 in [36, 76] {
            key(code, editor: editor); XCTAssertTrue(intents.isEmpty)
            key(code, .command, editor: editor); XCTAssertEqual(intents, [.steer]); intents.removeAll()
        }
        XCTAssertEqual(completions, 2)
        editor.completionKey = nil
        for code: UInt16 in [36, 76] {
            key(code, editor: editor); key(code, .command, editor: editor)
            XCTAssertEqual(intents, [.followUp, .steer]); intents.removeAll()
            for flags: NSEvent.ModifierFlags in [.shift, [.shift, .command], [.shift, .option], .option, .control] {
                key(code, flags, editor: editor); XCTAssertTrue(intents.isEmpty)
            }
        }
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        key(36, .command, editor: editor); XCTAssertTrue(intents.isEmpty)
    }

    /// AppKit offers a ⌘ key to the window's views, then to the menu bar, and
    /// only then to keyDown. The composer being typed in claims ⌘↩ at the
    /// first step, so no menu's ⌘↩ can turn a steer into a queued follow-up,
    /// as the Conversation menu's did before 0.1.95.
    @MainActor func testTheFocusedComposerClaimsCommandReturnBeforeTheMenuBar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)); window.contentView = content
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100)), other = ComposerTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
        editor.isRichText = false; other.isRichText = false
        content.addSubview(editor); content.addSubview(other)
        var intents: [ComposerSubmissionIntent] = [], elsewhere: [ComposerSubmissionIntent] = []
        editor.send = { intents.append($0) }; other.send = { elsewhere.append($0) }
        XCTAssertTrue(window.makeFirstResponder(editor))
        func equivalent(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            window.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                                               context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!)
        }
        for code: UInt16 in [36, 76] {
            XCTAssertTrue(equivalent(code, .command), "The composer takes ⌘↩ before the menu bar is asked")
            XCTAssertEqual(intents, [.steer]); intents.removeAll()
            for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
                XCTAssertFalse(equivalent(code, flags), "Only ⌘↩ is claimed: \(flags.rawValue)")
            }
        }
        XCTAssertTrue(intents.isEmpty)
        XCTAssertTrue(elsewhere.isEmpty, "A composer nobody is typing in claims nothing")
    }

    /// The field's height is its scroll view's own: the text reports its
    /// height to the scroll view in the layout pass that lays a new line
    /// out, and the scroll view asks SwiftUI to size it again. It used to go
    /// through SwiftUI state a run-loop turn later, so each new line was
    /// drawn in the old frame first, and a chat switch showed the previous
    /// chat's height until the new editor reported its own.
    @MainActor func testTheFieldTakesItsHeightFromItsText() throws {
        var text = "One line"
        let hosted = NSHostingView(rootView: ComposerHeightProbe(text: Binding(get: { text }, set: { text = $0 })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        func settle() { for _ in 0..<3 { hosted.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
        settle()
        let scroll = try XCTUnwrap(ConversationPaneTests.views(ComposerScrollView.self, in: hosted).first)
        let editor = try XCTUnwrap(scroll.documentView as? ComposerTextView)
        XCTAssertEqual(scroll.frame.height, ComposerScrollView.minimumHeight, accuracy: 0.5)
        editor.insertText("\nTwo\nThree\nFour\nFive", replacementRange: editor.selectedRange())
        hosted.layoutSubtreeIfNeeded()
        // In the pass that laid the lines out, before any run-loop turn.
        XCTAssertGreaterThan(scroll.intrinsicContentSize.height, ComposerScrollView.minimumHeight + 40, "the text reported its height in the same pass")
        settle()
        XCTAssertEqual(scroll.frame.height, scroll.intrinsicContentSize.height, accuracy: 0.5, "SwiftUI sized the field to its text")
        editor.insertText(String(repeating: "\nMore", count: 40), replacementRange: editor.selectedRange())
        settle()
        XCTAssertEqual(scroll.frame.height, ComposerScrollView.maximumHeight, accuracy: 0.5, "it stops at the ceiling")
        // Cleared through the model, as sending clears it.
        text = ""
        hosted.rootView = ComposerHeightProbe(text: Binding(get: { text }, set: { text = $0 }))
        settle()
        XCTAssertEqual(scroll.frame.height, ComposerScrollView.minimumHeight, accuracy: 0.5, "clearing brings it back to one line")
    }

    /// A sheet of the workspace window owns the keyboard: the conversation's
    /// shortcuts (⌘↩ send or steer, ⌘. stop, ⌘F search) stand down while it is
    /// up. ⌘↩ in the Git commit field used to send the chat's draft behind it.
    @MainActor func testASheetTakesTheConversationShortcutsAway() {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "sheet-chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p")
        model.chats = [chat]; model.selectedID = chat.id
        XCTAssertTrue(model.conversationCommandsEnabled)
        for present in [{ model.showGit = true }, { model.showProfiles = true }, { model.showResources = true },
                        { model.showWorkspaceManager = true }, { model.showConversationContent = true }] as [() -> Void] {
            present()
            XCTAssertTrue(model.presentsSheet); XCTAssertFalse(model.conversationCommandsEnabled)
            model.showGit = false; model.showProfiles = false; model.showResources = false
            model.showWorkspaceManager = false; model.showConversationContent = false
            XCTAssertTrue(model.conversationCommandsEnabled)
        }
    }

    /// The menu bar's ⌘↩ is the composer's send-or-steer, for when the
    /// keyboard is elsewhere; it used to be "Send / Queue Follow-up".
    @MainActor func testTheMenuBarGivesCommandReturnToSendOrSteer() throws {
        let menus = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu)
        menus.forEach { $0.update() }
        let items = menus.flatMap(\.items)
        guard items.contains(where: { $0.title == "Send / Queue Follow-up" }) else { throw XCTSkip("This test host has no Conversation menu") }
        let bound = items.filter { $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command }
        XCTAssertEqual(bound.map(\.title), ["Send / Steer Current Run"])
    }

    @MainActor func testUncommittedSkillAndNonChatPageCannotSubmit() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "origin"); view.draft = "/uncommitted"; view.directCommand = true
        model.displays[view.id] = view
        model.submitComposer(intent: .steer, sessionID: view.id)
        XCTAssertEqual(view.draft, "/uncommitted"); XCTAssertTrue(view.skills.isEmpty)
        XCTAssertTrue(view.notice.contains("Select the skill")); XCTAssertFalse(view.loading)
        XCTAssertFalse(model.completionKey(36, modifiers: .command, view: view))
        model.page = .report
        view.notice = "unchanged"
        model.submitComposer(intent: .followUp, sessionID: view.id)
        XCTAssertEqual(view.notice, "unchanged"); XCTAssertFalse(view.loading)
    }

    @MainActor func testNativeKeysReachDurableHelperLanesAndPreserveDraftOnStaleBusyState() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("composer-lanes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("scripts/test-native-host.py").path, "--serve"]
        fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        try fixture.run(); defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading, greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let workspace = WorkspaceRecord(id: "keys", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "slow"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture-secret")]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("empty").path), "skills": .bool(false)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "origin", workspaceID: workspace.id, title: "Keyboard fixture", path: nil, profileID: profile.id)
        let view = SessionDisplay(id: chat.id); model.chats = [chat]; model.displays[chat.id] = view
        model.selectedID = chat.id; model.selected = view
        let editor = ComposerTextView(); editor.send = { model.submitComposer(intent: $0, sessionID: chat.id) }
        func accepted() async throws {
            for _ in 0..<200 { if !view.loading { return }; try await Task.sleep(for: .milliseconds(10)) }
            XCTFail("Helper admission did not finish")
        }
        view.draft = "start"; key(76, .command, editor: editor); try await accepted()
        XCTAssertNil(view.sendFailure); XCTAssertEqual(view.draft, "")
        let host = try XCTUnwrap(model.hosts[workspace.id]); view.state = "running"
        view.draft = "follow up"; key(editor: editor); key(editor: editor)
        // A newer edit made before durable acceptance belongs to the reader.
        view.draft = "newer edit"; try await accepted(); XCTAssertEqual(view.draft, "newer edit")
        model.focusedSessionID = "unrelated"
        view.draft = "steering"; key(76, .command, editor: editor); try await accepted()
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
        let queue = snapshot["queue"]?.array?.compactMap(\.object) ?? []
        XCTAssertEqual(queue.filter { $0["kind"]?.string == "follow-up" }.count, 1)
        XCTAssertEqual(queue.filter { $0["kind"]?.string == "steering" }.count, 1)
        XCTAssertEqual(snapshot["commands"]?.array?.count, 3, "One key yields one acceptance; double presses while loading do not duplicate")
        _ = try await host.request("turn.stop", sessionID: chat.id)
        for _ in 0..<200 {
            let state = try await host.request("session.snapshot", sessionID: chat.id).object ?? [:]
            if state["state"]?.string == "paused" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The next assertions deliberately simulate stale UI run state. Stop
        // live snapshot publication so an unrelated cancellation observation
        // cannot race those assignments or open an uncertainty-review sheet.
        for _ in 0..<200 where view.snapshotInFlight { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(view.snapshotInFlight)
        view.snapshotInFlight = true
        defer { view.snapshotInFlight = false }
        view.uncertain = false
        view.state = "running"; view.draft = "preserved stale steer"
        key(36, .command, editor: editor); try await accepted()
        XCTAssertEqual(view.draft, "preserved stale steer")
        XCTAssertEqual(view.sendFailure, "The run finished. Press Return to send this as a new message.")
        XCTAssertFalse(view.uncertain)
        view.state = "paused"; key(36, .command, editor: editor); try await accepted()
        XCTAssertTrue(view.sendFailure?.contains("Resume or remove") == true)
        XCTAssertEqual(view.draft, "preserved stale steer")
    }
}

/// The native field alone, sized as the composer sizes it.
private struct ComposerHeightProbe: View {
    @Binding var text: String
    var body: some View { NativeComposer(text: $text, send: { _ in }).fixedSize(horizontal: false, vertical: true).frame(width: 480) }
}
