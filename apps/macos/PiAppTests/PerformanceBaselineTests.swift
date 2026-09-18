import XCTest
import SwiftUI
@testable import PiApp

/// Timings of the paths that run most: opening a long chat, a streaming delta,
/// the terminal parser, the highlighter and the sidebar. Printed, not asserted,
/// so a slower machine never fails the suite; the release record quotes them
/// from a Release build, where they are what the shipped app does.
final class PerformanceBaselineTests: XCTestCase {
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
        _ = clock("copy targets 14 KB") { TranscriptCopy.targets(in: long) }
        let messages = (0..<500).map { index -> TranscriptMessage in
            var message = TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", text: paragraph, turn: "m\(index - index % 2)")
            if index % 2 == 1 { message.tools = [ToolView(id: "t\(index)", name: "read", state: "completed", input: "{\"path\":\"a.swift\"}", output: "ok", durationMs: 3, truncated: false, path: "a.swift", added: nil, removed: nil)]; message.at = Double(index) * 1000 }
            return message
        }
        let items = clock("blocks(of:) 500 rows") { TranscriptActivity.blocks(of: messages) }
        XCTAssertEqual(items.count, 500)
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
        let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"
        let session = SessionDisplay(id: "perf")
        session.messages = (0..<300).map { index in
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
        print(String(format: "PERF open 300 rows (mount, layout, first display): %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        var classes: [String: Int] = [:]
        func walk(_ view: NSView) { classes[String(describing: type(of: view)), default: 0] += 1; for child in view.subviews { walk(child) } }
        walk(hosted)
        print("PERF NSViews in the hosted transcript: \(classes.values.reduce(0, +)) \(classes.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        try await Task.sleep(for: .milliseconds(300))
        let bytes = Array(Self.reply.utf8)
        var deltas = 0
        // PI_PERF_REPEAT streams the reply again that many times, long enough to sample the process.
        let repeats = Int(ProcessInfo.processInfo.environment["PI_PERF_REPEAT"] ?? "") ?? 1
        let deltaStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<repeats {
            var offset = 300
            while offset <= bytes.count {
                let text = String(decoding: bytes[0..<offset], as: UTF8.self)
                // One change per delta, as a helper snapshot arrives: the streaming row is replaced in place.
                let row = TranscriptMessage(id: "stream:x", role: "assistant", text: text, state: "streaming", turn: "m298")
                if deltas > 0 { session.messages[session.messages.count - 1] = row } else { session.messages.append(row) }
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                deltas += 1; offset += 300
            }
        }
        print(String(format: "PERF streaming delta (layout + display, 11 KB reply in a 300-row chat, %d deltas): %.1f ms each", deltas, (ProcessInfo.processInfo.systemUptime - deltaStart) * 1000 / Double(deltas)))
        window.contentView = nil; window.close()
    }
}
