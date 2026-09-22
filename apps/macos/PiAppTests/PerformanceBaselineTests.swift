import XCTest
import SwiftUI
@testable import PiApp

/// Timings of the paths that run most: opening a long chat, a streaming delta,
/// the terminal parser, the highlighter and the sidebar. Printed, not asserted,
/// so a slower machine never fails the suite; the release record quotes them
/// from a Release build, where they are what the shipped app does.
final class PerformanceBaselineTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// Mounting an NSHostingView does not run its async .task. Wait for actual
    /// row geometry before calling this a loaded transcript, not an empty shell.
    @MainActor private func waitForRows(_ hosted: NSView, window: NSWindow, lastID: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if let page = descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page,
               page.rowFrame(of: lastID) != nil || page.rowFrame(of: "block:" + lastID) != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Transcript did not lay out its last row")
    }
    private func clock<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let value = try work()
        print(String(format: "PERF %@: %.1f ms", label, (ProcessInfo.processInfo.systemUptime - start) * 1000))
        return value
    }
    /// A reply shaped like the model's: headings, prose with inline marks, lists and code.
    static let reply = (0..<40).map {
        "## Step \($0)\n\nHere is what changed in `file\($0).swift`: the handler now **retries** twice and logs the reason. See [docs](https://example.com/\($0)).\n\n1. First point with detail.\n2. Second point with more detail.\n\n```swift\nlet value = compute(index: \($0))\nif value > 0 { print(\"ok\") }\n```\n"
    }.joined(separator: "\n")   // ~11 KB

    func testParsingAndHighlightingBaselines() {
        let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"
        let long = String(repeating: paragraph, count: 60)   // ~14 KB
        let blocks = clock("markdown 14 KB, cold") { TranscriptMarkdown.parse(long) }
        XCTAssertGreaterThan(blocks.count, 100)
        _ = TranscriptMarkdown.blocks(long)
        _ = clock("markdown 14 KB, cached") { TranscriptMarkdown.blocks(long) }
        let bytes = Array(Self.reply.utf8)
        var whole = 0.0, cut = 0.0, deltas = 0
        var offset = 300
        while offset <= bytes.count {
            let partial = String(decoding: bytes[0..<offset], as: UTF8.self)
            var start = ProcessInfo.processInfo.systemUptime; _ = TranscriptMarkdown.parse(partial); whole += ProcessInfo.processInfo.systemUptime - start
            start = ProcessInfo.processInfo.systemUptime; _ = TranscriptMarkdown.streamingBlocks(partial); cut += ProcessInfo.processInfo.systemUptime - start
            deltas += 1; offset += 300
        }
        print(String(format: "PERF streaming parse per delta (11 KB reply, %d deltas): whole %.2f ms, settled parts + tail %.2f ms", deltas, whole * 1000 / Double(deltas), cut * 1000 / Double(deltas)))
        let code = String(repeating: "let value = compute(index: 42) // trailing comment\nif value > 0 { print(\"ok\") } else { throw Failure.bad }\n", count: 150)
        _ = clock("highlighter 16 KB swift") { SyntaxHighlighter.tokens(code, language: .swift) }
        _ = clock("attributed highlighter 16 KB swift, cold") { SyntaxHighlighter.attributed(code + "\n// cold", language: "swift") }
        _ = clock("copy targets 14 KB") { TranscriptCopy.targets(in: long) }
        let messages = (0..<500).map { index -> TranscriptMessage in
            var message = TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", text: paragraph, turn: "m\(index - index % 2)")
            if index % 2 == 1 { message.tools = [ToolView(id: "t\(index)", name: "read", state: "completed", input: "{\"path\":\"a.swift\"}", output: "ok", durationMs: 3, truncated: false, path: "a.swift", added: nil, removed: nil)]; message.at = Double(index) * 1000 }
            return message
        }
        let items = clock("blocks(of:) 500 rows") { TranscriptActivity.blocks(of: messages) }
        XCTAssertEqual(items.count, 750, "Each legacy work group remains local to its response")
        _ = clock("display page 500 rows") { TranscriptPage.displayPage(messages) }
    }

    func testTerminalParserBaseline() {
        let terminal = TerminalEmulator(columns: 120, rows: 40, scrollbackLimit: 10_000)
        var line = ""
        for column in 0..<110 { line += column % 7 == 0 ? "\u{1b}[3\(column % 8)m" : "x" }
        line += "\u{1b}[0m\r\n"
        let stream = Data(String(repeating: line, count: 20_000).utf8)   // ~3.4 MB with colour changes
        clock("terminal feed \(stream.count / 1024) KB") { terminal.feed(stream) }
        XCTAssertLessThanOrEqual(terminal.scrollback.count, 10_000); XCTAssertGreaterThanOrEqual(terminal.scrollback.count, 9_600)
        XCTAssertEqual(terminal.scrollback.count + terminal.trimmedLines, 20_000 - 39, "every line that left the screen is kept or counted")
    }

    @MainActor func testOpeningALongChatAndStreamingDeltaBaselines() async throws {
        try await measureOpeningAndStreaming(rowCount: 300)
    }

    @MainActor func testOpeningANormalHistoryPageAndStreamingDeltaBaselines() async throws {
        // The newest60 plus the preceding user needed to complete its turn.
        try await measureOpeningAndStreaming(rowCount: 61)
    }

    @MainActor private func measureOpeningAndStreaming(rowCount: Int) async throws {
        let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"
        let session = SessionDisplay(id: "perf-\(rowCount)")
        let lastUserID = "m\(rowCount - (rowCount.isMultiple(of: 2) ? 2 : 1))"
        session.messages = (0..<rowCount).map { index in
            var message = TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", text: paragraph + "Row \(index).", turn: "m\(index - index % 2)")
            message.at = Double(index) * 1000
            return message
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let start = ProcessInfo.processInfo.systemUptime
        let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, actions: TranscriptActions()))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        hosted.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print(String(format: "PERF mount transcript shell (\(rowCount) rows): %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        try await waitForRows(hosted, window: window, lastID: lastUserID)
        print(String(format: "PERF open \(rowCount) rows (mount through actual row layout): %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        var classes: [String: Int] = [:]
        func walk(_ view: NSView) { classes[String(describing: type(of: view)), default: 0] += 1; for child in view.subviews { walk(child) } }
        walk(hosted)
        print("PERF NSViews in the hosted transcript (\(rowCount) rows): \(classes.values.reduce(0, +)) \(classes.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        try await Task.sleep(for: .milliseconds(300))
        let bytes = Array(Self.reply.utf8)
        var deltas = 0
        // PI_PERF_REPEAT streams the reply again that many times, long enough to sample the process.
        let repeats = Int(testEnvironment("PI_PERF_REPEAT") ?? "") ?? 1
        let deltaStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<repeats {
            var offset = 300
            while offset <= bytes.count {
                let text = String(decoding: bytes[0..<offset], as: UTF8.self)
                // One change per delta, as a helper snapshot arrives: the streaming row is replaced in place.
                let row = TranscriptMessage(id: "stream:x", role: "assistant", text: text, state: "streaming", turn: lastUserID)
                if deltas > 0 { session.messages[session.messages.count - 1] = row } else { session.messages.append(row) }
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                // Let SwiftUI process deferred observation/layout/scroll work
                // between frames, as real network deltas do.
                await Task.yield()
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                deltas += 1; offset += 300
            }
        }
        print(String(format: "PERF streaming delta (layout + display, 11 KB reply in a \(rowCount)-row chat, %d deltas): %.1f ms each", deltas, (ProcessInfo.processInfo.systemUptime - deltaStart) * 1000 / Double(deltas)))
        window.contentView = nil; window.close()
    }

    /// Editing the first message of a long chat through the real conversation
    /// pane: the composer takes the text, then every keystroke is a layout and
    /// display pass. The transcript's rows must not be rebuilt for either.
    @MainActor func testEditingAnEarlyMessageInALongChatBaseline() async throws {
        let scratch = testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("perf-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let workspace = WorkspaceRecord(id: "perf-project", path: root.path, trusted: true)
        let chat = ChatRecord(id: "perf-edit", workspaceID: workspace.id, title: "Perf", path: nil, profileID: "profile")
        let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"
        let session = SessionDisplay(id: chat.id)
        session.messages = (0..<300).map { index in
            var message = TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", text: paragraph + "Row \(index).", turn: "m\(index - index % 2)")
            message.at = Double(index) * 1000
            return message
        }
        model.workspaces = [workspace]; model.chats = [chat]; model.displays[chat.id] = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 900))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await waitForRows(hosted, window: window, lastID: "m298")
        try await Task.sleep(for: .milliseconds(300))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let first = session.messages[0].id
        let original = session.messages[0].text
        model.editTargetRead = { _, id in
            ["messageId": .string(id), "text": .string(original), "legacyInputs": .bool(false)]
        }
        var start = ProcessInfo.processInfo.systemUptime
        model.editMessage(first, sessionID: chat.id)
        for _ in 0..<200 where session.editPreparing { try await Task.sleep(for: .milliseconds(10)) }
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        print(String(format: "PERF begin editing the first message of a 300-row chat (layout + display): %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        XCTAssertEqual(session.editingMessageID, first)
        try await Task.sleep(for: .milliseconds(100))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let keystrokes = 40
        start = ProcessInfo.processInfo.systemUptime
        for index in 0..<keystrokes {
            session.draft += index % 8 == 7 ? "\n" : "x"
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        print(String(format: "PERF typing while editing (%d keystrokes, layout + display each): %.2f ms per keystroke", keystrokes, (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(keystrokes)))
        start = ProcessInfo.processInfo.systemUptime
        model.cancelEdit(sessionID: chat.id)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        print(String(format: "PERF cancel editing (layout + display): %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        XCTAssertNil(session.editingMessageID)
        window.contentView = nil; window.close()
        model.shutdown()
        try await model.flushDrafts()
        await model.flushReadStates(); await model.flushProjectSidebarState()
        try await model.traces.close(); await model.store?.close()
    }
}
