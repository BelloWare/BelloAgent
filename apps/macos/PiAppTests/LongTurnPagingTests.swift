import XCTest
import AppKit
@testable import PiApp

/// A long chat whose turns each make forty to sixty tool calls, as a coding
/// agent's turns do, written the way the helper writes its journal (task ids
/// on every row, the task's receipt after its answer) and read through the
/// app's own history reader into the real conversation pane.
///
/// The owner (0.1.131): opening such a chat showed a turn as "42 tool calls"
/// when all of it was loaded, but as every call in detail when the window
/// began inside it, and the same turn changed shape as the rest of it loaded.
/// A turn must read the same however much of the chat is loaded.
enum ToolHeavyJournal {
    /// The calls turn `turn` makes: 40 to 60.
    static func calls(_ turn: Int) -> Int { 40 + turn * 7 % 21 }
    /// One journal, and the id of its last message. `bigTurn` makes that turn
    /// `bigCalls` calls long instead.
    static func make(turns: Int, receipts: Bool = true, bigTurn: Int? = nil, bigCalls: Int = 0,
                     calls: (Int) -> Int = ToolHeavyJournal.calls) throws -> (data: Data, lastID: String) {
        let encoder = JSONEncoder()
        var data = Data(), parent: String? = nil, last = ""
        var clock = 1_790_000_000_000.0
        func add(_ id: String, _ record: [String: WireValue]) throws {
            var record = record
            record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            data.append(try encoder.encode(record)); data.append(10); parent = id
        }
        func message(_ id: String, turn: Int, _ fields: [String: WireValue]) throws {
            clock += 1_500
            var message = fields
            message["timestamp"] = .number(clock)
            message["nativeTurn"] = .string("u\(turn)"); message["nativeTaskRoot"] = .string("u\(turn)")
            message["nativeTaskExecution"] = .string("e\(turn)")
            try add(id, ["type": .string("message"), "message": .object(message)])
            last = id
        }
        data.append(try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("tools")])); data.append(10)
        for turn in 0..<turns {
            let started = clock
            try message("u\(turn)", turn: turn, ["role": .string("user"),
                "content": .string("Question \(turn): find every caller of the parser in module \(turn % 13) and fix the off-by-one.")])
            let count = turn == bigTurn ? bigCalls : calls(turn)
            for step in 0..<count {
                let call = "c\(turn)_\(step)", read = step % 3 != 0
                var content: [WireValue] = []
                // Most steps only call; every fifth says what it is doing first.
                if step % 5 == 0 { content.append(.object(["type": .string("text"), "text": .string("Step \(step): checking the callers in file \(step).")])) }
                content.append(.object(["type": .string("toolCall"), "id": .string(call), "name": .string(read ? "read" : "bash"),
                                        "arguments": .object(read ? ["path": .string("Sources/Module\(turn % 13)/File\(step).swift")]
                                                                  : ["command": .string("rg -n 'parse(' Sources/Module\(turn % 13) | head -40")])]))
                try message("a\(turn)_\(step)", turn: turn, ["role": .string("assistant"), "content": .array(content), "nativeModelMs": .number(900)])
                let lines = 6 + (turn * 5 + step * 3) % 18
                let output = (0..<lines).map { "Sources/Module\(turn % 13)/File\(step).swift:\($0 * 4 + 1): let token = parse(input, at: \($0)) // pass \(step)" }.joined(separator: "\n")
                try message("r\(turn)_\(step)", turn: turn, ["role": .string("toolResult"), "toolCallId": .string(call), "toolName": .string(read ? "read" : "bash"),
                                                           "content": .array([.object(["type": .string("text"), "text": .string(output)])])])
            }
            let answer = (0..<(2 + turn % 3)).map { "Paragraph \($0) of the answer to question \(turn): the parser in module \(turn % 13) skipped the last token when a nested block closed early, so the callers now pass the end index explicitly." }
                .joined(separator: "\n\n")
            try message("a\(turn)_z", turn: turn, ["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(answer)])]),
                                                   "nativeModelMs": .number(1_200)])
            if receipts {
                var task = TaskPresentationRecord(rootID: "u\(turn)", executionID: "e\(turn)", startedAt: started / 1000, startedAtUnixMs: started)
                task.outcome = "completed"; task.phase = "terminal"; task.endedAt = clock / 1000; task.endedAtUnixMs = clock
                task.lastSourceID = "a\(turn)_z"; task.issuedCalls = count; task.replies = count + 1
                let value = try JSONDecoder().decode(WireValue.self, from: encoder.encode(task))
                try add("t\(turn)", ["type": .string("custom"), "customType": .string("pi-app.task-terminal.v1"), "data": value])
            }
        }
        return (data, last)
    }
    /// The turn a row belongs to, from the ids this journal writes.
    static func turn(of id: String) -> Int? {
        let id = id.hasPrefix("fold:") ? String(id.dropFirst(5)) : id
        guard let first = id.first, "uarte".contains(first) else { return nil }
        return Int(id.dropFirst().prefix { $0.isNumber })
    }
}

