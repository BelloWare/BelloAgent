import AppKit
import XCTest
@testable import PiApp

final class ReasoningLayoutTests: XCTestCase {
    @MainActor func testOpenedReasoningIsLaidOutOnceAtItsIndentedWidth() throws {
        for width: CGFloat in [380, 620] {
            for streaming in [true, false] {
                let text = String(repeating: "A **reasoning** paragraph that wraps inside the opened work row. ", count: 50)
                func inputs(_ text: String, open: Bool = true) -> TranscriptRowInputs {
                    let segment = TranscriptNativeRowParityTests.segment("thought", "reasoningText", text, state: streaming ? "streaming" : "complete")
                    let item = TranscriptNativeRowParityTests.partItem(segment, streaming: streaming)
                    return TranscriptRowInputs(item: item, fresh: false, actions: TranscriptActions(), width: width,
                                               environment: TranscriptRowEnvironment(), disclosure: TranscriptRowDisclosure(work: open))
                }
                let row = TranscriptNativePartRow(inputs: inputs(text))
                let inner = width - 4 - TranscriptRowChrome.indent
                func surface() throws -> NativeMarkdownContainer {
                    try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
                }
                let body = try surface()
                XCTAssertEqual(body.textLayouts, streaming ? 1 : 0, "only a streaming caret needs layout before measurement")
                if streaming { XCTAssertEqual(body.textLayoutWidth, inner, "the caret uses the indented width immediately") }
                func place() {
                    row.frame.size.width = width
                    row.frame.size.height = row.confirmHeight()
                    row.layoutSubtreeIfNeeded()
                }
                place()
                XCTAssertEqual(body.textLayouts, 1, "one full layout, including the caret and row measurement")
                XCTAssertEqual(body.textLayoutWidth, inner)
                let before = body.textLayouts
                row.apply(inputs(text + " The next reasoning words have arrived.")); place()
                XCTAssertTrue(try surface() === body)
                XCTAssertEqual(body.textLayouts, before + 1, "an append lays out only at the same width")
                XCTAssertEqual(body.textLayoutWidth, inner)
                row.apply(inputs(text, open: false)); place()
                XCTAssertTrue(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).isEmpty)
                row.apply(inputs(text)); place()
                XCTAssertEqual(try surface().textLayouts, 1, "reopening prepares the new surface too")
                XCTAssertEqual(try surface().textLayoutWidth, inner)
            }
        }
    }
}
