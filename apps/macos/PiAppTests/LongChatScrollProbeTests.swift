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