/// Opens tool-heavy chats and reads what each turn looks like.
@MainActor final class ToolHeavyChat {
    let chat: LongChatScroll
    init(turns: Int, receipts: Bool = true, bigTurn: Int? = nil, bigCalls: Int = 0, height: CGFloat = 760) async throws {
        let journal = try ToolHeavyJournal.make(turns: turns, receipts: receipts, bigTurn: bigTurn, bigCalls: bigCalls)
        chat = try await LongChatScroll(turns: turns, height: height, journal: journal)
    }
    var view: SessionDisplay { chat.view }
    var rows: [TranscriptRowContainer] { chat.document?.retainedRows ?? [] }

    /// How one turn reads: the line its work folds behind (nil when it shows
    /// every row), and for each of its rows whether the fold hides it.
    struct Shape: Equatable, CustomStringConvertible {
        var fold: String?
        var hidden: [String: Bool] = [:]
        var description: String {
            "fold \(fold.map { "\"\($0)\"" } ?? "none"), \(hidden.values.filter { !$0 }.count) rows drawn, \(hidden.values.filter { $0 }.count) folded away"
        }
    }
    func shapes() -> [Int: Shape] {
        var shapes: [Int: Shape] = [:]
        for row in rows {
            let id = row.itemID
            guard let turn = ToolHeavyJournal.turn(of: row.item.messageIDs.first ?? id) ?? ToolHeavyJournal.turn(of: id) else { continue }
            var shape = shapes[turn] ?? Shape()
            if case .block(let block) = row.item, block.presentation == .turnFold { shape.fold = block.foldSummary?.label }
            else { shape.hidden[id] = TranscriptRowDisclosure.of(row.item, in: view.disclosure).foldedAway }
            shapes[turn] = shape
        }
        return shapes
    }
    /// The turn the window's first row belongs to, and whether that row is
    /// the turn's own question (or the chat's first row).
    var windowStart: (turn: Int, atTurnStart: Bool)? {
        guard let first = view.messages.first, let turn = ToolHeavyJournal.turn(of: first.id) else { return nil }
        return (turn, first.role == "user" || view.olderPage.cursor == nil)
    }
    var windowEnd: (turn: Int, atTurnEnd: Bool)? {
        guard let last = view.messages.last, let turn = ToolHeavyJournal.turn(of: last.id) else { return nil }
        return (turn, last.id == "a\(turn)_z" || view.newerPage.cursor == nil)
    }
    /// What the first rows of `turn` are and how tall they are drawn.
    func describe(_ turn: Int, rows count: Int = 8) -> [String] {
        rows.filter { row in (ToolHeavyJournal.turn(of: row.item.messageIDs.first ?? row.itemID) ?? ToolHeavyJournal.turn(of: row.itemID)) == turn }
            .prefix(count).map { row in
                let kind: String
                switch row.item {
                case .message(let message): kind = message.kind ?? message.role
                case .block(let block): kind = block.presentation == .turnFold ? "fold \"\(block.foldSummary?.label ?? "")\"" : (block.part?.part.kind ?? "\(block.presentation)")
                }
                return String(format: "%@ %@ %.0f pt%@", row.itemID, kind, row.frame.height, chat.document?.isApproximate(row.itemID) == true ? " (estimated)" : "")
            }
    }
}

