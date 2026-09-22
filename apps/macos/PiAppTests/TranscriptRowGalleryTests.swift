import XCTest
import SwiftUI
@testable import PiApp

/// Captures of the transcript's rows, in both appearances, for looking at.
///
/// These render the real document in a window — the same `TranscriptPage` and
/// `TranscriptNativeDocument` the app draws through — rather than driving the
/// whole app through the synthetic gateway, because the states worth looking
/// at (a thought still being written, a call the reader stopped, a finished
/// turn folded) are ones the fixture gateway cannot produce.
///
/// Set `PI_APP_UI_SCREENSHOT_ROOT` (and `TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT`)
/// to a fresh directory; the PNGs land in its `screenshots` folder.
final class TranscriptRowGalleryTests: XCTestCase {
    @MainActor func testCaptureTranscriptRows() throws {
        guard let path = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else {
            throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT to render the transcript row gallery.")
        }
        let gallery = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        let previous = TranscriptDisplay.mode
        defer { TranscriptDisplay.use(previous) }

        TranscriptDisplay.use(.normal)
        try capture("20-work-rows", messages: rows(), into: gallery)
        try capture("20b-work-rows-open", messages: rows(), into: gallery) { session, items in
            for case .block(let block) in items where block.part != nil {
                session.disclosure.setOpen(true, .work(block.key))
                if let card = block.message?.tools?.first {
                    session.disclosure.setOpen(true, .tool(ToolOccurrence.key(block.message?.id ?? "", card.id)))
                }
            }
        }
        try capture("22-stopped-reply", messages: stopped(), into: gallery)

        TranscriptDisplay.use(.compact)
        try capture("21-turn-fold", messages: rows(), into: gallery)
        try capture("21b-turn-fold-open", messages: rows(), into: gallery) { session, items in
            for case .block(let block) in items where block.foldControl != nil {
                session.disclosure.setOpen(true, .turnFold(block.foldControl!))
            }
        }
    }

    // MARK: The conversations worth looking at

    /// A real edit request, so the row opens the diff card rather than the
    /// IN/OUT card: the card is chosen by what the call actually asked for.
    static let editArguments: String = {
        let before = (1...20).map { "    let attempt\($0) = retry(after: .seconds(\($0)), max: 3)" }.joined(separator: "\n")
        let after = (1...20).map { "    let attempt\($0) = retry(after: .seconds(\($0) * 2), max: 5)" }.joined(separator: "\n")
        let payload: [String: String] = ["path": "PaymentClient.swift", "oldText": before, "newText": after]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }()

