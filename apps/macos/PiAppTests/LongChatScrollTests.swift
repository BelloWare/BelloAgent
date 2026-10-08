import XCTest
import AppKit
@testable import PiApp

/// Scrolling a long chat end to end, in the real conversation pane, the way
/// a reader does it: a trackpad gesture frame by frame to the first message
/// and back, a fling of the wheel, the scroller dragged to the top, Home and
/// End, and a reply streaming in while the reader scrolls. Every frame checks
/// that the row the reader is on moved exactly as they scrolled it — a page
/// read in above them, rows let go of above them, or estimates measuring
/// never move it — and that the page never makes them wait at an edge with
/// more of the chat still to read. Frame times are held to a budget in
/// Release (`releaseBudget`); everything else holds in every configuration.
///
/// Serial: the frame times, and how far ahead a page arrives, are the
/// machine's to keep, not shared with other test hosts.
final class LongChatScrollTests: XCTestCase, SerialTestLane {
    /// The frame budget, in seconds, for scrolling through a long chat in
    /// Release, from what 0.1.122 measures on this fixture (Release, an idle
    /// machine; docs/perf/long-chat-scrolling.md). Most frames take their
    /// 16.7 ms; the long ones are where a page of earlier rows lands (rows
    /// estimated and the page placed again, ~50 ms) or a very long reply is
    /// first built and measured (~70 ms of it TextKit laying out a 51 KB
    /// reply). The budget holds those to well under 150 ms — the build before
    /// this one peaked at 151–185 ms — and to a small share of the frames,
    /// and keeps p95 within three frames and p99 within six.
    static let p95Budget = 0.050, p99Budget = 0.100, maxBudget = 0.150, slowShareBudget = 0.05

        @MainActor private func chat(turns: Int = 80) async throws -> LongChatScroll {
        let chat = try await LongChatScroll(turns: turns)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        XCTAssertNotNil(chat.view.olderPage.cursor, "The chat opens on its newest page, with earlier pages to read")
        return chat
    }

    /// `loading`: the reader holds the scroller at an edge, so the page reads
    /// one page after another under their hand; only the slowest frame is
    /// held to the budget there.
    @MainActor private func assertSmooth(_ run: LongChatScroll.Run, _ label: String, checkStalls: Bool = true, loading: Bool = false,
                                         file: StaticString = #filePath, line: UInt = #line) {
        print(run.summary(label))
        XCTAssertTrue(run.reached, "\(label): never got there in \(Int(run.seconds)) s", file: file, line: line)
        XCTAssertEqual(run.jumps.count, 0, "\(label): the reader's row moved on its own:\n" + run.jumps.prefix(8).joined(separator: "\n"), file: file, line: line)
        XCTAssertEqual(run.lost, 0, "\(label): the row the reader was on was let go of", file: file, line: line)
        XCTAssertEqual(run.errors, [], "\(label): a page failed to read", file: file, line: line)
        if checkStalls {
            XCTAssertEqual(run.stallFrames, 0, "\(label): the reader waited at an edge for \(run.stallFrames) frames with more of the chat to read", file: file, line: line)
        }
        XCTAssertLessThanOrEqual((run.frames.max() ?? 0) / 1000, releaseBudget(Self.maxBudget), "\(label): slowest frame", file: file, line: line)
        guard !loading else { return }
        XCTAssertLessThanOrEqual(run.percentile(run.frames, 0.95) / 1000, releaseBudget(Self.p95Budget), "\(label): p95 frame", file: file, line: line)
        XCTAssertLessThanOrEqual(run.percentile(run.frames, 0.99) / 1000, releaseBudget(Self.p99Budget), "\(label): p99 frame", file: file, line: line)
        let slow = Double(run.frames.filter { $0 > 50 }.count) / Double(max(1, run.frames.count))
        XCTAssertLessThanOrEqual(slow, releaseBudget(Self.slowShareBudget), "\(label): share of frames over 50 ms", file: file, line: line)
    }

    /// Up from the newest message to the very first, a trackpad gesture of
    /// 120 points a frame, then all the way back down to the newest.
    @MainActor func testScrollingToTheFirstMessageAndBackIsSmooth() async throws {
        let chat = try await chat()
        let up = await chat.drive(points: 120, seconds: 180) { chat.atFirstMessage }
        assertSmooth(up, "gesture up")
        XCTAssertEqual(chat.readingRow()?.id, chat.firstID, "The first row on screen is the chat's first message")
        let down = await chat.drive(points: -120, seconds: 180) { chat.atLastMessage }
        assertSmooth(down, "gesture down")
    }

    /// A fling: the wheel at 400 points a frame. AppKit applies each step on
    /// its own schedule, so the row may only have moved the way the reader
    /// is going, and the page must still never stop them at an edge.
    @MainActor func testAFlingToTheFirstMessageNeverStopsOrJumps() async throws {
        let chat = try await chat()
        let fling = await chat.drive(points: 400, seconds: 120, input: .wheel) { chat.atFirstMessage }
        assertSmooth(fling, "wheel fling up")
    }

