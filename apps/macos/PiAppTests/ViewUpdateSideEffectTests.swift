import XCTest
import SwiftUI
import AppKit
import Combine
import ObjectiveC
@testable import PiApp

/// Nothing the app does from inside a SwiftUI update may change SwiftUI state,
/// publish an observable object or move the first responder: each of those
/// schedules another update from inside the one running, or lays the window
/// out again in the middle of it. That is the class of the 0.1.89 freeze,
/// where one update kept scheduling the next. SwiftUI reports every such
/// side effect in the process log (`SwiftUIRuntimeIssues`); these scenes must
/// leave nothing there.
final class ViewUpdateSideEffectTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// A long reply streaming into the page: each token reaches the reply's
    /// surface from inside the window's update, and the block that holds the
    /// caret changes as paragraphs arrive. The caret and the copy target are
    /// published after that update, never during it.
    @MainActor func testAStreamingReplyPublishesNothingDuringAViewUpdate() async throws {
        let paragraphs = (0..<10).map { "Paragraph \($0) of a long reply, with **bold** and `code` so it is real Markdown." }
        var reply = TranscriptMessage(id: "reply", role: "assistant", text: paragraphs.joined(separator: "\n\n"), at: 2_000, turn: "u1")
        reply.state = "streaming"
        let pane = try ConversationPaneTests.Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Write it all out.", at: 1_000, turn: "u1"), reply])
        defer { pane.close() }
        pane.session.state = "running"
        await pane.settle(12)
        let start = Date()
        var text = pane.session.messages[1].text
        for index in 0..<12 {
            // A new paragraph moves the caret to a new block; a word extends the last.
            text += index % 3 == 0 ? "\n\nNew paragraph \(index) arriving" : " more words \(index)"
            pane.session.messages[1].text = text
            await pane.settle(3)
        }
        pane.session.messages[1].state = nil
        pane.session.state = "idle"
        await pane.settle(8)
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while a reply streamed")
    }

    /// Switching a reply to its markdown source and back rebuilds the reply's
    /// row, re-measures it and moves the rows under it, all from the click
    /// (`ReplySource`): nothing is published from inside a SwiftUI update.
    @MainActor func testSwitchingAReplyToItsSourcePublishesNothingDuringAViewUpdate() async throws {
        let sections = (0..<12).map { "## Part \($0)\nParagraph \($0) with **bold**, `code` and a [link](https://example.com)." }
        let pane = try ConversationPaneTests.Pane(messages: [
            TranscriptMessage(id: "u1", role: "user", text: "Write it **all** out,\n- as typed.", at: 1_000, turn: "u1"),
            TranscriptMessage(id: "a1", role: "assistant", text: sections.joined(separator: "\n\n"), state: "complete", at: 2_000, turn: "u1"),
            TranscriptMessage(id: "u2", role: "user", text: "And a short one.", at: 3_000, turn: "u2"),
            TranscriptMessage(id: "a2", role: "assistant", text: "A short **reply**.", state: "complete", at: 4_000, turn: "u2")
        ])
        defer { pane.close() }
        await pane.settle(12)
        let document = try XCTUnwrap(descendants(TranscriptNativeDocument.self, in: pane.hosted).first)
        let rows = ["a1", "a2"].compactMap { id in document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == id } }
        XCTAssertEqual(rows.count, 2, "Both replies have a row of text")
        let start = Date()
        for _ in 0..<2 {
            for (row, id) in zip(rows, ["a1", "a2"]) {
                row.toggleDisclosure(.source(id)); await pane.settle(6)
                row.toggleDisclosure(.source(id)); await pane.settle(6)
            }
        }
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while replies switched to their source and back")
    }

    /// Switching an edited message to an earlier version and back swaps the
    /// rows under the page, and each switcher's marker learns its message in
    /// its own update: nothing is published from inside one.
    @MainActor func testSwitchingVersionsPublishesNothingDuringAViewUpdate() async throws {
        let pane = try await MessageVersionTranscriptTests.pane(); defer { pane.close() }
        let start = Date()
        let document = try MessageVersionTranscriptTests.document(pane)
        document.actionRelay.forwarded.switchVersion?("u2b", -1)
        await MessageVersionTranscriptTests.shown(pane, version: 1)
        document.actionRelay.forwarded.switchVersion?("u2", 1)
        await MessageVersionTranscriptTests.shown(pane, version: nil)
        XCTAssertTrue(pane.model.stepVersion(sessionID: pane.chat.id, step: -1))
        await MessageVersionTranscriptTests.shown(pane, version: 1)
        document.actionRelay.forwarded.latestVersion?()
        await MessageVersionTranscriptTests.shown(pane, version: nil)
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while versions switched")
    }

    /// Opening the report hides the conversation's native views and takes the
    /// keyboard from the composer. Doing that inside the window's update made
    /// the composer's text view commit a Core Animation transaction that laid
    /// the window out again in the middle of the update.
    @MainActor func testOpeningTheReportMovesFocusAfterTheWindowsUpdate() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("report-focus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["Focused chat"])
        let model = bench.model, chat = bench.chats[0]
        let session = SessionDisplay(id: chat.id)
        model.displays[chat.id] = session; model.selectedID = chat.id; model.selected = session; model.focusedSessionID = chat.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { model.shutdown(); window.contentView = nil; window.close() }
        for _ in 0..<10 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let editor = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first, "The composer is on screen")
        // A composer being typed into: its insertion point is blinking.
        window.makeFirstResponder(editor)
        editor.insertText("Draft", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        FirstResponderMoves.start()
        defer { FirstResponderMoves.stop() }
        for _ in 0..<2 {
            model.page = .report
            for _ in 0..<15 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).allSatisfy(\.isHiddenOrHasHiddenAncestor), "The report hides the composer")
            XCTAssertFalse(window.firstResponder is ComposerTextView, "The report takes the keyboard from the composer")
            model.page = .chats
            for _ in 0..<15 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(window.firstResponder === editor, "Closing the report gives the composer the keyboard back")
        }
        XCTAssertEqual(FirstResponderMoves.insideUpdates, [], "The first responder moved from inside a SwiftUI update")
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while the report opened and closed")
    }

    /// The Changes panel keeps the window it is in, so a confirmation can be a
    /// sheet on it. It learned the window by writing its state from
    /// `updateNSView`, on every update of the panel.
    @MainActor func testTheChangesPanelLearnsItsWindowAfterItsUpdate() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("changes-window-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = root; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try Data("first\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try git(["add", "."]); try git(["commit", "-q", "-m", "First"])
        try Data("first\nsecond\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent(".state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let start = Date()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GitPanelView(model: model, roots: [root.path]))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<60 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while the Changes panel opened and loaded")
    }

    /// The caret and copy target of a reply's block are published on the turn
    /// after the update that changed them, and only when they did change.
    @MainActor func testTheReplyDecorationPublishesOnTheTurnAfterItChanges() async throws {
        let decoration = MarkdownBlockDecoration()
        var published = 0
        let subscription = decoration.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        decoration.update(caret: true, target: nil)
        XCTAssertEqual(published, 0, "Nothing is published from inside the update that asked")
        XCTAssertFalse(decoration.caret)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(published, 1)
        XCTAssertTrue(decoration.caret)
        // Several changes in one update publish once, with the newest values.
        decoration.update(caret: false, target: nil)
        decoration.update(caret: true, target: nil)
        decoration.update(caret: false, target: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(published, 2)
        XCTAssertFalse(decoration.caret)
        // Values it already shows publish nothing.
        decoration.update(caret: false, target: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(published, 2)
    }

    /// "Show all" in the Inspector puts a text in place: the outline's rows
    /// change and a Turn page's prompt card grows when the text arrives from
    /// its worker, never from inside the update that asked for it; a new width
    /// is laid out again the same way.
    @MainActor func testShowingATextWholeInPlacePublishesNothingDuringAViewUpdate() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: InspectorExpandInPlaceTests.result))
        defer { fixture.close() }
        let model = InspectorPromptExpansion()
        let whole = InspectorExpandBodies.toolResult(lines: 200)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView { InspectorPromptCard(preview: String(whole.prefix(2_000)), model: model, showAll: {}).padding(24) })
        window.orderFront(nil)
        defer { model.collapse(); window.contentView = nil; window.close() }
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let start = Date()
        try await fixture.showAll("item:3")
        try await fixture.showAll("section:system")
        fixture.window.setContentSize(NSSize(width: 600, height: 820))
        try await fixture.wait("the texts laid out to the new width") {
            fixture.coordinator.expansions.values.allSatisfy { !$0.laying && ($0.layout?.width ?? 0) < 600 }
        }
        await fixture.settle()
        fixture.coordinator.showLess(.item(3)); fixture.coordinator.showLess(.section(.system))
        await fixture.settle()
        model.show { (whole, (whole as NSString).length, (whole as NSString).length) }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, model.expansion?.layout == nil { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.expansion?.layout, "The prompt opened in its card")
        window.setContentSize(NSSize(width: 600, height: 640))
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        model.collapse()
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while texts opened in place and folded")
    }

    /// Return in a choice list saves the highlighted choice. SwiftUI runs key
    /// handlers inside its update of the list, so the caller's model — here a
    /// published selection — is changed on the next turn, not from there.
    @MainActor func testChoosingWithReturnPublishesAfterTheListsUpdate() async throws {
        final class Choice: ObservableObject { @Published var selection: String? = "first"; var committed: [String] = [] }
        /// The list's caller shows the saved choice, as every caller does.
        struct Host: View {
            @ObservedObject var choice: Choice
            let choices = [PiChoice(id: "first", title: "First option"), PiChoice(id: "second", title: "Second option")]
            var body: some View {
                PiChoiceList(title: "Choose", selection: choice.selection, choices: choices,
                             choose: { choice.committed.append($0); choice.selection = $0 }, cancel: {})
            }
        }
        let choice = Choice()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(choice: choice))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let start = Date()
        func key(_ code: UInt16, _ characters: String) throws {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            }
        }
        try key(125, "\u{F701}")
        try await Task.sleep(for: .milliseconds(50))
        try key(36, "\r")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, choice.committed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(choice.committed, ["second"], "Return saves the highlighted choice, once")
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates while a choice was saved from the keyboard")
    }
}