/// Serial: it shows a window, and scrolls it frame by frame.
final class LongTurnPagingTests: XCTestCase, SerialTestLane {
    @MainActor private func open(turns: Int = 30, receipts: Bool = true, bigTurn: Int? = nil, bigCalls: Int = 0) async throws -> ToolHeavyChat {
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(.compact)
        let heavy = try await ToolHeavyChat(turns: turns, receipts: receipts, bigTurn: bigTurn, bigCalls: bigCalls)
        registerWorkspaceFixtureTeardown(heavy.chat.model, root: heavy.chat.root)
        addTeardownBlock { @MainActor in heavy.chat.close(); TranscriptDisplay.use(previous) }
        // The default transcript: a finished turn folds its work.
        TranscriptDisplay.use(.compact)
        try await heavy.chat.ready()
        return heavy
    }

    /// Opening a long chat whose turns are each longer than a history page
    /// started the window inside its newest turn, which then showed every
    /// call; once the rest of that turn was read in, the same turn folded
    /// behind "N tool calls" and its rows vanished. Every turn must read the
    /// same — the same fold line, the same rows drawn — whether the window
    /// has just been opened or has read more of the chat since.
    @MainActor func testATurnReadsTheSameHoweverMuchOfTheChatIsLoaded() async throws {
        let heavy = try await open()
        let view = heavy.view
        let start = try XCTUnwrap(heavy.windowStart)
        let opened = heavy.shapes()
        print("TURNPAGING opened: \(view.messages.count) rows, first \(view.messages.first?.id ?? "-") (turn \(start.turn), at its start: \(start.atTurnStart)), last \(view.messages.last?.id ?? "-")")
        for line in heavy.describe(start.turn) { print("TURNPAGING   opened turn \(start.turn): " + line) }
        print("TURNPAGING   opened turn \(start.turn) reads: \(opened[start.turn].map(String.init(describing:)) ?? "-")")
        XCTAssertTrue(start.atTurnStart, "The window opened inside turn \(start.turn): its first row is \(view.messages.first?.id ?? "-"), not the turn's question")
        // Read earlier rows until the turn the window started in is whole.
        var reads = 0
        while view.messages.first?.id != "u\(start.turn)", view.olderPage.cursor != nil, reads < 20 {
            let read = await heavy.chat.model.loadEarlierPage(sessionID: view.id)
            XCTAssertTrue(read, "An earlier page read")
            reads += 1
            for _ in 0..<4 { heavy.chat.draw(); try await Task.sleep(for: .milliseconds(10)) }
        }
        let whole = heavy.shapes()
        print("TURNPAGING after \(reads) earlier page(s): \(view.messages.count) rows, first \(view.messages.first?.id ?? "-")")
        for line in heavy.describe(start.turn) { print("TURNPAGING   whole turn \(start.turn): " + line) }
        print("TURNPAGING   whole turn \(start.turn) reads: \(whole[start.turn].map(String.init(describing:)) ?? "-")")
        // One more page of earlier rows: what the window held must not change.
        if view.olderPage.cursor != nil {
            let read = await heavy.chat.model.loadEarlierPage(sessionID: view.id)
            XCTAssertTrue(read)
            for _ in 0..<4 { heavy.chat.draw(); try await Task.sleep(for: .milliseconds(10)) }
        }
        let more = heavy.shapes()
        for (label, before, after) in [("opened → whole", opened, whole), ("whole → one page more", whole, more)] {
            for (turn, shape) in before.sorted(by: { $0.key < $1.key }) {
                guard let later = after[turn] else { continue }
                XCTAssertEqual(shape.fold, later.fold, "\(label): turn \(turn) read \(shape) and then \(later)")
                let common = Set(shape.hidden.keys).intersection(later.hidden.keys)
                let changed = common.filter { shape.hidden[$0] != later.hidden[$0] }
                XCTAssertTrue(changed.isEmpty, "\(label): \(changed.count) rows of turn \(turn) changed from drawn to folded or back, e.g. \(changed.sorted().prefix(3))")
            }
        }
    }

