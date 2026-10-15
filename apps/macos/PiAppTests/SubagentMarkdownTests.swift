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
    @MainActor private func findFixture(_ messages: [(String, [String: WireValue])]) async throws -> (WorkspaceModel, NativeTranscriptPane, NSWindow) {
        let root = scratchRoot("agent-markdown-find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var bytes = try JSONEncoder().encode(WireValue.object(["type": .string("session"), "version": .number(3), "id": .string("agent-find")])); bytes.append(10)
        var parent: String?
        for (id, message) in messages {
            bytes.append(try JSONEncoder().encode(WireValue.object(["type": .string("message"), "id": .string(id), "parentId": parent.map(WireValue.string) ?? .null, "message": .object(message)])))
            bytes.append(10); parent = id
        }
        let path = root.appendingPathComponent("find.jsonl"); try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "agent-find", workspaceID: "project", title: "Find", path: path.path, profileID: "profile")]
        await model.select("agent-find")
        let session = try XCTUnwrap(model.selected)
        let pane = NativeTranscriptPane()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in pane.closeFind(focusing: false); window.contentView = nil; window.close() }
        pane.showTranscript(model: model, session: session, state: "idle", canFork: false, canQuote: false, enabled: true)
        return (model, pane, window)
    }
    @MainActor func testFindQuerySearchesRenderedAgentProseInSavedUnloadedRows() async throws {
        let delivered: WireValue = .object(["version": .number(1), "author": .string("subagent"), "childId": .string("child"), "turn": .number(1),
            "events": .array([.object(["kind": .string("note"), "text": .string("A **typed** observation.")])])])
        var messages: [(String, [String: WireValue])] = [
            ("question", ["role": .string("user"), "content": .string("Review")]),
            ("call-reply", ["role": .string("assistant"), "content": .array([
                .object(["type": .string("toolCall"), "id": .string("call"), "name": .string("subagent"), "arguments": .object(["task": .string("Check **task** boundaries.")])])])]),
            ("result", ["role": .string("toolResult"), "toolName": .string("subagent"), "toolCallId": .string("call"), "content": .string(try Self.tool(result: "Last **unique** result. Last **unique** result.").output)]),
            ("report", ["role": .string("assistant"), "content": .array([
                .object(["type": .string("toolCall"), "id": .string("report-call"), "name": .string("subagent_report"), "arguments": .object(["kind": .string("note"), "message": .string("A **reported** observation.")])])])]),
            ("delivery", ["role": .string("user"), "nativeAgentDelivery": delivered, "content": .string("agent_events")])
        ]
        for index in 0..<80 {
            messages.append(("later-user-\(index)", ["role": .string("user"), "content": .string("Later question \(index)")]))
            messages.append(("later-reply-\(index)", ["role": .string("assistant"), "content": .string("Later reply \(index)")]))
        }
        let (model, pane, window) = try await findFixture(messages)
        XCTAssertFalse(try XCTUnwrap(model.selected).messages.contains { $0.id == "result" }, "Search must include unmounted, unloaded agent prose")
        pane.showFind()
        for (query, ids) in [("Check task boundaries", ["call-reply"]), ("Last unique result", ["result", "result"]),
                             ("A reported observation", ["report"]), ("A typed observation", ["delivery"])] {
            pane.find.setQuery(query)
            try await eventually("Find query finished: \(query)") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
            XCTAssertFalse(pane.find.failed)
            XCTAssertEqual(pane.find.matches.map(\.messageID), ids, query)
            try await eventually("Rendered match is revealed: \(query)") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard !pane.document.focusPending, let text = pane.document.focusText else { return false }
                return (text.string as NSString).substring(with: pane.document.focusRange) == query
            }
        }
    }
    @MainActor func testFindQueryKeepsLiveTextAndUnsavedDelegatedTasksSearchable() async throws {
        let (model, pane, window) = try await findFixture([
            ("question", ["role": .string("user"), "content": .string("Review")]),
            ("live", ["role": .string("assistant"), "content": .string("Earlier saved text")])
        ])
        let session = try XCTUnwrap(model.selected)
        session.messages[1].text = "Current streaming text"; session.messages[1].state = "streaming"
        var pending = TranscriptMessage(id: "pending", role: "user", text: "A **live** report.")
        pending.nativeAgentDelivery = .object(["author": .string("subagent"), "childId": .string("child"), "turn": .number(1)])
        session.messages.append(pending)
        for (query, expected) in [("Current streaming text", ["live"]), ("A live report", ["pending"])] {
            pane.find.setQuery(query)
            try await eventually("Live Find finished") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
            XCTAssertEqual(pane.find.matches.map(\.messageID), expected)
        }
        session.isManagedSubagent = true; session.delegatedTask = "An **unsaved** delegated task."; session.messages = []
        model.chats[0].path = nil
        pane.find.setQuery("An unsaved delegated task")
        try await eventually("Unsaved task Find finished") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["subagent-task:agent-find"])
    }
    @MainActor func testFindQuerySurvivesAppendsThroughoutALiveRenderedSearch() async throws {
        for stage in HistoryReader.SearchReadStage.allCases {
            let messages: [(String,[String:WireValue])] = (0..<121).map { index in
                ("delivery-\(index)",["role":.string("user"),"content":.string("A **rendered** report"),
                    "nativeAgentDelivery":.object(["author":.string("subagent"),"childId":.string("child"),"turn":.number(1)])])
            }
            let (model,pane,window) = try await findFixture(messages)
            let session = try XCTUnwrap(model.selected), path = try XCTUnwrap(model.chats[0].path)
            session.runState = .running; model.opened.insert(session.id)
            await model.history.releaseIndexes()
            // Exercise messages, tool results and the helper's sorted state
            // records at the actual index/scan publication boundaries.
            let appended: String
            switch stage {
            case .captured: appended = "{\"type\":\"message\",\"id\":\"new-reply\",\"parentId\":\"delivery-120\",\"message\":{\"role\":\"assistant\",\"content\":\"Still working\"}}"
            case .indexed: appended = "{\"type\":\"message\",\"id\":\"new-result\",\"parentId\":\"delivery-120\",\"message\":{\"role\":\"toolResult\",\"toolName\":\"read\",\"toolCallId\":\"call\",\"content\":\"Read completed\"}}"
            case .scanned: appended = "{\"customType\":\"pi-app.native.state.v1\",\"data\":{\"active\":true},\"id\":\"state\",\"parentId\":\"delivery-120\",\"timestamp\":\"2026-10-16T00:00:00Z\",\"type\":\"custom\"}"
            }
            let addition = Data((appended + "\n").utf8)
            let once = ContentSearchTests.Once()
            await model.history.observeSearchReads { current in
                if current == stage { try once.run { try ContentSearchTests.append(addition,to:path) } }
            }
            pane.showFind(); pane.find.setQuery("A rendered report")
            try await eventually("Live rendered Find finishes across both pages") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching
            }
            XCTAssertFalse(pane.find.failed,"An ordinary \(stage) append must never become Search failed")
            XCTAssertEqual(pane.find.matches.map(\.messageID),(0..<121).map { "delivery-\($0)" })
            XCTAssertNotEqual(pane.findBar?.count.line.text,"Search failed")
            pane.closeFind(focusing:false); await model.history.observeSearchReads(nil)
        }
    }
    @MainActor func testFindQuerySearchesALegacyChildsRenderedDelegatedTask() async throws {
        let (model, pane, window) = try await findFixture([
            ("question", ["role": .string("user"), "content": .string("Check **legacy** task boundaries.")]),
            ("reply", ["role": .string("assistant"), "content": .string("Done.")])
        ])
        var link = SubagentTranscriptTests.link; link.childSessionID = "agent-find"
        model.chats[0].delegation = link
        let session = try XCTUnwrap(model.selected); session.isManagedSubagent = true
        let rows = session.messages; session.messages = rows
        pane.showTranscript(model: model, session: session, state: "idle", canFork: false, canQuote: false, enabled: true)
        pane.showFind(); pane.find.setQuery("Check legacy task boundaries")
        try await eventually("Legacy child task Find finished") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["question"])
        try await eventually("Legacy child task is marked") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard !pane.document.focusPending, let text = pane.document.focusText else { return false }
            return (text.string as NSString).substring(with: pane.document.focusRange) == "Check legacy task boundaries"
        }
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
    @MainActor func testBoundedCodePreviewCopiesTheWholeFenceThroughBothNativeActions() async throws {
        let code = String(repeating: "let value = 123 // Retain every line\n", count: 80) + "finish()"
        func source(_ code: String) -> String { "```swift\n" + code + "\n```" }
        let row = try Self.card(task: "Task", result: source(code))
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).last)
        let surface = body.markdown, text = surface.textView
        let window = NSWindow(contentRect: row.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = row
        defer { window.contentView = nil; window.close() }
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(body.isComplete); XCTAssertLessThan(text.string.count, code.count)
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil), in: container)
        let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        surface.mouseMoved(with: event)
        let toolbar = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownCodeToolbarView }.first)
        func checkCopies(_ expected: String) throws {
            NSPasteboard.general.clearContents()
            XCTAssertTrue(toolbar.copy.accessibilityPerformPress())
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected, "The hover button copies the complete fence")
            NSPasteboard.general.clearContents()
            let action = try XCTUnwrap(text.accessibilityCustomActions()?.first { $0.name == "Copy code" })
            XCTAssertTrue(action.handler?() ?? false)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected, "VoiceOver copies the same complete fence")
        }
        try checkCopies(code)
        body.setExpanded(true)
        try await eventually("The entire code fence is drawn") { body.isComplete }
        try checkCopies(code)
        body.setExpanded(false); XCTAssertFalse(body.isComplete)
        try checkCopies(code)
        let prefix = text.string, changed = code + "\nnewEnding()"
        body.update(source(changed), environment: .init())
        XCTAssertEqual(text.string, prefix, "Only the hidden suffix changed; the existing toolbar must still update")
        try checkCopies(changed)
        body.copy.onPress?(); XCTAssertEqual(NSPasteboard.general.string(forType: .string), source(changed))
    }
    @MainActor func testNestedCodePreviewCopyTargetsKeepTheirOrderWhileExpanding() async throws {
        let long = String(repeating: "  let nested = 42\n", count: 90) + "  done()"
        let source = "```\n```\n\n> ```swift\n> first()\n> ```\n\n- Nested fence\n\n  ```swift\n" + long + "\n  ```\n\n```swift\nlast()\n```"
        let row = try Self.card(task: "Task", result: source)
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).last)
        // Empty fences have no parsed block, so they must not shift the targets.
        let expected = ["first()", String(repeating: "let nested = 42\n", count: 90) + "done()", "last()"]
        func checkCopies(_ codes: ArraySlice<String>) throws {
            let actions = (body.markdown.textView.accessibilityCustomActions() ?? []).filter { $0.name.hasPrefix("Copy code") }
            XCTAssertEqual(actions.count, codes.count)
            for (action, code) in zip(actions, codes) {
                NSPasteboard.general.clearContents(); XCTAssertTrue(action.handler?() ?? false)
                XCTAssertEqual(NSPasteboard.general.string(forType: .string), code)
            }
        }
        XCTAssertFalse(body.isComplete)
        try checkCopies(expected.prefix(2))
        body.setExpanded(true)
        try await eventually("All nested fences are drawn") { body.isComplete }
        try checkCopies(expected[...])
        body.setExpanded(false)
        try checkCopies(expected.prefix(2))
    }
    @MainActor func testCopyIncludesTheVisibleTailOfATruncatedMarkdownRun() throws {
        for source in ["**Lead** " + String(repeating: "body ", count: 400),
                       "**Lead** [" + String(repeating: "body ", count: 400) + "](https://example.test)",
                       "**Lead** `" + String(repeating: "body ", count: 400) + "`"] {
            let row = try Self.card(task: "Task", result: source)
            let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).last)
            XCTAssertFalse(body.isComplete)
            let text = body.markdown.textView
            let selection = (text.string as NSString).range(of: "Lead body")
            XCTAssertNotEqual(selection.location, NSNotFound)
            let opening = source.contains("[") ? "[" : source.contains("`") ? "`" : ""
            XCTAssertEqual(text.copyText([selection]), "**Lead** " + opening + "body")
            let tail = NSRange(location: 1_190, length: 10)
            XCTAssertEqual(text.copyText([tail]), (text.string as NSString).substring(with: tail))
        }
    }

    /// The oracle is authored alongside a small random Markdown grammar; it
    /// never asks Foundation's parser or the copy mapper for source positions.
    /// Check every grapheme boundary and every nonempty visible selection,
    /// including surrogate pairs and combining characters.
    @MainActor func testRandomMarkdownPreviewSelectionsPreserveTheirExactSource() {
        var random = MarkdownCopyRandom(seed: 0xB311015)
        var checks = 0, boundaries = 0
        for sample in 0..<40 {
            var document = MarkdownCopyOracle()
            var kinds = [0, 1, 2, 3, 4, 5, 6, 7]
            for i in kinds.indices.reversed() { kinds.swapAt(i, random.next(i + 1)) }
            for (index, kind) in kinds.enumerated() {
                if index > 0 { document.append(body: " ") }
                let body = (0..<(1 + random.next(3))).map { _ in String(["a", "b", "x", "a", "é", "😀", "e\u{301}"][random.next(7)]) }.joined()
                switch kind {
                case 0: document.append(body: body)
                case 1: document.append(body: body, before: "**", after: "**")
                case 2: document.append(body: body, before: "*", after: "*")
                case 3: document.append(body: body, before: "`", after: "`")
                case 4: document.append(body: body, before: "[", after: "](https://example.test/\(sample))")
                case 5: document.append(body: "&", source: "&amp;")
                case 6: document.append(body: "😀", source: "&#x1F600;")
                default: document.append(body: "*", source: #"\*"#)
                }
            }
            var fenced = MarkdownCopyOracle()
            fenced.append(body: sample % 5 == 0 ? "swift" : document.rendered + " `*`", before: "```swift\n", after: "\n```", wraps: false)
            for document in [document, fenced] {
                XCTAssertEqual(Self.assistant(document.source).textView.string, document.rendered, "The oracle describes the actual native reader")
                let visible = document.rendered as NSString
                let offsets = document.rendered.indices.map { $0.utf16Offset(in: document.rendered) } + [visible.length]
                for boundaryIndex in 1..<offsets.count {
                    let boundary = offsets[boundaryIndex]
                    boundaries += 1
                    let preview = visible.substring(to: boundary)
                    for startIndex in 0..<boundaryIndex {
                        for endIndex in (startIndex + 1)...boundaryIndex {
                            let start = offsets[startIndex], end = offsets[endIndex]
                            let selected = NSRange(location: start, length: end - start)
                            let expected = boundary == visible.length && start == 0 && end == boundary ? document.source : document.copy(selected)
                            let actual = MarkdownSourceCopy.copy(document.source, rendered: preview, ranges: [selected], complete: boundary == visible.length)
                            checks += 1
                            if actual != expected {
                                XCTFail("seed=0xB311015 sample=\(sample) boundary=\(boundary) selection=\(selected) source=\(document.source) expected=\(expected.debugDescription) actual=\(String(describing: actual))")
                                return
                            }
                        }
                    }
                }
            }
        }
        print("PROPERTY Markdown preview: 80 random documents, \(boundaries) boundaries, \(checks) exact source selections")
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
        let (_, pane, window) = try await findFixture([
            ("question", ["role": .string("user"), "content": .string("Review")]),
            ("reply", ["role": .string("assistant"), "content": .array([
                .object(["type": .string("toolCall"), "id": .string("call"), "name": .string("subagent"), "arguments": .object(["task": .string("Short task")])])])]),
            ("result", ["role": .string("toolResult"), "toolName": .string("subagent"), "toolCallId": .string("call"), "content": .string(try Self.tool(result: source).output)]),
            ("done", ["role": .string("assistant"), "content": .string("Done.")])
        ])
        let document = pane.document
        pane.showFind(); pane.find.setQuery("Last unique result")
        try await eventually("The Markdown result's Find match") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && document.focusText != nil && !document.focusPending
        }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: document).first { $0.accessibilityIdentifier() == "agent-markdown-result" })
        XCTAssertTrue(body.expanded)
        let text = try XCTUnwrap(document.focusText), range = document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), "Last unique result")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        var glyph = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        glyph.origin.x += text.textContainerOrigin.x; glyph.origin.y += text.textContainerOrigin.y
        let rect = text.convert(glyph, to: pane.scrollView.contentView)
        XCTAssertTrue(pane.scrollView.contentView.bounds.intersects(rect), "clip=\(pane.scrollView.contentView.bounds) match=\(rect)")
        var owner: NSView? = body
        while owner != nil && !(owner is TranscriptRowContainer) { owner = owner?.superview }
        let work = try XCTUnwrap(owner as? TranscriptRowContainer)
        work.contentSizeChanged()
        XCTAssertNil(document.resolveFocus()?.target, "A pending native height validation must defer the Find destination")
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

