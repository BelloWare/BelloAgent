import XCTest
import SwiftUI
@testable import PiApp

final class TranscriptPerformanceRegressionTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor private func settle(_ hosted: NSView, window: NSWindow, until ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The transcript's exact row geometry did not settle")
    }

    private func requireInteractivePointerTests() throws {
        guard testEnvironment("PI_APP_INTERACTIVE_POINTER_TESTS") == "1" else {
            throw XCTSkip("Requires an interactive desktop with pointer delivery; set PI_APP_INTERACTIVE_POINTER_TESTS=1 to verify native disclosure/retry controls. The remote XCTest desktop cannot activate even a plain SwiftUI Button.")
        }
    }

    /// Dispatch through the real AppKit hit-test/event path. SwiftUI does not
    /// publish its accessibility children inside this in-process XCTest host.
    @MainActor private func click(_ point: NSPoint, in view: NSView, window: NSWindow) async throws {
        let location = view.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 2, clickCount: 1, pressure: 0))
        // Native buttons may synchronously track until the matching mouse-up.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        // SwiftUI can return without entering AppKit's synchronous tracking
        // loop; XCTest then needs to deliver the queued release explicitly.
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
        try await Task.sleep(for: .milliseconds(20))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    @MainActor func testMeasuredRowReusesExactHeightAndInvalidatesForWidthAndContent() {
        var message = TranscriptMessage(id: "measured", role: "assistant", text: String(repeating: "A selectable paragraph with a useful amount of text. ", count: 20))
        let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: TranscriptActions())
        let original = row.measure(width: 600)
        XCTAssertGreaterThan(original.height, 50, "The cache must contain real text layout, never a placeholder height")
        let before = row.measurementCount
        XCTAssertEqual(row.measure(width: 0), .zero, "The layout's minimum-width probe must remain shrinkable")
        for _ in 0..<20 { XCTAssertEqual(row.measure(width: 600), original) }
        XCTAssertEqual(row.measurementCount, before, "A parent's layout must not remeasure unchanged selectable text")
        let narrow = row.measure(width: 300)
        XCTAssertGreaterThan(narrow.height, original.height)
        XCTAssertEqual(narrow.width, 300)
        let afterBothWidths = row.measurementCount
        for _ in 0..<20 {
            XCTAssertEqual(row.measure(width: 600), original)
            XCTAssertEqual(row.measure(width: 300), narrow)
        }
        XCTAssertEqual(row.measurementCount, afterBothWidths, "Alternating ideal and actual widths must reuse both exact layouts")
        // Finish on a cached proposal that differs from the wrapping width in
        // the host. The actual row bounds still determine the text we draw.
        XCTAssertEqual(row.measure(width: 600), original)
        row.frame = NSRect(origin: .zero, size: original)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.subviews.first?.frame.size, original)
        XCTAssertEqual(row.subviews.first?.fittingSize.height ?? 0, original.height, accuracy: 1,
                       "A speculative size must never leave native text wrapped for a different viewport")
        message.text += String(repeating: "\n\nAnother complete paragraph.", count: 12)
        row.update(item: .message(message), fresh: false, actions: TranscriptActions())
        XCTAssertGreaterThan(row.measure(width: 300).height, narrow.height)
    }

    @MainActor func testStreamingTailKeepsSettledNativeTextSelectionAndCachedLayout() async throws {
        let session = SessionDisplay(id: "isolated-native-rows")
        let source = "Stable selectable prose.\n\n- First point\n- Second point\n\n```swift\nlet answer = 42\n```"
        session.messages = (0..<30).map { index in
            TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", text: source + "\n\nRow \(index).", turn: "m\(index - index % 2)")
        }
        session.messages.append(TranscriptMessage(id: "latest-question", role: "user", text: "Keep the earlier selection", turn: "latest-question"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, state: "running", actions: TranscriptActions()))
        window.contentView = hosted; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(hosted, window: window) {
            self.descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page?.rowFrame(of: "latest-question") != nil
        }
        // Flush the first measurement's deferred intrinsic-size notifications.
        try await Task.sleep(for: .milliseconds(100))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let page = try XCTUnwrap(marker.page), scroll = try XCTUnwrap(marker.enclosingScrollView)
        let targetFrame = try XCTUnwrap(page.rowFrame(of: "block:m1"))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetFrame.minY))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let row = try XCTUnwrap(descendants(TranscriptRowContainer.self, in: hosted).first { $0.itemID == "block:m1" })
        // The reply's prose is one TextKit text, selectable across its blocks.
        let editor = try XCTUnwrap(descendants(MarkdownTextView.self, in: row).first { $0.string.hasPrefix("Stable selectable prose.") })
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        let selectedRange = editor.selectedRange()
        let rowFrame = try XCTUnwrap(page.rowFrame(of: row.itemID))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: rowFrame.minY))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        let origin = scroll.contentView.bounds.origin.y
        XCTAssertFalse(page.followsBottom)
        let counts = Dictionary(uniqueKeysWithValues: descendants(TranscriptRowContainer.self, in: hosted).map { ($0.itemID, $0.measurementCount) })
        for step in 1...4 {
            let streamed = TranscriptMessage(id: "stream:tail", role: "assistant", text: String(repeating: "New answer text.\n\n", count: step * 5), state: "streaming", turn: "latest-question")
            if step == 1 { session.messages.append(streamed) } else { session.messages[session.messages.count - 1] = streamed }
            // Journal IDs are opaque, including a literal "stream:" prefix.
            // The same render identity survives the reply settling.
            try await settle(hosted, window: window) {
                page.snapshot?.messages.last?.text == streamed.text && (page.rowFrame(of: TranscriptRenderIdentity.block(streamed.id).key)?.height ?? 0) > 20
            }
            try await Task.sleep(for: .milliseconds(30))
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), selectedRange)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(page.rowFrame(of: row.itemID)), rowFrame)
        }
        for retained in descendants(TranscriptRowContainer.self, in: hosted) {
            if let count = counts[retained.itemID] {
                XCTAssertEqual(retained.measurementCount, count, "Streaming must not remeasure settled row \(retained.itemID)")
            }
        }
        let oldWidth = row.frame.width
        window.setContentSize(NSSize(width: 650, height: 700))
        try await settle(hosted, window: window) { row.frame.width < oldWidth && row.measurementCount > (counts[row.itemID] ?? 0) }
        XCTAssertTrue(window.firstResponder === editor, "Reflow keeps the same selectable native text")
        XCTAssertEqual(editor.selectedRange(), selectedRange)
        session.scrollAnchor = TranscriptAnchor(id: "m1", offset: 12, followsBottom: false)
        session.messages.insert(contentsOf: [TranscriptMessage(id: "earlier-user", role: "user", text: "Earlier question"),
                                            TranscriptMessage(id: "earlier-answer", role: "assistant", text: String(repeating: "Earlier paragraph.\n\n", count: 10))], at: 0)
        session.viewportRequest += 1
        try await settle(hosted, window: window) {
            guard let frame = page.rowFrame(of: row.itemID), page.rowFrame(of: "earlier-user") != nil else { return false }
            return abs(scroll.contentView.bounds.origin.y - (frame.minY - 12)) < 1
        }
        XCTAssertTrue(window.firstResponder === editor, "Prepending earlier history must keep the selected native text")
        XCTAssertEqual(editor.selectedRange(), selectedRange)
    }

    @MainActor func testDisclosureChangesTheExactHeightWithoutChangingRowContentOrWidth() async throws {
        try requireInteractivePointerTests()
        let session = SessionDisplay(id: "native-disclosure")
        let tool = ToolView(id: "read", name: "read", state: "completed", input: #"{"path":"README.md"}"#, output: "Tool output stays collapsed.", durationMs: 12, truncated: false)
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Read the project"),
                            TranscriptMessage(id: "answer", role: "assistant", text: "Finished.", thinking: "Exposed reasoning stays selectable.", tools: [tool], turn: "question")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, actions: TranscriptActions()))
        window.contentView = hosted; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(hosted, window: window) { self.descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page?.rowFrame(of: "block:answer") != nil }
        let page = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page)
        let row = try XCTUnwrap(descendants(TranscriptRowContainer.self, in: hosted).first { $0.itemID == "block:answer" })
        let initial = try XCTUnwrap(page.rowFrame(of: row.itemID))
        // The work-summary header begins at the block's top and is itself
        // clickable, so this exercises the real disclosure without test hooks.
        let answer = try XCTUnwrap(textFields(in: row).first { $0.stringValue == "Finished." })
        try await click(NSPoint(x: 30, y: 9), in: row, window: window)
        // Check the visible answer during the local transition as well as its
        // end state: shrinking the outer row must not clip animated contents.
        for _ in 0..<18 {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let drawn = answer.convert(answer.bounds, to: row)
            XCTAssertLessThanOrEqual(drawn.maxY, row.bounds.maxY + 1, "The exact-height boundary must contain the answer throughout disclosure")
            try await Task.sleep(for: .milliseconds(16))
        }
        try await settle(hosted, window: window) { (page.rowFrame(of: row.itemID)?.height ?? initial.height) < initial.height - 10 }
        let collapsed = try XCTUnwrap(page.rowFrame(of: row.itemID))
        XCTAssertEqual(collapsed.width, initial.width, accuracy: 0.5)
        try await click(NSPoint(x: 30, y: 9), in: row, window: window)
        try await settle(hosted, window: window) { abs((page.rowFrame(of: row.itemID)?.height ?? 0) - initial.height) < 1 }
        let reopened = try XCTUnwrap(page.rowFrame(of: row.itemID))
        XCTAssertEqual(reopened.width, initial.width, accuracy: 0.5)
        XCTAssertEqual(reopened.height, initial.height, accuracy: 1)
        XCTAssertEqual(session.messages.count, 2, "A local disclosure must not require a new host snapshot")
    }

    @MainActor func testDisabledParentKeepsNestedRetryUnavailableUntilReenabled() async throws {
        try requireInteractivePointerTests()
        let session = SessionDisplay(id: "disabled-row")
        session.messages = [TranscriptMessage(id: "failure:run:fixture", role: "system", text: "A fixture request failed.", kind: "failure")]
        var retries = 0
        let actions = TranscriptActions(retry: { retries += 1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: AnyView(NativeTranscriptView(session: session, actions: actions).disabled(true)))
        window.contentView = hosted; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(hosted, window: window) { self.descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page?.rowFrame(of: "failure:run:fixture") != nil }
        let row = try XCTUnwrap(descendants(TranscriptRowContainer.self, in: hosted).first)
        // The retry pill is at the trailing edge of the failure heading.
        let retryPoint = NSPoint(x: row.bounds.width - 55, y: 23)
        try await click(retryPoint, in: row, window: window)
        XCTAssertEqual(retries, 0, "An install/report overlay disables every nested row action")
        hosted.rootView = AnyView(NativeTranscriptView(session: session, actions: actions).disabled(false))
        try await Task.sleep(for: .milliseconds(100))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await click(retryPoint, in: row, window: window)
        try await settle(hosted, window: window) { retries == 1 }
        XCTAssertEqual(retries, 1, "The same unchanged row must become interactive when its parent is reenabled")
    }

    @MainActor private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor func testMarkdownContentRemainsSelectableWithoutSelectableDecorations() async throws {
        let source = "Selectable prose.\n\n- First selectable item\n- Second selectable item\n\n```swift\nlet selectableCode = 42\n```\n\n| Header |\n| --- |\n| Selectable cell |"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: MarkdownBodyView(source: source).padding(20))
        window.contentView = hosted; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        // Every block is in the one selectable text; the toolbar and copy
        // controls are not text, and a copy of the list gives its markers
        // as text, not the drawn bullets.
        let texts = descendants(MarkdownTextView.self, in: hosted)
        XCTAssertEqual(texts.count, 1, "The reply is one selectable text")
        let reply = try XCTUnwrap(texts.first)
        XCTAssertTrue(reply.isSelectable)
        for text in ["Selectable prose.", "First selectable item", "Second selectable item", "let selectableCode = 42", "Header", "Selectable cell"] {
            XCTAssertTrue(reply.string.contains(text), "Content must retain native text selection: \(text)")
        }
        let copied = reply.copyText([NSRange(location: 0, length: (reply.string as NSString).length)])
        XCTAssertTrue(copied.contains("- First selectable item\n- Second selectable item"), copied)
        XCTAssertFalse(copied.contains("•"), "Decorative list markers are not copied")
        XCTAssertFalse(reply.string.contains("swift"), "The language toolbar is a label; the code remains selectable")
        XCTAssertFalse(textFields(in: hosted).filter(\.isSelectable).contains { $0.stringValue.contains("Copy") }, "Copy controls must not inherit content selection")
    }

    func testAttributedSyntaxKeepsUnicodeAndColorsTheFollowingTokensExactly() {
        let code = "let cafe\u{301} = \"👩🏽‍💻 🇸🇬 e\u{301}\"\r\n// 🌈 comment with e\u{301}\nreturn 42"
        let styled = SyntaxHighlighter.attributed(code, language: "swift")
        XCTAssertEqual(String(styled.characters), code, "Coloring must never rewrite source or split its Unicode text")
        func runs(_ color: Color) -> [String] {
            styled.runs.filter { $0.foregroundColor == color }.map { String(styled[$0.range].characters) }
        }
        XCTAssertEqual(runs(TranscriptPalette.keyword), ["let", "return"])
        XCTAssertEqual(runs(TranscriptPalette.string), ["\"👩🏽‍💻 🇸🇬 e\u{301}\""])
        XCTAssertEqual(runs(TranscriptPalette.comment), ["// 🌈 comment with e\u{301}"])
        XCTAssertEqual(runs(TranscriptPalette.number), ["42"])
    }

    func testDenseSyntaxNearTheHighlightLimitKeepsEveryTokenAndPlainSpan() {
        let line = "let value = 42 // 🌈\n"
        let repetitions = 600
        let code = String(repeating: line, count: repetitions)
        XCTAssertLessThan(code.utf8.count, SyntaxHighlighter.limit)
        let styled = SyntaxHighlighter.attributed(code, language: "swift")
        XCTAssertEqual(String(styled.characters), code)
        XCTAssertEqual(styled.runs.filter { $0.foregroundColor == TranscriptPalette.keyword }.count, repetitions)
        XCTAssertEqual(styled.runs.filter { $0.foregroundColor == TranscriptPalette.number }.count, repetitions)
        XCTAssertEqual(styled.runs.filter { $0.foregroundColor == TranscriptPalette.comment }.count, repetitions)
        XCTAssertEqual(styled.runs.filter { $0.foregroundColor == TranscriptPalette.text }.map { String(styled[$0.range].characters) }.joined(), String(repeating: " value =  \n", count: repetitions))
    }

    func testCollapsedFileLabelUsesTheResolvedPathAndLegacyLabelsStillUseArguments() {
        var tool = ToolView(id: "write", name: "write", state: "running", input: "incomplete input while streaming", output: "", durationMs: nil, truncated: true, path: "/project/Sources/Feature.swift")
        XCTAssertEqual(TranscriptActivity.describe(tool), ActionDescription(kind: .write, verb: "Writing", object: "Sources/Feature.swift", path: "/project/Sources/Feature.swift"))
        tool.state = "completed"; tool.added = 10; tool.removed = 0
        XCTAssertEqual(TranscriptActivity.describe(tool).verb, "Created")
        tool.path = nil; tool.name = "read"; tool.input = #"{"path":"/old/project/README.md"}"#
        XCTAssertEqual(TranscriptActivity.describe(tool), ActionDescription(kind: .read, verb: "Read", object: "project/README.md", path: "/old/project/README.md"))
        tool.name = "grep"; tool.path = "/project"; tool.input = #"{"pattern":"needle"}"#
        XCTAssertEqual(TranscriptActivity.describe(tool).object, "needle", "A reported path does not replace the argument used by a search or other non-file label")
    }

    @MainActor private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor func testJumpToLatestStillFollowsWhenTheDocumentGrowsDuringTheJump() async throws {
        let session = SessionDisplay(id: "growing-jump")
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Question")]
        let page = TranscriptPage()
        page.state = "running"; page.bind(session)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let document = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_200))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        page.attach(scroll, host: document)
        page.viewportChanged(scroll.contentView.bounds.size)
        page.contentChanged(ContentGeometry(top: 0, height: 1_200))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertFalse(page.followsBottom)
        page.jumpToLatest()
        try await Task.sleep(for: .milliseconds(80))
        document.setFrameSize(NSSize(width: 600, height: 1_800))
        page.contentChanged(ContentGeometry(top: -scroll.contentView.bounds.origin.y, height: 1_800))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, document.frame.height - scroll.contentView.bounds.height, accuracy: 1, "A streaming delta during the animation must not leave the reader at the old bottom")
        XCTAssertTrue(page.followsBottom, "The old animation target must not detach the page")
        XCTAssertFalse(page.detached)
    }
}