    /// Reading back past the resident window lets go of the newest turns,
    /// whole: the window's last turn is then a finished turn short of the
    /// newest row. Its work stays folded, as it was, also in a chat whose
    /// tasks wrote no receipt to say they ended (older chats, imports). The
    /// page is planned without a pane, so no read of its own joins in.
    @MainActor func testTheWindowsLastTurnKeepsItsFoldWhenNewerTurnsAreLetGo() async throws {
        let previous = TranscriptDisplay.mode
        defer { TranscriptDisplay.use(previous) }
        let root = scratchRoot("turn-last")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tools.jsonl")
        try ToolHeavyJournal.make(turns: 40, receipts: false).data.write(to: file)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        registerWorkspaceFixtureTeardown(model, root: root)
        TranscriptDisplay.use(.compact)
        model.chats = [ChatRecord(id: "tools", workspaceID: "project", title: "Tools", path: file.path, profileID: "profile")]
        await model.select("tools")
        let view = try XCTUnwrap(model.selected), page = TranscriptPage()
        page.bind(view)
        model.historyViewportReady(view.id, generation: view.presentationGeneration)
        /// Each turn's fold line, as the page plans it.
        func folds() -> [Int: String?] {
            var folds: [Int: String?] = [:]
            for item in page.snapshot?.items ?? [] {
                guard case .block(let block) = item, block.presentation == .turnFold, let turn = ToolHeavyJournal.turn(of: block.id) else { continue }
                folds[turn] = block.foldSummary?.label
            }
            for message in page.snapshot?.messages ?? [] where message.role == "user" {
                if let turn = ToolHeavyJournal.turn(of: message.id), folds[turn] == nil { folds[turn] = .some(nil) }
            }
            return folds
        }
        var seen = folds(), evicted = false
        XCTAssertFalse(seen.isEmpty)
        while view.olderPage.cursor != nil {
            let read = await model.loadEarlierPage(sessionID: view.id)
            XCTAssertTrue(read, "An earlier page read")
            guard read else { break }
            if view.newerPage.cursor != nil { evicted = true }
            let now = folds()
            for (turn, fold) in now {
                guard let earlier = seen[turn] else { continue }
                XCTAssertEqual(earlier, fold, "turn \(turn) read \(String(describing: earlier)) and then \(String(describing: fold)) (window \(view.messages.first?.id ?? "-")…\(view.messages.last?.id ?? "-"))")
            }
            seen.merge(now) { _, new in new }
        }
        XCTAssertTrue(evicted, "The window let go of its newest turns")
        XCTAssertTrue(view.newerPage.endsTurn, "It ends where a turn does")
        let last = try XCTUnwrap(view.messages.last), turn = try XCTUnwrap(ToolHeavyJournal.turn(of: last.id))
        XCTAssertEqual(last.id, "a\(turn)_z", "The window ends at turn \(turn)'s answer")
        XCTAssertNotNil(folds()[turn] ?? nil, "The window's last turn keeps its fold line")
    }

