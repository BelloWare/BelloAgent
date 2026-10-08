import XCTest
import AppKit
@testable import PiApp

/// The measurement behind `LongChatScrollTests`: prints what scrolling a
/// 200-turn chat does (frame intervals, jumps, stalls, page reads) for a
/// gesture up to the first message and back, a scroller drag, a wheel fling
/// and Home, without asserting. Opt-in (`PI_LONG_PROBE=1`); compare builds
/// with it (docs/perf/long-chat-scrolling.md).
final class LongChatScrollProbeTests: XCTestCase, SerialTestLane {
    override func setUpWithError() throws {
        try XCTSkipUnless(testEnvironment("PI_LONG_PROBE") == "1", "Set PI_LONG_PROBE=1 to measure long-chat scrolling")
    }
    @MainActor private func chat() async throws -> LongChatScroll {
        let turns = Int(testEnvironment("PI_LONG_TURNS") ?? "") ?? 200
        let chat = try await LongChatScroll(turns: turns)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close() }
        try await chat.ready()
        print("LONGSCROLL opened: \(chat.view.messages.count) rows, first \(chat.view.messages.first?.id ?? "-"), document \(chat.document?.frame.height ?? 0)")
        return chat
    }
    @MainActor private func report(_ chat: LongChatScroll, _ run: LongChatScroll.Run, _ label: String) {
        print(run.summary(label))
        print("LONGSCROLL \(label) state: rows \(chat.view.messages.count) first \(chat.view.messages.first?.id ?? "-") last \(chat.view.messages.last?.id ?? "-") older \(chat.view.olderPage.cursor?.entry ?? "nil") loading \(chat.view.olderPage.loading) newer \(chat.view.newerPage.cursor?.entry ?? "nil") y \(chat.clipY) lowest \(chat.lowest) highest \(chat.highest) waits \(chat.page?.earlierWaitsForReader ?? false)")
        for line in run.jumps.prefix(20) { print("LONGSCROLL \(label) jump " + line) }
        for line in run.errors { print("LONGSCROLL \(label) error " + line) }
        for line in run.hitchReport() { print("LONGSCROLL \(label) hitch " + line) }
    }
    @MainActor func testProbeGestureUpAndDown() async throws {
        let step = CGFloat(Double(testEnvironment("PI_LONG_STEP") ?? "") ?? 120)
        let chat = try await chat()
        report(chat, await chat.drive(points: step, seconds: 150) { chat.atFirstMessage }, "gesture up \(Int(step))")
        report(chat, await chat.drive(points: -step, seconds: 150) { chat.atLastMessage }, "gesture down \(Int(step))")
    }
    @MainActor func testProbeScrollerDragToTop() async throws {
        let chat = try await chat()
        report(chat, await chat.drive(points: 1, seconds: 60, input: .scroller) { chat.atFirstMessage }, "scroller top")
        report(chat, await chat.drive(points: -1, seconds: 60, input: .scroller) { chat.atLastMessage }, "scroller bottom")
    }
    @MainActor func testProbeWheelFling() async throws {
        let chat = try await chat()
        report(chat, await chat.drive(points: 400, seconds: 60, input: .wheel) { chat.atFirstMessage }, "wheel up 400")
    }
    @MainActor func testProbeHomeKey() async throws {
        let chat = try await chat()
        var presses = 0
        let began = Date()
        while !chat.atFirstMessage, Date().timeIntervalSince(began) < 60 {
            chat.scroll?.scroll(by: .top); presses += 1
            for _ in 0..<30 { chat.draw(); try await Task.sleep(for: .milliseconds(16)) }
        }
        print("LONGSCROLL home: reached=\(chat.atFirstMessage) presses \(presses) in \(Date().timeIntervalSince(began)) s; first \(chat.view.messages.first?.id ?? "-") y \(chat.clipY)")
    }
}

/// Opt-in (`PI_LONG_PROBE=1`): what building and measuring one forty-section
/// reply costs — the row a long chat measures when the reader reaches it.
final class LongReplyMeasureProbeTests: XCTestCase, SerialTestLane {
    override func setUpWithError() throws {
        try XCTSkipUnless(testEnvironment("PI_LONG_PROBE") == "1", "Set PI_LONG_PROBE=1 to measure long-chat scrolling")
    }
    @MainActor func testWhatMeasuringAFortySectionReplyCosts() throws {
        func code(_ lines: Int, _ seed: Int) -> String {
            (0..<lines).map { "    let value\($0) = compute(\(seed), \($0)) // step \($0) of the pass" }.joined(separator: "\n")
        }
        let text = (0..<40).map { section in
            "## Finding 20.\(section)\n\nThe parser in module 3 reads the token stream twice when **a nested block** closes early, so `parse(input:)` returns a shorter tree than the caller expects.\n\n- The first pass keeps the offsets.\n- The second pass loses them.\n\n```swift\n" + code(8 + (20 + section) % 22, 2000 + section) + "\n```\n"
        }.joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        window.contentView = host
        var times: [Double] = []
        for round in 0..<(Int(testEnvironment("PI_LONG_ROUNDS") ?? "") ?? 6) {
            let message = TranscriptMessage(id: "reply\(round)", role: "assistant", text: text)
            let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: TranscriptActions())
            host.addSubview(row)
            let start = ProcessInfo.processInfo.systemUptime
            let size = row.measure(width: 837)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if round == 0 { print(String(format: "LONGREPLY %d bytes, height %.0f", text.utf8.count, size.height)) }
            row.removeFromSuperview()
        }
        print("LONGREPLY measure ms: " + times.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}
