import XCTest
import AppKit
@testable import PiApp

/// Typing in the sidebar's search stays instant: titles filter in the
/// keystroke, and the content index — building or answering — works off
/// the main thread. Serial: it measures the main thread.
final class SidebarSearchTypingTests: XCTestCase, SerialTestLane {
    @MainActor func testTypingDoesNotBlockTheMainThread() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("search-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state")); defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "one", path: root.appendingPathComponent("one").path, trusted: true)]
        let words = ["retry", "backoff", "jitter", "ledger", "invoice", "webhook", "cursor", "schema"]
        var chats: [ChatRecord] = []
        for index in 0..<16 {
            let journal = try SearchJournal(root.appendingPathComponent("chat-\(index).jsonl"), id: "chat-\(index)")
            try journal.turns(1_000, prefix: "c\(index)") { turn in
                let word = words[(turn + index) % words.count]
                return ("Turn \(turn): how does the \(word) path behave under load in chat \(index)?",
                        "In chat \(index) the \(word) path keeps a bounded queue; turn \(turn) measured it at \(turn * 7 % 113) ms.")
            }
            if index == 9 { try journal.message("needle", role: "user", "Please check the quartzfeather retry budget") }
            chats.append(ChatRecord(id: "chat-\(index)", workspaceID: "one", title: "Ticket \(index)", path: journal.url.path, profileID: "fixture",
                                    sidebarOrder: Int64(1_000 - index)))
        }
        model.chats = chats
        let view = WorkspaceSidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700); view.layoutSubtreeIfNeeded()
        let search = model.sidebarSearch

        let watchdog = MainThreadWatchdog(limit: 5, abortOnStall: false); watchdog.start(); defer { watchdog.stop() }
        var keystrokes: [Double] = []
        func type(_ text: String) async throws {
            for end in 1...text.count {
                let start = ProcessInfo.processInfo.systemUptime
                view.setFilter(String(text.prefix(end))); view.settle()
                keystrokes.append(ProcessInfo.processInfo.systemUptime - start)
                try await Task.sleep(for: .milliseconds(35))
            }
        }
        // While the index is first built: 16 chats of 2,000 rows each.
        let building = ProcessInfo.processInfo.systemUptime
        try await type("Ticket 1")
        XCTAssertEqual(model.sidebarChatOrder.count, 7, "Titles filter in the keystroke: Ticket 1 and Ticket 10–15")
        try await type("quartzfeather")
        while search.passes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        let built = ProcessInfo.processInfo.systemUptime - building
        await search.settleQuery(); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["chat-9"], "The content match arrives once indexed")
        let duringBuild = watchdog.worstStall

        // Against the built index, with every query slowed to 300 ms on its own thread.
        search.reader.delay = 0.3
        view.setFilter(""); view.settle()
        let answered = search.answeredQueries
        try await type("quartzfeather retry")
        await search.settleQuery(); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["chat-9"])
        XCTAssertLessThanOrEqual(search.answeredQueries - answered, 3, "Stale queries are dropped, not answered one by one")
        let worst = watchdog.worstStall, slowest = keystrokes.max() ?? 0
        FileHandle.standardError.write(Data(String(format: "SEARCH-TYPING index build %.2f s; keystroke max %.1f ms median %.1f ms; main stall max %.1f ms (during build %.1f ms)\n",
                                                   built, slowest * 1_000, keystrokes.sorted()[keystrokes.count / 2] * 1_000, worst * 1_000, duringBuild * 1_000).utf8))
        // Debug's bound is loose, but well under the 300 ms each query is held
        // for on its own thread; a Release run holds the owner's 50 ms.
        XCTAssertLessThan(worst, min(0.25, releaseBudget(0.05)), "The main thread never waits on the index")
        XCTAssertLessThan(slowest, releaseBudget(0.016), "A keystroke filters within a frame")
    }

    /// Hundreds of chats matching at once: refining the query refines their
    /// snippets and redraws the list on the main actor, which must stay quick.
    @MainActor func testTypingStaysQuickWithHundredsOfContentMatches() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("search-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state")); defer { model.shutdown() }
        model.workspaces = [WorkspaceRecord(id: "one", path: root.appendingPathComponent("one").path, trusted: true)]
        var chats: [ChatRecord] = []
        for index in 0..<600 {
            let journal = try SearchJournal(root.appendingPathComponent("c\(index).jsonl"), id: "c\(index)")
            try journal.turns(3, prefix: "c\(index)") { turn in
                ("Turn \(turn) of chat \(index)", "The lantern roster for shift \(index) lists \(turn * 3 + index % 7) keepers before the lantern rotation.")
            }
            chats.append(ChatRecord(id: "c\(index)", workspaceID: "one", title: "Ticket \(index)", path: journal.url.path, profileID: "fixture",
                                    sidebarOrder: Int64(10_000 - index)))
        }
        model.chats = chats
        let view = WorkspaceSidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700); view.layoutSubtreeIfNeeded()
        let search = model.sidebarSearch
        await search.reconcileNow()
        view.setFilter("lantern"); view.settle()
        await search.settleQuery(); view.settle()
        XCTAssertEqual(model.sidebarContentMatches.count, 600)
        let watchdog = MainThreadWatchdog(limit: 5, abortOnStall: false); watchdog.start(); defer { watchdog.stop() }
        var keystrokes: [Double] = []
        for text in ["lantern ", "lantern r", "lantern ro", "lantern ros", "lantern rost", "lantern roste", "lantern roster"] {
            let start = ProcessInfo.processInfo.systemUptime
            view.setFilter(text); view.settle()
            keystrokes.append(ProcessInfo.processInfo.systemUptime - start)
            try await Task.sleep(for: .milliseconds(35))
        }
        await search.settleQuery(); view.settle()
        XCTAssertEqual(model.sidebarContentMatches.count, 600, "Every chat says 'lantern roster'")
        let worst = watchdog.worstStall, slowest = keystrokes.max() ?? 0
        FileHandle.standardError.write(Data(String(format: "SEARCH-MANY 600 matches: keystroke max %.1f ms median %.1f ms; main stall max %.1f ms\n",
                                                   slowest * 1_000, keystrokes.sorted()[keystrokes.count / 2] * 1_000, worst * 1_000).utf8))
        XCTAssertLessThan(slowest, releaseBudget(0.05), "Refining 600 snippets and redrawing the list")
        XCTAssertLessThan(worst, releaseBudget(0.05))
    }
}