    /// Scrolling a long tool-heavy chat from its newest message to its first,
    /// a trackpad gesture frame by frame: how many pages it reads, whether
    /// each one lands at the start of a turn, and whether any turn changes
    /// shape or moves the reader once it has been drawn.
    @MainActor func testScrollingUpThroughToolHeavyTurnsNeverReshapesATurn() async throws {
        let heavy = try await open()
        let view = heavy.view, chat = heavy.chat
        var seen: [Int: ToolHeavyChat.Shape] = [:], reshaped: [String] = []
        var windows = 0, midTurn = 0, lastFirst = view.messages.first?.id, lastWindow = ""
        func check() {
            if view.messages.first?.id != lastFirst {
                lastFirst = view.messages.first?.id; windows += 1
                if heavy.windowStart?.atTurnStart == false { midTurn += 1 }
            }
            // A turn's shape changes only with the rows the window holds.
            let window = "\(view.messages.count) \(view.messages.first?.id ?? "") \(view.messages.last?.id ?? "") \(heavy.rows.count)"
            guard window != lastWindow else { return }
            lastWindow = window
            for (turn, shape) in heavy.shapes() {
                guard let earlier = seen[turn] else { seen[turn] = shape; continue }
                if earlier.fold != shape.fold || shape.hidden.contains(where: { id, hidden in earlier.hidden[id].map { $0 != hidden } ?? false }) {
                    reshaped.append("turn \(turn): \(earlier) → \(shape) (window \(view.messages.first?.id ?? "-")…\(view.messages.last?.id ?? "-"))")
                }
                var merged = earlier; merged.fold = shape.fold
                for (id, hidden) in shape.hidden { merged.hidden[id] = hidden }
                seen[turn] = merged
            }
        }
        check()
        let up = await chat.drive(points: 120, seconds: 240, onFrame: check) { chat.atFirstMessage }
        check()
        print(up.summary("tool-heavy gesture up"))
        print("TURNPAGING scrolled up: \(windows) windows, \(midTurn) of them starting inside a turn, \(reshaped.count) reshaped turns")
        for line in reshaped.prefix(12) { print("TURNPAGING   reshaped " + line) }
        for line in up.jumps.prefix(8) { print("TURNPAGING   jump " + line) }
        for line in up.hitchReport(6) { print("TURNPAGING   hitch " + line) }
        XCTAssertTrue(up.reached, "Never reached the first message in \(Int(up.seconds)) s")
        // Folded rows draw nothing and build nothing: the trees held are the
        // rows that draw, near the reader, not every row of every folded turn
        // scrolled past (each folded turn hides about 170 rows).
        XCTAssertLessThan(chat.document?.hostedRowCount ?? 0, 150, "Rows hidden by a turn's fold built their trees")
        XCTAssertEqual(midTurn, 0, "\(midTurn) of \(windows) windows started inside a turn")
        XCTAssertEqual(reshaped, [], "A turn changed shape after it was drawn")
        XCTAssertEqual(up.jumps.count, 0, "The reader's row moved on its own:\n" + up.jumps.prefix(8).joined(separator: "\n"))
        XCTAssertEqual(up.lost, 0, "The row the reader was on was let go of")
        XCTAssertEqual(up.errors, [])
    }
}