    /// The scroller's knob dragged to the top and held there: the page keeps
    /// reading earlier pages under the reader's hand until it reaches the
    /// first message, and nothing ever moves back down. The reader is at the
    /// top of what is read the whole time, so waiting there is the drag's
    /// own doing, not a stall.
    @MainActor func testDraggingTheScrollerToTheTopReachesTheFirstMessage() async throws {
        let chat = try await chat()
        let drag = await chat.drive(points: 1, seconds: 120, input: .scroller) { chat.atFirstMessage }
        assertSmooth(drag, "scroller to the top", checkStalls: false, loading: true)
        let back = await chat.drive(points: -1, seconds: 120, input: .scroller) { chat.atLastMessage }
        assertSmooth(back, "scroller to the bottom", checkStalls: false, loading: true)
    }

    /// Home, pressed with the conversation focused, goes to the chat's first
    /// message — not the top of the rows the page happens to hold — and the
    /// first message then stays exactly where it landed while the rest of
    /// the page measures. End goes back to the newest message.
    @MainActor func testHomeReachesTheFirstMessageAndItStaysPut() async throws {
        let chat = try await chat()
        let scroll = try XCTUnwrap(chat.scroll)
        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: chat.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: keyCode))
        }
        // Home with the conversation focused (from the composer the same
        // key reaches it through `ComposerTextView.conversationScroll`).
        scroll.keyDown(with: try key(KeyCode.home))
        try await eventually("Home never reached the chat's first message", timeout: .seconds(20)) { chat.draw(); return chat.atFirstMessage }
        // In one read of the chat's first page, not by reading every page
        // between the newest and it: the rows after the window are unread.
        XCTAssertNotNil(chat.view.newerPage.cursor, "Home read the chat's first page directly")
        let landed = try XCTUnwrap(chat.screenTop(of: chat.firstID))
        // Idle measuring runs for a while after a landing: the first message
        // must not move under the reader while it does.
        let clock = ContinuousClock(), until = clock.now.advanced(by: .seconds(2))
        while clock.now < until {
            chat.draw()
            let now = try XCTUnwrap(chat.screenTop(of: chat.firstID), "The first message was let go of")
            XCTAssertEqual(now, landed, accuracy: 1, "The first message moved after it landed")
            if abs(now - landed) > 1 { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(chat.readingRow()?.id, chat.firstID)
        // ⌘↓ with the conversation itself focused.
        scroll.keyDown(with: try key(KeyCode.downArrow, .command))
        try await eventually("⌘↓ never returned to the newest message", timeout: .seconds(20)) {
            chat.draw(); return chat.view.newerPage.cursor == nil && chat.view.messages.last?.id == chat.lastID && chat.page?.followsBottom == true
        }
    }

    /// A reply streams in at the end of the chat while the reader scrolls up
    /// away from it and back: rows growing below the reader never move them,
    /// and once back at the bottom the page follows the reply again.
    @MainActor func testScrollingWhileAReplyStreams() async throws {
        let chat = try await chat(turns: 40)
        let replyID = try XCTUnwrap(chat.view.messages.last?.id)
        var tokens = 0
        func stream() {
            // By id: earlier pages read in above shift every index.
            guard let index = chat.view.messages.firstIndex(where: { $0.id == replyID }) else { return XCTFail("The streaming reply left the page") }
            tokens += 1
            chat.view.messages[index].text += " token\(tokens)" + (tokens % 12 == 0 ? "\n\n" : "")
        }
        // Up a few screens while the reply grows.
        let up = await chat.drive(points: 90, seconds: 30, onFrame: stream) { tokens >= 120 }
        print(up.summary("streaming up"))
        XCTAssertEqual(up.jumps.count, 0, "The reader's row moved while a reply streamed below:\n" + up.jumps.prefix(8).joined(separator: "\n"))
        XCTAssertEqual(up.lost, 0)
        // And back down to it: it follows the reply again.
        let down = await chat.drive(points: -90, seconds: 30, onFrame: stream) { chat.page?.followsBottom == true && chat.clipY >= chat.highest - 0.5 }
        print(down.summary("streaming down"))
        XCTAssertTrue(down.reached, "The reader never got back to the streaming reply")
        XCTAssertEqual(down.jumps.count, 0, "The reader's row moved while a reply streamed:\n" + down.jumps.prefix(8).joined(separator: "\n"))
        for _ in 0..<30 {
            stream(); chat.draw()
            try await Task.sleep(for: .milliseconds(16))
        }
        try await eventually("The page stopped following the reply") { chat.draw(); return chat.clipY >= chat.highest - TranscriptPage.followThreshold }
        XCTAssertLessThanOrEqual(down.percentile(down.frames, 0.95) / 1000, releaseBudget(Self.p95Budget), "streaming p95 frame")
        XCTAssertLessThanOrEqual((down.frames.max() ?? 0) / 1000, releaseBudget(Self.maxBudget), "streaming slowest frame")
    }
}
