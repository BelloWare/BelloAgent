import XCTest
@testable import PiApp

/// A reply that is still arriving parses in settled parts plus a live tail;
/// the parts must read exactly as the whole would.
final class MarkdownStreamingTests: XCTestCase {
    private let reply = """
    Intro paragraph with **bold**, `code` and a [link](https://example.com).

    ```swift
    let a = 1

    let b = 2
    ```

    - one

    - two
      continued

    1. first

    2. second

    > quoted
    > more

    | a | b |
    |---|---|
    | 1 | 2 |

    ~~~
    tilde fence

    ```
    still in the tilde fence
    ~~~

    ## Heading

    Last paragraph.
    """

    func testCutsFallOnlyWhereBothSidesParseAlike() {
        let cuts = TranscriptMarkdown.settledCuts(in: reply).map { String(reply[$0...].prefix(12)) }
        XCTAssertEqual(cuts, ["```swift\nlet", "> quoted\n> m", "| a | b |\n|-", "~~~\ntilde fe", "## Heading\n\n", "Last paragra"],
                       "no cut inside a fence, between list items or after a mid-fence blank line")
        XCTAssertEqual(TranscriptMarkdown.streamingBlocks(reply), TranscriptMarkdown.parse(reply))
        XCTAssertTrue(TranscriptMarkdown.settledCuts(in: "- a\n\n- b\n\n* c\n\n1. d\n\n2) e").isEmpty, "a loose list stays whole")
        XCTAssertTrue(TranscriptMarkdown.settledCuts(in: "```\ncode\n\nmore\n").isEmpty, "an open fence is never cut")
        XCTAssertEqual(TranscriptMarkdown.settledCuts(in: "a\n\n    indented code\n\nb").count, 1, "an indented line is not a cut; the margin line is")
    }

    func testEveryPartialReplyReadsAsItsWholeParse() {
        let bytes = Array(reply.utf8)
        var offset = 1
        var checked = 0
        while offset <= bytes.count {
            if let partial = String(bytes: bytes[0..<offset], encoding: .utf8) {
                XCTAssertEqual(TranscriptMarkdown.streamingBlocks(partial), TranscriptMarkdown.parse(partial), "at \(offset) bytes")
                checked += 1
            }
            offset += 7
        }
        XCTAssertGreaterThan(checked, 30)
    }
}