/// The measurement behind SCROLL-1 (opt-in, `PI_TURN_PROBE=1`): a tool-heavy
/// chat (`ToolHeavyJournal`, `PI_TURN_PROBE_TURNS` turns, 30 by default)
/// opened from its journal, read back page by page to its first message,
/// and scrolled from its newest message to its first and back with a
/// trackpad gesture. Prints TURNPROBE lines and asserts nothing; compare
/// builds with it (docs/validation/a131-scroll-0.1.131.md).
final class LongTurnPagingProbeTests: XCTestCase, SerialTestLane {
    override func setUpWithError() throws {
        try XCTSkipUnless(testEnvironment("PI_TURN_PROBE") == "1", "Set PI_TURN_PROBE=1 to measure tool-heavy paging")
    }
    private var turns: Int { Int(testEnvironment("PI_TURN_PROBE_TURNS") ?? "") ?? 30 }
    private static func footprint() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
    }
    private static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    /// From selecting the chat to its first rows on screen, then each earlier
    /// page read and landed, one by one, to the first message.
    @MainActor func testProbeOpeningAndReadingBack() async throws {
        let previous = TranscriptDisplay.mode
        defer { TranscriptDisplay.use(previous) }
        let journal = try ToolHeavyJournal.make(turns: turns)
        let root = scratchRoot("turn-probe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tools.jsonl")
        try journal.data.write(to: file)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        TranscriptDisplay.use(.compact)
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "tools", workspaceID: "project", title: "Tools", path: file.path, profileID: "profile")
        let empty = ChatRecord(id: "empty", workspaceID: "project", title: "Empty", path: nil, profileID: "profile")
        model.chats = [chat, empty]
        await model.select("empty")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = ConversationPaneView(model: model)
        pane.show(session: try XCTUnwrap(model.selected), chat: empty)
        window.contentView = pane; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        func draw() { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        var document: TranscriptNativeDocument? { LongChatScroll.views(TranscriptNativeScrollView.self, in: pane).first?.documentView as? TranscriptNativeDocument }
        for _ in 0..<10 { draw(); try await Task.sleep(for: .milliseconds(10)) }
        let opening = Self.footprint()
        let started = ProcessInfo.processInfo.systemUptime
        await model.select("tools")
        let view = try XCTUnwrap(model.selected)
        let sourceReady = ProcessInfo.processInfo.systemUptime - started
        pane.show(session: view, chat: chat)
        while ProcessInfo.processInfo.systemUptime - started < 60 {
            draw()
            if view.historyState == .ready, let document, document.visibleContentPrepared, document.retainedRows.contains(where: { $0.superview != nil }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let firstRows = ProcessInfo.processInfo.systemUptime - started
        print("TURNPROBE open \(turns) turns: source read \(Self.ms(sourceReady)) ms, first rows \(Self.ms(firstRows)) ms, window \(view.messages.count) rows (\(view.messages.first?.id ?? "-")…\(view.messages.last?.id ?? "-")), document rows \(document?.retainedRows.count ?? 0), footprint +\(String(format: "%.1f", Self.footprint() - opening)) MB")
        for _ in 0..<60 { draw(); try await Task.sleep(for: .milliseconds(16)) }
        var pages = 0, reads: [Double] = [], lands: [Double] = []
        while view.olderPage.cursor != nil, pages < 200 {
            let cursor = view.olderPage.cursor, rows = view.messages.count
            let readStarted = ProcessInfo.processInfo.systemUptime
            _ = try await model.history.window(path: file.path, cursor: cursor)
            let read = ProcessInfo.processInfo.systemUptime - readStarted
            let started = ProcessInfo.processInfo.systemUptime
            guard await model.loadEarlierPage(sessionID: view.id) else { break }
            let joined = ProcessInfo.processInfo.systemUptime - started
            let drawStarted = ProcessInfo.processInfo.systemUptime
            draw()
            let drawn = ProcessInfo.processInfo.systemUptime - drawStarted
            pages += 1; reads.append(read); lands.append(max(0, joined - read) + drawn)
            print("TURNPROBE page \(pages): \(rows) → \(view.messages.count) rows, first \(view.messages.first?.id ?? "-"), read \(Self.ms(read)) ms, joined \(Self.ms(joined)) ms, landing on the main thread ≈ \(Self.ms(max(0, joined - read) + drawn)) ms (draw \(Self.ms(drawn)) ms)")
            for _ in 0..<10 { draw(); try await Task.sleep(for: .milliseconds(16)) }
        }
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        print("TURNPROBE read back \(turns) turns: \(pages) pages, read mean/max \(Self.ms(mean(reads)))/\(Self.ms(reads.max() ?? 0)) ms, landing mean/max \(Self.ms(mean(lands)))/\(Self.ms(lands.max() ?? 0)) ms, window \(view.messages.count) rows, footprint +\(String(format: "%.1f", Self.footprint() - opening)) MB")
    }

    /// From the newest message to the first and back, 120 points a frame.
    @MainActor func testProbeGestureToTheFirstMessageAndBack() async throws {
        let previous = TranscriptDisplay.mode
        let heavy = try await ToolHeavyChat(turns: turns)
        let chat = heavy.chat, view = heavy.view
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close(); TranscriptDisplay.use(previous) }
        TranscriptDisplay.use(.compact)
        try await chat.ready()
        let opening = Self.footprint()
        var windows = 0, midTurn = 0, lastFirst = view.messages.first?.id, largest = view.messages.count
        func check() {
            largest = max(largest, view.messages.count)
            guard view.messages.first?.id != lastFirst else { return }
            lastFirst = view.messages.first?.id; windows += 1
            if heavy.windowStart?.atTurnStart == false { midTurn += 1 }
        }
        for (label, points) in [("up", CGFloat(120)), ("down", CGFloat(-120))] {
            let run = await chat.drive(points: points, seconds: 300, onFrame: check) { points > 0 ? chat.atFirstMessage : chat.atLastMessage }
            print(run.summary("tool-heavy \(turns) turns, gesture \(label)").replacingOccurrences(of: "LONGSCROLL", with: "TURNPROBE"))
            for line in run.hitchReport(6) { print("TURNPROBE \(label) hitch " + line) }
            for line in run.jumps.prefix(6) { print("TURNPROBE \(label) jump " + line) }
        }
        print("TURNPROBE gestures: \(windows) windows, \(midTurn) starting inside a turn, largest window \(largest) rows, footprint +\(String(format: "%.1f", Self.footprint() - opening)) MB")
    }
}