/// Records every move of a window's first responder made from inside a
/// SwiftUI update: the call stack runs through a representable's update or
/// AttributeGraph's.
@MainActor enum FirstResponderMoves {
    private(set) static var insideUpdates: [String] = []
    private static var installed = false
    static func start() {
        insideUpdates = []
        guard !installed else { return }
        installed = true; exchange()
    }
    static func stop() {
        guard installed else { return }
        installed = false; exchange()
    }
    private static func exchange() {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeFirstResponder(_:))),
              let recording = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.pi_recordingMakeFirstResponder(_:))) else { return }
        method_exchangeImplementations(original, recording)
    }
    /// The first frame outside this test bundle is whoever asked. Only the
    /// app's own requests count; SwiftUI moving focus for a focus state is
    /// SwiftUI's business.
    static func record(_ stack: [String]) {
        guard let caller = stack.first(where: { !$0.contains("PiAppTests") }), caller.contains("Bello Agent") else { return }
        let markers = ["updateNSView", "UpdateStack", "AGSubgraphUpdate", "AGGraphGetValue"]
        guard stack.contains(where: { frame in markers.contains { frame.contains($0) } }) else { return }
        let tokens = caller.split(separator: " ").map(String.init)
        let symbol = tokens.firstIndex { $0.hasPrefix("0x") }.flatMap { tokens.indices.contains($0 + 1) ? tokens[$0 + 1] : nil }
        insideUpdates.append(symbol ?? caller)
    }
}

extension NSWindow {
    @objc dynamic func pi_recordingMakeFirstResponder(_ responder: NSResponder?) -> Bool {
        FirstResponderMoves.record(Thread.callStackSymbols)
        return pi_recordingMakeFirstResponder(responder)
    }
}
