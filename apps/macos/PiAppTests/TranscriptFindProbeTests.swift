import XCTest
import AppKit
@testable import PiApp

/// Opt-in (`PI_LONG_PROBE=1`): ⌘F for a query whose only match is far up a
/// long chat, the Swift-vs-Rust find benchmark's case — from the query
/// typed to the match marked on screen, with the time the search, the
/// reveal's read and the landing each took. Prints, does not assert; the
/// record is docs/perf/smooth-scrolling-0.1.123.md.
final class TranscriptFindProbeTests: XCTestCase, SerialTestLane {
    override func setUpWithError() throws {
        try XCTSkipUnless(testEnvironment("PI_LONG_PROBE") == "1", "Set PI_LONG_PROBE=1 to measure find in a long chat")
    }
    @MainActor private func focusShown(_ chat: LongChatScroll, query: String) -> Bool {
        guard let document = chat.document, let text = document.focusText, !document.focusPending,
              let manager = text.layoutManager, let container = text.textContainer, let clip = chat.scroll?.contentView,
              document.focusRange.location != NSNotFound, NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0) else { return false }
        let found = ((text.textStorage?.string ?? "") as NSString).substring(with: document.focusRange)
        let rect = text.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: container), to: clip)
        return found.lowercased() == query.lowercased() && clip.bounds.contains(CGPoint(x: clip.bounds.midX, y: rect.midY))
    }
    @MainActor func testProbeFindDeepInHistory() async throws {
        let turns = Int(testEnvironment("PI_LONG_TURNS") ?? "") ?? 400
        let runs = Int(testEnvironment("PI_LONG_ROUNDS") ?? "") ?? 5
        let query = "zephyr"
        var totals: [Double] = []
        for run in 0..<runs {
            let chat = try await LongChatScroll(turns: turns, markTurn: turns / 2)
            registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
            addTeardownBlock { @MainActor in chat.close() }
            try await chat.ready()
            let pane = try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
            chat.model.findInFocusedConversation(.show, in: chat.window)
            try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
            let clock = ProcessInfo.processInfo
            var searched: [Double] = [], revealed: [Double] = []
            let search = try XCTUnwrap(pane.find.search), reveal = try XCTUnwrap(pane.find.reveal)
            pane.find.search = { id, text, start in
                let began = clock.systemUptime; defer { searched.append((clock.systemUptime - began) * 1000) }
                return try await search(id, text, start)
            }
            pane.find.reveal = { id, message in
                let began = clock.systemUptime; defer { revealed.append((clock.systemUptime - began) * 1000) }
                return await reveal(id, message)
            }
            let typed = clock.systemUptime
            pane.findBar?.field.text = query; pane.find.setQuery(query)
            var found: Double?
            try await eventually("The match was never shown", timeout: .seconds(30)) {
                chat.draw()
                if found == nil, !pane.find.matches.isEmpty { found = (clock.systemUptime - typed) * 1000 }
                return focusShown(chat, query: query)
            }
            let shown = (clock.systemUptime - typed) * 1000
            totals.append(shown)
            print(String(format: "FINDPROBE run %d: typed → matches %.0f ms (debounce 150), search calls %@ ms, reveal %@ ms, → marked on screen %.0f ms; %d matches",
                         run, found ?? -1, searched.map { String(format: "%.0f", $0) }.joined(separator: "+"),
                         revealed.map { String(format: "%.0f", $0) }.joined(separator: "+"), shown, pane.find.matches.count))
            chat.close()
        }
        let sorted = totals.sorted()
        print(String(format: "FINDPROBE %d turns, %d runs: typed → marked p50 %.0f ms, min %.0f, max %.0f", turns, runs, sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0))
    }
}
