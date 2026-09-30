import XCTest
import SwiftUI
import FileView
@testable import PiApp

/// A file a chat's tool read or changed opens from its path in the chat: in a
/// tab of the pane, at the lines the read returned or the change made (when
/// the host said where), as a file of the project whose root holds it. Only a
/// path that came whole links; the line the host sends comes through every
/// way a card is read.
final class ChatFileLinkTests: XCTestCase {
    private func tool(_ name: String, state: String = "completed", input: String, output: String = "", path: String? = "/p/notes.txt",
                      added: Int? = nil, line: Int? = nil, lastLine: Int? = nil, inputTruncated: Bool? = nil) -> ToolView {
        ToolView(id: "c", name: name, state: state, input: input, output: output, durationMs: 5, truncated: false,
                 path: path, added: added, removed: nil, line: line, lastLine: lastLine, inputTruncated: inputTruncated)
    }

    func testFileToolsLinkTheirFileAtTheLinesReadOrChanged() {
        func link(_ tool: ToolView) -> TranscriptActivity.FileLink? { TranscriptActivity.fileLink(tool) }
        // A read of named lines: the lines the host says it returned, as the
        // viewer counts them (a file of lone "\r"s: one of pi's lines, three
        // of the viewer's); from an older host, the lines of its result, not
        // the host's note.
        XCTAssertEqual(link(tool("read", input: #"{"path":"notes.txt","offset":1,"limit":1}"#, output: "a\rb\rc", line: 1, lastLine: 3))?.lines, 1...3)
        XCTAssertEqual(link(tool("read", input: #"{"path":"notes.txt","offset":10,"limit":5}"#, output: "a\nb\nc\nd\ne")),
                       .init(path: "/p/notes.txt", lines: 10...14))
        XCTAssertEqual(link(tool("read", input: #"{"path":"notes.txt","limit":3}"#, output: "a\nb\nc\n[Truncated. 90 total lines; read another range.]"))?.lines, 1...3)
        XCTAssertEqual(link(tool("read", input: #"{"path":"notes.txt","offset":7}"#, output: "last line cut shor"))?.lines, 7...7, "a line returned in part counts")
        XCTAssertEqual(link(tool("read", input: #"{"path":"notes.txt"}"#, output: "a\nb")), .init(path: "/p/notes.txt", lines: nil), "a whole file opens at its top")
        XCTAssertNil(link(tool("read", input: #"{"path":"notes.txt"}"#, output: "a\nb", line: 1, lastLine: 2))?.lines, "whatever the host says it returned")
        XCTAssertNil(link(tool("read", input: #"{"path":"a.png","offset":2}"#, output: "Read image file [image/png]"))?.lines)
        XCTAssertNil(link(tool("read", input: #"{"path":"notes.txt","offset":2}"#, output: ""))?.lines)
        XCTAssertEqual(link(tool("read", state: "failed", input: #"{"path":"notes.txt","offset":2}"#, output: "ENOENT")), .init(path: "/p/notes.txt", lines: nil))
        // A change: the lines the host says it changed, whatever pi counted.
        XCTAssertEqual(link(tool("edit", input: #"{"path":"notes.txt"}"#, added: 1, line: 7, lastLine: 9))?.lines, 7...9)
        XCTAssertEqual(link(tool("edit", input: #"{"path":"notes.txt"}"#, added: 3, line: 7))?.lines, 7...7, "a first line alone")
        XCTAssertEqual(link(tool("write", input: #"{"path":"notes.txt"}"#, added: 2, line: 4, lastLine: 5))?.lines, 4...5)
        XCTAssertNil(link(tool("write", input: #"{"path":"notes.txt"}"#, added: 9))?.lines, "a new file, or an older host: its top")
        // The path: the host's once it ran, else the call's own, only whole.
        XCTAssertEqual(link(tool("read", state: "cancelled", input: #"{"path":"~/n.txt"}"#, path: nil))?.path, "~/n.txt")
        XCTAssertNil(link(tool("read", state: "running", input: #"{"path":"notes.t"#, path: nil)), "still streaming")
        XCTAssertNil(link(tool("write", state: "failed", input: #"{"path":"notes.txt","content":"#, path: nil, inputTruncated: true)), "cut short")
        XCTAssertNil(link(tool("bash", input: #"{"command":"cat notes.txt"}"#, path: nil)))
        XCTAssertNil(link(tool("ls", input: #"{"path":"."}"#, path: "/p")))
    }

    /// The line comes through the wire's fast reading and Codable alike, and
    /// from a journal's recorded stats onto the card.
    func testTheLineComesThroughEveryReadingOfACard() throws {
        let row: [String: Any] = ["id": "m", "role": "assistant", "text": "Edited",
                                  "tools": [["id": "c", "name": "edit", "state": "completed", "input": "{}", "output": "ok", "truncated": false,
                                             "path": "/p/a.swift", "added": 2, "removed": 1, "line": 14, "lastLine": 15]]]
        func wire(_ object: Any) throws -> WireValue { try JSONDecoder().decode(WireValue.self, from: JSONSerialization.data(withJSONObject: object)) }
        let value = try wire([row])
        let fast = try TranscriptMessage.projected(value), coded = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))
        XCTAssertEqual(fast.first?.tools?.first?.line, 14)
        XCTAssertEqual(fast.first?.tools?.first?.lastLine, 15)
        XCTAssertEqual(fast, coded)
        let old = try TranscriptMessage.projected(wire([["id": "m", "role": "assistant", "text": "",
            "tools": [["id": "c", "name": "edit", "state": "completed", "input": "{}", "output": "", "truncated": false]]]]))
        XCTAssertNil(old.first?.tools?.first?.line, "an older card has none")
        XCTAssertNil(old.first?.tools?.first?.lastLine)
        let record: [String: WireValue] = ["role": .string("toolResult"), "toolCallId": .string("c"), "isError": .bool(false),
                                           "content": .array([.object(["type": .string("text"), "text": .string("Edited")])]),
                                           "nativeToolStats": .object(["path": .string("/p/a.swift"), "added": .number(2), "removed": .number(1),
                                                                       "line": .number(14), "lastLine": .number(15), "outcome": .string("completed")])]
        let (_, result) = try XCTUnwrap(ToolResultRecord.of(record))
        XCTAssertEqual(result.line, 14)
        XCTAssertEqual(result.lastLine, 15)
        let recorded = TranscriptMessage(id: "a", role: "assistant", text: "", tools: [ToolView(id: "c", name: "edit", state: "recorded", input: "{}", output: "", truncated: false)])
        var resultRow = TranscriptMessage(id: "r", role: "tool", text: "Edited"); resultRow.toolCallID = "c"
        let resolved = TranscriptMessage.resolvingToolResults([recorded, resultRow], results: ["r": result])
        XCTAssertEqual(resolved.first?.tools?.first?.line, 14, "the journal's card says it too")
        XCTAssertEqual(resolved.first?.tools?.first?.lastLine, 15)
    }

    // MARK: In the app

    @MainActor private func model(untrusted other: URL? = nil) async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-file-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
            + (other.map { [WorkspaceRecord(id: "u", path: $0.path, trusted: false)] } ?? [])
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key")]
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "main", workspaceID: "w", title: "Main", path: nil, profileID: profile.id)
        let main = SessionDisplay(id: chat.id)
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main]
        return (model, root)
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// A read's path in the chat opens its file in a tab, at the lines read;
    /// the row it is on stays as it was.
    @MainActor func testAReadsPathInTheChatOpensItsFileAtTheLinesRead() async throws {
        let (model, root) = try await model()
        let notes = root.appendingPathComponent("notes.txt")
        try Data((1...20).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: notes)
        let read = ToolView(id: "c1", name: "read", state: "completed", input: #"{"path":"notes.txt","offset":5,"limit":3}"#,
                            output: "line 5\nline 6\nline 7", durationMs: 4, truncated: false, path: FileTab.key(for: notes))
        model.selected?.messages = [TranscriptMessage(id: "u1", role: "user", text: "Read the notes"),
                                    TranscriptMessage(id: "a1", role: "assistant", text: "", tools: [read]),
                                    TranscriptMessage(id: "a2", role: "assistant", text: "Lines 5 to 7 say so.")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        var link: PiPopoverTriggerButton?
        try await eventually("the path a link") {
            hosted.layoutSubtreeIfNeeded()
            link = self.descendants(PiPopoverTriggerButton.self, in: hosted).first { $0.accessibilityIdentifier() == "transcript-open-file" }
            return link != nil
        }
        XCTAssertTrue(model.tabs.pane.tabs.isEmpty)
        link?.performClick(nil)
        let tab = try XCTUnwrap(model.tabs.pane.tabs.first as? FileTab)
        XCTAssertEqual(tab.key, FileTab.key(for: notes))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("shown at the lines read") { (tab.focusView as? FileTextView)?.emphasized == 4...6 }
    }

    /// A failed call's row says what went wrong where its path was: those
    /// words are not a link (its card's path is).
    @MainActor func testAFailuresWordsAreNotALink() async throws {
        let (model, root) = try await model()
        let failed = ToolView(id: "c1", name: "read", state: "failed", input: #"{"path":"gone.txt"}"#,
                              output: "ENOENT: no such file", durationMs: 4, truncated: false, path: nil)
        let ok = ToolView(id: "c2", name: "read", state: "completed", input: #"{"path":"notes.txt"}"#,
                          output: "a", durationMs: 4, truncated: false, path: root.appendingPathComponent("notes.txt").path)
        model.selected?.messages = [TranscriptMessage(id: "u1", role: "user", text: "Read"),
                                    TranscriptMessage(id: "a1", role: "assistant", text: "", tools: [failed, ok]),
                                    TranscriptMessage(id: "a2", role: "assistant", text: "Done.")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        var links: [PiPopoverTriggerButton] = []
        try await eventually("the good path a link") {
            hosted.layoutSubtreeIfNeeded()
            links = self.descendants(PiPopoverTriggerButton.self, in: hosted).filter { $0.accessibilityIdentifier() == "transcript-open-file" }
            return !links.isEmpty
        }
        XCTAssertEqual(links.count, 1, "the failure's words are not a link")
        XCTAssertEqual(links.first?.accessibilityLabel(), "Open notes.txt")
    }

    /// A link to the whole file shows its start, whatever an earlier link to
    /// it left shown: nothing set apart, the insertion point at its start,
    /// the view at its top left.
    @MainActor func testALinkToTheWholeFileShowsItsStart() async throws {
        let (model, root) = try await model()
        let notes = root.appendingPathComponent("notes.txt")
        let lines = (1...300).map { $0 == 150 ? String(repeating: "wide ", count: 400) : "line \($0)" }
        try Data(lines.joined(separator: "\n").utf8).write(to: notes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        let tab = try XCTUnwrap(model.openFile(fromChat: "main", path: "notes.txt", lines: 150...152))
        var view: FileTextView?
        try await eventually("the lines set apart") {
            hosted.layoutSubtreeIfNeeded()
            view = tab.focusView as? FileTextView
            return view?.emphasized == 149...151
        }
        let clip = try XCTUnwrap(view?.enclosingScrollView?.contentView)
        XCTAssertGreaterThan(clip.bounds.minY, 0, "scrolled to them")
        clip.scroll(to: NSPoint(x: 300, y: clip.bounds.minY)); view?.enclosingScrollView?.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(clip.bounds.minX, 0)
        XCTAssertTrue(model.openFile(fromChat: "main", path: "notes.txt", lines: nil) === tab, "the same tab")
        XCTAssertNil(view?.emphasized, "nothing set apart")
        XCTAssertEqual(view?.anchor, .start); XCTAssertEqual(view?.focus, .start)
        XCTAssertEqual(clip.bounds.origin, .zero, "at its top left")
        // A link to lines still shows them, as before.
        model.openFile(fromChat: "main", path: "notes.txt", lines: 10...12)
        try await eventually("set apart again") { view?.emphasized == 9...11 }
    }

    /// A file call whose arguments did not read as a request (a write with no
    /// content) fails in words that are not a link; its card still opens the
    /// file.
    @MainActor func testAFailedCallsCardStillOpensItsFile() throws {
        let write = ToolView(id: "c1", name: "write", state: "failed", input: #"{"path":"notes.txt"}"#,
                             output: "Missing content", durationMs: 4, truncated: false, path: nil)
        var opened: [String] = []
        let hosted = NSHostingView(rootView: ActionRowView(tool: write, open: true, openFile: { path, _ in opened.append(path) })
            .environment(\.transcriptOpensFiles, true).frame(width: 700))
        hosted.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        hosted.layoutSubtreeIfNeeded()
        let links = descendants(PiPopoverTriggerButton.self, in: hosted).filter { $0.accessibilityIdentifier() == "transcript-open-file" }
        XCTAssertEqual(links.count, 1, "the card's path, not the failure's words")
        XCTAssertEqual(links.first?.accessibilityLabel(), "Open notes.txt")
        links.first?.performClick(nil)
        XCTAssertEqual(opened, ["notes.txt"])
    }

    /// A path from a chat opens as a file of the project whose root holds it:    /// A path from a chat opens as a file of the project whose root holds it:
    /// the chat's own, from its root; another, untrusted, not read; from home.
    @MainActor func testAPathFromAChatOpensAsAFileOfTheProjectHoldingIt() async throws {
        let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-file-link-other-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        let (model, root) = try await model(untrusted: other)
        try Data("a\nb\nc".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("secret".utf8).write(to: other.appendingPathComponent("secret.txt"))
        let own = try XCTUnwrap(model.openFile(fromChat: "main", path: "notes.txt", lines: 2...3))
        XCTAssertEqual(own.key, FileTab.key(for: root.appendingPathComponent("notes.txt")))
        XCTAssertEqual(own.projectID, "w")
        XCTAssertTrue(own.readable)
        let theirs = try XCTUnwrap(model.openFile(fromChat: "main", path: other.appendingPathComponent("secret.txt").path, lines: nil))
        XCTAssertEqual(theirs.projectID, "u", "the project holding it, not the chat's")
        XCTAssertFalse(theirs.readable)
        XCTAssertNotNil(theirs.missingReason)
        let home = try XCTUnwrap(model.openFile(fromChat: "main", path: "~/chat-file-link-nowhere.txt", lines: nil))
        XCTAssertEqual(home.key, FileTab.key(for: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("chat-file-link-nowhere.txt")))
        XCTAssertNil(model.openFile(fromChat: "no-such-chat", path: "notes.txt", lines: nil), "a relative path needs its chat's project")
    }
}
