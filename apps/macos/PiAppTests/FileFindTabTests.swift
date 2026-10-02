import XCTest
import SwiftUI
import FileView
@testable import PiApp

/// Find and go to line in a file tab, as the reader works them: ⌘F in the
/// text opens the find bar with the keys in its field, a selection on one
/// line its query; typing finds as it goes; ⌘G, ⇧⌘G and Return go on and
/// back; Escape closes it and gives the keys back to the text; ⌘L goes to a
/// line, the last if past the end. Elsewhere ⌘F and ⇧⌘G stay the menus'. The
/// same in a tab's own window.
final class FileFindTabTests: XCTestCase {
    @MainActor private func model() async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("file-find-tab-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key")]
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        addTeardownBlock { @MainActor in for window in model.tabs.windows { model.tabs.window(of: window)?.close() } }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "main", workspaceID: "w", title: "Main", path: nil, profileID: profile.id)
        let main = SessionDisplay(id: chat.id)
        main.messages = [TranscriptMessage(id: "u1", role: "user", text: "The chat")]
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main]
        return (model, root)
    }
    @MainActor private func window(_ model: WorkspaceModel) -> (NSWindow, NSHostingView<WorkspaceView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        hosted.layoutSubtreeIfNeeded()
        return (window, hosted)
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func file(_ root: URL, _ name: String, lines: Int = 400) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((0..<lines).map { "line \($0) with some words in it" }.joined(separator: "\n").utf8).write(to: url)
        return url
    }
    @MainActor private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    /// The field editor of a field in a tab's content, if it has the keys.
    @MainActor private func fieldEditor(in window: NSWindow, of tab: HostedTab) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.isDescendant(of: tab.contentView) else { return nil }
        return editor
    }
    /// Types over what the field has selected, as the keys would.
    @MainActor private func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @MainActor func testCommandFFindsAsTypedAndEscapeGivesTheKeysBack() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "f.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(window.makeFirstResponder(text))
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        // A selection on one line becomes the query.
        text.select(from: FileTextPosition(line: 12, column: 0), to: FileTextPosition(line: 12, column: 7))
        try await eventually("its text come") { text.selectedText == "line 12" }
        XCTAssertTrue(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        XCTAssertEqual(tab.bar, .find)
        XCTAssertEqual(tab.findQuery, "line 12")
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the find field has the keys") { self.fieldEditor(in: window, of: tab) != nil }
        let editor = try XCTUnwrap(fieldEditor(in: window, of: tab))
        // "line 1" is on lines 1, 10 to 19 and 100 to 199: line 12 is the fourth.
        type("line 1", into: editor)
        try await eventually("typed") { tab.findQuery == "line 1" }
        try await eventually("found and counted") { tab.findLabel == "4 of 111 matches" }
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 12, column: 0))
        XCTAssertTrue(controller.takesKey(try key("g", .command, keyCode: 5, in: window)), "⌘G in the field")
        try await eventually("on") { tab.findLabel == "5 of 111 matches" }
        XCTAssertTrue(controller.takesKey(try key("G", [.command, .shift], keyCode: 5, in: window)), "⇧⌘G in the field")
        try await eventually("back") { tab.findLabel == "4 of 111 matches" }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await eventually("Return goes on") { tab.findLabel == "5 of 111 matches" }
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 13, column: 0))
        XCTAssertNotNil(text.find, "matches drawn")
        // Escape closes the bar and gives the keys back to the text.
        window.sendEvent(try key("\u{1B}", [], keyCode: 53, in: window))
        try await eventually("closed") { tab.bar == .none }
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertNil(text.find, "no matches drawn")
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 13, column: 0), "the match stays selected")
        // ⌘F again: the query as it was, the keys in the field, all of it
        // selected to type over; and again with the keys already there.
        text.select(from: FileTextPosition(line: 3, column: 0), to: FileTextPosition(line: 3, column: 0))
        XCTAssertTrue(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        XCTAssertEqual(tab.findQuery, "line 1")
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the field again, its text selected") { self.fieldEditor(in: window, of: tab)?.selectedRange() == NSRange(location: 0, length: 6) }
        let again = try XCTUnwrap(fieldEditor(in: window, of: tab))
        again.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        try await eventually("selected again") { again.selectedRange() == NSRange(location: 0, length: 6) }
        type("line 2", into: again)
        try await eventually("typed over") { tab.findQuery == "line 2" }
    }

    @MainActor func testCommandLGoesToALineAndThePastTheEndToTheLast() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "l.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(window.makeFirstResponder(text))
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        for (asked, line) in [("250", 249), ("99999", 399), (" 7 ", 6)] {
            XCTAssertTrue(controller.takesKey(try key("l", .command, keyCode: 37, in: window)))
            XCTAssertEqual(tab.bar, .goToLine)
            hosted.layoutSubtreeIfNeeded()
            try await eventually("the line field has the keys") { self.fieldEditor(in: window, of: tab) != nil }
            let editor = try XCTUnwrap(fieldEditor(in: window, of: tab))
            type(asked, into: editor)
            try await eventually("typed") { tab.lineQuery == asked }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await eventually("gone to \(asked)") { text.focus.line == line }
            XCTAssertEqual(tab.bar, .none)
            XCTAssertTrue(window.firstResponder === text)
            XCTAssertTrue(text.visibleLines.contains(line))
        }
        // Not a number: nothing happens, the bar stays for another.
        XCTAssertTrue(controller.takesKey(try key("l", .command, keyCode: 37, in: window)))
        tab.lineQuery = "twelve"
        tab.goToLine()
        XCTAssertEqual(tab.bar, .goToLine)
        XCTAssertEqual(text.focus.line, 6)
    }

    @MainActor func testCommandKeysElsewhereStayTheMenus() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "m.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        // The text with no find open: ⌘G and ⇧⌘G go on (⇧⌘G is Changes and History).
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertFalse(controller.takesKey(try key("g", .command, keyCode: 5, in: window)))
        XCTAssertFalse(controller.takesKey(try key("G", [.command, .shift], keyCode: 5, in: window)))
        XCTAssertFalse(controller.tabKey(try key("w", .command, keyCode: 13, in: window)), "⌘W is the pane's")
        // The chat's composer: ⌘F is the conversation's search, as before.
        let composer = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertFalse(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        XCTAssertFalse(controller.takesKey(try key("l", .command, keyCode: 37, in: window)))
        XCTAssertEqual(tab.bar, .none)
        // Under a sheet, nothing is the tab's.
        XCTAssertTrue(window.makeFirstResponder(text))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        try await eventually("the sheet up") { window.attachedSheet === sheet }
        XCTAssertFalse(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        window.endSheet(sheet)
        try await eventually("the sheet down") { window.attachedSheet == nil }
        XCTAssertTrue(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
    }

    @MainActor func testKeysInATabsOwnWindow() async throws {
        let (model, root) = try await model()
        let (_, hosted) = window(model)
        model.tabs.showsWindows = true
        let tab = model.openFile(try file(root, "w.txt"))
        hosted.layoutSubtreeIfNeeded()
        let popped = model.tabs.popOut(tab)
        let other = try XCTUnwrap(model.tabs.window(of: popped))
        other.contentView?.layoutSubtreeIfNeeded()
        try await eventually("shown in its window and read") { tab.focusView?.window === other && tab.status == .ready }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(other.makeFirstResponder(text))
        XCTAssertTrue(other.performKeyEquivalent(with: try key("f", .command, keyCode: 3, in: other)))
        XCTAssertEqual(tab.bar, .find)
        other.contentView?.layoutSubtreeIfNeeded()
        try await eventually("the find field has the keys") { self.fieldEditor(in: other, of: tab) != nil }
        let editor = try XCTUnwrap(fieldEditor(in: other, of: tab))
        type("words", into: editor)
        try await eventually("found and counted") { tab.findLabel == "1 of 400 matches" }
        XCTAssertTrue(other.performKeyEquivalent(with: try key("g", .command, keyCode: 5, in: other)))
        try await eventually("on") { tab.findLabel == "2 of 400 matches" }
        XCTAssertTrue(other.performKeyEquivalent(with: try key("l", .command, keyCode: 37, in: other)))
        XCTAssertEqual(tab.bar, .goToLine)
        XCTAssertNil(text.find, "going to a line closes the find")
    }

    // MARK: Through a reload (D6)

    /// The text, as `file` writes it, with some lines replaced.
    private func contents(lines: Int = 400, replacing: [Int: String] = [:], appending: [String] = []) -> Data {
        Data(((0..<lines).map { replacing[$0] ?? "line \($0) with some words in it" } + appending).joined(separator: "\n").utf8)
    }
    /// Opens a file, finds "line 1" with case matched, and steps to the
    /// fifth of its 111 matches (line 13), the field keeping the keys with
    /// part of its text selected.
    @MainActor private func findingInFile(_ name: String) async throws -> (WorkspaceModel, NSWindow, NSHostingView<WorkspaceView>, FileTab, FileTextView, NSTextView, URL) {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let url = try file(root, name)
        let tab = model.openFile(url)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready && tab.isWatching }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(window.makeFirstResponder(text))
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        text.select(from: FileTextPosition(line: 12, column: 0), to: FileTextPosition(line: 12, column: 0))
        XCTAssertTrue(controller.takesKey(try key("f", .command, keyCode: 3, in: window)))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the find field has the keys") { self.fieldEditor(in: window, of: tab) != nil }
        let editor = try XCTUnwrap(fieldEditor(in: window, of: tab))
        type("line 1", into: editor)
        tab.matchCase = true
        try await eventually("found and counted") { tab.findLabel == "4 of 111 matches" }
        tab.findNext()
        try await eventually("on to the fifth") { tab.findLabel == "5 of 111 matches" }
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 13, column: 0))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        return (model, window, hosted, tab, text, editor, url)
    }

    /// An atomic save while finding: the bar, the query, match case, the
    /// field's text, its selection and its keys stay; the count is the new
    /// text's; the match shown, still there, stays shown; nothing scrolls or
    /// moves the selection.
    @MainActor func testFindingCarriesOnThroughASaveWhereTheMatchStays() async throws {
        let (_, window, hosted, tab, text, editor, url) = try await findingInFile("save.txt")
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin, selection = text.selectedRange
        let old = tab.document
        try contents(appending: ["line 1 appended"]).write(to: url, options: .atomic)
        try await eventually("the save is read") { tab.document !== old && tab.status == .ready }
        hosted.layoutSubtreeIfNeeded()
        try await eventually("counted again") { tab.findLabel == "5 of 112 matches" }
        XCTAssertEqual(tab.bar, .find)
        XCTAssertEqual(tab.findQuery, "line 1"); XCTAssertTrue(tab.matchCase)
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor, "the field keeps the keys")
        XCTAssertEqual(editor.string, "line 1")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3), "and its selection")
        XCTAssertEqual(text.selectedRange.start, selection.start); XCTAssertEqual(text.selectedRange.end, selection.end)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1, "nothing scrolled")
        XCTAssertTrue(text.find != nil, "matches drawn, of the new text")
        tab.findNext()
        try await eventually("Next goes on from it") { tab.findLabel == "6 of 112 matches" }
    }

    /// A save that takes the match shown away: the bar stays, no match is
    /// shown, the count is the new text's, and nothing moves.
    @MainActor func testASaveThatRemovesTheMatchShownKeepsTheBarAndMovesNothing() async throws {
        let (_, window, _, tab, text, editor, url) = try await findingInFile("gone.txt")
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin, selection = text.selectedRange
        let old = tab.document
        try contents(replacing: [13: "LINE 13 in capitals now"]).write(to: url, options: .atomic)
        try await eventually("the save is read") { tab.document !== old && tab.status == .ready }
        try await eventually("counted again, nothing shown") { tab.findLabel == "110 matches" }
        XCTAssertEqual(tab.bar, .find)
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor)
        XCTAssertEqual(text.selectedRange.start, selection.start)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1)
        tab.findNext()
        try await eventually("Next finds the next one after where the reader is") { tab.findLabel.hasSuffix("of 110 matches") }
    }

    /// Two quick saves, then the query edited before the second is read: the
    /// last query, searched in the last text.
    @MainActor func testTheLastSaveAndTheLastQueryWin() async throws {
        let (_, _, _, tab, _, editor, url) = try await findingInFile("quick.txt")
        let old = tab.document
        try contents(appending: ["line 1 first"]).write(to: url, options: .atomic)
        try contents(appending: ["line 1 first", "line 2 second", "line 2 third"]).write(to: url, options: .atomic)
        editor.selectAll(nil); type("line 2", into: editor)
        try await eventually("the last text read") { tab.document !== old && tab.status == .ready && tab.document?.lineCount == 403 }
        try await eventually("the last query counted in it") { tab.findLabel.hasSuffix("113 matches") }
        XCTAssertEqual(tab.findQuery, "line 2")
    }

    /// Go to Line keeps its typed number through a save; Return then goes by
    /// the new, shorter text: past its end, to its last line.
    @MainActor func testGoToLineKeepsWhatWasTypedThroughASave() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let url = try file(root, "goto.txt")
        let tab = model.openFile(url)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready && tab.isWatching }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(window.makeFirstResponder(text))
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        XCTAssertTrue(controller.takesKey(try key("l", .command, keyCode: 37, in: window)))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the line field has the keys") { self.fieldEditor(in: window, of: tab) != nil }
        let editor = try XCTUnwrap(fieldEditor(in: window, of: tab))
        type("350", into: editor)
        let old = tab.document
        try contents(lines: 100).write(to: url, options: .atomic)
        try await eventually("the shorter text read") { tab.document !== old && tab.status == .ready }
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(tab.bar, .goToLine)
        XCTAssertEqual(tab.lineQuery, "350")
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor, "the field keeps the keys")
        XCTAssertEqual(tab.lineRange, "Lines 1 to 100")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await eventually("gone to the last line there is now") { text.focus.line == 99 }
    }

    /// The file deleted while finding: the bar and its field stay over
    /// "Missing", with no count of a text that is not there; written again,
    /// the same search counts in it.
    @MainActor func testFindingWaitsThroughADeletionAndGoesOnWhenTheFileIsBack() async throws {
        let (_, window, hosted, tab, _, editor, url) = try await findingInFile("deleted.txt")
        try FileManager.default.removeItem(at: url)
        try await eventually("shown missing") { tab.missingReason != nil }
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(tab.bar, .find)
        XCTAssertEqual(tab.findLabel, "", "no count of a file that is gone")
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor, "the field and its keys stay")
        try contents(lines: 50).write(to: url, options: .atomic)
        try await eventually("back and counted") { tab.missingReason == nil && tab.findLabel.hasSuffix("11 matches") }
        XCTAssertEqual(tab.findQuery, "line 1")
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor)
    }

    /// Replaced by something that is not text, and back: the bar stays.
    @MainActor func testABinaryReplacementKeepsTheBar() async throws {
        let (_, window, hosted, tab, _, editor, url) = try await findingInFile("binary.txt")
        let old = tab.document
        try Data([0, 1, 2, 0, 255, 0, 7]).write(to: url, options: .atomic)
        try await eventually("shown as not text") { tab.document !== old && tab.status == .binary }
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(tab.bar, .find)
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor)
        try contents().write(to: url, options: .atomic)
        try await eventually("text again, counted") { tab.status == .ready && tab.findLabel.hasSuffix("111 matches") }
        XCTAssertTrue(fieldEditor(in: window, of: tab) === editor)
    }

    /// The keys elsewhere (the text) when the save is read: they stay there.
    @MainActor func testASaveDoesNotTakeTheKeysBackToTheBar() async throws {
        let (_, window, _, tab, text, _, url) = try await findingInFile("keys.txt")
        XCTAssertTrue(window.makeFirstResponder(text))
        let old = tab.document
        try contents(appending: ["more"]).write(to: url, options: .atomic)
        try await eventually("the save is read") { tab.document !== old && tab.status == .ready }
        try await eventually("counted again") { tab.findLabel == "5 of 111 matches" }
        XCTAssertTrue(window.firstResponder === text, "the keys stay with the text")
    }

    /// Trust taken away while finding: nothing more is read, the bar goes.
    @MainActor func testTrustRevokedClosesTheBar() async throws {
        let (model, _, _, tab, text, _, _) = try await findingInFile("trust.txt")
        let saved = FileTab.resolveProject
        defer { FileTab.resolveProject = saved }
        FileTab.resolveProject = { _ in .untrusted(name: "w") }
        tab.projectsChanged()
        XCTAssertEqual(tab.bar, .none)
        XCTAssertNil(text.find, "no matches drawn")
        XCTAssertFalse(tab.hasDocument)
        _ = model
    }

    /// The reader working in another window when the save is read: that
    /// window keeps the keys and stays in front.
    @MainActor func testASaveDoesNotTakeTheKeysFromAnotherWindow() async throws {
        let (_, window, _, tab, _, _, url) = try await findingInFile("other.txt")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        other.contentView?.addSubview(field)
        other.makeKeyAndOrderFront(nil)
        defer { other.close() }
        XCTAssertTrue(other.makeFirstResponder(field))
        let keys = other.firstResponder
        let old = tab.document
        try contents(appending: ["more"]).write(to: url, options: .atomic)
        try await eventually("the save is read") { tab.document !== old && tab.status == .ready }
        try await eventually("counted again") { tab.findLabel == "5 of 111 matches" }
        XCTAssertTrue(other.firstResponder === keys, "the other window keeps its keys")
        XCTAssertTrue(other.isKeyWindow || !window.isKeyWindow, "and the file's window is not brought forward")
    }

    /// Saved while the tab is hidden: nothing is searched then; shown again,
    /// the bar is as it was and counts in the saved text.
    @MainActor func testFindingWhileHiddenCarriesOnWhenShown() async throws {
        let (_, _, _, tab, _, _, url) = try await findingInFile("hidden.txt")
        tab.didHide()
        XCTAssertFalse(tab.isWatching)
        let old = tab.document
        try contents(appending: ["line 1 while hidden"]).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(tab.document === old, "a hidden tab reads nothing")
        tab.didShow()
        try await eventually("read on showing") { tab.document !== old && tab.status == .ready }
        try await eventually("counted in it") { tab.findLabel == "5 of 112 matches" }
        XCTAssertEqual(tab.bar, .find)
    }

    /// A file with a very long line, saved while finding along it: counted
    /// again in the new text, the bar as it was.
    @MainActor func testFindingAlongAVeryLongLineCarriesOnThroughASave() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let long = String(repeating: "abc needle ", count: 200_000)
        let url = root.appendingPathComponent("long.txt")
        try Data(("first\n" + long + "\nlast").utf8).write(to: url)
        let tab = model.openFile(url)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready && tab.isWatching }
        tab.openFind(); tab.findQuery = "needle"
        try await eventually("counted along it") { tab.findLabel.hasSuffix("200,000 matches") }
        let old = tab.document
        try Data(("first\n" + long + "needle\nlast").utf8).write(to: url, options: .atomic)
        try await eventually("the save is read") { tab.document !== old && tab.status == .ready }
        try await eventually("counted again") { tab.findLabel.hasSuffix("200,001 matches") }
        XCTAssertEqual(tab.bar, .find)
    }

    /// The file replaced by a link to another file: not read under the
    /// trust the first was opened with, so nothing of it is searched or
    /// counted; the bar stays.
    @MainActor func testALinkReplacingTheFileIsNotSearched() async throws {
        let (_, _, _, tab, _, _, url) = try await findingInFile("linked.txt")
        let elsewhere = url.deletingLastPathComponent().appendingPathComponent("elsewhere-" + UUID().uuidString + ".txt")
        try contents(lines: 50).write(to: elsewhere)
        let old = tab.document
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        try await eventually("the replacement is refused") { tab.missingReason != nil }
        XCTAssertTrue(tab.document === old, "the link's target is not read")
        XCTAssertEqual(tab.bar, .find)
        XCTAssertEqual(tab.findLabel, "", "and nothing of it counted")
    }
}