private struct MarkdownCopyRandom {
    var seed: UInt64
    mutating func next(_ upper: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 32) % UInt64(upper))
    }
}
private struct MarkdownCopyOracle {
    var source = "", rendered = ""
    var atoms: [(visible: NSRange, body: NSRange, whole: NSRange)] = []
    mutating func append(body: String, source authored: String? = nil, before: String = "", after: String = "", wraps: Bool = true) {
        let raw = authored ?? body, start = source.utf16.count, offset = rendered.utf16.count
        source += before + raw + after; rendered += body
        atoms.append((NSRange(location: offset, length: body.utf16.count),
                      NSRange(location: start + before.utf16.count, length: raw.utf16.count),
                      wraps ? NSRange(location: start, length: before.utf16.count + raw.utf16.count + after.utf16.count) : NSRange(location: start + before.utf16.count, length: raw.utf16.count)))
    }
    func copy(_ selection: NSRange) -> String {
        var first: Int?, end = 0
        for atom in atoms {
            let common = NSIntersectionRange(selection, atom.visible)
            guard common.length > 0 else { continue }
            let range: NSRange
            if common == atom.visible { range = atom.whole }
            else if atom.body.length == atom.visible.length {
                range = NSRange(location: atom.body.location + common.location - atom.visible.location, length: common.length)
            } else { range = atom.body }
            first = min(first ?? range.location, range.location); end = max(end, NSMaxRange(range))
        }
        return (source as NSString).substring(with: NSRange(location: first ?? 0, length: end - (first ?? 0)))
    }
}
