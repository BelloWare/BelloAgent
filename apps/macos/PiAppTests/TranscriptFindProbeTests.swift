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

    /// The process's CPU time so far, in milliseconds: the main thread and
    /// the history reader's searches together.
    private func cpuMilliseconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }
    /// ⌘F open on a word a long chat does not have yet while a reply streams
    /// into it at the live end, one sentence per 30 ms, the word arriving half
    /// way: the searches the stream causes while it runs and after it, what
    /// each delta costs the main thread (presented at once, no 30 Hz pacing),
    /// the CPU the stream and its aftermath take, and how long after the
    /// stream ends the word is counted. `PI_LONG_TURNS`, `PI_LONG_DELTAS`.
    @MainActor func testProbeFindWhileALongReplyStreams() async throws {
        let turns = Int(testEnvironment("PI_LONG_TURNS") ?? "") ?? 400
        let deltas = Int(testEnvironment("PI_LONG_DELTAS") ?? "") ?? 300
        let chat = try await LongChatScroll(turns: turns)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        let pane = try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
        chat.page?.presentationInterval = 0
        chat.model.findInFocusedConversation(.show, in: chat.window)
        try await eventually("⌘F never showed the find bar") { chat.draw(); return pane.findBar != nil }
        let clock = ProcessInfo.processInfo, search = try XCTUnwrap(pane.find.search)
        var calls = 0, searched: [Double] = []
        pane.find.search = { id, text, start in
            calls += 1
            let began = clock.systemUptime; defer { searched.append((clock.systemUptime - began) * 1000) }
            return try await search(id, text, start)
        }
        let query = "zebra"
        pane.findBar?.field.text = query; pane.find.setQuery(query)
        try await eventually("The first search never finished", timeout: .seconds(120)) { chat.draw(); return !pane.find.searching }
        let first = searched.reduce(0, +), firstCalls = calls
        calls = 0; searched = []
        let view = chat.view
        view.messages.append(TranscriptMessage(id: "probe-question", role: "user", text: "One more, please."))
        var live = TranscriptMessage(id: "probe-reply", role: "assistant", text: "", state: "streaming")
        view.messages.append(live); chat.draw()
        try await Task.sleep(for: .milliseconds(100))
        var costs: [Double] = []
        let streamCPU = cpuMilliseconds(), streamStart = clock.systemUptime
        for index in 0..<deltas {
            live.text += "Sentence \(index) of a reply arriving into a long chat\(index == deltas / 2 ? ", past a zebra" : ""). "
            let began = clock.systemUptime
            view.messages[view.messages.count - 1] = live
            chat.draw()
            costs.append((clock.systemUptime - began) * 1000)
            try await Task.sleep(for: .milliseconds(30))
        }
        let during = calls, duringCPU = cpuMilliseconds() - streamCPU, streamed = (clock.systemUptime - streamStart) * 1000
        live.state = "complete"; view.messages[view.messages.count - 1] = live; chat.draw()
        let ended = clock.systemUptime, endCPU = cpuMilliseconds()
        var counted: Double?
        while clock.systemUptime < ended + 30 {
            chat.draw()
            if counted == nil, !pane.find.searching, pane.find.matches.count == 1 { counted = (clock.systemUptime - ended) * 1000 }
            // Past the count, and past any search it could still start.
            if let counted, clock.systemUptime - ended > counted / 1000 + 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterCPU = cpuMilliseconds() - endCPU, window = (clock.systemUptime - ended) * 1000
        let sorted = costs.sorted()
        print(String(format: "FINDSTREAM %d turns, %d deltas over %.0f ms: first search %.0f ms in %d calls; searches during the stream %d, after it %d (%@ ms); "
                     + "delta main thread mean %.2f, p95 %.2f, max %.2f ms; CPU during the stream %.0f ms, after it %.0f ms over %.0f ms; stream end → counted %@",
                     turns, deltas, streamed, first, firstCalls, during, calls - during, searched.map { String(format: "%.0f", $0) }.joined(separator: "+"),
                     costs.reduce(0, +) / Double(max(1, costs.count)), sorted[sorted.count * 95 / 100], sorted.last ?? 0,
                     duringCPU, afterCPU, window, counted.map { String(format: "%.0f ms", $0) } ?? "never (30 s)"))
    }
}
