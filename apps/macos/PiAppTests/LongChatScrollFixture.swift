import XCTest
import AppKit
@testable import PiApp

/// A long chat shaped like a real one — questions, tool calls with their
/// output, long replies with code — read from its journal through the app's
/// own history reader, shown in the real conversation pane, and scrolled the
/// way a trackpad scrolls it: one wheel event per display frame.
@MainActor final class LongChatScroll {
    let model: WorkspaceModel
    let chat: ChatRecord
    let view: SessionDisplay
    let window: NSWindow
    let pane: ConversationPaneView
    let root: URL
    let turns: Int
    /// The journal's first and last message ids.
    let firstID = "u0"
    var lastID: String { "a\(turns - 1)b" }

    /// `bigOutputTurn`: that turn's first tool output is larger than a page
    /// may hold (`HistoryWindowPolicy.envelopeBytes`), and its second one
    /// ends with a line nothing else says, "zephyr checkpoint 42".
    static func journal(turns: Int, bigOutputTurn: Int? = nil) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data(), parent: String? = nil
        func add(_ id: String, _ message: [String: WireValue]) throws {
            data.append(try encoder.encode(["type": WireValue.string("message"), "id": .string(id),
                                            "parentId": parent.map(WireValue.string) ?? .null, "message": .object(message)]))
            data.append(10); parent = id
        }
        data.append(try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("long")])); data.append(10)
        func code(_ lines: Int, _ seed: Int) -> String {
            (0..<lines).map { "    let value\($0) = compute(\(seed), \($0)) // step \($0) of the pass" }.joined(separator: "\n")
        }
        for turn in 0..<turns {
            var question = "Question \(turn): please look at module \(turn % 17) and tell me what changed in the parser."
            if turn % 9 == 4 { question += "\n\nHere is the failing part:\n\n```swift\n" + code(18 + turn % 20, turn) + "\n```\n\nWhy does it fail?" }
            try add("u\(turn)", ["role": .string("user"), "content": .string(question)])
            try add("a\(turn)a", ["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("I'll look at the module and its tests first.")]),
                .object(["type": .string("toolCall"), "id": .string("t\(turn)a"), "name": .string("bash"),
                         "arguments": .object(["command": .string("rg -n 'parse' Sources/Module\(turn % 17) | head -80")])]),
                .object(["type": .string("toolCall"), "id": .string("t\(turn)b"), "name": .string("read"),
                         "arguments": .object(["path": .string("Sources/Module\(turn % 17)/Parser\(turn).swift")])]),
            ])])
            let lines = turn == bigOutputTurn ? 5_000 : 5 + turn * 7 % 60
            let grep = (0..<lines).map { "Sources/Module\(turn % 17)/File\($0).swift:\($0 * 3 + 1): let token = parse(input, at: \($0))" }.joined(separator: "\n")
            try add("r\(turn)a", ["role": .string("toolResult"), "toolCallId": .string("t\(turn)a"), "toolName": .string("bash"),
                                  "content": .array([.object(["type": .string("text"), "text": .string(grep)])])])
            try add("r\(turn)b", ["role": .string("toolResult"), "toolCallId": .string("t\(turn)b"), "toolName": .string("read"),
                                  "content": .array([.object(["type": .string("text"), "text": .string(code(20 + turn * 13 % 150, turn) + (turn == bigOutputTurn ? "\n// zephyr checkpoint 42" : ""))])])])
            let sections = turn % 37 == 20 ? 40 : 1 + turn % 4
            var parts: [String] = []
            for section in 0..<sections {
                let heading = "## Finding \(turn).\(section)\n\nThe parser in module \(turn % 17) reads the token stream twice when **a nested block** closes early, "
                let body = "so `parse(input:)` returns a shorter tree than the caller expects. This paragraph is long enough to wrap across the pane at its usual width.\n\n"
                let list = "- The first pass keeps the offsets.\n- The second pass loses them after a nested block.\n\n"
                let block: String = "```swift\n" + code(8 + (turn + section) % 22, turn * 100 + section) + "\n```\n"
                parts.append(heading + body + list + block)
            }
            let reply = parts.joined(separator: "\n") + "\n\nThat is everything for question \(turn)."
            try add("a\(turn)b", ["role": .string("assistant"), "content": .string(reply)])
        }
        return data
    }

    init(turns: Int, width: CGFloat = 900, height: CGFloat = 760, bigOutputTurn: Int? = nil) async throws {
        self.turns = turns
        root = scratchRoot("long-chat-scroll")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("long.jsonl")
        try Self.journal(turns: turns, bigOutputTurn: bigOutputTurn).write(to: file)
        model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        chat = ChatRecord(id: "long", workspaceID: "project", title: "Long", path: file.path, profileID: "profile")
        model.chats = [chat]
        await model.select("long")
        view = try XCTUnwrap(model.selected)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        pane = ConversationPaneView(model: model)
        pane.show(session: view, chat: chat)
        window.contentView = pane; window.makeKeyAndOrderFront(nil)
    }

    var marker: TranscriptSurfaceMarker? { Self.views(TranscriptSurfaceMarker.self, in: pane).first }
    var page: TranscriptPage? { marker?.page }
    var scroll: TranscriptNativeScrollView? { Self.views(TranscriptNativeScrollView.self, in: pane).first }
    var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
    func draw() { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func ready() async throws {
        try await eventually("The long chat never opened", timeout: .seconds(60)) { draw(); return view.historyState == .ready && document?.retainedRows.isEmpty == false }
        for _ in 0..<10 { draw(); try await Task.sleep(for: .milliseconds(10)) }
    }
    func close() { window.contentView = nil; window.close() }

    // MARK: Where the reader is

    var clipY: CGFloat { scroll?.contentView.bounds.minY ?? 0 }
    var lowest: CGFloat { -(scroll?.contentInsets.top ?? 0) }
    var highest: CGFloat {
        guard let scroll else { return 0 }
        return max(lowest, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
    }
    /// The row the reader is reading at the top of the screen and where its
    /// top is, relative to the viewport's top: the row covering the top, or —
    /// when less than a third of the screen shows that one — the row after
    /// it, which starts on screen (`TranscriptReadingCoordinator.firstStartingOnScreen`).
    func readingRow() -> (id: String, top: CGFloat)? {
        guard let document, let scroll else { return nil }
        let top = scroll.contentView.bounds.minY
        guard let covering = document.retainedRows.first(where: { $0.frame.maxY > top + 1 }) else { return nil }
        let row = TranscriptReadingCoordinator.firstStartingOnScreen(document, clip: scroll.contentView, after: covering) ?? covering
        return (row.itemID, row.frame.minY - top)
    }
    /// Where row `id`'s top is on screen now, or nil once the page let go of it.
    func screenTop(of id: String) -> CGFloat? {
        guard let document, let scroll, let row = document.retainedRows.first(where: { $0.itemID == id }) else { return nil }
        return row.frame.minY - scroll.contentView.bounds.minY
    }

    /// How the reader moves.
    enum Input { case gesture, wheel, scroller }
    /// One wheel event of `points` (positive scrolls up, toward the start).
    /// AppKit applies it on its own schedule, up to a frame later.
    func wheel(_ points: CGFloat) {
        guard let scroll, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(points.rounded()), wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:)) else { return }
        scroll.scrollWheel(with: event)
    }
    /// One frame of a trackpad gesture: the clip moves by `points` at once,
    /// and the scroll view says so, as AppKit does inside a live scroll.
    func gestureStep(_ points: CGFloat) {
        guard let scroll else { return }
        scroll.readerWillNavigate(upward: points > 0)
        let clip = scroll.contentView
        let target = min(max(lowest, clip.bounds.minY - points), highest)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    func beginGesture() {
        guard let scroll else { return }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    }
    func endGesture() {
        guard let scroll else { return }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    /// The reader drags the scroller's knob to `fraction` of the loaded
    /// rows (0 is the top). NSScroller's tracking loop moves the clip on each
    /// mouse-dragged event inside a live scroll, without a wheel event.
    func dragKnob(to fraction: CGFloat) {
        guard let scroll else { return }
        let clip = scroll.contentView
        let target = lowest + (highest - lowest) * min(1, max(0, fraction))
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }

    // MARK: Driving it frame by frame

    struct Run {
        var frames: [Double] = []          // ms between frame starts
        var work: [Double] = []            // ms of the frame's own scroll + layout + display
        var jumps: [String] = []
        var lost = 0
        var stallFrames = 0                // frames the reader pushed at an edge with more to read
        var loads = 0
        var errors: [String] = []
        var reached = false
        var seconds: Double = 0
        /// For the slowest frames: what happened in them (`hitchReport`).
        var hitches: [(ms: Double, what: String)] = []
        func hitchReport(_ count: Int = 12) -> [String] {
            hitches.sorted { $0.ms > $1.ms }.prefix(count).map { String(format: "%.1f ms: %@", $0.ms, $0.what) }
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        func summary(_ label: String) -> String {
            String(format: "LONGSCROLL %@: reached=%@ %.1f s, %d frames, interval p50/p95/p99/max %.1f/%.1f/%.1f/%.1f ms, work p95/max %.1f/%.1f ms, over 25 ms %d, over 50 ms %d, jumps %d, lost %d, stall frames %d, loads %d, errors %d",
                   label, reached ? "yes" : "NO", seconds, frames.count, percentile(frames, 0.5), percentile(frames, 0.95), percentile(frames, 0.99), frames.max() ?? 0,
                   percentile(work, 0.95), work.max() ?? 0, frames.filter { $0 > 25 }.count, frames.filter { $0 > 50 }.count, jumps.count, lost, stallFrames, loads, errors.count)
        }
    }

    /// Scrolls `points` per frame (positive up) at 60 frames a second until
    /// `done` holds or `seconds` pass. Checks every frame that the reader's
    /// row moved by exactly the scroll, and that it stayed put between frames.
    func drive(points: CGFloat, seconds: Double, input: Input = .gesture, gestureFrames: Int = 90,
               onFrame: () -> Void = {}, done: () -> Bool) async -> Run {
        var run = Run()
        let clock = ProcessInfo.processInfo
        let began = clock.systemUptime, period = 1.0 / 60
        var next = began, lastStart: Double?
        var wasLoading = view.olderPage.loading || view.newerPage.loading
        func counters(_ document: TranscriptNativeDocument) -> (rows: Int, built: Int, passes: Int, traversals: Int, corrections: Int, estimated: Int) {
            (view.messages.count, document.rowsBuiltCount, document.layoutPassCount, document.rowLayoutTraversalCount, document.correctionRounds, document.estimatedEver)
        }
        var lastCounters = document.map(counters) ?? (rows: 0, built: 0, passes: 0, traversals: 0, corrections: 0, estimated: 0)
        var previous = readingRow()
        var previousClip = clipY, previousRowY = (previous?.top ?? 0) + clipY
        while clock.systemUptime - began < seconds {
            if done() { run.reached = true; break }
            let start = clock.systemUptime
            if let lastStart {
                let interval = (start - lastStart) * 1000
                run.frames.append(interval)
                if interval > 33, let document {
                    let now = counters(document)
                    run.hitches.append((interval, String(format: "rows %d→%d, built %d, passes %d, traversals %d, corrections %d, estimated %d, approximate %d, work %.1f",
                        lastCounters.rows, now.rows, now.built - lastCounters.built, now.passes - lastCounters.passes, now.traversals - lastCounters.traversals,
                        now.corrections - lastCounters.corrections, now.estimated - lastCounters.estimated, document.approximateRowCount, run.work.last ?? 0)))
                }
            }
            if let document { lastCounters = counters(document) }
            lastStart = start
            // Between frames nobody scrolled a gesture: the reader's row must
            // be where it was. A wheel or a scroller moves the clip on AppKit's
            // own schedule, so there the row may only have moved the way the
            // reader is going — a wheel by at most a few of its steps — never
            // back, and never by a page read in above it.
            if let previous, let now = screenTop(of: previous.id) {
                let moved = now - previous.top, along = points > 0 ? moved : -moved
                let wrong: Bool
                switch input {
                case .gesture: wrong = abs(moved) > 1
                case .wheel: wrong = along < -1 || along > abs(points) * 4 + 1
                case .scroller: wrong = along < -1
                }
                if wrong {
                    run.jumps.append(String(format: "between frames %d: %@ moved %.1f pt (row in document %.1f -> %.1f, clip %.1f -> %.1f, rows %d, first %@, anchor %@ %@)", run.frames.count, previous.id, moved,
                                            previousRowY, now + clipY, previousClip, clipY, view.messages.count, view.messages.first?.id ?? "-",
                                            scroll?.transcriptReading.hasAnchor == true ? "held" : "none", scroll?.transcriptReading.lastInvalidation ?? "-"))
                }
            } else if previous != nil { run.lost += 1 }
            onFrame()
            let before = readingRow(), y = clipY
            let room = points > 0 ? max(0, y - lowest) : max(0, highest - y)
            let expected = points > 0 ? min(points, room) : -min(-points, room)
            if room < 0.5 { run.stallFrames += 1 }
            switch input {
            case .wheel: wheel(points)
            case .gesture:
                if run.frames.count % gestureFrames == 0 { if run.frames.count > 0 { endGesture() }; beginGesture() }
                gestureStep(points)
            case .scroller:
                if run.frames.isEmpty { beginGesture() }
                dragKnob(to: points > 0 ? 0 : 1)
            }
            draw()
            run.work.append((clock.systemUptime - start) * 1000)
            if input == .gesture, let before, let now = screenTop(of: before.id) {
                // Rows move down on screen as the reader scrolls up.
                let moved = now - before.top
                if abs(moved - expected) > 1 { run.jumps.append(String(format: "frame %d: %@ moved %.1f pt, scroll %.1f", run.frames.count, before.id, moved, expected)) }
            } else if input == .gesture, before != nil { run.lost += 1 }
            previous = readingRow()
            previousClip = clipY; previousRowY = (previous?.top ?? 0) + clipY
            let loading = view.olderPage.loading || view.newerPage.loading
            if loading && !wasLoading { run.loads += 1 }
            wasLoading = loading
            for error in [view.olderPage.error, view.newerPage.error].compactMap({ $0 }) where !run.errors.contains(error) { run.errors.append(error) }
            next += period
            let now = clock.systemUptime
            if next < now { next = now }
            try? await Task.sleep(for: .seconds(next - now))
        }
        if input != .wheel { endGesture() }
        if !run.reached, done() { run.reached = true }
        run.seconds = clock.systemUptime - began
        return run
    }
    var atFirstMessage: Bool {
        view.messages.first?.id == firstID && view.olderPage.cursor == nil && clipY <= lowest + 0.5
    }
    var atLastMessage: Bool {
        view.newerPage.cursor == nil && view.messages.last?.id == lastID && clipY >= highest - 0.5
    }
}