    private func part(_ timeline: inout ResponseTimeline, _ ordinal: Int, _ kind: String, _ text: String,
                      call: String? = nil, name: String? = nil, state: String = "complete") {
        timeline.consume(ResponsePartEvent(attemptID: "attempt", ordinal: ordinal, itemID: "item-\(ordinal)",
                                           outputIndex: ordinal, partIndex: 0, kind: kind, update: "replace",
                                           text: text, callID: call, name: name))
    }
    /// One turn: a thought, a read, a failed command, a call the reader
    /// stopped, an edit with its totals, and the answer.
    private func rows() -> [TranscriptMessage] {
        var timeline = ResponseTimeline()
        part(&timeline, 0, "reasoningText", "**Plan**\nRead the retry loop, then check what the budget does on the third attempt.")
        part(&timeline, 1, "toolArguments", "{\"path\":\"apps/macos/PiApp/Networking/PaymentClient.swift\"}", call: "c1", name: "read")
        part(&timeline, 2, "toolArguments", "{\"command\":\"swift test --filter Retry\"}", call: "c2", name: "bash")
        part(&timeline, 3, "toolArguments", "{\"command\":\"swift build -c release\"}", call: "c3", name: "bash")
        part(&timeline, 4, "toolArguments", Self.editArguments, call: "c4", name: "edit")
        part(&timeline, 5, "text", "The loop retries three times with a fixed delay. I widened the budget to five and made the delay grow.")
        timeline.finish("completed")
        let file = (1...24).map { "    let attempt\($0) = retry(after: .seconds(\($0)))" }.joined(separator: "\n")
        var reply = TranscriptMessage(id: "a1", role: "assistant",
                                      text: "The loop retries three times with a fixed delay. I widened the budget to five and made the delay grow.",
                                      thinking: "**Plan**\nRead the retry loop, then check what the budget does on the third attempt.",
                                      tools: [
                                        ToolView(id: "c1", name: "read", state: "completed",
                                                 input: "{\"path\":\"apps/macos/PiApp/Networking/PaymentClient.swift\"}",
                                                 output: file, durationMs: 41, truncated: false,
                                                 path: "apps/macos/PiApp/Networking/PaymentClient.swift"),
                                        ToolView(id: "c2", name: "bash", state: "failed",
                                                 input: "{\"command\":\"swift test --filter Retry\"}",
                                                 output: "error: no such module 'Retry'\n  at Package.swift:12", durationMs: 1_820, truncated: false),
                                        ToolView(id: "c3", name: "bash", state: "cancelled",
                                                 input: "{\"command\":\"swift build -c release\"}",
                                                 output: "", durationMs: 9_400, truncated: false),
                                        ToolView(id: "c4", name: "edit", state: "completed",
                                                 input: Self.editArguments,
                                                 output: "ok", durationMs: 12, truncated: false,
                                                 path: "PaymentClient.swift", added: 130, removed: 130)],
                                      state: "complete", at: 2_000, turn: "u1")
        reply.modelMs = 4_100
        reply.responseTimeline = timeline
        return [TranscriptMessage(id: "u1", role: "user", text: "Why does the payment retry give up so early?", at: 1_000, turn: "u1"), reply]
    }
    /// What Stop leaves behind: the partial answer, and the chip that says why
    /// it ends where it does.
    private func stopped() -> [TranscriptMessage] {
        var timeline = ResponseTimeline()
        part(&timeline, 0, "reasoningText", "Working through the budget one attempt at a time.")
        part(&timeline, 1, "toolArguments", "{\"command\":\"swift build -c release\"}", call: "s1", name: "bash")
        part(&timeline, 2, "text", "The first attempt waits one second, the second waits two, and then")
        timeline.finish("interrupted")
        var reply = TranscriptMessage(id: "a1", role: "assistant",
                                      text: "The first attempt waits one second, the second waits two, and then",
                                      tools: [ToolView(id: "s1", name: "bash", state: "cancelled",
                                                       input: "{\"command\":\"swift build -c release\"}",
                                                       output: "", durationMs: 6_200, truncated: false)],
                                      state: "complete", at: 2_000, turn: "u1")
        reply.stopReason = "interrupted"
        reply.responseTimeline = timeline
        return [TranscriptMessage(id: "u1", role: "user", text: "Walk me through the retry budget.", at: 1_000, turn: "u1"), reply]
    }

    // MARK: Rendering

    @MainActor private func capture(_ name: String, messages: [TranscriptMessage], into gallery: URL,
                                    open: ((SessionDisplay, [TranscriptItem]) -> Void)? = nil) throws {
        for (appearance, style) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let session = SessionDisplay(id: "gallery")
            session.messages = messages
            let page = TranscriptPage()
            page.state = "idle"
            page.bind(session)
            open?(session, page.snapshot?.items ?? [])
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: 880, height: 620))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            let document = TranscriptNativeDocument(page: page)
            scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: style)
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            var values = EnvironmentValues(); values.colorScheme = style == .darkAqua ? .dark : .light
            document.update(snapshot: page.snapshot, actions: TranscriptActions(),
                            environment: TranscriptRowEnvironment(values), disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width)
            document.finishDisclosureMotion()
            for row in document.retainedRows { row.prepareToDraw(); row.layoutForViewport() }
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            let representation = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: gallery.appendingPathComponent("\(name)-\(appearance).png"), options: .atomic)
        }
    }
}
