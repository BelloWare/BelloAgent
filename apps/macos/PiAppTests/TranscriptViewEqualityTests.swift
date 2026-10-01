import XCTest
import SwiftUI
@testable import PiApp

/// SwiftUI skips an `Equatable` view's body while its `==` says nothing
/// changed, so a view whose `==` leaves out an input it draws shows stale
/// content, with no error anywhere. The transcript's views write their `==`
/// by hand. These tests list each one's stored properties, so a property
/// added later fails here as a reminder to decide whether `==` compares it.
final class TranscriptViewEqualityTests: XCTestCase {
    @MainActor private func properties<V>(_ value: V) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }
    private func changed(_ view: String, _ file: String) -> String {
        "\(view)'s stored properties changed. Its `==` (\(file)) must compare a new input that changes what it draws; then update this list."
    }

    @MainActor func testTheTranscriptViewComparesWhatItDraws() {
        let view = NativeTranscriptView(session: SessionDisplay(id: "equality"), actions: TranscriptActions())
        XCTAssertEqual(properties(view), ["_session", "state", "actions", "onAnchorChanged", "onReadReply", "onLoadEarlier",
                                          "onLoadNewer", "onLatest", "onViewportReady", "_page", "_reduceMotion",
                                          "_earlierSlow", "_newerSlow"],
                       changed("NativeTranscriptView", "NativeTranscriptView.swift"))
    }

    @MainActor func testTheRowViewsCompareWhatTheyDraw() throws {
        let question = TranscriptMessage(id: "u1", role: "user", text: "Question", turn: "u1")
        let answer = TranscriptMessage(id: "a1", role: "assistant", text: "Answer", turn: "u1")
        XCTAssertEqual(properties(MessageRowView(message: question, actions: TranscriptActions())),
                       ["message", "actions", "inlineAccounting", "disclosure", "toggle", "switchesSource", "_hovering", "_forks"],
                       changed("MessageRowView", "TranscriptRows.swift"))
        let block = try XCTUnwrap(TranscriptActivity.blocks(of: [question, answer]).lazy.compactMap { item -> TranscriptBlock? in
            if case .block(let block) = item { return block }
            return nil
        }.first)
        XCTAssertEqual(properties(BlockRowView(block: block, actions: TranscriptActions())),
                       ["block", "actions", "fresh", "now", "disclosure", "toggle", "workListHeight", "workListMeasured",
                        "foldInMotion", "_hovering", "_reduceMotion", "_forks"],
                       changed("BlockRowView", "TranscriptRows.swift"))
        XCTAssertEqual(properties(MarkdownBodyView(source: "Text")),
                       ["source", "style", "capsWidth", "streaming", "copyTargets", "sourceIdentity", "parked", "resolveFile", "openFile", "_hovering"],
                       changed("MarkdownBodyView", "TranscriptRows.swift"))
        XCTAssertEqual(properties(CodeBlockView(language: "swift", code: "let a = 1")),
                       ["language", "code", "size", "_hovering", "_section", "streaming", "_usesNativeText"],
                       changed("CodeBlockView", "TranscriptRows.swift"))
        let tool = ToolView(id: "t1", name: "bash", state: "done", input: "{}", output: "", durationMs: nil, truncated: false)
        // `openFile`, like `toggle`, is an action forwarded to the pane's; whether
        // a path is a link is the environment's `_opensFiles`, which SwiftUI
        // follows apart from `==`.
        XCTAssertEqual(properties(ActionRowView(tool: tool)), ["tool", "open", "fetched", "toggle", "openFile", "_opensFiles"],
                       changed("ActionRowView", "TranscriptRows.swift"))
        XCTAssertEqual(properties(ActivityGroupView(tools: [tool])), ["tools", "openTools", "fetched", "toggle", "openFile"],
                       changed("ActivityGroupView", "TranscriptRows.swift"))
    }
}
