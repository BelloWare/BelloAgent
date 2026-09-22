import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The working indicator: shimmering words and a stable duration slot.
final class LiveWorkingIndicatorTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// Renders a view in a real key window and returns what it draws, so the
    /// question "does it move" is answered by pixels rather than by state.
    @MainActor private func frames<Content: View>(of content: Content, size: NSSize, count: Int,
                                                  apart interval: Duration) async throws -> [Data] {
        let hosted = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        var result: [Data] = []
        try await Task.sleep(for: .milliseconds(120))
        for _ in 0..<count {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            result.append(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            try await Task.sleep(for: interval)
        }
        return result
    }

    /// The words move. That is the whole indicator: nothing spins, nothing
    /// claims to know how far the run has got.
    @MainActor func testTheWorkingIndicatorShimmers() async throws {
        let shots = try await frames(of: PiShimmerText(text: "Generating response…"),
                                     size: NSSize(width: 180, height: 22), count: 8, apart: .milliseconds(120))
        XCTAssertGreaterThan(Set(shots).count, 1, "the working indicator stayed still")
    }

    /// Reduce Motion leaves the words where they are, and still says them.
    @MainActor func testReduceMotionLeavesTheWordsStill() async throws {
        let shots = try await frames(of: PiShimmerText(text: "Generating response…").environment(\.piReduceMotion, true),
                                     size: NSSize(width: 180, height: 22), count: 6, apart: .milliseconds(140))
        XCTAssertEqual(Set(shots).count, 1, "the working indicator moved although motion was reduced")
    }

    /// Duration remains visible from the start, without inserting another row.
    @MainActor func testTheElapsedClockUpdatesFromTheStart() async throws {
        func turn(elapsedMs: Double?) -> TurnSummary {
            var value = TaskTranscriptPlan.summary([], task: nil)
            value.live = true; value.phase = "model"
            if let elapsedMs {
                value.startedAt = Date().timeIntervalSince1970 * 1000 - elapsedMs
                value.elapsedMs = elapsedMs
            }
            return value
        }
        func drawn(elapsedMs: Double) throws -> Data {
            let hosted = NSHostingView(rootView: LiveTurnBar(turn: turn(elapsedMs: elapsedMs), state: "running")
                .frame(width: 420).background(Color.white)
                .environment(\.piReduceMotion, true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        XCTAssertNotEqual(try drawn(elapsedMs: 3_000), try drawn(elapsedMs: 62_000),
                          "the reported elapsed duration must update")
        XCTAssertNotEqual(try drawn(elapsedMs: 3_000), try drawn(elapsedMs: 9_000),
                          "duration should be visible even in a short run")
    }

    /// The composer is never taken away from the reader while a run is going:
    /// they can keep typing, and Return and ⌘Return deliver the two different
    /// things — a follow-up behind the run, or a steer into it.
    @MainActor func testTheComposerStaysOpenDuringARunAndOffersBothDeliveries() async throws {
        let pane = try ConversationPaneTests.Pane(messages: [TranscriptMessage(id: "u", role: "user", text: "Start")])
        defer { pane.close() }
        await pane.settle(6)
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(editor.isEditable, "the composer must take typing before a run starts")
        pane.session.state = "running"
        await pane.settle(8)
        let running = try XCTUnwrap(pane.editor)
        XCTAssertTrue(running.isEditable, "the composer must stay open while a run is going")
        pane.window.makeFirstResponder(running)
        XCTAssertTrue(pane.window.firstResponder === running, "the reader must be able to put the caret in it during a run")
        // The two deliveries are offered by name; which key does which is
        // pinned by `ComposerSubmissionTests`.
        XCTAssertEqual(ComposerSubmissionIntent.hint(running: true), "↩ Queue · ⌘↩ Steer · ⇧↩ New line")
        XCTAssertEqual(ComposerSubmissionIntent.hint(running: false), "↩ Send · ⌘↩ Send · ⇧↩ New line")
        pane.session.state = "idle"
        await pane.settle(4)
    }
}
