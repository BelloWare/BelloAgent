import AppKit
import XCTest
@testable import PiApp

final class SubagentMarkdownTests: XCTestCase {
    static let rich = """
    # Parser findings

    The **token boundary** preserves *emphasis* and `inline code`.

    - Keep every input byte.
    - Check the [reference](https://example.test/reference).

    > A quoted observation.

    ```swift
    let token = Parser.read("input")
    // Preserve the source
    ```

    | Check | Result |
    | --- | --- |
    | Unicode | Passed |
    | Empty input | Passed |

    Final **searchable conclusion**.
    """
    static func tool(task: String = rich, result: String = rich) throws -> ToolView {
        var tool = SubagentTranscriptTests.tool
        tool.input = String(decoding: try JSONEncoder().encode(["task": task]), as: UTF8.self)
        tool.output = String(decoding: try JSONEncoder().encode(["status": "completed", "text": result]), as: UTF8.self)
        return tool
    }
    @MainActor static func card(task: String = rich, result: String = rich) throws -> TranscriptNativeActionRow {
        let row = TranscriptNativeActionRow()
        row.update(tool: try tool(task: task, result: result), open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        row.frame = CGRect(x: 0, y: 0, width: 620, height: row.height(width: 620)); row.layoutSubtreeIfNeeded()
        return row
    }
    @MainActor static func assistant(_ text: String) -> NativeMarkdownContainer {
        let source = TranscriptMessage(id: "assistant", role: "assistant", text: text)
        let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(source), fresh: false,
            actions: .init(), width: 620, environment: .init(), disclosure: .init(), toggle: { _ in }))
        return ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first!
    }
    @MainActor func testCardTaskAndResultRenderExactlyLikeAssistantMarkdown() throws {
        let row = try Self.card(), expected = Self.assistant(Self.rich)
        let surfaces = ConversationPaneTests.views(NativeMarkdownContainer.self, in: row)
        XCTAssertEqual(surfaces.count, 2, "Both Task and Result use the assistant surface")
        for surface in surfaces {
            XCTAssertEqual(surface.textView.string, expected.textView.string)
            XCTAssertEqual(surface.retainedBlockCount, expected.retainedBlockCount)
            for key in [NSAttributedString.Key.font, .foregroundColor, .link] {
                for position in 0..<surface.textLength {
                    let a = surface.textView.textStorage?.attribute(key, at: position, effectiveRange: nil) as? NSObject
                    let b = expected.textView.textStorage?.attribute(key, at: position, effectiveRange: nil) as? NSObject
                    XCTAssertEqual(a, b, "Assistant attribute \(key) at \(position)")
                }
            }
        }
    }
    @MainActor func testTypedResultsReportsAndDelegatedTasksUseTheSameRenderer() throws {
        for (author, kind) in [("subagent", "result"), ("subagent", "note"), ("subagent", "blocker"), ("subagent", "question"), ("parent", "task")] {
            var message = TranscriptMessage(id: "delivery", role: "user", text: Self.rich, kind: "agent_message")
            message.nativeAgentDelivery = .object(["author": .string(author), "childId": .string("chat-child"), "turn": .number(1),
                "events": .array([.object(["kind": .string(kind), "text": .string(Self.rich)])])])
            let row = TranscriptNativeAgentRow(inputs: .init(item: .message(message), fresh: false, actions: .init(), width: 620,
                environment: .init(), disclosure: .init(), toggle: { _ in }))
            let surfaces = ConversationPaneTests.views(NativeMarkdownContainer.self, in: row)
            XCTAssertEqual(surfaces.count, 1, kind)
            XCTAssertEqual(surfaces.first?.textView.string, Self.assistant(Self.rich).textView.string, kind)
        }
    }
    @MainActor func testLongResultFoldsExpandsAndCopiesOriginalMarkdown() async throws {
        let source = Self.rich + "\n\n" + String(repeating: "Another **important** observation.\n\n", count: 40)
        let row = try Self.card(task: "Short task", result: source)
        let before = row.height(width: 620)
        let more = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "agent-markdown-toggle-result" })
        XCTAssertEqual(more.title, "Show more")
        more.onPress?()
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).last)
        try await eventually("Expanded result") { body.isComplete }
        let after = row.height(width: 620)
        XCTAssertGreaterThan(after, before + 200)
        XCTAssertEqual(more.title, "Show less")
        let copy = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "agent-markdown-copy-result" })
        copy.onPress?(); XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).last)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("subagent-markdown-" + UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        surface.textView.setSelectedRange(NSRange(location: 0, length: surface.textLength))
        XCTAssertTrue(surface.textView.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), source)
        more.onPress?(); XCTAssertEqual(row.height(width: 620), before)
    }
    @MainActor func testSelectionCopiesTheSelectedMarkdownSpelling() throws {
        let source = "One **bold** word, `code`, and [reference](https://example.test). Same **bold** word."
        let row = try Self.card(task: "Task", result: source)
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).last)
        for (text, copied) in [("bold", "**bold**"), ("code", "`code`"), ("reference", "[reference](https://example.test)")] {
            let range = (surface.textView.string as NSString).range(of: text)
            XCTAssertEqual(surface.textView.copyText([range]), copied)
        }
        let last = (surface.textView.string as NSString).range(of: "bold", options: .backwards)
        XCTAssertEqual(surface.textView.copyText([last]), "**bold**")
    }
    @MainActor func testReportedTruncationNotesDoNotBecomeCopiedMarkdown() throws {
        var tool = try Self.tool(task: "Task", result: Self.rich); tool.truncated = true
        let row = TranscriptNativeActionRow()
        row.update(tool: tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        let copy = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "agent-markdown-copy-result" })
        copy.onPress?(); XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.rich)
    }
    @MainActor func testPartialSelectionsKeepEntitiesEscapesAndImageSource() throws {
        for (source, needle, expected) in [
            ("One &amp; word.", "word", "word"), ("One &amp; word.", "&", "&amp;"),
            (#"One \*literal\* word."#, "literal", "literal"), (#"One \*literal\* word."#, "*literal*", #"\*literal\*"#),
            ("One &#x1F600; word.", "😀", "&#x1F600;"),
            ("![private](https://example.test/pic)", "private", "![private](https://example.test/pic)"),
            (#"Before [reference](https://example.test/a\)b). After."#, "reference", #"[reference](https://example.test/a\)b)"#),
            (#"Before [reference](https://example.test "A ) title"). After."#, "reference", #"[reference](https://example.test "A ) title")"#)
        ] {
            let row = try Self.card(task: "Task", result: source)
            let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).last)
            let range = (surface.textView.string as NSString).range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertEqual(surface.textView.copyText([range]), expected)
        }
    }
    @MainActor func testFindExpandsTheResultAndKeepsItsRenderedMatchOnScreen() async throws {
        let source = Self.rich + "\n\n" + String(repeating: "A **retained** observation.\n\n", count: 120) + "Last **unique** result."
        let session = SessionDisplay(id: "agent-find")
        var reply = TranscriptMessage(id: "reply", role: "assistant", text: "Done.", turn: "question")
        reply.tools = [try Self.tool(task: "Short task", result: source)]
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Review"), reply]
        let stage = TranscriptStressTestCase.Stage(session, width: 620); defer { stage.close() }
        await stage.settleUntilExact()
        let work = try XCTUnwrap(stage.workRow)
        work.toggleDisclosure(try XCTUnwrap(stage.workPart(work))); stage.draw()
        work.toggleDisclosure(.tool(ToolOccurrence.key("reply", "call"))); stage.draw()
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: stage.document).first { $0.accessibilityIdentifier() == "agent-markdown-result" })
        XCTAssertFalse(body.expanded)
        stage.document.highlights = .init(query: "Last unique result", focus: .init(messageID: "reply", needle: "Last unique result", occurrence: 0, serial: 1, fromFind: true, scopeCall: "call"))
        try await eventually("The Markdown result's Find match") {
            stage.draw(); stage.document.revealFocusIfPending()
            return body.expanded && stage.document.focusText != nil && !stage.document.focusPending
        }
        let text = try XCTUnwrap(stage.document.focusText), range = stage.document.focusRange
        await stage.settle()
        XCTAssertEqual((text.string as NSString).substring(with: range), "Last unique result")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        var glyph = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        glyph.origin.x += text.textContainerOrigin.x; glyph.origin.y += text.textContainerOrigin.y
        let rect = text.convert(glyph, to: stage.scroll.contentView)
        XCTAssertTrue(stage.scroll.contentView.bounds.intersects(rect), "clip=\(stage.scroll.contentView.bounds) match=\(rect) text=\(text.frame) body=\(body.frame)")
        work.contentSizeChanged()
        XCTAssertNil(stage.document.resolveFocus()?.target, "A pending native height validation must defer the Find destination")
    }
    @MainActor func testFindUsesRenderedWordsAndUntrustedMarkdownKeepsAssistantRules() throws {
        let source = "A **searchable** conclusion.\n\n[Unsafe](javascript:alert(1)) ![private](https://example.test/image.png)\n\n<b>Raw HTML</b>"
        let row = try Self.card(task: "Task", result: source)
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).last)
        XCTAssertEqual(surface.textView.string, Self.assistant(source).textView.string)
        XCTAssertEqual(TranscriptNativeDocument.ranges(of: "searchable conclusion", in: surface.textView.string as NSString).count, 1)
        XCTAssertTrue(surface.textView.string.contains("Image not loaded"))
        surface.textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: surface.textLength)) { value, _, _ in
            XCTAssertNil(value, "Unsafe links never become actions")
        }
    }
    @MainActor func testDelegatedTaskHeaderUsesMarkdownWithoutChangingTheSavedRow() throws {
        let session = SessionDisplay(id: "child")
        session.isManagedSubagent = true; session.delegatedTask = Self.rich; session.subagentNumbers = ["child": 2]
        let message = try XCTUnwrap(session.presentedMessages.first)
        XCTAssertEqual(message.text, Self.rich)
        XCTAssertTrue(session.messages.isEmpty)
        let row = TranscriptNativeAgentRow(inputs: .init(item: .message(message), fresh: false, actions: .init(), width: 620,
            environment: .init(), disclosure: .init(), toggle: { _ in }))
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).first)
        XCTAssertEqual(body.markdown.textView.string, Self.assistant(Self.rich).textView.string)
        XCTAssertTrue(body.copy.accessibilityLabel()?.contains("sub-agent 2") == true)
    }
    @MainActor func testReplacedAndFoldedPresentationsRejectPendingMarkdownWork() async throws {
        let body = TranscriptAgentMarkdown(label: "Result", identity: "test")
        let large = "# Superseded source\n\n" + String(repeating: "- A **long** observation.\n", count: 800)
        body.update(large, environment: .init())
        XCTAssertFalse(body.prepared)
        body.setExpanded(true)
        body.update("Replacement **reply**.", environment: .init())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(body.expanded); XCTAssertEqual(body.markdown.textView.string, "Replacement reply.")
        body.update(large, environment: .init())
        try await eventually("Prepared cached large source") { body.prepared }
        body.setExpanded(true)
        try await eventually("First expansion batch") { body.markdown.textLength > 1_200 }
        body.setExpanded(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(body.expanded); XCTAssertFalse(body.isComplete)
        XCTAssertLessThan(body.markdown.textLength, 1_400)
        let range = (body.markdown.textView.string as NSString).range(of: "observation")
        body.markdown.textView.setSelectedRange(range)
        body.update(large, environment: .init())
        XCTAssertEqual(body.markdown.textView.selectedRange(), range, "A repeated paint keeps the existing native selection")
    }
    @MainActor func testExpandingAndFoldingKeepTheResultAtTheReadingPosition() async throws {
        let source = Self.rich + "\n\n" + String(repeating: "A **retained** observation.\n\n", count: 90)
        let session = SessionDisplay(id: "agent-reading-position")
        var reply = TranscriptMessage(id: "reply", role: "assistant", text: "Done.", turn: "question")
        reply.tools = [try Self.tool(task: "Short task", result: source)]
        let history = TranscriptStressTestCase.history(turns: 60)
        session.messages = Array(history.prefix(60)) + [.init(id: "question", role: "user", text: "Review"), reply] + Array(history.suffix(60))
        let stage = TranscriptStressTestCase.Stage(session, width: 620); defer { stage.close() }
        await stage.settleUntilExact()
        let work = try XCTUnwrap(stage.workRow)
        stage.readerScroll(to: work.frame.minY)
        work.toggleDisclosure(try XCTUnwrap(stage.workPart(work))); stage.draw()
        work.toggleDisclosure(.tool(ToolOccurrence.key("reply", "call"))); stage.draw()
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: work).last)
        stage.readerScroll(to: body.convert(body.bounds, to: stage.document).minY - 50)
        let before = body.convert(body.bounds, to: stage.document).minY - stage.scrollY
        body.setExpanded(true)
        try await eventually("Expanded text at the reading position") { stage.draw(); return body.isComplete }
        await stage.settle()
        XCTAssertEqual(body.convert(body.bounds, to: stage.document).minY - stage.scrollY, before, accuracy: 1)
        body.setExpanded(false); await stage.settle()
        XCTAssertEqual(body.convert(body.bounds, to: stage.document).minY - stage.scrollY, before, accuracy: 1)
    }

}
