import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The pane is kept across chats, and so is the transcript's page. What the
/// pane shows from the first frame it is drawn for a chat is that chat's:
/// its rows and its live turn bar. The page was bound a turn of the run loop
/// after the pane, and for the frames in between the chat shown before stood
/// under the one just opened: its bar, whose room the conversation took back
/// a moment later, moving the opened chat's rows 116 pt; and its rows, which
/// moved as its bar went or its figures arrived (found by `SoakTests`).
final class TranscriptSwitchFirstFrameTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testAChatJustOpenedShowsItsOwnRowsAndBarFromTheFirstFrame() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // A chat whose run is under way, as the helper presents it: a task
        // still running, and the reply it is writing. And one that is idle.
        let running = TranscriptFrameBudgetTests.chat("bar-running", rows: 6), idle = TranscriptFrameBudgetTests.chat("bar-idle", rows: 6)
        var task = TaskPresentationRecord(rootID: "live-question", executionID: "live-execution", startedAt: 1_000)
        task.phase = "model"
        running.taskPresentation = TaskPresentationProjection(sessionID: running.id, epoch: "epoch", timeline: "root", sequence: 1, sourceRevision: "epoch:1", active: task, recent: [])
        running.messages += [TranscriptMessage(id: "live-question", role: "user", text: "A question still being answered", state: "complete", turn: "live-question", taskRootID: "live-question", taskExecutionID: "live-execution"),
                             TranscriptMessage(id: "live-answer", role: "assistant", text: "The answer so far", state: "streaming", turn: "live-question", taskRootID: "live-question", taskExecutionID: "live-execution")]
        running.state = "running"
        func pane(_ session: SessionDisplay) -> NativeTranscriptView { NativeTranscriptView(session: session, state: session.state, actions: TranscriptActions()) }
        let hosted = NSHostingView(rootView: pane(running))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func viewport() throws -> CGFloat { try XCTUnwrap(descendants(TranscriptNativeScrollView.self, in: hosted).first).frame.height }
        func page() throws -> TranscriptPage { try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page) }
        func rows() throws -> Set<String> {
            Set(try XCTUnwrap(descendants(TranscriptNativeScrollView.self, in: hosted).first?.documentView as? TranscriptNativeDocument).retainedRows.map(\.itemID))
        }
        for _ in 0..<40 { draw(); try await Task.sleep(for: .milliseconds(5)) }
        let full = hosted.frame.height
        XCTAssertLessThan(try viewport(), full - 40, "the running chat's live bar stands under its conversation")

        // The reader opens the idle chat. Nothing is awaited between drawing
        // the pane for it and measuring it: the page is still bound to the
        // running chat.
        let shown = try rows()
        XCTAssertTrue(shown.contains { $0.contains("live-") }, "the running chat's rows are on its page: \(shown.sorted())")
        hosted.rootView = pane(idle)
        draw()
        XCTAssertEqual(try page().sessionID, idle.id, "the page is the opened chat's in the frame the pane is drawn for it")
        XCTAssertFalse(try rows().contains { $0.contains("live-") }, "the running chat's rows are not under the chat just opened")
        XCTAssertEqual(try viewport(), full, accuracy: 0.5, "the running chat's bar does not stand under the chat just opened")
        for _ in 0..<40 { draw(); try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try viewport(), full, accuracy: 0.5, "nor does it once the page is bound to the chat")

        // And back: the running chat's own bar is there from its first frame.
        hosted.rootView = pane(running)
        draw()
        XCTAssertEqual(try page().sessionID, running.id)
        XCTAssertLessThan(try viewport(), full - 40, "the running chat's bar is under it from the first frame")
    }
}
